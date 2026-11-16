import SwiftUI

/// Liquid Glass on macOS 26 and later; the closest material on earlier systems.
///
/// The glass APIs only exist in the macOS 26 SDK, which ships with Swift 6.2. The Intel CI runner still builds with
/// the macOS 15 SDK, so the check happens at compile time as well as at run time.
extension View {
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            materialBackground(in: shape)
        }
        #else
        materialBackground(in: shape)
        #endif
    }

    private func materialBackground<S: Shape>(in shape: S) -> some View {
        background(.regularMaterial, in: shape)
            .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
    }

    /// A glass push button on macOS 26 and later, a standard bordered one before.
    @ViewBuilder
    func glassButtonStyle() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
        #else
        buttonStyle(.bordered)
        #endif
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
