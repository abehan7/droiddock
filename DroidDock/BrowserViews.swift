import SwiftUI
import AppKit

// MARK: - as List

struct ListBrowser: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Table(of: PhoneItem.self, selection: $model.selection) {
            TableColumn("Name") { item in
                Label {
                    Text(item.name).lineLimit(1)
                } icon: {
                    ItemIcon(item: item, thumbnail: model.thumbnails[item.id])
                }
                .onAppear { model.itemAppeared(item) }     // infinite scroll
            }
            TableColumn("Date Modified") { item in
                Text(item.modified.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Size") { item in
                Text(item.isFolder ? "--" : bytes(item.size))
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Kind") { item in
                Text(item.kind.name).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 100)
        } rows: {
            ForEach(model.sections) { section in
                if let title = section.title {
                    Section(title) {
                        ForEach(section.items) { item in
                            TableRow(item).itemProvider { model.dragProvider(for: item) }   // drag to Finder
                        }
                    }
                } else {
                    ForEach(section.items) { item in
                        TableRow(item).itemProvider { model.dragProvider(for: item) }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: PhoneItem.ID.self) { ids in
            ItemMenu(model: model, ids: ids)
        } primaryAction: { ids in                     // double-click
            guard ids.count == 1, let item = model.items.first(where: { ids.contains($0.id) }) else { return }
            Task { await model.activate(item) }
        }
    }
}

// MARK: - as Icons

struct IconBrowser: View {
    @Environment(BrowserModel.self) private var model
    @State private var anchor: PhoneItem.ID?          // where a shift-click range starts
    @State private var frames: [PhoneItem.ID: CGRect] = [:]   // tiles' frames, for box selection
    @State private var marquee: CGRect?
    @State private var marqueeBase = Set<PhoneItem.ID>()   // kept while ⌘/⇧ box-selecting

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 128), spacing: 8)]

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVGrid(columns: columns, spacing: 14, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.sections) { section in
                            Section {
                                ForEach(section.items) { item in tile(item) }
                            } header: {
                                if let title = section.title { SectionHeader(title: title, count: section.items.count) }
                            }
                        }
                    }
                    .padding(16)
                }
                .frame(minHeight: viewport.size.height, alignment: .top)
                .background { emptySpace }
                .overlay(alignment: .topLeading) { marqueeBox }
                .coordinateSpace(.named(Self.space))
            }
        }
        // Dragging any selected tile carries the whole selection to Finder.
        .dragContainer(for: PhoneItem.self) { ids in model.items.filter { ids.contains($0.id) } }
        .dragContainerSelection(model.visibleItems.map(\.id).filter { model.selection.contains($0) })
    }

    private static let space = "icon-grid"

    private func tile(_ item: PhoneItem) -> some View {
        IconCell(item: item, isSelected: model.selection.contains(item.id))
            // Tiles on screen keep their frame here for box selection; ones that scroll away
            // (or vanish when the folder changes) drop out, so stale frames never get hit.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[item.id] = $0 }
            .onDisappear { frames[item.id] = nil }
            .onTapGesture(count: 2) { Task { await model.activate(item) } }
            .simultaneousGesture(TapGesture().onEnded { click(item) })
            .contextMenu { ItemMenu(model: model, ids: menuTargets(for: item)) }
            .draggable(containerItemID: item.id)
            .onAppear { model.itemAppeared(item) }   // infinite scroll
            .frame(maxWidth: .infinity)               // the slot; only the tile itself is hittable
    }

    /// Whitespace: click to deselect, drag to draw a selection box (⌘/⇧ add to the selection).
    private var emptySpace: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { model.selection = [] }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
                    .onChanged { drag in
                        if marquee == nil {
                            let flags = NSEvent.modifierFlags
                            marqueeBase = flags.contains(.command) || flags.contains(.shift) ? model.selection : []
                        }
                        let box = CGRect(x: min(drag.startLocation.x, drag.location.x),
                                         y: min(drag.startLocation.y, drag.location.y),
                                         width: abs(drag.location.x - drag.startLocation.x),
                                         height: abs(drag.location.y - drag.startLocation.y))
                        marquee = box
                        let hit = frames.filter { $0.value.intersects(box) }.map(\.key)
                        model.selection = marqueeBase.union(hit)
                    }
                    .onEnded { _ in marquee = nil }
            )
            .contextMenu { ItemMenu(model: model, ids: []) }
    }

    @ViewBuilder private var marqueeBox: some View {
        if let marquee {
            Rectangle()
                .fill(Color.accentColor.opacity(0.15))
                .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1)
                .frame(width: marquee.width, height: marquee.height)
                .offset(x: marquee.minX, y: marquee.minY)
                .allowsHitTesting(false)
        }
    }

    /// Click selects; ⌘-click toggles; ⇧-click extends from the last click.
    private func click(_ item: PhoneItem) {
        let flags = NSEvent.modifierFlags
        let ordered = model.visibleItems
        if flags.contains(.command) {
            if model.selection.contains(item.id) { model.selection.remove(item.id) } else { model.selection.insert(item.id) }
        } else if flags.contains(.shift), let anchor,
                  let from = ordered.firstIndex(where: { $0.id == anchor }),
                  let to = ordered.firstIndex(where: { $0.id == item.id }) {
            model.selection = Set(ordered[min(from, to)...max(from, to)].map(\.id))
            return
        } else if !model.selection.contains(item.id) {
            model.selection = [item.id]   // clicking inside a selection keeps it, so it can be dragged
        }
        anchor = item.id
    }

    private func menuTargets(for item: PhoneItem) -> Set<PhoneItem.ID> {
        model.selection.contains(item.id) ? model.selection : [item.id]
    }
}

