---
title: Building DroidDock from source
---

[← Home](index.md)

## Prerequisites

- Xcode 26 or later, on an Apple silicon Mac
- [Homebrew](https://brew.sh), then:

```bash
brew install libmtp xcodegen
```

## Build and run

```bash
git clone https://github.com/abehan7/droiddock.git
cd droiddock
xcodegen generate          # project.yml -> DroidDock.xcodeproj
open DroidDock.xcodeproj   # then ⌘R
```

`project.yml` is the source of truth for the Xcode project; edit it rather than the
`.xcodeproj`, then run `xcodegen generate` again.

## How libmtp is linked

- **Debug** builds load `libmtp` straight from `/opt/homebrew/lib`.
- **Release** builds run `scripts/embed-dylibs.sh`, which copies `libmtp` and its dependency
  `libusb` into `DroidDock.app/Contents/Frameworks`, rewrites their install names to `@rpath`
  and signs them, so the app runs on Macs without Homebrew.

The app is not sandboxed (the sandbox blocks raw USB access and writing to arbitrary folders),
and library validation is off because the Homebrew dylibs aren't signed by the same team.

## Make the DMG

```bash
scripts/make-dmg.sh
```

This builds Release and writes `dist/DroidDock-<version>.dmg` with the drag-to-Applications
window. The window layout lives in `scripts/dmg/settings.py` and is built by
[dmgbuild](https://github.com/dmgbuild/dmgbuild), which the script installs into `build/dmgbuild-venv`
on first run. The background is `scripts/dmg/background.png` (+ `@2x`), drawn from
`design/dmg-background.svg`; keep it light, because Finder always draws the icon labels in black.
The version comes from `MARKETING_VERSION` in `project.yml`.

Releases are ad-hoc signed (`CODE_SIGN_IDENTITY: "-"`). To ship a notarized build, set a
Developer ID identity and team in `project.yml`, then notarize the DMG with `xcrun notarytool`.

## Debugging

- Set the environment variable `LIBMTP_DEBUG=9` in the scheme to log all MTP traffic.
- Run with the `-demo` argument to use the built-in fake phone.
- In Terminal, `mtp-detect` (from libmtp) should print the phone's model when MTP works.

## Code layout

| File | Role |
| --- | --- |
| `PhoneEngine.swift` | The protocol both connection types implement |
| `MTPEngine.swift` | Every libmtp call, on one serial queue |
| `ADBEngine.swift`, `ADB.swift` | The adb connection: folder listings, transfers, thumbnails |
| `BrowserModel.swift` | `@MainActor` app state: connection, folder, selection, transfers |
| `USBWatcher.swift` | IOKit plug/unplug notifications for Samsung (`0x04E8`) |
| `ContentView.swift` | Window, sidebar, toolbar, item menu, path and transfer bars |
| `BrowserViews.swift` | Icons, List, Columns and Gallery views; thumbnails and previews |
| `WiFiConnectView.swift` | Wireless-debugging pairing (built, hidden behind `BrowserModel.wifiEnabled`) |
| `DemoPhone.swift` | Fake phone for `-demo` |
| `DroidDockApp.swift` | Entry point and menus; releases the phone on quit |
