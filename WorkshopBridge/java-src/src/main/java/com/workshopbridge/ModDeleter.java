package com.workshopbridge;

import java.io.File;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

/**
 * Deletes mods from disk. Deletion is the one irreversible thing this mod
 * does, so every folder goes through the guards in {@link #checkFolder}
 * and anything suspicious is skipped with a reason instead of removed:
 *
 * <ul>
 *   <li>the folder must be the one the game itself resolves for the mod
 *       id ({@code ZomboidFileSystem.getModDir}) - never a hand-built path,
 *       so a crafted id cannot traverse anywhere;</li>
 *   <li>the folder's canonical path must lie strictly inside the mods dir
 *       (symlinks pointing out are caught);</li>
 *   <li>the folder's {@code mod.info} must declare the expected id, so a
 *       folder that was repurposed since is never wiped;</li>
 *   <li>a folder still claimed by another workshop map entry is left alone.</li>
 * </ul>
 *
 * <p>Deleting a tracked workshop item also drops its map entry, otherwise a
 * later "update all" would silently re-download the deleted mod.
 */
public final class ModDeleter {
    private ModDeleter() {}

    /** Outcome of a delete: what went and what was deliberately kept. */
    public static final class Result {
        /** mod ids whose folders were removed */
        public final List<String> deleted;
        /** mod id -> human reason, for folders deliberately left in place */
        public final Map<String, String> skipped;
        /** mod ids whose folder was attempted but is still there */
        public final List<String> failed;
        Result(List<String> deleted, Map<String, String> skipped,
                List<String> failed) {
            this.deleted = deleted;
            this.skipped = skipped;
            this.failed = failed;
        }
        public boolean ok() {
            return skipped.isEmpty() && failed.isEmpty();
        }
    }

    /**
     * Deletes every mod folder recorded for a workshop item, then drops the
     * map entry. The entry is dropped whenever nothing failed outright (a
     * folder that could not be removed keeps its entry so a retry still
     * finds it).
     */
    public static Result deleteWorkshopItem(Backend backend, String workshopId) {
        List<String> modIds = new ArrayList<>();
        WorkshopMap.Entry entry = backend.workshopMap().snapshot().get(workshopId);
        if (entry != null) {
            modIds.addAll(entry.modIds);
        }
        Result r = deleteFolders(backend, workshopId, modIds);
        if (r.failed.isEmpty()) {
            backend.workshopMap().remove(workshopId);
        }
        return r;
    }

    /**
     * Deletes a single manually-installed mod folder (no map entry).
     * Refuses when the id is still claimed by a workshop map entry.
     */
    public static Result deleteModFolder(Backend backend, String modId) {
        String owner = backend.workshopMap().getWorkshopId(modId);
        if (owner != null) {
            Map<String, String> skipped = new LinkedHashMap<>();
            skipped.put(modId, "still tracked by workshop item " + owner);
            return new Result(List.of(), skipped, List.of());
        }
        return deleteFolders(backend, null, List.of(modId));
    }

    private static Result deleteFolders(Backend backend, String workshopId,
            List<String> modIds) {
        List<String> deleted = new ArrayList<>();
        Map<String, String> skipped = new LinkedHashMap<>();
        List<String> failed = new ArrayList<>();
        Consumer<String> log = line -> System.out.println("[WorkshopBridge] " + line);
        Map<String, WorkshopMap.Entry> items = backend.workshopMap().snapshot();
        for (String modId : modIds) {
            String reason = checkFolder(backend, items, workshopId, modId);
            if (reason != null) {
                log.accept("Not deleting " + modId + ": " + reason);
                skipped.put(modId, reason);
                continue;
            }
            File dir = new File(gameModDir(backend, modId));
            log.accept("Deleting mod folder " + dir.getName() + " (" + modId + ")");
            ModInstaller.deleteRecursiveQuiet(dir.toPath(), log);
            if (dir.exists()) {
                log.accept("Could not remove " + modId + ": folder still there");
                failed.add(modId);
                continue;
            }
            deleted.add(modId);
        }
        return new Result(deleted, skipped, failed);
    }

    /**
     * The guards. Returns null when the folder may be deleted, otherwise the
     * human-readable reason to skip it.
     */
    static String checkFolder(Backend backend, Map<String, WorkshopMap.Entry> items,
            String workshopId, String modId) {
        if (modId == null || modId.isEmpty()) {
            return "blank mod id";
        }
        String dir = gameModDir(backend, modId);
        if (dir == null) {
            return "mod folder not found";
        }
        File folder = new File(dir);
        try {
            String modsRoot = backend.modsDir().getCanonicalPath();
            String target = folder.getCanonicalPath();
            if (!target.startsWith(modsRoot + File.separator)) {
                return "folder is outside the mods directory";
            }
        } catch (Exception e) {
            return "could not resolve folder path (" + e.getMessage() + ")";
        }
        if (!modId.equals(ModInstaller.readModId(folder))) {
            return "folder's mod.info does not declare this id";
        }
        for (Map.Entry<String, WorkshopMap.Entry> e : items.entrySet()) {
            if (!e.getKey().equals(workshopId)
                    && e.getValue().modIds.contains(modId)) {
                return "still tracked by workshop item " + e.getKey();
            }
        }
        return null;
    }

    /** The folder the game resolves for a mod id, or null. Never throws. */
    private static String gameModDir(Backend backend, String modId) {
        try {
            return zombie.ZomboidFileSystem.instance.getModDir(modId);
        } catch (Throwable t) {
            return null;
        }
    }
}
