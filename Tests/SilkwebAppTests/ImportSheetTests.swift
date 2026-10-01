import AppKit
import SwiftUI
import XCTest
import SilkwebCore
@testable import Silkweb

final class ImportSheetTests: XCTestCase {
    @MainActor
    func testReviewCopySelectionAndOffscreenSheets() async throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("Library")
        let source = base.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Parent/Target"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("hello".utf8).write(to: source.appendingPathComponent("one.md"))
        let workspace = LibraryWorkspace()
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        workspace.session.selectedFolder = "Parent/Target"
        let request = ImportRequest(source: source, destination: workspace.targetFolder)
        workspace.importRequest = request
        let review = ImportReview()
        review.review(request, root: root, destination: request.destination)
        for _ in 0..<500 {
            if review.plan != nil || review.message != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(review.message)
        XCTAssertEqual(review.plan?.documentCount, 1)
        let sheet = NSHostingView(rootView: ImportSheet(workspace: workspace, request: request))
        let picker = NSHostingView(rootView: MovePicker(workspace: workspace, request: MoveRequest(paths: []), importChoice: { _ in }))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 4096, height: 2160))
        host.addSubview(sheet); host.addSubview(picker)
        for width: CGFloat in [0, 1, 440, 540, 4096] {
            for height: CGFloat in [0, 1, 480, 560, 2160] {
                sheet.setFrameSize(NSSize(width: width, height: height)); sheet.layoutSubtreeIfNeeded()
                picker.setFrameSize(NSSize(width: width, height: height)); picker.layoutSubtreeIfNeeded()
            }
        }
        review.start(workspace)
        for _ in 0..<500 {
            if !workspace.mutating { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(review.message)
        XCTAssertFalse(workspace.mutating)
        XCTAssertNil(workspace.importRequest)
        XCTAssertEqual(workspace.session.selectedFolder, "Parent/Target/Notes")
        XCTAssertTrue(workspace.session.expandedFolders.contains("Parent"))
        XCTAssertTrue(workspace.session.expandedFolders.contains("Parent/Target"))
        XCTAssertTrue(workspace.session.expandedFolders.contains(""))
        XCTAssertEqual(workspace.documents.map(\.relativePath), ["Parent/Target/Notes/one.md"])
    }
    @MainActor
    func testEmptyReviewAndExternalLibraryContainmentErrors() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("Library")
        let source = base.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let review = ImportReview()
        for url in [source, root, base] {
            review.review(ImportRequest(source: url, destination: ""), root: root, destination: "")
            for _ in 0..<500 {
                if review.plan != nil || review.message != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            if url == source { XCTAssertEqual(review.plan?.documentCount, 0); XCTAssertNil(review.message) }
            else { XCTAssertNotNil(review.message); XCTAssertNil(review.plan) }
        }
    }
}
