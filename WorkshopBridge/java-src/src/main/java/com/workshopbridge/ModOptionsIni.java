package com.workshopbridge;

import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

/**
 * Reads vanilla mod-option tickboxes from the game's ModOptions.ini
 * ({@code <Zomboid>/Lua/ModOptions.ini}, written by PZAPI.ModOptions when
 * the player applies Options > Mods). Lets the Java side honor our mod
 * options without Lua having to push values over.
 *
 * Vanilla format, one per line:
 * {@code tickbox|<modId>|<optionId>|true}
 * (the writer uses CRLF; values are trimmed).
 *
 * A missing file, a missing option, or an unreadable value degrades to
 * the caller's default, matching the Lua getters' behavior when the
 * options API is absent. Read live on every call (the file is tiny): a
 * change applied in the options screen takes effect immediately, with no
 * restart and no cache-invalidation bugs.
 */
final class ModOptionsIni {
    private ModOptionsIni() {}

    static boolean getTick(File zomboidDir, String modId, String optionId, boolean def) {
        File f = new File(new File(zomboidDir, "Lua"), "ModOptions.ini");
        if (!f.isFile()) {
            return def;
        }
        String key = modId + "|" + optionId;
        Boolean found = null;
        try (BufferedReader br = Files.newBufferedReader(f.toPath(), StandardCharsets.UTF_8)) {
            String line;
            while ((line = br.readLine()) != null) {
                String[] t = line.split("\\|", -1);
                if (t.length != 4 || !"tickbox".equals(t[0])) {
                    continue;
                }
                if (!key.equals(t[1] + "|" + t[2])) {
                    continue;
                }
                String v = t[3].trim();
                if ("true".equals(v)) {
                    found = true; // last one wins, like the vanilla loader
                } else if ("false".equals(v)) {
                    found = false;
                }
            }
        } catch (IOException ignored) {
            // degrade to default
        }
        return found == null ? def : found;
    }
}
