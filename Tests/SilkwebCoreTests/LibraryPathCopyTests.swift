import Foundation
import XCTest

@testable import SilkwebCore

final class LibraryPathCopyTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Users/me/Notes", isDirectory: true)

    func testAbsoluteJoinsWithoutTrailingSlash() {
        XCTAssertEqual(LibraryPathCopy.absolute(root: root, path: ""), "/Users/me/Notes")
        XCTAssertEqual(LibraryPathCopy.absolute(root: root, path: "Blog"), "/Users/me/Notes/Blog")
        XCTAssertEqual(
            LibraryPathCopy.absolute(root: root, path: "Blog/Drafts/Hello World.md"),
            "/Users/me/Notes/Blog/Drafts/Hello World.md")
    }

    func testAbsoluteStandardizesTheRoot() {
        let messy = URL(fileURLWithPath: "/Users/me/./Other/../Notes/", isDirectory: true)
        XCTAssertEqual(LibraryPathCopy.absolute(root: messy, path: "a.md"), "/Users/me/Notes/a.md")
        XCTAssertEqual(LibraryPathCopy.absolute(root: URL(fileURLWithPath: "/"), path: "a.md"), "/a.md")
        XCTAssertEqual(LibraryPathCopy.absolute(root: URL(fileURLWithPath: "/"), path: ""), "/")
    }

    func testStringIsOnePathPerLineInOrder() {
        let paths = ["b.md", "Folder/a.md", "Folder"]
        XCTAssertEqual(
            LibraryPathCopy.string(root: root, paths: paths, relative: false),
            "/Users/me/Notes/b.md\n/Users/me/Notes/Folder/a.md\n/Users/me/Notes/Folder")
        XCTAssertEqual(LibraryPathCopy.string(root: root, paths: paths, relative: true), "b.md\nFolder/a.md\nFolder")
    }

    func testStringSingleAndEmptyAndDuplicates() {
        XCTAssertEqual(LibraryPathCopy.string(root: root, paths: ["a.md"], relative: false), "/Users/me/Notes/a.md")
        XCTAssertEqual(LibraryPathCopy.string(root: root, paths: [""], relative: false), "/Users/me/Notes")
        XCTAssertEqual(LibraryPathCopy.string(root: root, paths: [], relative: false), "")
        XCTAssertEqual(
            LibraryPathCopy.string(root: root, paths: ["a.md", "b.md", "a.md"], relative: true), "a.md\nb.md")
    }

    func testUnicodeAndSpacesAreCopiedVerbatim() {
        XCTAssertEqual(
            LibraryPathCopy.string(root: root, paths: ["Café notes/日記 1.md"], relative: false),
            "/Users/me/Notes/Café notes/日記 1.md")
    }

    func testRelativeIsNotOfferedForTheRoot() {
        XCTAssertTrue(LibraryPathCopy.canCopyRelative(["a.md", "Folder"]))
        XCTAssertFalse(LibraryPathCopy.canCopyRelative([""]))
        XCTAssertFalse(LibraryPathCopy.canCopyRelative(["a.md", ""]))
        XCTAssertFalse(LibraryPathCopy.canCopyRelative([]))
    }

    func testOrderedFollowsTheListThenSortsHiddenSelection() {
        let list = ["z.md", "a.md", "m.md", "b.md"]
        XCTAssertEqual(LibraryPathCopy.ordered(["a.md", "z.md", "b.md"], in: list), ["z.md", "a.md", "b.md"])
        XCTAssertEqual(LibraryPathCopy.ordered(["q.md", "m.md", "c.md"], in: list), ["m.md", "c.md", "q.md"])
        XCTAssertEqual(LibraryPathCopy.ordered([], in: list), [])
        XCTAssertEqual(LibraryPathCopy.ordered(["b.md", "a.md"], in: []), ["a.md", "b.md"])
    }
}
