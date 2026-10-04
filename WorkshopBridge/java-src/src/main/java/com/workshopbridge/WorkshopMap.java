package com.workshopbridge;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Persists the workshopID -> { modIds, timeUpdated, lastDownloaded } mapping
 * as JSON. Owned and written only by the Java side.
 *
 * File: <Zomboid>/workshopbridge_map.json
 *   {"version":1,"items":{"12345":{"modIds":["ModA"],"timeUpdated":1727...,"lastDownloaded":1727...}}}
 */
public final class WorkshopMap {
    public static final class Entry {
        public final List<String> modIds;
        public final long timeUpdated;
        public final long lastDownloaded;

        public Entry(List<String> modIds, long timeUpdated, long lastDownloaded) {
            this.modIds = Collections.unmodifiableList(new ArrayList<>(modIds));
            this.timeUpdated = timeUpdated;
            this.lastDownloaded = lastDownloaded;
        }
    }

    private final File file;
    private final Map<String, Entry> items = new LinkedHashMap<>();

    public WorkshopMap(File file) {
        this.file = file;
    }

    /** workshopId -> Entry snapshot (safe to iterate off-thread). */
    public synchronized Map<String, Entry> snapshot() {
        return new LinkedHashMap<>(items);
    }

    /** Reverse lookup: PZ mod id -> workshop id, or null when unknown. */
    public synchronized String getWorkshopId(String modId) {
        for (Map.Entry<String, Entry> e : items.entrySet()) {
            if (e.getValue().modIds.contains(modId)) {
                return e.getKey();
            }
        }
        return null;
    }

    /**
     * Repairs a stale recorded mod id (e.g. change in broken parse logic, 
     * folder renamed, etc).
     * No-op when the entry or old id is absent.
     */
    public synchronized void replaceModId(String workshopId, String oldModId, String newModId) {
        Entry e = items.get(workshopId);
        if (e == null || oldModId == null || newModId == null
                || oldModId.equals(newModId)) {
            return;
        }
        List<String> ids = new ArrayList<>(e.modIds);
        boolean changed = false;
        for (int i = 0; i < ids.size(); i++) {
            if (ids.get(i).equals(oldModId) && !ids.contains(newModId)) {
                ids.set(i, newModId);
                changed = true;
            }
        }
        if (changed) {
            items.put(workshopId, new Entry(ids, e.timeUpdated, e.lastDownloaded));
            save();
        }
    }

    public synchronized void record(String workshopId, List<String> modIds, long timeUpdated) {
        items.put(workshopId,
                new Entry(modIds, timeUpdated, System.currentTimeMillis() / 1000L));
        save();
    }

    /**
     * Re-links a mod from its {@link ModSidecar} stamp: adds the mod id to
     * the entry, creating the entry from the stamp's timestamps when the
     * workshop id is absent. An existing entry keeps its own timestamps
     * (they may be newer than the stamp's). No-op when the mod id is
     * already recorded. Atomic save, like every other mutation.
     */
    public synchronized void mergeSidecar(String workshopId, String modId,
            long timeUpdated, long lastDownloaded) {
        Entry e = items.get(workshopId);
        if (e == null) {
            List<String> ids = new ArrayList<>();
            ids.add(modId);
            items.put(workshopId, new Entry(ids, timeUpdated, lastDownloaded));
        } else if (!e.modIds.contains(modId)) {
            List<String> ids = new ArrayList<>(e.modIds);
            ids.add(modId);
            items.put(workshopId, new Entry(ids, e.timeUpdated, e.lastDownloaded));
        } else {
            return;
        }
        save();
    }

    /**
     * Drops mod ids from an entry (their folders were deleted by hand);
     * drops the whole entry when no mod ids remain. Timestamps of a
     * surviving entry are kept. No-op when the entry or ids are absent.
     * Atomic save, like every other mutation.
     */
    public synchronized void removeModIds(String workshopId, java.util.Collection<String> modIds) {
        Entry e = items.get(workshopId);
        if (e == null || modIds == null || modIds.isEmpty()) {
            return;
        }
        List<String> kept = new ArrayList<>(e.modIds);
        if (!kept.removeAll(modIds)) {
            return;
        }
        if (kept.isEmpty()) {
            items.remove(workshopId);
        } else {
            items.put(workshopId, new Entry(kept, e.timeUpdated, e.lastDownloaded));
        }
        save();
    }

    /**
     * Drops a workshop entry (mod deletion). No-op when absent.
     * Atomic save, like every other mutation.
     */
    public synchronized void remove(String workshopId) {
        if (items.remove(workshopId) != null) {
            save();
        }
    }

    public synchronized void load() {
        items.clear();
        if (!file.isFile()) {
            return;
        }
        try {
            String json = Files.readString(file.toPath(), StandardCharsets.UTF_8);
            Object root = Json.parse(json);
            Map<String, Object> obj = Json.object(root);
            Object itemsObj = obj == null ? null : obj.get("items");
            Map<String, Object> itemsMap = Json.object(itemsObj);
            if (itemsMap == null) {
                return;
            }
            for (Map.Entry<String, Object> e : itemsMap.entrySet()) {
                Map<String, Object> m = Json.object(e.getValue());
                if (m == null) {
                    continue;
                }
                List<String> modIds = new ArrayList<>();
                List<Object> ids = Json.array(m.get("modIds"));
                if (ids != null) {
                    for (Object id : ids) {
                        modIds.add(String.valueOf(id));
                    }
                }
                long timeUpdated = num(m.get("timeUpdated"));
                long lastDownloaded = num(m.get("lastDownloaded"));
                items.put(e.getKey(), new Entry(modIds, timeUpdated, lastDownloaded));
            }
            System.out.println("[WorkshopBridge] loaded map: " + items.size() + " workshop items");
        } catch (Exception ex) {
            System.out.println("[WorkshopBridge] map load failed (" + file + "): " + ex);
        }
    }

    private synchronized void save() {
        try {
            Map<String, Object> itemsMap = new LinkedHashMap<>();
            for (Map.Entry<String, Entry> e : items.entrySet()) {
                Map<String, Object> m = new LinkedHashMap<>();
                m.put("modIds", new ArrayList<>(e.getValue().modIds));
                m.put("timeUpdated", e.getValue().timeUpdated);
                m.put("lastDownloaded", e.getValue().lastDownloaded);
                itemsMap.put(e.getKey(), m);
            }
            Map<String, Object> root = new LinkedHashMap<>();
            root.put("version", 1);
            root.put("items", itemsMap);
            String json = Json.stringify(root);
            // atomic
            Path target = file.toPath();
            Path tmp = target.resolveSibling(file.getName() + ".tmp");
            Path parent = target.getParent();
            if (parent != null) {
                Files.createDirectories(parent);
            }
            Files.writeString(tmp, json, StandardCharsets.UTF_8);
            try {
                Files.move(tmp, target,
                        StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            } catch (AtomicMoveNotSupportedException e) {
                Files.move(tmp, target, StandardCopyOption.REPLACE_EXISTING);
            }
        } catch (Exception ex) {
            System.out.println("[WorkshopBridge] map save failed: " + ex);
        }
    }

    private static long num(Object o) {
        return o instanceof Number ? ((Number) o).longValue() : 0L;
    }
}
