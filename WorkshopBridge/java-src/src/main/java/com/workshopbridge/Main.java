package com.workshopbridge;

import java.lang.reflect.Constructor;
import java.lang.reflect.Method;

/**
 * Optional entry point: ZombieBuddy calls {@code Main.main(String[])} when the
 * mod loads. Kept deliberately light - the backend initializes lazily on the
 * first Lua call, when ZomboidFileSystem is guaranteed ready.
 */
public class Main {
    public static void main(String[] args) {
        exposeLuaApi();
        System.out.println("[WorkshopBridge] Java backend loaded via ZombieBuddy "
                + "(Lua API: wbIsAvailable, wbGetSteamCmdPath, wbGetWorkshopId, "
                + "wbCheckForUpdates, wbUpdateAll, wbUpdateMod, wbInvalidateModCaches, "
                + "wbGetJobStatus, wbOpenWorkshopPage, wbExportModList, "
                + "wbImportMods, wbImportCollection, wbAdoptMod, wbCheckDependencies, "
                + "wbGetServerMods, wbGetModIds, wbDeleteMod)");
        runDiagnostics();
    }

    /**
     * Runs {@code com.workshopbridge.Diagnostics.run()} when the diagnostics
     * sources were compiled in (dev builds). Reflective so release builds
     * ({@code -Pdiagnostics=false}) compile and run without the class.
     */
    private static void runDiagnostics() {
        try {
            Class.forName("com.workshopbridge.Diagnostics").getMethod("run").invoke(null);
        } catch (Throwable ignored) {
            // diagnostics excluded from this build
        }
    }

    /**
     * Registers our {@code @LuaMethod(global = true)} functions with the game's
     * Lua state. ZombieBuddy's automatic discovery runs in its afterExposeAll
     * phase, which fires BEFORE our jar is loaded on a cold boot (our jar is
     * found via the loadMods hook), so without this the wb* globals are never
     * registered and the mod only starts working after a Lua reload. Main.main
     * runs at jar-load time, after ZB has already exposed its own classes, so
     * {@code LuaManager.exposer} exists and we can expose immediately. This
     * mirrors what ZB's {@code Exposer.afterExposeAll} does for classes with
     * global @LuaMethod methods. Idempotent: a later afterExposeAll (e.g. on
     * Lua reset) just re-registers the same globals.
     *
     * Pure reflection, so an older/newer ZombieBuddy without these entry
     * points degrades to the previous behavior instead of breaking the load.
     */
    private static void exposeLuaApi() {
        try {
            Class<?> exposerClass = Class.forName("me.zed_0xff.zombie_buddy.Exposer");
            // Register for future afterExposeAll runs (package-private in ZB).
            Method add = exposerClass.getDeclaredMethod(
                    "addClassWithGlobalLuaMethod", Class.class);
            add.setAccessible(true);
            add.invoke(null, SteamCmdApi.class);
            // Expose right now; the Lua engine is already up.
            Object exposer = Class.forName("zombie.Lua.LuaManager")
                    .getField("exposer").get(null);
            if (exposer == null) {
                System.out.println("[WorkshopBridge] Lua exposer not ready yet; "
                        + "wb* globals will be registered on the next Lua (re)load");
                return;
            }
            Constructor<?> ctor = SteamCmdApi.class.getDeclaredConstructor();
            ctor.setAccessible(true);
            Object instance = ctor.newInstance();
            Method exposeGlobals = exposer.getClass()
                    .getMethod("exposeGlobalFunctions", Object.class);
            exposeGlobals.invoke(exposer, instance);
            System.out.println("[WorkshopBridge] wb* Lua globals exposed");
        } catch (Throwable t) {
            System.out.println("[WorkshopBridge] manual Lua exposure failed: " + t
                    + " (wb* globals may only appear after a Lua reload)");
        }
    }
}
