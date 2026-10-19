#!/bin/zsh
# Builds build/ScreenBrightness.app. Pass "install" to copy it to /Applications,
# or "notarize" to notarize it for other Macs.
#
# Signing: set SIGNING_IDENTITY (a certificate name or SHA-1 from `security find-identity -v -p codesigning`)
# and DEVELOPMENT_TEAM to sign with your own Developer ID, so macOS keeps the Accessibility
# permission across rebuilds. Without a matching certificate the app is signed ad hoc, which
# works, but macOS asks for Accessibility again after every rebuild.
set -euo pipefail
cd "${0:A:h}"

SIGNING_IDENTITY="${SIGNING_IDENTITY:-4D342BEA1039EF3ABCA370BDCBD694B78526A617}" # Developer ID Application: Jesper Mol
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-9WFDLY652Y}"

if security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
  SIGNING=(CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" OTHER_CODE_SIGN_FLAGS="--timestamp")
else
  echo "Signing identity not found; signing ad hoc."
  SIGNING=(CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Manual)
fi

[[ -d ScreenBrightness/Assets.xcassets/AppIcon.appiconset ]] || swift scripts/make-icon.swift .
xcodegen generate --quiet

xcodebuild -project ScreenBrightness.xcodeproj -scheme ScreenBrightness -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData -quiet \
  "${SIGNING[@]}" build

rm -rf build/ScreenBrightness.app
cp -R build/DerivedData/Build/Products/Release/ScreenBrightness.app build/
codesign --verify --strict --deep build/ScreenBrightness.app
echo "Built build/ScreenBrightness.app"

# Notarizing lets the app open on other Macs without a Gatekeeper warning. It needs a stored
# notarytool profile, created once with:
#   xcrun notarytool store-credentials ScreenBrightness --apple-id <id> --team-id 9WFDLY652Y
if [[ "${1:-}" == "notarize" ]]; then
  NOTARY_PROFILE="${NOTARY_PROFILE:-ScreenBrightness}"
  ditto -c -k --keepParent build/ScreenBrightness.app build/ScreenBrightness.zip
  xcrun notarytool submit build/ScreenBrightness.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple build/ScreenBrightness.app
  ditto -c -k --keepParent build/ScreenBrightness.app build/ScreenBrightness.zip
  spctl -a -vv build/ScreenBrightness.app
  echo "Notarized build/ScreenBrightness.app (zipped at build/ScreenBrightness.zip)"
fi

if [[ "${1:-}" == "install" ]]; then
  pkill -x ScreenBrightness 2>/dev/null || true
  rm -rf /Applications/ScreenBrightness.app
  cp -R build/ScreenBrightness.app /Applications/
  open /Applications/ScreenBrightness.app
  echo "Installed /Applications/ScreenBrightness.app"
fi
