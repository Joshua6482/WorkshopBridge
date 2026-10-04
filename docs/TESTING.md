# Testing

## Offline tests

Run the suites from the repository root:

```sh
./tests/lua/run.sh
./tests/java/run.sh
```

Lua needs Lua 5.3 or 5.4; the script can use the workspace build if no system Lua is available. Java needs JDK 17+. The Java suite uses stubs and fake steamcmd, so it does not need the game or network. Run it under WSL2 on Windows.

Test data is kept in the gitignored `tests/java/.test-work/` directory. The suite clears it at startup and leaves it in place after the run. Loopback-restricted environments may skip Java checks that use the local stub HTTP server.

## Online smoke test

```sh
./tests/java/run-online.sh
```

Requires JDK 17+ and internet access. It calls the real Steam API, downloads steamcmd from Valve, and downloads and installs a small workshop item. The first run may take several minutes. Its data stays in the gitignored `tests/java/.test-work-online/` directory.

On Linux, steamcmd needs 32-bit runtime libraries. On NixOS, use `steam-run`; WorkshopBridge uses `steam-run` automatically when available. 

Run the smoke test before releases or changes to Steam-facing code.

## In-game checks

The automated suites do not verify real ZombieBuddy exposure or UI appearance. Test those in Project Zomboid with a working ZombieBuddy build. Windows testing should also cover steamcmd bootstrap, paths with spaces, and a fresh profile.

## Troubleshooting

- A `SKIPPED` loopback HTTP check indicates an environment restriction, not a passing test.
- To rerun one Lua test, use `lua tests/lua/test_ui.lua` with `WB_LUA_DIR` set; replace the filename with the test you want to run.