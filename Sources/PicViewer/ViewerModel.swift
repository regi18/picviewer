import AppKit
import Observation
import PicViewerCore

/// The open folder, the picture on screen, and everything that can be done to it.
@MainActor
@Observable
final class ViewerModel {
    private(set) var files: [URL] = []
    private(set) var index = 0
    private(set) var image: CGImage?
    private(set) var info: ImageInfo?
    private(set) var loadFailed = false
    private(set) var orderLabel: String?
    private(set) var message: String?
    private(set) var folder: URL?
    /// Open the first time; after that, the way it was last left.
    var showsInfo = UserDefaults.standard.object(forKey: "showsInfo") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsInfo, forKey: "showsInfo") }
    }

    /// Set by the window, so the title bar follows the picture.
    @ObservationIgnored var onTitleChange: ((_ title: String, _ position: String) -> Void)?

    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var cache: [URL: CGImage] = [:]
    @ObservationIgnored private var shownURL: URL?
    @ObservationIgnored private var imageTask: Task<Void, Never>?
    @ObservationIgnored private var infoTask: Task<Void, Never>?
    @ObservationIgnored private var orderTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var editChain: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var lastTrashed: (original: URL, trashed: URL)?
    @ObservationIgnored private var lastStep = 1

    var current: URL? { files.indices.contains(index) ? files[index] : nil }
    var hasPrevious: Bool { index > 0 }
    var hasNext: Bool { index < files.count - 1 }
    var canUndoTrash: Bool { lastTrashed != nil }

    /// Large enough to fill the biggest screen at full sharpness, but no bigger: decoding a 26 MP RAW to full size
    /// for a 3K screen would only cost time and memory.
    private var maxPixelSize: Int {
        let longest = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 3000
        return Int(longest)
    }

    // MARK: Opening

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let folder = isFolder ? url : url.deletingLastPathComponent()
        let name = isFolder ? nil : url.lastPathComponent

        self.folder = folder
        cache.removeAll()
        shownURL = nil
        lastTrashed = nil
        files = name.map { [folder.appendingPathComponent($0)] } ?? []
        index = 0
        orderLabel = nil
        showCurrent()
        watcher = FolderWatcher(folder: folder) { [weak self] in self?.refreshFolder() }
        refreshFolder(keeping: name)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// Lists the folder again and sorts it the way Finder shows it right now. Runs when a folder opens, when its
    /// files change, and whenever the app comes to the front, in case the Finder sort changed meanwhile.
    func refreshFolder(keeping name: String? = nil) {
        guard let folder else { return }
        let keep = name ?? current?.lastPathComponent
        orderTask?.cancel()
        orderTask = Task {
            let (urls, order) = await Task.detached(priority: .userInitiated) {
                let order = FinderOrderResolver.resolve(folder: folder)
                let entries = FolderScanner.sort(FolderScanner.entries(in: folder), by: order.order)
                return (entries.map(\.url), order)
            }.value
            guard !Task.isCancelled, folder == self.folder else { return }
            NSLog("PicViewer: %@ sorted by %@ (%@)", folder.path, order.order.label, order.source)
            orderLabel = "\(order.order.label)  ·  \(order.source)"
            apply(urls, keeping: keep)
        }
    }

    private func apply(_ urls: [URL], keeping name: String?) {
        let previousIndex = index
        // A picture opened from a folder whose listing does not show it (an odd extension, say) stays viewable.
        var urls = urls
        if let name, let folder, !urls.contains(where: { $0.lastPathComponent == name }),
           files.count == 1, files.first?.lastPathComponent == name, FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            urls.insert(folder.appendingPathComponent(name), at: 0)
        }
        files = urls
        if let name, let found = urls.firstIndex(where: { $0.lastPathComponent == name }) {
            index = found
        } else {
            index = max(0, min(previousIndex, urls.count - 1))
        }
        let keepURLs = Set(neighbourhood)
        cache = cache.filter { keepURLs.contains($0.key) }
        if current != shownURL { showCurrent() } else { updateTitle(); prefetch() }
    }

    // MARK: Navigation

    func step(_ delta: Int) {
        let target = index + delta
        guard files.indices.contains(target) else { return }
        lastStep = delta
        index = target
        showCurrent()
    }

    private func showCurrent() {
        updateTitle()
        imageTask?.cancel()
        infoTask?.cancel()
        prefetchTask?.cancel()
        loadFailed = false
        shownURL = current
        guard let url = current else {
            image = nil
            info = nil
            return
        }

        infoTask = Task {
            let info = await Task.detached(priority: .userInitiated) { try? ImageInfo(url: url) }.value
            guard !Task.isCancelled else { return }
            self.info = info
        }

        if let cached = cache[url] {
            image = cached
            prefetch()
            return
        }
        let size = maxPixelSize
        imageTask = Task {
            if ImageDecoder.isRaw(url) {
                let preview = await Task.detached(priority: .userInitiated) { ImageDecoder.preview(url, maxPixelSize: size) }.value
                guard !Task.isCancelled else { return }
                if let preview { image = preview }
            }
            let full = await Task.detached(priority: .userInitiated) { ImageDecoder.full(url, maxPixelSize: size) }.value
            guard !Task.isCancelled else { return }
            if let full {
                cache[url] = full
                image = full
            } else if image == nil || shownURL == url {
                image = nil
                loadFailed = true
            }
            prefetch()
        }
    }

    private var neighbourhood: [URL] {
        // The next picture in the direction of travel first.
        [index, index + lastStep, index - lastStep].filter { files.indices.contains($0) }.map { files[$0] }
    }

    /// Decodes the pictures either side, so the next arrow press is instant.
    private func prefetch() {
        let wanted = neighbourhood
        cache = cache.filter { wanted.contains($0.key) }
        let missing = wanted.filter { cache[$0] == nil && $0 != current }
        guard !missing.isEmpty else { return }
        let size = maxPixelSize
        prefetchTask = Task {
            for url in missing {
                let image = await Task.detached(priority: .utility) { ImageDecoder.full(url, maxPixelSize: size) }.value
                guard !Task.isCancelled else { return }
                if let image, neighbourhood.contains(url) { cache[url] = image }
            }
        }
    }

    private func updateTitle() {
        let title = current?.lastPathComponent ?? "PicViewer"
        let position = files.count > 1 ? "\(index + 1) of \(files.count)" : ""
        onTitleChange?(title, position)
    }

    // MARK: Editing

    /// Turns the picture a quarter turn on disk, the way Settings says (the orientation tag, or the JPEG's pixels,
    /// losslessly), then turns the picture on screen to match without decoding it again. Turns queue up, so pressing
    /// ⌘R three times quickly does three turns in order.
    func rotate(clockwise: Bool) {
        guard let url = current else { return }
        let previous = editChain
        let mode = RotationMode.current
        editChain = Task {
            await previous?.value
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try LosslessRotation.rotate(url, clockwise: clockwise, mode: mode)
                }.value
                if let note = outcome.note { show(message: note) }
            } catch {
                show(message: error.localizedDescription)
                return
            }
            if let cached = cache[url], let turned = Self.turn(cached, clockwise: clockwise) {
                cache[url] = turned
            } else {
                cache[url] = nil
            }
            if url == current {
                if let cached = cache[url] {
                    image = cached
                    shownURL = url
                    infoTask?.cancel()
                    infoTask = Task {
                        let info = await Task.detached { try? ImageInfo(url: url) }.value
                        if !Task.isCancelled, url == current { self.info = info }
                    }
                } else {
                    showCurrent()
                }
            }
        }
    }

    func moveToTrash() {
        guard let url = current else { return }
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            lastTrashed = (trashed as URL?).map { (url, $0) }
            cache[url] = nil
            files.remove(at: index)
            // Stay on the same spot, which now holds the next picture; at the end, step back to the new last one.
            index = max(0, min(index, files.count - 1))
            showCurrent()
        } catch {
            show(message: "Could not move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)")
        }
    }

    func undoTrash() {
        guard let (original, trashed) = lastTrashed else { return }
        do {
            try FileManager.default.moveItem(at: trashed, to: original)
            lastTrashed = nil
            refreshFolder(keeping: original.lastPathComponent)
        } catch {
            show(message: "Could not put \(original.lastPathComponent) back: \(error.localizedDescription)")
        }
    }

    func revealInFinder() {
        guard let url = current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func show(message: String) {
        self.message = message
        messageTask?.cancel()
        messageTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self.message = nil }
        }
    }

    /// The same picture a quarter turn round, exactly what decoding the rotated file would give.
    private static func turn(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let width = image.height, height = image.width
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: image.bitsPerComponent,
                                      bytesPerRow: 0, space: space, bitmapInfo: image.bitmapInfo.rawValue)
                ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Core Graphics has its origin bottom left, so a clockwise turn on screen is a negative angle here.
        if clockwise {
            context.translateBy(x: 0, y: CGFloat(height))
            context.rotate(by: -.pi / 2)
        } else {
            context.translateBy(x: CGFloat(width), y: 0)
            context.rotate(by: .pi / 2)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
