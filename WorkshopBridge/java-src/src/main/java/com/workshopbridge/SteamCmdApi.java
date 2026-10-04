package com.workshopbridge;

import se.krka.kahlua.integration.annotations.LuaMethod;

/**
 * The Lua-visible API, exposed as plain globals via ZombieBuddy.
 *
 * Every method is static, non-blocking and thread-safe: anything slow runs on
 * a JobManager background thread and Lua polls {@link #wbGetJobStatus}.
 * {@code wbGetJobStatus} returns a JSON string (decoded in Lua by WB_Json)
 * because Kahlua return marshaling of Java objects is not something we want
 * to depend on.
 */
public final class SteamCmdApi {
    private SteamCmdApi() {}

    @LuaMethod(name = "wbIsAvailable", global = true)
    public static boolean wbIsAvailable() {
        try {
            Backend.get();
            return true;
        } catch (Throwable t) {
            System.out.println("[WorkshopBridge] backend init failed: " + t);
            return false;
        }
    }

    /** Absolute steamcmd path, or null when not detected. */
    @LuaMethod(name = "wbGetSteamCmdPath", global = true)
    public static String wbGetSteamCmdPath() {
        try {
            return Backend.get().steamCmd().findExecutable();
        } catch (Throwable t) {
            return null;
        }
    }

    /**
     * Workshop id for a PZ mod id (the {@code id=} value from mod.info),
     * or null when the mod wasn't installed via WorkshopBridge.
     */
    @LuaMethod(name = "wbGetWorkshopId", global = true)
    public static String wbGetWorkshopId(String modId) {
        try {
            return modId == null ? null : Backend.get().getWorkshopId(modId);
        } catch (Throwable t) {
            return null;
        }
    }

    /** Starts an update-check job. Returns a job id, or null on failure. */
    @LuaMethod(name = "wbCheckForUpdates", global = true)
    public static String wbCheckForUpdates() {
        try {
            return Backend.get().jobs().submitCheck();
        } catch (Throwable t) {
            return null;
        }
    }

    /** Starts an update-all job. Returns a job id, or null on failure. */
    @LuaMethod(name = "wbUpdateAll", global = true)
    public static String wbUpdateAll() {
        try {
            return Backend.get().jobs().submitUpdateAll();
        } catch (Throwable t) {
            return null;
        }
    }

    /** Starts an update job for one workshop item. Returns a job id, or null on failure. */
    @LuaMethod(name = "wbUpdateMod", global = true)
    public static String wbUpdateMod(String workshopId) {
        try {
            return Backend.get().jobs().submitUpdate(workshopId);
        } catch (Throwable t) {
            return null;
        }
    }

    /**
     * Invalidates the game's cached mod directory list and mod-info cache so a
     * subsequent {@code ModSelector:reloadMods()} actually sees freshly
     * downloaded/updated mods. The game scans the mod folders once and caches
     * the result (ZomboidFileSystem.modFolders), and ChooseGameInfo caches
     * parsed mod.infos by mod id; {@code reloadMods()} alone rebuilds the menu
     * model from those stale caches, and the game's own file watcher never
     * notices brand-new mod folders (its isModFile gate only matches paths
     * under already-cached mod dirs). This mirrors what the game's own
     * ZomboidFileSystem.update() does when its watcher fires. Call it on the
     * game thread (Lua job-completion handlers qualify), right before
     * {@code ms:reloadMods()}.
     */
    @LuaMethod(name = "wbInvalidateModCaches", global = true)
    public static void wbInvalidateModCaches() {
        try {
            zombie.ZomboidFileSystem.instance.resetModFolders();
            zombie.gameStates.ChooseGameInfo.Reset();
            System.out.println("[WorkshopBridge] invalidated game mod caches");
        } catch (Throwable t) {
            System.out.println("[WorkshopBridge] mod cache invalidation failed: " + t);
        }
    }

    /**
     * Polls a job. Returns a JSON status object
     * ({@code state/done/total/message[/error][/updates]}), or null for
     * unknown job ids. See docs/ARCHITECTURE.md for the shape.
     */
    @LuaMethod(name = "wbGetJobStatus", global = true)
    public static String wbGetJobStatus(String jobId) {
        try {
            return jobId == null ? null : Backend.get().jobs().statusJson(jobId);
        } catch (Throwable t) {
            return null;
        }
    }

    /**
     * Opens the workshop page for an item in the system browser.
     * Returns true if a browser process was launched. Tries
     * {@code java.awt.Desktop} first (the platform-sanctioned path), then
     * falls back to OS-specific launcher commands. The id is validated as
     * digits only before it goes anywhere near a command line, so the
     * {@code cmd /c start} path on Windows can't be injected into. On systems
     * where the JDK's posix_spawn launcher is blocked (e.g. inside
     * steam-run's sandbox), add {@code -Djdk.lang.Process.launchMechanism=FORK}
     * to the game's Java command line; see docs/INSTALL.md.
     */
    @LuaMethod(name = "wbOpenWorkshopPage", global = true)
    public static boolean wbOpenWorkshopPage(String workshopId) {
        try {
            if (workshopId == null || !workshopId.matches("[0-9]+")) return false;
            String url = "https://steamcommunity.com/sharedfiles/filedetails/?id=" + workshopId;
            if (openWithDesktop(url)) return true;
            for (String[] cmd : browserCommands(url)) {
                try {
                    new ProcessBuilder(cmd).start();
                    return true;
                } catch (Exception ignored) {
                }
            }
            System.out.println("[WorkshopBridge] could not open a browser for " + url);
            return false;
        } catch (Throwable t) {
            return false;
        }
    }

    /**
     * Opens a URL via {@code java.awt.Desktop}. Returns false (without
     * throwing) when the desktop module is missing, headless, or BROWSE is
     * unsupported, so the caller can fall back to launcher commands.
     * Package-visible for tests.
     */
    static boolean openWithDesktop(String url) {
        try {
            if (!java.awt.Desktop.isDesktopSupported()) return false;
            java.awt.Desktop desktop = java.awt.Desktop.getDesktop();
            if (!desktop.isSupported(java.awt.Desktop.Action.BROWSE)) return false;
            desktop.browse(new java.net.URI(url));
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    /**
     * OS-specific commands that open a URL in the default browser, in
     * preference order. Package-visible for tests.
     */
    static String[][] browserCommands(String url) {
        String os = System.getProperty("os.name", "").toLowerCase(java.util.Locale.ROOT);
        if (os.contains("win")) {
            // the empty title keeps start from eating the URL as the title
            return new String[][] { { "cmd", "/c", "start", "\"\"", url } };
        }
        if (os.contains("mac")) {
            return new String[][] { { "open", url } };
        }
        return new String[][] { { "xdg-open", url }, { "gio", "open", url } };
    }
}
