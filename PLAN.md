# WorkshopBridge build plan

Staged plan agreed with joshua. Each phase ends with a review checkpoint - we don't start the next phase until the previous one is signed off.

## Phase 0 - Validation (done)

- [x] Pure-Lua `steamcmd` execution is impossible (Kahlua has no `os.execute`/`io`, Java interop is whitelist-only, no sockets, sandboxed file I/O). See `docs/RESEARCH.md`.
- [x] ZombieBuddy validated as the Java→Lua bridge (B42-only, `@Exposer.LuaClass` / `@LuaMethod(global=true)`).
- [x] steamcmd anonymous workshop downloads work for PZ app ID 108600; install paths and mod-folder layout confirmed.
- [x] Prior art reviewed: `zomboid-mod-downloader`, `pz_launcher`, `pzmm`.

## Phase 1 - Skeleton + joint review (done)

- [x] Repo structure, docs, Lua stubs, Java stubs. Reviewed in parallel with Phase 2 kickoff.
- [x] Open items from research resolved via game decompile (see `docs/RESEARCH.md` §7).

## Phase 2 - Lua UI (done, verified in-game Oct 2026)

- B42 mod layout confirmed against a real B42 ZombieBuddy mod: `common/mod.info` (`require=ZombieBuddy`, no backslash), `42/media/java/WorkshopBridge.jar`, `42/media/lua/...`.
- In-game verification (42.20.4, debug stub): mod loads with no Lua errors, Check/Update-all buttons render bottom-right, per-mod Update button + three-state status label work, clicking Update flips the label to "Updating...".
- Two real bugs found and fixed during verification: (1) `doDrawItem` wrapper dropped vanilla's return value -> black screen, `__sub not defined for operands` every frame; (2) buttons anchored left of the bottom-left Back button -> rendered offscreen. Both covered by regression tests in `tests/lua/`.
- License: MIT scaffolded, not yet confirmed.
- **GOG ZombieBuddy install path**: proven on joshua's machine (launch script: `steam-run` + bundled JRE + `-javaagent:ZombieBuddy.jar` + `-Dzomboid.steam=0`). Step-by-step guide with screenshots still to be written (Phase 4).

## Phase 3 - Java side (done Oct 2026)

