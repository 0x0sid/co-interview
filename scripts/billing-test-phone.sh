#!/bin/sh
# Builds the Debug app as a **billing test build** and, with DEVICE set, installs it over the app on
# that phone (an in-place install: interviews, files and settings are kept).
#
# NEVERBLANK_INSTALLATION_ACCESS=YES is baked into the build's Info.plist, so the app registers an
# installation, runs RevenueCat on the server-issued identity and is checked by the backend exactly as
# Release is — also after an ordinary launch from the home screen. It still uses the Debug RevenueCat
# key from Local-Debug.xcconfig (the Test Store); Release refuses that key.
#
#   DEVICE=<devicectl identifier> scripts/billing-test-phone.sh
set -eu
cd "$(dirname "$0")/.."
DERIVED="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/neverblank-billing-test}"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*' \
  xcodebuild build -project co-interview.xcodeproj -scheme Co-Interview -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
  NEVERBLANK_INSTALLATION_ACCESS=YES -quiet
APP="$DERIVED/Build/Products/Debug-iphoneos/prompter.app"
echo "commit:              $(/usr/libexec/PlistBuddy -c 'Print :GitCommitHash' "$APP/Info.plist")"
echo "installation access: $(/usr/libexec/PlistBuddy -c 'Print :NeverblankInstallationAccess' "$APP/Info.plist")"
if [ -n "${DEVICE:-}" ]; then
  xcrun devicectl device install app --device "$DEVICE" "$APP"
fi
