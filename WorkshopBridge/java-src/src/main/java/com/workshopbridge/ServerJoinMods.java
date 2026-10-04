package com.workshopbridge;

import java.lang.reflect.Field;
import java.nio.BufferUnderflowException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * Reads the server's mod list from a failed join's connection details.
 *
 * When joining a server with missing mods, the game (non-Steam mode) skips
 * its workshop states entirely and goes straight to CheckMods, which fires
 * {@code OnConnectFailed} with "... [ModID: x, WorkshopID: y]" for the FIRST
 * missing mod and then disconnects. The server's FULL mod list (mod id,
 * workshop id, display name per mod) is sitting in the
 * {@code ConnectToServerState.connectionDetails} packet, so we re-read it
 * and offer to download every missing mod in one go instead of making the
 * user rejoin once per missing mod.
 *
 * This runs synchronously inside the Lua OnConnectFailed handler, which the
 * game fires on its own thread from CheckMods: {@code
 * ConnectToServerState.instance} is still set (it is cleared in
 * {@code exit()}, on a later tick) and nobody else touches the packet
 * concurrently, so duplicating the buffer is race-free.
 *
 * The packet layout mirrors {@code ConnectionDetails.write} (server side)
 * followed by the client's sequential reads in {@code ConnectToServerState}:
 * Start section, TestTCP section, then EITHER the workshop-item section
 * (only when the SERVER runs in Steam mode) or directly the mod section.
 * The two trailing fixed ints of writeStartLocation (10745, 9412, 0) act as
 * a magic anchor: we try the workshop-section interpretation first and
 * accept whichever one lands on the anchor. Any mismatch (a future game
 * version changing the layout, truncated data) yields null and the caller
 * falls back to the single mod named in the failure message. Nothing here
 * may ever throw out to the game.
 */
public final class ServerJoinMods {
    private ServerJoinMods() {}

    /** One server mod, with whether it is already installed locally. */
    public static final class Mod {
        public final String id;
        public final String workshopId;
        public final String name;
        public final boolean installed;
        Mod(String id, String workshopId, String name, boolean installed) {
            this.id = id;
            this.workshopId = workshopId;
            this.name = name;
            this.installed = installed;
        }
    }

    /** Outcome of the read. {@code steamMode} means the vanilla workshop
     * flow owns server mods (Steam client); the caller should stay out. */
    public static final class Result {
        public final boolean steamMode;
        public final List<Mod> mods;
        Result(boolean steamMode, List<Mod> mods) {
            this.steamMode = steamMode;
            this.mods = mods;
        }
    }

    /**
     * Reads the server mod list from the in-progress/just-failed join.
     * Returns null when there is no join to read from or the packet could
     * not be parsed; never throws.
     */
    public static Result read() {
        try {
            if (isSteamMode()) {
                return new Result(true, List.of());
            }
            ByteBuffer packet = connectionPacket();
            if (packet == null) {
                return null;
            }
            List<Mod> mods = parse(packet);
            if (mods == null) {
                System.out.println("[WorkshopBridge] could not parse server mod list "
                        + "(game packet layout may have changed)");
                return null;
            }
            return new Result(false, annotateInstalled(mods));
        } catch (Throwable t) {
            System.out.println("[WorkshopBridge] server mod read failed: " + t);
            return null;
        }
    }

    private static boolean isSteamMode() throws Exception {
        Class<?> c = Class.forName("zombie.core.znet.SteamUtils");
        return (Boolean) c.getMethod("isSteamModeEnabled").invoke(null);
    }

