# WorkshopBridge architecture

## Components

```
┌─────────────────────────────┐
│  Lua UI (client)            │  WB_Main.lua, WB_ModsMenu.lua, WB_Jobs.lua
│  - "Update all" button      │  WB_Download.lua, WB_Tools.lua, WB_Adopt.lua
│  - per-mod Update /         │  Runs on the game thread. Never blocks:
│    "Unknown workshop ID"    │  all Java calls are fire-and-poll.
└──────────────┬──────────────┘
               │ ZombieBuddy-exposed Java API
               │ (@Exposer.LuaClass / @LuaMethod global)
┌──────────────▼──────────────┐
│  Java backend               │  SteamCmdApi.java (exposed)
│  - SteamCmd: detect + spawn │  JobManager, WorkshopMap, SteamCmd
│    steamcmd (ProcessBuilder) │
│  - file moves Zomboid/mods/ │
│  - update checks via        │
│    GetPublishedFileDetails  │
└──────────────┬──────────────┘
               │ files
┌──────────────▼──────────────┐
│  Zomboid/                   │
│  - mods/<ModID>/            │  installed mods (PZ standard layout)
│  - workshopbridge_map.json  │  workshopID -> { modIds, timeUpdated,
│  - workshop_cache/          │    lastDownloaded }  (Java owns this file)
│    (steamcmd download area) │
└─────────────────────────────┘
```

## Lua ↔ Java contract (implemented)

Exposed as **plain Lua globals** (`wbIsAvailable()` etc.) via
`@LuaMethod(name = ..., global = true)`.

Cold-boot note: ZombieBuddy's automatic `@LuaMethod` discovery runs in its
`afterExposeAll` phase, which fires *before* our jar is loaded (our jar is
found via the `loadMods` hook), so on a cold boot the wb* globals were never
registered until a Lua reload. `Main.main` therefore registers
`SteamCmdApi` manually (reflective `addClassWithGlobalLuaMethod` + immediate
`exposeGlobalFunctions`, mirroring `afterExposeAll`), degrading gracefully on
other ZB versions.

| Function | Args | Returns |
|---|---|---|
| `wbIsAvailable()` | - | `true` when the Java side loaded (Lua uses this to detect ZombieBuddy presence) |
| `wbGetSteamCmdPath()` | - | path string, or `nil` if not detected |
| `wbGetWorkshopId(modId)` | PZ mod id (`mod.info` `id=`) | workshop ID string, or `nil` = "Unknown workshop ID" |
| `wbCheckForUpdates()` | - | starts a job; returns jobId. A done status carries `updates` = list of **workshopIds** with updates available (one entry per outdated item, however many mods it holds) |
| `wbUpdateMod(workshopId)` | workshop ID | jobId |
| `wbUpdateAll()` | - | jobId (checks, then downloads only outdated items) |
| `wbExportModList(idsCsv)` | comma-separated workshop IDs | absolute path of the written `workshopbridge-exports/modlist-<timestamp>.txt`, or null on failure (synchronous, no job) |
| `wbImportMods(idsCsv)` | comma-separated workshop IDs | jobId; downloads+installs each id in order ("Importing i/N") |
| `wbImportCollection(collectionId)` | workshop collection ID | jobId; resolves the collection's children via `GetPublishedFileDetails`, then imports them like `wbImportMods` |
| `wbAdoptMod(workshopId, modId)` | workshop ID + expected PZ mod id (`mod.info` `id=`) | jobId; force-downloads the item, verifies it contains `modId` **before** overwriting anything (fails naming what it holds otherwise), then installs+records |
| `wbInvalidateModCaches()` | - | invalidates the game's cached mod folder scan (`ZomboidFileSystem.resetModFolders()`) and parsed mod-info cache (`ChooseGameInfo.Reset()`) so a following `ms:reloadMods()` actually sees freshly downloaded/updated mods. Call on the game thread before `reloadMods()` |
| `wbGetJobStatus(jobId)` | jobId | **JSON string** `{"state","done","total","message"[,"error"][,"updates"]}`, or null for unknown jobs. Lua decodes it with the pure-Lua `WB_Json.lua` (Kahlua's Java return marshaling is deliberately not relied upon). A done check-job carries `updates` = list of **workshopIds** with updates available (one entry per outdated item, however many mods it holds) |
| `wbOpenWorkshopPage(workshopId)` | workshop ID | `true` if a browser process was launched. Tries `java.awt.Desktop.browse()` first, then falls back to `xdg-open`/`gio open` (Linux), `open` (macOS), or `cmd /c start` (Windows). The id is digits-validated before touching a command line |

### Job status shape (JSON string, decoded in Lua by WB_Json)

```lua
{
    state = "running" | "done" | "failed",
    done = 2, total = 5,            -- items processed (for Update all)
    message = "Downloading 123456789 (3/5)…",
    error = nil | "steamcmd not found",
}
```

Jobs run on Java background threads. Lua never blocks waiting on them: it
polls `wbGetJobStatus(jobId)` on `Events.OnTick`, with a fallback pump
driven by the Mods screen's per-frame `update()` (the tick doesn't reliably
fire while a main-menu screen is open). The poll is idempotent, so both
pumps running at once is harmless.

