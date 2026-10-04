#!/usr/bin/env bash
# release.sh - Build a WorkshopBridge release zip.
#
# Full packaging pass:
#   1. ./compile.sh with diagnostics off (dev-only probes excluded)
#   2. ./sign.sh (ZBS Ed25519 sidecar for the fresh jar)
#   3. stages the mod folder (42/, common/, poster.png) and stamps
#      modversion=<version> into the staged mod.info (the repo file
#      is left untouched)
#   4. zips it to dist/WorkshopBridge-<version>.zip
#   5. prints SHA-256 hashes and a VirusTotal report link for the zip
#
# The VirusTotal link is https://www.virustotal.com/gui/file/<zip sha256>.
# That page shows a scan report once the zip has been uploaded to
# VirusTotal at least once; before that it lands on an upload/search page,
# so the first release still needs one manual upload.
#
# The link points at the release zip (Lua + Java), not the jar alone:
# the zip is the file users actually download, and a VirusTotal link is
# keyed by file hash, so it has to match the distributed artifact.
#
# Usage:
#   ./release.sh [--yes] [--no-build] [--version=2026.10.04]
#
#   --yes        non-interactive: accept defaults, overwrite existing zip
#   --no-build   skip compile+sign; package the tree as-is (the jar and
#                its .zbs sidecar must already be in place)
#   --version=X  release version instead of today's date
#
# Env:
#   WB_VERSION   same as --version
set -euo pipefail
cd "$(dirname "$0")"  # repo root

die() { echo "release.sh: error: $*" >&2; exit 1; }

ASSUME_YES=""
NO_BUILD=""
VERSION="${WB_VERSION:-$(date +%Y.%m.%d)}"
for arg in "$@"; do
    case "$arg" in
        --yes) ASSUME_YES=1 ;;
        --no-build) NO_BUILD=1 ;;
        --version=*) VERSION="${arg#--version=}" ;;
        --help|-h)
            sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) die "unknown argument: $arg (try --help)" ;;
    esac
done

case "$VERSION" in
    ''|*[!A-Za-z0-9._-]*)
        die "bad version '$VERSION' (letters, digits, . _ - only)" ;;
esac

command -v sha256sum >/dev/null 2>&1 || die "sha256sum not found on PATH"
if command -v zip >/dev/null 2>&1; then
    ZIPPER="zip"
elif command -v jar >/dev/null 2>&1; then
    ZIPPER="jar"  # JDK ships one, so this is always there when compiling
else
    die "neither 'zip' nor JDK 'jar' found on PATH (needed to build the zip)"
fi