    /**
     * Duplicates the connection-details buffer of the current
     * ConnectToServerState, rewound to the start. Null when no join is in
     * progress. Pure reflection so this class loads (and the parser stays
     * unit-testable) without the game on the classpath.
     */
    private static ByteBuffer connectionPacket() throws Exception {
        Class<?> c = Class.forName("zombie.gameStates.ConnectToServerState");
        Object instance = c.getField("instance").get(null);
        if (instance == null) {
            return null;
        }
        Field details = c.getDeclaredField("connectionDetails");
        details.setAccessible(true);
        Object reader = details.get(instance);
        Field bb = reader.getClass().getField("bb");
        ByteBuffer buf = (ByteBuffer) bb.get(reader);
        ByteBuffer dup = buf.duplicate();
        dup.rewind();
        return dup;
    }

    /** Marks every entry installed when the game's own mod lookup knows it,
     * the same definition CheckMods uses (present beats enabled here). */
    static List<Mod> annotateInstalled(List<Mod> mods) {
        List<Mod> out = new ArrayList<>(mods.size());
        for (Mod m : mods) {
            boolean installed = false;
            try {
                installed = zombie.gameStates.ChooseGameInfo
                        .getAvailableModDetails(m.id) != null;
            } catch (Throwable ignored) {
                // a lookup hiccup must not hide the entry
            }
            out.add(new Mod(m.id, m.workshopId, m.name, installed));
        }
        return out;
    }

    /**
     * Parses a rewound connection-details packet. Package-private for tests.
     * Returns null when the layout is not recognized.
     */
    static List<Mod> parse(ByteBuffer bb) {
        try {
            bb.get(); // isCoopHost
            bb.getInt(); // maxPlayers
            if (bb.get() != 0) { // Steam/host info block (rare on this path)
                bb.getLong(); // hostSteamID
                getUTF(bb); // serverName
            }
            bb.get(); // playerId
            // Role.parse
            getUTF(bb); // name
            getUTF(bb); // description
            bb.getFloat();
            bb.getFloat();
            bb.getFloat();
            bb.getFloat(); // color
            bb.getInt(); // position
            int caps = bb.get() & 0xFF;
            for (int i = 0; i < caps; i++) {
                bb.get(); // Capability enum: one byte
            }
            bb.get(); // isReadOnly
            getUTF(bb); // gameMap (TestTCP)
            int modsAt = bb.position();
            // The workshop section exists only when the SERVER is in Steam
            // mode; try it first, then without. The start-location magic
            // ints after the mod list validate the guess.
            List<Mod> mods = tryParseMods(bb, modsAt, true);
            if (mods != null) {
                return mods;
            }
            return tryParseMods(bb, modsAt, false);
        } catch (RuntimeException e) {
            return null; // underflow / bad position: not our layout
        }
    }

    private static List<Mod> tryParseMods(ByteBuffer bb, int pos, boolean withWorkshop) {
        try {
            bb.position(pos);
            if (withWorkshop) {
                int wcount = bb.getShort() & 0xFFFF;
                if (wcount > 100_000) {
                    return null;
                }
                long skip = (long) wcount * 16L; // id + timestamp per item
                if (skip > bb.remaining()) {
                    return null;
                }
                bb.position(bb.position() + (int) skip);
            }
            int n = bb.getInt();
            if (n < 0 || n > 100_000) {
                return null;
            }
            List<Mod> mods = new ArrayList<>(n);
            for (int i = 0; i < n; i++) {
                String id = getUTF(bb);
                String workshopId = getUTF(bb);
                String name = getUTF(bb);
                mods.add(new Mod(id, workshopId, name, false));
            }
            // writeStartLocation's fixed ints: the anchor.
            if (bb.getInt() != 10745 || bb.getInt() != 9412 || bb.getInt() != 0) {
                return null;
            }
            return mods;
        } catch (RuntimeException e) {
            return null;
        }
    }

    /** Mirrors ByteBufferReader.getUTF: short length + UTF-8 bytes. */
    private static String getUTF(ByteBuffer bb) {
        int len = bb.getShort() & 0xFFFF;
        if (len > bb.remaining()) {
            throw new BufferUnderflowException();
        }
        byte[] bytes = new byte[len];
        bb.get(bytes);
        return new String(bytes, StandardCharsets.UTF_8);
    }
}
