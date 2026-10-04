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
│      (ProcessBuilder)       │
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

Cold boot: ZombieBuddy's `afterExposeAll` discovery runs before our jar loads
via the `loadMods` hook, so it misses our `wb*` globals until Lua reloads.
`Main.main` registers `SteamCmdApi` manually using reflective
`addClassWithGlobalLuaMethod` and `exposeGlobalFunctions`, and degrades
gracefully on other ZombieBuddy versions.

| Function | Args | Returns |
|---|---|---|
| `wbIsAvailable()` | - | `true` if Java loaded; Lua uses this to detect ZombieBuddy |
| `wbGetSteamCmdPath()` | - | path string, or `nil` if not detected |
| `wbGetWorkshopId(modId)` | PZ mod id (`mod.info` `id=`) | workshop ID string, or `nil` = "Unknown workshop ID" |
| `wbCheckForUpdates()` | - | starts a job; returns jobId. On completion, `updates` lists **workshopIds** with updates (one per outdated item, regardless of contained mod count) |
| `wbUpdateMod(workshopId)` | workshop ID | jobId |
| `wbUpdateAll()` | - | jobId; checks for and downloads outdated items |
| `wbExportModList(idsCsv)` | comma-separated workshop IDs | synchronously writes `workshopbridge-exports/modlist-<timestamp>.txt`; returns its absolute path or null on failure |
| `wbImportMods(idsCsv)` | comma-separated workshop IDs | jobId; downloads and installs IDs in order (`Importing i/N`) |
| `wbImportCollection(collectionId)` | workshop collection ID | jobId; resolves `children` via `GetCollectionDetails`, then imports them as `wbImportMods` does |
| `wbAdoptMod(workshopId, modId)` | workshop ID + expected PZ mod id (`mod.info` `id=`) | jobId; force-downloads, verifies `modId` before overwriting, then installs and records; failure names the contained IDs |
| `wbInvalidateModCaches()` | - | clears the game's mod-folder scan (`ZomboidFileSystem.resetModFolders()`) and parsed mod-info cache (`ChooseGameInfo.Reset()`). Call on the game thread before `ms:reloadMods()` so it sees new or updated mods |
| `wbGetJobStatus(jobId)` | jobId | **JSON string** `{"state","done","total","message"[,"error"][,"updates"]}`, or null for unknown jobs. Lua decodes it with `WB_Json.lua`; Kahlua Java-object marshaling is not relied on.
| `wbOpenWorkshopPage(workshopId)` | workshop ID | `true` if a browser launches. Tries `java.awt.Desktop.browse()`, then `xdg-open`/`gio open` (Linux), `open` (macOS), or `cmd /c start` (Windows). Validates the ID as digits before using it in a command |

### Job status shape (JSON string, decoded in Lua by WB_Json)

```lua
{
    state = "running" | "done" | "failed",
    done = 2, total = 5,            -- items processed (for Update all)
    message = "Downloading 123456789 (3/5)…",
    error = nil | "steamcmd not found",
    updates = { "123", ... },       -- check jobs: workshop ids with updates
    deps = {                        -- deps jobs only: required items
        { id = "123", title = "Some Library", installed = false }, ...
    },
}
```

Lua polls `wbGetJobStatus(jobId)` from `Events.OnTick` and the Mods screen's
per-frame `update()` fallback, since ticks may not fire while a main-menu
screen is open. Polling is idempotent, so both pumps can run safely.

Download jobs (`wbUpdateMod`, `wbUpdateAll`, `wbImportMods`,
`wbImportCollection`, `wbAdoptMod`) share a **single-thread executor** because
concurrent steamcmd processes share one install directory. Checks use the
cached pool. Waiting downloads report `"Queued..."` until they start.

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

- Java writes the map after a successful download and move. Saves use a
  temporary file and atomic rename; corrupt files load as empty.
- `modIds` come from each downloaded `mod.info` `id=` line. Java locates the
  file using the game's `ZomboidFileSystem.getModVersionDirName` and then
  `common/`, supporting layouts such as `42/`, `42.1/`, and `42.1.0/`. Legacy
  flat/B41 layouts are unsupported, matching the game. If no `mod.info` is
  found, the folder name is used. Items may contain multiple mods.
- Reverse lookup (modID → workshopID) inverts the map in memory. On a miss,
  installed folders are scanned; stale folder-name entries (for example,
  from a typo or previously unparsed layout) are repaired to the `mod.info`
  ID.
- `timeUpdated` comes from `GetPublishedFileDetails`; compared against the workshop on update checks.

## Flows

### Check for updates
1. Lua: **Check for updates** calls `wbCheckForUpdates()` and gets a jobId.
2. Java: calls `GetPublishedFileDetails` for each mapped item and compares `time_updated` with stored `timeUpdated`. It does not download files.
3. Lua polls with the progress panel. When done, updated rows get an "Update available" badge; **Update all** shows the number of outdated workshop items; the selected mod panel refreshes; and a brief result summary appears. Failures remain until clicked. A failed check keeps the previous results (badges and count) since it produced no new information. Items with a download in flight are skipped, not reported as up to date, and named in the summary.

### Single mod update
1. Lua: the per-mod button gets the workshop ID with `wbGetWorkshopId(modId)` and calls `wbUpdateMod(workshopId)`. It reads **Update** after a check flags the mod, otherwise **Force update**; either action downloads again without checking first.
2. Lua polls the progress panel and row label (`Updating...`, `Queued...`, `Up to date`, or failure). On success, the item's update flag clears for all sibling mods and the **Update all** count. Per-item jobs coalesce duplicate clicks and only update the selected item's label; switching away and back shows its live status. `WB_RefreshModList` invalidates game caches and reloads the list. The info panel is not repainted, so its completion message remains visible.
3. Java serializes the download with other downloads. The item's download dir is wiped first (steamcmd doesn't reliably drop files the author removed), then the item is installed into `Zomboid/mods/`: every mod the item now holds is installed, and folders for mods the item no longer holds are removed (only when no other workshop item claims them). The map is updated and the job marked done.

