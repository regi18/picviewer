import Foundation

/// Calls back (debounced) whenever files are added to, removed from or renamed in a folder.
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pending: DispatchWorkItem?

    init?(folder: URL, onChange: @escaping () -> Void) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            self?.pending?.cancel()
            let work = DispatchWorkItem(block: onChange)
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        pending?.cancel()
        source.cancel()
    }
}
