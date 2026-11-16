import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Everything the info panel shows about one picture. Fields are nil when the file does not carry them.
public struct ImageInfo: Sendable, Equatable {
    public var fileName: String
    public var folderPath: String
    public var pixelSize: CGSize
    public var fileSize: Int?
    public var format: String?
    public var modified: Date?
    public var created: Date?

    // When the shutter fired, as the camera's clock read it. EXIF usually stores no time zone, so this is read and
    // shown in UTC, which prints the camera's own wall-clock time unchanged wherever the Mac is.
    public var takenAt: Date?
    public var camera: String?
    public var lens: String?
    public var software: String?

    public var focalLength: String?
    public var aperture: String?
    public var shutter: String?
    public var iso: String?
    public var exposureBias: String?
    public var program: String?
    public var metering: String?
    public var flash: String?
    public var whiteBalance: String?

    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?
    public var direction: Double?
    public var place: String?

    public var colorProfile: String?
    public var bitDepth: Int?
    public var orientation: Int
    public var title: String?
    public var artist: String?
    public var copyright: String?

    public init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw RotationError.unreadable }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey])
        self.init(properties: properties, url: url, fileSize: values?.fileSize, modified: values?.contentModificationDate,
                  created: values?.creationDate, format: values?.localizedTypeDescription)
    }

    public init(properties: [CFString: Any], url: URL, fileSize: Int? = nil, modified: Date? = nil, created: Date? = nil, format: String? = nil) {
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let exifAux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        fileName = url.lastPathComponent
        folderPath = url.deletingLastPathComponent().path
        self.fileSize = fileSize
        self.modified = modified
        self.created = created
        self.format = format

        orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let width = properties[kCGImagePropertyPixelWidth] as? Double ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Double ?? 0
        // EXIF orientations 5 to 8 turn the picture a quarter turn, so a portrait shot reads as taller than wide.
        pixelSize = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        colorProfile = properties[kCGImagePropertyProfileName] as? String
        bitDepth = properties[kCGImagePropertyDepth] as? Int

        takenAt = Self.exifDate(exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff[kCGImagePropertyTIFFDateTime] as? String)
        camera = Self.joined(tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String)
        let lensModel = (exif[kCGImagePropertyExifLensModel] as? String) ?? (exifAux[kCGImagePropertyExifAuxLensModel] as? String)
        lens = Self.clean(lensModel)
        software = Self.clean(tiff[kCGImagePropertyTIFFSoftware] as? String)

        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double, focal > 0 {
            var text = "\(focal.formatted(.number.precision(.fractionLength(0...1))))mm"
            if let equivalent = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int, equivalent > 0, abs(Double(equivalent) - focal) >= 1 {
                text += "  (\(equivalent)mm equiv.)"
            }
            focalLength = text
        }
        if let number = exif[kCGImagePropertyExifFNumber] as? Double, number > 0 {
            aperture = "ƒ/\(number.formatted(.number.precision(.fractionLength(0...1))))"
        }
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            shutter = Self.shutterLabel(time)
        }
        if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let value = isos.first {
            iso = "ISO \(value)"
        }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double {
            exposureBias = Self.exposureBiasLabel(bias)
        }
        program = (exif[kCGImagePropertyExifExposureProgram] as? Int).flatMap(Self.programs.lookup)
        metering = (exif[kCGImagePropertyExifMeteringMode] as? Int).flatMap(Self.meteringModes.lookup)
        if let value = exif[kCGImagePropertyExifFlash] as? Int {
            flash = value & 1 == 1 ? "Fired" : "Did not fire"
        }
        if let value = exif[kCGImagePropertyExifWhiteBalance] as? Int {
            whiteBalance = value == 0 ? "Auto" : "Manual"
        }

        latitude = Self.coordinate(gps[kCGImagePropertyGPSLatitude], reference: gps[kCGImagePropertyGPSLatitudeRef], negative: "S")
        longitude = Self.coordinate(gps[kCGImagePropertyGPSLongitude], reference: gps[kCGImagePropertyGPSLongitudeRef], negative: "W")
        if let value = gps[kCGImagePropertyGPSAltitude] as? Double {
            altitude = (gps[kCGImagePropertyGPSAltitudeRef] as? Int) == 1 ? -value : value
        }
        direction = gps[kCGImagePropertyGPSImgDirection] as? Double
        let names = [kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCCity, kCGImagePropertyIPTCProvinceState, kCGImagePropertyIPTCCountryPrimaryLocationName]
            .compactMap { Self.clean(iptc[$0] as? String) }
        place = names.isEmpty ? nil : names.joined(separator: ", ")

        title = Self.clean(iptc[kCGImagePropertyIPTCObjectName] as? String) ?? Self.clean(tiff[kCGImagePropertyTIFFImageDescription] as? String)
        artist = Self.clean(tiff[kCGImagePropertyTIFFArtist] as? String) ?? (iptc[kCGImagePropertyIPTCByline] as? [String])?.first
        copyright = Self.clean(tiff[kCGImagePropertyTIFFCopyright] as? String) ?? Self.clean(iptc[kCGImagePropertyIPTCCopyrightNotice] as? String)
    }

    // MARK: Labels

    public var megapixels: Double { pixelSize.width * pixelSize.height / 1_000_000 }

    /// "35mm  ·  ƒ/11  ·  1/220s  ·  ISO 640". The exposure bias has its own row. Each value is held together with
    /// no-break spaces, so on a narrow sidebar the line can only wrap between values ("ISO 640" never splits).
    public var exposureLine: String? {
        let focal = focalLength.map { $0.components(separatedBy: "  (").first ?? $0 }
        let parts = [focal, aperture, shutter, iso].compactMap { $0?.replacingOccurrences(of: " ", with: "\u{00A0}") }
        return parts.isEmpty ? nil : parts.joined(separator: "\u{00A0}\u{00A0}·  ")
    }

    /// 6000 × 4000 -> "3:2", 4000 × 6000 -> "2:3", anything else -> "2.33:1".
    public var ratioLabel: String {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return "–" }
        let ratio = pixelSize.width / pixelSize.height
        let isPortrait = ratio < 1
        let wide = isPortrait ? 1 / ratio : ratio
        let named: [(Double, Double)] = [(1, 1), (5, 4), (4, 3), (7, 5), (3, 2), (16, 10), (5, 3), (16, 9), (2, 1), (21, 9), (65, 24), (3, 1)]
        if let match = named.first(where: { abs($0.0 / $0.1 - wide) / wide < 0.01 }) {
            let (a, b) = (Int(match.0), Int(match.1))
            return isPortrait ? "\(b):\(a)" : "\(a):\(b)"
        }
        let decimal = wide.formatted(FloatingPointFormatStyle<Double>(locale: Locale(identifier: "en_US_POSIX")).precision(.fractionLength(0...2)))
        return isPortrait ? "1:\(decimal)" : "\(decimal):1"
    }

    /// "Saturday, 14 November 2026 at 12:20", the camera's wall-clock time, in the user's own date format.
    public var takenLabel: String? {
        guard let takenAt else { return nil }
        var style = Date.FormatStyle(date: .complete, time: .shortened)
        style.timeZone = .gmt
        return takenAt.formatted(style)
    }

    public var orientationLabel: String {
        ["Normal", "Mirrored", "Rotated 180°", "Mirrored vertically", "Mirrored, rotated 90° CCW", "Rotated 90° CW",
         "Mirrored, rotated 90° CW", "Rotated 90° CCW"][max(0, min(7, orientation - 1))]
    }

    /// 46.3625, 14.0936 -> "46.3625° N, 14.0936° E".
    public static func coordinateLabel(latitude: Double, longitude: Double) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(5))
        return "\(abs(latitude).formatted(format))° \(latitude < 0 ? "S" : "N"), \(abs(longitude).formatted(format))° \(longitude < 0 ? "W" : "E")"
    }

    /// 0.004 -> "1/250s", 2.5 -> "2.5s".
    static func shutterLabel(_ seconds: Double) -> String {
        if seconds >= 0.3 {
            return "\(seconds.formatted(.number.precision(.fractionLength(0...1))))s"
        }
        return "1/\(Int((1 / seconds).rounded()))s"
    }

    /// 0.67 -> "+⅔ EV", -1.33 -> "−1⅓ EV", 2 -> "+2 EV", 0 -> "0 EV". Cameras step in thirds or halves and store them
    /// rounded, so near enough to one reads as the fraction the camera showed.
    static func exposureBiasLabel(_ ev: Double) -> String {
        let magnitude = abs(ev)
        guard magnitude >= 0.05 else { return "0 EV" }
        let sign = ev > 0 ? "+" : "−"
        let whole = Int(magnitude)
        let fraction = magnitude - Double(whole)
        let steps: [(value: Double, glyph: String)] = [(0, ""), (1.0 / 3, "⅓"), (0.5, "½"), (2.0 / 3, "⅔"), (1, "")]
        if let step = steps.first(where: { abs(fraction - $0.value) < 0.04 }) {
            let wholePart = whole + (step.value == 1 ? 1 : 0)
            let number = wholePart == 0 ? step.glyph : "\(wholePart)\(step.glyph)"
            return "\(sign)\(number) EV"
        }
        return "\(sign)\(magnitude.formatted(.number.precision(.fractionLength(0...1)))) EV"
    }

    private static let programs = [1: "Manual", 2: "Program", 3: "Aperture priority", 4: "Shutter priority", 5: "Creative", 6: "Action", 7: "Portrait", 8: "Landscape"]
    private static let meteringModes = [1: "Average", 2: "Center-weighted", 3: "Spot", 4: "Multi-spot", 5: "Multi-segment", 6: "Partial"]

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// "Canon" and "Canon EOS R5" -> "Canon EOS R5", since most cameras repeat the make in the model.
    /// "NIKON CORPORATION" and "NIKON D750" -> "NIKON D750"; "OLYMPUS IMAGING CORP." and "E-M1" -> "OLYMPUS E-M1".
    static func joined(_ make: String?, _ model: String?) -> String? {
        let corporate: Set<String> = ["corporation", "corp", "corp.", "imaging", "company", "co.", "co.,", "ltd", "ltd.",
                                      "inc", "inc.", "optical", "electronics", "electric"]
        let make = (clean(make) ?? "").split(separator: " ")
            .filter { !corporate.contains($0.lowercased()) }.joined(separator: " ")
        let model = clean(model) ?? ""
        if model.isEmpty { return make.isEmpty ? nil : make }
        if make.isEmpty || model.lowercased().hasPrefix(make.lowercased()) { return model }
        return "\(make) \(model)"
    }

    /// "2024:09:14 18:42:07" -> that moment, read in UTC.
    private static func exifDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    private static func coordinate(_ value: Any?, reference: Any?, negative: String) -> Double? {
        guard let value = value as? Double else { return nil }
        return (reference as? String) == negative ? -value : value
    }
}

private extension Dictionary where Key == Int, Value == String {
    func lookup(_ key: Int) -> String? { self[key] }
}
