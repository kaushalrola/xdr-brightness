#!/bin/bash
# Builds Brightness.app and packages it as a DMG.
#
# Signs, notarises and staples when the relevant environment variables are
# present; otherwise produces an ad-hoc signed DMG suitable for local testing.
# Used both locally and by .github/workflows/release.yml.
#
#   VERSION             version string written into Info.plist (default: 0.0.0-dev)
#   SIGN_IDENTITY       e.g. "Developer ID Application: Name (TEAMID)"
#   APPLE_ID            Apple ID for notarisation
#   APPLE_TEAM_ID       Apple Developer team ID
#   APPLE_APP_PASSWORD  app-specific password for that Apple ID
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
APP="build/Brightness.app"
DMG="build/Brightness-${VERSION}.dmg"
VOLNAME="Brightness ${VERSION}"

echo "==> building version ${VERSION}"
./Scripts/build.sh release

echo "==> stamping version into Info.plist"
plutil -replace CFBundleShortVersionString -string "${VERSION}" "${APP}/Contents/Info.plist"
plutil -replace CFBundleVersion -string "${VERSION}" "${APP}/Contents/Info.plist"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "==> signing app with Developer ID (hardened runtime)"
    codesign --force --deep --options runtime --timestamp \
             --sign "${SIGN_IDENTITY}" "${APP}"
    codesign --verify --strict --verbose=2 "${APP}"
else
    echo "==> no SIGN_IDENTITY: ad-hoc signing only (Gatekeeper will warn users)"
    codesign --force --deep --sign - "${APP}"
fi

echo "==> building DMG"
rm -f "${DMG}"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
hdiutil create -volname "${VOLNAME}" -srcfolder "${STAGE}" \
               -ov -format UDZO -quiet "${DMG}"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "==> signing DMG"
    codesign --force --sign "${SIGN_IDENTITY}" --timestamp "${DMG}"
fi

if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
    echo "==> submitting to Apple for notarisation (this can take a few minutes)"
    xcrun notarytool submit "${DMG}" \
        --apple-id "${APPLE_ID}" \
        --team-id "${APPLE_TEAM_ID}" \
        --password "${APPLE_APP_PASSWORD}" \
        --wait

    echo "==> stapling ticket"
    xcrun stapler staple "${DMG}"
    xcrun stapler validate "${DMG}"
    echo "==> notarised"
else
    echo "==> notarisation skipped (Apple credentials not provided)"
fi

echo
echo "==> ${DMG}"
ls -lh "${DMG}" | awk '{print "    " $5}'
