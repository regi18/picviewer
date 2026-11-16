import Foundation

/// Turns and flips a JPEG without decoding it to pixels, the way `jpegtran -perfect` does: the compressed 8×8 blocks
/// of DCT coefficients are moved and their signs flipped, nothing is ever quantised again, so not a single bit of
/// picture information is lost. Only pictures where this is exactly lossless are accepted (baseline JPEGs whose size
/// fits the block grid in the directions that flip); anything else throws, and the caller falls back to the
/// orientation tag.
///
/// The EXIF thumbnail and the previews a camera appends after the picture (MPF, as Fujifilm does) are turned with it,
/// every orientation tag is set to 1, and everything else in the file (EXIF, maker notes, XMP, ICC profile) is kept
/// byte for byte.
public enum JPEGLosslessTransform {
    public enum Failure: Error, Equatable {
        /// The picture's width or height is not a whole number of blocks in a direction that flips.
        case notAligned
        /// Progressive, arithmetic-coded, 12-bit, damaged, or otherwise not something this can turn losslessly.
        case unsupported(String)
    }

    /// What EXIF orientation `n` asks a viewer to do to the stored picture: transpose, then mirror left-right, then
    /// mirror top-bottom.
    public struct Flip: Equatable, Sendable {
        public let transpose: Bool, hflip: Bool, vflip: Bool

        public init?(orientation: Int) {
            switch orientation {
            case 2: (transpose, hflip, vflip) = (false, true, false)
            case 3: (transpose, hflip, vflip) = (false, true, true)
            case 4: (transpose, hflip, vflip) = (false, false, true)
            case 5: (transpose, hflip, vflip) = (true, false, false)
            case 6: (transpose, hflip, vflip) = (true, true, false)
            case 7: (transpose, hflip, vflip) = (true, true, true)
            case 8: (transpose, hflip, vflip) = (true, false, true)
            default: return nil
            }
        }
    }

    /// The JPEG with `orientation` applied to its pixels and every orientation tag set to 1.
    public static func bake(_ bytes: [UInt8], orientation: Int) throws -> [UInt8] {
        guard let flip = Flip(orientation: orientation) else { throw Failure.unsupported("orientation \(orientation)") }
        return try transform(bytes, flip, trim: false, embedded: false)
    }

    /// `trim` drops the partial blocks at the edges that would otherwise land on the wrong side, losing a few pixel
    /// rows. It is only used for thumbnails and previews, never for the picture itself.
    static func transform(_ bytes: [UInt8], _ flip: Flip, trim: Bool, embedded: Bool) throws -> [UInt8] {
        let source = try Picture(bytes)
        let target = try source.transformed(flip, trim: trim)

        var headers = source.headers.map { Array(bytes[$0]) }
        var mpfIndex: Int?
        for i in headers.indices {
            let marker = headers[i][1]
            if marker == 0xE1, headers[i].starts(at: 4, with: exifHeader) {
                try patchExif(&headers[i], flip, depth: embedded ? 1 : 0)
            } else if marker == 0xE1, headers[i].starts(at: 4, with: xmpHeader) {
                patchXMP(&headers[i])
            } else if marker == 0xE2, !embedded, mpfIndex == nil, headers[i].starts(at: 4, with: mpfHeader) {
                mpfIndex = i
            }
        }

        var output: [UInt8] = [0xFF, 0xD8]
        var positions: [Int] = []
        for header in headers {
            positions.append(output.count)
            output += header
        }
        output += try target.encode()

        var trailing = Array(bytes[source.end...])
        if let mpfIndex {
            try relocateMPF(in: &output, segmentAt: positions[mpfIndex], original: bytes,
                            originalSegmentAt: source.headers[mpfIndex].lowerBound, originalEnd: source.end,
                            trailing: &trailing, flip)
        }

        // Read back what was written: every coefficient must be exactly where it was meant to go.
        guard try Picture(output).sameImage(as: target) else { throw Failure.unsupported("verification") }
        return output + trailing
    }

    // MARK: Metadata

    private static let exifHeader: [UInt8] = Array("Exif".utf8) + [0, 0]
    private static let xmpHeader: [UInt8] = Array("http://ns.adobe.com/xap/1.0/".utf8) + [0]
    private static let mpfHeader: [UInt8] = Array("MPF".utf8) + [0]

    /// A TIFF structure inside a segment, read and written in its own byte order. Every access is bounds-checked, so
    /// a damaged file can only make the transform refuse, never crash.
    private struct TIFF {
        var bytes: [UInt8]
        let base: Int
        let little: Bool

        init?(_ bytes: [UInt8], base: Int) {
            guard base + 8 <= bytes.count else { return nil }
            switch (bytes[base], bytes[base + 1]) {
            case (0x49, 0x49): little = true
            case (0x4D, 0x4D): little = false
            default: return nil
            }
            self.bytes = bytes
            self.base = base
        }

        func u16(_ p: Int) -> Int {
            guard p >= 0, p + 2 <= bytes.count else { return 0 }
            return little ? Int(bytes[p]) | Int(bytes[p + 1]) << 8 : Int(bytes[p]) << 8 | Int(bytes[p + 1])
        }

        func u32(_ p: Int) -> Int { little ? u16(p) | u16(p + 2) << 16 : u16(p) << 16 | u16(p + 2) }

        mutating func set16(_ p: Int, _ value: Int) {
            guard p >= 0, p + 2 <= bytes.count else { return }
            let hi = UInt8((value >> 8) & 0xFF), lo = UInt8(value & 0xFF)
            bytes[p] = little ? lo : hi
            bytes[p + 1] = little ? hi : lo
        }

