import AppKit
import ImageIO
import XCTest

final class AppIconTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private let representations = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
    ]

    func testBundledPlistNamesCommittedIconWithAllTenRepresentations() throws {
        // Bundle the already-built executable, so this also works after a clean test build.
        try run("/bin/sh", arguments: ["scripts/bundle_app.sh"])
        let contents = repository.appendingPathComponent("build/Silkweb.app/Contents")
        let data = try Data(contentsOf: contents.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let name = try XCTUnwrap(plist["CFBundleIconFile"] as? String)
        XCTAssertEqual(name, "Silkweb.icns")
        let icon = contents.appendingPathComponent("Resources").appendingPathComponent(name)
        XCTAssertEqual(try Data(contentsOf: icon), try Data(contentsOf: repository.appendingPathComponent("scripts/Silkweb.icns")))
        try assertRepresentations(icon)
        XCTAssertNotNil(NSImage(contentsOf: icon), "AppKit must load the application icon")
        try run("/usr/bin/codesign", arguments: ["--verify", "--strict", "build/Silkweb.app"])
    }

    func testGeneratorProducesIdenticalPNGsInEverySizeAndAppearance() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SilkwebIcon-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let first = temporary.appendingPathComponent("first")
        let second = temporary.appendingPathComponent("second")
        for root in [first, second] {
            try run("/usr/bin/swift", arguments: ["scripts/make_icon.swift", root.path])
            try assertRepresentations(root.appendingPathComponent("scripts/Silkweb.icns"))
        }
        let committed = try XCTUnwrap(CGImageSourceCreateWithURL(repository.appendingPathComponent("scripts/Silkweb.icns") as CFURL, nil))
        for (name, size) in representations {
            let relative = ".build/icon-generation/Silkweb.iconset/" + name
            let a = first.appendingPathComponent(relative)
            let b = second.appendingPathComponent(relative)
            XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b), name)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(a as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, size, name)
            XCTAssertEqual(image.height, size, name)
            let matchingIndex = try XCTUnwrap((0..<CGImageSourceGetCount(committed)).first { index in
                CGImageSourceCreateImageAtIndex(committed, index, nil)?.width == size
            })
            let committedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(committed, matchingIndex, nil))
            XCTAssertEqual(image.dataProvider?.data as Data?, committedImage.dataProvider?.data as Data?,
                "Committed icon must match the generator: " + name)
            // All sizes retain transparent margins and visible artwork.
            let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
            XCTAssertTrue(bytes.contains { $0 != 0 }, name)
            XCTAssertEqual(Array(bytes.prefix(4)), [0, 0, 0, 0], name)
        }
        for name in ["icon-preview-light.png", "icon-preview-dark.png", "icon-16.png", "icon-32.png", "icon-1024.png"] {
            let relative = ".build/icon-generation/preview/" + name
            XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent(relative)),
                try Data(contentsOf: second.appendingPathComponent(relative)), name)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(first.appendingPathComponent(relative) as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            if name.hasPrefix("icon-preview-") {
                XCTAssertEqual(image.width, 1600)
                XCTAssertEqual(image.height, 700)
            }
        }
    }

    private func assertRepresentations(_ url: URL) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 10)
        let sizes = try (0..<CGImageSourceGetCount(source)).map { index -> Int in
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            XCTAssertEqual(image.width, image.height)
            return image.width
        }
        XCTAssertEqual(sizes.sorted(), representations.map { $0.1 }.sorted())
    }

    private func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = repository
        var environment = ProcessInfo.processInfo.environment
        environment["CLANG_MODULE_CACHE_PATH"] = repository.appendingPathComponent(".build/module-cache").path
        process.environment = environment
        // Use a file rather than a pipe to avoid blocking on compiler diagnostics.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("SilkwebIconProcess-" + UUID().uuidString)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        let diagnostics = String(decoding: try Data(contentsOf: log), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, diagnostics)
    }
}