confirm() { # $1 = prompt; true on yes (or with --yes)
    if [ -n "$ASSUME_YES" ]; then return 0; fi
    local ans
    read -r -p "$1 [y/N] " ans || ans=""
    [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

if [ -z "$ASSUME_YES" ]; then
    printf 'Release version [%s]: ' "$VERSION"
    read -r ans || ans=""
    [ -n "$ans" ] && VERSION="$ans"
    case "$VERSION" in
        ''|*[!A-Za-z0-9._-]*) die "bad version '$VERSION'" ;;
    esac
fi

# Warn when the tree is dirty: uncommitted changes end up in the release.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && [ -n "$(git status --porcelain)" ]; then
    echo "release.sh: warning: working tree has uncommitted changes:"
    git status --porcelain | head -10
    confirm "They will be included in the release. Continue?" \
        || die "aborted"
fi

DIST="dist"
STAGE="$DIST/stage"
ZIP="$DIST/WorkshopBridge-$VERSION.zip"
NOTES="$DIST/WorkshopBridge-$VERSION.notes.md"
JAR="WorkshopBridge/42/media/java/WorkshopBridge.jar"

if [ -f "$ZIP" ] && [ -z "$ASSUME_YES" ]; then
    confirm "$ZIP already exists. Overwrite?" || die "aborted"
fi

echo "release.sh: building WorkshopBridge $VERSION"
echo "  1. compile (diagnostics off)"
echo "  2. ZBS-sign the jar"
echo "  3. stage mod + stamp modversion=$VERSION"
echo "  4. zip -> $ZIP"
confirm "Proceed?" || die "aborted"

# 1+2. Fresh jar, then a fresh sidecar (a stale .zbs never validates).
if [ -z "$NO_BUILD" ]; then
    WB_DIAGNOSTICS=false ./compile.sh
    ./sign.sh "$JAR"
else
    echo "release.sh: --no-build: packaging the tree as-is."
fi
[ -f "$JAR" ] || die "jar not found: $JAR"
[ -f "$JAR.zbs" ] || die "sidecar not found: $JAR.zbs (run ./sign.sh)"

# 3. Stage exactly what the game loads: 42/, common/, poster.png.
#    java-src/ is build workspace, not part of the mod.
cp_tree() { # cp -a, falling back to plain recursive copy where the
            # filesystem will not let us preserve ownership
    cp -a "$@" 2>/dev/null || cp -r "$@"
}
rm -rf "$STAGE"
mkdir -p "$STAGE/WorkshopBridge"
cp_tree WorkshopBridge/42 WorkshopBridge/common WorkshopBridge/poster.png \
    "$STAGE/WorkshopBridge/"
STAGED_INFO="$STAGE/WorkshopBridge/common/mod.info"
if grep -q '^modversion=' "$STAGED_INFO"; then
    sed -i "s/^modversion=.*/modversion=$VERSION/" "$STAGED_INFO"
else
    printf 'modversion=%s\n' "$VERSION" >> "$STAGED_INFO"
fi

# 4. Zip with a top-level WorkshopBridge/ folder so it extracts cleanly.
rm -f "$ZIP"
if [ "$ZIPPER" = "zip" ]; then
    (cd "$STAGE" && zip -qr "../WorkshopBridge-$VERSION.zip" WorkshopBridge)
else
    (cd "$STAGE" && jar -cMf "../WorkshopBridge-$VERSION.zip" WorkshopBridge)
fi
rm -rf "$STAGE"
[ -f "$ZIP" ] || die "zip was not created"

ZIP_SHA="$(sha256sum "$ZIP" | cut -d' ' -f1)"
JAR_SHA="$(sha256sum "$JAR" | cut -d' ' -f1)"
VT_LINK="https://www.virustotal.com/gui/file/$ZIP_SHA"

cat > "$NOTES" <<EOF
# WorkshopBridge $VERSION

Download and update Steam Workshop mods from inside Project Zomboid.
Built for non-Steam (GOG) players.

## Install

1. Install [ZombieBuddy](https://github.com/zed-0xff/ZombieBuddy) (one-time).
2. Copy the \`WorkshopBridge\` folder from \`WorkshopBridge-$VERSION.zip\`
   into the \`mods\` folder inside your Zomboid folder
   (\`~/Zomboid/mods\` on Linux, \`%USERPROFILE%\\Zomboid\\mods\` on Windows).
3. Enable it in the Mods menu like any other mod.

## Verify this download

- Zip SHA-256: \`$ZIP_SHA\`
- VirusTotal: $VT_LINK
  (shows a scan report once the file has been uploaded there at least once)
- Jar SHA-256: \`$JAR_SHA\` (ZBS-signed; see WorkshopBridge.jar.zbs)
EOF

echo
echo "release.sh: done."
echo "  zip:      $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "  zip sha:  $ZIP_SHA"
echo "  jar sha:  $JAR_SHA"
echo "  VT link:  $VT_LINK"
echo "  notes:    $NOTES"
echo
echo "If the VirusTotal link shows no report yet, upload the zip once at"
echo "https://www.virustotal.com/gui/home/upload - afterwards the link"
echo "above resolves to the scan for everyone."
echo
TAG="v$VERSION"
if [ -z "$ASSUME_YES" ] && command -v gh >/dev/null 2>&1; then
    if confirm "Create GitHub release $TAG and upload the zip?"; then
        gh release create "$TAG" --title "WorkshopBridge $VERSION" \
            --notes-file "$NOTES" "$ZIP"
        exit 0
    fi
fi
echo "To publish manually:"
echo "  gh release create $TAG --title \"WorkshopBridge $VERSION\" \\"
echo "    --notes-file \"$NOTES\" \"$ZIP\""
