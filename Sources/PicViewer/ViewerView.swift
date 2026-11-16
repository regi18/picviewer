import AppKit
import SwiftUI

struct ViewerView: View {
    @Bindable var model: ViewerModel

    var body: some View {
        // Everything sits below the title bar, which keeps the full width of the window. The info panel slides in
        // from the right and the picture re-centres in the space that is left.
        HStack(spacing: 0) {
            ImageCanvas(model: model)
            if model.showsInfo {
                InfoPanel(model: model)
                    .frame(width: 360)
                    .glass(in: RoundedRectangle(cornerRadius: GlassMetrics.panelCornerRadius, style: .continuous))
                    .padding([.top, .trailing, .bottom], GlassMetrics.inset)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.smooth(duration: 0.3), value: model.showsInfo)
        .background(Color.black.ignoresSafeArea())
    }
}

/// The picture, the arrows either side that show while the mouse moves, and messages.
private struct ImageCanvas: View {
    let model: ViewerModel

    @State private var controlsVisible = false
    @State private var isOverControl = false
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            Color.black

            content

            HStack {
                arrow("chevron.left", help: "Previous picture (←)", isEnabled: model.hasPrevious) { model.step(-1) }
                Spacer()
                arrow("chevron.right", help: "Next picture (→)", isEnabled: model.hasNext) { model.step(1) }
            }
            .padding(.horizontal, 16)
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .animation(.easeInOut(duration: 0.2), value: controlsVisible)

            if let message = model.message {
                VStack {
                    Spacer()
                    Text(message)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glass(in: Capsule())
                        .padding(.horizontal, 40)
                        .padding(.bottom, 24)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.message)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active = phase { poke() }
        }
        .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image = model.image {
            GeometryReader { geometry in
                // Fit the window, but never blow a small picture up past its real size.
                let natural = CGSize(width: CGFloat(image.width) / displayScale, height: CGFloat(image.height) / displayScale)
                let scale = min(1, geometry.size.width / natural.width, geometry.size.height / natural.height)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: natural.width * scale, height: natural.height * scale)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        } else if model.loadFailed {
            ContentUnavailableView("Can't Open This Picture", systemImage: "exclamationmark.triangle",
                                   description: Text(model.current?.lastPathComponent ?? ""))
        } else if model.folder == nil {
            VStack(spacing: 14) {
                ContentUnavailableView("No Picture Open", systemImage: "photo",
                                       description: Text("Open a picture, or drop one here."))
                    .fixedSize()
                Button("Open…") { NSApp.sendAction(#selector(AppDelegate.openDocument(_:)), to: nil, from: nil) }
                    .controlSize(.large)
                    .glassButtonStyle()
            }
        } else if model.files.isEmpty {
            ContentUnavailableView("No Pictures", systemImage: "photo.on.rectangle",
                                   description: Text("This folder has no pictures left."))
        }
    }

    private func arrow(_ symbol: String, help: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .help(help)
        .opacity(isEnabled ? 1 : 0)
        .disabled(!isEnabled)
        .onHover { isOverControl = $0; poke() }
    }

    /// Shows the arrows, and hides them again after the mouse has rested for a moment (unless it rests on one).
    private func poke() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, !isOverControl else { return }
            controlsVisible = false
            if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }
}
