#!/usr/bin/env bash
# Offline Java test rig for WorkshopBridge's backend. No game, no network.
# Needs: JDK 17+ on PATH (javac, java).
#
# All test file activity (fake Zomboid dir, map, mods, steamcmd cache) stays
# inside tests/java/.test-work/ (gitignored). It is wiped at the start of
# every run and kept afterwards, so a failed run can be inspected.
#
# Run from anywhere:  ./tests/java/run.sh
set -u
cd "$(dirname "$0")" || exit 1  # tests/java (guarded: rm -rf "$WORK" below must not run elsewhere)
HERE="$PWD"
REPO="$(cd ../.. && pwd)"

# Sandbox fallback: this dev VM keeps a JDK under ~/.tools without putting it
# on PATH. Pick it up automatically so the rig just works there.
if ! command -v javac >/dev/null 2>&1; then
    for cand in "$HOME"/workspace/.tools/jdk-*/bin; do
        if [ -x "$cand/javac" ] && [ -x "$cand/java" ]; then
            export PATH="$cand:$PATH"
            break
        fi
    done
fi

for tool in javac java; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: '$tool' not found on PATH. Install a JDK 17+ first, e.g.:" >&2
        echo "  Debian/Ubuntu: sudo apt install openjdk-17-jdk" >&2
        echo "  Fedora:        sudo dnf install java-17-openjdk-devel" >&2
        echo "  macOS:         brew install openjdk@17" >&2
        exit 1
    fi
done
# tar is undeclared but required (archive tests, sections 11/11b)
command -v tar >/dev/null 2>&1 \
    || { echo "error: 'tar' not found on PATH (needed by the archive tests)." >&2; exit 1; }
JH_BIN="$(dirname "$(command -v javac)")"

WORK="$HERE/.test-work"
rm -rf "$WORK"
mkdir -p "$WORK/classes" "$WORK/zomboid"

echo "compiling..."
# find -print0 | xargs -0: no word-splitting hazards from $(find ...)
find stubs src -name "*.java" -print0 \
    | xargs -0 "$JH_BIN/javac" -d "$WORK/classes" \
        "$REPO/WorkshopBridge/java-src/src/main/java/com/workshopbridge/"*.java \
    || exit 1

echo "running tests..."
"$JH_BIN/java" \
    -Dwb.test.zomboid="$WORK/zomboid" \
    -Dwb.test.fakebin="$HERE/fakebin" \
    -Dwb.test.fixtures="$HERE/fixtures" \
    -cp "$WORK/classes" com.workshopbridge.WBTest
