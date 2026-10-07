import XCTest

@testable import SilkwebCore

final class CountPresentationTests: XCTestCase {
    func testEveryUnitAndCountBoundary() {
        XCTAssertEqual(CountPresentation.label(1, unit: .document), "1 document")
        XCTAssertEqual(CountPresentation.label(0, unit: .document), "0 documents")
        XCTAssertEqual(CountPresentation.label(2, unit: .document), "2 documents")
        XCTAssertEqual(CountPresentation.label(1, unit: .heading), "1 heading")
        XCTAssertEqual(CountPresentation.label(2, unit: .heading), "2 headings")
        XCTAssertEqual(CountPresentation.label(1, unit: .item), "1 item")
        XCTAssertEqual(CountPresentation.label(3, unit: .item), "3 items")
        XCTAssertEqual(CountPresentation.label(1, unit: .folder), "1 folder")
        XCTAssertEqual(CountPresentation.label(1, unit: .tag), "1 tag")
        XCTAssertEqual(CountPresentation.label(0, unit: .tag), "0 tags")
        XCTAssertEqual(CountPresentation.label(1, unit: .attachment), "1 attachment")
        XCTAssertEqual(CountPresentation.label(2, unit: .attachment), "2 attachments")
        for unit in CountPresentation.Unit.allCases {
            for count in [0, 1, 2, 999, 1_204, 10_000, Int.max] {
                XCTAssertEqual(
                    CountPresentation.label(count, unit: unit),
                    count.formatted() + " " + unit.rawValue + (count == 1 ? "" : "s"))
            }
        }
    }

    func testSidebarVisibleAndSpokenCountsAgree() {
        for direct in [0, 1, 2, 1_204, Int.max] {
            for recursive in [direct, Int.max] {
                let count = FolderDocumentCount(direct: direct, recursive: recursive)
                XCTAssertEqual(
                    count.tooltip,
                    CountPresentation.label(direct, unit: .document) + " · " + recursive.formatted()
                        + " including subfolders")
                XCTAssertEqual(
                    count.accessibilityValue,
                    CountPresentation.label(direct, unit: .document) + ", " + recursive.formatted()
                        + " including subfolders")
            }
        }
    }

    /// #111: the Import Folder Copy review joins only the non-zero parts, each in the right number.
    func testImportSummaryPluralsAndOmitsZeroParts() {
        func sentence(_ parts: [String], _ name: String = "X") -> String {
            (ListFormatter.localizedString(byJoining: parts)) + " will be copied into a new folder “\(name)”."
        }
        XCTAssertEqual(
            ImportPlan.summary(documents: 12, attachments: 1, folders: 4, emptyFolders: 1, folderName: "X"),
            sentence(["12 documents", "1 attachment", "4 folders (1 empty)"]))
        XCTAssertEqual(
            ImportPlan.summary(documents: 1, attachments: 0, folders: 1, emptyFolders: 0, folderName: "X"),
            sentence(["1 document", "1 folder"]))
        XCTAssertEqual(
            ImportPlan.summary(documents: 1, attachments: 0, folders: 0, emptyFolders: 0, folderName: "Notes"),
            "1 document will be copied into a new folder “Notes”.")
        XCTAssertEqual(
            ImportPlan.summary(documents: 2, attachments: 3, folders: 0, emptyFolders: 0, folderName: "X"),
            sentence(["2 documents", "3 attachments"]))
    }
}
