#!/bin/bash
# Produce a SideStore-free IPA from a LiveContainer IPA that has SideStoreApp.framework.
#
# Usage:
#   ./Mods/strip_sidestore.sh [input.ipa] [output.ipa]
#
# With no arguments, the newest *v*.ipa in the workspace QuickBar folder is used
# and the output is named "...-无SideStore-vNN.ipa" next to the input.
#
# What it does:
#   1. unzip the source IPA
#   2. remove Frameworks/SideStoreApp.framework (runtime sideStoreExist() then
#      hides every SideStore UI entry automatically; no source change needed)
#   3. re-sign inside out (dylibs -> nested frameworks -> frameworks -> appex -> app)
#   4. zip, then verify: zip integrity, codesign, no SideStore left, and that
#      the QuickBar injection / CoreData fix / gallery symbols survived
#
# The output is ad-hoc signed, same as the official CI ipa. Re-sign with your
# developer certificate before installing. See Mods/README.md for the
# entitlements your App ID must enable.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DELIVERY="/Volumes/MacHD/wb 项目目录/spaces/2026_11_20_01-16-25/QuickBar"

SRC="${1:-}"
OUT="${2:-}"

if [ -z "$SRC" ]; then
    SRC=$(ls -t "$DELIVERY"/*v*.ipa 2>/dev/null | grep -v '无SideStore' | head -1 || true)
    [ -n "$SRC" ] || { echo "no source ipa found in $DELIVERY"; exit 1; }
fi
[ -f "$SRC" ] || { echo "source ipa not found: $SRC"; exit 1; }

if [ -z "$OUT" ]; then
    base=$(basename "$SRC" .ipa)
    # carry the source version into the stripped name; caller can override OUT
    # to bump to a new version number.
    OUT="$DELIVERY/${base}-无SideStore.ipa"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
echo "=== source: $SRC ($(du -h "$SRC" | cut -f1)) ==="
unzip -qo "$SRC" -d "$WORK"
APP="$WORK/Payload/LiveContainer.app"
[ -d "$APP" ] || { echo "bad ipa: no Payload/LiveContainer.app"; exit 1; }

FW="$APP/Frameworks/SideStoreApp.framework"
[ -d "$FW" ] || { echo "source has no SideStoreApp.framework, nothing to strip"; exit 1; }
echo "--- remove SideStoreApp.framework ($(du -sh "$FW" | cut -f1)) ---"
rm -rf "$FW"

sign() { codesign -f -s - --timestamp=none "$1" >/dev/null 2>&1 || { echo "SIGN FAIL: $1"; exit 1; }; }
fwbin() {
    local e
    e=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$1/Info.plist" 2>/dev/null || true)
    [ -n "$e" ] && [ -f "$1/$e" ] && echo "$1/$e"
}

# Capture the main executable's entitlements BEFORE re-signing. Signing the
# app bundle recurses into the main binary and strips them; we restore after.
ENT_TMP="$WORK/main_ent.xml"
codesign -d --entitlements :- "$APP/LiveContainer" 2>/dev/null > "$ENT_TMP" || true
HAS_ENT=0
grep -q 'com.apple.developer.team-identifier' "$ENT_TMP" && HAS_ENT=1

echo "--- re-sign inside out ---"
# app bundle FIRST (it recurses into main), then nested components
sign "$APP"
for ext in "$APP"/PlugIns/*.appex; do
    [ -d "$ext" ] || continue
    bin="$ext/$(basename "$ext" .appex)"
    [ -f "$bin" ] && sign "$bin"
    sign "$ext"
done
for fw in "$APP"/Frameworks/*.framework; do
    for nested in "$fw"/Frameworks/*.framework; do
        [ -d "$nested" ] || continue
        b=$(fwbin "$nested"); [ -n "$b" ] && sign "$b"
        sign "$nested"
    done
    b=$(fwbin "$fw"); [ -n "$b" ] && sign "$b"
    sign "$fw"
done
while IFS= read -r -d '' f; do sign "$f"; done < <(find "$APP/Frameworks" -maxdepth 1 -name '*.dylib' -print0)

# main binary LAST, re-apply captured entitlements
if [ "$HAS_ENT" = "1" ]; then
    codesign -f -s - --timestamp=none --entitlements "$ENT_TMP" "$APP/LiveContainer" >/dev/null 2>&1 || {
        echo "SIGN FAIL main with entitlements"; exit 1; }
    echo "  OK main entitlements preserved"
else
    sign "$APP/LiveContainer"
fi

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
(cd "$WORK" && zip -qry "$OUT" Payload)

echo "=== verify ==="
unzip -tq "$OUT" >/dev/null || { echo "ZIP FAIL"; exit 1; }
codesign -v --deep --strict "$APP" 2>/dev/null || { echo "CODESIGN FAIL"; exit 1; }
left=$(find "$APP" -iname '*SideStoreApp*' | wc -l | tr -d ' ')
[ "$left" = "0" ] || { echo "SideStore residue: $left"; exit 1; }
for req in QuickBar.dylib QBLayoutFix.dylib SideStoreSupport.framework; do
    [ -e "$APP/Frameworks/$req" ] || { echo "MISSING $req"; exit 1; }
done
cdfix=$(strings "$APP/Frameworks/LiveContainerShared.framework/LiveContainerShared" | grep -c 'Library/Application Support' || true)
[ "${cdfix:-0}" -ge 1 ] || { echo "CoreData fix missing"; exit 1; }
gsym=$(nm "$APP/Frameworks/LiveContainerSwiftUI.framework/LiveContainerSwiftUI" 2>/dev/null | grep -cE 'nintendoQueries|lcMakeURL|trailingSuffixNumber' || true)
[ "${gsym:-0}" -ge 1 ] || { echo "gallery symbols missing"; exit 1; }
weak=$(otool -l "$APP/Frameworks/TweakLoader.dylib" | grep -c LC_LOAD_WEAK_DYLIB || true)
[ "${weak:-0}" -ge 6 ] || { echo "weak links only $weak"; exit 1; }

echo "zip OK / codesign OK / SideStore 0 / QuickBar+fix OK / CoreData fix OK / gallery $gsym syms / weak $weak"
echo "=== result ==="
ls -lh "$OUT"
shasum -a 256 "$OUT"
