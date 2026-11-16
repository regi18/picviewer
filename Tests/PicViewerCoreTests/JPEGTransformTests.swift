import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PicViewerCore

/// The lossless pixel rotation: blocks must land exactly where jpegtran puts them, four turns must give back the very
/// same coefficients, and anything that cannot be done losslessly must fall back to the orientation tag.
final class JPEGTransformTests: XCTestCase {
    private var folder: URL!
    /// Homebrew's jpegtran. The tests that need it skip without it.
    private let jpegtran = "/opt/homebrew/bin/jpegtran"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PicViewerJPEG-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Against jpegtran

    func testEveryOrientationMatchesJpegtran() throws {
        guard FileManager.default.isExecutableFile(atPath: jpegtran) else { throw XCTSkip("jpegtran not installed") }
        // Quality 1 gives 4:4:4, lower qualities 4:2:0; plus greyscale. All sizes a whole number of 16×16 MCUs.
        let cases: [(String, Double, Bool)] = [("444", 1.0, false), ("420", 0.7, false), ("grey", 0.8, true)]
        for (name, quality, grey) in cases {
            let url = try writeJPEG(name: "\(name).jpg", width: 96, height: 64, quality: quality, grey: grey)
            let original = try [UInt8](Data(contentsOf: url))
            for orientation in 2...8 {
                let baked = try JPEGLosslessTransform.bake(original, orientation: orientation)
                let reference = try run(jpegtran, ["-perfect", "-copy", "none"] + jpegtranArguments(orientation) + [url.path])
                XCTAssertTrue(try JPEGLosslessTransform.Picture(baked).sameImage(as: JPEGLosslessTransform.Picture(reference)),
                              "\(name) orientation \(orientation): coefficients differ from jpegtran")
                XCTAssertEqual(try decodedPixels(Data(baked)), try decodedPixels(Data(reference)),
                               "\(name) orientation \(orientation): pixels differ from jpegtran")
            }
        }
    }

    func testRestartMarkersAreReadAndDropped() throws {
        guard FileManager.default.isExecutableFile(atPath: jpegtran) else { throw XCTSkip("jpegtran not installed") }
        let url = try writeJPEG(name: "plain.jpg", width: 128, height: 96, quality: 0.8)
        let restarted = try run(jpegtran, ["-restart", "1", "-copy", "all", url.path])
        XCTAssertTrue(restarted.contains(0xD0) && restarted.count > 0)
        let baked = try JPEGLosslessTransform.bake(restarted, orientation: 6)
        let reference = try run(jpegtran, ["-perfect", "-rotate", "90", url.path])
        XCTAssertTrue(try JPEGLosslessTransform.Picture(baked).sameImage(as: JPEGLosslessTransform.Picture(reference)))
    }

    func testProgressiveFallsBackToTheTag() throws {
        guard FileManager.default.isExecutableFile(atPath: jpegtran) else { throw XCTSkip("jpegtran not installed") }
        let plain = try writeJPEG(name: "plain.jpg", width: 64, height: 64, quality: 0.8, orientation: 1)
        let url = folder.appendingPathComponent("progressive.jpg")
        try Data(run(jpegtran, ["-progressive", "-copy", "all", plain.path])).write(to: url)
        XCTAssertThrowsError(try JPEGLosslessTransform.bake([UInt8](Data(contentsOf: url)), orientation: 6))
        try assertFallsBackToTag(url)
    }

    // MARK: Through LosslessRotation

