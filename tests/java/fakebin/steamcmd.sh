#!/bin/sh
# fake steamcmd for tests: creates a canned workshop item layout.
# args: +force_install_dir <dir> +login anonymous +workshop_download_item 108600 <id> +quit
CACHE=""
ID=""
prev=""
for a in "$@"; do
  if [ "$prev" = "+force_install_dir" ]; then CACHE="$a"; fi
  if [ "$prev" = "108600" ]; then ID="$a"; fi
  prev="$a"
done
MODDIR="$CACHE/steamapps/workshop/content/108600/$ID/mods/FakeMod-$ID/common"
if [ "$ID" = "0" ]; then
  # failure mode for tests: exit nonzero without producing any files
  echo "ERROR! Download item 0 failed (No match)" >&2
  exit 1
fi
if [ -f "$CACHE/.fail-$ID" ]; then
  # simulated failure: exit nonzero without producing any files
  # (the caller wipes the item dir before downloading, so there is no
  # stale cache to fall back on either way)
  echo "ERROR! Download item $ID failed (simulated)" >&2
  exit 1
fi
if [ "$ID" = "99998" ]; then
  # slow mode for the download-serialization test: hold the worker so a
  # second queued download can be observed waiting
  sleep 2
fi
if [ "$ID" = "99987" ]; then
  # two-mod item for the stale-submod test: both mods, unless the
  # .single-99987 marker asks for only the first (author removed one)
  for m in A B; do
    if [ "$m" = "B" ] && [ -f "$CACHE/.single-99987" ]; then continue; fi
    D="$CACHE/steamapps/workshop/content/108600/$ID/mods/FakeMod-99987-$m/common"
    mkdir -p "$D"
    printf 'id=FakeMod-99987-%s\ntitle=Fake Mod\n' "$m" > "$D/mod.info"
  done
  echo "Steam Console Client"
  exit 0
fi
mkdir -p "$MODDIR"
printf 'id=FakeMod-%s\ntitle=Fake Mod\n' "$ID" > "$MODDIR/mod.info"
mkdir -p "$MODDIR/../media/lua"
echo "-- fake" > "$MODDIR/../media/lua/fake.lua"
echo "Steam Console Client"
