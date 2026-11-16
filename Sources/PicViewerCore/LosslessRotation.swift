import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum RotationError: LocalizedError {
    case unreadable
    case unsupported(String)
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .unreadable: "Could not read this picture."
        case .unsupported(let format): "\(format) files cannot be rotated without re-encoding them, so this one was left untouched."
        case .verificationFailed: "The rotated file did not check out, so the original was left untouched."
        }
    }
}

/// Rotates pictures without touching a single pixel: only the EXIF orientation tag changes, which every modern viewer
/// and editor honours.
///
/// Wherever the file already has an orientation tag (every camera JPEG and RAW, most phone photos) the two bytes of
/// that tag are rewritten in place: the file keeps its size, its pixels, its metadata, its tags and its dates. A file
/// without the tag (a PNG screenshot, say) gets one through ImageIO, and is only replaced after a check that the
/// decoded pixels are bit-for-bit the same as before. Anything that cannot be done this way is refused, never
/// re-encoded.
public enum LosslessRotation {
    /// The orientation after turning the displayed picture a quarter turn. EXIF orientations 1 to 8.
    public static func rotated(_ orientation: Int, clockwise: Bool) -> Int {
        let cw = [1: 6, 2: 7, 3: 8, 4: 5, 5: 2, 6: 3, 7: 4, 8: 1]
        let ccw = [1: 8, 2: 5, 3: 6, 4: 7, 5: 4, 6: 1, 7: 2, 8: 3]
        return (clockwise ? cw : ccw)[orientation] ?? (clockwise ? 6 : 8)
    }

    public static func orientation(of url: URL) -> Int? {
        // Read from fresh bytes so ImageIO cannot hand back what it read before the file changed.
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return properties[kCGImagePropertyOrientation] as? Int ?? 1
    }

    /// Turns the picture a quarter turn and returns the new orientation.
    @discardableResult
    public static func rotate(_ url: URL, clockwise: Bool) throws -> Int {
        guard let current = orientation(of: url) else { throw RotationError.unreadable }
        let target = rotated(current, clockwise: clockwise)
        let dates = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        defer {
            // Rotating should not move the picture in a folder sorted by date, so the modification date stays.
            if let modified = dates?.contentModificationDate {
                try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            }
        }

        if try patchInPlace(url, to: target) { return target }
        try rewriteWithImageIO(url, to: target)
        return target
    }

    // MARK: In-place tag patch

    struct TagLocation: Equatable {
        enum Encoding: Equatable {
            case short(littleEndian: Bool)
            /// The single digit of an XMP tiff:Orientation, which some editors write next to the EXIF tag.
            case asciiDigit
            /// The angle byte of a HEIF `irot` box, which is what HEIC readers go by. Quarter turns counterclockwise.
            case heifRotation
        }

        let offset: Int
        let encoding: Encoding

        init(offset: Int, isLittleEndian: Bool) {
            self.offset = offset
            encoding = .short(littleEndian: isLittleEndian)
        }

        init(xmpDigitAt offset: Int) {
            self.offset = offset
            encoding = .asciiDigit
        }

        init(irotAngleAt offset: Int) {
            self.offset = offset
            encoding = .heifRotation
        }

        var length: Int { encoding == .short(littleEndian: true) || encoding == .short(littleEndian: false) ? 2 : 1 }

        /// Nil when this tag cannot say it: an `irot` box only turns, it cannot mirror.
        func bytes(for orientation: Int) -> Data? {
            let value = UInt16(orientation)
            switch encoding {
            case .short(let little): return Data(little ? [UInt8(value & 0xff), UInt8(value >> 8)] : [UInt8(value >> 8), UInt8(value & 0xff)])
            case .asciiDigit: return Data([UInt8(0x30 + orientation)])
            case .heifRotation: return [1: 0, 8: 1, 3: 2, 6: 3][orientation].map { Data([UInt8($0)]) }
            }
        }
    }