    func testFourTurnsGiveBackTheSameCoefficients() throws {
        for (quality, grey) in [(1.0, false), (0.75, false), (0.9, true)] {
            let url = try writeJPEG(name: "turn.jpg", width: 160, height: 96, quality: quality, grey: grey, orientation: 1)
            let original = try JPEGLosslessTransform.Picture([UInt8](Data(contentsOf: url)))
            for clockwise in [true, false] {
                for turn in 1...4 {
                    let before = try displayed(url)
                    let outcome = try LosslessRotation.rotate(url, clockwise: clockwise, mode: .pixels)
                    XCTAssertNil(outcome.note)
                    XCTAssertEqual(LosslessRotation.orientation(of: url), 1, "the pixels turn, the tag stays 1")
                    let after = try displayed(url)
                    XCTAssertEqual(after.width, before.height)
                    let expected = clockwise ? corner(before, x: 0, y: before.height - 1) : corner(before, x: before.width - 1, y: 0)
                    assertClose(corner(after, x: 0, y: 0), expected, "turn \(turn)")
                }
                let back = try JPEGLosslessTransform.Picture([UInt8](Data(contentsOf: url)))
                XCTAssertTrue(back.sameImage(as: original), "four turns must restore every coefficient")
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    func testTaggedPictureGetsItsTagBakedIn() throws {
        // Stored sideways with orientation 6, as a camera held upright writes it.
        let url = try writeJPEG(name: "tagged.jpg", width: 96, height: 64, quality: 0.9, orientation: 6)
        let original = try JPEGLosslessTransform.Picture([UInt8](Data(contentsOf: url)))
        let before = try displayed(url)
        let outcome = try LosslessRotation.rotate(url, clockwise: true, mode: .pixels)
        XCTAssertEqual(outcome.orientation, 1)
        XCTAssertEqual(LosslessRotation.orientation(of: url), 1)
        let after = try displayed(url)
        XCTAssertEqual(after.width, before.height)
        assertClose(corner(after, x: 0, y: 0), corner(before, x: 0, y: before.height - 1))
        // Displayed upright-then-clockwise is orientation 3 of the stored blocks: a half turn.
        let expected = try original.transformed(XCTUnwrap(JPEGLosslessTransform.Flip(orientation: 3)), trim: false)
        XCTAssertTrue(try JPEGLosslessTransform.Picture([UInt8](Data(contentsOf: url))).sameImage(as: expected))
    }

    func testTurningBackToUprightOnlyTouchesTheTag() throws {
        let url = try writeJPEG(name: "tagged.jpg", width: 96, height: 64, quality: 0.9, orientation: 8)
        let before = try Data(contentsOf: url)
        let outcome = try LosslessRotation.rotate(url, clockwise: true, mode: .pixels)
        XCTAssertEqual(outcome.orientation, 1)
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after.count, before.count)
        XCTAssertLessThanOrEqual(zip(before, after).filter { $0 != $1 }.count, 4)
    }

    func testOddSizeFallsBackToTheTag() throws {
        let url = try writeJPEG(name: "odd.jpg", width: 61, height: 37, quality: 0.8, orientation: 1)
        XCTAssertThrowsError(try JPEGLosslessTransform.bake([UInt8](Data(contentsOf: url)), orientation: 6)) {
            XCTAssertEqual($0 as? JPEGLosslessTransform.Failure, .notAligned)
        }
        try assertFallsBackToTag(url)
    }

    func testOddSizeThatDoesNotFlipIsStillTurned() throws {
        // A transpose moves no partial block to the wrong edge, so any size works.
        let url = try writeJPEG(name: "odd.jpg", width: 61, height: 37, quality: 0.8)
        let original = try [UInt8](Data(contentsOf: url))
        let baked = try JPEGLosslessTransform.bake(original, orientation: 5)
        let props = try properties(Data(baked))
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 37)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 61)
    }

    func testModificationDateIsKept() throws {
        let url = try writeJPEG(name: "dated.jpg", width: 64, height: 64, quality: 0.8, orientation: 1)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        _ = try LosslessRotation.rotate(url, clockwise: true, mode: .pixels)
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(modified?.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970, accuracy: 1)
    }

    func testOtherFormatsUseTheTagInPixelMode() throws {
        let url = folder.appendingPathComponent("photo.tiff")
        try writeImage(makeImage(width: 64, height: 32, grey: false), to: url, type: .tiff, properties: [kCGImagePropertyOrientation: 1])
        let outcome = try LosslessRotation.rotate(url, clockwise: true, mode: .pixels)
        XCTAssertEqual(outcome.orientation, 6)
        XCTAssertNil(outcome.note)
    }

    // MARK: Metadata

