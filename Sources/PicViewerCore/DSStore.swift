import Foundation

/// A read-only parser for Finder's .DS_Store files, which keep each folder's view settings (view style, sort column,
/// arrangement). The format is a "buddy allocator" file holding a B-tree of records.
public struct DSStore {
    public enum Value {
        case long(UInt32)
        case bool(Bool)
        case blob(Data)
        case type(String)
        case string(String)
        case wide(UInt64)
    }

    public struct Record {
        public let filename: String
        public let code: String
        public let value: Value
    }

    public let records: [Record]

    public init?(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }

    public init?(data: Data) {
        var parser = Parser(bytes: [UInt8](data))
        guard let records = try? parser.parse() else { return nil }
        self.records = records
    }

    /// The records describing the folder itself (Finder files them under the name ".").
    public func folderRecords() -> [String: Value] {
        var result: [String: Value] = [:]
        for record in records where record.filename == "." {
            result[record.code] = record.value
        }
        return result
    }

    /// A record holding a binary property list, decoded.
    public static func plist(_ value: Value?) -> [String: Any]? {
        guard case .blob(let data)? = value else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private struct ParseError: Error {}

    private struct Parser {
        let bytes: [UInt8]
        // Every offset in the file counts from byte 4, past the alignment word.
        let base = 4
        var blockAddresses: [UInt32] = []
        var records: [Record] = []
        var visitedNodes = Set<Int>()

        init(bytes: [UInt8]) { self.bytes = bytes }

        func u32(_ offset: Int) throws -> UInt32 {
            let p = base + offset
            guard p >= base, p + 4 <= bytes.count else { throw ParseError() }
            return UInt32(bytes[p]) << 24 | UInt32(bytes[p + 1]) << 16 | UInt32(bytes[p + 2]) << 8 | UInt32(bytes[p + 3])
        }

        func slice(_ offset: Int, _ count: Int) throws -> [UInt8] {
            let p = base + offset
            guard count >= 0, p >= base, p + count <= bytes.count else { throw ParseError() }
            return Array(bytes[p..<(p + count)])
        }

        func fourCC(_ offset: Int) throws -> String {
            String(decoding: try slice(offset, 4), as: UTF8.self)
        }

        func block(_ index: Int) throws -> Int {
            guard blockAddresses.indices.contains(index) else { throw ParseError() }
            return Int(blockAddresses[index] & ~0x1f)
        }

        mutating func parse() throws -> [Record] {
            guard bytes.count > 36, try fourCC(0) == "Bud1" else { throw ParseError() }
            let rootOffset = Int(try u32(4))
            var p = rootOffset
            let count = Int(try u32(p))
            guard count < 1_000_000 else { throw ParseError() }
            p += 8
            for i in 0..<count {
                blockAddresses.append(try u32(p + 4 * i))
            }
            p += 4 * ((count + 255) / 256 * 256)

            let directoryCount = Int(try u32(p))
            p += 4
            var dsdb: Int?
            for _ in 0..<directoryCount {
                let length = Int(try slice(p, 1)[0])
                let name = String(decoding: try slice(p + 1, length), as: UTF8.self)
                let blockNumber = Int(try u32(p + 1 + length))
                p += 1 + length + 4
                if name == "DSDB" { dsdb = blockNumber }
            }
            guard let dsdb else { throw ParseError() }
            let header = try block(dsdb)
            try node(Int(try u32(header)))
            return records
        }

        mutating func node(_ index: Int) throws {
            guard visitedNodes.insert(index).inserted else { throw ParseError() }
            var p = try block(index)
            let rightmost = Int(try u32(p))
            let count = Int(try u32(p + 4))
            p += 8
            for _ in 0..<count {
                if rightmost != 0 {
                    try node(Int(try u32(p)))
                    p += 4
                }
                p = try record(at: p)
            }
            if rightmost != 0 { try node(rightmost) }
        }

        mutating func record(at start: Int) throws -> Int {
            var p = start
            let nameLength = Int(try u32(p))
            p += 4
            let filename = utf16(try slice(p, nameLength * 2))
            p += nameLength * 2
            let code = try fourCC(p)
            let type = try fourCC(p + 4)
            p += 8

            let value: Value
            switch type {
            case "long", "shor":
                value = .long(try u32(p)); p += 4
            case "bool":
                value = .bool(try slice(p, 1)[0] != 0); p += 1
            case "type":
                value = .type(try fourCC(p)); p += 4
            case "blob":
                let length = Int(try u32(p))
                value = .blob(Data(try slice(p + 4, length))); p += 4 + length
            case "ustr":
                let length = Int(try u32(p))
                value = .string(utf16(try slice(p + 4, length * 2))); p += 4 + length * 2
            case "comp", "dutc":
                value = .wide(UInt64(try u32(p)) << 32 | UInt64(try u32(p + 4))); p += 8
            default:
                throw ParseError()
            }
            records.append(Record(filename: filename, code: code, value: value))
            return p
        }

        func utf16(_ raw: [UInt8]) -> String {
            var units: [UInt16] = []
            units.reserveCapacity(raw.count / 2)
            var i = 0
            while i + 1 < raw.count {
                units.append(UInt16(raw[i]) << 8 | UInt16(raw[i + 1]))
                i += 2
            }
            return String(decoding: units, as: UTF16.self)
        }
    }
}