        mutating func set32(_ p: Int, _ value: Int) {
            set16(little ? p : p + 2, value & 0xFFFF)
            set16(little ? p + 2 : p, (value >> 16) & 0xFFFF)
        }

        var firstIFD: Int? { pointer(u32(base + 4)) }

        func pointer(_ offset: Int) -> Int? {
            let p = base + offset
            return offset > 0 && p + 2 <= bytes.count ? p : nil
        }

        func entries(_ ifd: Int) -> [Int] {
            let count = u16(ifd)
            guard count < 1000, ifd + 2 + count * 12 <= bytes.count else { return [] }
            return (0..<count).map { ifd + 2 + $0 * 12 }
        }

        func entry(_ ifd: Int, _ tag: Int) -> Int? { entries(ifd).first { u16($0) == tag } }

        func next(_ ifd: Int) -> Int? {
            let count = u16(ifd)
            let p = ifd + 2 + count * 12
            guard p + 4 <= bytes.count else { return nil }
            return pointer(u32(p))
        }

        /// The value of a single SHORT or LONG entry.
        func value(_ entry: Int) -> Int? {
            guard u32(entry + 4) == 1 else { return nil }
            switch u16(entry + 2) {
            case 3: return u16(entry + 8)
            case 4: return u32(entry + 8)
            default: return nil
            }
        }

        mutating func setValue(_ entry: Int, _ value: Int) -> Bool {
            switch u16(entry + 2) {
            case 3 where value <= 0xFFFF: set16(entry + 8, value)
            case 4: set32(entry + 8, value)
            default: return false
            }
            return true
        }

        mutating func setOrientation(in ifd: Int) {
            if let e = entry(ifd, 0x0112), u16(e + 2) == 3, (1...8).contains(u16(e + 8)) { set16(e + 8, 1) }
        }

        /// Swaps the values of two entries, such as width and height. The tags stay put, so the IFD stays sorted.
        mutating func swapValues(in ifd: Int, _ a: Int, _ b: Int) {
            guard let ea = entry(ifd, a), let eb = entry(ifd, b) else { return }
            for k in 2..<12 { bytes.swapAt(ea + k, eb + k) }
        }

