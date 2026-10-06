# WorkshopBridge Windows Test Pack

DRAFT, uncommitted. Covers the PLAN.md validation item: steamcmd.exe
bootstrap, paths with spaces, fresh-profile first run, and a normal play
session on Windows, plus the features still awaiting in-game verification.

Part A is for joshua (prep). Part B is the verbatim guide to send the tester.
Part C lists the risks we are specifically watching for.

## Part A - prep (joshua)

1. **Build a fresh release zip.** The tree currently has no built jar, so run
   `./release.sh` at the repo root. It compiles with diagnostics off,
   ZBS-signs, stamps the version into mod.info, and zips to `dist/`. Build
   from current HEAD so the zip includes the latest Java fixes: sidecar stamp
   + map reconcile, red-X cache clear, single-flight steamcmd bootstrap,
   `.install-staging` atomic installs.
2. **Confirm the tester is on the GOG version of Project Zomboid.** If they
   are on Steam, stop: WorkshopBridge exists for non-Steam players and there
   is nothing useful for a Steam user to test.
3. **Send the tester:** the release zip from step 1, Part B of this doc, and
   the two ZombieBuddy links below.
4. **ZombieBuddy files - use the GitHub releases, not the installer.**
   ZombieBuddy's automated Windows installer is Steam-oriented (it detects the
   Steam install and pulls ZombieBuddy from a Workshop subscription) and
   v4.2 predates the Build 42.21 fix, so it is wrong for a GOG tester twice
   over. Note: ZombieBuddy's Steam Workshop item (3619862853) is currently
   hidden (its page returns an error), so the Workshop/installer route is
   broken for everyone right now and the GitHub releases below are the only
   working source. Manual install from these instead:
   - `ZombieBuddy.jar` from **v2.3.4** (released 2026-10-03, "backport fix for
     #56"): https://github.com/zed-0xff/ZombieBuddy/releases/download/v2.3.4/ZombieBuddy.jar
   - `zbNative.dll` from **v2.3.3**:
     https://github.com/zed-0xff/ZombieBuddy/releases/download/v2.3.3/zbNative.dll
   v2.3.4 contains the fix for game build 42.21 (`ZomboidFileSystem.loadMods`
   changed its parameter from `ArrayList` to `List`; without the fix no Java
   mod loads at all on 42.21). The fix is backwards compatible, so v2.3.4
   works on 42.20 too. Either way, ask the tester which game build they are
   on and write it in the report.
5. When the report comes back, file anything it surfaces and sync PLAN.md.

## Part B - tester guide (send verbatim)

You are testing WorkshopBridge, a mod that lets the GOG version of Project
Zomboid download Steam Workshop mods from inside the game. Follow the steps
in order. If a step says "expect", that is what should happen; if anything
else happens, copy the exact message text into your report (Part B, step 5).

### Step 0 - check your game version

This test is only for the **GOG version** of Project Zomboid, Build 42. If
you bought the game on Steam, stop here and tell joshua: there is nothing
for you to test. Your game build number is shown at the bottom of the main
menu; write it down for the report.

### Step 1 - install ZombieBuddy

ZombieBuddy is the framework WorkshopBridge runs on. The automated installer
only works for Steam, so do it manually:

1. Download these two files:
   - https://github.com/zed-0xff/ZombieBuddy/releases/download/v2.3.4/ZombieBuddy.jar
   - https://github.com/zed-0xff/ZombieBuddy/releases/download/v2.3.3/zbNative.dll
2. Copy **both** files into your Project Zomboid game folder (where GOG
   installed it, e.g. `C:\GOG Games\Project Zomboid`).
3. In that same folder, open `ProjectZomboid64.bat` in Notepad. Find the line
   that starts with `SET _JAVA_OPTIONS=` and add
   `-agentlib:zbNative -Dzomboid.steam=0` inside the quotes, keeping whatever
   is already there. Save.
4. Launch the game by double-clicking `ProjectZomboid64.bat`. While it loads,
   look at the top-left corner: you should see "ZombieBuddy v2.3.4 loaded".
   If you do not see it, stop and tell joshua exactly what you did see.

### Step 2 - install WorkshopBridge

1. Unzip the release zip joshua sent you. Inside is a folder called
   `WorkshopBridge`.
2. Press Win+R, paste `%USERPROFILE%\Zomboid\mods`, press Enter. Copy the
   `WorkshopBridge` folder in there, so you have
   `%USERPROFILE%\Zomboid\mods\WorkshopBridge`.
3. Launch the game, open the Mods menu, and enable **both** ZombieBuddy and
   WorkshopBridge.
4. A ZombieBuddy dialog will pop up asking to approve `WorkshopBridge.jar`.
   Click **Yes**, and choose to remember the decision (persist it).

### Step 3 - playtest

Do these in order. "Expect" is what should happen.

1. **Mod menu check.** Open the Mods menu. Expect: WorkshopBridge buttons
   are visible ("Check for updates", "Download", per-mod "Update").
2. **Download a mod (this also bootstraps steamcmd).** Click Download, enter
   workshop ID `3487511907`, and confirm. Expect: the first run downloads
   steamcmd itself from Valve, which takes a few minutes; a progress panel
   shows it working. Then the mod installs and appears in your mod list.
   If Windows Defender quarantines `steamcmd.exe`: open Windows Security >
   Protection history, restore/allow the file (or allow-list the
   `%USERPROFILE%\Zomboid\workshop_cache\steamcmd` folder). A downloaded exe
   can also carry a "blocked" mark: right-click it > Properties > check
   **Unblock** > OK, then retry.
3. **Dependency prompt.** Click Download, enter workshop ID `3799732653`.
   Expect: after the download, a "Required Workshop items" dialog appears
   naming workshop item `3171167894`. Click **Install all**. Expect both
   mods to end up installed.
4. **Update check.** Click "Check for updates" with the downloaded mods
   installed. Expect: it finishes with no errors.
5. **Bad ID.** Click Download, enter workshop ID `1` (a bogus ID). Expect:
   a friendly error message, no crash, no freeze.
6. **Delete.** Find mod `3487511907` in the list and click its **Delete**
   button. Expect: a confirmation dialog naming the mod; after confirming,
   the mod disappears from the list.
7. **Play.** Enable the downloaded mods, start a new game, and play for
   about 10 minutes. Expect: no errors, no crashes.
8. **Paths with spaces.** If your Windows username contains a space, you
   have already covered this in every step above; just say so in the report.
   If not, skip.

Optional, only if easy:
- Per-mod **Open in Workshop** button: expect it to open the mod's Steam
  Workshop page in your browser.
- Skip the collection import button (experimental, off by default) and the
  server-join download offer (needs a modded server) unless you have one
  handy.

### Step 4 - report back

Copy this into your reply and fill it in:

- Windows version:
- Windows username contains a space: yes / no
- PZ build (bottom of main menu) and GOG confirmed: yes / no
- "ZombieBuddy vX.Y.Z loaded" text seen: yes / no (which version?)
- Step 1 (mod menu buttons): pass / fail
- Step 2 (download 3487511907): pass / fail; steamcmd download took about
  __ minutes; Defender flagged anything: yes / no
- Step 3 (dependency prompt for 3171167894): pass / fail
- Step 4 (update check): pass / fail
- Step 5 (bad ID): pass / fail
- Step 6 (delete): pass / fail
- Step 7 (play session): minutes played __; issues:
- Optional steps tried:
- Exact text of any error message you saw (copy it word for word):
- If something crashed: attach `%USERPROFILE%\Zomboid\console.txt` if the
  file exists.

## Part C - risks we are watching (joshua)

- **steamcmd.exe bootstrap on Windows:** Defender/SmartScreen quarantine,
  the "blocked" mark on the downloaded exe, allow-listing the
  `workshop_cache\steamcmd` folder. INSTALL.md documents the mitigations;
  the test should confirm they are sufficient and worded right.
- **Paths with spaces** in `%USERPROFILE%`: Java side quotes/escapes when
  launching steamcmd; untested on Windows so far.
- **260-char path limit** on deeply nested mod folders (INSTALL.md notes the
  registry fix; the mod's error message should point at it when likely).
- **ZombieBuddy install path for GOG is manual**: the installer is
  Steam-only and its bundled jar predates the 42.21 fix. If the tester
  struggles with the .bat edit, that is itself a finding: the GOG story may
  need a script or clearer docs.
- **First-run bootstrap slowness vs. stuck:** the progress panel should make
  it obvious the mod is working; the sticky error panel should appear on
  real failures (not a 2.5s flash).
- The Linux-only `posix_spawn`/FORK saga does not apply on Windows
  (`java.lang.Process` uses CreateProcess there); if a tester hits a process
  launch failure, it is a new bug, not the known one.
