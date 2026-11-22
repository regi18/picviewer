import AVFoundation
import XCTest
@testable import PicViewerCore

final class VideoTests: XCTestCase {
    func testFilmsAreListedAmongPictures() throws {
        let folder = try temporaryFolder()
        for name in ["IMG_0001.JPG", "IMG_0002.MOV", "IMG_0003.mp4", "notes.txt"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data([0]))
        }
        let names = FolderScanner.sort(FolderScanner.entries(in: folder), by: .byName).map(\.name)
        XCTAssertEqual(names, ["IMG_0001.JPG", "IMG_0002.MOV", "IMG_0003.mp4"])
        XCTAssertTrue(FolderScanner.isVideo(folder.appendingPathComponent("IMG_0002.MOV")))
        XCTAssertFalse(FolderScanner.isVideo(folder.appendingPathComponent("IMG_0001.JPG")))
    }

    func testLabels() {
        var info = ImageInfo(properties: [:], url: URL(fileURLWithPath: "/tmp/a.mov"))
        info.duration = 7.4
        XCTAssertEqual(info.durationLabel, "0:07")
        info.duration = 3723
        XCTAssertEqual(info.durationLabel, "1:02:03")
        info.frameRate = 29.97
        XCTAssertEqual(info.frameRateLabel, "29.97 fps")
        info.frameRate = 30
        XCTAssertEqual(info.frameRateLabel, "30 fps")

        let location = ImageInfo.iso6709("+37.3349-122.0090+010.000/")
        XCTAssertEqual(location?.latitude, 37.3349)
        XCTAssertEqual(location?.longitude, -122.0090)
        XCTAssertEqual(location?.altitude, 10)
        XCTAssertNil(ImageInfo.iso6709("nonsense"))

        let date = ImageInfo.wallClockDate("2001-02-03T04:05:06+0100")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        XCTAssertEqual(date.map { calendar.component(.hour, from: $0) }, 4)
        XCTAssertEqual(ImageInfo.codecName(0x6176_6331), "H.264")  // 'avc1'
    }

    /// Writes a real two-second H.264 film, held portrait by its track matrix, with camera and place metadata.
    func testReadsFilm() async throws {
        let url = try temporaryFolder().appendingPathComponent("clip.mov")
        try await writeFilm(to: url)

        let info = try await ImageInfo.video(at: url)
        XCTAssertTrue(info.isVideo)
        XCTAssertEqual(info.pixelSize, CGSize(width: 96, height: 160))
        XCTAssertEqual(info.duration ?? 0, 2, accuracy: 0.1)
        XCTAssertEqual(info.frameRate ?? 0, 10, accuracy: 0.5)
        XCTAssertEqual(info.codec, "H.264")
        XCTAssertEqual(info.camera, "ACME Cam 1")
        XCTAssertEqual(info.latitude ?? 0, 37.3349, accuracy: 0.0001)
        XCTAssertEqual(info.longitude ?? 0, -122.0090, accuracy: 0.0001)
        XCTAssertEqual(info.takenLabel.map { !$0.isEmpty }, true)
    }

    /// Four quarter turns either way: the size swaps each time, only the matrix bytes change, and after a full turn
    /// the file is byte-for-byte the original again.
    func testRotatesFilmLosslessly() async throws {
        let url = try temporaryFolder().appendingPathComponent("clip.mov")
        try await writeFilm(to: url, transform: .identity)
        let original = try Data(contentsOf: url)
        let modified = try XCTUnwrap(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)

        var info = try await ImageInfo.video(at: url)
        XCTAssertEqual(info.pixelSize, CGSize(width: 160, height: 96))
        XCTAssertEqual(info.videoRotationLabel, "Normal")

        try await VideoRotation.rotate(url, clockwise: true)
        info = try await ImageInfo.video(at: url)
        XCTAssertEqual(info.pixelSize, CGSize(width: 96, height: 160))
        XCTAssertEqual(info.videoRotationLabel, "Rotated 90° CW")
        let once = try Data(contentsOf: url)
        XCTAssertEqual(once.count, original.count)
        let changed = zip(once, original).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        let matrix = try XCTUnwrap(VideoRotation.videoTracks(in: url).first?.offset)
        XCTAssertTrue(changed.allSatisfy { UInt64($0) >= matrix && UInt64($0) < matrix + 36 }, "only the matrix changes")
        XCTAssertEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)

        for _ in 0..<3 { try await VideoRotation.rotate(url, clockwise: true) }
        XCTAssertEqual(try Data(contentsOf: url), original)

        try await VideoRotation.rotate(url, clockwise: false)
        info = try await ImageInfo.video(at: url)
        XCTAssertEqual(info.videoRotationLabel, "Rotated 90° CCW")
        try await VideoRotation.rotate(url, clockwise: false)
        info = try await ImageInfo.video(at: url)
        XCTAssertEqual(info.videoRotationLabel, "Rotated 180°")
        XCTAssertEqual(info.pixelSize, CGSize(width: 160, height: 96))
        for _ in 0..<2 { try await VideoRotation.rotate(url, clockwise: true) }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testMatrixMaths() {
        let identity: [Int32] = [0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x4000_0000]
        // The matrix an iPhone writes for a portrait 1920 × 1080 film.
        XCTAssertEqual(VideoRotation.rotated(identity, width: 1920, height: 1080, clockwise: true),
                       [0, 0x10000, 0, -0x10000, 0, 0, 1080 << 16, 0, 0x4000_0000])
        XCTAssertEqual(VideoRotation.rotated(identity, width: 1920, height: 1080, clockwise: false),
                       [0, -0x10000, 0, 0x10000, 0, 0, 0, 1920 << 16, 0x4000_0000])
    }

    func testRefusesWhatIsNotAFilm() async throws {
        let url = try temporaryFolder().appendingPathComponent("fake.mov")
        try Data("not a film at all".utf8).write(to: url)
        do {
            try await VideoRotation.rotate(url, clockwise: true)
            XCTFail("should refuse")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), Data("not a film at all".utf8))
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pvvideo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func writeFilm(to url: URL, transform: CGAffineTransform = CGAffineTransform(rotationAngle: .pi / 2)) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        writer.metadata = [
            item(.quickTimeMetadataMake, "ACME Corporation"),
            item(.quickTimeMetadataModel, "Cam 1"),
            item(.quickTimeMetadataLocationISO6709, "+37.3349-122.0090+010.000/"),
            item(.quickTimeMetadataCreationDate, "2001-02-03T04:05:06+0100"),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 96,
        ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 12), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 20, timescale: 10))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
}
