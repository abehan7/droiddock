import AppKit
import Observation

struct Transfer: Identifiable {
    enum Direction { case down, up }
    let id = UUID()
    let name: String
    let direction: Direction
    var progress: Double = 0
    var detail: String?        // current file during a folder copy
    var done = false
    var error: String?
}

@MainActor
@Observable
final class BrowserModel {
    enum Connection: Equatable {
        case disconnected, connecting, connected(name: String), failed(String)
    }
    struct Crumb: Hashable { let id: UInt32; let name: String }

    /// Where the window is: a folder on a storage, or one of the Images/Videos collections.
    struct Location: Equatable {
        let storage: PhoneStorage.ID?
        let path: [Crumb]
        let collection: Favorite?
    }

    var connection: Connection = .disconnected
    var storages: [PhoneStorage] = []
    private(set) var selectedStorage: PhoneStorage.ID?
    private(set) var path: [Crumb] = []    // empty = root of the storage
    private(set) var collection: Favorite?  // Images or Videos, when one is showing
    var items: [PhoneItem] = []
    var selection = Set<PhoneItem.ID>()
    var isLoading = false
    var errorMessage: String?
    var transfers: [Transfer] = []

    // View options, remembered between launches
    var viewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .list {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    var groupBy = GroupBy(rawValue: UserDefaults.standard.string(forKey: "groupBy") ?? "") ?? .none {
        didSet { UserDefaults.standard.set(groupBy.rawValue, forKey: "groupBy") }
    }
    var sortKey = SortKey(rawValue: UserDefaults.standard.string(forKey: "sortKey") ?? "") ?? .name {
        didSet { UserDefaults.standard.set(sortKey.rawValue, forKey: "sortKey") }
    }
    var searchText = ""

    // Sheets and dialogs any view can ask for
    var isNamingFolder = false
    var isConfirmingDelete = false
    private(set) var pendingDelete = Set<PhoneItem.ID>()
    var infoItem: PhoneItem?

    // Big folders: the first page shows at once, the rest of the details stream in behind it
    static let pageSize = 60
    private(set) var pending: [ItemRef] = []   // the current location's items not read yet
    private(set) var isPaged = false            // too big to read in one go
    private(set) var isLoadingAll = false
    private(set) var loadAllTotal = 0
    var hasMore: Bool { !pending.isEmpty }

    // Caches: what each location held, and every item whose details the phone already sent
    struct ItemRef: Hashable { let storage: UInt32; let id: UInt32 }
    private struct FolderKey: Hashable { let storage: UInt32; let folder: UInt32 }
    private enum ListingKey: Hashable { case folder(FolderKey), collection(Favorite) }
    private struct Listing { var items: [PhoneItem]; var pending: [ItemRef]; var isPaged: Bool }
    private var listings: [ListingKey: Listing] = [:]
    @ObservationIgnored private var known: [ItemRef: PhoneItem] = [:]
    private(set) var thumbnails: [PhoneItem.ID: NSImage] = [:]
    @ObservationIgnored private var thumbnailMisses = Set<PhoneItem.ID>()
    @ObservationIgnored private var previewCache: [PhoneItem.ID: NSImage] = [:]

    // Back / forward history
    private var backStack: [Location] = []
    private var forwardStack: [Location] = []

    /// How the phone is connected. USB uses adb when USB debugging is allowed (it lists a
    /// folder in one command, so big folders read in seconds) and MTP otherwise.
    enum Transport: Equatable {
        case usbMTP, usbADB, wifi
        var symbol: String { self == .wifi ? "wifi" : "cable.connector" }
        var label: String {
            switch self {
            case .usbMTP: "USB"
            case .usbADB: "USB · debugging"
            case .wifi: "Wi-Fi"
            }
        }
    }

    private(set) var transport: Transport = .usbMTP
    @ObservationIgnored private let mtp = MTPEngine()
    @ObservationIgnored private(set) var engine: any PhoneEngine
    /// USB debugging is on but the phone hasn't tapped "Allow" yet (MTP is used meanwhile).
    private(set) var usbDebuggingPending = false
    var isShowingWiFi = false

    /// Wi-Fi (Wireless debugging) is built but hidden for now; flip to bring back its buttons.
    static let wifiEnabled = false

    init() {
        engine = mtp
        try? FileManager.default.removeItem(at: Self.scratchRoot)   // leftovers from the last run
        DragExport.model = self
    }

    var isConnected: Bool { if case .connected = connection { true } else { false } }
    var currentFolderID: UInt32 { path.last?.id ?? MTPEngine.rootFolder }
    var currentStorageName: String { storages.first { $0.id == selectedStorage }?.name ?? "Phone" }
    var locationTitle: String { collection?.title ?? path.last?.name ?? currentStorageName }
    /// New folders need a real folder; uploads also work in Images/Videos (into Pictures/Movies).
    var canModifyHere: Bool { isConnected && collection == nil }
    var canUploadHere: Bool { isConnected }
    private var here: Location { Location(storage: selectedStorage, path: path, collection: collection) }

    /// What the sidebar highlights: a favorite when you're in it, otherwise the storage.
    var sidebarSelection: SidebarItem? {
        if let collection { return .favorite(collection) }
        if selectedStorage == storages.first?.id, path.count == 1,
           path[0].name.caseInsensitiveCompare(Favorite.download.title) == .orderedSame {
            return .favorite(.download)
        }
        return selectedStorage.map { .storage($0) }
    }
    var activeTransfers: [Transfer] { transfers.filter { !$0.done && $0.error == nil } }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var selectedItems: [PhoneItem] { items.filter { selection.contains($0.id) } }
    var singleSelectedItem: PhoneItem? { selection.count == 1 ? selectedItems.first : nil }

    // MARK: Connection

    /// USB: adb if the phone allows USB debugging, otherwise MTP ("File transfer" mode).
    func connect() async {
        guard connection != .connecting else { return }
        if !DemoPhone.isEnabled, let usb = await ADB.devices().first(where: { !$0.isWiFi }) {
            usbDebuggingPending = usb.state == "unauthorized"
            if usb.isReady { return await open(ADBEngine(serial: usb.serial), as: .usbADB) }
        } else {
            usbDebuggingPending = false
        }
        await open(mtp, as: .usbMTP)
    }

    /// Wi-Fi: a phone paired for Wireless debugging (see the Connect over Wi-Fi sheet).
    func connectWiFi(serial: String) async {
        await open(ADBEngine(serial: serial), as: .wifi)
    }

    private func open(_ newEngine: any PhoneEngine, as kind: Transport) async {
        guard connection != .connecting else { return }
        if isConnected { await disconnect() }
        connection = .connecting
        engine = newEngine
        transport = kind
        do {
            let info = try await engine.connect()
            storages = info.storages
            selectedStorage = info.storages.first?.id
            resetLocation()
            connection = .connected(name: info.name)
            await reload()
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        await engine.disconnect()
        connection = .disconnected
        storages = []; items = []
        resetLocation()
        listings = [:]; known = [:]; pending = []; isPaged = false
        thumbnails = [:]; thumbnailMisses = []; previewCache = [:]
    }

    // MARK: Navigation

    func selectSidebar(_ item: SidebarItem?) async {
        switch item {
        case .storage(let id):
            await go(to: Location(storage: id, path: [], collection: nil))
        case .favorite(let favorite) where favorite.isCollection:
            await go(to: Location(storage: selectedStorage, path: [], collection: favorite))
        case .favorite(let favorite):
            guard let primary = storages.first?.id,
                  let crumbs = await resolve(favorite.sources[0], on: primary) else {
                errorMessage = "This phone has no \(favorite.title) folder."
                return
            }
            await go(to: Location(storage: primary, path: crumbs, collection: nil))
        case nil:
            return
        }
    }

    /// Lists the current folder or collection: shows what's cached at once, then asks the
    /// phone for the IDs inside (one quick request) and fetches details only for IDs it
    /// hasn't seen. Big folders show their first page; the rest is read in the background.
    func reload(selecting: PhoneItem.ID? = nil) async {
        guard isConnected, selectedStorage != nil else { return }
        let location = here
        let key = listingKey
        if let cached = listings[key] {
            show(cached)
            selection = selecting.map { [$0] } ?? []
        } else {
            show(Listing(items: [], pending: [], isPaged: false))
            isLoading = true
        }
        defer { if location == here { isLoading = false } }
        do {
            let refs = try await childRefs()
            guard location == here else { return }
            let paged = !engine.listsDetailsUpFront && refs.count > Self.pageSize
            let ordered = refs
            let unknown = ordered.filter { known[$0] == nil }
            let firstPage = paged ? Array(unknown.prefix(Self.pageSize)) : unknown
            try await fetchDetails(firstPage)
            guard location == here else { return }
            let listing = Listing(items: ordered.compactMap { known[$0] }.filter(includes),
                                  pending: Array(unknown.dropFirst(firstPage.count)),
                                  isPaged: paged)
            listings[key] = listing
            show(listing)
            loadAllIfNeeded()
            let ids = Set(listing.items.map(\.id))
            selection = selection.filter { ids.contains($0) }
            if let selecting { selection = [selecting] }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sorting, grouping and searching need every item's name, date and size, and the
    /// phone sends those one file at a time; Android's IDs follow its folder scan, not
    /// dates, so there's no shortcut. After the first page shows, the rest is read in
    /// pages in the background (thumbnails still get their turn between pages), and items
    /// take their sorted place as they arrive. Leaving the folder pauses it; coming back
    /// resumes from what was already read.
    private func loadAllIfNeeded() {
        guard hasMore, !isLoadingAll else { return }
        Task { await loadAll() }
    }

    private func loadAll() async {
        guard !isLoadingAll, hasMore else { return }
        isLoadingAll = true
        loadAllTotal = items.count + pending.count
        defer { isLoadingAll = false }
        await loadPages()
    }

    private func loadPages() async {
        let location = here
        let key = listingKey
        while hasMore, location == here {
            let page = Array(pending.prefix(Self.pageSize))
            do { try await fetchDetails(page) } catch { errorMessage = error.localizedDescription; return }
            guard location == here else { return }
            pending.removeFirst(page.count)
            let new = page.compactMap { known[$0] }.filter(includes)
            items += new
            listings[key] = Listing(items: items, pending: pending, isPaged: isPaged)
        }
    }

    /// Views call this as rows and tiles appear: a folder whose background read stopped
    /// (you left and came back) picks it up again.
    func itemAppeared(_ item: PhoneItem) {
        loadAllIfNeeded()
    }

    private var listingKey: ListingKey {
        if let collection { return .collection(collection) }
        return .folder(FolderKey(storage: selectedStorage ?? 0, folder: currentFolderID))
    }

    private func includes(_ item: PhoneItem) -> Bool { collection?.includes(item) ?? true }

    private func show(_ listing: Listing) {
        items = listing.items
        pending = listing.pending
        isPaged = listing.isPaged
    }

    /// Everything inside the current folder, or inside every source folder of a collection.
    private func childRefs() async throws -> [ItemRef] {
        guard let collection else {
            guard let storage = selectedStorage else { return [] }
            return try await engine.childIDs(storage: storage, folder: currentFolderID)
                .map { ItemRef(storage: storage, id: $0) }
        }
        var refs: [ItemRef] = []
        var seen = Set<ItemRef>()
        for storage in storages {
            for folder in await sourceFolders(collection, on: storage.id) {
                guard let ids = try? await engine.childIDs(storage: storage.id, folder: folder) else { continue }
                for id in ids {
                    let ref = ItemRef(storage: storage.id, id: id)
                    if seen.insert(ref).inserted { refs.append(ref) }
                }
            }
        }
        return refs
    }

    private func fetchDetails(_ refs: [ItemRef]) async throws {
        guard !refs.isEmpty else { return }
        let storageOf = Dictionary(refs.map { ($0.id, $0.storage) }, uniquingKeysWith: { a, _ in a })
        for item in try await engine.metadata(for: refs.map(\.id)) {
            known[ItemRef(storage: storageOf[item.id] ?? item.storageID, id: item.id)] = item
        }
    }

    /// Every move goes through here, so Back and Forward see it.
    func navigate(to newPath: [Crumb], selecting: PhoneItem.ID? = nil) async {
        await go(to: Location(storage: selectedStorage, path: newPath, collection: nil), selecting: selecting)
    }

    private func go(to location: Location, selecting: PhoneItem.ID? = nil) async {
        guard location != here else {
            if let selecting { selection = [selecting] }
            return
        }
        backStack.append(here)
        forwardStack = []
        await move(to: location, selecting: selecting)
    }

    func open(_ item: PhoneItem) async {
        guard item.isFolder else { return }
        await navigate(to: path + [Crumb(id: item.id, name: item.name)])
    }

    /// Double-click: folders open in place, files open on the Mac in their default app.
    func activate(_ item: PhoneItem) async {
        if item.isFolder { await open(item) } else { await openOnMac(item) }
    }

    func goUp() async {
        guard !path.isEmpty else { return }
        await navigate(to: Array(path.dropLast()))
    }

    func goBack() async {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(here)
        await move(to: previous)
    }

    func goForward() async {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(here)
        await move(to: next)
    }

    func jump(to index: Int?) async {          // nil = storage root
        await navigate(to: index.map { Array(path.prefix($0 + 1)) } ?? [])
    }

    private func move(to location: Location, selecting: PhoneItem.ID? = nil) async {
        // Going up selects the folder you came out of, like Finder.
        let sameTree = location.storage == selectedStorage && location.collection == nil && collection == nil
        let newPath = location.path
        let cameFrom = sameTree && newPath.count < path.count && Array(path.prefix(newPath.count)) == newPath
            ? path[newPath.count].id : nil
        selectedStorage = location.storage
        path = newPath
        collection = location.collection
        searchText = ""
        await reload(selecting: selecting ?? cameFrom)
    }

    private func resetLocation() {
        path = []; collection = nil; selection = []; backStack = []; forwardStack = []; searchText = ""
    }

    // MARK: Finding folders by name

    private func sourceFolders(_ favorite: Favorite, on storage: PhoneStorage.ID) async -> [UInt32] {
        var folders: [UInt32] = []
        for source in favorite.sources {
            if source.last == "*" {
                guard let parent = await resolve(Array(source.dropLast()), on: storage),
                      let listing = await listing(of: parent.last?.id ?? MTPEngine.rootFolder, on: storage)
                else { continue }
                folders += listing.filter(\.isFolder).map(\.id)
            } else if let crumbs = await resolve(source, on: storage), let last = crumbs.last {
                folders.append(last.id)
            }
        }
        var seen = Set<UInt32>()
        return folders.filter { seen.insert($0).inserted }
    }

    /// Finds a folder path by name ("DCIM", "Camera"), ignoring case.
    private func resolve(_ names: [String], on storage: PhoneStorage.ID) async -> [Crumb]? {
        var crumbs: [Crumb] = []
        for name in names {
            guard let listing = await listing(of: crumbs.last?.id ?? MTPEngine.rootFolder, on: storage),
                  let folder = listing.first(where: { $0.isFolder && $0.name.caseInsensitiveCompare(name) == .orderedSame })
            else { return nil }
            crumbs.append(Crumb(id: folder.id, name: folder.name))
        }
        return crumbs
    }

    /// A whole folder at once, for small ones: the root, DCIM, a column on the left.
    private func listing(of folder: UInt32, on storage: PhoneStorage.ID) async -> [PhoneItem]? {
        let key = ListingKey.folder(FolderKey(storage: storage, folder: folder))
        if let cached = listings[key], cached.pending.isEmpty { return cached.items }
        guard let result = try? await engine.list(storage: storage, folder: folder) else { return nil }
        for item in result { known[ItemRef(storage: storage, id: item.id)] = item }
        listings[key] = Listing(items: result, pending: [], isPaged: false)
        return result
    }

    // MARK: Arranging (search, sort, groups)

    /// The current folder as the views show it: searched and sorted.
    var visibleItems: [PhoneItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let found = query.isEmpty ? items : items.filter { $0.name.localizedStandardContains(query) }
        return arranged(found)
    }

    /// Folders stay on top; the rest follows the Sort By choice.
    func arranged(_ list: [PhoneItem]) -> [PhoneItem] {
        list.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            switch sortKey {
            case .name: break
            case .kind where a.kind != b.kind: return a.kind.rawValue < b.kind.rawValue
            case .dateModified where a.modified != b.modified: return a.modified > b.modified
            case .size where a.size != b.size: return a.size > b.size
            default: break
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    var sections: [ItemSection] {
        let list = visibleItems
        let bucket: (PhoneItem) -> (order: Int, title: String)
        switch groupBy {
        case .none: return [ItemSection(id: "all", title: nil, items: list)]
        case .kind: bucket = { ($0.kind.rawValue, $0.kind.groupTitle) }
        case .dateModified: bucket = Self.dateBucket
        case .size: bucket = Self.sizeBucket
        }
        var groups: [Int: (title: String, items: [PhoneItem])] = [:]
        for item in list {
            let (order, title) = bucket(item)
            groups[order, default: (title, [])].items.append(item)
        }
        return groups.keys.sorted().map { ItemSection(id: groups[$0]!.title, title: groups[$0]!.title, items: groups[$0]!.items) }
    }

    private static func dateBucket(_ item: PhoneItem) -> (Int, String) {
        let calendar = Calendar.current
        let date = item.modified
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: .now)).day ?? 0
        if calendar.isDateInToday(date) { return (0, "Today") }
        if calendar.isDateInYesterday(date) { return (1, "Yesterday") }
        if days < 7 { return (2, "Previous 7 Days") }
        if days < 30 { return (3, "Previous 30 Days") }
        let year = calendar.component(.year, from: date)
        if year == calendar.component(.year, from: .now) {
            let month = calendar.component(.month, from: date)
            return (100 + (12 - month), calendar.standaloneMonthSymbols[month - 1])
        }
        return (1000 + (9999 - year), String(year))
    }

    private static func sizeBucket(_ item: PhoneItem) -> (Int, String) {
        if item.isFolder { return (0, "Folders") }
        switch item.size {
        case 1_000_000_000...: return (1, "Over 1 GB")
        case 100_000_000...: return (2, "100 MB – 1 GB")
        case 1_000_000...: return (3, "1 MB – 100 MB")
        case 1_000...: return (4, "1 KB – 1 MB")
        default: return (5, "Under 1 KB")
        }
    }

    // MARK: Column view

    func cachedListing(folder: UInt32) -> [PhoneItem]? {
        guard let storage = selectedStorage else { return nil }
        return listings[.folder(FolderKey(storage: storage, folder: folder))]?.items
    }

    /// Fills the cache for a column to the left of the current folder.
    func loadListing(folder: UInt32) async {
        guard let storage = selectedStorage else { return }
        _ = await listing(of: folder, on: storage)
    }

    /// A click in column `level` (0 = storage root). Folders open a column to the right.
    func selectInColumn(_ ids: Set<PhoneItem.ID>, level: Int) async {
        if level == path.count {   // the current folder's column
            if ids.count == 1, let item = items.first(where: { ids.contains($0.id) }), item.isFolder {
                await open(item)
            } else {
                selection = ids
            }
            return
        }
        let folder = level == 0 ? MTPEngine.rootFolder : path[level - 1].id
        guard ids.count == 1,
              let item = cachedListing(folder: folder)?.first(where: { ids.contains($0.id) }) else { return }
        let prefix = Array(path.prefix(level))
        if item.isFolder {
            await navigate(to: prefix + [Crumb(id: item.id, name: item.name)])
        } else {
            await navigate(to: prefix, selecting: item.id)
        }
    }

    // MARK: Thumbnails and previews

    /// The phone's own thumbnail; for a photo without one (often HEIC), the photo itself
    /// is copied over and shrunk on the Mac. Only cells on screen ask, and cells that
    /// scroll away cancel their request before it reaches the phone.
    func loadThumbnail(_ item: PhoneItem) async {
        guard item.hasThumbnail, thumbnails[item.id] == nil, !thumbnailMisses.contains(item.id) else { return }
        if let data = await engine.thumbnail(for: item.id), let image = NSImage(data: data) {
            thumbnails[item.id] = image
            return
        }
        if item.kind == .image, item.size <= 25_000_000, !Task.isCancelled,
           let url = await localCopy(of: item), let image = Self.downscaled(url, maxPixels: 256) {
            thumbnails[item.id] = image
            return
        }
        if !Task.isCancelled { thumbnailMisses.insert(item.id) }
    }

    /// Full-size image for the gallery and column previews (photos up to 60 MB).
    func previewImage(for item: PhoneItem) async -> NSImage? {
        if let cached = previewCache[item.id] { return cached }
        guard item.kind == .image, item.size < 60_000_000,
              let url = await localCopy(of: item), let image = NSImage(contentsOf: url) else { return nil }
        if previewCache.count > 30 { previewCache.removeAll() }
        previewCache[item.id] = image
        return image
    }

    /// The photo copied into the scratch folder, shared by thumbnails and previews.
    private func localCopy(of item: PhoneItem) async -> URL? {
        let url = Self.scratchDirectory("Previews").appendingPathComponent("\(item.id)-\(item.name)")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return await engine.fetchPreview(item, to: url) ? url : nil
    }

    private static func downscaled(_ url: URL, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,   // respect EXIF rotation
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: Requests from menus

    func requestNewFolder() {
        guard canModifyHere else { return }
        isNamingFolder = true
    }

    func requestDelete(_ ids: Set<PhoneItem.ID>) {
        guard !ids.isEmpty else { return }
        pendingDelete = ids
        isConfirmingDelete = true
    }

    func confirmDelete() async {
        let ids = pendingDelete
        pendingDelete = []
        await delete(ids: ids)
    }

    func showInfo(_ ids: Set<PhoneItem.ID>) {
        infoItem = items.first { ids.contains($0.id) }
    }

    // MARK: Open and share

    /// Copies a file to a scratch folder and opens it with its default Mac app.
    func openOnMac(_ item: PhoneItem) async {
        let urls = await copyToScratch([item.id])
        if let url = urls.first { NSWorkspace.shared.open(url) }
    }

    /// Copies the selection to a scratch folder, then shows the macOS share menu.
    func share(_ ids: Set<PhoneItem.ID>, from anchor: NSView?) async {
        let urls = await copyToScratch(ids)
        guard !urls.isEmpty, let view = anchor ?? NSApp.keyWindow?.contentView else { return }
        NSSharingServicePicker(items: urls).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    /// For a drag to Finder: copies the item off the phone when the drop lands.
    func exportForDrag(_ item: PhoneItem) async -> URL? {
        let dir = Self.scratchDirectory(UUID().uuidString)
        await download([item], to: dir)
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.first
    }

    private func copyToScratch(_ ids: Set<PhoneItem.ID>) async -> [URL] {
        let dir = Self.scratchDirectory(UUID().uuidString)
        await download(ids: ids, to: dir)
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }

    private static let scratchRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("DroidDock", isDirectory: true)

    private static func scratchDirectory(_ name: String) -> URL {
        let dir = scratchRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Transfers

    func download(ids: Set<PhoneItem.ID>, to directory: URL? = nil) async {
        await download(items.filter { ids.contains($0.id) }, to: directory)
    }

    private func download(_ picked: [PhoneItem], to directory: URL? = nil) async {
        let dir = directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        for item in picked {
            let tid = startTransfer(item.name, .down)
            do {
                if item.isFolder {
                    try await engine.downloadFolder(item, into: dir) { [weak self] file in
                        Task { @MainActor in self?.updateTransfer(tid) { $0.detail = file } }
                    }
                } else {
                    try await engine.download(item, to: uniqueURL(in: dir, name: item.name)) { [weak self] fraction in
                        Task { @MainActor in self?.updateTransfer(tid) { $0.progress = fraction } }
                    }
                }
                updateTransfer(tid) { $0.progress = 1; $0.done = true }
            } catch {
                updateTransfer(tid) { $0.error = error.localizedDescription }
                errorMessage = error.localizedDescription
                break
            }
        }
    }

    func upload(_ urls: [URL]) async {
        guard canUploadHere, let (storage, folder) = await uploadTarget() else { return }
        for url in urls {
            do { try await uploadItem(url, storage: storage, parent: folder) }
            catch { errorMessage = error.localizedDescription; break }
        }
        await refreshStorages()
        await reload()
    }

    /// The current folder, or for Images/Videos their Pictures/Movies folder.
    private func uploadTarget() async -> (UInt32, UInt32)? {
        guard let collection else { return selectedStorage.map { ($0, currentFolderID) } }
        guard let primary = storages.first?.id,
              let folder = await resolve(collection.uploadFolder, on: primary)?.last else {
            errorMessage = "This phone has no \(collection.uploadFolder.joined(separator: "/")) folder to copy into."
            return nil
        }
        return (primary, folder.id)
    }

    private func uploadItem(_ url: URL, storage: UInt32, parent: UInt32) async throws {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDirectory {
            let folderID = try await engine.createFolder(named: url.lastPathComponent, storage: storage, parent: parent)
            let children = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            for child in children {
                try await uploadItem(child, storage: storage, parent: folderID)
            }
        } else {
            let tid = startTransfer(url.lastPathComponent, .up)
            do {
                try await engine.upload(url, storage: storage, folder: parent) { [weak self] fraction in
                    Task { @MainActor in self?.updateTransfer(tid) { $0.progress = fraction } }
                }
                updateTransfer(tid) { $0.progress = 1; $0.done = true }
            } catch {
                updateTransfer(tid) { $0.error = error.localizedDescription }
                throw error
            }
        }
    }

    // MARK: Edits

    func makeFolder(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let storage = selectedStorage, !trimmed.isEmpty else { return }
        do { _ = try await engine.createFolder(named: trimmed, storage: storage, parent: currentFolderID) }
        catch { errorMessage = error.localizedDescription }
        await reload()
    }

    func delete(ids: Set<PhoneItem.ID>) async {
        for id in ids {
            do { try await engine.delete(id) }
            catch { errorMessage = error.localizedDescription; break }
        }
        await refreshStorages()
        await reload()
    }

    func refreshStorages() async {
        if let fresh = try? await engine.refreshStorages() { storages = fresh }
    }

    // MARK: Plug and play

    @ObservationIgnored private var usbWatcher: USBWatcher?

    func startWatchingUSB() {
        usbWatcher = USBWatcher(
            onAdd: { [weak self] in Task { await self?.phonePluggedIn() } },
            onRemove: { [weak self] in Task { await self?.phoneUnplugged() } })
    }

    private func phonePluggedIn() async {
        guard !isConnected else { return }   // already on Wi-Fi or USB
        try? await Task.sleep(for: .seconds(1.5))   // give Android a moment to start MTP
        await connect()
    }

    private func phoneUnplugged() async {
        guard isConnected, transport != .wifi else { return }   // Wi-Fi doesn't care about the cable
        await disconnect()
    }

    // MARK: Helpers

    private func startTransfer(_ name: String, _ direction: Transfer.Direction) -> UUID {
        let transfer = Transfer(name: name, direction: direction)
        transfers.append(transfer)
        return transfer.id
    }

    private func updateTransfer(_ id: UUID, _ change: (inout Transfer) -> Void) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[i])
    }

    /// photo.jpg → photo 2.jpg → photo 3.jpg, so downloads never overwrite.
    private func uniqueURL(in dir: URL, name: String) -> URL {
        var url = dir.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }
}
