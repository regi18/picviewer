import CoreGraphics
import Foundation

/// Works out how Finder orders a folder, so the viewer steps through the pictures in that same order.
///
/// 1. Ask Finder (AppleScript) about a window showing the folder right now. This is the live truth, including the
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

/// Asks Finder through AppleScript how a window showing the folder is sorted. The first time, macOS asks the user to
/// let PicViewer control Finder; without that permission this returns `.unavailable`.
enum FinderLiveQuery {
    enum Answer {
        case order(FolderOrder)
        /// A window shows the folder, but in a view AppleScript cannot read the sort of.
        case style(FinderOrderResolver.ViewStyle)
        case unavailable
    }

    // Enumerations are compared inside the script and mapped to plain words, so nothing depends on how AppleScript
    // turns a Finder constant into text. Sorts the dictionary has no word for (Date Added, say) come back as
    // "unknown" and fall through to the .DS_Store.
    private static let script = """
    on run argv
        set folderPath to item 1 of argv
        tell application "Finder"
            repeat with w in (every Finder window)
                try
                    set t to target of w
                    if POSIX path of (t as alias) is folderPath then
                        set v to current view of w
                        if v is list view then
                            set c to sort column of list view options of w
                            set n to name of c
                            set d to "normal"
                            if sort direction of c is reversed then set d to "reversed"
                            set k to "unknown"
                            if n is name column then set k to "name"
                            if n is modification date column then set k to "dateModified"
                            if n is creation date column then set k to "dateCreated"
                            if n is size column then set k to "size"
                            if n is kind column then set k to "kind"
                            if n is label column then set k to "label"
                            if n is version column then set k to "version"
                            if n is comment column then set k to "comments"
                            return "list" & tab & k & tab & d
                        else if v is icon view then
                            set a to arrangement of icon view options of w
                            if a is not arranged or a is snap to grid then
                                set ns to name of every item of t
                                set ps to position of every item of t
                                set out to {"icon" & tab & "positions"}
                                repeat with i from 1 to count of ns
                                    set p to item i of ps
                                    set end of out to ((item 1 of p) as text) & tab & ((item 2 of p) as text) & tab & (item i of ns)
                                end repeat
                                set AppleScript's text item delimiters to linefeed
                                return out as text
                            end if
                            set k to "unknown"
                            if a is arranged by name then set k to "name"
                            if a is arranged by modification date then set k to "dateModified"
                            if a is arranged by creation date then set k to "dateCreated"
                            if a is arranged by size then set k to "size"
                            if a is arranged by kind then set k to "kind"
                            if a is arranged by label then set k to "label"
                            return "icon" & tab & k
                        else if v is column view then
                            return "column"
                        else
                            return "gallery"
                        end if
                    end if
                end try
            end repeat
        end tell
        return "none"
    end run
    """

    static func query(folder: URL) -> Answer {
        guard let output = run(folderPath: folder.standardizedFileURL.path + "/") else { return .unavailable }
        return parse(output)
    }

    static func parse(_ output: String) -> Answer {
        let lines = output.components(separatedBy: "\n")
        let head = lines.first?.components(separatedBy: "\t") ?? []
        switch head.first {
        case "list":
            guard head.count == 3, let key = SortKey(rawValue: head[1]) else { return .style(.list) }
            let ascending = head[2] == "reversed" ? !key.naturalAscending : key.naturalAscending
            return .order(.sorted(key, ascending: ascending))
        case "icon":
            if head.count == 2, head[1] == "positions" {
                var positions: [String: CGPoint] = [:]
                for line in lines.dropFirst() {
                    let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                    guard parts.count == 3, let x = Double(parts[0]), let y = Double(parts[1]) else { continue }
                    positions[String(parts[2])] = CGPoint(x: x, y: y)
                }
                return .order(.iconPositions(positions))
            }
            guard head.count == 2, let key = SortKey(rawValue: head[1]) else { return .style(.icon) }
            return .order(.sorted(key, ascending: key.naturalAscending))
        case "column": return .style(.column)
        case "gallery": return .style(.gallery)
        default: return .unavailable
        }
    }

    /// Runs the script with osascript, giving up after a few seconds so a busy Finder cannot hold up the viewer.
    private static func run(folderPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, folderPath]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        // Reading before waiting, so a long answer cannot fill the pipe and stall osascript.
        var data = Data()
        let reader = DispatchQueue(label: "picviewer.osascript.read")
        reader.async { data = output.fileHandleForReading.readDataToEndOfFile() }
        if done.wait(timeout: .now() + 4) == .timedOut {
            process.terminate()
            return nil
        }
        reader.sync {}
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        return text.isEmpty ? nil : text
    }
}
