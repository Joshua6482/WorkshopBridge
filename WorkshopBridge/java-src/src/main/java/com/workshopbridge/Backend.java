package com.workshopbridge;

import java.io.File;

/**
 * Singleton holder for the backend services. Initialized lazily on the first
 * Lua call (which happens in the menu, long after ZomboidFileSystem is ready).
 */
public final class Backend {
    private static volatile Backend instance;

    public static Backend get() {
        Backend b = instance;
        if (b == null) {
            synchronized (Backend.class) {
                b = instance;
                if (b == null) {
                    instance = b = new Backend();
                }
            }
        }
        return b;
    }

    private final File zomboidDir;
    private final File modsDir;
    private final File cacheDir;
    private final WorkshopMap workshopMap;
    private final SteamCmd steamCmd;
    private final JobManager jobs;

    private Backend() {
        this.zomboidDir = resolveZomboidDir();
        this.modsDir = new File(zomboidDir, "mods");
        this.cacheDir = new File(zomboidDir, "workshop_cache");
        this.workshopMap = new WorkshopMap(new File(zomboidDir, "workshopbridge_map.json"));
        try {
            this.workshopMap.load();
        } catch (Exception e) {
            System.out.println("[WorkshopBridge] map load failed: " + e);
        }
        this.steamCmd = new SteamCmd(zomboidDir);
        this.jobs = new JobManager(this);
        System.out.println("[WorkshopBridge] backend ready (zomboidDir=" + zomboidDir + ")");
    }

    private static File resolveZomboidDir() {
        try {
            String dir = zombie.ZomboidFileSystem.instance.getCacheDir();
            if (dir != null && !dir.isEmpty()) {
                return new File(dir);
            }
        } catch (Throwable t) {
            System.out.println("[WorkshopBridge] ZomboidFileSystem unavailable, using fallback: " + t);
        }
        return new File(System.getProperty("user.home"), "Zomboid");
    }

    public File zomboidDir() {
        return zomboidDir;
    }

    public File modsDir() {
        return modsDir;
    }

    public File cacheDir() {
        return cacheDir;
    }

    public WorkshopMap workshopMap() {
        return workshopMap;
    }

    /**
     * Writes the given workshop ids as one Steam Workshop URL per line to a
     * timestamped file under {@code <Zomboid>/workshopbridge-exports/}.
     * The path is fixed (no file picker): the user is told exactly where it
     * landed. Returns the exported file's absolute path.
     */
    public String exportModList(java.util.List<String> workshopIds) throws java.io.IOException {
        File dir = new File(zomboidDir, "workshopbridge-exports");
        if (!dir.isDirectory() && !dir.mkdirs()) {
            throw new java.io.IOException("cannot create export dir: " + dir);
        }
        // millisecond stamp plus CREATE_NEW with a numeric fallback: two
        // exports in the same second must not overwrite each other.
        String stamp = java.time.format.DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss-SSS")
                .withZone(java.time.ZoneId.systemDefault())
                .format(java.time.Instant.now());
        java.nio.file.Path out = uniquePath(dir.toPath(), "modlist-" + stamp, ".txt");
        StringBuilder sb = new StringBuilder();
        for (String wsid : workshopIds) {
            sb.append("https://steamcommunity.com/sharedfiles/filedetails/?id=")
                    .append(wsid).append('\n');
        }
        java.nio.file.Files.writeString(out, sb.toString(),
                java.nio.charset.StandardCharsets.UTF_8,
                java.nio.file.StandardOpenOption.CREATE_NEW);
        return out.toFile().getAbsolutePath();
    }

    private static java.nio.file.Path uniquePath(java.nio.file.Path dir, String base, String ext)
            throws java.io.IOException {
        java.nio.file.Path candidate = dir.resolve(base + ext);
        for (int n = 2; java.nio.file.Files.exists(candidate) && n < 1000; n++) {
            candidate = dir.resolve(base + "-" + n + ext);
        }
        if (java.nio.file.Files.exists(candidate)) {
            throw new java.io.IOException("cannot find a free export name in " + dir);
        }
        return candidate;
    }

    /**
     * PZ mod id -> workshop id, with some self-healing.
     * The map is the ground truth; only when it misses do we look at the
     * mod folder itself: first the folder-name repair below, then the
     * mod's sidecar stamp (a mod archived to disk and moved back re-links
     * from the stamp and is merged into the map).
     */
    public synchronized String getWorkshopId(String modId) {
        String wsid = workshopMap.getWorkshopId(modId);
        if (wsid != null || modId == null || modId.isEmpty()) {
            return wsid;
        }
        File[] dirs = modsDir.listFiles(File::isDirectory);
        if (dirs == null) {
            return null;
        }
        for (File dir : dirs) {
            if (!modId.equals(ModInstaller.readModId(dir))) {
                continue;
            }
            String byFolder = workshopMap.getWorkshopId(dir.getName());
            if (byFolder != null) {
                workshopMap.replaceModId(byFolder, dir.getName(), modId);
                System.out.println("[WorkshopBridge] repaired map entry for "
                        + modId + " (was recorded as folder \"" + dir.getName() + "\")");
                return byFolder;
            }
            ModSidecar sidecar = ModSidecar.read(dir);
            if (sidecar != null) {
                workshopMap.mergeSidecar(sidecar.workshopId, sidecar.modId,
                        sidecar.timeUpdated, sidecar.lastDownloaded);
                System.out.println("[WorkshopBridge] re-linked " + modId
                        + " to workshop item " + sidecar.workshopId + " (sidecar stamp)");
                return sidecar.workshopId;
            }
        }
        return null;
    }

    public SteamCmd steamCmd() {
        return steamCmd;
    }

    public JobManager jobs() {
        return jobs;
    }
}
