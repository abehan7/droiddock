import AppKit

/// A fake phone for trying the UI without a cable: launch with `-demo`
/// (Xcode: Product → Scheme → Edit Scheme → Run → Arguments).
struct DemoPhone {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    let name = "Galaxy S25 (demo)"
    let storages = [
        PhoneStorage(id: 0x0001_0001, name: "Internal storage", freeBytes: 148_000_000_000, capacityBytes: 256_000_000_000),
        PhoneStorage(id: 0x0002_0001, name: "SD card", freeBytes: 51_000_000_000, capacityBytes: 64_000_000_000),
    ]
    private var children: [UInt32: [PhoneItem]] = [:]

    init() {
        var nextID: UInt32 = 100
        var tree: [UInt32: [PhoneItem]] = [:]
        let now = Date.now

        func add(_ name: String, in parent: UInt32, folder: Bool = false, size: UInt64 = 0, daysAgo: Double) -> UInt32 {
            nextID += 1
            tree[parent, default: []].append(PhoneItem(
                id: nextID, parentID: parent, storageID: 0x0001_0001, name: name, size: size,
                modified: now.addingTimeInterval(-daysAgo * 86_400), isFolder: folder))
            return nextID
        }

        let root = MTPEngine.rootFolder
        let dcim = add("DCIM", in: root, folder: true, daysAgo: 0.2)
        let camera = add("Camera", in: dcim, folder: true, daysAgo: 0.2)
        for i in 0..<36 {
            _ = add(String(format: "20260%d%02d_1%05d.jpg", 9 - i / 20, 28 - i % 20, 4213 + i * 37),
                    in: camera, size: UInt64(2_400_000 + i * 91_000), daysAgo: Double(i) * 2.3 + 0.1)
        }
        _ = add("20260914_183022.mp4", in: camera, size: 184_000_000, daysAgo: 17)
        _ = add("20260929_120407.mp4", in: camera, size: 96_000_000, daysAgo: 2)
        let screenshots = add("Screenshots", in: dcim, folder: true, daysAgo: 3)
        for i in 0..<8 {
            _ = add("Screenshot_202609\(20 + i)_09\(10 + i)44_KakaoTalk.png", in: screenshots,
                    size: UInt64(640_000 + i * 12_000), daysAgo: Double(10 - i))
        }
        let download = add("Download", in: root, folder: true, daysAgo: 1)
        _ = add("boarding-pass.pdf", in: download, size: 312_000, daysAgo: 1)
        _ = add("invoice-2026-09.pdf", in: download, size: 88_000, daysAgo: 6)
        _ = add("photos-export.zip", in: download, size: 1_240_000_000, daysAgo: 40)
        _ = add("app-release.apk", in: download, size: 48_000_000, daysAgo: 12)
        _ = add("meeting-notes.txt", in: download, size: 4_200, daysAgo: 0.5)
        _ = add("Documents", in: root, folder: true, daysAgo: 30)
        let music = add("Music", in: root, folder: true, daysAgo: 90)
        _ = add("voice-memo-0412.m4a", in: music, size: 3_800_000, daysAgo: 170)
        _ = add("playlist-mix.mp3", in: music, size: 9_100_000, daysAgo: 200)
        let movies = add("Movies", in: root, folder: true, daysAgo: 60)
        _ = add("trip-highlights.mp4", in: movies, size: 820_000_000, daysAgo: 60)
        let pictures = add("Pictures", in: root, folder: true, daysAgo: 8)
        let kakao = add("KakaoTalk", in: pictures, folder: true, daysAgo: 2)
        for i in 0..<6 {
            _ = add("KakaoTalk_2026092\(i)_19\(30 + i)12.jpg", in: kakao, size: UInt64(410_000 + i * 8_000), daysAgo: Double(9 - i))
        }
        _ = add("wallpaper.png", in: pictures, size: 3_100_000, daysAgo: 45)
        let recordings = add("Screen recordings", in: dcim, folder: true, daysAgo: 5)
        _ = add("Screen_Recording_20260926_101533.mp4", in: recordings, size: 42_000_000, daysAgo: 5)
        _ = add("Android", in: root, folder: true, daysAgo: 400)
        _ = add("Alarms", in: root, folder: true, daysAgo: 400)
        _ = add("Ringtones", in: root, folder: true, daysAgo: 400)
        children = tree
    }

    func list(folder: UInt32) -> [PhoneItem] {
        children[folder] ?? []
    }

    /// Real landscape photos that ship with macOS, used as the demo camera roll.
    private static let samplePhotos: [URL] = {
        let dir = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { url in
                let name = url.lastPathComponent
                return url.pathExtension == "heic"
                    && ["Big Sur", "Catalina", "Monterey", "Sonoma", "Ventura", "Sequoia", "Tahoe"].contains { name.hasPrefix($0) }
                    && !["Graphic", "Dark", "Light"].contains { name.contains($0) }
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()

    func item(_ id: UInt32) -> PhoneItem? {
        children.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    private func samplePhoto(for id: UInt32) -> URL? {
        Self.samplePhotos.isEmpty ? nil : Self.samplePhotos[Int(id) % Self.samplePhotos.count]
    }

    func thumbnail(for id: UInt32) -> Data? {
        guard let item = item(id), item.hasThumbnail else { return nil }
        if let url = samplePhoto(for: id), let image = NSImage(contentsOf: url),
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        }
        return gradientThumbnail(for: id)
    }

    /// "Downloads" a photo for the gallery preview.
    func writePreview(for id: UInt32, to destination: URL) -> Bool {
        guard let item = item(id), item.kind == .image, let source = samplePhoto(for: id) else { return false }
        try? FileManager.default.removeItem(at: destination)
        return (try? FileManager.default.copyItem(at: source, to: destination)) != nil
    }

    /// Fallback when the Mac has no desktop pictures: a gradient sky over a hill.
    private func gradientThumbnail(for id: UInt32) -> Data? {
        let size = 160
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let hue = CGFloat((id * 47) % 360) / 360
        let top = NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor
        let bottom = NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.55, alpha: 1).cgColor
        let gradient = CGGradient(colorsSpace: nil, colors: [bottom, top] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size), options: [])
        ctx.setFillColor(NSColor(white: 0.1, alpha: 0.35).cgColor)
        ctx.fillEllipse(in: CGRect(x: -40 + Int(id % 50), y: -90, width: 260, height: 150))
        ctx.setFillColor(NSColor(white: 1, alpha: 0.85).cgColor)
        ctx.fillEllipse(in: CGRect(x: 100 - Int(id % 40), y: 104, width: 22, height: 22))
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:])
    }
}
