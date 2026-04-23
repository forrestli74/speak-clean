#!/usr/bin/env bash
#
# Build a release .app bundle for SpeakClean and ad-hoc sign it.
# Output: build/SpeakClean.app
#
# Override the version: VERSION=0.2.0 scripts/build-app.sh
#
# For testing TCC permission persistence across updates:
#   1. Build, copy to /Applications, grant mic + input-monitoring +
#      accessibility, use the app.
#   2. Rebuild (any source change), copy to /Applications replacing the
#      old bundle, relaunch, see whether permissions still work.
#
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
APP_NAME="SpeakClean"
# Bundle ID must NOT equal the UserDefaults suite name in PersonalLibrary.swift
# ("local.speakclean") — macOS refuses `UserDefaults(suiteName:)` when the
# suite name matches the caller's bundle ID.
BUNDLE_ID="io.github.forrestli74.speak-clean"
EXECUTABLE="speak-clean"
MIN_MACOS="26.0"

APP_DIR="build/${APP_NAME}.app"

echo "==> swift build -c release"
swift build -c release --arch arm64

BUILT_BIN="$(swift build -c release --arch arm64 --show-bin-path)/${EXECUTABLE}"
if [[ ! -f "$BUILT_BIN" ]]; then
    echo "error: built binary not found at $BUILT_BIN" >&2
    exit 1
fi

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILT_BIN" "$APP_DIR/Contents/MacOS/${EXECUTABLE}"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>${APP_NAME} records microphone audio to transcribe dictation.</string>
</dict>
</plist>
EOF

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --verbose=2 "$APP_DIR"

echo ""
echo "built $APP_DIR (version $VERSION)"
echo ""
echo "to install and test:"
echo "  cp -R $APP_DIR /Applications/"
echo "  open /Applications/${APP_NAME}.app"
