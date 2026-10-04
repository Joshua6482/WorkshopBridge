# Usage & how it works

## Usage

- **Check for updates** scans the workshop for newer versions of your WorkshopBridge-tracked mods. Nothing happens automatically. Checks only run when you ask, so a surprise update can't break your save.
- **Update all (N)** downloads and installs every available update. Mods are replaced cleanly, stale files removed.
- **Download** grabs a brand-new mod from the workshop: paste a workshop ID or URL (e.g. `2685600088` or the full `steamcommunity.com/sharedfiles/...?id=2685600088` link). It installs like an update and is tracked from then on.
- Downloads run one at a time; a waiting download shows "Queued...".
- Selecting a mod shows its state in the info panel: tracked by WorkshopBridge
  (with a per-mod button: **Update** when a check found a newer version,
  **Force update** otherwise - it re-downloads regardless), **Managed by Steam**,
  or **Unknown workshop ID**. After a check, mods with updates also get an
  "Update available" badge right on their row.
- Long operations show a progress panel with a throbber. If the network is down you'll get "Couldn't reach Steam's servers - check your internet connection" instead of a raw exception.

## How it works

1. **Update** asks the Java side to run `steamcmd +login anonymous +workshop_download_item 108600 <id> +quit` on a background thread.
2. The downloaded mod is copied flat into `Zomboid/mods/<modID>/`. The game's mod scan only looks one level deep, so nesting under a workshop-ID folder would hide the mod.
3. The `workshopID -> [modID]` mapping is persisted in `Zomboid/workshopbridge_map.json`. That's what powers update checks.
4. Update checks compare the workshop item's `time_updated` (via the Steam Web API) against the locally installed version.

For the full Lua/Java contract, data flows, and map format, see [ARCHITECTURE.md](ARCHITECTURE.md).
