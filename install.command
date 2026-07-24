#!/bin/bash
# Double-click this to install Flaunch.
# It copies the app into /Applications, clears the macOS "unidentified
# developer" quarantine flag so it opens on a normal double-click, and launches it.
set -euo pipefail

APP_NAME="Flaunch"
APP_BUNDLE="${APP_NAME}.app"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/${APP_BUNDLE}"
DEST="/Applications/${APP_BUNDLE}"

pause() { [[ -t 0 ]] && read -n 1 -s -r -p "Press any key to close this window." || true; echo; }

clear 2>/dev/null || true
echo "Installing ${APP_NAME}…"
echo

if [[ ! -d "${SRC}" ]]; then
    echo "❌  Couldn't find \"${APP_BUNDLE}\" next to this installer."
    echo "    Unzip the download first, and keep this installer in the same"
    echo "    folder as the app, then double-click it again."
    echo
    pause
    exit 1
fi

# Quit any running copy so the bundle can be replaced cleanly.
osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true

echo "→ Copying to /Applications…"
if [[ -w /Applications ]]; then
    rm -rf "${DEST}"
    cp -R "${SRC}" "${DEST}"
else
    # Non-admin or locked /Applications: ask for an admin password via a GUI prompt.
    echo "  (administrator permission needed for /Applications)"
    osascript -e "do shell script \"rm -rf '${DEST}' && cp -R '${SRC}' '${DEST}'\" with administrator privileges"
fi

echo "→ Cleaning up and clearing the quarantine flag so it opens without a warning…"
# Some unzip tools scatter AppleDouble (._*) sidecar files inside the bundle, which
# breaks the code-signature seal — remove them so the app stays valid.
find "${DEST}" -name '._*' -delete 2>/dev/null || true
# Clear all extended attributes (quarantine, provenance, …) so Gatekeeper won't prompt.
xattr -cr "${DEST}" 2>/dev/null || true

echo "→ Launching…"
open "${DEST}"

echo
echo "✅  Installed to /Applications and launched."
echo "    Look for the terminal icon in your menu bar (top-right of the screen)."
echo "    Click it, then choose the folder that holds your projects."
echo
pause
