import CoreGraphics
import Foundation

/// Works out how Finder orders a folder, so the viewer steps through the pictures in that same order.
///
/// 1. Ask Finder (Apple Events) about a window showing the folder right now. This is the live truth, including the
///    icon positions of an unsorted icon view.
/// 2. Read the folder's .DS_Store, where Finder saves each folder's view settings.
/// 3. Read Finder's default view settings.
/// 4. Fall back to names, A to Z.
public enum FinderOrderResolver {
    public struct Result: Sendable {
        public let order: FolderOrder
        /// Where the order came from, for the info panel and the log.
        public let source: String
    }

    /// The Finder view styles, as .DS_Store files and Finder's preferences name them.
    enum ViewStyle: String {
        case icon = "icnv"
        case list = "Nlsv"
        case column = "clmv"
        case gallery = "glyv"
        case coverFlow = "Flwv"
    }

    public static func resolve(folder: URL, askFinder: Bool = true) -> Result {
        var liveStyle: ViewStyle?
        if askFinder {
            switch FinderLiveQuery.query(folder: folder) {
            case .order(let order):
                return Result(order: order, source: "Finder window")
            case .style(let style):
                liveStyle = style
            case .unavailable:
                break
            }
        }
        if let order = storedOrder(folder: folder, liveStyle: liveStyle) {
            return order
        }
        return Result(order: .byName, source: "Default")
    }

    // MARK: Saved settings

    static func storedOrder(folder: URL, liveStyle: ViewStyle?) -> Result? {
        let records = DSStore(url: folder.appendingPathComponent(".DS_Store"))?.folderRecords() ?? [:]
        let defaults = UserDefaults(suiteName: "com.apple.finder")
        let standard = defaults?.dictionary(forKey: "StandardViewSettings") ?? [:]

        var style = liveStyle
        if style == nil, case .type(let code)? = records["vstl"] { style = ViewStyle(rawValue: code) }
        if style == nil, let code = defaults?.string(forKey: "FXPreferredViewStyle") { style = ViewStyle(rawValue: code) }
        let source = records.isEmpty ? "Finder defaults" : "Folder view settings"

        switch style ?? .icon {
        case .list, .coverFlow:
            let settings = DSStore.plist(records["lsvP"]) ?? DSStore.plist(records["lsvp"])
                ?? standard["ExtendedListViewSettingsV2"] as? [String: Any]
                ?? standard["ListViewSettings"] as? [String: Any]
            guard let settings else { return nil }
            return listOrder(settings).map { Result(order: $0, source: source) }
        case .icon:
            let settings = DSStore.plist(records["icvp"]) ?? standard["IconViewSettings"] as? [String: Any]
            return settings.flatMap(arrangedOrder).map { Result(order: $0, source: source) }
        case .gallery:
            let settings = DSStore.plist(records["glvp"]) ?? standard["GalleryViewSettings"] as? [String: Any]
            return settings.flatMap(arrangedOrder).map { Result(order: $0, source: source) }
        case .column:
            let settings = DSStore.plist(records["clvp"]) ?? standard["ColumnViewSettings"] as? [String: Any]
            return settings.flatMap(arrangedOrder).map { Result(order: $0, source: source) }
        }
    }

    /// A list view's sort column and its direction. Older files keep the columns in a dictionary keyed by
    /// identifier, newer ones in an array of dictionaries with an "identifier".
    static func listOrder(_ settings: [String: Any]) -> FolderOrder? {
        let column = (settings["sortColumn"] as? String) ?? "name"
        guard let key = SortKey(rawValue: column) else { return nil }
        var ascending: Bool?
        if let columns = settings["columns"] as? [String: Any], let info = columns[column] as? [String: Any] {
            ascending = info["ascending"] as? Bool
        } else if let columns = settings["columns"] as? [[String: Any]],
                  let info = columns.first(where: { $0["identifier"] as? String == column }) {
            ascending = info["ascending"] as? Bool
        }
        return .sorted(key, ascending: ascending ?? key.naturalAscending)
    }