    /// Rewrites every orientation tag in the file (EXIF IFD0/IFD1, XMP, HEIF irot). Returns false when the file has none, or when ImageIO does not
    /// read the new value back (in which case the original bytes are put back).
    private static func patchInPlace(_ url: URL, to target: Int) throws -> Bool {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let locations = orientationTags(in: data, type: UTType(filenameExtension: url.pathExtension))
        guard !locations.isEmpty else { return false }

        let originals = locations.map { Data(Array(data[$0.offset..<($0.offset + $0.length)])) }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        func write(_ bytes: [Data]) throws {
            for (location, value) in zip(locations, bytes) {
                try handle.seek(toOffset: UInt64(location.offset))
                try handle.write(contentsOf: value)
            }
            try handle.synchronize()
        }

        let replacements = locations.compactMap { $0.bytes(for: target) }
        guard replacements.count == locations.count else { return false }
        try write(replacements)
        if orientation(of: url) == target { return true }

        try write(originals)
        return false
    }

    /// Where the orientation tags sit: in a JPEG's EXIF segment, at the top of a TIFF-based file (TIFF, DNG and most
    /// RAW formats), in the JPEG a Fujifilm RAF carries, or in an EXIF block anywhere in a HEIF or WebP file.
    static func orientationTags(in data: Data, type: UTType?) -> [TagLocation] {
        let bytes = [UInt8](data)
        if bytes.count < 16 { return [] }
        // PNG chunks carry checksums, so their bytes are never patched.
        if let type, type.conforms(to: .png) { return [] }
        let exif = exifTags(bytes)
        // XMP is only touched next to an EXIF tag, so the two never disagree.
        return exif.isEmpty ? [] : exif + xmpTags(bytes) + irotBoxes(bytes)
    }

    private static func exifTags(_ bytes: [UInt8]) -> [TagLocation] {
        if bytes[0] == 0xFF, bytes[1] == 0xD8 {
            return jpegTags(bytes, start: 0, end: bytes.count)
        }
        if bytes.starts(with: Array("FUJIFILMCCD-RAW".utf8)), bytes.count > 92 {
            let offset = Int(be32(bytes, 84)), length = Int(be32(bytes, 88))
            guard offset > 0, length > 0, offset + length <= bytes.count else { return [] }
            return jpegTags(bytes, start: offset, end: offset + length)
        }
        let tiff = tiffTags(bytes, tiffStart: 0, end: bytes.count)
        if !tiff.isEmpty { return tiff }
        // HEIF and WebP keep EXIF in a plain block.
        return exifBlocks(bytes).flatMap { tiffTags(bytes, tiffStart: $0, end: bytes.count) }
    }

    private static func jpegTags(_ bytes: [UInt8], start: Int, end: Int) -> [TagLocation] {
        guard end - start > 4, bytes[start] == 0xFF, bytes[start + 1] == 0xD8 else { return [] }
        var p = start + 2
        var tags: [TagLocation] = []
        while p + 4 <= end {
            guard bytes[p] == 0xFF else { break }
            let marker = bytes[p + 1]
            if marker == 0xFF { p += 1; continue }
            if marker == 0xDA || marker == 0xD9 { break } // Start of scan: no metadata after this.
            if (0xD0...0xD7).contains(marker) || marker == 0x01 { p += 2; continue }
            let length = Int(bytes[p + 2]) << 8 | Int(bytes[p + 3])
            guard length >= 2, p + 2 + length <= end else { break }
            let segmentEnd = p + 2 + length
            if marker == 0xE1, length >= 16, Array(bytes[(p + 4)..<(p + 10)]) == exifHeader {
                tags += tiffTags(bytes, tiffStart: p + 10, end: segmentEnd)
            }
            p = segmentEnd
        }
        return tags
    }

    /// `tiff:Orientation="6"` and `<tiff:Orientation>6</tiff:Orientation>`, the two ways XMP writes it.
    private static func xmpTags(_ bytes: [UInt8]) -> [TagLocation] {
        var tags: [TagLocation] = []
        for pattern in ["tiff:Orientation=\"", "<tiff:Orientation>"].map({ Array($0.utf8) }) {
            for start in occurrences(of: pattern, in: bytes) {
                let digit = start + pattern.count
                guard digit + 1 < bytes.count, (0x31...0x38).contains(bytes[digit]),
                      bytes[digit + 1] == 0x22 || bytes[digit + 1] == 0x3C
                else { continue }
                tags.append(TagLocation(xmpDigitAt: digit))
            }
        }
        return tags
    }

