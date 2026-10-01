---
title: Install DroidDock
---

[← Home](index.md)

## Requirements

- A Mac with **Apple silicon** (M1 or later)
- **macOS 26** Tahoe or later
- An Android phone and a USB cable that carries data (not a charge-only cable)

## Install

1. Download **`DroidDock-<version>.dmg`** from the [latest release](https://github.com/abehan7/droiddock/releases/latest).
2. Open the DMG and drag **DroidDock** onto the **Applications** folder.
3. Eject the DMG.

## First launch

DroidDock is open source and isn't notarized by Apple (that needs a paid developer account),
so macOS blocks it the first time you open it:

1. Open DroidDock. macOS says it can't verify that the app is free of malware. Click **Done**.
2. Open **System Settings → Privacy & Security**.
3. Scroll down to the message about DroidDock and click **Open Anyway**.
4. Click **Open Anyway** again and enter your password.

You only do this once. If you prefer Terminal, this does the same thing:

```bash
xattr -dr com.apple.quarantine /Applications/DroidDock.app
```

You can always read the [source](https://github.com/abehan7/droiddock) or [build it yourself](building.md).

## Uninstall

Drag **DroidDock** from Applications to the Trash.

Next: [Using DroidDock →](guide.md)
