#!/bin/zsh
# Builds ScreenBrightness.app signed with Developer ID, so macOS keeps the
# Accessibility permission across rebuilds. Pass "install" to copy it to /Applications.
set -euo pipefail
cd "${0:A:h}"

SIGNING_IDENTITY="${SIGNING_IDENTITY:-4D342BEA1039EF3ABCA370BDCBD694B78526A617}" # Developer ID Application: Jesper Mol

[[ -d ScreenBrightness/Assets.xcassets/AppIcon.appiconset ]] || swift scripts/make-icon.swift .
xcodegen generate --quiet

xcodebuild -project ScreenBrightness.xcodeproj -scheme ScreenBrightness -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData -quiet \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp" build

rm -rf build/ScreenBrightness.app
cp -R build/DerivedData/Build/Products/Release/ScreenBrightness.app build/
codesign --verify --strict --deep build/ScreenBrightness.app
echo "Built build/ScreenBrightness.app"

if [[ "${1:-}" == "install" ]]; then
  pkill -x ScreenBrightness 2>/dev/null || true
  rm -rf /Applications/ScreenBrightness.app
  cp -R build/ScreenBrightness.app /Applications/
  open /Applications/ScreenBrightness.app
  echo "Installed /Applications/ScreenBrightness.app"
fi
