#!/bin/bash
set -euo pipefail

APP_NAME="VoiceInput"
BUILD_DIR=".build/release"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
DMG_NAME="${1:-${APP_NAME}.dmg}"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"

if [ ! -d "${APP_PATH}" ]; then
    echo "Error: ${APP_PATH} not found. Run scripts/bundle.sh first."
    exit 1
fi

# Remove old DMG if exists
rm -f "${DMG_PATH}"

echo "Creating DMG: ${DMG_NAME}..."

# Check if create-dmg is available for pretty DMG
if command -v create-dmg &>/dev/null; then
    create-dmg \
        --volname "${APP_NAME}" \
        --volicon "Resources/VoiceInput.icns" \
        --background "Resources/dmg-background.png" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --icon-size 160 \
        --icon "${APP_NAME}.app" 170 190 \
        --app-drop-link 490 190 \
        --hide-extension "${APP_NAME}.app" \
        --no-internet-enable \
        "${DMG_PATH}" \
        "${APP_PATH}" \
    || true  # create-dmg returns 2 on success without code signing
else
    # Fallback: simple DMG with hdiutil
    DMG_TEMP=$(mktemp -d)
    cp -R "${APP_PATH}" "${DMG_TEMP}/"
    ln -s /Applications "${DMG_TEMP}/Applications"
    hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_TEMP}" -ov -format UDZO "${DMG_PATH}"
    rm -rf "${DMG_TEMP}"
fi

if [ -f "${DMG_PATH}" ]; then
    echo ""
    echo "DMG created: ${DMG_PATH}"
    ls -lh "${DMG_PATH}"
else
    echo "Error: DMG was not created"
    exit 1
fi
