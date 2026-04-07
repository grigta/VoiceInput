#!/bin/bash
set -euo pipefail

APP_NAME="VoiceInput"
BUILD_DIR=".build/release"
BUNDLE_DIR="${BUILD_DIR}/${APP_NAME}.app"

echo "Building ${APP_NAME} in release mode..."
swift build -c release

echo "Assembling .app bundle..."
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

# Copy binary
cp "${BUILD_DIR}/${APP_NAME}" "${BUNDLE_DIR}/Contents/MacOS/"

# Copy Info.plist
cp Resources/Info.plist "${BUNDLE_DIR}/Contents/"

# Copy Metal shader bundles (whisper.cpp builds these as SPM resources)
find "${BUILD_DIR}" -name "*.bundle" -maxdepth 2 | while read -r bundle; do
    echo "Copying resource bundle: ${bundle}"
    cp -R "${bundle}" "${BUNDLE_DIR}/Contents/Resources/"
done

# Ad-hoc code sign
codesign --force --sign - "${BUNDLE_DIR}"

echo ""
echo "Built successfully: ${BUNDLE_DIR}"
echo ""
echo "To run: open ${BUNDLE_DIR}"
echo "Or:     ${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"
