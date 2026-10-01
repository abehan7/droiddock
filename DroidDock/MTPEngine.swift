import Foundation

typealias MTPDevicePtr = UnsafeMutablePointer<LIBMTP_mtpdevice_t>

/// Owns the phone connection. Every libmtp call runs on one serial queue,
/// because libmtp blocks and is not thread-safe.
final class MTPEngine: @unchecked Sendable {
    static let rootFolder: UInt32 = 0xFFFF_FFFF   // LIBMTP_FILES_AND_FOLDERS_ROOT

    private let queue = DispatchQueue(label: "droiddock.mtp", qos: .userInitiated)
    private var device: MTPDevicePtr?             // touched only on `queue`
    private let demo = DemoPhone.isEnabled ? DemoPhone() : nil

    init() {
        queue.sync { LIBMTP_Init() }
    }

    // MARK: Connection

    func connect() async throws -> (name: String, storages: [PhoneStorage]) {
        if let demo { return (demo.name, demo.storages) }
        return try await run {
            self.releaseDevice()

            var rawDevices: UnsafeMutablePointer<LIBMTP_raw_device_t>?
            var count: Int32 = 0
            let status = LIBMTP_Detect_Raw_Devices(&rawDevices, &count)
            guard status == LIBMTP_ERROR_NONE, count > 0, let rawDevices else {
                throw MTPError.noDevice
            }
            defer { free(rawDevices) }

            // Uncached: never let libmtp walk every file on the phone at connect time.
            guard let dev = LIBMTP_Open_Raw_Device_Uncached(rawDevices) else {
                throw MTPError.openFailed
            }
            self.device = dev

            let name = takeCString(LIBMTP_Get_Friendlyname(dev))
                ?? takeCString(LIBMTP_Get_Modelname(dev))
                ?? "Android phone"
            return (name, try self.readStorages(dev))
        }
    }

    func disconnect() async {
        try? await run { self.releaseDevice() }
    }

    /// Blocking version for applicationWillTerminate.
    func shutdown() {
        queue.sync { releaseDevice() }
    }

    func refreshStorages() async throws -> [PhoneStorage] {
        if let demo { return demo.storages }
        return try await run { try self.readStorages(self.requireDevice()) }
    }

    // MARK: Browsing

    func list(storage: UInt32, folder: UInt32) async throws -> [PhoneItem] {
        if let demo { return demo.list(folder: folder) }
        return try await run { try self.listSync(self.requireDevice(), storage: storage, folder: folder) }
    }

    /// The IDs of a folder's contents: one quick request, without names or sizes.
    func childIDs(storage: UInt32, folder: UInt32) async throws -> [UInt32] {
        if let demo { return demo.list(folder: folder).map(\.id) }
        return try await run {
            let dev = try self.requireDevice()
            var ids: UnsafeMutablePointer<UInt32>?
            let count = LIBMTP_Get_Children(dev, storage, folder, &ids)
            defer { free(ids) }
            if count < 0 { throw MTPError.failed(self.lastError(dev) ?? "Couldn't read that folder.") }
            guard let ids, count > 0 else { return [] }
            return Array(UnsafeBufferPointer(start: ids, count: Int(count)))
        }
    }

    /// Names, sizes and dates for a page of IDs. The phone answers one file at a time,
    /// which is what makes big folders slow, so callers ask for a page at once.
    func metadata(for ids: [UInt32]) async throws -> [PhoneItem] {
        if let demo { return ids.compactMap(demo.item) }
        return try await run {
            let dev = try self.requireDevice()
            return ids.compactMap { id in
                guard let file = LIBMTP_Get_Filemetadata(dev, id) else { return nil }
                defer { LIBMTP_destroy_file_t(file) }
                return PhoneItem(file.pointee)
            }
        }
    }

    // MARK: Downloads

    func download(_ item: PhoneItem, to destination: URL,
                  progress: @escaping (Double) -> Void) async throws {
        try await run {
            try self.getFileSync(self.requireDevice(), item, to: destination, progress: progress)
        }
    }

    func downloadFolder(_ folder: PhoneItem, into directory: URL,
                        onFile: @escaping (String) -> Void) async throws {
        try await run {
            try self.copyFolderSync(self.requireDevice(), folder, into: directory, onFile: onFile)
        }
    }

