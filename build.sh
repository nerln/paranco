#!/bin/zsh
# Builds Paranco.app. No Xcode project: SwiftPM makes the executable and the
# bundle is assembled around it here, so everything stays in git as text.
set -euo pipefail
cd "$(dirname "$0")"
APP="Paranco.app"
CONF="${1:-release}"

echo "==> building ($CONF)"
swift build -c "$CONF" --disable-sandbox --product ParancoApp
BIN="$(swift build -c "$CONF" --show-bin-path)/ParancoApp"
[[ -x "$BIN" ]] || { echo "executable not found: $BIN"; exit 1 }

echo "==> assembling the bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Paranco"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/Paranco.icns ]] || ./make-icon.sh >/dev/null
cp Resources/Paranco.icns "$APP/Contents/Resources/Paranco.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: enough to run locally, and enough for the Full Disk Access
# list to identify the bundle. One thing to know: an ad-hoc signature identifies
# the binary by its hash, so every rebuild is a different application to the
# privacy database and the grant has to be given again. That is the price of not
# having a Developer ID, not a fault in the build.
codesign --force --sign - "$APP" 2>/dev/null || \
    echo "   (signing failed: the app still starts if you right-click > Open the first time)"

echo "==> done: $(pwd)/$APP"
