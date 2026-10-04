package zombie.gameStates;
// Test stub mirroring the real game's cache-clearing entry point.
public class ChooseGameInfo {
    /** Test hook: set when Reset() is called. */
    public static boolean resetCalled = false;

    /** Mirrors the real method: clears the cached mod/map infos. */
    public static void Reset() {
        resetCalled = true;
    }

    /** Test hook: mod ids the stub reports as installed. */
    public static final java.util.Set<String> availableModIds = new java.util.HashSet<>();

    /** Mirrors the real lookup: non-null when the mod is installed. */
    public static Object getAvailableModDetails(String modId) {
        return availableModIds.contains(modId) ? new Object() : null;
    }
}
