#!/bin/bash
# Build Flaunch.app — a clickable macOS app bundle.
# Pass --install to also copy the bundle to /Applications.
set -euo pipefail

cd "$(dirname "$0")"

INSTALL=0
DIST=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --dist)    DIST=1 ;;
        -h|--help)
            echo "Usage: $0 [--install] [--dist]"
            echo "  --install   Copy the built bundle to /Applications/"
            echo "  --dist      Package the app + install.command into a shareable zip"
            exit 0
            ;;
    esac
done

APP_NAME="Flaunch"
BIN_NAME="Flaunch"
BUNDLE_ID="com.georgegoodwin.flaunch"
APP_DIR="${APP_NAME}.app"
# Shown in Settings → Advanced; bump when cutting a release.
APP_VERSION="1.1.0"

echo "→ Building release binary…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${BIN_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
    echo "Build failed: binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "→ Assembling ${APP_DIR}…"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${BIN_NAME}"

ICON_SRC="icon/AppIcon.icns"
if [[ -f "${ICON_SRC}" ]]; then
    cp "${ICON_SRC}" "${APP_DIR}/Contents/Resources/AppIcon.icns"
    ICON_PLIST_ENTRY=$'    <key>CFBundleIconFile</key>\n    <string>AppIcon</string>'
else
    echo "  (no icon at ${ICON_SRC} — run icon/build-icon.sh to generate one)"
    ICON_PLIST_ENTRY=""
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${BIN_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
${ICON_PLIST_ENTRY}
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Used to open Terminal and run "claude" in the folder you select.</string>
</dict>
</plist>
PLIST

cat > "${APP_DIR}/Contents/PkgInfo" <<<"APPL????"

echo "→ Ad-hoc code signing…"
codesign --force --deep --sign - "${APP_DIR}" >/dev/null

echo "✓ Built: ${PWD}/${APP_DIR}"

if [[ "${INSTALL}" -eq 1 ]]; then
    INSTALL_PATH="/Applications/${APP_DIR}"
    echo "→ Installing to ${INSTALL_PATH}…"
    # Quit any running instance so we can replace the bundle cleanly.
    osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
    rm -rf "${INSTALL_PATH}"
    cp -R "${APP_DIR}" "${INSTALL_PATH}"
    echo "✓ Installed: ${INSTALL_PATH}"
    echo "  Launch with: open \"${INSTALL_PATH}\""
else
    echo "  Double-click it, or run: open \"${APP_DIR}\""
    echo "  To install to /Applications: $0 --install"
fi

if [[ "${DIST}" -eq 1 ]]; then
    ZIP_NAME="${APP_NAME}.zip"
    echo "→ Packaging ${ZIP_NAME} (app + install.command)…"
    if [[ ! -f "install.command" ]]; then
        echo "Packaging failed: install.command not found next to this script." >&2
        exit 1
    fi
    # Stage both items inside a folder named for the product so the zip
    # unpacks to a single tidy folder holding the app and the installer.
    STAGE="$(mktemp -d)/${APP_NAME}"
    mkdir -p "${STAGE}"
    cp -R "${APP_DIR}" "${STAGE}/"
    cp "install.command" "${STAGE}/install.command"
    chmod +x "${STAGE}/install.command"          # ditto preserves this exec bit
    # Strip extended attributes (e.g. com.apple.provenance) so the zip carries no
    # AppleDouble metadata. Otherwise a plain `unzip` materializes it as ._ sidecar
    # files inside the bundle, which breaks the code-signature seal.
    xattr -cr "${STAGE}/${APP_DIR}"
    rm -f "${ZIP_NAME}"
    ditto -c -k --keepParent "${STAGE}" "${ZIP_NAME}"
    rm -rf "$(dirname "${STAGE}")"
    echo "✓ Packaged: ${PWD}/${ZIP_NAME}"
    echo "  Share this zip. Recipients unzip it and double-click install.command."
fi