        /// Every byte range the EXIF structure uses: the IFDs (0, 1, EXIF, GPS, interoperability), and every value
        /// stored outside its entry, the maker note included, apart from `skipping`.
        func referencedRanges(skipping: Range<Int>) -> [Range<Int>] {
            var ranges: [Range<Int>] = []
            var queue = [firstIFD].compactMap { $0 }
            var seen = Set<Int>()
            while let ifd = queue.popLast() {
                guard seen.insert(ifd).inserted, seen.count < 16 else { continue }
                let list = entries(ifd)
                ranges.append(ifd..<(ifd + 2 + list.count * 12 + 4))
                for e in list {
                    let tag = u16(e)
                    if [0x8769, 0x8825, 0xA005].contains(tag), let offset = value(e), let sub = pointer(offset) { queue.append(sub) }
                    let unit = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4][u16(e + 2)] ?? 1
                    let size = unit * u32(e + 4)
                    if size > 4 {
                        let start = base + u32(e + 8)
                        if start != skipping.lowerBound { ranges.append(start..<(start + size)) }
                    }
                }
                if let next = next(ifd) { queue.append(next) }
            }
            return ranges
        }
    }

    /// Sets the EXIF orientation to 1, swaps the recorded width and height when the picture turns a quarter, and
    /// turns the thumbnail.
    private static func patchExif(_ segment: inout [UInt8], _ flip: Flip, depth: Int) throws {
        guard var tiff = TIFF(segment, base: 10), let ifd0 = tiff.firstIFD else { return }
        tiff.setOrientation(in: ifd0)
        if flip.transpose {
            tiff.swapValues(in: ifd0, 0x0100, 0x0101)
            if let pointer = tiff.entry(ifd0, 0x8769), let offset = tiff.value(pointer), let exif = tiff.pointer(offset) {
                tiff.swapValues(in: exif, 0xA002, 0xA003)
            }
        }
        defer { segment = tiff.bytes }
        guard let ifd1 = tiff.next(ifd0) else { return }
        tiff.setOrientation(in: ifd1)

        guard let offsetEntry = tiff.entry(ifd1, 0x0201), let lengthEntry = tiff.entry(ifd1, 0x0202),
              let offset = tiff.value(offsetEntry), let length = tiff.value(lengthEntry), length > 0
        else { return }
        let start = tiff.base + offset
        guard start + length <= tiff.bytes.count, tiff.bytes[start] == 0xFF, tiff.bytes[start + 1] == 0xD8, depth < 2 else {
            throw Failure.unsupported("thumbnail")
        }
        let thumbnail = try transform(Array(tiff.bytes[start..<(start + length)]), flip, trim: true, embedded: true)
        // The slot is the old thumbnail plus the zero padding after it that nothing in the EXIF points into: earlier
        // turns may have left some there, and cameras pad the segment too.
        let reserved = tiff.referencedRanges(skipping: start..<(start + length))
        var slotEnd = start + length
        while slotEnd < tiff.bytes.count, tiff.bytes[slotEnd] == 0,
              !reserved.contains(where: { $0.contains(slotEnd) }) { slotEnd += 1 }
        if thumbnail.count <= slotEnd - start {
            tiff.bytes.replaceSubrange(start..<(start + thumbnail.count), with: thumbnail)
            for i in (start + thumbnail.count)..<slotEnd { tiff.bytes[i] = 0 }
        } else if start + length == tiff.bytes.count, tiff.bytes.count - length + thumbnail.count <= 0xFFFF + 2 {
            tiff.bytes.replaceSubrange(start..<tiff.bytes.count, with: thumbnail)
        } else {
            throw Failure.unsupported("thumbnail")
        }
        guard tiff.setValue(lengthEntry, thumbnail.count) else { throw Failure.unsupported("thumbnail") }
        let segmentLength = tiff.bytes.count - 2
        tiff.bytes[2] = UInt8(segmentLength >> 8)
        tiff.bytes[3] = UInt8(segmentLength & 0xFF)
    }

    /// `tiff:Orientation="6"` and `<tiff:Orientation>6</tiff:Orientation>` become 1.
    private static func patchXMP(_ segment: inout [UInt8]) {
        for pattern in ["tiff:Orientation=\"", "<tiff:Orientation>"].map({ Array($0.utf8) }) {
            var i = 0
            while i + pattern.count + 1 < segment.count {
                if segment[i] == pattern[0], segment[i..<(i + pattern.count)].elementsEqual(pattern) {
                    let digit = i + pattern.count
                    if (0x31...0x38).contains(segment[digit]), segment[digit + 1] == 0x22 || segment[digit + 1] == 0x3C {
                        segment[digit] = 0x31
                    }
                }
                i += 1
            }
        }
    }

    /// Turns the previews listed in the MPF index (stored after the picture) and points the index at their new
    /// places. The index sits in the picture's header, so its size never changes.
    private static func relocateMPF(in output: inout [UInt8], segmentAt segment: Int, original: [UInt8],
                                    originalSegmentAt originalSegment: Int, originalEnd: Int,
                                    trailing: inout [UInt8], _ flip: Flip) throws {
        let header = segment + 8, originalHeader = originalSegment + 8
        guard var tiff = TIFF(output, base: header), let ifd = tiff.firstIFD,
              let entry = tiff.entry(ifd, 0xB002), tiff.u16(entry + 2) == 7
        else { return }
        let length = tiff.u32(entry + 4)
        let table = header + tiff.u32(entry + 8)
        let segmentEnd = segment + 2 + (Int(output[segment + 2]) << 8 | Int(output[segment + 3]))
        guard length >= 16, length % 16 == 0, table >= header, table + length <= segmentEnd else {
            throw Failure.unsupported("MPF")
        }

        struct Item { let entry: Int; let start: Int; let size: Int }
        var items: [Item] = []
        for i in 0..<(length / 16) {
            let e = table + i * 16
            let size = tiff.u32(e + 4), offset = tiff.u32(e + 8)
            if offset == 0 {
                if i == 0 { tiff.set32(e + 4, output.count) } // The picture itself.
                continue
            }
            guard size > 0 else { continue }
            let start = originalHeader + offset - originalEnd
            guard start >= 0, start + size <= trailing.count else { throw Failure.unsupported("MPF") }
            items.append(Item(entry: e, start: start, size: size))
        }
        items.sort { $0.start < $1.start }

        var rebuilt: [UInt8] = []
        var cursor = 0
        for item in items {
            guard item.start >= cursor else { throw Failure.unsupported("MPF") }
            rebuilt += trailing[cursor..<item.start]
            let preview = Array(trailing[item.start..<(item.start + item.size)])
            guard preview.starts(with: [0xFF, 0xD8]) else { throw Failure.unsupported("MPF") }
            let turned = try transform(preview, flip, trim: true, embedded: true)
            tiff.set32(item.entry + 4, turned.count)
            tiff.set32(item.entry + 8, output.count + rebuilt.count - header)
            rebuilt += turned
            cursor = item.start + item.size
        }
        rebuilt += trailing[cursor...]
        trailing = rebuilt
        output = tiff.bytes
    }

    // MARK: Coefficients

    static let zigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]

    struct Component {
        let id: UInt8
        let h: Int, v: Int
        let tq: Int
        /// The block grid, padded to whole MCUs.
        var gridWidth = 0, gridHeight = 0
        /// The blocks that hold picture.
        var blocksWide = 0, blocksHigh = 0
        /// Where the component's blocks start in `Picture.coefficients`, in coefficients.
        var offset = 0
    }

    struct QuantTable: Equatable {
        var sixteenBit: Bool
        /// In natural (row by row) order.
        var values: [UInt16]
    }

    struct Picture {
        var frameMarker: UInt8 = 0xC0
        var width = 0, height = 0
        var components: [Component] = []
        var quant: [Int: QuantTable] = [:]
        /// APPn and COM segments before the first scan, marker included.
        var headers: [Range<Int>] = []
        /// Just after EOI.
        var end = 0
        /// Every block of every component, 64 coefficients each, in natural order.
        var coefficients: [Int16] = []
        var maxH = 1, maxV = 1, mcusWide = 0, mcusHigh = 0

        init() {}

        mutating func layOut() throws {
            guard width > 0, height > 0, !components.isEmpty else { throw Failure.unsupported("frame") }
            if components.count == 1 {
                // A single component is coded block by block whatever sampling it declares.
                components[0] = Component(id: components[0].id, h: 1, v: 1, tq: components[0].tq)
            }
            maxH = components.map(\.h).max()!
            maxV = components.map(\.v).max()!
            mcusWide = (width + 8 * maxH - 1) / (8 * maxH)
            mcusHigh = (height + 8 * maxV - 1) / (8 * maxV)
            var total = 0
            for i in components.indices {
                let c = components[i]
                components[i].gridWidth = mcusWide * c.h
                components[i].gridHeight = mcusHigh * c.v
                components[i].blocksWide = ((width * c.h + maxH - 1) / maxH + 7) / 8
                components[i].blocksHigh = ((height * c.v + maxV - 1) / maxV + 7) / 8
                components[i].offset = total
                total += components[i].gridWidth * components[i].gridHeight * 64
            }
            guard total < 1 << 31 else { throw Failure.unsupported("size") }
            coefficients = [Int16](repeating: 0, count: total)
        }

        func transformed(_ flip: Flip, trim: Bool) throws -> Picture {
            var out = Picture()
            out.frameMarker = frameMarker
            out.width = flip.transpose ? height : width
            out.height = flip.transpose ? width : height
            let mcuWidth = 8 * (flip.transpose ? maxV : maxH), mcuHeight = 8 * (flip.transpose ? maxH : maxV)
            if flip.hflip, out.width % mcuWidth != 0 {
                guard trim, out.width > mcuWidth else { throw Failure.notAligned }
                out.width -= out.width % mcuWidth
            }
            if flip.vflip, out.height % mcuHeight != 0 {
                guard trim, out.height > mcuHeight else { throw Failure.notAligned }
                out.height -= out.height % mcuHeight
            }
            out.components = components.map {
                Component(id: $0.id, h: flip.transpose ? $0.v : $0.h, v: flip.transpose ? $0.h : $0.v, tq: $0.tq)
            }
            out.quant = quant.mapValues { table in
                guard flip.transpose else { return table }
                var t = table
                for v in 0..<8 { for u in 0..<8 { t.values[v * 8 + u] = table.values[u * 8 + v] } }
                return t
            }
            try out.layOut()

            // Where each output coefficient comes from, and whether its sign flips: mirroring a block left-right
            // negates its odd horizontal frequencies, top-bottom its odd vertical ones.
            var from = [Int](repeating: 0, count: 64), negate = [Bool](repeating: false, count: 64)
            for v in 0..<8 {
                for u in 0..<8 {
                    from[v * 8 + u] = flip.transpose ? u * 8 + v : v * 8 + u
                    negate[v * 8 + u] = (flip.hflip && u % 2 == 1) != (flip.vflip && v % 2 == 1)
                }
            }

            coefficients.withUnsafeBufferPointer { src in
                out.coefficients.withUnsafeMutableBufferPointer { dst in
                    for (s, d) in zip(components, out.components) {
                        for dy in 0..<d.gridHeight {
                            for dx in 0..<d.gridWidth {
                                let y1 = flip.vflip ? d.blocksHigh - 1 - dy : dy
                                let x1 = flip.hflip ? d.blocksWide - 1 - dx : dx
                                let (sx, sy) = flip.transpose ? (y1, x1) : (x1, y1)
                                guard sx >= 0, sy >= 0, sx < s.gridWidth, sy < s.gridHeight else { continue }
                                let a = s.offset + (sy * s.gridWidth + sx) * 64
                                let b = d.offset + (dy * d.gridWidth + dx) * 64
                                for k in 0..<64 {
                                    let c = src[a + from[k]]
                                    dst[b + k] = negate[k] ? 0 &- c : c
                                }
                            }
                        }
                    }
                }
            }
            return out
        }

        /// Same size, sampling, tables and coefficients in every block that holds picture.
        func sameImage(as other: Picture) -> Bool {
            guard width == other.width, height == other.height, components.count == other.components.count else { return false }
            for (a, b) in zip(components, other.components) {
                guard a.id == b.id, a.h == b.h, a.v == b.v, quant[a.tq]?.values == other.quant[b.tq]?.values,
                      a.blocksWide == b.blocksWide, a.blocksHigh == b.blocksHigh
                else { return false }
                for y in 0..<a.blocksHigh {
                    let ra = a.offset + y * a.gridWidth * 64, rb = b.offset + y * b.gridWidth * 64
                    if !coefficients[ra..<(ra + a.blocksWide * 64)].elementsEqual(other.coefficients[rb..<(rb + b.blocksWide * 64)]) {
                        return false
                    }
                }
            }
            return true
        }
    }
}

