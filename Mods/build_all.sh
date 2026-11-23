#!/bin/bash
# One-shot build: produce BOTH variants from source in a single run.
#
#   1. LiveContainer+SideStore-...-vN.ipa   (full build, built-in SideStore 0.7.0 fixed)
#   2. LiveContainer-独立版-无SideStore-vN.ipa (SideStore removed, for cert re-signing)
#
# Usage:
#   ./Mods/build_all.sh [version]     # e.g. 69; defaults to next vN after newest ipa
#
# Pipeline:
#   make dylibs -> xcodebuild (unsigned) -> package.sh with fixed SideStore framework
#   -> strip_sidestore.sh on the result -> verify both.
#
# The SideStore framework is a checked-in asset at Mods/assets/SideStoreApp.framework,
# binary hash 075a8f72ce543932 (0.7.0, contains the INCREASED_MEMORY_LIMIT fix),
# extracted from the verified v67 build. No network / nightly download needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DELIVERY="/Volumes/MacHD/wb 项目目录/spaces/2026_11_20_01-16-25/QuickBar"
FW="$ROOT/Mods/assets/SideStoreApp.framework"
BUILD="$ROOT/Build/Build/Products/Release-iphoneos/LiveContainer.app"

# --- version ---
VER="${1:-}"
if [ -z "$VER" ]; then
    VER=$(ls "$DELIVERY"/*v[0-9]*.ipa 2>/dev/null | grep -oE 'v[0-9]+' | tr -d 'v' | sort -n | tail -1)
    VER=$(( ${VER:-67} + 1 ))
fi
[ -d "$DELIVERY" ] || { echo "delivery dir missing: $DELIVERY"; exit 1; }
[ -d "$FW" ] || { echo "SideStore asset missing: $FW"; exit 1; }
FWHASH=$(shasum -a 256 "$FW/SideStore" | awk '{print substr($1,1,16)}')
[ "$FWHASH" = "075a8f72ce543932" ] || { echo "SideStore asset hash mismatch: $FWHASH"; exit 1; }
echo "=== version v$VER, SideStore asset $FWHASH (0.7.0 fixed) ==="

OUT_FULL="$DELIVERY/LiveContainer+SideStore-内置应用切换与文件修复-大内存版-v${VER}.ipa"
OUT_BARE="$DELIVERY/LiveContainer-独立版-无SideStore-v${VER}.ipa"
[ ! -e "$OUT_FULL" ] && [ ! -e "$OUT_BARE" ] || { echo "output for v$VER already exists, pass another version"; exit 1; }

# --- 1. dylibs ---
echo "=== [1/4] build injected dylibs ==="
make -C "$ROOT/Mods/QuickBar" all fix

# --- 2a. OpenSSL xcframework (gitignored; download if missing, same as CI) ---
if [ ! -d "$ROOT/Dependencies/OpenSSL.xcframework" ]; then
    echo "=== [2a] download OpenSSL 3.6.5000 xcframework ==="
    TMP=$(mktemp -d)
    curl -sL -o "$TMP/openssl.zip" \
        https://github.com/krzyzanowskim/OpenSSL/releases/download/3.6.5000/OpenSSL.xcframework.zip
    unzip -q "$TMP/openssl.zip" -d "$ROOT/Dependencies"
    rm -rf "$TMP"
fi

# --- 2. xcodebuild (unsigned; -disable-sandbox required in sandboxed shells) ---
echo "=== [2/4] xcodebuild (unsigned) ==="
xcodebuild -project "$ROOT/LiveContainer.xcodeproj" -scheme LiveContainer \
    -configuration Release -sdk iphoneos -derivedDataPath "$ROOT/Build" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
    OTHER_SWIFT_FLAGS=-disable-sandbox >/tmp/lc_build_all.log 2>&1 || {
        echo "xcodebuild FAILED, tail of /tmp/lc_build_all.log:"; tail -30 /tmp/lc_build_all.log; exit 1; }
[ -d "$BUILD" ] || { echo "build product missing: $BUILD"; exit 1; }
echo "xcodebuild OK"

# --- 3. full variant with SideStore ---
echo "=== [3/4] package full variant (with SideStore) ==="
SIDESTORE_FW="$FW" "$ROOT/Mods/package.sh" "$BUILD" "$OUT_FULL" >/tmp/lc_pack_full.log 2>&1 || {
    echo "package.sh FAILED:"; tail -30 /tmp/lc_pack_full.log; exit 1; }
tail -6 /tmp/lc_pack_full.log

# --- 4. bare variant (strip SideStore from the full ipa) ---
echo "=== [4/4] strip SideStore -> bare variant ==="
"$ROOT/Mods/strip_sidestore.sh" "$OUT_FULL" "$OUT_BARE" >/tmp/lc_pack_bare.log 2>&1 || {
    echo "strip_sidestore.sh FAILED:"; tail -30 /tmp/lc_pack_bare.log; exit 1; }
tail -6 /tmp/lc_pack_bare.log

echo "=== DONE: both variants for v$VER ==="
ls -lh "$OUT_FULL" "$OUT_BARE"
shasum -a 256 "$OUT_FULL" "$OUT_BARE"