### Update all
1. Lua: **Update all** calls `wbUpdateAll()` and gets a jobId.
2. Java: checks each mapped item; if `time_updated > timeUpdated`, it downloads the item, installs it, and updates the map. The job reports `done/total`.
3. Lua: on completion, `WB_RefreshModList` calls `wbInvalidateModCaches()` before `ms:reloadMods()`. The game caches mod folders and parsed `mod.info` files, so reloading without invalidation would show stale names and versions. On failure the previous update marks are kept; if any items installed before the failure, the list still refreshes so they appear.

### Download a new mod
1. Lua: **Download** opens an ID/URL dialog, parses it with `WB_ParseWorkshopId`, then calls `wbUpdateMod(workshopId)`. Java downloads untracked IDs, installs them in `Zomboid/mods/`, and records them in the map.
2. Lua polls `wbGetJobStatus(jobId)` and shows progress. On completion, `WB_RefreshModList` invalidates caches and reloads the list so the new mod appears and is tracked.

### More tools
1. Lua: **More tools** opens three dialogs. **Export enabled mods** collects tracked or Steam-managed workshop IDs and calls `wbExportModList` synchronously. **Import from text** accepts URLs/IDs and calls `wbImportMods`. **Import from collection** (button disabled pending in-game testing) accepts a collection ID/URL; `wbImportCollection` resolves its `children` through `GetCollectionDetails` and imports them.
2. Export writes one URL per line to `Zomboid/workshopbridge-exports/modlist-<timestamp>.txt` (millisecond stamp, `CREATE_NEW` plus a numeric fallback so back-to-back exports never overwrite each other); the path is fixed by design. Imports use the serialized download and atomic-install path, one item at a time (`Importing i/N`). On completion, caches are invalidated and the list reloaded.

### Adopt a mod
1. Lua: **Adopt...** (shown for "Unknown workshop ID") opens an ID/URL dialog, parses it with `WB_ParseWorkshopId`, and calls `wbAdoptMod(workshopId, modId)`.
2. Java serializes the job with other downloads, force-downloads the item, scans its `mods/` tree, and checks for the selected mod's exact `mod.info` ID. A mismatch names the contained IDs and installs or records nothing. A match installs all mods in the item and records their IDs. The fresh download supplies the remote timestamp, avoiding a phantom update on the next check.
3. Lua shows the normal job status and refreshes the mod list on completion.

### First run / missing pieces
- Without ZombieBuddy, the game refuses to load the mod because `mod.info` requires it. Its javaagent prompt handles setup; our earlier in-game guidance was unreachable.
- On first run, `Zomboid/workshopbridge.properties` is created with comments for each setting. The only setting is `steamcmd.path`, an executable-validated override that takes precedence over the managed copy. Existing files are never overwritten.
- If steamcmd is missing, Java downloads it from Valve's CDN to `Zomboid/workshop_cache/steamcmd/` and reports progress. It does not search system paths: it uses `steamcmd.path` or the managed copy. `wbGetSteamCmdPath()` returns nil if neither exists. If the game-drive copy cannot execute (for example, a noexec mount), it retries from `~/.cache/workshopbridge/steamcmd` or `$XDG_CACHE_HOME`.
- In steam-run's sandbox, `posix_spawn` may fail with EACCES. Set `-Djdk.lang.Process.launchMechanism=FORK` on the game's Java command line. Setting it from the mod is too late because the JDK freezes the mechanism on the first process launch, before the mod loads.

## UI placement (B42; verified in-game Oct 2026 unless noted)

- **Update all** and **Check for updates** wrap `ModSelector:create` and join vanilla's bottom-right MapsOrder/ModsOrder/Accept cluster, using its anchors, font, and sizing flags.
- **More tools** (not yet verified in-game) joins the same cluster.
- **Per-row status:** wrap `ModListBox:doDrawItem` at class level and key text by `item.item`'s mod ID; the method receives a row wrapper, not `modData`. Class-level wrapping lets patches installed later (such as ModFolders on `OnMainMenuEnter`) chain regardless of load order. Rows are not widgets, so buttons would require manual hit-testing. The modID-to-workshopID lookup is memoized per mod ID (a Java miss scans every mod folder, and rows draw every frame); `WB_RefreshModList` clears the memo, which every install path calls.
- **Wrapper rule: propagate return values.** Vanilla `prerender` uses the result of `doDrawItem` to set row height, so wrappers must forward arguments and returns.
- **Per-mod Update button/status:** `ModInfoPanel.createChildren()` runs once; `updateView(modInfo)` runs on selection. The button reads **Update** when a check flags the mod, otherwise **Force update**. **Adopt...** (verified in-game Oct 2026) replaces it for "Unknown workshop ID"; **Open in Workshop** appears below when an ID is known.
- Row states (three): in our map → per-mod button (+ "Update available" badge after a check); game's `getWorkshopID()` non-empty → "Managed by Steam"; else grey "Unknown workshop ID".
- Wrapping is idempotent per instance and re-applied by `WB_RefreshModList` after update-all, per-mod update, and download reloads.

## Design constraints

- **B42 only**
- **Zero bytecode patches**: we use only ZombieBuddy's Lua-exposure surface, its most stable API.
- **Never store Steam credentials.** Anonymous steamcmd login only.
