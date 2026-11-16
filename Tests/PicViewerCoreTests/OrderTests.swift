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

    func testLiveAnswersParse() {
        if case .order(let order) = FinderLiveQuery.parse("list\tdateModified\tnormal") {
            XCTAssertEqual(order, .sorted(.dateModified, ascending: false))
        } else { XCTFail() }
        if case .order(let order) = FinderLiveQuery.parse("list\tname\treversed") {
            XCTAssertEqual(order, .sorted(.name, ascending: false))
        } else { XCTFail() }
        if case .order(let order) = FinderLiveQuery.parse("icon\tsize") {
            XCTAssertEqual(order, .sorted(.size, ascending: false))
        } else { XCTFail() }
        if case .order(.iconPositions(let positions)) = FinderLiveQuery.parse("icon\tpositions\n10\t20\tmy\tfile.jpg\n30\t20\tb.jpg") {
            XCTAssertEqual(positions["my\tfile.jpg"], CGPoint(x: 10, y: 20))
            XCTAssertEqual(positions.count, 2)
        } else { XCTFail() }
        if case .style(.list) = FinderLiveQuery.parse("list\tunknown\tnormal") {} else { XCTFail() }
        if case .style(.column) = FinderLiveQuery.parse("column") {} else { XCTFail() }
        if case .unavailable = FinderLiveQuery.parse("none") {} else { XCTFail() }
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
