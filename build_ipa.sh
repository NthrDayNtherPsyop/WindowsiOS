#!/bin/bash
# Build an UNSIGNED WindowsiOS.ipa from a checkout of
# https://github.com/ammaarreshi/WindowsiOS
#
# Put this file in the repo root and run:  ./build_ipa.sh
# Output: build/WindowsiOS.ipa  (re-sign it with Sideloadly / AltStore / SideStore)
#
# Needs: Xcode with an iOS SDK that has UIHingeInteraction (iOS 27.1 SDK or newer),
#        plus Homebrew packages: xcodegen meson ninja pkg-config python
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
export PATH="/opt/homebrew/bin:$PATH"

step() { printf '\n==> %s\n' "$*"; }

step "Checking tools"
missing=0
for t in xcodebuild xcodegen meson ninja pkg-config /opt/homebrew/bin/python3 codesign zip; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing: $t"; missing=1; }
done
[ "$missing" = 0 ] || { echo "Install Xcode, then: brew install xcodegen meson ninja pkg-config python"; exit 1; }
xcodebuild -version
echo "iOS SDK: $(xcrun --sdk iphoneos --show-sdk-version)"

# glib's meson build needs the Python 'packaging' module in the interpreter
# that scripts/build_ios_deps.sh hard-codes (/opt/homebrew/bin/python3).
if ! /opt/homebrew/bin/python3 -c 'import packaging' 2>/dev/null; then
    step "Installing Python 'packaging' module"
    /opt/homebrew/bin/python3 -m pip install --quiet --break-system-packages packaging
fi

# build_ios_deps.sh applies Husk's libslirp iOS patch from $HUSK_REF/patches/.
# The default path only exists on the author's machine, so fetch the patch.
if [ -z "${HUSK_REF:-}" ]; then
    export HUSK_REF="$ROOT/work/husk_ref"
    if [ ! -s "$HUSK_REF/patches/libslirp-v4.9.1.patch" ]; then
        step "Fetching Husk libslirp patch"
        mkdir -p "$HUSK_REF/patches"
        curl -fsSL --retry 3 -o "$HUSK_REF/patches/libslirp-v4.9.1.patch" \
            https://raw.githubusercontent.com/Leviidev/Husk/main/patches/libslirp-v4.9.1.patch
    fi
fi

step "Cross-compiling libffi + glib + libslirp for iOS (slow the first time)"
if ! ./scripts/build_ios_deps.sh; then
    echo "Dependency build failed. Logs:"
    for f in work/ios_deps_build/*.log; do echo "--- $f"; tail -40 "$f"; done
    exit 1
fi

step "Building engine static library (build/ios/libwinvm.a)"
make -j"$(sysctl -n hw.ncpu)" ios-lib

step "Generating Xcode project"
xcodegen generate --spec ios/project.yml

step "Building WindowsiOS.app (Release, iphoneos, unsigned)"
# project.yml pins the author's team + provisioning profile; override all of it.
xcodebuild \
    -project ios/WindowsiOS.xcodeproj \
    -scheme WindowsiOS \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    build

APP="build/DerivedData/Build/Products/Release-iphoneos/WindowsiOS.app"
[ -d "$APP" ] || { echo "Build finished but $APP is missing"; exit 1; }

# Ad-hoc sign so the get-task-allow entitlement (needed for debugger-attached JIT)
# is embedded; sideloading tools read it when they re-sign.
step "Ad-hoc signing with project entitlements"
codesign --force --sign - --timestamp=none --entitlements ios/WindowsiOS.entitlements "$APP"

step "Packaging IPA"
rm -rf build/ipa build/WindowsiOS.ipa
mkdir -p build/ipa/Payload
cp -R "$APP" build/ipa/Payload/
( cd build/ipa && zip -qry ../WindowsiOS.ipa Payload )
rm -rf build/ipa

ls -lh build/WindowsiOS.ipa
echo "Done: $ROOT/build/WindowsiOS.ipa"
