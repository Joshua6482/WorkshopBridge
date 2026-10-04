package com.workshopbridge;

import java.lang.reflect.Field;
import java.util.Map;

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
     * Workshop id for a PZ mod id (the id= value from mod.info),
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
     * Exports workshop ids (comma-separated) as one Steam Workshop URL per
     * line to a timestamped file under {@code <Zomboid>/workshopbridge-exports/}.
     * Synchronous: writing a small text file needs no job. Returns a JSON
     * result ({@code ok/path/count}) or null on failure.
     */
    @LuaMethod(name = "wbExportModList", global = true)
    public static String wbExportModList(String idsCsv) {
        try {
            java.util.List<String> ids = parseIdList(idsCsv);
            String path = Backend.get().exportModList(ids);
            java.util.Map<String, Object> r = new java.util.LinkedHashMap<>();
            r.put("ok", true);
            r.put("path", path);
            r.put("count", ids.size());
            return Json.stringify(r);
        } catch (Throwable t) {
            return null;
        }
    }

    /** Starts an import job for the given comma-separated workshop ids.
     * Returns a job id, or null on failure. */
    @LuaMethod(name = "wbImportMods", global = true)
    public static String wbImportMods(String idsCsv) {
        try {
            java.util.List<String> ids = parseIdList(idsCsv);
            if (ids.isEmpty()) {
                return null;
            }
            return Backend.get().jobs().submitImport(ids);
        } catch (Throwable t) {
            return null;
        }
    }

    /** Starts an import job for every mod in a workshop collection.
     * Returns a job id, or null on failure. */
    @LuaMethod(name = "wbImportCollection", global = true)
    public static String wbImportCollection(String collectionId) {
        try {
            return Backend.get().jobs().submitImportCollection(collectionId);
        } catch (Throwable t) {
            return null;
        }
    }

    /**
     * Starts an adopt job: force-downloads the workshop item, verifies it
     * contains {@code modId} before overwriting, then installs and records
     * it. Returns a job id, or null on failure.
     */
    @LuaMethod(name = "wbAdoptMod", global = true)
    public static String wbAdoptMod(String workshopId, String modId) {
        try {
            return Backend.get().jobs().submitAdopt(workshopId, modId);
        } catch (Throwable t) {
            return null;
        }
    }

    /** Splits a comma/newline/whitespace-separated id list, digits only,
     * order kept, duplicates dropped. */
    static java.util.List<String> parseIdList(String idsCsv) {
        java.util.List<String> ids = new java.util.ArrayList<>();
        if (idsCsv == null) {
            return ids;
        }
        for (String part : idsCsv.split("[,\\s]+")) {
            String id = part.trim();
            if (id.matches("\\d+") && !ids.contains(id)) {
                ids.add(id);
            }
        }
        return ids;
    }

    /**
     * Invalidates the game's cached mod directory list and mod-info cache so a
     * subsequent {@code ModSelector:reloadMods()} actually sees freshly
     * downloaded/updated mods. The game scans the mod folders once and caches
     * the result (ZomboidFileSystem.modFolders), and ChooseGameInfo caches
     * parsed mod.infos by mod id; {@code reloadMods()} alone rebuilds the menu
     * model from those stale caches, and the game's own file watcher never
     * notices brand-new mod folders (its isModFile gate only matches paths
     * under already-cached mod dirs).
     *
     * resetModFolders() + ChooseGameInfo.Reset() alone are NOT enough: the
     * game also caches modIdToDir/modDirToMod on ZomboidFileSystem, and each
     * Mod caches isAvailable() in its availableDone flag. Without clearing
     * those, a mod whose missing requirement just got installed keeps its
     * red X until restart (the menu rebuild reuses the stale Mod object via
     * getModInfoForDir). This mirrors what the game's own
     * ZomboidFileSystem.update() does when its watcher fires. Call it on the
     * game thread (Lua job-completion handlers qualify), right before
     * {@code ms:reloadMods()}.
     */
    @LuaMethod(name = "wbInvalidateModCaches", global = true)
    public static void wbInvalidateModCaches() {
        try {
            clearModCacheMap("modIdToDir");
            clearModCacheMap("modDirToMod");
            zombie.ZomboidFileSystem.instance.resetModFolders();
            zombie.gameStates.ChooseGameInfo.Reset();
            System.out.println("[WorkshopBridge] invalidated game mod caches");
        } catch (Throwable t) {
            System.out.println("[WorkshopBridge] mod cache invalidation failed: " + t);
        }
    }

    /**
     * Best-effort clear of a private mod-cache map on
     * ZomboidFileSystem.instance (mirrors update()'s own refresh). Logs and
     * continues when the field is absent (e.g. a future game build renamed
     * it): the remaining invalidation steps still run.
     */
    private static void clearModCacheMap(String fieldName) {
        try {
            Object zfs = zombie.ZomboidFileSystem.instance;
            Field f = zfs.getClass().getDeclaredField(fieldName);
            f.setAccessible(true);
            Object v = f.get(zfs);
            if (v instanceof Map) {
                ((Map<?, ?>) v).clear();
            }
        } catch (ReflectiveOperationException e) {
            System.out.println("[WorkshopBridge] mod cache '" + fieldName
                    + "' not cleared (" + e.getMessage() + ")");
        }
    }

    /**
     * Starts a dependency-check job for a workshop item: resolves its
     * "required items" (transitively) on a background thread. The job's
     * {@code deps} status field carries one {id, title, installed} map per
     * required item when done. Returns a job id, or null on failure.
     */
    @LuaMethod(name = "wbCheckDependencies", global = true)
    public static String wbCheckDependencies(String workshopId) {
        try {
            if (workshopId == null || !workshopId.matches("[0-9]+")) return null;
            return Backend.get().jobs().submitDependencies(workshopId);
        } catch (Throwable t) {
            return null;
        }
    }

    /**
     * Polls a job. Returns a JSON status object
     * ({@code state/done/total/message[/error][/updates][/deps]}), or null for
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
        * {@code java.awt.Desktop} first, then falls back to OS-specific launcher
        * commands. The workshop id is validated as digits only before it is used
        * in a command. If process launching fails because posix_spawn is blocked
        * (e.g. inside steam-run's sandbox), add
        * {@code -Djdk.lang.Process.launchMechanism=FORK} to the game's Java
        * command line; see docs/INSTALL.md.
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

    /**
     * Reads the server's mod list from the failed join's connection details
     * (see {@link ServerJoinMods}). Returns a JSON object
     * {@code {steamMode, mods:[{id, workshopId, name, installed}]}}, or null
     * when there is no join to read from or the packet could not be parsed.
     * Lua falls back to the single mod named in the OnConnectFailed message
     * on null. Synchronous and fast: pure buffer parsing, no network.
     */
    @LuaMethod(name = "wbGetServerMods", global = true)
    public static String wbGetServerMods() {
        try {
            ServerJoinMods.Result r = ServerJoinMods.read();
            if (r == null) {
                return null;
            }
            java.util.List<Object> mods = new java.util.ArrayList<>();
            for (ServerJoinMods.Mod m : r.mods) {
                java.util.Map<String, Object> e = new java.util.LinkedHashMap<>();
                e.put("id", m.id);
                e.put("workshopId", m.workshopId);
                e.put("name", m.name);
                e.put("installed", m.installed);
                mods.add(e);
            }
            java.util.Map<String, Object> root = new java.util.LinkedHashMap<>();
            root.put("steamMode", r.steamMode);
            root.put("mods", mods);
            return Json.stringify(root);
        } catch (Throwable t) {
            return null;
        }
    }

    /**
     * Returns the mod ids recorded for a workshop item (JSON array), or null
     * when the item is not tracked. Used by the delete confirmation dialog
     * to list sub-mods.
     */
    @LuaMethod(name = "wbGetModIds", global = true)
    public static String wbGetModIds(String workshopId) {
        try {
            if (workshopId == null || !workshopId.matches("[0-9]+")) return null;
            WorkshopMap.Entry e = Backend.get().workshopMap().snapshot().get(workshopId);
            if (e == null) return null;
            return Json.stringify(new java.util.ArrayList<>(e.modIds));
        } catch (Throwable t) {
            return null;
        }
    }

    /**
     * Deletes a mod. With a tracked workshop id, deletes every mod folder
     * in its map entry and drops the entry (so update-all cannot resurrect
     * it); with a null/empty workshop id, deletes one manually-installed
     * mod folder. Every folder passes ModDeleter's safety guards or is
     * reported, never silently removed. Returns a JSON
     * {@code {deleted:[], skipped:{id:reason}, failed:[]}}.
     */
    @LuaMethod(name = "wbDeleteMod", global = true)
    public static String wbDeleteMod(String workshopId, String modId) {
        try {
            if (modId == null || modId.isEmpty()) return null;
            Backend backend = Backend.get();
            ModDeleter.Result r = (workshopId != null && workshopId.matches("[0-9]+")
                    && backend.workshopMap().snapshot().containsKey(workshopId))
                    ? ModDeleter.deleteWorkshopItem(backend, workshopId)
                    : ModDeleter.deleteModFolder(backend, modId);
            java.util.Map<String, Object> out = new java.util.LinkedHashMap<>();
            out.put("deleted", r.deleted);
            out.put("skipped", r.skipped);
            out.put("failed", r.failed);
            return Json.stringify(out);
        } catch (Throwable t) {
            return null;
        }
    }
}