    // MARK: Previews

    /// The phone's own thumbnail (a small JPEG), or nil if it has none.
    func thumbnail(for itemID: UInt32) async -> Data? {
        if let demo { return demo.thumbnail(for: itemID) }
        return await runUnlessCancelled {
            let dev = try self.requireDevice()
            var data: UnsafeMutablePointer<UInt8>?
            var size: UInt32 = 0
            let status = LIBMTP_Get_Thumbnail(dev, itemID, &data, &size)
            defer { free(data) }
            guard status == 0, let data, size > 0 else {
                LIBMTP_Clear_Errorstack(dev)   // a missing thumbnail isn't an error worth keeping
                return nil
            }
            return Data(bytes: data, count: Int(size))
        }
    }

    /// Downloads a full file for previewing. Skipped if the caller gave up while it was queued.
    func fetchPreview(_ item: PhoneItem, to destination: URL) async -> Bool {
        if let demo { return demo.writePreview(for: item.id, to: destination) }
        return await runUnlessCancelled { () -> Bool? in
            try self.getFileSync(self.requireDevice(), item, to: destination, progress: nil)
            return true
        } ?? false
    }

    // MARK: Uploads and edits

    func upload(_ fileURL: URL, storage: UInt32, folder: UInt32,
                progress: @escaping (Double) -> Void) async throws {
        try await run {
            let dev = try self.requireDevice()
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0

            guard let meta = LIBMTP_new_file_t() else { throw MTPError.failed("Out of memory.") }
            defer { LIBMTP_destroy_file_t(meta) }        // also frees the strdup'd name
            meta.pointee.filename = strdup(fileURL.lastPathComponent)
            meta.pointee.filesize = size
            meta.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
            meta.pointee.parent_id = folder == Self.rootFolder ? 0 : folder   // 0 = storage root when sending
            meta.pointee.storage_id = storage

            let box = ProgressBox(progress)
            let status = withExtendedLifetime(box) {
                LIBMTP_Send_File_From_File(dev, fileURL.path, meta, progressCallback,
                                           Unmanaged.passUnretained(box).toOpaque())
            }
            if status != 0 {
                throw MTPError.failed(self.lastError(dev) ?? "Couldn't upload \(fileURL.lastPathComponent).")
            }
        }
    }

    func createFolder(named name: String, storage: UInt32, parent: UInt32) async throws -> UInt32 {
        try await run {
            let dev = try self.requireDevice()
            guard let cName = strdup(name) else { throw MTPError.failed("Out of memory.") }
            defer { free(cName) }
            let newID = LIBMTP_Create_Folder(dev, cName, parent == Self.rootFolder ? 0 : parent, storage)
            if newID == 0 {
                throw MTPError.failed(self.lastError(dev) ?? "Couldn't create “\(name)”.")
            }
            return newID
        }
    }

    func delete(_ itemID: UInt32) async throws {
        try await run {
            let dev = try self.requireDevice()
            if LIBMTP_Delete_Object(dev, itemID) != 0 {
                throw MTPError.failed(self.lastError(dev) ?? "Couldn't delete that item.")
            }
        }
    }

