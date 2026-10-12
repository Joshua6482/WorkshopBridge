# WorkshopBridge: Remaining Work

## Validation

- Test on Windows: steamcmd.exe bootstrap, paths with spaces, fresh-profile first run, and a normal play session. Test pack drafted Oct 5 as uncommitted `docs/WINDOWS_TEST_PACK.md` (prep checklist, verbatim tester guide, report template, known Windows risks). Buddy test still pending: confirm the tester is on the GOG version first.
- Exercise error paths: bad ID, offline, and deleted workshop item.
- Test collection import in-game (behind the "Enable collection import (experimental)" mod option, off by default); enable by default once it is verified.
- Verify the dependency prompt in-game: download 3799732653 (depends on 3171167894), confirm the "Required Workshop items" dialog appears and Install all works.

## Open

- **Download UI polish** (joshua's Windows test notes, Oct 2026): (a) job cancel: no pause/stop for a running job; needs a cancel flag in `JobManager` plus destroying the steamcmd process on cancel. (b) minimize: users don't know it's safe to leave the mod tab mid-download; add a minimize button collapsing the progress panel to a small top-right icon (jobs already continue on background threads while the tab is closed; polling resumes when the menu reopens). (c) staged progress text: long downloads show only a throbber; set `Job.message` per phase from Java ("Loading steamcmd…", "Downloading 123 (3/5)…", "Installing…") — Lua already displays it. Note: steamcmd's `workshop_download_item` emits no percentage progress (unlike `app_update`'s `Update state` lines), so per-byte progress isn't available; phase-level is the realistic scope.
- **posix_spawn troubleshooting:** Expand `docs/INSTALL.md` with Windows launcher guidance and Linux instructions for distinguishing the steam-run sandbox case from native launch failures.
- **Internationalization:** Move Lua-facing labels, status text, dialogs, and error flashes into `WB_Strings.lua`; move Java messages such as `Net.friendlyMessage` and hints into a strings class or `.properties` bundle. Mod names are not currently parsed or displayed by this code; Java NIO handles Unicode paths, and the JSON parser handles `\\u` escapes including surrogate pairs.
- **Self-update check:** Notify users when a newer GitHub release is available; depends on GitHub releases.
- **Automatic update:** Download and install a new version; depends on the self-update check.

## Release Readiness

- Build release jars with `-Pdiagnostics=false` to exclude development-only probes.
- Set the version in `mod.info`.
- ZBS-sign the release (Ed25519) and publish a VirusTotal scan.

## Open Questions

- pzmm scanner: resolved/out of scope Oct 2026 (joshua investigated). pzmm's virus_scanner.py flags every `.jar` as high-severity `BLOCKED_EXTENSION` by extension alone, before any content scan — nothing about our jar specifically to fix. Our mitigations stand: open source, ZBS signing, the ZombieBuddy trust-author approval dialog.
