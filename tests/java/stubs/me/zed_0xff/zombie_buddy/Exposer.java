package me.zed_0xff.zombie_buddy;
// Test stub mirroring the ZombieBuddy surface Main.main touches: the
// package-private global-method registration (called reflectively).
public class Exposer {
    /** Test hook: set when addClassWithGlobalLuaMethod is called. */
    public static boolean addCalled = false;
    /** Test hook: the class it was called with. */
    public static Class<?> addedClass = null;

    static void addClassWithGlobalLuaMethod(Class<?> cls) {
        addCalled = true;
        addedClass = cls;
    }
}
