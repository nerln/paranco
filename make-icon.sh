#!/bin/zsh
# Builds Resources/Paranco.icns from the mark. Generated, not committed.
set -euo pipefail
cd "$(dirname "$0")"
WORK="$(mktemp -d)"; ICONSET="$WORK/Paranco.iconset"; mkdir -p Resources
swiftc -O -parse-as-library Tools/make-icon.swift -o "$WORK/make-icon"
"$WORK/make-icon" "$ICONSET"
iconutil -c icns "$ICONSET" -o Resources/Paranco.icns
echo "==> Resources/Paranco.icns"