    /// Icon, gallery and column views have one "Sort By" choice and always use its natural direction.
    /// "none" and "grid" mean the icons stay where they were put, which only a live Finder window can tell.
    static func arrangedOrder(_ settings: [String: Any]) -> FolderOrder? {
        guard let arrangement = (settings["arrangeBy"] ?? settings["ArrangeBy"]) as? String,
              let key = SortKey(rawValue: arrangement)
        else { return nil }
        return .sorted(key, ascending: key.naturalAscending)
    }
}

/// Asks Finder how a window showing the folder is sorted, with Apple Events sent straight from PicViewer. These are the
/// questions an AppleScript would ask, without starting osascript and compiling a script every time: three to five
/// round trips of a few milliseconds each, unless Finder is busy. The first time, macOS asks the user to let
/// PicViewer control Finder; without that permission, or with Finder not running, this returns `.unavailable`.
enum FinderLiveQuery {
    enum Answer {
        case order(FolderOrder)
        /// A window shows the folder, but in a view whose sort can't be read (column or gallery view, or a sort the
        /// scripting dictionary has no word for, like Date Added).
        case style(FinderOrderResolver.ViewStyle)
        case unavailable
    }

    static func query(folder: URL) -> Answer {
        let finder = FinderScripting()
        guard let window = finder.window(showing: folder) else { return .unavailable }
        switch finder.get("pvew", of: window)?.enumCodeValue.fourCharacterString {
        case "lsvw":
            let column = FinderScripting.property("srtc", of: FinderScripting.property("lvop", of: window))
            guard let name = finder.get("pnam", of: column)?.enumCodeValue.fourCharacterString else { return .style(.list) }
            let direction = finder.get("sord", of: column)?.enumCodeValue.fourCharacterString ?? "snrm"
            return listAnswer(column: name, direction: direction)
        case "icnv":
            let options = FinderScripting.property("icop", of: window)
            guard let arrangement = finder.get("iarr", of: options)?.enumCodeValue.fourCharacterString else { return .style(.icon) }
            if arrangement == "narr" || arrangement == "grda" {
                // Icons left where they were put: read every position. The one slow case, as Finder has to lay out
                // the whole folder to answer.
                let items = FinderScripting.every("cobj", of: FinderScripting.property("fvtg", of: window))
                guard let names = finder.get("pnam", of: items)?.listValues.compactMap(\.stringValue),
                      let points = finder.get("posn", of: items)?.listValues.map(FinderScripting.point)
                else { return .style(.icon) }
                return positionsAnswer(names: names, points: points)
            }
            return iconAnswer(arrangement: arrangement)
        case "clvw":
            return .style(.column)
        case .some:
            return .style(.gallery)
        case nil:
            return .unavailable
        }
    }

    /// A list view sorted by a column, from the codes Finder's dictionary uses for the column and direction.
    static func listAnswer(column: String, direction: String) -> Answer {
        let keys = ["elsn": SortKey.name, "elsm": .dateModified, "elsc": .dateCreated, "elss": .size, "elsk": .kind,
                    "elsl": .label, "elsv": .version, "elsC": .comments]
        guard let key = keys[column] else { return .style(.list) }
        let ascending = direction == "srvs" ? !key.naturalAscending : key.naturalAscending
        return .order(.sorted(key, ascending: ascending))
    }

    /// An icon view's Sort By, which always runs in its natural direction.
    static func iconAnswer(arrangement: String) -> Answer {
        let keys = ["nama": SortKey.name, "mdta": .dateModified, "cdta": .dateCreated, "siza": .size, "kina": .kind,
                    "laba": .label]
        guard let key = keys[arrangement] else { return .style(.icon) }
        return .order(.sorted(key, ascending: key.naturalAscending))
    }

    static func positionsAnswer(names: [String], points: [CGPoint?]) -> Answer {
        var positions: [String: CGPoint] = [:]
        for (name, point) in zip(names, points) {
            if let point { positions[name] = point }
        }
        return .order(.iconPositions(positions))
    }
}

/// Just enough of the Apple Event object model to ask Finder for properties: object specifiers for properties,
/// indexed elements and every element, and a "get" event sent with a timeout.
struct FinderScripting {
    private let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
    /// Seconds to wait for each answer, so a busy Finder can't hold up the viewer for long.
    var timeout: TimeInterval = 2

