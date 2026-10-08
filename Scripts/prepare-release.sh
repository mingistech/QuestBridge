#!/bin/bash
set -euo pipefail
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity or certificate SHA-1.}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if [[ ! -x Vendor/platform-tools/adb || ! -f Vendor/platform-tools/NOTICE.txt ]]; then
  echo 'Bundle official Platform Tools using Scripts/bundle-adb.sh before preparing a release.' >&2
  exit 1
fi
mkdir -p dist
if [[ -e dist/QuestBridge.app ]]; then
  echo 'dist/QuestBridge.app already exists. Move the previous release aside before preparing another.' >&2
  exit 1
fi
xcodebuild -project QuestBridge.xcodeproj -scheme QuestBridge \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/release CODE_SIGNING_ALLOWED=NO \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO ENABLE_DEBUG_DYLIB=NO build
/usr/bin/ditto build/release/Build/Products/Release/QuestBridge.app dist/QuestBridge.app
# Sign every bundled Mach-O, including Platform Tools executables and their libraries,
# before sealing the containing app. Do not use --deep to sign nested code.
while IFS= read -r -d '' item; do
  if /usr/bin/file -b "$item" | /usr/bin/grep -q 'Mach-O'; then
    /usr/bin/codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$item"
  fi
done < <(/usr/bin/find dist/QuestBridge.app -type f -print0)
/usr/bin/codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" dist/QuestBridge.app
/usr/bin/codesign --verify --deep --strict --verbose=2 dist/QuestBridge.app
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/QuestBridge.app/Contents/Info.plist)
/usr/bin/ditto -c -k --sequesterRsrc --keepParent dist/QuestBridge.app "dist/QuestBridge-${version}-macOS.zip"
echo "Signed archive prepared: dist/QuestBridge-${version}-macOS.zip"
echo 'Submit to Apple, wait for Accepted, staple the app, and rebuild the ZIP before publishing.'
