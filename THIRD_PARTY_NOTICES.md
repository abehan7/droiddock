# Third-party notices

DroidDock's own code is MIT-licensed (see [LICENSE](LICENSE)). The release build bundles
two libraries that keep their own license, the **GNU Lesser General Public License v2.1**:

| Library | Version in the DMG | Source | License text |
| --- | --- | --- | --- |
| [libmtp](https://github.com/libmtp/libmtp) | 1.1.23 | https://github.com/libmtp/libmtp | [licenses/libmtp-COPYING.txt](licenses/libmtp-COPYING.txt) |
| [libusb](https://github.com/libusb/libusb) | 1.0.30 | https://github.com/libusb/libusb | [licenses/libusb-COPYING.txt](licenses/libusb-COPYING.txt) |

Both are **dynamically linked**. They ship unmodified, as Homebrew builds them, in
`DroidDock.app/Contents/Frameworks/` (`libmtp.9.dylib`, `libusb-1.0.0.dylib`), and are
loaded through `@rpath`. You can swap in your own build of either library by replacing
that file and re-signing the app (`codesign --force --deep --sign - DroidDock.app`).
`scripts/embed-dylibs.sh` shows exactly how they are copied in.

These license texts also ship inside the app, in `DroidDock.app/Contents/Resources/`
(`LICENSE`, `THIRD_PARTY_NOTICES.md` and the `licenses` folder).
