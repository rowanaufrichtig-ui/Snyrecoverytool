#!/usr/bin/env bash
# Builds "Xperia Rescue.app" as a universal (Apple silicon + Intel) app with
# newflasher and libusb inside, then packages it as a .zip and a .dmg in dist/.
#
# Requirements: macOS 13+, Xcode command line tools (swift, clang), git, curl.
#
# Environment overrides:
#   VERSION=1.2.0            app version (default 1.0.0)
#   BUILD_NUMBER=42          bundle build number (default 1)
#   CODESIGN_IDENTITY="Developer ID Application: ..."   default "-" (ad-hoc)
#   NEWFLASHER_COMMIT=<sha>  newflasher revision to build
#   LIBUSB_VERSION=1.0.30
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Xperia Rescue"
EXECUTABLE="XperiaRescue"
BUNDLE_ID="io.github.snyrecoverytool.xperiarescue"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
NEWFLASHER_REPO="https://github.com/munjeni/newflasher.git"
NEWFLASHER_COMMIT="${NEWFLASHER_COMMIT:-59f12e437d29f0385eb27dcebba5158aa3f97b45}"
LIBUSB_VERSION="${LIBUSB_VERSION:-1.0.30}"
MACOS_MIN="13.0"
ARCHS=(arm64 x86_64)

WORK="$ROOT/.build-app"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "error: build-app.sh must run on macOS." >&2
    exit 1
fi

mkdir -p "$WORK" "$DIST"

# ---------------------------------------------------------------- libusb
LIBUSB="$WORK/libusb-$LIBUSB_VERSION"
if [[ ! -f "$LIBUSB/lib/libusb-1.0.0.dylib" ]]; then
    echo "==> Building libusb $LIBUSB_VERSION"
    tarball="$WORK/libusb-$LIBUSB_VERSION.tar.bz2"
    curl -fsSL --retry 3 -o "$tarball" \
        "https://github.com/libusb/libusb/releases/download/v$LIBUSB_VERSION/libusb-$LIBUSB_VERSION.tar.bz2"
    slices=()
    for arch in "${ARCHS[@]}"; do
        src="$WORK/libusb-src-$arch"
        prefix="$WORK/libusb-install-$arch"
        rm -rf "$src" "$prefix"
        mkdir -p "$src"
        tar -xjf "$tarball" -C "$src" --strip-components 1
        host="x86_64-apple-darwin"
        [[ "$arch" == "arm64" ]] && host="aarch64-apple-darwin"
        (
            cd "$src"
            ./configure --host="$host" --prefix="$prefix" --enable-shared --disable-static \
                CC="clang -arch $arch" \
                CFLAGS="-O2 -mmacosx-version-min=$MACOS_MIN" \
                LDFLAGS="-mmacosx-version-min=$MACOS_MIN" >"$WORK/libusb-configure-$arch.log"
            make -j"$NCPU" >"$WORK/libusb-make-$arch.log"
            make install >/dev/null
        )
        slices+=("$prefix/lib/libusb-1.0.0.dylib")
    done
    rm -rf "$LIBUSB"
    mkdir -p "$LIBUSB/lib" "$LIBUSB/include"
    lipo -create "${slices[@]}" -output "$LIBUSB/lib/libusb-1.0.0.dylib"
    install_name_tool -id "@rpath/libusb-1.0.0.dylib" "$LIBUSB/lib/libusb-1.0.0.dylib"
    cp -R "$WORK/libusb-install-${ARCHS[0]}/include/libusb-1.0" "$LIBUSB/include/"
    cp "$WORK/libusb-src-${ARCHS[0]}/COPYING" "$LIBUSB/COPYING"
fi

# ------------------------------------------------------------ newflasher
NF_SRC="$WORK/newflasher-src"
if [[ ! -d "$NF_SRC/.git" ]]; then
    echo "==> Fetching newflasher"
    git clone --quiet "$NEWFLASHER_REPO" "$NF_SRC"
fi
if ! git -C "$NF_SRC" cat-file -e "$NEWFLASHER_COMMIT^{commit}" 2>/dev/null; then
    git -C "$NF_SRC" fetch --quiet origin
