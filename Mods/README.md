# Mods — QuickBar overlay + packaging

This folder holds the parts of the mod that live **outside** the Xcode project:
the two injected dylibs and the script that turns a Release build into a
sideloadable ipa.

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
