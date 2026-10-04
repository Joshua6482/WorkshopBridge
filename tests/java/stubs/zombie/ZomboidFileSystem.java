package zombie;
// Test stub: getCacheDir() honors wb.test.zomboid. There is deliberately NO
// fallback to the real ~/Zomboid: tests must never touch the user's actual
// game folder, even if someone runs the harness without the property set
// (WBTest refuses to run in that case).
public class ZomboidFileSystem {
    public static final ZomboidFileSystem instance = new ZomboidFileSystem();
    /** Test hook: set when resetModFolders() is called. */
    public static boolean resetModFoldersCalled = false;
    public String getCacheDir() {
        String d = System.getProperty("wb.test.zomboid");
        if (d == null || d.isEmpty()) {
            throw new IllegalStateException(
                    "wb.test.zomboid not set - run the tests via tests/java/run.sh");
        }
        return d;
    }
    /** Mirrors the real method: drops the cached mod folder scan. */
    public void resetModFolders() {
        resetModFoldersCalled = true;
    }
    /** Test hook: mod id -> mod folder, backing getModDir. */
    public static final java.util.Map<String, String> modIdToDir = new java.util.HashMap<>();
    /** Mirrors the real instance cache: mod dir -> parsed Mod object.
     * wbInvalidateModCaches clears it (like the game's own update()). */
    public final java.util.Map<String, Object> modDirToMod = new java.util.HashMap<>();
    /** Mirrors the real lookup: the folder the game resolves for a mod id. */
    public String getModDir(String modId) {
        return modIdToDir.get(modId);
    }
    /**
     * Test port of the game's version-dir picker (ZomboidFileSystem.
     * getModVersionDirName): highest version-like dir at or below the game
     * version, floored at the min required version 42.0. Game version comes
     * from the wb.test.gameVersion property (default 42.1.0). Same
     * major*1000+minor scheme as the game's getGameVersionIntFromName:
     * "42" -> 42000, "42.1"/"42.1.0" -> 42001, non-numeric names -> 0.
     */
    public String getModVersionDirName(java.nio.file.Path modDir) {
        int gameVersion = versionInt(System.getProperty("wb.test.gameVersion", "42.1.0"));
        String best = "42.0";
        int bestV = 42000;
        String[] names = modDir.toFile().list();
        if (names != null) {
            java.util.Arrays.sort(names); // determinism; the game uses fs order
            for (String name : names) {
                int v = versionInt(name);
                if (v >= bestV && v <= gameVersion) {
                    best = name;
                    bestV = v;
                }
            }
        }
        return best;
    }
    private static int versionInt(String name) {
        if (name == null) {
            return 0;
        }
        String[] parts = name.split("\\.");
        if (parts.length == 1) {
            return tryParse(parts[0]) * 1000;
        }
        return tryParse(parts[0]) * 1000 + Math.min(tryParse(parts[1]), 999);
    }
    private static int tryParse(String s) {
        try {
            return Integer.parseInt(s);
        } catch (NumberFormatException e) {
            return 0;
        }
    }
}
