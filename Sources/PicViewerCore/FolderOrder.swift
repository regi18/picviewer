import CoreGraphics
import CoreServices
import Foundation
import UniformTypeIdentifiers

/// The Finder column or arrangement a folder is sorted by. Raw values are the identifiers Finder itself writes in
/// .DS_Store files and in its preferences.
public enum SortKey: String, Sendable, CaseIterable {
    case name
    case dateModified
    case dateCreated
    case dateAdded
    case dateLastOpened
    case size
    case kind
    case label
    case version
    case comments

    /// The direction Finder uses when you first pick this sort: names and kinds A to Z, dates newest first, sizes
    /// largest first. AppleScript's "normal" sort direction means this one.
    public var naturalAscending: Bool {
        switch self {
        case .name, .kind, .label, .version, .comments: true
        case .dateModified, .dateCreated, .dateAdded, .dateLastOpened, .size: false
        }
    }

    public var label: String {
        switch self {
        case .name: "Name"
        case .dateModified: "Date Modified"
        case .dateCreated: "Date Created"
        case .dateAdded: "Date Added"
        case .dateLastOpened: "Date Last Opened"
        case .size: "Size"
        case .kind: "Kind"
        case .label: "Tags"
        case .version: "Version"
        case .comments: "Comments"
        }
    }
}

/// How the pictures of a folder are ordered.
public enum FolderOrder: Sendable, Equatable {
    case sorted(SortKey, ascending: Bool)
    /// Finder's icon view with no sorting: the icons sit where they were put, read row by row like text.
    case iconPositions([String: CGPoint])

    public static let byName = FolderOrder.sorted(.name, ascending: true)

    public var label: String {
        switch self {
        case .sorted(let key, let ascending):
            let direction: String
            switch key {
            case .dateModified, .dateCreated, .dateAdded, .dateLastOpened: direction = ascending ? "oldest first" : "newest first"
            case .size: direction = ascending ? "smallest first" : "largest first"
            default: direction = ascending ? "A to Z" : "Z to A"
            }
            return "\(key.label), \(direction)"
        case .iconPositions: return "Icon positions"
        }
    }
}

/// One picture in a folder with the attributes Finder sorts by.
public struct FolderEntry: Sendable {
    public let url: URL
    public var name: String { url.lastPathComponent }
    let modified: Date?
    let created: Date?
    let added: Date?
    let size: Int?
    let kind: String
    let tags: [String]

    public init(url: URL, modified: Date? = nil, created: Date? = nil, added: Date? = nil, size: Int? = nil, kind: String = "", tags: [String] = []) {
        self.url = url
        self.modified = modified
        self.created = created
        self.added = added
        self.size = size
        self.kind = kind
        self.tags = tags
    }
}

public enum FolderScanner {
    private static let keys: [URLResourceKey] = [
        .isRegularFileKey, .contentTypeKey, .contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey,
        .fileSizeKey, .localizedTypeDescriptionKey, .tagNamesKey,
    ]

    public static func isImage(_ url: URL) -> Bool {
        contentType(of: url)?.conforms(to: .image) == true
    }

    /// A film (MOV, MP4, …), which is played rather than decoded.
    public static func isVideo(_ url: URL) -> Bool {
        contentType(of: url)?.conforms(to: .movie) == true
    }

    /// Pictures and films: everything PicViewer steps through.
    public static func isViewable(_ type: UTType?) -> Bool {
        guard let type else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    private static func contentType(of url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
    }

    /// Every picture and film directly in `folder` (hidden files skipped, like Finder does), unsorted.
    public static func entries(in folder: URL) -> [FolderEntry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  isViewable(values.contentType ?? UTType(filenameExtension: url.pathExtension))
            else { return nil }
            return FolderEntry(
                url: url,
                modified: values.contentModificationDate,
                created: values.creationDate,
                added: values.addedToDirectoryDate,
                size: values.fileSize,
                kind: values.localizedTypeDescription ?? "",
                tags: values.tagNames ?? []
            )
        }
    }

    /// The entries in the order Finder shows them.
    public static func sort(_ entries: [FolderEntry], by order: FolderOrder) -> [FolderEntry] {
        switch order {
        case .iconPositions(let positions):
            return sortByPosition(entries, positions: positions)
        case .sorted(let key, let ascending):
            // Spotlight attributes are only fetched when the sort needs them.
            var spotlight: [String: Any] = [:]
            if key == .dateLastOpened || key == .comments {
                let attribute = key == .dateLastOpened ? kMDItemLastUsedDate : kMDItemFinderComment
                for entry in entries {
                    if let item = MDItemCreateWithURL(nil, entry.url as CFURL), let value = MDItemCopyAttribute(item, attribute) {
                        spotlight[entry.name] = value
                    }
                }
            }
            return entries.sorted { a, b in
                let primary = compare(a, b, key: key, spotlight: spotlight)
                if primary != .orderedSame {
                    return ascending ? primary == .orderedAscending : primary == .orderedDescending
                }
                // Ties fall back to the name, A to Z, as in Finder.
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    private static func compare(_ a: FolderEntry, _ b: FolderEntry, key: SortKey, spotlight: [String: Any]) -> ComparisonResult {
        switch key {
        case .name, .version: return a.name.localizedStandardCompare(b.name)
        case .dateModified: return compare(a.modified, b.modified)
        case .dateCreated: return compare(a.created, b.created)
        case .dateAdded: return compare(a.added, b.added)
        case .dateLastOpened: return compare(spotlight[a.name] as? Date, spotlight[b.name] as? Date)
        case .size: return compare(a.size, b.size)
        case .kind: return a.kind.localizedStandardCompare(b.kind)
        case .label: return compare(a.tags.first, b.tags.first)
        case .comments: return compare(spotlight[a.name] as? String, spotlight[b.name] as? String)
        }
    }

    /// Missing values sort after present ones.
    private static func compare<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (a?, b?): return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        }
    }

    private static func compare(_ a: String?, _ b: String?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (a?, b?): return a.localizedStandardCompare(b)
        }
    }

    /// Row by row, top to bottom, then left to right. Icons a little out of line still count as the same row.
    static func sortByPosition(_ entries: [FolderEntry], positions: [String: CGPoint]) -> [FolderEntry] {
        let placed = entries.filter { positions[$0.name] != nil }
            .sorted { positions[$0.name]!.y < positions[$1.name]!.y }
        let unplaced = entries.filter { positions[$0.name] == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let rowTolerance: CGFloat = 24
        var rows: [[FolderEntry]] = []
        var rowTop: CGFloat = -.greatestFiniteMagnitude
        for entry in placed {
            let y = positions[entry.name]!.y
            if rows.isEmpty || y - rowTop > rowTolerance {
                rows.append([entry])
                rowTop = y
            } else {
                rows[rows.count - 1].append(entry)
            }
        }
        let ordered = rows.flatMap { row in row.sorted { positions[$0.name]!.x < positions[$1.name]!.x } }
        return ordered + unplaced
    }
}