// MARK: - Decoding

extension JPEGLosslessTransform.Picture {
    typealias Failure = JPEGLosslessTransform.Failure

    struct HuffmanSpec {
        var counts: [UInt8] // Codes of each length 1...16.
        var symbols: [UInt8]
    }

    init(_ bytes: [UInt8]) throws {
        self.init()
        let n = bytes.count
        guard n > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw Failure.unsupported("not a JPEG") }
        var dcSpecs: [Int: HuffmanSpec] = [:], acSpecs: [Int: HuffmanSpec] = [:]
        var restartInterval = 0
        var hasFrame = false, scanned = false
        var decoded = Set<Int>()
        var p = 2

        func be16(_ i: Int) -> Int { Int(bytes[i]) << 8 | Int(bytes[i + 1]) }

        markers: while true {
            guard p + 1 < n, bytes[p] == 0xFF else { throw Failure.unsupported("damaged") }
            var marker = bytes[p + 1]
            while marker == 0xFF {
                p += 1
                guard p + 1 < n else { throw Failure.unsupported("damaged") }
                marker = bytes[p + 1]
            }
            let start = p
            p += 2
            switch marker {
            case 0xD9:
                end = p
                break markers
            case 0xD0...0xD7, 0x01:
                continue markers
            default:
                break
            }
            guard p + 2 <= n else { throw Failure.unsupported("damaged") }
            let length = be16(p)
            guard length >= 2, p + length <= n else { throw Failure.unsupported("damaged") }
            let body = (p + 2)..<(p + length)

            switch marker {
            case 0xE0...0xEF, 0xFE:
                if !scanned { headers.append(start..<(p + length)) }
            case 0xDB:
                guard !scanned else { throw Failure.unsupported("tables between scans") }
                var q = body.lowerBound
                while q < body.upperBound {
                    let precision = Int(bytes[q] >> 4), id = Int(bytes[q] & 15)
                    let size = precision == 0 ? 64 : 128
                    guard precision <= 1, id < 4, q + 1 + size <= body.upperBound else { throw Failure.unsupported("damaged") }
                    var values = [UInt16](repeating: 0, count: 64)
                    for k in 0..<64 {
                        values[JPEGLosslessTransform.zigzag[k]] = precision == 0 ? UInt16(bytes[q + 1 + k]) : UInt16(be16(q + 1 + 2 * k))
                    }
                    quant[id] = JPEGLosslessTransform.QuantTable(sixteenBit: precision == 1, values: values)
                    q += 1 + size
                }
            case 0xC4:
                var q = body.lowerBound
                while q < body.upperBound {
                    guard q + 17 <= body.upperBound else { throw Failure.unsupported("damaged") }
                    let tableClass = Int(bytes[q] >> 4), id = Int(bytes[q] & 15)
                    let counts = Array(bytes[(q + 1)..<(q + 17)])
                    let total = counts.reduce(0) { $0 + Int($1) }
                    guard tableClass <= 1, id < 4, total <= 256, q + 17 + total <= body.upperBound else { throw Failure.unsupported("damaged") }
                    let spec = HuffmanSpec(counts: counts, symbols: Array(bytes[(q + 17)..<(q + 17 + total)]))
                    if tableClass == 0 { dcSpecs[id] = spec } else { acSpecs[id] = spec }
                    q += 17 + total
                }
            case 0xDD:
                guard length == 4 else { throw Failure.unsupported("damaged") }
                restartInterval = be16(body.lowerBound)
            case 0xC0, 0xC1:
                guard !hasFrame, length >= 8 else { throw Failure.unsupported("damaged") }
                hasFrame = true
                frameMarker = marker
                guard bytes[body.lowerBound] == 8 else { throw Failure.unsupported("\(bytes[body.lowerBound])-bit") }
                height = be16(body.lowerBound + 1)
                width = be16(body.lowerBound + 3)
                guard height > 0 else { throw Failure.unsupported("DNL") }
                let count = Int(bytes[body.lowerBound + 5])
                guard (1...4).contains(count), length == 8 + 3 * count else { throw Failure.unsupported("damaged") }
                for i in 0..<count {
                    let c = body.lowerBound + 6 + 3 * i
                    let h = Int(bytes[c + 1] >> 4), v = Int(bytes[c + 1] & 15), tq = Int(bytes[c + 2])
                    guard (1...4).contains(h), (1...4).contains(v), tq < 4 else { throw Failure.unsupported("damaged") }
                    components.append(JPEGLosslessTransform.Component(id: bytes[c], h: h, v: v, tq: tq))
                }
                try layOut()
            case 0xC2, 0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
                throw Failure.unsupported("progressive or arithmetic")
            case 0xDC:
                throw Failure.unsupported("DNL")
            case 0xDA:
                guard hasFrame, length >= 6 else { throw Failure.unsupported("damaged") }
                let count = Int(bytes[body.lowerBound])
                guard count >= 1, count <= components.count, length == 6 + 2 * count else { throw Failure.unsupported("damaged") }
                var scan: [(component: Int, dc: HuffmanDecoder, ac: HuffmanDecoder)] = []
                for i in 0..<count {
                    let s = body.lowerBound + 1 + 2 * i
                    guard let index = components.firstIndex(where: { $0.id == bytes[s] }), !decoded.contains(index),
                          let dc = dcSpecs[Int(bytes[s + 1] >> 4)], let ac = acSpecs[Int(bytes[s + 1] & 15)]
                    else { throw Failure.unsupported("damaged") }
                    decoded.insert(index)
                    scan.append((index, try HuffmanDecoder(dc), try HuffmanDecoder(ac)))
                }
                let tail = body.lowerBound + 1 + 2 * count
                guard bytes[tail] == 0, bytes[tail + 1] == 63, bytes[tail + 2] == 0 else { throw Failure.unsupported("progressive") }
                p = try decodeScan(bytes, from: p + length, scan, restartInterval: restartInterval)
                scanned = true
                continue markers
            default:
                break
            }
            p += length
        }
        guard hasFrame, decoded.count == components.count else { throw Failure.unsupported("incomplete") }
        guard components.allSatisfy({ quant[$0.tq] != nil }) else { throw Failure.unsupported("damaged") }
    }

    /// Decodes one scan's entropy-coded data into `coefficients` and returns where the next marker starts.
    private mutating func decodeScan(_ bytes: [UInt8], from start: Int,
                                     _ scan: [(component: Int, dc: HuffmanDecoder, ac: HuffmanDecoder)],
                                     restartInterval: Int) throws -> Int {
        let components = components
        let mcusWide = mcusWide, mcusHigh = mcusHigh
        let blocksPerMCU = scan.reduce(0) { $0 + components[$1.component].h * components[$1.component].v }
        guard scan.count == 1 || blocksPerMCU <= 10 else { throw Failure.unsupported("damaged") }

        return try bytes.withUnsafeBufferPointer { raw in
            try coefficients.withUnsafeMutableBufferPointer { coef in
                var reader = BitReader(raw.baseAddress!, end: raw.count, pos: start)
                var predictors = [Int](repeating: 0, count: scan.count)
                var mcu = 0
                var expectedRestart = 0

                func restartIfDue() throws {
                    guard restartInterval > 0, mcu > 0, mcu % restartInterval == 0 else { return }
                    guard !reader.overran else { throw Failure.unsupported("damaged") }
                    // The reader stops at a marker, so this is usually already the RST marker.
                    var q = reader.pos
                    while q + 1 < raw.count, !(raw[q] == 0xFF && raw[q + 1] != 0 && raw[q + 1] != 0xFF) { q += 1 }
                    guard q + 1 < raw.count, raw[q + 1] == 0xD0 + UInt8(expectedRestart & 7) else { throw Failure.unsupported("damaged") }
                    expectedRestart += 1
                    reader.restart(at: q + 2)
                    for i in predictors.indices { predictors[i] = 0 }
                }

                if scan.count == 1 {
                    let c = components[scan[0].component]
                    let dc = scan[0].dc, ac = scan[0].ac
                    for by in 0..<c.blocksHigh {
                        for bx in 0..<c.blocksWide {
                            try restartIfDue()
                            try reader.decodeBlock(coef.baseAddress! + c.offset + (by * c.gridWidth + bx) * 64, dc, ac, &predictors[0])
                            mcu += 1
                        }
                    }
                } else {
                    for my in 0..<mcusHigh {
                        for mx in 0..<mcusWide {
                            try restartIfDue()
                            for (i, s) in scan.enumerated() {
                                let c = components[s.component]
                                for v in 0..<c.v {
                                    for h in 0..<c.h {
                                        let block = c.offset + ((my * c.v + v) * c.gridWidth + mx * c.h + h) * 64
                                        try reader.decodeBlock(coef.baseAddress! + block, s.dc, s.ac, &predictors[i])
                                    }
                                }
                            }
                            mcu += 1
                        }
                    }
                }
                guard !reader.overran else { throw Failure.unsupported("damaged") }

                var q = reader.pos
                while q + 1 < raw.count {
                    if raw[q] == 0xFF, raw[q + 1] != 0, raw[q + 1] != 0xFF, !(0xD0...0xD7).contains(raw[q + 1]) { return q }
                    q += 1
                }
                throw Failure.unsupported("damaged")
            }
        }
    }
}

