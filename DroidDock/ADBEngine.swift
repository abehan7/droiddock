import Foundation
import ImageIO
import AppKit

/// Talks to a phone through `adb` (USB debugging or Wi-Fi "Wireless debugging").
///
/// Unlike MTP, one shell command lists a whole folder with names, sizes and dates, so
/// big folders read in a second instead of one request per file. Files are addressed by
/// path on the phone; this engine hands the rest of the app stable UInt32 IDs for them.
final class ADBEngine: PhoneEngine, @unchecked Sendable {
    let serial: String

    private let lock = NSLock()
    private var paths: [UInt32: String] = [:]      // ID → absolute path on the phone
    private var ids: [String: UInt32] = [:]
    private var items: [UInt32: PhoneItem] = [:]   // details from the last listing
    private var roots: [UInt32: String] = [:]      // storage ID → its root folder
    private var nextID: UInt32 = 1
    private var mediaIDs: [String: UInt64] = [:]          // path → MediaStore _id, for thumbnails
    private var mediaScans: [String: Task<Void, Never>] = [:]   // one bulk lookup per folder
    private let thumbnailSlots = AsyncLimiter(4)          // don't spawn an adb per visible tile at once

    var listsDetailsUpFront: Bool { true }

    init(serial: String) {
        self.serial = serial
    }

    // MARK: Connection

