#!/bin/sh
# Builds the Aitracker.app that goes to GitHub Releases, signed with the
# witchmymac certificate when ~/Documents/VSCode/witchmymac-release exists
# (ad hoc otherwise) and without Hardened Runtime (no paid developer account).
# Output: build/DerivedData-release/Build/Products/Release/Aitracker.app
set -eu
cd "$(dirname "$0")/.."

DERIVED=build/DerivedData-release
rm -rf "$DERIVED"

xcodebuild -project "Claude Usage.xcodeproj" -scheme "Claude Usage" -configuration Release \
  -derivedDataPath "$DERIVED" -skipMacroValidation -skipPackagePluginValidation \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO \
  build

APP="$DERIVED/Build/Products/Release/Aitracker.app"
SIGN_APP="$HOME/Documents/VSCode/witchmymac-release/sign-app.sh"
if [ -f "$SIGN_APP" ]; then
  sh "$SIGN_APP" "$APP"
else
  echo "WARNING: $SIGN_APP not found, the app stays ad hoc signed" >&2
fi
codesign --verify --deep --strict --verbose=2 "$APP"

# Don't leave a second "Aitracker" registered next to the installed one.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true

echo "Built: $APP"
lipo -archs "$APP/Contents/MacOS/Aitracker"
