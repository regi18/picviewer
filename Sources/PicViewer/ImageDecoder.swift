import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decodes pictures for the screen: upright, in their own colour space, scaled to at most the screen's size.
enum ImageDecoder {
    static func isRaw(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) == true
    }

    /// For a RAW file, the JPEG the camera embedded, when it is big enough to look sharp. Much faster than
    /// developing the RAW, so stepping through a folder of RAWs stays quick.
    static func preview(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = thumbnail(source, maxPixelSize: maxPixelSize, fromImage: false)
        else { return nil }
        // Some cameras embed a tiny 160×120 preview, letterboxed whatever the picture's shape. Not worth showing.
        let full = pixelSize(source)
        guard full.width > 0, full.height > 0 else { return nil }
        let fullAspect = full.width / full.height
        let aspect = Double(image.width) / Double(image.height)
        guard abs(aspect - fullAspect) / fullAspect < 0.02, max(image.width, image.height) >= 1000 else { return nil }
        return image
    }

    static func full(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source, maxPixelSize: maxPixelSize, fromImage: true)
    }

    private static func thumbnail(_ source: CGImageSource, maxPixelSize: Int, fromImage: Bool) -> CGImage? {
        let options: [CFString: Any] = [
            fromImage ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func pixelSize(_ source: CGImageSource) -> CGSize {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return .zero }
        let width = properties[kCGImagePropertyPixelWidth] as? Double ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Double ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}
