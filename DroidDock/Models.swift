import Foundation

struct PhoneStorage: Identifiable, Hashable {
    let id: UInt32
    let name: String
    let freeBytes: UInt64
    let capacityBytes: UInt64
}

struct PhoneItem: Identifiable, Hashable {
    let id: UInt32
    let parentID: UInt32
    let storageID: UInt32
    let name: String
    let size: UInt64
    let modified: Date
    let isFolder: Bool
}

enum MTPError: LocalizedError {
    case noDevice, openFailed, locked, notConnected
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noDevice:
            "No phone found. Plug it in, unlock it, and choose “File transfer” in the USB notification."
        case .openFailed:
            "The phone was found but couldn't be opened. Quit Smart Switch, Android File Transfer, OpenMTP or Image Capture, then replug."
        case .locked:
            "The phone didn't share its storage. Unlock it, tap “Allow” on the access prompt, then reconnect."
        case .notConnected:
            "No phone connected."
        case .failed(let message):
            message
        }
    }
}

// MARK: - Kinds

enum ItemKind: Int, CaseIterable {
    case folder, image, movie, music, document, archive, app, other

    init(_ item: PhoneItem) {
        if item.isFolder { self = .folder; return }
        switch (item.name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "dng", "bmp": self = .image
        case "mp4", "mov", "mkv", "3gp", "webm", "avi": self = .movie
        case "mp3", "m4a", "wav", "ogg", "flac", "aac", "amr", "opus": self = .music
        case "pdf", "txt", "md", "rtf", "csv", "json", "doc", "docx", "xls", "xlsx",
             "ppt", "pptx", "hwp", "hwpx", "pages", "numbers", "key": self = .document
        case "zip", "rar", "7z", "tar", "gz": self = .archive
        case "apk", "apks", "xapk": self = .app
        default: self = .other
        }
    }

    var symbol: String {
        switch self {
        case .folder: "folder.fill"
        case .image: "photo"
        case .movie: "film"
        case .music: "music.note"
        case .document: "doc.text"
        case .archive: "doc.zipper"
        case .app: "shippingbox"
        case .other: "doc"
        }
    }

    var name: String {
        switch self {
        case .folder: "Folder"
        case .image: "Image"
        case .movie: "Movie"
        case .music: "Audio"
        case .document: "Document"
        case .archive: "Archive"
        case .app: "Android App"
        case .other: "File"
        }
    }

    var groupTitle: String {
        switch self {
        case .folder: "Folders"
        case .image: "Images"
        case .movie: "Movies"
        case .music: "Music"
        case .document: "Documents"
        case .archive: "Archives"
        case .app: "Apps"
        case .other: "Other"
        }
    }
}

extension PhoneItem {
    var kind: ItemKind { ItemKind(self) }
    /// MTP phones generate thumbnails for photos and videos.
    var hasThumbnail: Bool { kind == .image || kind == .movie }
}

// MARK: - View options

enum ViewMode: String, CaseIterable, Identifiable {
    case icons, list, columns, gallery
    var id: Self { self }

    var title: String {
        switch self {
        case .icons: "as Icons"
        case .list: "as List"
        case .columns: "as Columns"
        case .gallery: "as Gallery"
        }
    }

    var symbol: String {
        switch self {
        case .icons: "square.grid.2x2"
        case .list: "list.bullet"
        case .columns: "rectangle.split.3x1"
        case .gallery: "rectangle.bottomthird.inset.filled"
        }
    }

    var shortcut: Character {
        switch self {
        case .icons: "1"
        case .list: "2"
        case .columns: "3"
        case .gallery: "4"
        }
    }
}

enum GroupBy: String, CaseIterable, Identifiable {
    case none, kind, dateModified, size
    var id: Self { self }

    var title: String {
        switch self {
        case .none: "None"
        case .kind: "Kind"
        case .dateModified: "Date Modified"
        case .size: "Size"
        }
    }
}

enum SortKey: String, CaseIterable, Identifiable {
    case name, kind, dateModified, size
    var id: Self { self }

    var title: String {
        switch self {
        case .name: "Name"
        case .kind: "Kind"
        case .dateModified: "Date Modified"
        case .size: "Size"
        }
    }
}

struct ItemSection: Identifiable {
    let id: String
    let title: String?
    let items: [PhoneItem]
}

// MARK: - Sidebar favorites

/// The sidebar's Favorites. Images and Videos gather files from the folders Android
/// saves them in (a Samsung camera puts photos and videos together in DCIM/Camera);
/// Download is a plain shortcut to that folder.
enum Favorite: String, CaseIterable, Identifiable {
    case images, videos, download
    var id: Self { self }

    var title: String {
        switch self {
        case .images: "Images"
        case .videos: "Videos"
        case .download: "Download"
        }
    }

    var symbol: String {
        switch self {
        case .images: "photo.on.rectangle"
        case .videos: "film"
        case .download: "arrow.down.circle"
        }
    }

    var isCollection: Bool { self != .download }

    /// Folder names from the storage root. A trailing "*" means every folder inside
    /// (Pictures/KakaoTalk, Pictures/Instagram, …).
    var sources: [[String]] {
        switch self {
        case .images: [["DCIM", "Camera"], ["DCIM", "Screenshots"], ["Pictures"], ["Pictures", "*"]]
        case .videos: [["DCIM", "Camera"], ["DCIM", "Screen recordings"], ["Movies"], ["Movies", "*"]]
        case .download: [["Download"]]
        }
    }

    /// Where files dropped onto this favorite go.
    var uploadFolder: [String] {
        switch self {
        case .images: ["Pictures"]
        case .videos: ["Movies"]
        case .download: ["Download"]
        }
    }

    func includes(_ item: PhoneItem) -> Bool {
        switch self {
        case .images: item.kind == .image
        case .videos: item.kind == .movie
        case .download: true
        }
    }
}

enum SidebarItem: Hashable {
    case favorite(Favorite)
    case storage(PhoneStorage.ID)
}
