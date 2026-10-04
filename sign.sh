#!/usr/bin/env bash
# sign.sh - ZBS-sign the WorkshopBridge release jar (ZombieBuddy Ed25519 scheme).
#
# A signed mod is WorkshopBridge.jar plus a WorkshopBridge.jar.zbs sidecar:
#   ZBS
#   SteamID64:<author steam id>
#   Signature:<ed25519 signature hex>
# signing the canonical payload "ZBS:<SteamID64>:<JAR_SHA256>".
# ZombieBuddy verifies the sidecar at mod load; users can trust the author
# identity once and auto-approve future signed jars. See
# https://github.com/zed-0xff/ZombieBuddy/blob/master/doc/ModSigning.md
#
# The script is fully automatic after first run:
#   - Ed25519 keypair is generated into $WB_SIGNING_DIR (default ~/.signing)
#     if missing. The private key never leaves that directory and is never
#     committed to the repo.
#   - On the first run you are asked for your SteamID64; it is saved next to
#     the key (machine-local, not in the repo) for all future runs.
#
# Usage:
#   ./sign.sh [path/to/WorkshopBridge.jar]
# Writes <jar>.zbs next to the jar. Re-run after every rebuild; a stale
# .zbs will not validate a rebuilt jar.
#
# Env:
#   WB_SIGNING_DIR  signing directory (default ~/.signing)
#   WB_STEAMID64     SteamID64 to use non-interactively (saved for later runs)
set -euo pipefail

SIGNING_DIR="${WB_SIGNING_DIR:-$HOME/.signing}"
KEY_FILE="$SIGNING_DIR/workshopbridge-ed25519.der"
ID_FILE="$SIGNING_DIR/workshopbridge-steamid64"
PUB_FILE="$SIGNING_DIR/workshopbridge-ed25519.pub.hex"

JAR="${1:-WorkshopBridge/42/media/java/WorkshopBridge.jar}"

die() { echo "sign.sh: error: $*" >&2; exit 1; }

command -v openssl >/dev/null 2>&1 || die "openssl not found on PATH (needed for Ed25519 keygen/signing)"
command -v od >/dev/null 2>&1 || die "od not found on PATH (coreutils)"
# hexdump helper: raw bytes on stdin -> lowercase hex on one line, no spaces
hexdump_one_line() { od -A n -v -t x1 | tr -d ' \n'; }
[ -f "$JAR" ] || die "jar not found: $JAR (build it first, e.g. ./compile.sh)"

mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"

# 1. Private key: generate once, keep it private.
if [ ! -f "$KEY_FILE" ]; then
    echo "sign.sh: generating new Ed25519 keypair in $SIGNING_DIR ..."
    openssl genpkey -algorithm ed25519 -outform DER -out "$KEY_FILE"
    chmod 600 "$KEY_FILE"
fi

# 2. Public key hex, derived from the private key and cached.
#    openssl emits a 44-byte SubjectPublicKeyInfo for Ed25519; the raw
#    32-byte key is the tail of it.
if [ ! -f "$PUB_FILE" ]; then
    SPKI_LEN="$(openssl pkey -in "$KEY_FILE" -inform DER -pubout -outform DER | wc -c)"
    [ "$SPKI_LEN" -eq 44 ] || die "unexpected Ed25519 public key length ($SPKI_LEN bytes)"
    openssl pkey -in "$KEY_FILE" -inform DER -pubout -outform DER \
        | tail -c 32 | hexdump_one_line > "$PUB_FILE"
    chmod 600 "$PUB_FILE"
fi
PUB_HEX="$(cat "$PUB_FILE")"
[ "${#PUB_HEX}" -eq 64 ] || die "bad cached public key in $PUB_FILE"

# 3. SteamID64: env, then saved file, then ask once and save.
STEAMID="${WB_STEAMID64:-}"
if [ -z "$STEAMID" ] && [ -f "$ID_FILE" ]; then
    STEAMID="$(tr -d '[:space:]' < "$ID_FILE")"
fi
if [ -z "$STEAMID" ]; then
    printf 'sign.sh: no SteamID64 saved yet.\n'
    printf 'Enter your SteamID64 (find it at steamid.io or in your Steam client): '
    IFS= read -r STEAMID || STEAMID=""
fi
STEAMID="$(printf '%s' "$STEAMID" | tr -d '[:space:]')"
case "$STEAMID" in
    ''|*[!0-9]*)
        die "SteamID64 must be digits only, got: '$STEAMID'" ;;
esac
# ZombieBuddy's verifier requires exactly 17 digits (^SteamID64:(\d{17})$);
# anything else makes the .zbs invalid, so fail here instead of shipping one.
[ "${#STEAMID}" -eq 17 ] || die "SteamID64 must be exactly 17 digits, got ${#STEAMID}: '$STEAMID'"
if [ ! -f "$ID_FILE" ]; then
    printf '%s' "$STEAMID" > "$ID_FILE"
    chmod 600 "$ID_FILE"
    echo "sign.sh: saved SteamID64 to $ID_FILE"
fi

# 4. Sign the canonical payload "ZBS:<SteamID64>:<JAR_SHA256>".
#    (via a temp file: pkeyutl -rawin cannot size piped stdin)
SHA="$(sha256sum "$JAR" | cut -d' ' -f1)"
PAYLOAD_FILE="$(mktemp "${TMPDIR:-/tmp}/zbs-payload.XXXXXX")"
trap 'rm -f "$PAYLOAD_FILE"' EXIT
printf 'ZBS:%s:%s' "$STEAMID" "$SHA" > "$PAYLOAD_FILE"
SIG_HEX="$(openssl pkeyutl -sign -inkey "$KEY_FILE" -keyform DER -rawin \
    -in "$PAYLOAD_FILE" | hexdump_one_line)"
[ "${#SIG_HEX}" -eq 128 ] || die "unexpected signature length (${#SIG_HEX} hex chars)"

ZBS_FILE="${JAR}.zbs"
printf 'ZBS\nSteamID64:%s\nSignature:%s\n' "$STEAMID" "$SIG_HEX" > "$ZBS_FILE"

echo "sign.sh: signed $JAR"
echo "sign.sh: wrote $ZBS_FILE"
echo "sign.sh: publish this public key once so ZombieBuddy can verify you:"
echo "  add to Steam profile summary: JavaModZBS:${PUB_HEX}"
echo "  (or PR it into ZombieBuddy's authors/ directory to keep the profile private)"
