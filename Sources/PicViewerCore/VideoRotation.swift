import AVFoundation
import CoreGraphics
import Foundation

/// Rotates films without touching a single frame: only the display matrix in each video track's header (`tkhd`)
/// changes, the same 36 bytes a phone sets when it records upright. QuickTime, AVFoundation, ffmpeg, browsers and
/// Immich all turn the film by that matrix, the way they turn a photo by its EXIF orientation tag.
///
/// The matrix is overwritten in place, so the file keeps its size, its frames, its sound and its metadata. After
/// writing, the header is read back twice, from the bytes and through AVFoundation, and if either doesn't match, the
/// original bytes go back.
public enum VideoRotation {
    public enum Failure: LocalizedError {
        case layout

        public var errorDescription: String? {
            "This film's header isn't one PicViewer can rotate in place, so the file was left untouched."
        }
    }

    /// Where one video track's matrix sits in the file, and the size of its frames before the matrix turns them.
    struct Track: Equatable {
        let offset: UInt64
        let matrix: [Int32]
        let width: Double
        let height: Double
    }

    /// Turns the film a quarter turn on screen.
    public static func rotate(_ url: URL, clockwise: Bool) async throws {
        let tracks = try videoTracks(in: url)
        guard !tracks.isEmpty, tracks.allSatisfy({ $0.width > 0 && $0.height > 0 }) else { throw Failure.layout }
        let turned = tracks.map { rotated($0.matrix, width: $0.width, height: $0.height, clockwise: clockwise) }

        let dates = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        defer {
            // Rotating should not move the film in a folder sorted by date, so the modification date stays.
            if let modified = dates?.contentModificationDate {
                try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            }
        }

        try write(turned, at: tracks.map(\.offset), in: url)
        let readBack = (try? videoTracks(in: url))?.map(\.matrix)
        let played = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first?.load(.preferredTransform)
        if readBack == turned, let played, close(played, transform(turned[0])) { return }

        try write(tracks.map(\.matrix), at: tracks.map(\.offset), in: url)
        throw RotationError.verificationFailed
    }

    /// The matrix after a further quarter turn, moved so the turned frame starts at the top left again.
    ///
    /// QuickTime matrices act on row vectors, x' = a·x + c·y + tx and y' = b·x + d·y + ty, with y pointing down, so a
    /// clockwise quarter turn is a = 0, b = 1, c = −1, d = 0 applied after the existing matrix.
    static func rotated(_ m: [Int32], width: Double, height: Double, clockwise: Bool) -> [Int32] {
        let (a, b, c, d) = (m[0], m[1], m[3], m[4])
        let (na, nb, nc, nd) = clockwise ? (0 &- b, a, 0 &- d, c) : (b, 0 &- a, d, 0 &- c)
        func value(_ fixed: Int32) -> Double { Double(fixed) / 65536 }
        let xs = [0, value(na) * width, value(nc) * height, value(na) * width + value(nc) * height]
        let ys = [0, value(nb) * width, value(nd) * height, value(nb) * width + value(nd) * height]
        func fixed(_ v: Double) -> Int32 { Int32((v * 65536).rounded()) }
        var result = m
        result[0] = na
        result[1] = nb
        result[3] = nc
        result[4] = nd
        result[6] = fixed(-(xs.min() ?? 0))
        result[7] = fixed(-(ys.min() ?? 0))
        return result
    }

    static func transform(_ m: [Int32]) -> CGAffineTransform {
        func value(_ fixed: Int32) -> CGFloat { CGFloat(fixed) / 65536 }
        return CGAffineTransform(a: value(m[0]), b: value(m[1]), c: value(m[3]), d: value(m[4]), tx: value(m[6]), ty: value(m[7]))
    }

    private static func close(_ x: CGAffineTransform, _ y: CGAffineTransform) -> Bool {
        [x.a - y.a, x.b - y.b, x.c - y.c, x.d - y.d, x.tx - y.tx, x.ty - y.ty].allSatisfy { abs($0) < 0.01 }
    }

