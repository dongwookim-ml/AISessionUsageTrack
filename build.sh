#!/bin/bash
# Build the SwiftPM executable and wrap it in a .app bundle so macOS treats
# it as a real menubar app (LSUIElement=true => no dock icon).
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="AISessionUsageTrack"
APP_DIR="${APP_NAME}.app"
CONFIG="${1:-release}"

echo ">>> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_PATH=".build/${CONFIG}/${APP_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
  echo "Build did not produce ${BIN_PATH}" >&2
  exit 1
fi

echo ">>> assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Info.plist "${APP_DIR}/Contents/Info.plist"

# Ad-hoc sign so WebKit / cookie storage work without Gatekeeper complaints.
codesign --force --deep --sign - "${APP_DIR}" >/dev/null

echo ">>> done: ${APP_DIR}"
echo "Launch with:  open ${APP_DIR}"
