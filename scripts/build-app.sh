#!/bin/sh
# Builds Sundog and packages it as build/Sundog.app with an ad-hoc signature.
set -eu

cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)

APP=build/Sundog.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Sundog" "$APP/Contents/MacOS/Sundog"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The official icon is not part of this repository. Set SUNDOG_ICON to an .icns file to include one.
if [ -n "${SUNDOG_ICON:-}" ]; then
    cp "$SUNDOG_ICON" "$APP/Contents/Resources/AppIcon.icns"
fi
# The official brand picture for the waiting screen. Set SUNDOG_BRAND_IMAGE to a PNG file to include one.
if [ -n "${SUNDOG_BRAND_IMAGE:-}" ]; then
    cp "$SUNDOG_BRAND_IMAGE" "$APP/Contents/Resources/Brand.png"
fi

codesign --force --sign - "$APP"
echo "Built $APP"
