#!/bin/bash
set -euo pipefail

APP_NAME="VoiceInput"
INSTALL_DIR="/Applications"

# Kill running instance
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5

# Build
echo "Building..."
cd "$(dirname "$0")/.."
swift build -c release 2>&1 | tail -1

# Bundle
BUNDLE="${INSTALL_DIR}/${APP_NAME}.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp .build/release/$APP_NAME "$BUNDLE/Contents/MacOS/"
cp Resources/Info.plist "$BUNDLE/Contents/"
[ -f Resources/VoiceInput.icns ] && cp Resources/VoiceInput.icns "$BUNDLE/Contents/Resources/"
find .build/release -name "*.bundle" -maxdepth 2 -exec cp -R {} "$BUNDLE/Contents/Resources/" \;

# Fix Metal: copy ggml-common.h into the Metal shader bundle
METAL_BUNDLE=$(find .build/release -name "whisper_whisper.bundle" -maxdepth 2 | head -1)
if [ -n "$METAL_BUNDLE" ] && [ -f vendor/whisper.cpp/ggml/src/ggml-common.h ]; then
    cp vendor/whisper.cpp/ggml/src/ggml-common.h "$METAL_BUNDLE/"
    # Also copy to Resources in app bundle
    for b in "$BUNDLE/Contents/Resources/"*.bundle; do
        [ -d "$b" ] && cp vendor/whisper.cpp/ggml/src/ggml-common.h "$b/" 2>/dev/null
    done
fi
codesign --force --deep --sign - "$BUNDLE"
xattr -cr "$BUNDLE"

echo "Installed → $BUNDLE"
echo "Launching..."
open "$BUNDLE"
