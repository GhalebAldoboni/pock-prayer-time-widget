#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
BUILD_ROOT="${REPO_ROOT}/build"
WIDGET_NAME="PrayerTimeWidget"
WIDGET_BUNDLE="${BUILD_ROOT}/${WIDGET_NAME}.pock"

cd "${SCRIPT_DIR}"
swift build
BUILD_PRODUCTS_DIR="$(swift build --show-bin-path)"
PRODUCT="${BUILD_PRODUCTS_DIR}/lib${WIDGET_NAME}.dylib"

rm -rf "${WIDGET_BUNDLE}"
mkdir -p "${WIDGET_BUNDLE}/Contents/MacOS" "${WIDGET_BUNDLE}/Contents/Resources"
cp "${PRODUCT}" "${WIDGET_BUNDLE}/Contents/MacOS/${WIDGET_NAME}"
cp "${SCRIPT_DIR}/Resources/Info.plist" "${WIDGET_BUNDLE}/Contents/Info.plist"
chmod +x "${WIDGET_BUNDLE}/Contents/MacOS/${WIDGET_NAME}"

codesign --force --sign - "${WIDGET_BUNDLE}/Contents/MacOS/${WIDGET_NAME}"
codesign --force --sign - "${WIDGET_BUNDLE}"
codesign --verify --deep --strict "${WIDGET_BUNDLE}"

echo "${WIDGET_BUNDLE}"
