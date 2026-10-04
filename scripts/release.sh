#!/bin/sh
# Builds a signed and notarized Sundog DMG for Apple silicon and Intel Macs.
#
# Requirements:
#   - A "Developer ID Application" certificate in the login keychain.
#   - Notary credentials in the keychain. Make them one time with:
#       xcrun notarytool store-credentials sundog-notary \
#           --apple-id <Apple ID> --team-id <team ID> --password <app-specific password>
#
# Environment:
#   SUNDOG_SIGN_IDENTITY   The signing identity. Default: "Developer ID Application".
#   SUNDOG_NOTARY_PROFILE  The notarytool keychain profile. Default: "sundog-notary".
#
# Use --skip-notarize to test the packaging without notarization.
set -eu

cd "$(dirname "$0")/.."

IDENTITY="${SUNDOG_SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${SUNDOG_NOTARY_PROFILE:-sundog-notary}"
NOTARIZE=1
if [ "${1:-}" = "--skip-notarize" ]; then
    NOTARIZE=0
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
APP=build/Sundog.app
DMG="build/Sundog-$VERSION.dmg"
STAGING=build/dmg

# 1. Build a universal binary and the app bundle.
swift build -c release --arch arm64 --arch x86_64
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Sundog" "$APP/Contents/MacOS/Sundog"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 2. Sign the app with the hardened runtime and a secure timestamp.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# 3. Make the DMG: the app and a link to Applications.
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "Sundog" -srcfolder "$STAGING" -format UDZO -ov "$DMG"
rm -rf "$STAGING"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# 4. Notarize the DMG and attach the ticket.
if [ "$NOTARIZE" -eq 1 ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
else
    echo "Notarization skipped. macOS blocks this DMG on other Macs."
fi

echo "Built $DMG"
