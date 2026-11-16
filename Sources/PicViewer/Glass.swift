import SwiftUI

/// Liquid Glass on macOS 26 and later; the closest material on earlier systems.
extension View {
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            materialBackground(in: shape)
        }
    }

    private func materialBackground<S: Shape>(in shape: S) -> some View {
        background(.regularMaterial, in: shape)
            .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
    }

    /// A glass push button on macOS 26 and later, a standard bordered one before.
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// The info panel floats this far from the window edges, with corners that follow the window's own.
enum GlassMetrics {
    static let inset: CGFloat = 8
    static var panelCornerRadius: CGFloat {
        if #available(macOS 26, *) { return 18 }
        return 10
    }
}
