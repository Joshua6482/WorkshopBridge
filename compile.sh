#!/usr/bin/env bash
# Compile the WorkshopBridge Java backend and install the jar into the mod.
#
# Usage:
#   ./compile.sh [path-to-game-classes]
#
# path-to-game-classes is the game's compiled-classes directory or the game
# jar itself, e.g.:
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

for tool in javac java jar; do
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
# Jars seen in libs/ that did not validate as game classes (named in the
# error message so a misplaced/wrong jar is diagnosable).
REJECTED_JARS=""
# Internal probe for "is this the game's classes": a class only the game
# jar/classes dir contains. Never surfaced in user-facing text.
GAME_CLASS_PROBE="zombie/ZomboidFileSystem.class"
has_game_classes() {
    if [ -d "$1" ]; then
        [ -f "$1/$GAME_CLASS_PROBE" ]
    elif [ -f "$1" ]; then
        # 'jar' ships with the JDK (already required above), so unlike
        # 'unzip' it is always available here.
        jar tf "$1" 2>/dev/null | grep -qx "$GAME_CLASS_PROBE"
    else
        return 1
    fi
}
# Game classes location: explicit argument wins, then $PZ_JAVA_DIR, then the
# conventional spots inside java-src/libs (a dropped-in projectzomboid.jar
# just works). Sets PZ_JAVA (and REJECTED_JARS for the error message).
resolve_pz_java() {
    if [ -n "${1:-}" ]; then PZ_JAVA="$1"; return 0; fi
    if [ -n "${PZ_JAVA_DIR:-}" ]; then PZ_JAVA="$PZ_JAVA_DIR"; return 0; fi
    local libs="$SRC/libs" candidate jar
    for candidate in "$libs/pz-java" "$libs/projectzomboid.jar"; do
        if has_game_classes "$candidate" 2>/dev/null; then
            PZ_JAVA="$candidate"
            return 0
        elif [ -f "$candidate" ]; then
            REJECTED_JARS="$REJECTED_JARS $candidate"
        fi
    done
    for jar in "$libs"/*.jar; do
        [ -e "$jar" ] || break
        case "$(basename "$jar")" in
            ZombieBuddy.jar) continue ;;
        esac
        if has_game_classes "$jar" 2>/dev/null; then
            PZ_JAVA="$jar"
            return 0
        else
            REJECTED_JARS="$REJECTED_JARS $jar"
        fi
    done
    PZ_JAVA="$libs/pz-java" # default, so the error below names a real path
}
resolve_pz_java "${1:-}"
if ! has_game_classes "$PZ_JAVA"; then
    echo "error: PZ game classes not found at '$PZ_JAVA'." >&2
    if [ -n "$REJECTED_JARS" ]; then
        echo "These files in $SRC/libs did not look like the game" >&2
        echo "classes:$REJECTED_JARS" >&2
    fi
    echo "Point ./compile.sh at your game jar (e.g. projectzomboid.jar) or the" >&2
    echo "game's Java classes directory, as an argument or via \$PZ_JAVA_DIR." >&2
    echo "Dropping projectzomboid.jar into $SRC/libs/ also works." >&2
    exit 1
fi

echo "Compiling against game classes: $PZ_JAVA"
(cd "$SRC" && gradle -PpzJavaDir="$PZ_JAVA" installJar)
echo "Built: WorkshopBridge/42/media/java/WorkshopBridge.jar"