Download-bearing jobs (`wbUpdateMod`, `wbUpdateAll`, `wbImportMods`, `wbImportCollection`, `wbAdoptMod`) run **serialized** on a
dedicated single-thread executor - concurrent steamcmd processes share one
install dir and gain nothing. Checks stay on the cached pool. A download job
waiting its turn reports `"Queued..."` as its message until it starts.

Hardening (Oct 2026, from an external audit):
- `SteamCmd.download()` enforces a zero exit code - a failed run can never
  install a stale cache dir as if it were fresh; the previous download is
  left untouched.
- A timed-out steamcmd is waited on (bounded) after `destroyForcibly()`
  so it can't overlap the next serialized job.
- Malformed Steam API responses fail the check job (`IOException`) instead
  of parsing as "no items listed" (which would misreport every mod as
  deleted or up to date).
- Repeat check clicks coalesce onto the already-running check job.
- On API failure during a per-mod update, the previously recorded
  `timeUpdated` is kept instead of the wall clock, so the next check
  retries the comparison rather than wrongly calling it current.
- A check re-reads the workshop map AFTER its API round trip and ignores
  items with a download in flight, so a concurrent update can't resurrect
  stale "update available" badges.
- The shared progress panel has ownership: the first job to paint owns it
  (no flicker between concurrent jobs); a completing job never hides a
  still-running job's status, and a stuck error holds the panel against
  concurrent jobs until the user dismisses it (a newer job's paints clear
  it). UI timers (flash, throbber) advance only in
  the Mods-screen fallback pump, never in `WB_PollJobs` itself, so they
  can't run double speed when both pumps run.

## workshopbridge_map.json

```json
{
  "version": 1,
  "items": {
    "123456789": {
      "modIds": ["ModA", "ModB"],
      "timeUpdated": 1727745600,
      "lastDownloaded": 1727745700
    }
  }
}
```

- Written only by the Java side, after a successful download+move. Saves are
  atomic (write temp + rename); a corrupt file loads as empty rather than
  throwing.
- `modIds` parsed from each downloaded `mod.info` (`id=` line). The mod.info is
  located the way the game locates it: via the game's own
  `ZomboidFileSystem.getModVersionDirName` (so `42/`, `42.1/`, `42.1.0/`
  resolve exactly as in-game), then `common/`. Legacy flat/B41 mod.info is
  unsupported, matching the game. Falls back to the folder name when no
  mod.info is found. A workshop item can contain multiple mods - hence the
  list.
- Reverse lookup (modID → workshopID) inverts the map in memory, with
  self-healing: on a miss, installed mod folders are scanned and an entry
  recorded under a stale folder name (author typo, or a layout we didn't
  parse at install time) is repaired to the true mod.info id on the spot.
- `timeUpdated` comes from `GetPublishedFileDetails`; compared against the workshop on update checks.

