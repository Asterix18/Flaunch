#!/bin/bash
# Generates AppIcon.icns from generate-icon.swift.
# Run this once (or whenever the icon design changes).
set -euo pipefail

cd "$(dirname "$0")"

SRC_PNG="icon_1024.png"
ICONSET_DIR="AppIcon.iconset"
ICNS_OUT="AppIcon.icns"

echo "→ Rendering source PNG…"
swift generate-icon.swift "${SRC_PNG}"

echo "→ Building iconset…"
rm -rf "${ICONSET_DIR}"
mkdir -p "${ICONSET_DIR}"

# Apple's required iconset sizes for macOS .icns
declare -a SIZES=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

for entry in "${SIZES[@]}"; do
    px="${entry%%:*}"
    name="${entry##*:}"
    sips -z "${px}" "${px}" "${SRC_PNG}" --out "${ICONSET_DIR}/${name}" >/dev/null
done

echo "→ Compiling .icns…"
iconutil --convert icns "${ICONSET_DIR}" --output "${ICNS_OUT}"

# Clean up intermediates — keep only the .icns
rm -rf "${ICONSET_DIR}" "${SRC_PNG}"

echo "✓ Built: $(pwd)/${ICNS_OUT}"
