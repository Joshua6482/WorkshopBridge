#!/usr/bin/env bash
# lint.sh — static analysis for the whole WorkshopBridge repo.
#
# Runs, in order: ShellCheck, luacheck, SpotBugs, Error Prone, PMD.
#
# Tool lookup: each tool is tried on PATH first (nixpkgs provides shellcheck,
# luacheck, spotbugs, pmd), then under ~/workspace/.tools/<tool>/ (this dev
# VM's shelf). A missing tool is skipped with a note — nothing is downloaded
# automatically.
#
# This is report-only: it prints findings and always exits 0 unless a tool
# itself errors. (PMD/SpotBugs have deliberate-idiom noise in this codebase,
# so there is no clean baseline to gate on yet. ShellCheck is the closest
# to clean.)
#
# Usage: ./lint.sh
set -u
cd "$(dirname "$0")" || exit 1

TOOLS_DIR="$HOME/workspace/.tools"

section() { echo; echo "=== $1 ==="; }
skip()    { echo "SKIP: $1 not found (PATH or $TOOLS_DIR)"; }

# --- ShellCheck ---
section "ShellCheck"
SC=""
if command -v shellcheck >/dev/null 2>&1; then SC="shellcheck"
elif [ -x "$TOOLS_DIR/shellcheck/shellcheck" ]; then SC="$TOOLS_DIR/shellcheck/shellcheck"
fi
if [ -n "$SC" ]; then
    "$SC" compile.sh release.sh sign.sh lint.sh \
        tests/java/run.sh tests/java/run-online.sh tests/lua/run.sh
    "$SC" -s sh tests/java/fakebin/steamcmd.sh
else skip "shellcheck"; fi

# --- luacheck (.luacheckrc in repo root applies) ---
section "luacheck"
LC=""
if command -v luacheck >/dev/null 2>&1; then LC="luacheck"
elif [ -x "$TOOLS_DIR/luarocks/bin/luacheck" ]; then LC="$TOOLS_DIR/luarocks/bin/luacheck"
fi
if [ -n "$LC" ]; then
    "$LC" WorkshopBridge/42/media/lua tests/lua
else skip "luacheck"; fi

# --- Java tools need a JDK and compiled classes ---
section "Java setup"
# Same sandbox fallback as tests/java/run.sh.
if ! command -v javac >/dev/null 2>&1; then
    for cand in "$HOME"/workspace/.tools/jdk-*/bin; do
        if [ -x "$cand/javac" ] && [ -x "$cand/java" ]; then
            export PATH="$cand:$PATH"
            break
        fi
    done
fi
if ! command -v javac >/dev/null 2>&1; then
    echo "SKIP: no JDK found; SpotBugs/Error Prone/PMD need one"
    exit 0
fi
export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(command -v javac)")")}"
JH_BIN="$(dirname "$(command -v javac)")"
echo "javac: $(command -v javac)"

TMPD="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$TMPD'" EXIT
mkdir -p "$TMPD/classes"
REPO="$PWD"
echo "compiling backend + stubs..."
(cd tests/java && find stubs src -name "*.java" -print0 \
    | xargs -0 "$JH_BIN/javac" -d "$TMPD/classes" \
        "$REPO/WorkshopBridge/java-src/src/main/java/com/workshopbridge/"*.java) \
    || { echo "ERROR: compile failed, cannot run Java analyzers"; exit 1; }
SOURCES=("$REPO"/WorkshopBridge/java-src/src/main/java/com/workshopbridge/*.java)

# --- SpotBugs ---
section "SpotBugs"
SB=""
if command -v spotbugs >/dev/null 2>&1; then SB="spotbugs"
else
    for cand in "$TOOLS_DIR"/spotbugs/spotbugs-*/bin/spotbugs; do
        [ -x "$cand" ] && SB="$cand" && break
    done
fi
if [ -n "$SB" ]; then
    "$SB" -textui -effort:default -onlyAnalyze 'com.workshopbridge.*' \
        -auxclasspath "$TMPD/classes" "$TMPD/classes" 2>&1 | grep -v "^Picked up" || true
else skip "spotbugs"; fi

# --- Error Prone (javac plugin; best-effort, never fails the run) ---
section "Error Prone"
EP_DIR="$TOOLS_DIR/errorprone"
if [ -d "$EP_DIR" ] && ls "$EP_DIR"/error_prone_core-*.jar >/dev/null 2>&1; then
    PP="$(printf "%s:" "$EP_DIR"/*.jar)"; PP="${PP%:}"
    # shellcheck disable=SC2086
    "$JH_BIN/javac" \
        -J--add-exports=jdk.compiler/com.sun.tools.javac.api=ALL-UNNAMED \
        -J--add-exports=jdk.compiler/com.sun.tools.javac.file=ALL-UNNAMED \
        -J--add-exports=jdk.compiler/com.sun.tools.javac.main=ALL-UNNAMED \
        -J--add-exports=jdk.compiler/com.sun.tools.javac.jvm=ALL-UNNAMED \
        -J--add-exports=jdk.compiler/com.sun.tools.javac.processing=ALL-UNNAMED \
        -J--add-exports=jdk.compiler/com.sun.tools.javac.comp=ALL-UNNAMED \
        -J--add-exports=jdk.compiler/com.sun.tools.javac.code=ALL-UNNAMED \
        -J--add-exports=jdk.compiler/com.sun.tools.javac.tree=ALL-UNNAMED \
        -J--add-exports=jdk.compiler/com.sun.tools.javac.util=ALL-UNNAMED \
        -J--add-exports=jdk.compiler/com.sun.tools.javac.parser=ALL-UNNAMED \
        -J--add-opens=jdk.compiler/com.sun.tools.javac.code=ALL-UNNAMED \
        -J--add-opens=jdk.compiler/com.sun.tools.javac.comp=ALL-UNNAMED \
        -XDcompilePolicy=simple \
        -processorpath "$PP" -Xplugin:ErrorProne \
        -cp "$TMPD/classes" -d "$TMPD/ep-classes" \
        -Xmaxerrs 50 "${SOURCES[@]}" 2>&1 | grep -v "^Picked up" || true
else skip "error_prone (needs $EP_DIR/error_prone_core-*.jar)"; fi

# --- PMD ---
section "PMD"
PMD=""
if command -v pmd >/dev/null 2>&1; then PMD="pmd"
else
    for cand in "$TOOLS_DIR"/pmd/pmd-bin-*/bin/pmd; do
        [ -x "$cand" ] && PMD="$cand" && break
    done
fi
if [ -n "$PMD" ]; then
    "$PMD" check -d WorkshopBridge/java-src/src/main/java \
        -R category/java/bestpractices.xml,category/java/errorprone.xml \
        --no-cache --no-fail-on-violation -f text 2>&1 | grep -v "^Picked up" || true
else skip "pmd"; fi

echo
echo "lint done."
