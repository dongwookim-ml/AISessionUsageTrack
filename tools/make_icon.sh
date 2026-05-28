#!/bin/bash
# Regenerate AppIcon.icns from tools/make_icon.swift.
# Output goes to the repo root as AppIcon.icns, which build.sh copies
# into the .app bundle's Contents/Resources/.
set -euo pipefail

cd "$(dirname "$0")"

SRC_PNG="icon-1024.png"
ICONSET="AppIcon.iconset"

echo ">>> rendering ${SRC_PNG}"
swift make_icon.swift "${SRC_PNG}"

echo ">>> building ${ICONSET}"
rm -rf "${ICONSET}"
mkdir "${ICONSET}"

# Apple's required iconset sizes (1x and 2x for each base size up to 512).
# iconutil consumes 16, 32, 128, 256, 512 (and their @2x = 32, 64, 256, 512, 1024).
declare -a BASES=(16 32 128 256 512)
for sz in "${BASES[@]}"; do
  twox=$((sz * 2))
  sips -z "${sz}"  "${sz}"  "${SRC_PNG}" --out "${ICONSET}/icon_${sz}x${sz}.png"       >/dev/null
  sips -z "${twox}" "${twox}" "${SRC_PNG}" --out "${ICONSET}/icon_${sz}x${sz}@2x.png" >/dev/null
done

echo ">>> packaging AppIcon.icns"
iconutil -c icns "${ICONSET}" -o ../AppIcon.icns
rm -rf "${ICONSET}" "${SRC_PNG}"

echo ">>> done: AppIcon.icns ($(du -h ../AppIcon.icns | cut -f1))"