    func connect() async throws -> (name: String, storages: [PhoneStorage]) {
        let state = try await adb(["get-state"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        if state == "unauthorized" {
            throw MTPError.failed("Tap “Allow” on the phone's debugging prompt, then connect again.")
        }
        guard state == "device" else { throw MTPError.failed("The phone isn't reachable over adb (\(state)).") }

        var name = try await shell("settings get global device_name").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "null" {
            name = try await shell("getprop ro.product.model").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (name.isEmpty ? "Android phone" : name, try await refreshStorages())
    }

    func disconnect() async {}   // the adb connection stays up; nothing is held exclusively
    func shutdown() {}

    func refreshStorages() async throws -> [PhoneStorage] {
        // Internal storage, plus SD cards mounted as /storage/XXXX-XXXX.
        let extra = try await shell("ls /storage").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "emulated" && $0 != "self" }
        let mounts = ["/storage/emulated/0"] + extra.map { "/storage/\($0)" }
        var storages: [PhoneStorage] = []
        for (index, mount) in mounts.enumerated() {
            let id = UInt32(index + 1) << 16 | 1
            lock.withLock { roots[id] = mount }
            // "Filesystem 1K-blocks Used Available Use% Mounted-on"; the mount column can be a
            // parent (/storage/emulated), so ask about one path at a time and take its line.
            let df = (try? await shell("df -k \(Self.quote(mount))")) ?? ""
            let line = df.split(whereSeparator: \.isNewline).last
            let columns = line?.split(separator: " ", omittingEmptySubsequences: true) ?? []
            let total = columns.count > 3 ? (UInt64(columns[1]) ?? 0) * 1024 : 0
            let free = columns.count > 3 ? (UInt64(columns[3]) ?? 0) * 1024 : 0
            storages.append(PhoneStorage(id: id, name: index == 0 ? "Internal storage" : "SD card",
                                         freeBytes: free, capacityBytes: total))
        }
        return storages
    }

    // MARK: Browsing

    func list(storage: UInt32, folder: UInt32) async throws -> [PhoneItem] {
        try await metadata(for: childIDs(storage: storage, folder: folder))
    }

    /// One `stat` over the folder's contents: every name, type, size and date in one reply.
    func childIDs(storage: UInt32, folder: UInt32) async throws -> [UInt32] {
        let dir = try path(of: folder, storage: storage)
        let output = try await shell("cd \(Self.quote(dir)) && stat -c '%F|%s|%Y|%n' -- * .* 2>/dev/null; true")
        var result: [UInt32] = []
        lock.withLock {
            for line in output.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count == 4 else { continue }
                let name = String(parts[3])
                guard name != ".", name != "..", name != "*", name != ".*" else { continue }
                let isFolder = parts[0] == "directory"
                let id = idLocked(for: dir == "/" ? "/\(name)" : "\(dir)/\(name)")
                items[id] = PhoneItem(
                    id: id, parentID: folder, storageID: storage, name: name,
                    size: isFolder ? 0 : UInt64(parts[1]) ?? 0,
                    modified: Date(timeIntervalSince1970: TimeInterval(parts[2]) ?? 0),
                    isFolder: isFolder)
                result.append(id)
            }
        }
        return result
    }

    func metadata(for ids: [UInt32]) async throws -> [PhoneItem] {
        lock.withLock { ids.compactMap { items[$0] } }
    }

    // MARK: Previews

    /// Android's media database keeps a thumbnail for every photo and video; one bulk
    /// query per folder maps paths to media IDs, then each thumbnail is one read.
    /// Falls back to the EXIF thumbnail inside a JPEG's first 128 KB.
    func thumbnail(for itemID: UInt32) async -> Data? {
        guard !Task.isCancelled, let (path, item) = lock.withLock({ paths[itemID].flatMap { p in items[itemID].map { (p, $0) } } }),
              item.hasThumbnail else { return nil }
        await thumbnailSlots.acquire()
        defer { Task { await thumbnailSlots.release() } }
        guard !Task.isCancelled else { return nil }

        if let mediaID = await mediaID(for: path) {
            let collection = item.kind == .movie ? "video" : "images"
            let uri = "content://media/external/\(collection)/media/\(mediaID)/thumbnail"
            if let data = try? await adb(["exec-out", "content read --uri \(Self.quote(uri))"]).data,
               NSImage(data: data) != nil {
                return data
            }
        }
        return await exifThumbnail(path)
    }

    private func mediaID(for path: String) async -> UInt64? {
        let dir = (path as NSString).deletingLastPathComponent
        let scan: Task<Void, Never> = lock.withLock {
            if let existing = mediaScans[dir] { return existing }
            let task = Task { await self.scanMedia(in: dir) }
            mediaScans[dir] = task
            return task
        }
        await scan.value
        return lock.withLock { mediaIDs[path] }
    }

    private func scanMedia(in dir: String) async {
        let sqlDir = dir.replacingOccurrences(of: "'", with: "''")
        let query = "content query --uri content://media/external/file --projection _id:_data --where "
            + Self.quote("_data LIKE '\(sqlDir)/%'")
        guard let output = try? await shell(query) else { return }
        var found: [String: UInt64] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            // "Row: 12 _id=1000224571, _data=/storage/emulated/0/DCIM/Camera/x.mp4"
            guard let idRange = line.range(of: "_id="), let dataRange = line.range(of: ", _data=") else { continue }
            if let id = UInt64(line[idRange.upperBound..<dataRange.lowerBound]) {
                found[String(line[dataRange.upperBound...])] = id
            }
        }
        lock.withLock { mediaIDs.merge(found) { _, new in new } }
    }

