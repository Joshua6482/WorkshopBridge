# WorkshopBridge: Remaining Work

## Validation

- Test on Windows: paths with spaces, and a normal play session. 
- Exercise error paths: bad ID, offline, and deleted workshop item.
- Test collection import in-game (behind the "Enable collection import (experimental)" mod option, off by default); enable by default once it is verified.

## Open

- **Download UI polish** 
  1. job cancel: no pause/stop for a running job; needs a cancel flag in `JobManager` plus destroying the steamcmd process on cancel. 
  2. minimize: users don't know it's safe to leave the mod tab mid-download; add a minimize button collapsing the progress panel to a small top-right icon 
- **Documentation:** Refine `docs/INSTALL.md`.
- **Internationalization:** Move Lua-facing labels, status text, dialogs, and error flashes into `WB_Strings.lua`; move Java messages such as `Net.friendlyMessage` and hints into a strings class or `.properties` bundle. Mod names are not currently parsed or displayed by this code; Java NIO handles Unicode paths, and the JSON parser handles `\\u` escapes including surrogate pairs.
- **Self-update check:** Notify users when a newer GitHub release is available
- **Automatic update:** Download and install a new version
