#!/bin/sh
# Builds a signed and notarized Sundog ZIP for Apple silicon and Intel Macs.
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
#   SUNDOG_ICON            An .icns file for the app icon. Without it, macOS shows the default icon.
#   SUNDOG_BRAND_IMAGE     A PNG for the waiting screen. Without it, the waiting screen shows only text.
#
# Options:
#   --skip-notarize  Test the packaging without notarization.
set -eu

cd "$(dirname "$0")/.."

IDENTITY="${SUNDOG_SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${SUNDOG_NOTARY_PROFILE:-sundog-notary}"
NOTARIZE=1
for option in "$@"; do
    case "$option" in
        --skip-notarize) NOTARIZE=0 ;;
        *) echo "Unknown option: $option" >&2; exit 2 ;;
    esac
done

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
APP=build/Sundog.app
ARCHIVE="build/Sundog-$VERSION.zip"

# 1. Build a universal binary and the app bundle.
swift build -c release --arch arm64 --arch x86_64
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Sundog" "$APP/Contents/MacOS/Sundog"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
# The official icon is not part of this repository. Set SUNDOG_ICON to an .icns file to include one.
if [ -n "${SUNDOG_ICON:-}" ]; then
    cp "$SUNDOG_ICON" "$APP/Contents/Resources/AppIcon.icns"
fi
# The official brand picture for the waiting screen. Set SUNDOG_BRAND_IMAGE to a PNG file to include one.
if [ -n "${SUNDOG_BRAND_IMAGE:-}" ]; then
    cp "$SUNDOG_BRAND_IMAGE" "$APP/Contents/Resources/Brand.png"
fi

# 2. Sign the app with the hardened runtime and a secure timestamp.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
# 3. Submit the app in a ZIP, then attach the ticket to the app.
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
if [ "$NOTARIZE" -eq 1 ]; then
    xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
    rm -f "$ARCHIVE"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
else
    echo "Notarization skipped. macOS can block this app on other Macs."
fi

echo "Built $ARCHIVE"
