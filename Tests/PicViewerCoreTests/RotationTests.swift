import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PicViewerCore

final class RotationTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PicViewerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testOrientationTableRoundTrips() {
        for orientation in 1...8 {
            XCTAssertEqual(LosslessRotation.rotated(LosslessRotation.rotated(orientation, clockwise: true), clockwise: false), orientation)
            var turned = orientation
            for _ in 0..<4 { turned = LosslessRotation.rotated(turned, clockwise: true) }
            XCTAssertEqual(turned, orientation)
        }
    }

    func testJPEGRotatesInPlaceWithoutTouchingPixels() throws {
        let url = try write(type: .jpeg, name: "photo.jpg", orientation: 1)
        try assertRotationIsLossless(url, expectInPlace: true)
    }

    func testTIFFRotatesInPlace() throws {
        let url = try write(type: .tiff, name: "photo.tiff", orientation: 1)
        try assertRotationIsLossless(url, expectInPlace: true)
    }

    func testPNGWithoutTagGetsOneAndKeepsPixels() throws {
        let url = try write(type: .png, name: "shot.png", orientation: nil)
        try assertRotationIsLossless(url, expectInPlace: false)
    }

    func testHEICRotatesWithoutReencodingOrRefuses() throws {
        guard let url = try? write(type: .heic, name: "photo.heic", orientation: 1) else { throw XCTSkip("No HEIC encoder") }
        let before = try Data(contentsOf: url)
        do {
            try assertRotationIsLossless(url, expectInPlace: nil)
            print("HEIC: rotated losslessly")
        } catch let error as RotationError {
            // Refusing is fine; changing the file is not.
            print("HEIC: refused with \(error)")
            XCTAssertEqual(try Data(contentsOf: url), before, "\(error)")
        }
    }

    func testModificationDateIsKept() throws {
        let url = try write(type: .jpeg, name: "dated.jpg", orientation: 1)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        try LosslessRotation.rotate(url, clockwise: true)
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(modified?.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970, accuracy: 1)
    }

    /// Turns the file all the way round, checking after each quarter turn that the pixels are untouched and that the
    /// picture, as any viewer draws it, really turned the right way.
    private func assertRotationIsLossless(_ url: URL, expectInPlace: Bool?) throws {
        let originalBytes = try Data(contentsOf: url)
        let originalSource = try XCTUnwrap(CGImageSourceCreateWithData(originalBytes as CFData, nil))
        var expectedOrientation = LosslessRotation.orientation(of: url) ?? 1

        for clockwise in [true, true, false, true, true, true] {
            let displayedBefore = try displayed(url)
            let result = try LosslessRotation.rotate(url, clockwise: clockwise)
            expectedOrientation = LosslessRotation.rotated(expectedOrientation, clockwise: clockwise)
            XCTAssertEqual(result, expectedOrientation)
            XCTAssertEqual(LosslessRotation.orientation(of: url), expectedOrientation)

            let bytes = try Data(contentsOf: url)
            if expectInPlace == true {
                XCTAssertEqual(bytes.count, originalBytes.count, "an in-place patch keeps the file size")
                XCTAssertEqual(zip(bytes, originalBytes).filter { $0 != $1 }.count <= 4, true, "only the tag bytes change")
            }
            let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
            XCTAssertTrue(LosslessRotation.samePixels(originalSource, source), "pixels must be bit-for-bit identical")

            let displayedAfter = try displayed(url)
            XCTAssertEqual(displayedAfter.width, displayedBefore.height)
            XCTAssertEqual(displayedAfter.height, displayedBefore.width)
            // After a clockwise turn the old bottom-left corner is top-left; after a counterclockwise one, the old top-right.
            let expectedCorner = clockwise ? corner(displayedBefore, x: 0, y: displayedBefore.height - 1)
                                           : corner(displayedBefore, x: displayedBefore.width - 1, y: 0)
            assertClose(corner(displayedAfter, x: 0, y: 0), expectedCorner)
        }
    }

    // MARK: Helpers

    /// A 64×32 picture in four solid quadrants: red, green / blue, white.
    private func write(type: UTType, name: String, orientation: Int?) throws -> URL {
        let width = 64, height = 32
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Core Graphics draws bottom-up, so the top row of the picture is y = height / 2 ..< height here.
        let quadrants: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: 16, width: 32, height: 16), CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
            (CGRect(x: 32, y: 16, width: 32, height: 16), CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
            (CGRect(x: 0, y: 0, width: 32, height: 16), CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
            (CGRect(x: 32, y: 0, width: 32, height: 16), CGColor(red: 1, green: 1, blue: 1, alpha: 1)),
        ]
        for (rect, color) in quadrants {
            context.setFillColor(color)
            context.fill(rect)
        }
        let image = try XCTUnwrap(context.makeImage())
        let url = folder.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("Cannot write \(type)") }
        return url
    }

    /// The picture as viewers draw it, with the orientation applied.
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

    /// The colour a few pixels in from the given corner, as 0–255 RGB.
    private func corner(_ image: CGImage, x: Int, y: Int) -> [Int] {
        let inset = 4
        let px = x == 0 ? inset : x - inset, py = y == 0 ? inset : y - inset
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        // Draw so that pixel (px, py), counted from the top left, lands on the 1×1 context.
        context.draw(image, in: CGRect(x: -px, y: py - image.height + 1, width: image.width, height: image.height))
        return pixel.prefix(3).map(Int.init)
    }

    private func assertClose(_ a: [Int], _ b: [Int], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(zip(a, b).allSatisfy { abs($0 - $1) < 40 }, "\(a) is not \(b)", file: file, line: line)
    }
}
