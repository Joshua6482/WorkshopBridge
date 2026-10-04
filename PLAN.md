# WorkshopBridge: Remaining Work

## Validation

- Test on Windows: steamcmd.exe bootstrap, paths with spaces, fresh-profile first run, and a normal play session.
- Exercise error paths: bad ID, offline, and deleted workshop item.
- Test collection import in-game; its button remains disabled until this is verified.

## Open Work

- **Orphaned sub-mods:** Updating a multi-mod workshop item can leave behind a folder for a mod removed from that item. If implemented, remove it only when its `mod.info` ID matches the removed ID and no other WorkshopBridge map entry claims that ID; otherwise leave the folder untouched.
- **Mod dependencies:** Find a reliable source for required workshop items; `GetPublishedFileDetails` has no dependencies field. Example: `3799732653` depends on `3171167894`. Resolve the dependency list in Java, prompt in Lua to install all or choose items, and install each selected dependency through the normal serialized download job path.
- **Server-join mod download prompt:** Joining a server with missing mods opens the game's Steam Workshop prompt, which does not work for GOG players. Hook the prompt and download missing items through steamcmd, then resume the join. Find the correct hook, likely the workshop-download dialog or join-flow state; the decompiled `ConnectToServerState` item-update path was investigated and is not suitable.
- **Authentication UX:** After anonymous-login rejection, offer an interactive account-login fallback without storing credentials; improve Steam Guard handling and add job cancellation.
- **posix_spawn troubleshooting:** Expand `docs/INSTALL.md` with Windows launcher guidance and Linux instructions for distinguishing the steam-run sandbox case from native launch failures.
- **Internationalization:** Move Lua-facing labels, status text, dialogs, and error flashes into `WB_Strings.lua`; move Java messages such as `Net.friendlyMessage` and hints into a strings class or `.properties` bundle. Mod names are not currently parsed or displayed by this code; Java NIO handles Unicode paths, and the JSON parser handles `\\u` escapes including surrogate pairs.
- **Jar signing script:** done (`./sign.sh`, repo root). ZBS is ZombieBuddy's own Ed25519 scheme (see zed-0xff/ZombieBuddy `doc/ModSigning.md`). One-time: Ed25519 keypair auto-generated into `~/.signing/` (private key never in the repo), SteamID64 asked once and saved next to the key (machine-local, not in the repo; joshua needs a Steam account for the identity even as a GOG player); later runs are fully automatic. Public key published as `JavaModZBS:<64 hex>` on the Steam profile or via PR to ZombieBuddy's `authors/` (keeps the profile private; keys there are authoritative). The documented `zb-gradle-plugin` does not exist (absent from the ZombieBuddy repo and the Gradle Plugin Portal), so the script implements the format directly with openssl: SHA-256 the release jar, sign the canonical payload `ZBS:<SteamID64>:<JAR_SHA256>`, write the `WorkshopBridge.jar.zbs` sidecar next to the jar. Regenerate on every rebuild; ship the `.zbs` alongside the jar in the release zip. Round-trip tested on a dummy jar (openssl verify passes, fails on a tampered jar); the sidecar format was additionally parsed by ZombieBuddy itself in-game (verification got as far as the Steam key lookup, which failed only because the public key is not published yet). Signing proves identity + integrity and enables ZombieBuddy's trust-author auto-approval, not safety.
- **Release script:** done (`./release.sh`, repo root). Interactive: prompts for the version (default today's date as `YYYY.MM.DD`, overridable via `--version=`/`WB_VERSION`), warns when the working tree is dirty, then compiles with diagnostics off, ZBS-signs the fresh jar, stages the mod folder (`42/`, `common/`, `poster.png`; `java-src/` is build workspace and is excluded), stamps `modversion=<version>` into the staged `mod.info` (the repo file is left untouched), and zips to `dist/WorkshopBridge-<version>.zip` (gitignored). Prints the zip and jar SHA-256 hashes, a VirusTotal report link for the zip (`https://www.virustotal.com/gui/file/<zip sha256>`; the link points at the zip because that is the file users download and VT links are keyed by file hash, and it shows a report once the zip has been uploaded there at least once), and a ready-to-paste release notes file; offers to create the GitHub release via `gh`. Flags: `--yes` (non-interactive), `--no-build` (package the tree as-is). End-to-end tested with `--no-build` on a dummy jar: zip layout, modversion stamping, hashes, VT link, and notes file all verified.
- **GitHub releases:** Publish versioned downloadable releases of the mod.
- **Self-update check:** Notify users when a newer GitHub release is available; depends on GitHub releases.
- **Automatic update:** Download and install a new version; depends on the self-update check.

## Release Readiness

- Build release jars with `-Pdiagnostics=false` to exclude development-only probes.
- Set the version in `mod.info`.
- ZBS-sign the release (Ed25519) and publish a VirusTotal scan.

## Open Questions

- Check whether pzmm-style scanners flag the JAR's `ProcessBuilder` usage at warning or block level. Mitigations include open source, signing, and the ZombieBuddy approval dialog.

