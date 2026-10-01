#!/bin/bash
# Builds a Release DroidDock.app and packs it into dist/DroidDock-<version>.dmg
# (drag-to-Applications layout, plus the license files).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(awk -F'"' '/MARKETING_VERSION/ { print $2; exit }' project.yml)"
APP=build/Build/Products/Release/DroidDock.app
DMG="dist/DroidDock-$VERSION.dmg"

xcodegen generate
xcodebuild -scheme DroidDock -configuration Release -derivedDataPath build build | tail -1

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/Licenses"
cp LICENSE THIRD_PARTY_NOTICES.md licenses/*.txt "$STAGE/Licenses/"

mkdir -p dist
rm -f "$DMG"
hdiutil create -volname "DroidDock $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "$DMG"
