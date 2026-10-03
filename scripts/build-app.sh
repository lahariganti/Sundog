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

codesign --force --sign - "$APP"
echo "Built $APP"