## Flows

### Check for updates
1. Lua: **Check for updates** button → `wbCheckForUpdates()` → jobId.
2. Java: for each mapped workshop item, `GetPublishedFileDetails` → compare `time_updated` vs stored `timeUpdated`. No downloads.
3. Lua polls with the progress panel; on completion, rows whose workshop item has an update show an "Update available" badge, **Update all** becomes "Update all (n)" (n counts workshop items, not mods), the selected mod's panel refreshes in place, and the result summary ("Everything is up to date" / "N updates available") flashes briefly. Failures stick in the panel until clicked.

### Single mod update
1. Lua: per-mod button → `wbGetWorkshopId(modId)` → `wbUpdateMod(workshopId)` → jobId. The button reads **Update** when a check flagged the mod, **Force update** otherwise (it always re-downloads; it never checks first).
2. Lua polls with the progress panel; the row label tracks the job ("Updating...", "Queued...", "Up to date" / failure). On success the update-available flag clears for the whole workshop item, so sibling mods from the same item lose their badges and the **Update all** count drops too. Per-mod jobs are tracked per workshop item: a second click while one is in flight coalesces instead of queueing a duplicate, and the panel label only ever shows the job for the workshop item currently selected (selecting another mod mid-download shows its live status on return, never another job's text). Then `WB_RefreshModList` invalidates the game mod caches and reloads the list so the row shows the new mod.info (the info panel is not repainted by the reload, so the "Up to date" confirmation stays visible).
3. Java (serialized with other downloads): download → move into `Zomboid/mods/` (replace existing) → update map → job `done`.

### Update all
1. Lua: **Update all** button → `wbUpdateAll()` → jobId.
2. Java: for each mapped workshop item, `GetPublishedFileDetails` → if `time_updated > timeUpdated`, download+move+update map. Job reports `done/total`.
3. Lua: `WB_RefreshModList` on completion: `wbInvalidateModCaches()` (the game caches the mod folder scan and parsed mod.infos, so `reloadMods()` alone would rebuild from stale data) then `ms:reloadMods()`. Without the invalidation, updated mods would keep showing old names/versions in the list.

### Download a new mod
1. Lua: **Download** button → dialog takes a workshop ID or URL → `WB_ParseWorkshopId` → `wbUpdateMod(workshopId)` → jobId. (The Java side treats untracked ids the same as updates: download → move into `Zomboid/mods/` → record in map.)
2. Lua polls `wbGetJobStatus(jobId)` on tick with the progress panel; on completion `WB_RefreshModList` (invalidate + `ms:reloadMods()`) so the new mod appears, and it is tracked from then on.

### More tools
1. Lua: **More tools** button → three dialogs: **Export enabled mods** collects the enabled mods' workshop IDs (tracked or Steam-managed) and calls `wbExportModList` synchronously; **Import from text** pastes URLs/IDs and calls `wbImportMods`; **Import from collection** (currently hidden in the UI pending real in-game testing) pastes a collection ID/URL and calls `wbImportCollection`, which resolves the collection's `children` via `GetPublishedFileDetails` and imports each.
2. Export writes `Zomboid/workshopbridge-exports/modlist-<timestamp>.txt` (one URL per line; fixed path, no file pickers by design). Imports reuse the serialized download path and the atomic install, one item at a time ("Importing i/N"); on completion the game caches are invalidated and the list reloaded.

### Adopt a mod
1. Lua: per-mod **Adopt...** button (shown only for mods with "Unknown workshop ID") → dialog takes a workshop ID or URL → `WB_ParseWorkshopId` → `wbAdoptMod(workshopId, modId)` → jobId.
2. Java (serialized with other downloads): **force-download first**, then scan the downloaded item's `mods/` tree for its mod.info ids, then compare against the selected mod's exact id. A mismatch fails the job and names what the item actually holds ("workshop item X does not contain mod 'Y'; it contains: ...") - nothing is installed, nothing is recorded. A match installs all of the item's mods (multi-mod items adopt naturally) and records every id under the workshop item. The fresh download also provides the current remote timestamp, so the adopted mod doesn't report a phantom update on the next check.
3. Lua: same job tracking UI as updates; on completion the mod list is refreshed in place.

### First run / missing pieces
- ZombieBuddy not installed → the mod doesn't load at all: our mod.info has `require=ZombieBuddy`, so the game refuses to enable us without it. (An earlier in-game "install ZombieBuddy" guidance label was removed as unreachable; ZombieBuddy's own javaagent prompt covers its setup.)
- `Zomboid/workshopbridge.properties` is auto-created on first run with commented documentation of each setting. Currently the only setting is `steamcmd.path`: an explicit steamcmd override, validated by execution, always wins over the managed copy. An existing file is never overwritten.
- steamcmd not found → the Java side **bootstraps it automatically** from Valve's CDN into `Zomboid/workshop_cache/steamcmd/` (with progress). No system-wide discovery: either the `steamcmd.path` override or the previously bootstrapped managed copy. `wbGetSteamCmdPath()` returns nil only when neither exists yet. If the binary can't execute from the game drive (noexec/sandboxed mount), it is bootstrapped again under `~/.cache/workshopbridge/steamcmd` (or `$XDG_CACHE_HOME`) and retried there.
- Process launching: the default `posix_spawn` fails with EACCES inside steam-run's sandbox; the fix is `-Djdk.lang.Process.launchMechanism=FORK` on the game's Java command line (set manually - the mod used to set it itself at load, but the JDK freezes the mechanism on the first process launch, before the mod loads, so that had no effect).

