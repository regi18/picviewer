import AVFoundation
import CoreMedia
import Foundation

extension ImageInfo {
    /// What a film says about itself: its size the way it plays (turned by its track matrix), length, frame rate and
    /// codec, and the camera, date and place cameras and phones write into QuickTime metadata.
    public static func video(at url: URL) async throws -> ImageInfo {
        let asset = AVURLAsset(url: url)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey])
        var info = ImageInfo(properties: [:], url: url, fileSize: values?.fileSize, modified: values?.contentModificationDate,
                             created: values?.creationDate, format: values?.localizedTypeDescription)
        info.isVideo = true

        let (duration, metadata) = try await asset.load(.duration, .metadata)
        if duration.isNumeric, duration.seconds > 0 { info.duration = duration.seconds }

        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (size, transform, rate, formats) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
            let turned = CGRect(origin: .zero, size: size).applying(transform)
            info.pixelSize = CGSize(width: abs(turned.width).rounded(), height: abs(turned.height).rounded())
            info.videoRotation = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
            if rate > 0 { info.frameRate = Double(rate) }
            info.codec = formats.first.map { codecName(CMFormatDescriptionGetMediaSubType($0)) }
        }

        func string(_ identifiers: [AVMetadataIdentifier]) async -> String? {
            for identifier in identifiers {
                if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first,
                   let value = try? await item.load(.stringValue), !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    return value
                }
            }
            return nil
        }

        info.camera = joined(await string([.quickTimeMetadataMake, .quickTimeUserDataMake, .commonIdentifierMake]),
                             await string([.quickTimeMetadataModel, .quickTimeUserDataModel, .commonIdentifierModel]))
        info.software = await string([.quickTimeMetadataSoftware, .quickTimeUserDataSoftware, .commonIdentifierSoftware])
        info.title = await string([.quickTimeMetadataTitle, .commonIdentifierTitle])

        if let text = await string([.quickTimeMetadataCreationDate, .quickTimeUserDataCreationDate, .commonIdentifierCreationDate]) {
            info.takenAt = wallClockDate(text)
        }
        if info.takenAt == nil, let item = try? await asset.load(.creationDate) {
            // The movie header's own date, which cameras without a time zone setting write in their local time.
            info.takenAt = try? await item.load(.dateValue)
        }

        if let text = await string([.quickTimeMetadataLocationISO6709, .quickTimeUserDataLocationISO6709, .commonIdentifierLocation]),
           let location = iso6709(text) {
            info.latitude = location.latitude
            info.longitude = location.longitude
            info.altitude = location.altitude
        }
        return info
    }

    /// 7.4 -> "0:07", 83 -> "1:23", 3723 -> "1:02:03".
    public var durationLabel: String? {
        guard let duration else { return nil }
        let whole = Int(duration.rounded())
        let (hours, minutes, seconds) = (whole / 3600, whole / 60 % 60, whole % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }

    /// 0 -> "Normal", 90 -> "Rotated 90° CW", 180 -> "Rotated 180°", -90 -> "Rotated 90° CCW".
    public var videoRotationLabel: String? {
        guard let videoRotation else { return nil }
        switch (videoRotation % 360 + 360) % 360 {
        case 0: return "Normal"
        case 90: return "Rotated 90° CW"
        case 180: return "Rotated 180°"
        case 270: return "Rotated 90° CCW"
        default: return "Rotated \(videoRotation)°"
        }
    }

    /// 29.97 -> "29.97 fps", 30 -> "30 fps".
    public var frameRateLabel: String? {
        frameRate.map { "\($0.formatted(FloatingPointFormatStyle<Double>(locale: Locale(identifier: "en_US_POSIX")).precision(.fractionLength(0...2)))) fps" }
    }

    static func codecName(_ code: FourCharCode) -> String {
        let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "?"
        switch fourCC {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "jpeg", "mjpa", "mjpb", "dmb1": return "Motion JPEG"
        case "ap4h", "ap4x": return "ProRes 4444"
        case "apch": return "ProRes 422 HQ"
        case "apcn": return "ProRes 422"
        case "apcs": return "ProRes 422 LT"
        case "apco": return "ProRes 422 Proxy"
        case "aprn", "aprh": return "ProRes RAW"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case "mp4v": return "MPEG-4"
        default: return fourCC.trimmingCharacters(in: .whitespaces)
        }
    }

    /// "2001-02-03T04:05:06+0100" -> 04:05:06 read in UTC, so a film's time prints the way its camera's clock read,
    /// like a picture's EXIF time does.
    static func wallClockDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy:MM:dd HH:mm:ss"] {
            formatter.dateFormat = format
            if text.count >= 19, let date = formatter.date(from: String(text.prefix(19))) { return date }
        }
        return nil
    }

    /// "+37.3349-122.0090+010.000/" -> 37.3349, -122.009, 10.
    static func iso6709(_ text: String) -> (latitude: Double, longitude: Double, altitude: Double?)? {
        let numbers = text.matches(of: #/[+-]\d+(?:\.\d+)?/#).compactMap { Double($0.output) }
        guard numbers.count >= 2, abs(numbers[0]) <= 90, abs(numbers[1]) <= 180 else { return nil }
        return (numbers[0], numbers[1], numbers.count >= 3 ? numbers[2] : nil)
    }
}
