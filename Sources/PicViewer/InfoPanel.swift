import AppKit
import CoreLocation
import MapKit
import PicViewerCore
import SwiftUI

/// The sidebar: what the picture's file says about itself. Read only.
struct InfoPanel: View {
    let model: ViewerModel

    var body: some View {
        Form {
            if let info = model.info {
                fileSection(info)
                cameraSection(info)
                if let latitude = info.latitude, let longitude = info.longitude {
                    LocationSection(info: info, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                }
                detailsSection(info)
            } else if model.current != nil {
                Section { ProgressView().controlSize(.small).frame(maxWidth: .infinity) } header: { header(nil) }
            } else {
                Section { Text("No picture open.").foregroundStyle(.secondary) } header: { header(nil) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .textSelection(.enabled)
    }

    private func header(_ section: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Info", systemImage: "info.circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            if let section { Text(section) }
        }
    }

    @ViewBuilder
    private func fileSection(_ info: ImageInfo) -> some View {
        Section {
            InfoRow("File", value: info.fileName)
            InfoRow("Size") {
                if info.isVideo {
                    Text("\(Int(info.pixelSize.width).formatted()) × \(Int(info.pixelSize.height).formatted())")
                } else {
                    Text("\(Int(info.pixelSize.width).formatted()) × \(Int(info.pixelSize.height).formatted())  ·  \(info.megapixels.formatted(.number.precision(.fractionLength(1)))) MP")
                }
            }
            InfoRow("Aspect ratio", value: info.ratioLabel)
            if let duration = info.durationLabel {
                InfoRow("Duration", value: duration)
            }
            if let fileSize = info.fileSize {
                InfoRow("File size", value: Int64(fileSize).formatted(.byteCount(style: .file)))
            }
            if let taken = info.takenLabel {
                InfoRow("Taken", value: taken)
            }
        } header: {
            header("File")
        }
    }

    @ViewBuilder
    private func cameraSection(_ info: ImageInfo) -> some View {
        let rows: [(String, String?)] = [
            ("Camera", info.camera),
            ("Lens", info.lens),
            ("Exposure", info.exposureLine),
            ("Exposure bias", info.exposureBias),
            ("Focal length", info.focalLength?.contains("equiv") == true ? info.focalLength : nil),
            ("Mode", info.program),
            ("Metering", info.metering),
            ("White balance", info.whiteBalance),
            ("Flash", info.flash),
        ]
        let present = rows.compactMap { row in row.1.map { (row.0, $0) } }
        if !present.isEmpty {
            Section("Camera") {
                ForEach(present, id: \.0) { InfoRow($0.0, value: $0.1) }
            }
        }
    }

    @ViewBuilder
    private func detailsSection(_ info: ImageInfo) -> some View {
        Section("Details") {
            if let title = info.title { InfoRow("Title", value: title) }
            if let artist = info.artist { InfoRow("Artist", value: artist) }
            if let copyright = info.copyright { InfoRow("Copyright", value: copyright) }
            if let format = info.format { InfoRow("Format", value: format) }
            if let codec = info.codec { InfoRow("Codec", value: codec) }
            if let rate = info.frameRateLabel { InfoRow("Frame rate", value: rate) }
            if let profile = info.colorProfile { InfoRow("Colour profile", value: profile) }
            if let depth = info.bitDepth { InfoRow("Bit depth", value: "\(depth) bit") }
            if !info.isVideo { InfoRow("Orientation", value: info.orientationLabel) }
            if let rotation = info.videoRotationLabel { InfoRow("Orientation", value: rotation) }
            if let software = info.software { InfoRow("Software", value: software) }
            if let modified = info.modified {
                InfoRow("Modified", value: modified.formatted(date: .abbreviated, time: .shortened))
            }
            if let created = info.created {
                InfoRow("Created", value: created.formatted(date: .abbreviated, time: .shortened))
            }
            InfoRow("Folder") {
                HStack(spacing: 6) {
                    Text(info.folderPath).lineLimit(1).truncationMode(.middle)
                    Button("Show in Finder", systemImage: "folder") { model.revealInFinder() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help("Show in Finder")
                }
            }
            if let order = model.orderLabel, let index = model.files.firstIndex(where: { $0 == model.current }) {
                InfoRow("Order") {
                    Text("\(index + 1) of \(model.files.count)  ·  \(order)")
                }
                .help("PicViewer steps through the folder in the order Finder shows it")
            }
        }
    }
}

/// Where the picture was taken: a small map, the coordinates, and the place name.
private struct LocationSection: View {
    let info: ImageInfo
    let coordinate: CLLocationCoordinate2D

    @State private var placeName: String?

    var body: some View {
        Section("Location") {
            Map(initialPosition: .camera(MapCamera(centerCoordinate: coordinate, distance: 4000))) {
                Marker("", coordinate: coordinate)
            }
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .id("\(coordinate.latitude),\(coordinate.longitude)")

            if let place = info.place ?? placeName {
                InfoRow("Place", value: place)
            }
            InfoRow("Coordinates") {
                HStack(spacing: 6) {
                    Text(ImageInfo.coordinateLabel(latitude: coordinate.latitude, longitude: coordinate.longitude))
                    Button("Show in Maps", systemImage: "map") { openInMaps() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help("Open this spot in Maps")
                }
            }
            if let altitude = info.altitude {
                InfoRow("Altitude", value: Measurement(value: altitude, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0)))))
            }
            if let direction = info.direction {
                InfoRow("Facing", value: "\(Int(direction.rounded()))°  \(Self.compass(direction))")
            }
        }
        .task(id: "\(coordinate.latitude),\(coordinate.longitude)") {
            placeName = nil
            guard info.place == nil else { return }
            placeName = await Self.placeName(for: coordinate)
        }
    }

    private func openInMaps() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = info.fileName
        item.openInMaps(launchOptions: [MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: coordinate)])
    }

    /// "Cupertino, California, United States", looked up from the coordinates.
    private static func placeName(for coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        let parts = [placemark.locality ?? placemark.name, placemark.administrativeArea, placemark.country]
            .compactMap { $0 }
        var unique: [String] = []
        for part in parts where !unique.contains(part) { unique.append(part) }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }

    private static func compass(_ degrees: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return points[Int(((degrees.truncatingRemainder(dividingBy: 360) + 360 + 22.5) / 45)) % 8]
    }
}

/// One label–value row. The label stays on one line at the left; the value sits right-aligned on the same first line
/// and wraps underneath itself if it is long, so every row lines up the same way.
struct InfoRow<Value: View>: View {
    let label: String
    let value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            value
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

extension InfoRow where Value == Text {
    init(_ label: String, value: String) {
        self.init(label) { Text(value) }
    }
}
