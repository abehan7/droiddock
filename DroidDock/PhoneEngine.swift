import Foundation

/// What BrowserModel needs from a connection. Two implementations:
/// - `MTPEngine`: USB "File transfer" mode, through libmtp.
/// - `ADBEngine`: USB debugging (or Wi-Fi Wireless debugging), through the `adb` tool.
///
/// Items are addressed by UInt32 IDs, with `MTPEngine.rootFolder` meaning a storage's
/// root. MTP IDs come from the phone; ADB maps file paths to IDs of its own.
protocol PhoneEngine: AnyObject, Sendable {
    /// True when `childIDs` already brings every item's details (ADB), so there is
    /// nothing to page through; MTP fetches them one file at a time.
    var listsDetailsUpFront: Bool { get }

    func connect() async throws -> (name: String, storages: [PhoneStorage])
    func disconnect() async
    /// Blocking release for applicationWillTerminate.
    func shutdown()
    func refreshStorages() async throws -> [PhoneStorage]

    /// A whole folder at once.
    func list(storage: UInt32, folder: UInt32) async throws -> [PhoneItem]
    /// The IDs inside a folder; quick, without details.
    func childIDs(storage: UInt32, folder: UInt32) async throws -> [UInt32]
    /// Details for IDs returned by `childIDs`.
    func metadata(for ids: [UInt32]) async throws -> [PhoneItem]

    func thumbnail(for itemID: UInt32) async -> Data?
    func fetchPreview(_ item: PhoneItem, to destination: URL) async -> Bool

    func download(_ item: PhoneItem, to destination: URL, progress: @escaping (Double) -> Void) async throws
    func downloadFolder(_ folder: PhoneItem, into directory: URL, onFile: @escaping (String) -> Void) async throws
    func upload(_ fileURL: URL, storage: UInt32, folder: UInt32, progress: @escaping (Double) -> Void) async throws
    func createFolder(named name: String, storage: UInt32, parent: UInt32) async throws -> UInt32
    func delete(_ itemID: UInt32) async throws
}

extension MTPEngine: PhoneEngine {
    var listsDetailsUpFront: Bool { false }
}
