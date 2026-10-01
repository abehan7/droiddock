import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Window

struct ContentView: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if model.isConnected {
                FileBrowserView()
            } else {
                NotConnectedView()
            }
        }
        .sheet(isPresented: Binding(get: { model.isShowingWiFi }, set: { model.isShowingWiFi = $0 })) {
            WiFiConnectView().environment(model)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        List(selection: Binding(
            get: { model.sidebarSelection },
            set: { item in Task { await model.selectSidebar(item) } })
        ) {
            if case .connected(let name) = model.connection {
                Section("Favorites") {
                    ForEach(Favorite.allCases) { favorite in
                        Label(favorite.title, systemImage: favorite.symbol)
                            .tag(SidebarItem.favorite(favorite))
                    }
                }
                Section(name) {
                    ForEach(model.storages) { storage in
                        StorageRow(storage: storage).tag(SidebarItem.storage(storage.id))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { ConnectionBar() }
    }
}

struct StorageRow: View {
    let storage: PhoneStorage

    var body: some View {
        let used = max(0, Double(storage.capacityBytes) - Double(storage.freeBytes))
        VStack(alignment: .leading, spacing: 4) {
            Label(storage.name, systemImage: "internaldrive")
            ProgressView(value: used, total: max(Double(storage.capacityBytes), 1))
                .controlSize(.small)
            Text("\(bytes(storage.freeBytes)) free of \(bytes(storage.capacityBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct ConnectionBar: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.transport == .usbMTP && model.usbDebuggingPending && model.isConnected {
                // USB debugging is on but not allowed yet: MTP works, adb would be much faster.
                Button {
                    Task { await model.connect() }
                } label: {
                    Label("Tap “Allow” on the phone for faster USB, then click here", systemImage: "bolt")
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 8) {
                switch model.connection {
                case .connected(let name):
                    Image(systemName: model.transport.symbol).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name).lineLimit(1)
                        Text(model.transport.label).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Eject", systemImage: "eject") { Task { await model.disconnect() } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Release the phone")
                case .connecting:
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                    Spacer()
                case .disconnected, .failed:
                    Image(systemName: "smartphone").foregroundStyle(.secondary)
                    Text("No phone").foregroundStyle(.secondary)
                    Spacer()
                    Button("USB") { Task { await model.connect() } }
                        .help("Connect with the USB cable")
                    if BrowserModel.wifiEnabled {
                        Button("Wi-Fi…") { model.isShowingWiFi = true }
                            .help("Connect over Wi-Fi (Wireless debugging)")
                    }
                }
            }
        }
        .font(.callout)
        .padding(10)
    }
}

struct NotConnectedView: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Connect your phone", systemImage: "smartphone")
        } description: {
            if case .failed(let message) = model.connection {
                Text(message)
            } else {
                Text(BrowserModel.wifiEnabled
                     ? "Plug in your Samsung and choose “File transfer” in the USB notification, or connect over Wi-Fi with Wireless debugging."
                     : "Plug in your Samsung, unlock it, and choose “File transfer” in the USB notification.")
            }
        } actions: {
            HStack {
                Button {
                    Task { await model.connect() }
                } label: {
                    Label(model.connection == .connecting ? "Connecting…" : "Connect with USB", systemImage: "cable.connector")
                }
                .disabled(model.connection == .connecting)
                if BrowserModel.wifiEnabled {
                    Button {
                        model.isShowingWiFi = true
                    } label: {
                        Label("Connect over Wi-Fi…", systemImage: "wifi")
                    }
                }
            }
            .controlSize(.large)
        }
    }
}

// MARK: - File browser

