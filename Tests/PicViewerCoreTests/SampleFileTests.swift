import ImageIO
import XCTest
@testable import PicViewerCore

/// Rotates real camera files. Point PICVIEWER_SAMPLES at a folder of them to run:
/// `PICVIEWER_SAMPLES=~/Pictures/samples swift test --filter SampleFileTests`
final class SampleFileTests: XCTestCase {
    func testSampleFilesRotateLosslessly() throws {
        guard let path = ProcessInfo.processInfo.environment["PICVIEWER_SAMPLES"] else { throw XCTSkip("PICVIEWER_SAMPLES not set") }
        let samples = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
            .filter { FolderScanner.isImage($0) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("PicViewerSamples-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        for sample in samples {
            let url = work.appendingPathComponent(sample.lastPathComponent)
            try FileManager.default.copyItem(at: sample, to: url)
            let original = try Data(contentsOf: url)
            let originalSource = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
            let start = LosslessRotation.orientation(of: url) ?? 1
            do {
                let before = try displayedSize(url)
                let turned = try LosslessRotation.rotate(url, clockwise: true)
                let after = try displayedSize(url)
                XCTAssertEqual(turned, LosslessRotation.rotated(start, clockwise: true), sample.lastPathComponent)
                XCTAssertEqual(before.width, after.height, sample.lastPathComponent)
                let rotated = try Data(contentsOf: url)
                let changed = zip(original, rotated).filter { $0 != $1 }.count
                let source = try XCTUnwrap(CGImageSourceCreateWithData(rotated as CFData, nil))
                XCTAssertTrue(LosslessRotation.samePixels(originalSource, source), sample.lastPathComponent)
                try LosslessRotation.rotate(url, clockwise: false)
                XCTAssertEqual(try Data(contentsOf: url), original, "a turn back restores the file exactly: \(sample.lastPathComponent)")
                print("SAMPLE \(sample.lastPathComponent): orientation \(start) -> \(turned), \(changed) bytes changed, size \(original.count) -> \(rotated.count)")
            } catch {
                XCTAssertEqual(try Data(contentsOf: url), original, "a refused file stays untouched")
                print("SAMPLE \(sample.lastPathComponent): refused (\(error.localizedDescription))")
            }
        }
    }

    private func displayedSize(_ url: URL) throws -> CGSize {
        let data = try Data(contentsOf: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 600,
                                        kCGImageSourceCreateThumbnailFromImageIfAbsent: true]
        let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
        return CGSize(width: image.width, height: image.height)
    }
}