    private static func write(_ matrices: [[Int32]], at offsets: [UInt64], in url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        for (matrix, offset) in zip(matrices, offsets) {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data(matrix.flatMap { value -> [UInt8] in
                let bits = UInt32(bitPattern: value)
                return [UInt8(bits >> 24), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
            }))
        }
        try handle.synchronize()
    }

    // MARK: Reading the boxes

    /// Every video track's header. Only the `moov` box is read, so a film of several gigabytes costs a few kilobytes.
    static func videoTracks(in url: URL) throws -> [Track] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()

        var position: UInt64 = 0
        while position + 8 <= fileSize {
            try handle.seek(toOffset: position)
            guard let header = try handle.read(upToCount: 16).map(Array.init), header.count >= 8 else { break }
            var size = UInt64(be32(header, 0))
            var headerLength: UInt64 = 8
            if size == 1, header.count >= 16 {
                size = header[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
                headerLength = 16
            } else if size == 0 {
                size = fileSize - position
            }
            guard size >= headerLength, position + size <= fileSize else { throw Failure.layout }
            if String(bytes: header[4..<8], encoding: .macOSRoman) == "moov" {
                // A movie header beyond 64 MB isn't a camera file.
                guard size < 64 << 20 else { throw Failure.layout }
                try handle.seek(toOffset: position)
                guard let data = try handle.read(upToCount: Int(size)), data.count == Int(size) else { throw Failure.layout }
                return try tracks(inMovie: [UInt8](data), at: position, headerLength: Int(headerLength))
            }
            position += size
        }
        throw Failure.layout
    }

    private static func tracks(inMovie bytes: [UInt8], at base: UInt64, headerLength: Int) throws -> [Track] {
        var result: [Track] = []
        for trak in try children(bytes, headerLength, bytes.count) where trak.type == "trak" {
            let parts = try children(bytes, trak.start, trak.end)
            guard let tkhd = parts.first(where: { $0.type == "tkhd" }),
                  let mdia = parts.first(where: { $0.type == "mdia" }),
                  let hdlr = try children(bytes, mdia.start, mdia.end).first(where: { $0.type == "hdlr" }),
                  hdlr.end - hdlr.start >= 12,
                  String(bytes: bytes[(hdlr.start + 8)..<(hdlr.start + 12)], encoding: .macOSRoman) == "vide"
            else { continue }
            let matrixStart = tkhd.start + 4 + (bytes[tkhd.start] == 1 ? 32 : 20) + 16
            guard matrixStart + 44 <= tkhd.end else { throw Failure.layout }
            let matrix = (0..<9).map { Int32(bitPattern: be32(bytes, matrixStart + $0 * 4)) }
            result.append(Track(offset: base + UInt64(matrixStart), matrix: matrix,
                                width: Double(be32(bytes, matrixStart + 36)) / 65536,
                                height: Double(be32(bytes, matrixStart + 40)) / 65536))
        }
        return result
    }

    /// The boxes directly inside `start..<end`: their type, and where their contents start and end.
    private static func children(_ bytes: [UInt8], _ start: Int, _ end: Int) throws -> [(type: String, start: Int, end: Int)] {
        var result: [(String, Int, Int)] = []
        var position = start
        while position + 8 <= end {
            var size = Int(be32(bytes, position))
            var headerLength = 8
            if size == 1 {
                guard position + 16 <= end else { throw Failure.layout }
                size = Int(bytes[(position + 8)..<(position + 16)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
                headerLength = 16
            } else if size == 0 {
                size = end - position
            }
            guard size >= headerLength, position + size <= end else { throw Failure.layout }
            let type = String(bytes: bytes[(position + 4)..<(position + 8)], encoding: .macOSRoman) ?? ""
            result.append((type, position + headerLength, position + size))
            position += size
        }
        return result
    }

    private static func be32(_ bytes: [UInt8], _ p: Int) -> UInt32 {
        UInt32(bytes[p]) << 24 | UInt32(bytes[p + 1]) << 16 | UInt32(bytes[p + 2]) << 8 | UInt32(bytes[p + 3])
    }
}