struct FileBrowserView: View {
    @Environment(BrowserModel.self) private var model
    @State private var newFolderName = ""
    @State private var isDropTarget = false
    @State private var shareAnchor: NSView?

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.viewMode {
            case .icons: IconBrowser()
            case .list: ListBrowser()
            case .columns: ColumnBrowser()
            case .gallery: GalleryBrowser()
            }
        }
        .overlay {
            if model.isLoading && model.items.isEmpty {
                ProgressView()
            } else if model.viewMode != .columns && model.visibleItems.isEmpty {
                if let collection = model.collection, model.searchText.isEmpty {
                    ContentUnavailableView("No \(collection.title)", systemImage: collection.symbol,
                                           description: Text("Nothing in DCIM, Pictures or Movies yet."))
                } else if model.searchText.isEmpty {
                    ContentUnavailableView("Empty Folder", systemImage: "folder",
                                           description: Text("Drop files here to copy them to your phone."))
                } else {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in   // drag from Finder = upload here
            guard model.canUploadHere else { return false }
            Task { await model.upload(urls) }
            return true
        } isTargeted: { isDropTarget = $0 && model.canUploadHere }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                TransfersBar()
                Divider()
                PathBar()
            }
        }
        .navigationTitle(model.locationTitle)
        .toolbar { toolbarContent }
        .searchable(text: $model.searchText, placement: .toolbar,
                    prompt: "Search \(model.locationTitle)")
        .confirmationDialog("Delete \(model.pendingDelete.count) item(s) from your phone?",
                            isPresented: $model.isConfirmingDelete) {
            Button("Delete", role: .destructive) { Task { await model.confirmDelete() } }
        } message: {
            Text("This can't be undone.")
        }
        .alert("New Folder", isPresented: $model.isNamingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { Task { await model.makeFolder(named: newFolderName) } }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: model.isNamingFolder) { if model.isNamingFolder { newFolderName = "untitled folder" } }
        .sheet(item: $model.infoItem) { InfoSheet(item: $0).environment(model) }
    }

    /// Laid out like Finder: back/forward, then view, group, actions and search capsules.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        @Bindable var model = model

        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.left") { Task { await model.goBack() } }
                .disabled(!model.canGoBack)
                .help("See folders you viewed previously")
            Button("Forward", systemImage: "chevron.right") { Task { await model.goForward() } }
                .disabled(!model.canGoForward)
                .help("See folders you viewed next")
        }

        ToolbarItem {
            Menu {
                Picker("View", selection: $model.viewMode) {
                    ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.viewMode.symbol)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                }
            }
            .menuIndicator(.hidden)
            .help("Change the item view")
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            Menu {
                Picker("Group By", selection: $model.groupBy) {
                    ForEach(GroupBy.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("Sort By", selection: $model.sortKey) {
                    ForEach(SortKey.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                if model.hasMore {
                    Text("The order settles once every file's details are read")
                }
            } label: {
                Label("Group", systemImage: "square.grid.3x1.below.line.grid.1x2")
            }
            .help("Change the way items are grouped and sorted")
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup {
            Button("Share", systemImage: "square.and.arrow.up") {
                Task { await model.share(model.selection, from: shareAnchor) }
            }
            .disabled(model.selection.isEmpty)
            .background(ViewAnchor { shareAnchor = $0 })
            .help("Copy the selection to the Mac and share it")

            Button("Download", systemImage: "arrow.down.circle") {
                Task { await model.download(ids: model.selection) }
            }
            .disabled(model.selection.isEmpty)
            .help("Copy the selection to Downloads")

            Button("Upload", systemImage: "arrow.up.circle") { model.presentUploadPanel() }
                .disabled(!model.canUploadHere)
                .help(model.collection.map { "Copy files from the Mac into \($0.uploadFolder.joined(separator: "/"))" }
                      ?? "Copy files from the Mac into this folder")

            Menu {
                ItemMenu(model: model, ids: model.selection)
            } label: {
                Label("Action", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("Perform tasks with the selected items")
        }
    }
}

/// The menu shared by right-click, the ⋯ toolbar button and every view mode.
///
/// Takes the model directly rather than from the environment: menus that macOS draws
/// outside the window (the toolbar's overflow » menu) don't carry SwiftUI's environment.
struct ItemMenu: View {
    let model: BrowserModel
    let ids: Set<PhoneItem.ID>

    var body: some View {
        let picked = model.items.filter { ids.contains($0.id) }
        if picked.count == 1, let item = picked.first {
            Button(item.isFolder ? "Open" : "Open on Mac") { Task { await model.activate(item) } }
            Divider()
        }
        if model.canModifyHere { Button("New Folder") { model.requestNewFolder() } }
        if model.canUploadHere { Button("Upload Files…") { model.presentUploadPanel() } }
        if !picked.isEmpty {
            Divider()
            Button("Download to Downloads") { Task { await model.download(ids: ids) } }
            Button("Download To…") { model.presentDownloadPanel(ids) }
            Button("Get Info") { model.showInfo(ids) }
            Divider()
            Button("Delete…", role: .destructive) { model.requestDelete(ids) }
        }
        Divider()
        Button("Refresh") { Task { await model.reload() } }
    }
}

extension BrowserModel {
    func presentUploadPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "Copy to Phone"
        guard panel.runModal() == .OK else { return }
        Task { await upload(panel.urls) }
    }

    func presentDownloadPanel(_ ids: Set<PhoneItem.ID>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await download(ids: ids, to: folder) }
    }
}

extension BrowserModel {
    /// Drag to Finder: a promise of the file, fulfilled by copying it off the phone when
    /// the drop lands (Finder shows it arriving; the transfer bar shows the progress).
    func dragProvider(for item: PhoneItem) -> NSItemProvider {
        // Finder names the dropped file suggestedName + the type's preferred extension.
        // So a typed file is suggested without its extension ("p2" + "png"); one whose
        // extension isn't the preferred one (.jpg vs .jpeg) goes as plain data, full name.
        let ext = (item.name as NSString).pathExtension.lowercased()
        let exact = UTType(filenameExtension: ext).flatMap { $0.preferredFilenameExtension == ext ? $0 : nil }
        let type = item.isFolder ? UTType.folder : exact ?? .data
        let provider = NSItemProvider()
        provider.suggestedName = exact != nil ? (item.name as NSString).deletingPathExtension : item.name
        provider.registerFileRepresentation(for: type, visibility: .all, openInPlace: false) { completion in
            Task { @MainActor in
                if let url = await self.exportForDrag(item) {
                    completion(url, false, nil)
                } else {
                    completion(nil, false, MTPError.failed("Couldn't copy \(item.name) from the phone."))
                }
            }
            return nil
        }
        return provider
    }
}

/// Lets SwiftUI drag phone items to Finder (several at once from the icon grid). Each
/// file is copied off the phone only when the drop lands. Files go as plain data so
/// Finder keeps their names as-is (it would turn "x.jpg" typed as JPEG into "x.jpg.jpeg").
extension PhoneItem: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .folder) { item in
            SentTransferredFile(try await DragExport.copy(item))
        }
        .exportingCondition { $0.isFolder }
        .suggestedFileName { $0.name }

        FileRepresentation(exportedContentType: .data) { item in
            SentTransferredFile(try await DragExport.copy(item))
        }
        .exportingCondition { !$0.isFolder }
        .suggestedFileName { $0.name }
    }
}

