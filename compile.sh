#!/usr/bin/env bash
# Compile the WorkshopBridge Java backend and install the jar into the mod.
#
# Usage:
#   ./compile.sh [path-to-game-classes]
#
# path-to-game-classes is the folder holding the game's compiled classes
# (the one containing zombie/ZomboidFileSystem.class) or the game jar
# itself, e.g.:
#   ./compile.sh ~/games/projectzomboid/projectzomboid.jar
#
# When omitted, $PZ_JAVA_DIR is used; otherwise it looks inside
# WorkshopBridge/java-src/libs/ for libs/pz-java/, libs/projectzomboid.jar,
# or any other jar holding the game classes.
#
# One-time setup: put ZombieBuddy.jar in WorkshopBridge/java-src/libs/
# (see WorkshopBridge/java-src/README.md).
#
# Needs: JDK 17+ and Gradle on PATH. Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")"  # repo root
SRC="WorkshopBridge/java-src"

for tool in javac java; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: '$tool' not found on PATH. Install a JDK 17+ first, e.g.:" >&2
        echo "  Debian/Ubuntu: sudo apt install openjdk-17-jdk" >&2
        echo "  Fedora:        sudo dnf install java-17-openjdk-devel" >&2
        echo "  macOS:         brew install openjdk@17" >&2
        exit 1
    fi
done

if ! command -v gradle >/dev/null 2>&1; then
    echo "error: 'gradle' not found on PATH. Install it first, e.g.:" >&2
    echo "  Debian/Ubuntu: sudo apt install gradle" >&2
    echo "  Fedora:        sudo dnf install gradle" >&2
    echo "  macOS:         brew install gradle" >&2
    exit 1
fi

if [ ! -f "$SRC/libs/ZombieBuddy.jar" ]; then
    echo "error: $SRC/libs/ZombieBuddy.jar not found." >&2
    echo "Build ZombieBuddy (./gradlew shadowJar in the ZombieBuddy repo)" >&2
    echo "and copy the result there. See $SRC/README.md." >&2
    exit 1
fi

PZ_JAVA=""
has_game_classes() {
    if [ -d "$1" ]; then
        [ -f "$1/zombie/ZomboidFileSystem.class" ]
    elif [ -f "$1" ]; then
        unzip -l "$1" zombie/ZomboidFileSystem.class >/dev/null 2>&1
    else
        return 1
    fi
}
# Game classes location: explicit argument wins, then $PZ_JAVA_DIR, then the
# conventional spots inside java-src/libs (a dropped-in projectzomboid.jar
# just works).
resolve_pz_java() {
    if [ -n "${1:-}" ]; then echo "$1"; return 0; fi
    if [ -n "${PZ_JAVA_DIR:-}" ]; then echo "$PZ_JAVA_DIR"; return 0; fi
    local libs="$SRC/libs" candidate jar
    for candidate in "$libs/pz-java" "$libs/projectzomboid.jar"; do
        if has_game_classes "$candidate" 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
    for jar in "$libs"/*.jar; do
        [ -e "$jar" ] || break
        case "$(basename "$jar")" in
            ZombieBuddy.jar) continue ;;
        esac
        if has_game_classes "$jar" 2>/dev/null; then
            echo "$jar"
            return 0
        fi
    done
    echo "$libs/pz-java" # default, so the error below names a real path
}
PZ_JAVA="$(resolve_pz_java "${1:-}")"
if ! has_game_classes "$PZ_JAVA"; then
    echo "error: PZ game classes not found at '$PZ_JAVA'." >&2
    echo "Pass the folder containing zombie/ZomboidFileSystem.class (or the" >&2
    echo "game .jar itself) as an argument or via \$PZ_JAVA_DIR. Find it with:" >&2
    echo "  find <game-install-dir> -name ZomboidFileSystem.class 2>/dev/null" >&2
    exit 1
fi

echo "Compiling against game classes: $PZ_JAVA"
(cd "$SRC" && gradle -PpzJavaDir="$PZ_JAVA" installJar)
echo "Built: WorkshopBridge/42/media/java/WorkshopBridge.jar"
