# WorkshopBridge

Download and update Steam Workshop mods from inside Project Zomboid. Built for non-Steam (GOG) players who can't use the Steam Workshop directly.

A Lua UI in the Mods menu ("Check for updates", "Update all", per-mod "Update", "Download") talks to a Java backend (via [ZombieBuddy](https://github.com/zed-0xff/ZombieBuddy)) that runs `steamcmd`, moves downloaded mods into place, and remembers which workshop item each mod came from.

![Mods menu buttons](docs/images/menu-buttons.png)
![Download dialog](docs/images/download-dialog.png)

## Recommended Mods

- [Mod Folders](https://steamcommunity.com/sharedfiles/filedetails/?id=3779201168)
- [Enable Reset Lua Button](https://steamcommunity.com/sharedfiles/filedetails/?id=3487511907)

## Docs

- [Installation](docs/INSTALL.md) - ZombieBuddy setup, installing the mod, steamcmd options, Windows notes, troubleshooting
- [Usage & how it works](docs/USAGE.md) - the check/update/download flows and what's happening under the hood
- [Building](WorkshopBridge/java-src/README.md) - compile the Java backend with Gradle
- [Architecture](docs/ARCHITECTURE.md) - Lua/Java contract, data flows, map format
- [Testing](TESTING.md) - how to run the offline suites and the online smoke test

## License

MIT, see [LICENSE](LICENSE).

---

Disclaimer: Vibecoded, Most of the source code manually reviewed and tweaked , but still. 
