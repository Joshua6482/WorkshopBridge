package com.workshopbridge;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Per-mod provenance stamp: a small JSON file ({@code workshopbridge.json})
 * written into the root of every mod folder WorkshopBridge installs.
 *
 * The central map stays the ground truth, but a mod that left the mods
 * folder (archived to disk, moved by hand) and comes back can re-link
 * itself to its workshop item from this stamp, without the map having
 * survived the trip. Deleting the file unlinks the mod: it will no longer
 * re-link on its own (the Adopt button still works).
 *
 * The stamp is a claim, not proof: re-linking only re-records the
 * workshopID -> modID mapping. Any overwrite still goes through the normal
 * download path, which verifies the workshop item's contents first.
 */
final class ModSidecar {
    static final String FILE_NAME = "workshopbridge.json";

    final String workshopId;
    final String modId;
    final long timeUpdated;
    final long lastDownloaded;

    private ModSidecar(String workshopId, String modId, long timeUpdated, long lastDownloaded) {
        this.workshopId = workshopId;
        this.modId = modId;
        this.timeUpdated = timeUpdated;
        this.lastDownloaded = lastDownloaded;
    }

    /**
     * Writes the stamp into {@code modDir}. Called as part of the atomic
     * install swap, so a live mod folder always carries a current stamp.
     * {@code timeUpdated} is the workshop item's timestamp from the Steam
     * API (or the best-effort fallback the caller used).
     */
    static void write(File modDir, String workshopId, String modId, long timeUpdated)
            throws IOException {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("v", 1);
        m.put("workshopId", workshopId);
        m.put("modId", modId);
        m.put("timeUpdated", timeUpdated);
        m.put("lastDownloaded", System.currentTimeMillis() / 1000L);
        Files.writeString(new File(modDir, FILE_NAME).toPath(),
                Json.stringify(m), StandardCharsets.UTF_8);
    }

    /**
     * Reads and validates the stamp in {@code modDir}. Returns null when
     * the file is absent, unparseable, or no longer describes this folder:
     * the stamped mod id must still match the folder's current mod.info
     * id=, so a copy the user turned into a different mod does not
     * re-link to the old workshop item. Never throws.
     */
    static ModSidecar read(File modDir) {
        File f = new File(modDir, FILE_NAME);
        if (!f.isFile()) {
            return null;
        }
        try {
            String json = Files.readString(f.toPath(), StandardCharsets.UTF_8);
            Map<String, Object> m = Json.object(Json.parse(json));
            if (m == null) {
                return null;
            }
            Object v = m.get("v");
            if (!(v instanceof Number) || ((Number) v).longValue() != 1) {
                return null;
            }
            String wsid = str(m.get("workshopId"));
            String mid = str(m.get("modId"));
            if (wsid == null || !wsid.matches("\\d+") || mid == null || mid.isEmpty()) {
                return null;
            }
            if (!mid.equals(ModInstaller.readModId(modDir))) {
                return null;
            }
            return new ModSidecar(wsid, mid, num(m.get("timeUpdated")), num(m.get("lastDownloaded")));
        } catch (Exception e) {
            return null;
        }
    }

    private static String str(Object o) {
        return o instanceof String ? (String) o : null;
    }

    private static long num(Object o) {
        return o instanceof Number ? ((Number) o).longValue() : 0L;
    }
}
