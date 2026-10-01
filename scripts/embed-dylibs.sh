#!/bin/bash
# Step 7, self-contained route: copy libmtp + libusb into the app's Frameworks
# folder and point every load path at @rpath, so the app no longer needs Homebrew.
set -euo pipefail

# Debug builds load libmtp straight from Homebrew; only Release/Archive is self-contained.
[ "$CONFIGURATION" = Release ] || exit 0

BREW="${HOMEBREW_PREFIX:-/opt/homebrew}"
FW="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
BIN="$TARGET_BUILD_DIR/$EXECUTABLE_PATH"   # main executable
SIGN="${EXPANDED_CODE_SIGN_IDENTITY:--}"

# Install names as Homebrew wrote them (versions change between releases).
MTP_SRC="$(otool -D "$BREW/lib/libmtp.dylib" | tail -1)"
USB_SRC="$(otool -L "$MTP_SRC" | awk '/libusb/ { print $1 }')"
MTP="$(basename "$MTP_SRC")"
USB="$(basename "$USB_SRC")"

# Prepare the copies in a scratch folder, never inside the bundle: a DroidDock that's
# running while this builds has these dylibs mapped, and rewriting them in place makes
# macOS kill it ("Code Signature Invalid" on the next page it loads).
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
for lib in "$MTP_SRC" "$USB_SRC"; do
  cp -fL "$lib" "$WORK/"
  chmod u+w "$WORK/$(basename "$lib")"
done

install_name_tool -id "@rpath/$MTP" "$WORK/$MTP"
install_name_tool -id "@rpath/$USB" "$WORK/$USB"
install_name_tool -change "$USB_SRC" "@rpath/$USB" "$WORK/$MTP"
codesign --force --sign "$SIGN" "$WORK/$MTP" "$WORK/$USB"

# Swap in only what changed, with a rename (a new file, so a running copy keeps its old one).
mkdir -p "$FW"
for name in "$MTP" "$USB"; do
  if ! cmp -s "$WORK/$name" "$FW/$name"; then
    mv -f "$WORK/$name" "$FW/$name"
  fi
done

install_name_tool -change "$MTP_SRC" "@rpath/$MTP" "$BIN"   # Xcode signs $BIN after this phase
