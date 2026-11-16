import CoreGraphics
import XCTest
@testable import PicViewerCore

final class OrderTests: XCTestCase {
    private func entry(_ name: String, modified: TimeInterval = 0, size: Int = 0) -> FolderEntry {
        FolderEntry(url: URL(fileURLWithPath: "/tmp/\(name)"), modified: Date(timeIntervalSince1970: modified), size: size, kind: "JPEG image")
    }

    func testNamesSortLikeFinder() {
        let entries = ["IMG_10.jpg", "img_2.jpg", "IMG_1.jpg", "a.jpg"].map { entry($0) }
        let sorted = FolderScanner.sort(entries, by: .byName).map(\.name)
        XCTAssertEqual(sorted, ["a.jpg", "IMG_1.jpg", "img_2.jpg", "IMG_10.jpg"])
        let reversed = FolderScanner.sort(entries, by: .sorted(.name, ascending: false)).map(\.name)
        XCTAssertEqual(reversed, ["IMG_10.jpg", "img_2.jpg", "IMG_1.jpg", "a.jpg"])
    }

    func testDatesNewestFirstWithNameTieBreak() {
        let entries = [entry("b.jpg", modified: 10), entry("a.jpg", modified: 10), entry("c.jpg", modified: 30), entry("d.jpg", modified: 5)]
        let sorted = FolderScanner.sort(entries, by: .sorted(.dateModified, ascending: false)).map(\.name)
        XCTAssertEqual(sorted, ["c.jpg", "a.jpg", "b.jpg", "d.jpg"])
        let oldest = FolderScanner.sort(entries, by: .sorted(.dateModified, ascending: true)).map(\.name)
        XCTAssertEqual(oldest, ["d.jpg", "a.jpg", "b.jpg", "c.jpg"])
    }

    func testIconPositionsReadRowByRow() {
        let entries = ["a", "b", "c", "d", "e"].map { entry("\($0).jpg") }
        let positions: [String: CGPoint] = [
            "a.jpg": CGPoint(x: 300, y: 50), "b.jpg": CGPoint(x: 100, y: 52),
            "c.jpg": CGPoint(x: 200, y: 160), "d.jpg": CGPoint(x: 100, y: 170),
        ]
        let sorted = FolderScanner.sort(entries, by: .iconPositions(positions)).map(\.name)
        XCTAssertEqual(sorted, ["b.jpg", "a.jpg", "d.jpg", "c.jpg", "e.jpg"])
    }

    func testLiveAnswers() {
        if case .order(let order) = FinderLiveQuery.listAnswer(column: "elsm", direction: "snrm") {
            XCTAssertEqual(order, .sorted(.dateModified, ascending: false))
        } else { XCTFail() }
        if case .order(let order) = FinderLiveQuery.listAnswer(column: "elsn", direction: "srvs") {
            XCTAssertEqual(order, .sorted(.name, ascending: false))
        } else { XCTFail() }
        if case .order(let order) = FinderLiveQuery.iconAnswer(arrangement: "siza") {
            XCTAssertEqual(order, .sorted(.size, ascending: false))
        } else { XCTFail() }
        if case .order(.iconPositions(let positions)) = FinderLiveQuery.positionsAnswer(
            names: ["my file.jpg", "b.jpg", "c.jpg"], points: [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 20), nil]) {
            XCTAssertEqual(positions["my file.jpg"], CGPoint(x: 10, y: 20))
            XCTAssertEqual(positions.count, 2)
        } else { XCTFail() }
        if case .style(.list) = FinderLiveQuery.listAnswer(column: "zzzz", direction: "snrm") {} else { XCTFail() }
        if case .style(.icon) = FinderLiveQuery.iconAnswer(arrangement: "narr") {} else { XCTFail() }
    }

    func testAppleEventPieces() {
        XCTAssertEqual(FinderScripting.code("brow"), 0x62726F77)
        XCTAssertEqual(FinderScripting.code("elsC").fourCharacterString, "elsC")
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(int32: 12), at: 0)
        list.insert(NSAppleEventDescriptor(int32: -40), at: 0)
        XCTAssertEqual(FinderScripting.point(list), CGPoint(x: 12, y: -40))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("some folder \(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Finder answers with the real path (/private/var/…) and a trailing slash.
        let real = URL(fileURLWithPath: realpath(folder.path, nil).map { String(cString: $0) } ?? folder.path, isDirectory: true)
        XCTAssertEqual(FinderScripting.normalized(real.absoluteString), FinderScripting.normalized(folder))
        let window = FinderScripting.element("brow", index: 2, of: .null())
        let target = FinderScripting.property("fvtg", of: window)
        XCTAssertEqual(target.descriptorType, FinderScripting.code("obj "))
        XCTAssertEqual(target.forKeyword(FinderScripting.code("seld"))?.typeCodeValue, FinderScripting.code("fvtg"))
        XCTAssertEqual(target.forKeyword(FinderScripting.code("from"))?.forKeyword(FinderScripting.code("seld"))?.int32Value, 2)
    }

    func testStoredListSettings() {
        let old: [String: Any] = ["sortColumn": "dateAdded", "columns": ["dateAdded": ["ascending": true]]]
        XCTAssertEqual(FinderOrderResolver.listOrder(old), .sorted(.dateAdded, ascending: true))
        let new: [String: Any] = ["sortColumn": "size", "columns": [["identifier": "size", "ascending": false]]]
        XCTAssertEqual(FinderOrderResolver.listOrder(new), .sorted(.size, ascending: false))
        XCTAssertEqual(FinderOrderResolver.arrangedOrder(["arrangeBy": "dateLastOpened"]), .sorted(.dateLastOpened, ascending: false))
        XCTAssertNil(FinderOrderResolver.arrangedOrder(["arrangeBy": "none"]))
    }
}
