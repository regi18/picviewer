import AppKit
import PicViewerCore
import SwiftUI

/// The app's one setting, in a standard Settings window.
struct SettingsView: View {
    @AppStorage(RotationMode.defaultsKey) private var mode: RotationMode = .orientationTag

    var body: some View {
        Form {
            Picker("Rotate pictures by:", selection: $mode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Changing the orientation tag")
                    Text("Instant, works for every format, and the file stays byte for byte the same apart from one tag. Apps that ignore the tag show the picture unrotated.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tag(RotationMode.orientationTag)
                .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Turning the pixels (JPEG only)")
                    Text("The picture looks right everywhere. The compressed data is rearranged, never re-encoded, so no quality is lost. If a JPEG can’t be turned this way, or for other formats, the orientation tag is used instead.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tag(RotationMode.pixels)
            }
            .pickerStyle(.radioGroup)
        }
        .padding(20)
        .frame(width: 480)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init() {
        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        self.init(window: window)
        window.center()
    }
}