## UI placement (B42, verified in-game Oct 2026 unless noted)

- **Update all** + **Check for updates**: wrapped `ModSelector:create`; the buttons join vanilla's bottom-right cluster (MapsOrder, ModsOrder, Accept), anchored right+bottom with the same font and sizing flags vanilla uses. (First attempt anchored them left of the Back button, which is bottom-left - they rendered offscreen.)
- **More tools** (not yet verified in-game): joins the same bottom-right cluster.
- **Per-row**: wrap `ModListBox:doDrawItem` at class level; draw status text keyed by `item.item`'s mod id (doDrawItem gets the row wrapper, not the modData). Class-level (not per-instance) because the ModSelector is built at boot while other mods (e.g. ModFolders) patch the class later on OnMainMenuEnter - an instance wrap would shadow their patch. Whoever wraps last chains the previous implementation, so install order doesn't matter. Rows are not widget-composed, so no per-row buttons (would need manual hit-testing).
- **Wrapper rule: always propagate return values.** Vanilla `prerender` does `v.height = y2 - y` where `y2 = self:doDrawItem(...)`; our first wrapper dropped the return and the menu rendered black with `__sub not defined for operands` thrown every frame. Wrapping a vanilla method means forwarding args AND returns.
- **Per-mod Update button / status label**: `ModInfoPanel` - `createChildren()` once, `updateView(modInfo)` per selection. Button title is **Update** when a check flagged that mod, **Force update** otherwise. **Adopt...** (not yet verified in-game) occupies the Update button's slot for mods with "Unknown workshop ID"; the **Open in Workshop** button stacks below it whenever a workshop id is known.
- Row states (three): in our map → per-mod button (+ "Update available" badge after a check); game's `getWorkshopID()` non-empty → "Managed by Steam"; else grey "Unknown workshop ID".
- Wrapping is idempotent per instance and re-applied defensively by `WB_RefreshModList` after every list reload (update-all, per-mod update, and download flows).

## Design constraints

- **B42 only** (ZombieBuddy requirement).
- **Zero bytecode patches**: we use only ZombieBuddy's Lua-exposure surface, its most stable API.
- **Never store Steam credentials.** Anonymous steamcmd login is the default; if it's ever rejected, fall back to an interactive user login (Steam Guard via the user's own terminal), never persisted.
- **Mods load at game start** - updating files while sitting in the Mods menu is safe; changes apply on next new game / continue.
