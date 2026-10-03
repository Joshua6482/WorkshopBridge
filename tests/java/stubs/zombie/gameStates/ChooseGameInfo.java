package zombie.gameStates;
// Test stub mirroring the real game's cache-clearing entry point.
public class ChooseGameInfo {
    /** Test hook: set when Reset() is called. */
    public static boolean resetCalled = false;

    /** Mirrors the real method: clears the cached mod/map infos. */
    public static void Reset() {
        resetCalled = true;
    }
}