    private func exifThumbnail(_ path: String) async -> Data? {
        guard ["jpg", "jpeg"].contains((path as NSString).pathExtension.lowercased()),
              let head = try? await adb(["exec-out", "head -c 131072 \(Self.quote(path))"]).data,
              let source = CGImageSourceCreateWithData(head as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageIfAbsent: false,   // only the embedded one
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 256,
              ] as CFDictionary)
        else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:])
    }

    func fetchPreview(_ item: PhoneItem, to destination: URL) async -> Bool {
        guard !Task.isCancelled else { return false }
        return (try? await download(item, to: destination, progress: { _ in })) != nil
    }

    // MARK: Transfers

    func download(_ item: PhoneItem, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let source = try path(of: item.id)
        try await watching(local: destination, total: item.size, progress: progress) {
            try await self.check(self.adb(["pull", source, destination.path]), "Couldn't download \(item.name).")
        }
    }

    func downloadFolder(_ folder: PhoneItem, into directory: URL, onFile: @escaping (String) -> Void) async throws {
        onFile(folder.name)
        try await check(adb(["pull", try path(of: folder.id), directory.path]), "Couldn't download \(folder.name).")
    }

    func upload(_ fileURL: URL, storage: UInt32, folder: UInt32, progress: @escaping (Double) -> Void) async throws {
        let dest = try path(of: folder, storage: storage) + "/" + fileURL.lastPathComponent
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        try await watching(remote: dest, total: size, progress: progress) {
            try await self.check(self.adb(["push", fileURL.path, dest]), "Couldn't upload \(fileURL.lastPathComponent).")
        }
        // Files pushed over adb don't show in Gallery until the media scanner sees them.
        let uri = "file://" + (dest.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dest)
        _ = try? await shell("am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(Self.quote(uri))")
    }

    func createFolder(named name: String, storage: UInt32, parent: UInt32) async throws -> UInt32 {
        let dir = try path(of: parent, storage: storage) + "/" + name
        try await check(adb(["shell", "mkdir \(Self.quote(dir))"]), "Couldn't create “\(name)”.")
        return lock.withLock { idLocked(for: dir) }
    }

    func delete(_ itemID: UInt32) async throws {
        let target = try path(of: itemID)
        try await check(adb(["shell", "rm -rf \(Self.quote(target))"]), "Couldn't delete that item.")
        lock.withLock {
            items[itemID] = nil
            ids[target] = nil
            paths[itemID] = nil
        }
    }

    // MARK: Internals

    private func adb(_ arguments: [String]) async throws -> ADB.Output {
        try await ADB.run(["-s", serial] + arguments)
    }

    private func shell(_ command: String) async throws -> String {
        try await check(adb(["shell", command]), "The phone didn't answer.").text
    }

    @discardableResult
    private func check(_ output: ADB.Output, _ message: String) throws -> ADB.Output {
        guard output.status == 0 else {
            throw MTPError.failed(output.error.isEmpty ? message : "\(message)\n\(output.error)")
        }
        return output
    }

    private func path(of id: UInt32, storage: UInt32? = nil) throws -> String {
        try lock.withLock {
            if id == MTPEngine.rootFolder, let storage, let root = roots[storage] { return root }
            guard let path = paths[id] else { throw MTPError.failed("That item is gone; refresh and try again.") }
            return path
        }
    }

    private func idLocked(for path: String) -> UInt32 {
        if let id = ids[path] { return id }
        let id = nextID
        nextID += 1
        ids[path] = id
        paths[id] = path
        return id
    }

    /// adb pull/push print no progress when not on a terminal, so watch the file grow.
    private func watching(local url: URL? = nil, remote: String? = nil, total: UInt64,
                          progress: @escaping (Double) -> Void,
                          _ transfer: @escaping () async throws -> Void) async throws {
        let poller = Task {
            while !Task.isCancelled, total > 0 {
                try? await Task.sleep(for: .milliseconds(remote == nil ? 250 : 700))
                var size: UInt64?
                if let url {
                    size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
                } else if let remote {
                    size = UInt64((try? await shell("stat -c %s \(Self.quote(remote)) 2>/dev/null"))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                }
                if let size { progress(min(Double(size) / Double(total), 0.99)) }
            }
        }
        defer { poller.cancel() }
        do {
            try await transfer()
            progress(1)
        } catch {
            if let url { try? FileManager.default.removeItem(at: url) }   // drop the partial file
            throw error
        }
    }

    /// Single-quotes text for the phone's shell.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A tiny async semaphore.
actor AsyncLimiter {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ slots: Int) { free = slots }

    func acquire() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { free += 1 } else { waiters.removeFirst().resume() }
    }
}
