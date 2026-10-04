# Installation

In this doc, "the Zomboid folder" means the game's save/cache directory: `~/Zomboid` on Linux, `%USERPROFILE%\Zomboid` on Windows. That's where saves, mods, and logs live. It is not the game install folder (the one with `ProjectZomboid.jar`).

1. **Install [ZombieBuddy](https://github.com/zed-0xff/ZombieBuddy)** (one-time). WorkshopBridge's Java backend loads through it. The mod tells you in-game if it's missing.
2. **Copy the `WorkshopBridge` folder** from a release into the `mods` folder inside your Zomboid folder, then enable it in the Mods menu like any other mod.
3. **steamcmd**, two options:
   - *Let the mod handle it:* on your first update, WorkshopBridge downloads Valve's official steamcmd into `Zomboid/workshop_cache/steamcmd/` automatically.
   - *Use your own:* create `Zomboid/workshopbridge.properties` in your Zomboid folder with one line:
     ```
     steamcmd.path=C:/path/to/steamcmd.exe
     ```
     (Forward slashes work on Windows too, and avoid Java properties'
     backslash escaping, where a single `\t` would become a tab. If you must
     use backslashes, double every one: `C:\\path\\to\\steamcmd.exe`.)
     The mod validates it by running `<exe> +quit`. A broken path fails fast
     with a message telling you to fix or remove it; when no path is
     configured, the mod uses its managed copy (bootstrapping it first if
     needed).
   - *NixOS:* Valve's steamcmd can't run directly (no `/lib/ld-linux.so.2`).
     Install `steam-run` from nixpkgs (or enable `nix-ld`); WorkshopBridge
     runs steamcmd through `steam-run` automatically when it's available.
4. Launch the game. If you run with `-Dzomboid.steam=0` (GOG), everything works. WorkshopBridge never touches Steamworks.

## Windows notes

- **Your Zomboid folder** is at `%USERPROFILE%\Zomboid` (press Win+R, paste
  `%USERPROFILE%`, open the `Zomboid` folder). Mods go in `Zomboid\mods`,
  `workshopbridge.properties` (if you use one) goes directly in `Zomboid`.
- **Windows Defender / SmartScreen vs. steamcmd.exe:** a freshly downloaded
  `steamcmd.exe` can get quarantined or blocked. If downloads fail right after
  the automatic bootstrap, check Defender's protection history and
  restore/allow-list the file, or allow-list the `Zomboid\workshop_cache\steamcmd`
  folder. Also: a downloaded exe can carry the "blocked" mark - right-click
  `steamcmd.exe` -> Properties -> check **Unblock** -> OK, then retry.
- **Editing `workshopbridge.properties` in Notepad:** save it via File -> Save As
  with "Save as type" set to **All files** (otherwise you get
  `workshopbridge.properties.txt`, which the mod ignores). Plain UTF-8 is fine;
  if Notepad saved it with a BOM the mod strips it.
- **Very long mod paths:** if an install fails and the mod lives in a deeply
  nested folder, Windows' 260-character path limit may be the cause. The error
  message says so when it looks likely; the fix is enabling long paths in
  `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled`.

## Troubleshooting

- **steamcmd fails with `posix_spawn failed, error: 13 (Permission denied)`**,
  e.g. when the game runs inside steam-run's sandbox: the JDK's default process
  launcher (posix_spawn) can be blocked there. Add
  `-Djdk.lang.Process.launchMechanism=FORK` to your game's Java command line
  manually (the mod used to set this itself at load, but the JDK freezes the
  mechanism on the first process launch, which happens before the mod loads,
  so the in-code set had no effect).
- **steamcmd can't execute from the game drive** (e.g. a `noexec` removable-media
  mount, or a sandboxed bind mount): the mod automatically bootstraps the
  steamcmd *binary* into `~/.cache/workshopbridge/steamcmd` (or
  `$XDG_CACHE_HOME`; on Windows `%LOCALAPPDATA%\workshopbridge\steamcmd`) and
  retries there. Workshop downloads still land in `Zomboid/workshop_cache` on
  the game drive.
