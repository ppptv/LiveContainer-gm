#!/bin/bash
# Package a sideloadable ipa from an existing Release build of LiveContainer.
#
#   xcodebuild -project LiveContainer.xcodeproj -scheme LiveContainer \
#              -configuration Release -sdk iphoneos -derivedDataPath Build \
#              CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
#   OTHER_SWIFT_FLAGS=-disable-sandbox   # required in sandboxed shells, else
#                                        # SwiftUIMacros' plugin server aborts
#   ./Mods/package.sh
#
# What it does: copy the .app -> inject QuickBar.dylib / QBLayoutFix.dylib into
# TweakLoader -> put SideStoreApp.framework in Frameworks -> ad-hoc sign from
# the inside out -> zip into an .ipa.
#
# Note: TweakLoader must already carry acyclic weak links to the two dylibs.
# This script injects them if they are absent (idempotent).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/Build/Products/Release-iphoneos/LiveContainer.app}"
OUT="${2:-$ROOT/Mods/out/LiveContainer-mod.ipa}"
MODS="$ROOT/Mods/QuickBar"

# SideStoreApp.framework is not produced by the Xcode project: LiveContainer's
# CI dylibifies the SideStore nightly into a framework. Extract one from an
# official release ipa and point SIDESTORE_FW at it, e.g.
#   unzip -o LiveContainer.ipa 'Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/*' -d vendor
#   SIDESTORE_FW=vendor/Payload/LiveContainer.app/Frameworks/SideStoreApp.framework ./Mods/package.sh
SIDESTORE_FW="${SIDESTORE_FW:-$ROOT/vendor/SideStoreApp.framework}"

[ -d "$SRC" ] || { echo "no build at $SRC"; exit 1; }
[ -f "$MODS/QuickBar.dylib" ] || { echo "build the dylibs first: make -C $MODS all fix"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Payload"
cp -R "$SRC" "$WORK/Payload/LiveContainer.app"
APP="$WORK/Payload/LiveContainer.app"

echo "--- copy dylibs"
cp "$MODS/QuickBar.dylib"    "$APP/Frameworks/QuickBar.dylib"
cp "$MODS/QBLayoutFix.dylib" "$APP/Frameworks/QBLayoutFix.dylib"

if [ ! -d "$APP/Frameworks/SideStoreApp.framework" ]; then
    if [ -d "$SIDESTORE_FW" ]; then
        echo "--- add SideStoreApp.framework"
        cp -R "$SIDESTORE_FW" "$APP/Frameworks/"
        rm -rf "$APP/Frameworks/SideStoreApp.framework/_CodeSignature"
    else
        echo "!! SideStoreApp.framework missing and no SIDESTORE_FW given: building an ipa without the built-in SideStore"
    fi
fi

TL="$APP/Frameworks/TweakLoader.dylib"
echo "--- weak links before: $(otool -l "$TL" | grep -c LC_LOAD_WEAK_DYLIB || true)"
# Three load paths per dylib so it resolves whether TweakLoader is loaded from
# Frameworks/, from the app root, or from a guest container. The script skips
# paths that are already present, so re-running the packaging step is safe.
for dep in QuickBar QBLayoutFix; do
    otool -l "$TL" | grep -q "$dep.dylib" && continue
    python3 "$MODS/inject_dylib.py" "$TL" \
        "@loader_path/$dep.dylib" \
        "@executable_path/Frameworks/$dep.dylib" \
        "@loader_path/../Frameworks/$dep.dylib"
done
echo "--- weak links after:  $(otool -l "$TL" | grep -c LC_LOAD_WEAK_DYLIB || true)"

sign() { codesign -f -s - --timestamp=none "$1" >/dev/null 2>&1 || { echo "SIGN FAIL $1"; exit 1; }; }

# The executable name of a framework is not always its directory name
# (SideStoreApp.framework ships "SideStore"), so read CFBundleExecutable.
fwbin() {
    local exe
    exe=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$1/Info.plist" 2>/dev/null || true)
    [ -n "$exe" ] && [ -f "$1/$exe" ] && echo "$1/$exe"
}

echo "--- sign inside out"
while IFS= read -r -d '' f; do sign "$f"; done < <(find "$APP/Frameworks" -maxdepth 1 -name "*.dylib" -print0)

for fw in "$APP"/Frameworks/*.framework; do
    for nested in "$fw"/Frameworks/*.framework; do
        [ -d "$nested" ] || continue
        b=$(fwbin "$nested"); [ -n "$b" ] && sign "$b"
        sign "$nested"
    done
done
for fw in "$APP"/Frameworks/*.framework; do
    b=$(fwbin "$fw"); [ -n "$b" ] && sign "$b"
    sign "$fw"
done
for ext in "$APP"/PlugIns/*.appex; do
    bin="$ext/$(basename "$ext" .appex)"
    [ -f "$bin" ] && sign "$bin"
    sign "$ext"
done
sign "$APP/LiveContainer"
sign "$APP"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
(cd "$WORK" && zip -qry "$OUT" Payload)

echo "=== result"
ls -l "$OUT"
shasum -a 256 "$OUT"
unzip -tq "$OUT" >/dev/null && echo "zip OK"
codesign -v "$APP" && echo "codesign OK"
otool -l "$TL" | grep -A2 LC_LOAD_WEAK_DYLIB | grep name | sed 's/^ *//'