struct IconCell: View {
    let item: PhoneItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ThumbnailView(item: item, size: 64)
                .padding(5)
                .background(isSelected ? Color.secondary.opacity(0.25) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
            Text(item.name)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .foregroundStyle(isSelected ? .white : .primary)
                .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .frame(maxWidth: 120)
        .contentShape(Rectangle())
    }
}

struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Text("\(count) item\(count == 1 ? "" : "s")").font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - as Columns

struct ColumnBrowser: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(0...model.path.count, id: \.self) { level in
                            BrowserColumn(level: level)
                                .frame(width: 230, height: geo.size.height)
                                .id(level)
                            Divider()
                        }
                        if let item = model.singleSelectedItem, !item.isFolder {
                            PreviewPane(item: item, compact: true)
                                .frame(width: 300, height: geo.size.height)
                                .id("preview")
                        }
                    }
                }
                .onChange(of: model.path) {
                    withAnimation { proxy.scrollTo(model.path.count, anchor: .trailing) }
                }
                .onChange(of: model.selection) {
                    if model.singleSelectedItem?.isFolder == false {
                        withAnimation { proxy.scrollTo("preview", anchor: .trailing) }
                    }
                }
            }
        }
    }
}

/// One column: level 0 is the storage root, level n is the n-th folder of the path.
struct BrowserColumn: View {
    @Environment(BrowserModel.self) private var model
    let level: Int

    private var isCurrent: Bool { level == model.path.count }
    private var folderID: UInt32 { level == 0 ? MTPEngine.rootFolder : model.path[level - 1].id }

    var body: some View {
        let items = isCurrent ? model.visibleItems : model.arranged(model.cachedListing(folder: folderID) ?? [])
        List(items, selection: Binding(
            get: { isCurrent ? model.selection : [model.path[level].id] },
            set: { ids in Task { await model.selectInColumn(ids, level: level) } })
        ) { item in
            HStack(spacing: 6) {
                ItemIcon(item: item, thumbnail: model.thumbnails[item.id])
                    .frame(width: 18)
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if item.isFolder {
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                }
            }
            .onAppear { if isCurrent { model.itemAppeared(item) } }
            .onDrag { model.dragProvider(for: item) }
        }
        .contextMenu(forSelectionType: PhoneItem.ID.self) { ids in
            ItemMenu(model: model, ids: isCurrent ? ids : [])
        } primaryAction: { ids in
            guard isCurrent, ids.count == 1, let item = model.items.first(where: { ids.contains($0.id) }) else { return }
            Task { await model.activate(item) }
        }
        .overlay {
            if isCurrent && model.isLoading && items.isEmpty { ProgressView().controlSize(.small) }
        }
        .task(id: folderID) {
            if !isCurrent { await model.loadListing(folder: folderID) }
        }
    }
}

