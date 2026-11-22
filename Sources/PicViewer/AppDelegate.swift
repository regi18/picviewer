import AppKit
import SwiftUI

@main
enum PicViewerMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// One window; opening another picture replaces the one on screen. Every action lives in the menu bar with its
/// shortcut, so the keys work wherever the focus is.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSUserInterfaceValidations {
    let model = ViewerModel()
    private var window: NSWindow!
    private let counter: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.alignment = .right
        field.lineBreakMode = .byClipping
        return field
    }()
    private var hasLaunched = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Pictures look best on dark grey and black, whatever the system appearance.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = makeMainMenu()
        makeWindow()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        hasLaunched = true
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        model.open(url)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // The Finder sort may have changed while PicViewer was in the background.
        if hasLaunched { model.refreshFolder() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Window

    private func makeWindow() {
        let hosting = NSHostingController(rootView: ViewerView(model: model))
        hosting.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.title = "PicViewer"
        window.backgroundColor = .black
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 480, height: 340)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("PicViewerMain")

        let toolbar = NSToolbar(identifier: "PicViewerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // The position goes in the toolbar rather than the window subtitle: a subtitle lifts the title off the line
        // of the window buttons.
        model.onTitleChange = { [weak self] title, position in
            guard let self else { return }
            window.title = title
            window.representedURL = model.current
            counter.stringValue = position
        }
    }

    // MARK: Actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .folder]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.open(url)
    }

    @objc func previousPicture(_ sender: Any?) { model.step(-1) }
    @objc func nextPicture(_ sender: Any?) { model.step(1) }
    @objc func togglePlayback(_ sender: Any?) { model.togglePlayback() }
    @objc func rotateClockwise(_ sender: Any?) { model.rotate(clockwise: true) }
    @objc func rotateCounterclockwise(_ sender: Any?) { model.rotate(clockwise: false) }
    @objc func moveToTrash(_ sender: Any?) { model.moveToTrash() }
    @objc func undoMoveToTrash(_ sender: Any?) { model.undoTrash() }
    @objc func toggleInfo(_ sender: Any?) { model.showsInfo.toggle() }
    @objc func showInFinder(_ sender: Any?) { model.revealInFinder() }

    private lazy var settings = SettingsWindowController()
    @objc func showSettings(_ sender: Any?) { settings.showWindow(sender) }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(previousPicture(_:)): return model.hasPrevious
        case #selector(nextPicture(_:)): return model.hasNext
        case #selector(togglePlayback(_:)):
            (item as? NSMenuItem)?.title = model.isPlaying ? "Pause" : "Play"
            return model.player != nil
        case #selector(rotateClockwise(_:)), #selector(rotateCounterclockwise(_:)), #selector(moveToTrash(_:)), #selector(showInFinder(_:)):
            return model.current != nil
        case #selector(undoMoveToTrash(_:)): return model.canUndoTrash
        case #selector(toggleInfo(_:)):
            (item as? NSMenuItem)?.title = model.showsInfo ? "Hide Info" : "Show Info"
            return true
        default: return true
        }
    }

    // MARK: Menu bar

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = submenu(in: main, title: "PicViewer")
        app.addItem(withTitle: "About PicViewer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide PicViewer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit PicViewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(in: main, title: "File")
        file.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        file.addItem(item("Show in Finder", #selector(showInFinder(_:)), "r", [.command, .option]))
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = submenu(in: main, title: "Edit")
        edit.addItem(withTitle: "Undo Move to Trash", action: #selector(undoMoveToTrash(_:)), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let picture = submenu(in: main, title: "Picture")
        picture.addItem(item("Previous", #selector(previousPicture(_:)), arrow(NSLeftArrowFunctionKey), []))
        picture.addItem(item("Next", #selector(nextPicture(_:)), arrow(NSRightArrowFunctionKey), []))
        picture.addItem(item("Play", #selector(togglePlayback(_:)), " ", []))
        picture.addItem(.separator())
        picture.addItem(item("Rotate Clockwise", #selector(rotateClockwise(_:)), "r", [.command]))
        picture.addItem(item("Rotate Counterclockwise", #selector(rotateCounterclockwise(_:)), "r", [.command, .shift]))
        picture.addItem(.separator())
        picture.addItem(item("Move to Trash", #selector(moveToTrash(_:)), "\u{8}", [.command]))

        let view = submenu(in: main, title: "View")
        view.addItem(item("Show Info", #selector(toggleInfo(_:)), "i", [.command]))
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        let windowMenu = submenu(in: main, title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        return main
    }

    private func submenu(in main: NSMenu, title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func arrow(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt16(key))!))
    }

    // MARK: Toolbar

    private enum ToolbarID {
        static let rotateLeft = NSToolbarItem.Identifier("rotateLeft")
        static let rotateRight = NSToolbarItem.Identifier("rotateRight")
        static let trash = NSToolbarItem.Identifier("trash")
        static let info = NSToolbarItem.Identifier("info")
        static let counter = NSToolbarItem.Identifier("counter")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ToolbarID.counter, .space, ToolbarID.rotateLeft, ToolbarID.rotateRight, ToolbarID.trash, .space, ToolbarID.info]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == ToolbarID.counter {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Position"
            item.view = counter
            item.isBordered = false
            return item
        }
        let specs: [NSToolbarItem.Identifier: (String, String, Selector)] = [
            ToolbarID.rotateLeft: ("Rotate Counterclockwise (⇧⌘R)", "rotate.left", #selector(rotateCounterclockwise(_:))),
            ToolbarID.rotateRight: ("Rotate Clockwise (⌘R)", "rotate.right", #selector(rotateClockwise(_:))),
            ToolbarID.trash: ("Move to Trash (⌘⌫)", "trash", #selector(moveToTrash(_:))),
            ToolbarID.info: ("Info (⌘I)", "info.circle", #selector(toggleInfo(_:))),
        ]
        guard let (label, symbol, action) = specs[id] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.action = action
        item.target = self
        item.isBordered = true
        return item
    }
}
