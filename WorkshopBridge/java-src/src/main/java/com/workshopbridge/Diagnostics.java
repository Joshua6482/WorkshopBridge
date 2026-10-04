package com.workshopbridge;

/**
 * Diagnostic probes that are useful during development but have no place in a
 * release build. Excluded from release jars with
 * {@code gradle -Pdiagnostics=false ...}; {@code Main.main} invokes
 * {@link #run()} reflectively so the main sources compile with or without
 * this file.
 */
public final class Diagnostics {
    private Diagnostics() {
    }

    public static void run() {
        probeNativeDialogs();
    }

    /**
     * Logs which native file-dialog backends are on the classpath, for future
     * reference (a "More tools" panel with import/export was considered; the
     * in-game approach won, but this settles whether LWJGL's tinyfd/NFD
     * modules ship with the game). Pure probe: never throws, never
     * initializes anything.
     */
    static void probeNativeDialogs() {
        boolean tinyfd = false;
        boolean nfd = false;
        try {
            Class.forName("org.lwjgl.util.tinyfd.TinyFileDialogs");
            tinyfd = true;
        } catch (Throwable ignored) {
        }
        try {
            Class.forName("org.lwjgl.util.nfd.NativeFileDialog");
            nfd = true;
        } catch (Throwable ignored) {
        }
        System.out.println("[WorkshopBridge] native dialog backends: tinyfd=" + tinyfd
                + " nfd=" + nfd);
    }
}