// MARK: - as Gallery

struct GalleryBrowser: View {
    @Environment(BrowserModel.self) private var model

    private var focused: PhoneItem? {
        model.visibleItems.first { model.selection.contains($0.id) } ?? model.visibleItems.first
    }

    var body: some View {
        VStack(spacing: 0) {
            PreviewPane(item: focused, compact: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 6) {
                        ForEach(model.visibleItems) { item in
                            ThumbnailView(item: item, size: 56)
                                .padding(5)
                                .background(item.id == focused?.id ? Color.accentColor.opacity(0.35) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .help(item.name)
                                .onTapGesture(count: 2) { Task { await model.activate(item) } }
                                .simultaneousGesture(TapGesture().onEnded { model.selection = [item.id] })
                                .contextMenu { ItemMenu(model: model, ids: [item.id]) }
                                .id(item.id)
                                .onAppear { model.itemAppeared(item) }   // infinite scroll
                                .onDrag { model.dragProvider(for: item) }
                        }

                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: 82)
                .onChange(of: model.selection) {
                    if let id = focused?.id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
                .onAppear {
                    if let id = focused?.id { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .onKeyPress(.return) {
            guard let focused else { return .ignored }
            Task { await model.activate(focused) }
            return .handled
        }
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        let list = model.visibleItems
        guard !list.isEmpty else { return .ignored }
        let current = focused.flatMap { item in list.firstIndex { $0.id == item.id } } ?? 0
        let next = min(max(current + offset, 0), list.count - 1)
        model.selection = [list[next].id]
        return .handled
    }
}

// MARK: - Previews and icons

/// A big preview with name and details, for the gallery and the last column.
struct PreviewPane: View {
    @Environment(BrowserModel.self) private var model
    let item: PhoneItem?
    let compact: Bool
    @State private var fullImage: NSImage?

    var body: some View {
        VStack(spacing: 14) {
            if let item {
                Group {
                    if let image = fullImage ?? model.thumbnails[item.id] {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .shadow(radius: 6, y: 2)
                    } else {
                        Image(systemName: item.kind.symbol)
                            .resizable()
                            .scaledToFit()
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(item.isFolder ? Color.accentColor : Color.secondary)
                            .frame(maxWidth: compact ? 96 : 160, maxHeight: compact ? 96 : 160)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 3) {
                    Text(item.name)
                        .font(compact ? .headline : .title3.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(item.isFolder ? item.kind.name : "\(item.kind.name) – \(bytes(item.size))")
                        .foregroundStyle(.secondary)
                    Text(item.modified.formatted(date: .abbreviated, time: .shortened))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(compact ? 16 : 24)
        .task(id: item?.id) {
            fullImage = nil
            guard let item, item.hasThumbnail else { return }
            await model.loadThumbnail(item)
            fullImage = await model.previewImage(for: item)
        }
    }
}

/// The phone's thumbnail for photos and videos, otherwise a symbol for the kind.
struct ThumbnailView: View {
    @Environment(BrowserModel.self) private var model
    let item: PhoneItem
    let size: CGFloat

    var body: some View {
        Group {
            if let image = model.thumbnails[item.id] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: item.kind.symbol)
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(item.isFolder ? Color.accentColor : Color.secondary)
                    .frame(width: size * 0.78, height: size * 0.78)
            }
        }
        .frame(width: size, height: size)
        .task(id: item.id) { await model.loadThumbnail(item) }
    }
}

/// Small icon for list rows; shows the thumbnail once one has loaded elsewhere.
///
/// Takes the thumbnail as a value instead of reading the model from the environment:
/// Table and List rows are separate hosting views, and a row that lays out while it is
/// being removed (switching storage swaps every row) has no environment, which crashes.
struct ItemIcon: View {
    let item: PhoneItem
    let thumbnail: NSImage?

    var body: some View {
        if let image = thumbnail {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        } else {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(item.isFolder ? Color.accentColor : Color.secondary)
        }
    }
}