**Blocker (resolved):** ZombieBuddy 2.3.2 did not load Java mods on PZ 42.21.0 (`loadMods(ArrayList<String>)` -> `loadMods(List<String>)`, [zed-0xff/ZombieBuddy#53](https://github.com/zed-0xff/ZombieBuddy/issues/53)). joshua built ZB from [PR #56](https://github.com/zed-0xff/ZombieBuddy/pull/56) and we compiled clean against the real 42.21.0 `projectzomboid.jar`.

- [x] `SteamCmdApi` (Lua globals), `Backend` (lazy singleton), `JobManager` (background jobs, JSON status), `WorkshopMap` (atomic persisted map), `SteamCmd` (explicit `steamcmd.path` or managed Valve-CDN bootstrap; NixOS `steam-run` auto-wrap), `ModInstaller` (atomic swap installs, crash recovery), `WorkshopApi` (keyless `GetPublishedFileDetails`), `Json`, `Net` (friendly failures), `Main` (load logging).
- [x] **Checkpoint:** end-to-end test passed - real download+install of a workshop mod in-game (EnableResetLuaButton, Oct 2026), after the full online smoke test passed on joshua's machine (real API + CDN + steamcmd).
- [x] Live-session hardening: noexec/sandbox binary fallback dir, single-flight bootstrap, validation-timeout leniency (first-run self-update), FORK launch-mechanism default (posix_spawn EACCES in steam-run's sandbox), ANSI stripping, sticky error panel, staging outside `mods/` (game's file watcher tripped over backup dirs).
- [x] Download-new-mod UI (Lua): Download button + ID/URL dialog; Java side needed no changes.

Moved to Phase 4 (hardening, not blockers): anonymous-login rejection -> account-login fallback (interactive, never store credentials); Steam Guard UX; job cancellation. Done Oct 2026: malformed Steam API JSON now fails the check (`IOException`) instead of looking like an empty/deleted result; failed steamcmd can no longer install a stale cache (exit code enforced); timed-out steamcmd is waited on before the next serialized job starts; repeat check clicks coalesce onto the running job; per-update timestamp falls back to the previously recorded one instead of the wall clock on API failure; multi-mod workshop items tracked per item, not per mod (check emits one entry per outdated item - "1 update available" / "Update all (1)" instead of "5 mods need update" - and a per-mod update clears the flag for all sibling mods of the item plus the Update-all count); test-only fixes Oct 2026: `WorkshopApi` now reads the `steamApiUrl` override per call instead of freezing it at class-load (the fixture test class-loaded it first, so joshua's "stubbed" checks were secretly hitting the real Steam API - invisible here because the live tests skip without Java sockets); 32-bit-hint tests pass the NixOS flag explicitly instead of sniffing the real OS. Windows audit Oct 2026 (`docs/WINDOWS_AUDIT.md`): no P0 code breakage in the default flow (steamcmd.zip bootstrap verified); P1 fixes done - Windows Defender/SmartScreen branch for the steamcmd failure hint, UTF-8 BOM stripped from `workshopbridge.properties` (and `mod.info` id matching), `isExecDenied` recognizes Windows error=5/193, fallback binary dir prefers `%LOCALAPPDATA%` on Windows, moves/deletes retry with backoff against AV holds, explicit UTF-8 for mod.info, steamcmd output decoded with the platform charset on Windows, FORK launch flag skipped on Windows, long-path hint on very long install paths; README gained a Windows troubleshooting section, TESTING.md notes WSL2 for the Java suite on Windows. Still open: verbatim Windows-GOG ZombieBuddy install steps for the buddy doc-test (P0-2), and confirming the buddy is on GOG not Steam (P0-1).

Follow-up audit (Oct 2026), all addressed: check re-reads the map after its API round trip and skips in-flight downloads (no stale badges when an update lands mid-check); shared progress panel has ownership (first painter wins, no flicker; a completing job never hides a running job's status); UI timers advance only in the fallback pump (no more double-speed flashes when both pumps run); no-backend path now shows an in-game ZombieBuddy guidance label instead of a silent menu; README `steamcmd.path` example uses forward slashes (single backslashes are properties escapes) with the validation error hinting the same; README row/panel state wording corrected; RESEARCH.md steamcmd-discovery note marked superseded.

## Phase 4 - Harden + release

- Remaining edge cases from Phase 3 (see above).
- Deleted/private workshop items are already surfaced in the job message (done Oct 2026).
- 32-bit Linux runtime: hints in place (distro packages, NixOS `steam-run`/`nix-ld`); keep validating on real systems.
- ZBS-sign releases (Ed25519); publish VirusTotal scan per release (see meowwoem's `SECURITYCHECK.MD` pattern).
- Reproducible-build notes so users can verify the JAR.
- GOG ZombieBuddy install guide with screenshots (path proven, guide not written).
- Workshop page + README install instructions.
- Consider: "adopt" flow for mods the user installed manually (match by modID → ask for workshop URL), currently out of scope.

## Testing status (Oct 2026)

Verified in-game (joshua, Linux/GOG, 42.21.0): real Steam API check,
steamcmd bootstrap incl. self-update, download + atomic install
(EnableResetLuaButton), progress panel rendering, job completion lines,
check/update-all result flashes, sticky click-to-dismiss errors,
"Force update"/"Update" button titles, map self-healing (TrueWeight).

Pending: out-of-date mod end-to-end (check -> badge -> update -> map
advances -> check clean); normal playtest with mod loaded; Windows
machine test (buddy: steamcmd.exe bootstrap, paths with spaces, fresh
profile first-run); Windows playtest; error paths (bad ID, offline,
deleted item); update-all with 2+ outdated mods; downloaded mod appears
without restart (reloadMods question); doc test (buddy follows README
verbatim).

## Open questions (carried)

- Whether pzmm-style scanners flag the JAR's `ProcessBuilder` usage at warn or block level - mitigations already planned (open source, signing, ZB approval dialog).
- B41 support: out of scope (ZombieBuddy is B42-only). Revisit only if a B41-compatible loader emerges.
- License choice: MIT scaffolded, not yet confirmed by joshua.

## Mod compatibility notes

- **ModFolders** (workshop 3779201168, v0.2.26, ~2k-line Lua; audited Oct
  2026): real collision found and fixed. It patches `ModListBox.doDrawItem`
  at class level on OnMainMenuEnter, but the MainScreen builds the
  ModSelector (and its listbox) eagerly at boot, before that. Our old
  per-instance `doDrawItem` wrap therefore captured vanilla as its base and
  shadowed ModFolders' later class patch, so folder rows rendered through
  vanilla (big red X, no folder buttons). Fixed by wrapping
  `ModListBox.doDrawItem` at class level instead: whoever wraps last chains
  the previous implementation, so install order no longer matters. Same
  audit also fixed a latent bug in our code: the row "update available"
  badge never drew in-game at all, because the wrapper passed the listbox
  row wrapper to `WB_GetModId` instead of `item.item` (the Lua test masked
  it by passing modInfo directly); now unwrapped, and folder rows safely
  yield no badge. The badge shifts left when ModFolders' panel controls are
  detected (per draw via `listbox.parent`), clearing its +/- icons. Lua
  tests cover both install orders. Residual quirk (ModFolders' design, not
  ours): selecting a folder row doesn't update the info panel, so our
  Update button keeps showing the last-selected mod until a real mod row
  is picked.

## Backlog (from live testing, Oct 2026)

New scope goes here, not into the phases above, until it is picked up and
planned properly.

- [x] **Progress/feedback UI (fixed Oct 2026).** Three stacked in-game-only
  bugs, all fixed and verified: (1) the panel was built three times with
  discarded Java peers (vanilla `instantiate()` calls `createChildren()`
  itself); fixed by building a plain `ISPanel` once, eagerly in the menu
  hook, following the working download dialog's order.
  (2) Job `onDone` callbacks never fired - the poll never delivered while
  the Mods menu (a main-menu screen) was open; fixed with a fallback pump
  driving `WB_PollJobs` from the screen's per-frame `update()`, kept
  alongside `Events.OnTick` (idempotent, double-pump harmless). Transitions
  now log (`nil -> running -> done`).
  (3) The check's `onDone` threw on a forward-referenced Lua local
  (`WB_RefreshModPanel` declared after its use), silently swallowed by the
  poll's `pcall` - hence checks going quiet after "Checking..."; fixed by
  moving helpers above the handlers. Lesson: keep shared Lua locals above
  first use; the poll swallows errors.
  Panel renders with animated dots, check/update-all flash their result
  summary ("Everything is up to date" / "N mod(s) have updates"), job
  errors stick until clicked.
- [x] **Operation logging (Oct 2026).** Every check / update-all / per-mod
  update / download logs start (with job id) and finish/failure to the game
  log, plus job state transitions while in flight.
- [x] **Mod id vs folder-name mismatch (fixed Oct 2026).** A mod whose
  folder name differs from its mod.info `id=` (e.g. author typo: folder
  "True Weigth", id "TrueWeight") showed "Unknown workshop ID". Root cause:
  `readModId` didn't know the B42 `42.0/mod.info` layout, so it fell back to
  the folder name when recording. Fixed: added `42.0/mod.info` to the
  candidates, plus a self-healing reverse lookup (`Backend.getWorkshopId`)
  that repairs stale folder-name entries on the spot by scanning mod.info.
  Existing bad entries fix themselves on next lookup; no map wipe needed.
- [x] **Per-mod button title reflects state (Oct 2026).** "Update" when a
  check found an update for that mod, "Force update" otherwise (clicking
  always re-downloads; per-mod update never checks first). The visible mod
  panel refreshes on check completion without reselecting.
- [x] **In-game backend unload investigated, declined (Oct 2026).** True
  unloading is impossible (ZombieBuddy loads our jar into the app
  classloader, which lives for the JVM lifetime). A `wbShutdown()` on
  `OnGameStart` was considered and rejected: idle in-game cost is ~0 (0-4
  parked daemon threads, <1MB heap, one no-op OnTick handler), while shutdown
  risks killing mid-install downloads (interrupted installs would land
  unmapped as "Unknown workshop ID") and orphaned steamcmd processes. The
  lazy design already gives the important property: zero threads/network
  until first use, and cached-pool threads self-terminate.
- [x] **Serialized downloads (Oct 2026).** Download-bearing jobs
  (`submitUpdate`, `submitUpdateAll`) run on a dedicated single-thread
  executor; checks stay on the cached pool. A waiting job reports
  "Queued..." until it starts (surfaced in the per-mod label and progress
  panel via the normal message path). Removes the concurrent-steamcmd
  question and the shared-panel flicker entirely.

- [x] **Per-mod job status vs. selection (fixed Oct 2026).** The per-mod
  job's poll callbacks used to write to the shared ModInfoPanel unconditionally,
  so selecting another mod mid-download showed the wrong job's text, and two
  queued jobs fought over the one label ("Downloading..." vs "Queued...").
  Now per-mod jobs are tracked per workshop item: callbacks only paint while
  the panel shows that item (siblings included), reselecting mid-download shows
  live status, duplicate clicks coalesce instead of queueing, failures persist
  on reselect until retried, and update-all clears stale failure notes.
- [x] **Cold-boot Lua exposure (fixed Oct 2026).** On first boot the wb* Lua
  globals were missing until a Lua reload. Root-caused from the game log:
  ZB's automatic @LuaMethod discovery runs in its afterExposeAll phase, which
  fires BEFORE our jar is loaded (our jar is found via the loadMods hook), so
  our globals were never registered; the Lua-reset log showed our class
  exposed in afterExposeAll because the jar was already known by then. Fix:
  Main.main now manually registers SteamCmdApi with ZB's Exposer
  (reflective addClassWithGlobalLuaMethod + immediate exposeGlobalFunctions,
  mirroring what afterExposeAll does), degrading gracefully on ZB versions
  without those entry points. Covered by Java test section 17
  (Exposer/LuaManager stubs). Verified by joshua Oct 2026: cold boot now
  exposes the wb* globals, no Lua reload needed.

- [x] **Mod menu UI refresh without restart/lua reload.** Root-caused via the
  game decompile (Oct 2026): `ms:reloadMods()` rebuilds the menu model from
  `getModDirectoryTable()`, but the game caches the mod folder scan after the
  first call (`ZomboidFileSystem.modFolders`) and caches parsed mod.infos by
  id (`ChooseGameInfo.Mods`), so the rebuild saw stale data. The game's own
  file watcher can't save us: its `isModFile` gate only matches paths under
  already-cached mod dirs, so brand-new folders never trigger its refresh.
  Fix: new Lua-visible `wbInvalidateModCaches()` calls
  `ZomboidFileSystem.instance.resetModFolders()` + `ChooseGameInfo.Reset()`
  on the game thread (mirroring the game's own `ZomboidFileSystem.update()`),
  then `ms:reloadMods()`; wrapped in a `WB_RefreshModList(ms)` helper used
  by all three completion flows (update-all, per-mod update, download-new).
  The info panel is not repainted by the reload (it only updates on
  selection), so per-mod confirmation labels survive. Needs joshua's in-game
  verification.

- [ ] **Orphaned sub-mods on multi-mod item update.** If a workshop item
  containing several mods drops one of them, updating installs the new set
  but never removes the dropped mod's folder, and the map forgets the
  association. Fix: after a successful install, compare the previous entry's
  modIds with the new ones and delete folders whose mod.info id matches a
  removed modId - but only when ownership is unambiguous (no other map entry
  claims that mod id). Deferring: rare case, and auto-deleting the wrong
  folder would be worse than leaving an orphan the user can delete manually.

- [ ] **Mod dependencies.** When downloading/updating a mod, detect required
  workshop items and offer to install them too. Example: `3799732653`
  depends on `3171167894`. Open mechanism: Steam's `GetPublishedFileDetails`
  has no dependencies field, so investigate sources (workshop page
  "Required items" section, SteamKit, ...). Then: Java resolves the dep
  list, Lua prompts (install-all vs pick), jobs install each dep like a
  normal download.

- [ ] **Workshop Collections support (idea, unlikely).** Paste a collection
  URL/ID, resolve the contained workshop items, download/install all of
  them (reusing the serialized download queue). Investigate:
  `GetPublishedFileDetails` returns a `children` array for collection
  items. Note: authoring collections needs Steam game ownership, but
  *consuming* them is just item IDs, so anonymous download works.
  Only worth doing if the mod gets real users beyond us.

- [ ] **Server-join mod download prompt.** Joining a server with mods you
  don't have pops the game's "download missing mods" prompt, which goes
  through Steam Workshop and is useless for GOG players. Hook that prompt
  and fulfill it through our steamcmd download path instead, then continue
  the join. Prior note: the game's built-in `ConnectToServerState`
  item.update() path was investigated from the decompile and deliberately
  not reused - find the right seam (likely the workshop-download dialog or
  state in the join flow).

- [x] **"Open in Workshop" button (done Oct 2026).** Per-mod button in the
  info panel opening the item's workshop page in the system browser. Java
  `wbOpenWorkshopPage(workshopId)` via `ProcessBuilder` (`xdg-open` /
  `gio open` / `open` / `cmd /c start`), id digits-validated before it
  touches a command line. Shown whenever a workshop id is known (tracked
  by us or Steam-managed).

- [ ] **Release checklist (before any public build).**
  - ~~`WB_Config.DEBUG_STUB` must be off for release~~ done Oct 2026:
    defaults to `false`; the Lua UI tests enable it explicitly. Without the
    Java backend the mod now shows install guidance instead of fake successes.
  - Version number in mod.info.
  - Release signing + VirusTotal scan of the jar.
  - GOG/ZombieBuddy install guide with screenshots; Workshop page +
    release-ready README install instructions.
- [ ] **GitHub releases for WorkshopBridge.** Versioned, downloadable
  releases of the mod itself. Depends on: release checklist above.
  (May never get done.)
- [ ] **Self update check.** The mod checks GitHub releases for a newer
  version of itself and tells the user. Depends on: GitHub releases.
  (May never get done.)
- [ ] **Auto update.** Download and install the new version itself.
  Depends on: self update check. (May never get done.)
