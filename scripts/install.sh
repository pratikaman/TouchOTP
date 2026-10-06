#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/TouchOTP.app"
destination="$HOME/Applications/TouchOTP.app"
if [ ! -d "$app" ]; then
  printf 'Build the app first with ./scripts/build.sh\n' >&2
  exit 1
fi
codesign --verify --strict "$app"
if [ -e "$destination" ]; then
  identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist")
  if [ "$identifier" != 'local.touchotp.mac' ]; then
    printf 'A different app already exists at %s. It was left untouched.\n' "$destination" >&2
    exit 1
  fi
  if pgrep -f "$destination/Contents/MacOS/TouchOTP" >/dev/null; then
    printf 'Quit TouchOTP from its menu bar before reinstalling.\n' >&2
    exit 1
  fi
fi
mkdir -p "$HOME/Applications"
ditto "$app" "$destination"
codesign --verify --strict "$destination"
printf 'Installed %s\n' "$destination"
