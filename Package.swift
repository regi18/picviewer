// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PicViewer",
    platforms: [.macOS(.v14)],
    targets: [
        // Folder ordering, lossless rotation and metadata live apart from the UI so they can be tested without a window.
        .target(name: "PicViewerCore"),
        .executableTarget(name: "PicViewer", dependencies: ["PicViewerCore"]),
        .testTarget(name: "PicViewerCoreTests", dependencies: ["PicViewerCore"]),
    ],
    // Swift 5 mode, like Autopost: AppKit and ImageIO types are not Sendable yet.
    swiftLanguageModes: [.v5]
)
