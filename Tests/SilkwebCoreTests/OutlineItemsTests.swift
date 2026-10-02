import XCTest
@testable import SilkwebCore

final class OutlineItemsTests: XCTestCase {
    func testOrderNestingReferencesAndCodeExclusions() {
        let text = """
        ![Before](first.png)
        # Title
        ## Child
        ![**Portrait**][photo]
        ### Detail
        ![Transparent](media/doc/transparent.png)
        ## End
        ![Missing](.silkweb-assets/missing.png)
        ![Remote](https://example.invalid/a.png)
        ![Outside](../outside.png)
        `![Code](code.png)` and \\![Escaped](escaped.png)
            ![Indented](indent.png)
        ~~~
        ![Fenced](fence.png)
        [photo]: wrong.png
        ~~~
        [photo]: portrait.png
        """
        let items = OutlineItem.parse(text)
        XCTAssertEqual(items.map(\.label), ["Before", "Title", "Child", "Portrait", "Detail", "Transparent", "End", "Missing", "Remote", "Outside"])
        XCTAssertEqual(items.map { $0.indent(shallowest: 1) }, [0, 0, 0, 24, 0, 36, 0, 24, 24, 24])
        XCTAssertEqual(items.map(\.sourceRange.location), items.map(\.sourceRange.location).sorted())
        let root = URL(fileURLWithPath: "/tmp/outline-root")
        let document = root.appendingPathComponent("note.md")
        let references = items.compactMap { item -> InlineImages.Reference? in
            if case .image(let reference) = item.content { return reference }; return nil
        }
        XCTAssertEqual(references.map { InlineImages.resource($0, document: document, root: root) }, [
            .local(root.appendingPathComponent("first.png")), .local(root.appendingPathComponent("portrait.png")),
            .local(root.appendingPathComponent("media/doc/transparent.png")), .local(root.appendingPathComponent(".silkweb-assets/missing.png")), .remote, .outsideLibrary])
    }

    func testReferenceFormsLabelsUnicodeAndCounts() {
        let source = "😀\r\n![Full][ID]\r\n![collapsed][]\n![shortcut]\n![](a%20b.png)\n![](https://example.invalid)\n[ID]: full.png\n[collapsed]: c.png\n[shortcut]: s.png\n"
        let items = OutlineItem.parse(source)
        XCTAssertEqual(items.map(\.label), ["Full", "collapsed", "shortcut", "a b.png", "example.invalid"])
        XCTAssertEqual(items.first?.sourceRange.location, 4)
        XCTAssertEqual(CountPresentation.label(1, unit: .image), "1 image")
        XCTAssertEqual(CountPresentation.label(2, unit: .image), "2 images")
        let collision = OutlineItem.parse("# Outline Image 0\n![x](a.png)")
        XCTAssertEqual(Set(collision.map(\.id)).count, 2)
        XCTAssertTrue(OutlineItem.parse("").isEmpty)
        XCTAssertTrue(OutlineItem.parse("```\n![x](a.png)\n```").isEmpty)
        for count in [1, 2, 200] {
            let images = OutlineItem.parse("###### Deep\n" + Array(repeating: "![x](a.png)\n", count: count).joined())
            XCTAssertEqual(images.count, count + 1)
            XCTAssertEqual(images.last?.indent(shallowest: 1), 72)
            XCTAssertEqual(Set(images.map(\.id)).count, count + 1)
        }
    }
}
