#!/bin/bash
# Build BOTH variants from the verified v67 binary baseline (NOT from source).
#
# WHY THIS EXISTS
#   build_all.sh recompiles the whole app from source. That swaps the signing
#   components (ZSign.dylib, TweakLoader.dylib, SideStoreSupport, main binary)
#   to freshly-built ones. On iOS 26 this BREAKS self-install / self-update
#   ("install LiveContainer+SideStore from the built-in SideStore"), which the
#   v67 binary baseline handles correctly. v45..v67 all shipped the SAME ZSign
#   binary (b467ceffe77543da); only the source-rebuild changed it.
#
#   This script instead takes a known-good full IPA as the binary mother and
#   only re-signs + repackages it, so every signing component stays byte-identical.
#
# Usage:
#   ./Mods/build_from_baseline.sh [version] [baseline.ipa]
#     version      output version number, e.g. 70 (default: newest + 1)
#     baseline.ipa known-good full IPA (default: newest *v*.ipa with SideStore)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DELIVERY="/Volumes/MacHD/wb 项目目录/spaces/2026_11_20_01-16-25/QuickBar"
STRIP="$ROOT/Mods/strip_sidestore.sh"

# Expected hashes of the v67-verified signing components. If the baseline
# drifts from these, refuse to build instead of silently shipping a broken base.
EXPECT_ZSIGN="b467ceffe77543da"
EXPECT_TWEAK="c24e17782fc3a867"
EXPECT_MAIN="c940b1e556560744"