final class HuffmanDecoder {
    /// For codes up to 9 bits: length << 8 | symbol, 0 when the code is longer.
    private var lookup = [UInt16](repeating: 0, count: 512)
    private var maxCode = [Int32](repeating: -1, count: 18)
    private var valueOffset = [Int32](repeating: 0, count: 17)
    private let symbols: [UInt8]

    init(_ spec: JPEGLosslessTransform.Picture.HuffmanSpec) throws {
        symbols = spec.symbols
        var code: Int32 = 0, k = 0
        for length in 1...16 {
            let count = Int(spec.counts[length - 1])
            if count > 0 {
                valueOffset[length] = Int32(k) - code
                for _ in 0..<count {
                    if length <= 9 {
                        let shift = 9 - length, first = Int(code) << shift
                        for i in 0..<(1 << shift) { lookup[first + i] = UInt16(length << 8) | UInt16(symbols[k]) }
                    }
                    code += 1
                    k += 1
                }
                maxCode[length] = code - 1
            }
            guard code <= 1 << length else { throw JPEGLosslessTransform.Failure.unsupported("damaged") }
            code <<= 1
        }
    }

    @inline(__always)
    func decode(_ reader: inout BitReader) throws -> Int {
        if reader.count < 16 { reader.fill() }
        let entry = lookup[Int(reader.acc >> 55)]
        if entry != 0 {
            reader.skip(Int(entry >> 8))
            return Int(entry & 0xFF)
        }
        for length in 10...16 {
            let code = Int32(truncatingIfNeeded: reader.acc >> UInt64(64 - length))
            if code <= maxCode[length] {
                reader.skip(length)
                return Int(symbols[Int(valueOffset[length] + code)])
            }
        }
        throw JPEGLosslessTransform.Failure.unsupported("damaged")
    }
}

