#!/bin/bash
# Builds a Release DroidDock.app and packs it into dist/DroidDock-<version>.dmg with the
# drag-to-Applications window (layout in scripts/dmg/settings.py, built by dmgbuild).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(awk -F'"' '/MARKETING_VERSION/ { print $2; exit }' project.yml)"
APP=build/Build/Products/Release/DroidDock.app
DMG="dist/DroidDock-$VERSION.dmg"
VENV=build/dmgbuild-venv

xcodegen generate
xcodebuild -scheme DroidDock -configuration Release -derivedDataPath build build | tail -1

if [ ! -x "$VENV/bin/dmgbuild" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet dmgbuild
fi

mkdir -p dist
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s scripts/dmg/settings.py -D app="$APP" "DroidDock $VERSION" "$DMG"
echo "$DMG"