    /// HEIF `irot` boxes: a 9-byte box whose last byte holds the angle.
    private static func irotBoxes(_ bytes: [UInt8]) -> [TagLocation] {
        guard bytes.count > 12, Array(bytes[4..<8]) == Array("ftyp".utf8) else { return [] }
        return occurrences(of: [0, 0, 0, 9] + Array("irot".utf8), in: bytes)
            .filter { $0 + 8 < bytes.count && bytes[$0 + 8] <= 3 }
            .map { TagLocation(irotAngleAt: $0 + 8) }
    }

    private static func occurrences(of pattern: [UInt8], in bytes: [UInt8]) -> [Int] {
        guard let first = pattern.first, bytes.count >= pattern.count else { return [] }
        var result: [Int] = []
        var i = 0
        let last = bytes.count - pattern.count
        while i <= last {
            if bytes[i] == first, bytes[i..<(i + pattern.count)].elementsEqual(pattern) { result.append(i) }
            i += 1
        }
        return result
    }

    private static let exifHeader: [UInt8] = Array("Exif".utf8) + [0, 0]

    private static func exifBlocks(_ bytes: [UInt8]) -> [Int] {
        occurrences(of: exifHeader, in: bytes).map { $0 + exifHeader.count }
    }

    /// The orientation entry in the first IFD of the TIFF structure at `tiffStart`.
    static func tiffTag(_ bytes: [UInt8], tiffStart: Int, end: Int) -> TagLocation? {
        guard tiffStart + 8 <= end else { return nil }
        let little: Bool
        switch (bytes[tiffStart], bytes[tiffStart + 1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        func u16(_ p: Int) -> Int { little ? Int(bytes[p]) | Int(bytes[p + 1]) << 8 : Int(bytes[p]) << 8 | Int(bytes[p + 1]) }
        func u32(_ p: Int) -> Int { little ? u16(p) | u16(p + 2) << 16 : u16(p) << 16 | u16(p + 2) }

        // 42 is TIFF; Olympus (ORF) and Panasonic (RW2) RAW files use their own magic numbers in the same layout.
        guard [42, 0x4F52, 0x5352, 0x55].contains(u16(tiffStart + 2)) else { return nil }
        let ifd = tiffStart + u32(tiffStart + 4)
        guard ifd > tiffStart, ifd + 2 <= end else { return nil }
        let count = u16(ifd)
        guard count > 0, count < 1000, ifd + 2 + count * 12 <= end else { return nil }
        for i in 0..<count {
            let entry = ifd + 2 + i * 12
            // Tag 0x0112 Orientation, type 3 (SHORT), one value, which sits in the first two bytes of the value field.
            guard u16(entry) == 0x0112 else { continue }
            guard u16(entry + 2) == 3, u32(entry + 4) == 1, (1...8).contains(u16(entry + 8)) else { return nil }
            return TagLocation(offset: entry + 8, isLittleEndian: little)
        }
        return nil
    }

    /// The orientation entries of IFD0 and of the IFD after it (IFD1, usually the thumbnail). Some decoders, such as
    /// Apple's for Fujifilm RAF, read the orientation from IFD1, so both are kept in step.
    static func tiffTags(_ bytes: [UInt8], tiffStart: Int, end: Int) -> [TagLocation] {
        guard let first = tiffTag(bytes, tiffStart: tiffStart, end: end) else { return [] }
        let little = bytes[tiffStart] == 0x49
        func u16(_ p: Int) -> Int { little ? Int(bytes[p]) | Int(bytes[p + 1]) << 8 : Int(bytes[p]) << 8 | Int(bytes[p + 1]) }
        func u32(_ p: Int) -> Int { little ? u16(p) | u16(p + 2) << 16 : u16(p) << 16 | u16(p + 2) }

        let ifd0 = tiffStart + u32(tiffStart + 4)
        let nextPointer = ifd0 + 2 + u16(ifd0) * 12
        guard nextPointer + 4 <= end else { return [first] }
        let ifd1 = tiffStart + u32(nextPointer)
        guard ifd1 > tiffStart, ifd1 != ifd0, ifd1 + 2 <= end else { return [first] }
        let count = u16(ifd1)
        guard count > 0, count < 1000, ifd1 + 2 + count * 12 <= end else { return [first] }
        for i in 0..<count {
            let entry = ifd1 + 2 + i * 12
            guard u16(entry) == 0x0112 else { continue }
            guard u16(entry + 2) == 3, u32(entry + 4) == 1, (1...8).contains(u16(entry + 8)) else { break }
            return [first, TagLocation(offset: entry + 8, isLittleEndian: little)]
        }
        return [first]
    }

    private static func be32(_ bytes: [UInt8], _ p: Int) -> UInt32 {
        UInt32(bytes[p]) << 24 | UInt32(bytes[p + 1]) << 16 | UInt32(bytes[p + 2]) << 8 | UInt32(bytes[p + 3])
    }

    // MARK: ImageIO rewrite for files without the tag

    private static func rewriteWithImageIO(_ url: URL, to target: Int) throws {
        let original = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              let typeID = CGImageSourceGetType(source)
        else { throw RotationError.unreadable }
        let type = UTType(typeID as String)
        // Only formats ImageIO can copy without decoding. Camera RAW is read-only to ImageIO.
        guard let type, [UTType.jpeg, .png, .tiff, .heic, .heif].contains(where: { type.conforms(to: $0) }),
              CGImageSourceGetCount(source) == 1
        else { throw RotationError.unsupported(type?.preferredFilenameExtension?.uppercased() ?? "These") }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, typeID, 1, nil) else {
            throw RotationError.unsupported(type.preferredFilenameExtension?.uppercased() ?? "These")
        }
        let metadata = CGImageMetadataCreateMutable()
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true,
            kCGImageDestinationOrientation: target,
        ]
        var error: Unmanaged<CFError>?
        var rewritten: Data
        if CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) {
            rewritten = output as Data
        } else if [UTType.png, .tiff].contains(where: { type.conforms(to: $0) }) {
            // ImageIO only copies JPEG data without decoding. PNG and TIFF are lossless, so writing the decoded pixels
            // again with the new orientation gives the same pixels back; the check below makes sure of it.
            let again = NSMutableData()
            guard let lossless = CGImageDestinationCreateWithData(again, typeID, 1, nil) else {
                throw RotationError.unsupported(type.preferredFilenameExtension?.uppercased() ?? "These")
            }
            CGImageDestinationAddImageFromSource(lossless, source, 0, [kCGImagePropertyOrientation: target] as CFDictionary)
            guard CGImageDestinationFinalize(lossless) else { throw RotationError.verificationFailed }
            rewritten = again as Data
        } else {
            throw RotationError.unsupported(type.preferredFilenameExtension?.uppercased() ?? "These")
        }
        guard let check = CGImageSourceCreateWithData(rewritten as CFData, nil),
              (CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int == target,
              samePixels(source, check)
        else { throw RotationError.verificationFailed }

        // Written over the original rather than swapped in, so the file keeps its identity, Finder tags and date added.
        try rewritten.write(to: url)
    }

    /// Whether two files decode to exactly the same pixels, ignoring orientation.
    static func samePixels(_ a: CGImageSource, _ b: CGImageSource) -> Bool {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let first = CGImageSourceCreateImageAtIndex(a, 0, options),
              let second = CGImageSourceCreateImageAtIndex(b, 0, options),
              first.width == second.width, first.height == second.height,
              first.bitsPerPixel == second.bitsPerPixel, first.bytesPerRow == second.bytesPerRow,
              first.bitmapInfo == second.bitmapInfo,
              let firstData = first.dataProvider?.data, let secondData = second.dataProvider?.data
        else { return false }
        return (firstData as Data) == (secondData as Data)
    }
}
