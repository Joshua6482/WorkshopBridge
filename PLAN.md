# WorkshopBridge: Remaining Work

## Validation

- Test on Windows: steamcmd.exe bootstrap, paths with spaces, fresh-profile first run, and a normal play session. Test pack drafted Oct 5, committed as `docs/WINDOWS_TEST_PACK.md` (prep checklist, verbatim tester guide, report template, known Windows risks). Buddy test still pending: confirm the tester is on the GOG version first.
- Exercise error paths: bad ID, offline, and deleted workshop item.
- Test collection import in-game (behind the "Enable collection import (experimental)" mod option, off by default); enable by default once it is verified.
- Verify the dependency prompt in-game: download 3799732653 (depends on 3171167894), confirm the "Required Workshop items" dialog appears and Install all works.

## Open

- **Download UI polish** 
  1. job cancel: no pause/stop for a running job; needs a cancel flag in `JobManager` plus destroying the steamcmd process on cancel. 
  2. minimize: users don't know it's safe to leave the mod tab mid-download; add a minimize button collapsing the progress panel to a small top-right icon 
- **Documentation:** Refine `docs/INSTALL.md`.
- **Internationalization:** Move Lua-facing labels, status text, dialogs, and error flashes into `WB_Strings.lua`; move Java messages such as `Net.friendlyMessage` and hints into a strings class or `.properties` bundle. Mod names are not currently parsed or displayed by this code; Java NIO handles Unicode paths, and the JSON parser handles `\\u` escapes including surrogate pairs.
- **Self-update check:** Notify users when a newer GitHub release is available
- **Automatic update:** Download and install a new version