struct BitReader {
    let base: UnsafePointer<UInt8>
    let end: Int
    var pos: Int
    /// Unread bits, left aligned.
    var acc: UInt64 = 0
    var count = 0
    /// Stopped at a marker: only zero bits from here on.
    var marker = false
    /// Bytes of zeros fed in after the data ran out.
    var padding = 0

    init(_ base: UnsafePointer<UInt8>, end: Int, pos: Int) {
        self.base = base
        self.end = end
        self.pos = pos
    }

    /// Whether decoding read past the end of the data, which only a damaged file does.
    var overran: Bool { padding * 8 > count }

    @inline(__always)
    mutating func fill() {
        while count <= 56 {
            var byte: UInt64 = 0
            if !marker, pos < end {
                let b = base[pos]
                if b != 0xFF {
                    byte = UInt64(b)
                    pos += 1
                } else if pos + 1 < end, base[pos + 1] == 0 {
                    byte = 0xFF
                    pos += 2
                } else {
                    marker = true
                    padding += 1
                }
            } else {
                padding += 1
            }
            acc |= byte << UInt64(56 - count)
            count += 8
        }
    }

    @inline(__always)
    mutating func skip(_ n: Int) {
        acc <<= UInt64(n)
        count -= n
    }

    @inline(__always)
    mutating func bits(_ n: Int) -> Int {
        if count < n { fill() }
        let value = Int(acc >> UInt64(64 - n))
        skip(n)
        return value
    }