    // MARK: Internals (run only on `queue`)

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// For work nobody waits on (thumbnails, previews): when the calling task is cancelled
    /// before the queue reaches it, it never touches the phone, so scrolling past a
    /// thousand photos doesn't leave a thousand requests ahead of the next click.
    private func runUnlessCancelled<T>(_ work: @escaping () throws -> T?) async -> T? {
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            let result = try? await run { () -> T? in
                flag.isCancelled ? nil : try work()
            }
            return result ?? nil
        } onCancel: {
            flag.cancel()
        }
    }

    private func requireDevice() throws -> MTPDevicePtr {
        if demo != nil { throw MTPError.failed("The demo phone can't transfer or change files. Plug in a real phone.") }
        guard let device else { throw MTPError.notConnected }
        return device
    }

    private func releaseDevice() {
        if let device {
            LIBMTP_Release_Device(device)
            self.device = nil
        }
    }

    private func readStorages(_ dev: MTPDevicePtr) throws -> [PhoneStorage] {
        LIBMTP_Get_Storage(dev, 0)   // 0 = LIBMTP_STORAGE_SORTBY_NOTSORTED
        var result: [PhoneStorage] = []
        var node = dev.pointee.storage
        while let s = node {
            result.append(PhoneStorage(
                id: s.pointee.id,
                name: s.pointee.StorageDescription.map { String(cString: $0) } ?? "Storage",
                freeBytes: s.pointee.FreeSpaceInBytes,
                capacityBytes: s.pointee.MaxCapacity))
            node = s.pointee.next
        }
        if result.isEmpty { throw MTPError.locked }
        return result
    }

    private func listSync(_ dev: MTPDevicePtr, storage: UInt32, folder: UInt32) throws -> [PhoneItem] {
        var items: [PhoneItem] = []
        var node = LIBMTP_Get_Files_And_Folders(dev, storage, folder)
        while let file = node {
            items.append(PhoneItem(file.pointee))
            node = file.pointee.next
            LIBMTP_destroy_file_t(file)
        }
        if items.isEmpty, let message = lastError(dev) {
            throw MTPError.failed(message)   // an error, not an empty folder
        }
        return items.sorted {
            ($0.isFolder ? 0 : 1, $0.name.localizedLowercase) < ($1.isFolder ? 0 : 1, $1.name.localizedLowercase)
        }
    }

    private func getFileSync(_ dev: MTPDevicePtr, _ item: PhoneItem, to destination: URL,
                             progress: ((Double) -> Void)?) throws {
        let box = progress.map { ProgressBox($0) }
        let callback: LIBMTP_progressfunc_t? = box == nil ? nil : progressCallback
        let status = withExtendedLifetime(box) {
            LIBMTP_Get_File_To_File(dev, item.id, destination.path, callback,
                                    box.map { Unmanaged.passUnretained($0).toOpaque() })
        }
        if status != 0 {
            try? FileManager.default.removeItem(at: destination)   // drop the partial file
            throw MTPError.failed(lastError(dev) ?? "Couldn't download \(item.name).")
        }
    }

    private func copyFolderSync(_ dev: MTPDevicePtr, _ folder: PhoneItem, into directory: URL,
                                onFile: (String) -> Void) throws {
        let target = directory.appendingPathComponent(folder.name, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for child in try listSync(dev, storage: folder.storageID, folder: folder.id) {
            if child.isFolder {
                try copyFolderSync(dev, child, into: target, onFile: onFile)
            } else {
                onFile(child.name)
                try getFileSync(dev, child, to: target.appendingPathComponent(child.name), progress: nil)
            }
        }
    }

    /// Reads and clears libmtp's error stack for this device.
    private func lastError(_ dev: MTPDevicePtr) -> String? {
        var messages: [String] = []
        var node = LIBMTP_Get_Errorstack(dev)
        while let e = node {
            if let text = e.pointee.error_text { messages.append(String(cString: text)) }
            node = e.pointee.next
        }
        LIBMTP_Clear_Errorstack(dev)
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
}

// MARK: - C helpers

private extension PhoneItem {
    init(_ f: LIBMTP_file_t) {
        self.init(
            id: f.item_id,
            parentID: f.parent_id,
            storageID: f.storage_id,
            name: f.filename.map { String(cString: $0) } ?? "(no name)",
            size: f.filesize,
            modified: Date(timeIntervalSince1970: TimeInterval(f.modificationdate)),
            isFolder: f.filetype == LIBMTP_FILETYPE_FOLDER)
    }
}

private func takeCString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    defer { free(pointer) }
    return String(cString: pointer)
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Carries a Swift closure through libmtp's C progress callback.
private final class ProgressBox {
    private let handler: (Double) -> Void
    private var lastReported = -1.0

    init(_ handler: @escaping (Double) -> Void) { self.handler = handler }

    func report(sent: UInt64, total: UInt64) {
        guard total > 0 else { return }
        let fraction = Double(sent) / Double(total)
        if fraction - lastReported >= 0.01 || fraction >= 1 {   // at most ~100 UI updates per file
            lastReported = fraction
            handler(fraction)
        }
    }
}

private let progressCallback: LIBMTP_progressfunc_t = { sent, total, context in
    guard let context else { return 0 }
    Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue().report(sent: sent, total: total)
    return 0   // returning non-zero cancels the transfer
}
