import AppKit
import XCTest
@testable import Silkweb

final class SnapshotHarnessTests: XCTestCase {
    @MainActor
    func testRequestedScenarios() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SILKWEB_SNAPSHOT_OUTPUT"] else {
            throw XCTSkip("Run scripts/snapshot.sh to generate the QA batch")
        }
        let names = ProcessInfo.processInfo.environment["SILKWEB_SNAPSHOT_SCENARIOS"]?
            .split(separator: " ").map(String.init) ?? []
        let manifest = try await SnapshotHarness().run(output: URL(fileURLWithPath: directory), names: names)
        let failures = manifest.captures.filter { $0.status != "ok" && $0.status != "unavailable in this environment" }
        XCTAssertTrue(failures.isEmpty, failures.map { "\($0.scenario)-\($0.appearance): \($0.status) \($0.details)" }.joined(separator: "\n"))
    }

    @MainActor
    func testTwoRealScenariosProduceNonblankLightAndDarkPNGs() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("SilkwebSnapshotTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let harness = SnapshotHarness()
        let manifest = try await harness.run(output: output, names: ["library-overview", "folder-selected"])
        XCTAssertEqual(manifest.captures.count, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(harness.activationIsSafe)
        var dataByName: [String: Data] = [:]
        var meanByName: [String: Double] = [:]
        for capture in manifest.captures {
            XCTAssertEqual(capture.status, "ok", capture.details.joined(separator: ", "))
            let file = try XCTUnwrap(capture.file)
            let data = try Data(contentsOf: output.appendingPathComponent(file))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            let scale = try XCTUnwrap(capture.backingScale)
            XCTAssertEqual(bitmap.pixelsWide, Int(1400 * scale))
            XCTAssertEqual(bitmap.pixelsHigh, Int(900 * scale))
            XCTAssertEqual(capture.pixelWidth, bitmap.pixelsWide)
            XCTAssertEqual(capture.pixelHeight, bitmap.pixelsHigh)
            // Sample the full canvas, requiring actual variation rather than a flat background.
            var luminances: [Double] = []
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 11) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 11) {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    luminances.append(Double((color.redComponent + color.greenComponent + color.blueComponent) / 3))
                }
            }
            let mean = luminances.reduce(0, +) / Double(luminances.count)
            let variance = luminances.reduce(0) { $0 + pow($1 - mean, 2) } / Double(luminances.count)
            XCTAssertGreaterThan(variance, 0.0005, "Blank snapshot: \(file)")
            dataByName[file] = data
            meanByName[file] = mean
        }
        for name in ["library-overview", "folder-selected"] {
            XCTAssertNotEqual(dataByName[name + "-light.png"], dataByName[name + "-dark.png"])
            XCTAssertLessThan(try XCTUnwrap(meanByName[name + "-dark.png"]),
                              try XCTUnwrap(meanByName[name + "-light.png"]) - 0.1)
        }
    }

    @MainActor
    func testUnknownScenariosAreReportedInBothAppearances() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let manifest = try await SnapshotHarness().run(output: output, names: ["unknown"])
        XCTAssertEqual(manifest.captures.map(\.status), ["error: Unknown scenario", "error: Unknown scenario"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("manifest.json").path))
    }

    @MainActor
    func testSizeLimitsAndTimeoutReporting() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        for size in [NSSize(width: 900, height: 560), NSSize(width: 4096, height: 2160)] {
            let manifest = try await SnapshotHarness(size: size).run(output: output, names: ["library-overview"])
            for capture in manifest.captures {
                XCTAssertEqual(capture.status, "ok", capture.details.joined(separator: ", "))
                let scale = try XCTUnwrap(capture.backingScale)
                XCTAssertEqual(capture.pixelWidth, Int(size.width * scale))
                XCTAssertEqual(capture.pixelHeight, Int(size.height * scale))
            }
        }
        let manifest = try await SnapshotHarness(timeout: 0).run(output: output, names: ["library-overview"])
        XCTAssertEqual(manifest.captures.map(\.status), ["timeout", "timeout"])
        XCTAssertTrue(manifest.captures.allSatisfy { $0.details.contains("Timed out waiting for library scan") })
        for size in [NSSize.zero, NSSize(width: 899, height: 560), NSSize(width: 4097, height: 2160)] {
            do {
                _ = try await SnapshotHarness(size: size).run(output: output, names: ["library-overview"])
                XCTFail("Invalid size accepted")
            } catch { /* Input limits rejected before allocating a window. */ }
        }
        let forbidden = SnapshotHarness.repository.appendingPathComponent("Test_Library/Snapshot-" + UUID().uuidString)
        do {
            _ = try await SnapshotHarness().run(output: forbidden)
            XCTFail("Owner library accepted as output")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: forbidden.path))
    }
}