    mutating func restart(at position: Int) {
        pos = position
        acc = 0
        count = 0
        marker = false
        padding = 0
    }

    @inline(__always)
    static func extend(_ value: Int, _ n: Int) -> Int {
        value < 1 << (n - 1) ? value - (1 << n) + 1 : value
    }

    @inline(__always)
    mutating func decodeBlock(_ block: UnsafeMutablePointer<Int16>, _ dc: HuffmanDecoder, _ ac: HuffmanDecoder,
                              _ predictor: inout Int) throws {
        let s = try dc.decode(&self)
        guard s <= 11 else { throw JPEGLosslessTransform.Failure.unsupported("damaged") }
        if s > 0 { predictor += Self.extend(bits(s), s) }
        guard predictor >= -32768, predictor <= 32767 else { throw JPEGLosslessTransform.Failure.unsupported("damaged") }
        block[0] = Int16(predictor)
        var k = 1
        while k < 64 {
            let rs = try ac.decode(&self)
            let run = rs >> 4, size = rs & 15
            if size == 0 {
                if run != 15 { break }
                k += 16
                continue
            }
            k += run
            guard k < 64 else { throw JPEGLosslessTransform.Failure.unsupported("damaged") }
            block[JPEGLosslessTransform.zigzag[k]] = Int16(Self.extend(bits(size), size))
            k += 1
        }
    }
}

// MARK: - Encoding

protocol SymbolSink {
    /// `table`: 0 luma DC, 1 luma AC, 2 chroma DC, 3 chroma AC.
    mutating func put(_ table: Int, _ symbol: Int, _ bits: Int, _ length: Int)
}

private struct SymbolCounter: SymbolSink {
    var frequencies = [Int](repeating: 0, count: 4 * 256)
    mutating func put(_ table: Int, _ symbol: Int, _ bits: Int, _ length: Int) { frequencies[table * 256 + symbol] += 1 }
}

private struct BitWriter: SymbolSink {
    let codes: [UInt32]
    let lengths: [UInt8]
    var output: [UInt8] = []
    var acc: UInt64 = 0
    var count = 0

    @inline(__always)
    mutating func emit(_ value: UInt32, _ n: Int) {
        acc = acc << UInt64(n) | UInt64(value) & ((1 << UInt64(n)) - 1)
        count += n
        while count >= 8 {
            count -= 8
            let byte = UInt8(truncatingIfNeeded: acc >> UInt64(count))
            output.append(byte)
            if byte == 0xFF { output.append(0) }
        }
    }

    mutating func put(_ table: Int, _ symbol: Int, _ bits: Int, _ length: Int) {
        emit(codes[table * 256 + symbol], Int(lengths[table * 256 + symbol]))
        if length > 0 { emit(UInt32(truncatingIfNeeded: bits), length) }
    }

    mutating func flush() {
        if count > 0 { emit((1 << UInt32(8 - count)) - 1, 8 - count) }
    }
}

extension JPEGLosslessTransform.Picture {
    /// Everything from DQT to EOI, with Huffman tables built for these exact coefficients.
    func encode() throws -> [UInt8] {
        let interleaved = components.count > 1 && components.reduce(0) { $0 + $1.h * $1.v } <= 10
        let scans: [[Int]] = interleaved ? [Array(components.indices)] : components.indices.map { [$0] }

        var counter = SymbolCounter()
        for scan in scans { try walk(scan, &counter) }
        let tableCount = components.count > 1 ? 4 : 2
        let specs = (0..<tableCount).map { Self.optimalTable(Array(counter.frequencies[($0 * 256)..<($0 * 256 + 256)])) }

        var codes = [UInt32](repeating: 0, count: 4 * 256), lengths = [UInt8](repeating: 0, count: 4 * 256)
        for (t, spec) in specs.enumerated() {
            var code: UInt32 = 0, k = 0
            for length in 1...16 {
                for _ in 0..<Int(spec.counts[length - 1]) {
                    codes[t * 256 + Int(spec.symbols[k])] = code
                    lengths[t * 256 + Int(spec.symbols[k])] = UInt8(length)
                    code += 1
                    k += 1
                }
                code <<= 1
            }
        }

        var out: [UInt8] = []
        func segment(_ marker: UInt8, _ body: [UInt8]) {
            out += [0xFF, marker, UInt8((body.count + 2) >> 8), UInt8((body.count + 2) & 0xFF)]
            out += body
        }

        for id in Set(components.map(\.tq)).sorted() {
            guard let table = quant[id] else { throw JPEGLosslessTransform.Failure.unsupported("tables") }
            var body: [UInt8] = [UInt8((table.sixteenBit ? 0x10 : 0) | id)]
            for k in 0..<64 {
                let value = table.values[JPEGLosslessTransform.zigzag[k]]
                body += table.sixteenBit ? [UInt8(value >> 8), UInt8(value & 0xFF)] : [UInt8(value)]
            }
            segment(0xDB, body)
        }

        var frame: [UInt8] = [8, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), UInt8(components.count)]
        for c in components { frame += [c.id, UInt8(c.h << 4 | c.v), UInt8(c.tq)] }
        segment(frameMarker, frame)

        var tables: [UInt8] = []
        for (t, spec) in specs.enumerated() {
            tables.append(UInt8((t % 2) << 4 | t / 2))
            tables += spec.counts
            tables += spec.symbols
        }
        segment(0xC4, tables)