fi
git -C "$NF_SRC" -c advice.detachedHead=false checkout --quiet "$NEWFLASHER_COMMIT"
NF_VERSION="$(sed -n 's/^#define VERSION //p' "$NF_SRC/version.h" | tr -d '[:space:]')"
echo "==> Building newflasher v$NF_VERSION ($(git -C "$NF_SRC" rev-parse --short HEAD))"
nf_slices=()
for arch in "${ARCHS[@]}"; do
    out="$WORK/newflasher-$arch"
    # newflasher is old-style C; keep modern clang's stricter defaults as warnings.
    clang -arch "$arch" -mmacosx-version-min="$MACOS_MIN" -O2 -w \
        -Wno-error=implicit-function-declaration -Wno-error=int-conversion \
        -Wno-error=incompatible-pointer-types -Wno-error=incompatible-function-pointer-types \
        -I"$LIBUSB/include/libusb-1.0" \
        "$NF_SRC/newflasher.c" -o "$out" \
        "$LIBUSB/lib/libusb-1.0.0.dylib" -lz -lexpat \
        -Wl,-rpath,@executable_path/../Frameworks
    nf_slices+=("$out")
done
lipo -create "${nf_slices[@]}" -output "$WORK/newflasher"

# ------------------------------------------------------------------ app
echo "==> Building the Swift app"
swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT" --product "$EXECUTABLE"
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT" --show-bin-path)"

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$WORK/newflasher" "$APP/Contents/MacOS/newflasher"
cp "$LIBUSB/lib/libusb-1.0.0.dylib" "$APP/Contents/Frameworks/"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
echo "v$NF_VERSION ($(git -C "$NF_SRC" rev-parse --short HEAD))" >"$APP/Contents/Resources/newflasher-version.txt"
if [[ -f "$ROOT/LICENSE" ]]; then
    cp "$ROOT/LICENSE" "$APP/Contents/Resources/Licenses/XperiaRescue-LICENSE.txt"
fi
cp "$NF_SRC/LICENSE" "$APP/Contents/Resources/Licenses/newflasher-LICENSE.txt"
cp "$LIBUSB/COPYING" "$APP/Contents/Resources/Licenses/libusb-COPYING.txt"
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD_NUMBER/" -e "s/@BUNDLE_ID@/$BUNDLE_ID/" \
    "$ROOT/Resources/Info.plist.in" >"$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing (identity: $SIGN_IDENTITY)"
sign_flags=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    sign_flags+=(--options runtime --timestamp)
fi
codesign "${sign_flags[@]}" "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
codesign "${sign_flags[@]}" "$APP/Contents/MacOS/newflasher"
codesign "${sign_flags[@]}" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Smoke test"
lipo -archs "$APP/Contents/MacOS/$EXECUTABLE"
lipo -archs "$APP/Contents/MacOS/newflasher"
linked_libraries="$(otool -L "$APP/Contents/MacOS/newflasher")"
if ! grep -q "@rpath/libusb-1.0.0.dylib" <<<"$linked_libraries"; then
    echo "error: newflasher is not linked against the bundled libusb" >&2
    exit 1
fi
# With no phone attached newflasher must start, load libusb and report that no device is connected.
smoke_dir="$(mktemp -d)"
smoke_output="$(cd "$smoke_dir" && "$APP/Contents/MacOS/newflasher" Dump-trim-area 2>&1 || true)"
rm -rf "$smoke_dir"
sed -n '1,8p' <<<"$smoke_output"
if ! grep -q "by Munjeni" <<<"$smoke_output"; then
    echo "error: bundled newflasher did not start" >&2
    exit 1
fi
if grep -qi "dyld\|Library not loaded" <<<"$smoke_output"; then
    echo "error: bundled newflasher could not load libusb" >&2
    exit 1
fi

echo "==> Packaging"
ZIP="$DIST/XperiaRescue-$VERSION-macOS.zip"
DMG="$DIST/XperiaRescue-$VERSION-macOS.dmg"
rm -f "$ZIP" "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
staging="$WORK/dmg"
rm -rf "$staging"
mkdir -p "$staging"
cp -R "$APP" "$staging/"
ln -s /Applications "$staging/Applications"
for attempt in 1 2 3; do
    if hdiutil create -volname "$APP_NAME" -srcfolder "$staging" -ov -format UDZO "$DMG" >/dev/null; then
        break
    fi
    echo "hdiutil failed (attempt $attempt), retrying…" >&2
    sleep 5
    [[ "$attempt" == 3 ]] && exit 1
done

echo
echo "Built:"
echo "  $APP"
echo "  $ZIP"
echo "  $DMG"
