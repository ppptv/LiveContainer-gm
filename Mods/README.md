# Mods — QuickBar overlay + packaging

This folder holds the parts of the mod that live **outside** the Xcode project:
the two injected dylibs and the scripts that turn a Release build into
sideloadable ipas.

## Which build script to use

### build_from_baseline.sh — RECOMMENDED for self-install / self-update

```sh
./Mods/build_from_baseline.sh          # auto version, newest full IPA as baseline
./Mods/build_from_baseline.sh 70       # explicit version
```

This builds both variants from the **verified v67 binary baseline**: it takes a
known-good full IPA and only re-signs/repackages it, so the signing components
stay byte-identical to v67. Use this when you rely on installing/updating
LiveContainer from the built-in SideStore ("self-install"). It verifies the
baseline hashes before building and refuses a drifted baseline.

Why: `build_all.sh` recompiles from source, which swaps ZSign / TweakLoader /
SideStoreSupport / main binary to freshly-built versions. On iOS 26 that broke
self-install. v45–v67 all shipped the SAME ZSign (`b467ceffe77543da`); only the
source rebuild changed it. If you need source changes (e.g. a UI tweak), use
`build_all.sh`, but expect self-install to need re-verification.

### build_all.sh — build BOTH variants from source

```sh
./Mods/build_all.sh          # auto version = (newest vN) + 1
./Mods/build_all.sh 69       # explicit version
```

One command compiles the injected dylibs, runs `xcodebuild` (unsigned), then
produces **both** variants for the same source/build:

1. `LiveContainer+SideStore-...-vN.ipa` — full build with built-in SideStore.
2. `LiveContainer-独立版-无SideStore-vN.ipa` — same build with SideStore stripped,
   for developer-certificate signing.

Both land in the delivery folder (`~/…/QuickBar/`). The script verifies each
one (zip, codesign, QuickBar injection, CoreData fix, gallery symbols, weak
links) and refuses to overwrite an existing version.

### assets/SideStoreApp.framework

The built-in SideStore is **checked in** here so every build uses the exact same
verified binary — no nightly download / dylibify step. It is SideStore 0.7.0,
`SideStore` binary SHA256 prefix `075a8f72ce543932`, carrying the
`INCREASED_MEMORY_LIMIT` / `bundleIdCapabilities` fix so a free Apple ID still
gets the higher memory limit. `build_all.sh` refuses to run if this hash drifts.

## QuickBar/

| file | what it is |
|---|---|
| `QuickBar.m` | guest-app overlay: a dark tab glued to the top edge that opens an app-switch card, so you can jump between installed apps without leaving the running one. Also carries the newer gallery/dock work. |
| `QBLayoutFix.m` | a 151-line runtime geometry patch for the **shipped** `QuickBar.dylib`. Built separately, loaded next to it. |
| `Makefile` | builds both dylibs with the Xcode toolchain only, no Theos. |
| `inject_dylib.py` | inserts `LC_LOAD_WEAK_DYLIB` commands into `TweakLoader.dylib` in place. Idempotent and self-healing (it removes the old `LC_RPATH` entries produced by the buggy version). |

Build them:

```sh
make -C Mods/QuickBar all fix      # -> QuickBar.dylib, QBLayoutFix.dylib (ad-hoc signed)
```

`QuickBar.dylib` is **not** rebuilt from `QuickBar.m` in the current lineage:
the binary that has been shipping on device for days predates the `.m` file in
this folder (it has four classes the `.m` no longer has, and vice versa).
`QBLayoutFix.m` exists precisely to patch the shipped binary's geometry at
runtime instead of swapping the whole overlay UI. If you want to rebuild from
`QuickBar.m`, expect the overlay UI to change.

## package.sh

```sh
xcodebuild -project LiveContainer.xcodeproj -scheme LiveContainer \
           -configuration Release -sdk iphoneos -derivedDataPath Build \
           CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
           OTHER_SWIFT_FLAGS=-disable-sandbox

./Mods/package.sh Build/Build/Products/Release-iphoneos/LiveContainer.app
```

`OTHER_SWIFT_FLAGS=-disable-sandbox` is not optional in sandboxed shells: the
Swift macro plugin server aborts with `sandbox_apply: Operation not permitted`
and the build dies with ~1500 bogus `could not be found` errors.

The script copies the `.app`, drops both dylibs into `Frameworks/`, adds
`SideStoreApp.framework`, injects the weak links into `TweakLoader.dylib`,
signs inside-out (nested frameworks first, then the shell) and zips.

### SideStoreApp.framework

It is not produced by the Xcode project — LiveContainer's CI dylibifies the
SideStore nightly into a framework whose executable is called `SideStore` and
whose install name is `@executable_path/SideStore.dylib`. Extract one from an
official release ipa:

```sh
unzip -o LiveContainer.ipa 'Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/*' -d vendor
mv vendor/Payload/LiveContainer.app/Frameworks/SideStoreApp.framework vendor/
SIDESTORE_FW=vendor/SideStoreApp.framework ./Mods/package.sh
```

Without it the build still packages, but the built-in SideStore is gone and the
ipa drops from ~33.8 MB to ~6.9 MB — that is the tell-tale of a half-filled
package.

Signing is ad-hoc (no entitlements, no team), same as the official CI ipa,
which is also unsigned (`zip` + `ldid -S""`). Both must be re-signed by
SideStore/AltStore before installing.

## strip_sidestore.sh — SideStore-free variant

For every full build, produce a standalone LiveContainer with the built-in
SideStore removed (e.g. to sign with your own developer certificate):

```sh
./Mods/strip_sidestore.sh                         # newest v*.ipa -> ...-无SideStore.ipa
./Mods/strip_sidestore.sh in.ipa out.ipa          # explicit names
```

No source change is needed: `sideStoreExist` is resolved at runtime by checking
whether `Frameworks/SideStoreApp.framework` exists, so removing that one
directory automatically hides every SideStore entry in the UI. The script
drops the framework, re-signs inside out, and verifies zip integrity, codesign,
zero SideStore residue, and survival of the QuickBar injection / CoreData fix /
gallery symbols. Output lands next to the source by default (ad-hoc signed).

Expected size: ~6.6 MB (vs ~33.8 MB with SideStore). Note the resulting bundle
still declares HealthKit, increased-memory-limit, get-task-allow, 128 keychain
groups and two app groups in its entitlements — your App ID must enable those
capabilities or the developer-certificate signature will be rejected.