VER="${1:-}"
if [ -z "$VER" ]; then
    VER=$(ls "$DELIVERY"/*v[0-9]*.ipa 2>/dev/null | grep -oE 'v[0-9]+' | tr -d 'v' | sort -n | tail -1)
    VER=$(( ${VER:-67} + 1 ))
fi

BASE="${2:-}"
if [ -z "$BASE" ]; then
    # newest full (SideStore-containing) IPA; exclude the stripped variants
    BASE=$(ls -t "$DELIVERY"/*大内存版-v[0-9]*.ipa 2>/dev/null | head -1 || true)
fi
[ -f "$BASE" ] || { echo "baseline IPA not found: $BASE"; exit 1; }
[ -d "$DELIVERY" ] || { echo "delivery dir missing: $DELIVERY"; exit 1; }

OUT_FULL="$DELIVERY/LiveContainer+SideStore-内置应用切换与文件修复-大内存版-v${VER}.ipa"
OUT_BARE="$DELIVERY/LiveContainer-独立版-无SideStore-v${VER}.ipa"
[ ! -e "$OUT_FULL" ] && [ ! -e "$OUT_BARE" ] || { echo "output for v$VER exists; pass another version"; exit 1; }

echo "=== baseline: $(basename "$BASE")  ->  v$VER ==="

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
unzip -qo "$BASE" -d "$W"
APP="$W/Payload/LiveContainer.app"
[ -d "$APP" ] || { echo "bad IPA: no Payload/LiveContainer.app"; exit 1; }

# --- verify the baseline is the known-good binary set ---
check() {
    local got
    got=$(shasum -a 256 "$APP/$1" | awk '{print substr($1,1,16)}')
    [ "$got" = "$2" ] || { echo "baseline mismatch: $1 = $got (expected $2). Refusing."; exit 1; }
    echo "  OK $1 = $got"
}
echo "--- verify baseline components ---"
check "LiveContainer" "$EXPECT_MAIN"
check "Frameworks/ZSign.dylib" "$EXPECT_ZSIGN"
check "Frameworks/TweakLoader.dylib" "$EXPECT_TWEAK"

FW="$APP/Frameworks/SideStoreApp.framework"
[ -d "$FW" ] || { echo "baseline has no SideStoreApp.framework"; exit 1; }
fwh=$(shasum -a 256 "$FW/SideStore" | awk '{print substr($1,1,16)}')
[ "$fwh" = "075a8f72ce543932" ] || { echo "SideStore not the fixed 0.7.0: $fwh"; exit 1; }
echo "  OK SideStoreApp = $fwh (0.7.0 fixed)"

# --- restore the main executable's entitlements template ---
# ROOT CAUSE of self-install CoreData crash ("NSPersistentStoreCoordinator has
# no persistent stores"): v66..v70 were rebuilt with CODE_SIGNING_ALLOWED=NO,
# so the main binary has NO embedded entitlements. self-install
# (LCUtils.m archiveIPAWithBundleName -> getExecutableEntitlementXML) reads that
# template to inject app groups into the reinstalled IPA; empty template =>
# SideStore 0.7.0 cannot reach its App Group container => CoreData store fails.
# The known-good template comes from the PR4 "big-memory" gold IPA.
ENT="$ROOT/Mods/assets/main_entitlements.xml"
[ -f "$ENT" ] || { echo "entitlements template missing: $ENT"; exit 1; }
[ "$(shasum -a 256 "$ENT" | awk '{print $1}')" = "e2348feeb876022fc3cb43d087e0c7fc86ea7cb30c9059b3a9b839f98acd0ab0" ] || {
    echo "entitlements template checksum drift"; exit 1; }

# --- re-sign inside out ---
# IMPORTANT: signing the app BUNDLE recurses into the main binary and STRIPS
# entitlements. So sign everything else first, sign the bundle, then sign the
# main binary LAST with the restored entitlements template.
sign() { codesign -f -s - --timestamp=none "$1" >/dev/null 2>&1 || { echo "SIGN FAIL: $1"; exit 1; }; }
fwbin() {
    local e
    e=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$1/Info.plist" 2>/dev/null || true)
    [ -n "$e" ] && [ -f "$1/$e" ] && echo "$1/$e"
}
echo "--- re-sign inside out ---"
sign "$APP"
for ext in "$APP"/PlugIns/*.appex; do
    [ -d "$ext" ] || continue
    bin="$ext/$(basename "$ext" .appex)"; [ -f "$bin" ] && sign "$bin"; sign "$ext"
done
for fw in "$APP"/Frameworks/*.framework; do
    [ -d "$fw" ] || continue
    for nested in "$fw"/Frameworks/*.framework; do
        [ -d "$nested" ] || continue
        b=$(fwbin "$nested"); [ -n "$b" ] && sign "$b"; sign "$nested"
    done
    b=$(fwbin "$fw"); [ -n "$b" ] && sign "$b"; sign "$fw"
done
while IFS= read -r -d '' f; do sign "$f"; done < <(find "$APP/Frameworks" -maxdepth 1 -name '*.dylib' -print0)

# main binary LAST, with entitlements
codesign -f -s - --timestamp=none --entitlements "$ENT" "$APP/LiveContainer" >/dev/null 2>&1 || {
    echo "SIGN FAIL main with entitlements"; exit 1; }
ent=$(codesign -d --entitlements :- "$APP/LiveContainer" 2>/dev/null)
echo "$ent" | grep -q 'com.apple.developer.team-identifier' || { echo "entitlements restore FAILED"; exit 1; }
echo "$ent" | grep -q 'increased-memory-limit' || { echo "entitlements restore FAILED (no memory)"; exit 1; }
echo "  OK main entitlements restored ($(echo "$ent" | wc -c | tr -d ' ') bytes)"
codesign -v --deep --strict "$APP" 2>&1 || { echo "codesign verify failed"; exit 1; }

(cd "$W" && zip -qry "$OUT_FULL" Payload)
echo "--- full variant: $(basename "$OUT_FULL") ($(du -h "$OUT_FULL" | cut -f1)) ---"

# --- bare variant ---
echo "--- strip SideStore -> bare variant ---"
"$STRIP" "$OUT_FULL" "$OUT_BARE" >/tmp/lc_base_bare.log 2>&1 || {
    echo "strip_sidestore.sh FAILED:"; tail -30 /tmp/lc_base_bare.log; exit 1; }
tail -4 /tmp/lc_base_bare.log

echo "=== DONE: v$VER (binary-identical to baseline) ==="
ls -lh "$OUT_FULL" "$OUT_BARE"
shasum -a 256 "$OUT_FULL" "$OUT_BARE"