@MainActor
enum DragExport {
    static weak var model: BrowserModel?

    static func copy(_ item: PhoneItem) async throws -> URL {
        guard let model, let url = await model.exportForDrag(item) else {
            throw MTPError.failed("Couldn't copy \(item.name) from the phone.")
        }
        return url
    }
}

/// Hands back the AppKit view behind a SwiftUI control, so the share menu can point at it.
struct ViewAnchor: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct InfoSheet: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: PhoneItem

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ThumbnailView(item: item, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.title3.bold()).lineLimit(2)
                    Text(item.isFolder ? "Folder" : bytes(item.size)).foregroundStyle(.secondary)
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Kind", item.kind.name)
                if !item.isFolder { row("Size", "\(bytes(item.size)) (\(item.size.formatted()) bytes)") }
                row("Modified", item.modified.formatted(date: .long, time: .shortened))
                row("Where", model.collection?.title
                    ?? ([model.currentStorageName] + model.path.map(\.name)).joined(separator: " › "))
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label + ":").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }
}

// MARK: - Bottom bars

struct TransfersBar: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        if let current = model.activeTransfers.first {
            HStack(spacing: 10) {
                Image(systemName: current.direction == .down ? "arrow.down.circle" : "arrow.up.circle")
                    .foregroundStyle(.tint)
                Text(current.detail ?? current.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if current.detail == nil {
                    ProgressView(value: current.progress).frame(width: 140)
                } else {
                    ProgressView().controlSize(.small)   // folder copy: file names, no total
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

struct PathBar: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            if let collection = model.collection {
                Label("\(collection.title) from all folders and storages", systemImage: collection.symbol)
            } else {
                Button(model.currentStorageName) { Task { await model.jump(to: nil) } }
                ForEach(Array(model.path.enumerated()), id: \.offset) { index, crumb in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(crumb.name) { Task { await model.jump(to: index) } }
                }
            }
            Spacer()
            if model.hasMore {
                let total = max(model.loadAllTotal, model.items.count + model.pending.count, 1)
                let done = total - model.pending.count
                Text("Reading file details · \(done) of \(total)")
                ProgressView(value: Double(done), total: Double(total))
                    .frame(width: 90)
            } else {
                Text("\(model.items.count) item\(model.items.count == 1 ? "" : "s")")
            }
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Helpers

func bytes(_ value: UInt64) -> String {
    Int64(clamping: value).formatted(.byteCount(style: .file))
}
