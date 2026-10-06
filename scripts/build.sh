#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
# Xcode manages the provisioning profile needed for biometric-protected keychain access.
xcodebuild -project TouchOTP.xcodeproj -scheme TouchOTP -configuration Release \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates build \
  "DEVELOPMENT_TEAM=${TOUCHOTP_DEVELOPMENT_TEAM:-3Y5VKS8JJ5}"
app="$PWD/build/DerivedData/Build/Products/Release/TouchOTP.app"
codesign --verify --strict "$app"
ditto "$app" "$PWD/build/TouchOTP.app"
printf 'Built %s\n' "$PWD/build/TouchOTP.app"
