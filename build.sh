#!/bin/bash
# Builds "Sweep.app".  Usage: ./build.sh [--install]
#   --install   installs the app to /Applications (the only copy kept) and launches it
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Sweep.app"

# The macOS 27 SDK implements @State as a macro whose plugin ships only with full Xcode.
# With Command Line Tools alone, build against the newest SDK that still uses the property wrapper.
if [ -z "${SDKROOT:-}" ] && [ ! -d /Applications/Xcode.app ]; then
  for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk; do [ -d "$sdk" ] && export SDKROOT="$sdk"; done
fi

swift build -c release

if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make_icon.swift Resources
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Sweep "$APP/Contents/MacOS/Sweep"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Prefer the stable local identity (see scripts/make_signing_identity.sh) so macOS keeps the app's
# permissions across rebuilds; fall back to an ad-hoc signature when it is missing or unusable.
IDENTITY="Sweep Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\"" \
   && perl -e 'alarm 60; exec @ARGV' codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "Signed with \"$IDENTITY\""
else
  codesign --force --deep --sign - "$APP"
  echo "Signed ad hoc (run scripts/make_signing_identity.sh once for a stable identity)"
fi
echo "Built: $APP"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app "Sweep"' 2>/dev/null || true
  rm -rf "/Applications/Sweep.app"
  cp -R "$APP" /Applications/
  rm -rf build   # keep a single copy of the app: the one in /Applications
  echo "Installed to /Applications/Sweep.app"
  open "/Applications/Sweep.app"
fi
