#!/bin/bash
set -euo pipefail

APP_NAME="VoiceInput"
BUILD_DIR=".build/release"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
DMG_NAME="${1:-${APP_NAME}.dmg}"

if [ ! -d "${APP_PATH}" ]; then
    echo "Error: ${APP_PATH} not found. Run scripts/bundle.sh first."
    exit 1
fi

echo "Creating DMG: ${DMG_NAME}..."

# Create a temporary directory for DMG contents
DMG_TEMP=$(mktemp -d)
cp -R "${APP_PATH}" "${DMG_TEMP}/"

# Create a symlink to /Applications for drag-and-drop install
ln -s /Applications "${DMG_TEMP}/Applications"

# Create DMG
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_TEMP}" \
    -ov \
    -format UDZO \
    "${BUILD_DIR}/${DMG_NAME}"

# Cleanup
rm -rf "${DMG_TEMP}"

echo ""
echo "DMG created: ${BUILD_DIR}/${DMG_NAME}"
echo ""
echo "After downloading, users should run:"
echo "  xattr -cr /Applications/${APP_NAME}.app"