    func testThumbnailAndMetadataFollow() throws {
        // ImageIO writes an EXIF thumbnail when asked to.
        let url = folder.appendingPathComponent("thumb.jpg")
        try writeImage(makeImage(width: 320, height: 240, grey: false), to: url, type: .jpeg, properties: [
            kCGImageDestinationLossyCompressionQuality: 0.8,
            kCGImageDestinationEmbedThumbnail: true,
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "keep me"],
        ])
        let original = try Data(contentsOf: url)
        let baked = Data(try JPEGLosslessTransform.bake([UInt8](original), orientation: 6))
        let props = try properties(baked)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 240)
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int ?? 1, 1)
        XCTAssertEqual((props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String, "keep me")

        let source = try XCTUnwrap(CGImageSourceCreateWithData(baked as CFData, nil))
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: false] as CFDictionary)
        if let thumbnail {
            XCTAssertLessThan(thumbnail.width, thumbnail.height, "the embedded thumbnail turned too")
        }
    }

    func testMPFPreviewIsTurnedAndRelocated() throws {
        let main = try [UInt8](Data(contentsOf: writeJPEG(name: "main.jpg", width: 128, height: 64, quality: 0.8)))
        let preview = try [UInt8](Data(contentsOf: writeJPEG(name: "preview.jpg", width: 64, height: 32, quality: 0.8)))
        let file = makeMPF(main: main, preview: preview)
        let baked = try JPEGLosslessTransform.bake(file, orientation: 6)

        // Read the index back: entry 1 is the whole picture, entry 2 points at a JPEG turned on its side.
        let header = try XCTUnwrap(find(Array("MPF".utf8) + [0], in: baked)) + 4
        func be32(_ p: Int) -> Int { Int(baked[p]) << 24 | Int(baked[p + 1]) << 16 | Int(baked[p + 2]) << 8 | Int(baked[p + 3]) }
        let table = header + be32(header + 8 + 2 + 2 * 12 + 8)
        let mainSize = be32(table + 4)
        let previewSize = be32(table + 16 + 4), previewOffset = be32(table + 16 + 8)
        XCTAssertEqual(Array(baked[(mainSize - 2)..<mainSize]), [0xFF, 0xD9])
        let turned = Array(baked[(header + previewOffset)..<(header + previewOffset + previewSize)])
        let props = try properties(Data(turned))
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 32)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 64)
        let expected = try JPEGLosslessTransform.Picture(preview).transformed(XCTUnwrap(JPEGLosslessTransform.Flip(orientation: 6)), trim: true)
        XCTAssertTrue(try JPEGLosslessTransform.Picture(turned).sameImage(as: expected))
    }

    func testOptimalTableNeverUsesTheAllOnesCodeOrLongCodes() {
        // Fibonacci counts force the deepest possible tree.
        var counts = [Int](repeating: 0, count: 256)
        var a = 1, b = 1
        for i in 0..<40 { counts[i] = a; (a, b) = (b, a + b) }
        let spec = JPEGLosslessTransform.Picture.optimalTable(counts)
        XCTAssertEqual(spec.symbols.count, 40)
        XCTAssertEqual(spec.counts.reduce(0) { $0 + Int($1) }, 40)
        // Kraft sum strictly below one: the all-ones code stays free.
        let kraft = spec.counts.enumerated().reduce(0.0) { $0 + Double($1.element) / pow(2, Double($1.offset + 1)) }
        XCTAssertLessThan(kraft, 1)
    }

    // MARK: Helpers

    private func assertFallsBackToTag(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try Data(contentsOf: url)
        let start = LosslessRotation.orientation(of: url) ?? 1
        let outcome = try LosslessRotation.rotate(url, clockwise: true, mode: .pixels)
        XCTAssertNotNil(outcome.note, file: file, line: line)
        XCTAssertEqual(outcome.orientation, LosslessRotation.rotated(start, clockwise: true), file: file, line: line)
        let after = try Data(contentsOf: url)
        let a = try XCTUnwrap(CGImageSourceCreateWithData(before as CFData, nil))
        let b = try XCTUnwrap(CGImageSourceCreateWithData(after as CFData, nil))
        XCTAssertTrue(LosslessRotation.samePixels(a, b), "the fallback never touches the pixels", file: file, line: line)
    }

    private func jpegtranArguments(_ orientation: Int) -> [String] {
        switch orientation {
        case 2: ["-flip", "horizontal"]
        case 3: ["-rotate", "180"]
        case 4: ["-flip", "vertical"]
        case 5: ["-transpose"]
        case 6: ["-rotate", "90"]
        case 7: ["-transverse"]
        default: ["-rotate", "270"]
        }
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> [UInt8] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("\(tool) failed") }
        return [UInt8](data)
    }

    /// Smooth gradients plus hard-edged shapes and noise, so every frequency of every block is exercised.
    private func makeImage(width: Int, height: Int, grey: Bool) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 12345
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 1_103_515_245 &+ 12345
                let noise = Int(seed >> 24) % 40
                let i = (y * width + x) * 4
                let shape = (x / 7 + y / 5) % 3 == 0 ? 90 : 0
                pixels[i] = UInt8(clamping: x * 255 / width + noise - shape)
                pixels[i + 1] = UInt8(clamping: y * 255 / height + noise)
                pixels[i + 2] = UInt8(clamping: (x < width / 3 && y < height / 2) ? 230 : noise + shape)
            }
        }
        let space = grey ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        if grey {
            var luma = [UInt8](repeating: 0, count: width * height)
            for index in luma.indices {
                let red = Int(pixels[index * 4]), green = Int(pixels[index * 4 + 1]), blue = Int(pixels[index * 4 + 2])
                luma[index] = UInt8(red / 3 + green / 3 + blue / 3)
            }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(luma) as CFData))
            return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                         space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                     space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func writeJPEG(name: String, width: Int, height: Int, quality: Double, grey: Bool = false,
                           orientation: Int? = nil) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        try writeImage(makeImage(width: width, height: height, grey: grey), to: url, type: .jpeg, properties: properties)
        return url
    }

    private func writeImage(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any]) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("Cannot write \(type)") }
    }

    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func decodedPixels(_ data: Data) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try XCTUnwrap(image.dataProvider?.data as Data?)
    }

    /// A main JPEG with an MPF index pointing at a preview appended after it, laid out the way cameras write it.
    private func makeMPF(main: [UInt8], preview: [UInt8]) -> [UInt8] {
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func be32(_ v: Int) -> [UInt8] { be16(v >> 16) + be16(v & 0xFFFF) }
        // MP header: "MM", 42, IFD at 8; IFD of 3 entries: version, count, entry table (32 bytes) after the IFD.
        let tableOffset = 8 + 2 + 3 * 12 + 4
        func index(mainSize: Int, previewOffset: Int) -> [UInt8] {
            var tiff: [UInt8] = [0x4D, 0x4D] + be16(42) + be32(8) + be16(3)
            tiff += be16(0xB000) + be16(7) + be32(4) + Array("0100".utf8)
            tiff += be16(0xB001) + be16(4) + be32(1) + be32(2)
            tiff += be16(0xB002) + be16(7) + be32(32) + be32(tableOffset)
            tiff += be32(0)
            tiff += be32(0x030000) + be32(mainSize) + be32(0) + be16(0) + be16(0)
            tiff += be32(0x010001) + be32(preview.count) + be32(previewOffset) + be16(0) + be16(0)
            let body = Array("MPF".utf8) + [0] + tiff
            return [0xFF, 0xE2] + be16(body.count + 2) + body
        }
        let segmentLength = index(mainSize: 0, previewOffset: 0).count
        let mainSize = main.count + segmentLength
        let header = 2 + 8 // SOI, then FF E2 LL LL "MPF\0"
        let file = [0xFF, 0xD8] + index(mainSize: mainSize, previewOffset: mainSize - header) + main.dropFirst(2)
        return file + preview
    }

    private func find(_ pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= pattern.count else { return nil }
        return (0...(bytes.count - pattern.count)).first { bytes[$0..<($0 + pattern.count)].elementsEqual(pattern) }
    }

    private func displayed(_ url: URL) throws -> CGImage {
        let data = try Data(contentsOf: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1000,
        ]
        return try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
    }

    /// The colour a few pixels in from the given corner, averaged over a small patch, as 0–255 RGB.
    private func corner(_ image: CGImage, x: Int, y: Int) -> [Int] {
        let size = 6
        let px = x == 0 ? 1 : x - size, py = y == 0 ? 1 : y - size
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: -px, y: py + size - image.height, width: image.width, height: image.height))
        return (0..<3).map { c in stride(from: c, to: pixels.count, by: 4).reduce(0) { $0 + Int(pixels[$1]) } / (size * size) }
    }

    private func assertClose(_ a: [Int], _ b: [Int], _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(zip(a, b).allSatisfy { abs($0 - $1) < 30 }, "\(a) is not \(b) \(message)", file: file, line: line)
    }
}