        for scan in scans {
            var header: [UInt8] = [UInt8(scan.count)]
            for i in scan {
                let t = UInt8(i == 0 ? 0 : 1)
                header += [components[i].id, t << 4 | t]
            }
            header += [0, 63, 0]
            segment(0xDA, header)
            var writer = BitWriter(codes: codes, lengths: lengths)
            writer.output.reserveCapacity(coefficients.count / 4)
            try walk(scan, &writer)
            writer.flush()
            out += writer.output
        }
        out += [0xFF, 0xD9]
        return out
    }

    /// Feeds every block of a scan, in coding order, to `sink` as Huffman symbols.
    private func walk<S: SymbolSink>(_ scan: [Int], _ sink: inout S) throws {
        let components = components
        try coefficients.withUnsafeBufferPointer { coef in
            var predictors = [Int](repeating: 0, count: scan.count)
            if scan.count == 1 {
                let c = components[scan[0]]
                let table = scan[0] == 0 ? 0 : 2
                for by in 0..<c.blocksHigh {
                    for bx in 0..<c.blocksWide {
                        try Self.encodeBlock(coef.baseAddress! + c.offset + (by * c.gridWidth + bx) * 64, &predictors[0], table, &sink)
                    }
                }
            } else {
                for my in 0..<mcusHigh {
                    for mx in 0..<mcusWide {
                        for (i, ci) in scan.enumerated() {
                            let c = components[ci]
                            let table = ci == 0 ? 0 : 2
                            for v in 0..<c.v {
                                for h in 0..<c.h {
                                    let block = c.offset + ((my * c.v + v) * c.gridWidth + mx * c.h + h) * 64
                                    try Self.encodeBlock(coef.baseAddress! + block, &predictors[i], table, &sink)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @inline(__always)
    private static func magnitude(_ value: Int) -> (size: Int, bits: Int) {
        let size = value == 0 ? 0 : Int.bitWidth - abs(value).leadingZeroBitCount
        return (size, value < 0 ? (value - 1) & ((1 << size) - 1) : value)
    }

    @inline(__always)
    private static func encodeBlock<S: SymbolSink>(_ block: UnsafePointer<Int16>, _ predictor: inout Int, _ table: Int,
                                                   _ sink: inout S) throws {
        let dc = Int(block[0])
        let (size, bits) = magnitude(dc - predictor)
        predictor = dc
        guard size <= 11 else { throw JPEGLosslessTransform.Failure.unsupported("coefficients") }
        sink.put(table, size, bits, size)
        var run = 0
        for k in 1..<64 {
            let value = Int(block[JPEGLosslessTransform.zigzag[k]])
            if value == 0 {
                run += 1
                continue
            }
            while run > 15 {
                sink.put(table + 1, 0xF0, 0, 0)
                run -= 16
            }
            let (size, bits) = magnitude(value)
            guard size <= 10 else { throw JPEGLosslessTransform.Failure.unsupported("coefficients") }
            sink.put(table + 1, run << 4 | size, bits, size)
            run = 0
        }
        if run > 0 { sink.put(table + 1, 0, 0, 0) }
    }

    /// The optimal Huffman table for these symbol counts, limited to 16-bit codes, with no code of all ones
    /// (JPEG Annex K.2, as libjpeg does it).
    static func optimalTable(_ counts: [Int]) -> HuffmanSpec {
        var freq = counts + [1] // Symbol 256 reserves the all-ones code.
        if !counts.contains(where: { $0 > 0 }) { freq[0] = 1 }
        var codeSize = [Int](repeating: 0, count: 257), others = [Int](repeating: -1, count: 257)
        while true {
            var c1 = -1, c2 = -1, v = Int.max
            for i in 0...256 where freq[i] > 0 && freq[i] <= v { v = freq[i]; c1 = i }
            v = Int.max
            for i in 0...256 where freq[i] > 0 && freq[i] <= v && i != c1 { v = freq[i]; c2 = i }
            if c2 < 0 { break }
            freq[c1] += freq[c2]
            freq[c2] = 0
            codeSize[c1] += 1
            while others[c1] >= 0 { c1 = others[c1]; codeSize[c1] += 1 }
            others[c1] = c2
            codeSize[c2] += 1
            while others[c2] >= 0 { c2 = others[c2]; codeSize[c2] += 1 }
        }
        let longest = max(codeSize.max() ?? 0, 17)
        var bits = [Int](repeating: 0, count: longest + 1)
        for size in codeSize where size > 0 { bits[size] += 1 }
        var i = longest
        while i > 16 {
            while bits[i] > 0 {
                var j = i - 2
                while bits[j] == 0 { j -= 1 }
                bits[i] -= 2
                bits[i - 1] += 1
                bits[j + 1] += 2
                bits[j] -= 1
            }
            i -= 1
        }
        while bits[i] == 0 { i -= 1 }
        bits[i] -= 1 // Drop the reserved code.
        var symbols: [UInt8] = []
        for length in 1...longest {
            for s in 0..<256 where codeSize[s] == length { symbols.append(UInt8(s)) }
        }
        return HuffmanSpec(counts: (1...16).map { UInt8(bits[$0]) }, symbols: symbols)
    }
}

private extension Array where Element == UInt8 {
    func starts(at offset: Int, with prefix: [UInt8]) -> Bool {
        offset + prefix.count <= count && self[offset..<(offset + prefix.count)].elementsEqual(prefix)
    }
}