    /// The frontmost Finder window or tab showing `folder`, if any.
    func window(showing folder: URL) -> NSAppleEventDescriptor? {
        let wanted = Self.normalized(folder)
        let windows = Self.every("brow", of: .null())
        // One question for all windows at once. It fails when a window shows something without a URL, like
        // Recents or a search, and then the windows are asked one by one.
        if let urls = get("pURL", of: Self.property("fvtg", of: windows))?.listValues {
            guard let index = urls.firstIndex(where: { Self.normalized($0.stringValue) == wanted }) else { return nil }
            return Self.element("brow", index: index + 1, of: .null())
        }
        let count = Int(send(Self.event("core", "cnte", [
            keyDirectObject: .null(), Self.code("kocl"): NSAppleEventDescriptor(typeCode: Self.code("brow")),
        ]))?.int32Value ?? 0)
        for index in 1 ... max(1, min(count, 50)) where count > 0 {
            let window = Self.element("brow", index: index, of: .null())
            if Self.normalized(get("pURL", of: Self.property("fvtg", of: window))?.stringValue) == wanted { return window }
        }
        return nil
    }

    func get(_ property: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        send(Self.event("core", "getd", [keyDirectObject: Self.property(property, of: container)]))
    }

    private func send(_ event: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        // Sent to Finder only if it's already running; Finder isn't launched just to be asked.
        guard let reply = try? event.sendEvent(options: [.waitForReply], timeout: timeout) else { return nil }
        if let error = reply.paramDescriptor(forKeyword: keyErrorNumber), error.int32Value != 0 { return nil }
        return reply.paramDescriptor(forKeyword: keyDirectObject)
    }

    private static func event(_ eventClass: String, _ id: String, _ parameters: [AEKeyword: NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: code(eventClass), eventID: code(id), targetDescriptor: FinderScripting().target,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        for (keyword, value) in parameters { event.setParam(value, forKeyword: keyword) }
        return event
    }

    static func property(_ property: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(wanting: "prop", of: container, form: "prop", data: NSAppleEventDescriptor(typeCode: code(property)))
    }

    static func element(_ elementClass: String, index: Int, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(wanting: elementClass, of: container, form: "indx", data: NSAppleEventDescriptor(int32: Int32(index)))
    }

    static func every(_ elementClass: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        var all = code("all ")
        let data = NSAppleEventDescriptor(descriptorType: code("abso"), bytes: &all, length: MemoryLayout<FourCharCode>.size)!
        return specifier(wanting: elementClass, of: container, form: "indx", data: data)
    }

    private static func specifier(wanting wanted: String, of container: NSAppleEventDescriptor, form: String,
                                  data: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record().coerce(toDescriptorType: code("obj "))!
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: code(wanted)), forKeyword: code("want"))
        specifier.setDescriptor(container, forKeyword: code("from"))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        specifier.setDescriptor(data, forKeyword: code("seld"))
        return specifier
    }

    /// An item position: a list of two numbers, or an old QuickDraw point (vertical first).
    static func point(_ descriptor: NSAppleEventDescriptor) -> CGPoint? {
        let values = descriptor.listValues
        if values.count == 2 {
            return CGPoint(x: Double(values[0].int32Value), y: Double(values[1].int32Value))
        }
        guard let point = descriptor.coerce(toDescriptorType: code("QDpt")), point.data.count == 4 else { return nil }
        let shorts = point.data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        return CGPoint(x: Double(shorts[1]), y: Double(shorts[0]))
    }

    /// Paths compared without symbolic links or a trailing slash, so /tmp/x/ matches /private/tmp/x.
    static func normalized(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    static func normalized(_ urlString: String?) -> String? {
        guard let urlString, let url = URL(string: urlString), url.isFileURL else { return nil }
        return normalized(url)
    }

    static func code(_ text: String) -> FourCharCode { text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }
}

extension NSAppleEventDescriptor {
    /// The items of a list, or the descriptor itself when it isn't one.
    var listValues: [NSAppleEventDescriptor] {
        guard descriptorType == typeAEList else { return [self] }
        return numberOfItems == 0 ? [] : (1 ... numberOfItems).compactMap { atIndex($0) }
    }
}

extension FourCharCode {
    var fourCharacterString: String {
        String(bytes: [24, 16, 8, 0].map { UInt8((self >> $0) & 0xFF) }, encoding: .macOSRoman) ?? ""
    }
}
