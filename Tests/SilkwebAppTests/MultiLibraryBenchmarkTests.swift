import AppKit
import Darwin
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// #197 performance budget (owner, #193): three Libraries open in the real window, one of 10,000 documents in 1,000
/// folders and two small ones. Records idle CPU, memory, main-thread stalls while loading and typing, and how long
/// expanding the collapsed 10k section takes. Slow (it writes 10,000 files), so it runs only with
/// `SILKWEB_BENCH=1 ./scripts/build.sh test --filter MultiLibraryBenchmarkTests`; numbers print as `BENCH197`.
@MainActor
final class MultiLibraryBenchmarkTests: XCTestCase {
    /// Main-run-loop heartbeat: the longest gap between 5 ms ticks is the longest main-thread stall.
    private final class Heartbeat {
        private var timer: Timer?
        private var last = CFAbsoluteTimeGetCurrent()
        private(set) var longest: Double = 0

        func start() {
            last = CFAbsoluteTimeGetCurrent()
            longest = 0
            let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
                guard let self else { return }
                let now = CFAbsoluteTimeGetCurrent()
                longest = max(longest, now - last)
                last = now
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        /// The longest stall in milliseconds since `start`.
        func stop() -> Double {
            timer?.invalidate()
            timer = nil
            longest = max(longest, CFAbsoluteTimeGetCurrent() - last)
            return longest * 1000
        }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Resident and footprint memory of the test process, in MB.
    private static func memory() -> (resident: Double, footprint: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.resident_size) / 1_048_576, Double(info.phys_footprint) / 1_048_576)
    }

    /// `documents` notes spread over `folders` folders, each two levels deep under a top folder.
    private static func library(_ root: URL, documents: Int, folders: Int) throws {
        let manager = FileManager.default
        let perFolder = max(1, documents / max(1, folders))
        for folder in 0..<folders {
            let path = root.appendingPathComponent("Area \(folder / 50)/Topic \(folder)")
            try manager.createDirectory(at: path, withIntermediateDirectories: true)
            for index in 0..<perFolder {
                let number = folder * perFolder + index
                try Data(
                    "# Note \(number)\n\nSome text about topic \(folder), item \(index). Kiwi \(number % 7).\n".utf8
                ).write(to: path.appendingPathComponent("Note \(number).md"))
            }
        }
    }

    func testThreeLibrariesOneOf10kStayWithinTheBudget() async throws {
        // Or a `.build/SILKWEB_BENCH` file containing 1, for shells that can't pass the variable through.
        let marker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "../../.build/SILKWEB_BENCH")
        let marked = (try? String(contentsOf: marker.standardizedFileURL, encoding: .utf8))?.hasPrefix("1") == true
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SILKWEB_BENCH"] == "1" || marked,
            "Set SILKWEB_BENCH=1 to run the benchmark")
        _ = NSApplication.shared
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebBench-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let big = temporary.appendingPathComponent("Archive")
        let writing = temporary.appendingPathComponent("Writing")
        let journal = temporary.appendingPathComponent("Journal")
        var clock = ContinuousClock.now
        try Self.library(big, documents: 10_000, folders: 1_000)
        try Self.library(writing, documents: 60, folders: 6)
        try Self.library(journal, documents: 40, folders: 4)
        let generated = ContinuousClock.now - clock
        let baseline = Self.memory()

        // Relaunch with the 10k Library collapsed and a small one current, as the owner would use it.
        let defaults = disposableDefaults("Bench197")
        let session = AppSession(
            sections: [
                .init(location: LibraryLocation.saving(writing.standardizedFileURL.resolvingSymlinksInPath())),
                .init(
                    location: LibraryLocation.saving(big.standardizedFileURL.resolvingSymlinksInPath()), collapsed: true
                ),
                .init(location: LibraryLocation.saving(journal.standardizedFileURL.resolvingSymlinksInPath())),
            ],
            currentPath: writing.standardizedFileURL.resolvingSymlinksInPath().path)
        defaults.set(try JSONEncoder().encode(session), forKey: LibraryWindowRegistry.sessionKey)
        let registry = LibraryWindowRegistry(defaults: defaults) {
            let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: nil)
            workspace.canSaveWindowSession = false
            workspace.recoveryDirectory = temporary.appendingPathComponent(".recovery")
            return workspace
        }
        let window = KeyedTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: LibraryWindow(registry: registry))
        controller.sizingOptions = []
        let heartbeat = Heartbeat()
        heartbeat.start()
        clock = ContinuousClock.now
        window.contentViewController = controller // Never ordered on screen.
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
        defer {
            window.contentViewController = nil
            window.close()
        }
        try await waitUntil("three Libraries load", timeout: .seconds(120)) {
            registry.sections.count == 3 && registry.sections.allSatisfy { $0.snapshot != nil && !$0.loading }
        }
        let loaded = ContinuousClock.now - clock
        for workspace in registry.sections { await workspace.search.waitForIndex() }
        let indexed = ContinuousClock.now - clock
        let loadStall = heartbeat.stop()
        let archive = try XCTUnwrap(registry.sections.first { $0.root?.lastPathComponent == "Archive" })
        XCTAssertEqual(archive.snapshot?.documents.count, 10_000)
        let outline = try XCTUnwrap(
            Self.descendants(window.contentView!).compactMap { $0 as? SidebarOutlineView }.first)
        let sections = try XCTUnwrap(outline.delegate as? SidebarSections)
        let archiveHeader = try XCTUnwrap(sections.headers.first { $0.workspace === archive })
        XCTAssertNil(archiveHeader.coordinator, "the collapsed 10k section builds no folder tree")

        // Expanding the 10k section.
        heartbeat.start()
        clock = ContinuousClock.now
        outline.expandItem(archiveHeader)
        try await waitUntil("the 10k tree", timeout: .seconds(30)) { archiveHeader.coordinator != nil }
        window.contentView?.layoutSubtreeIfNeeded()
        let expanded = ContinuousClock.now - clock
        let expandStall = heartbeat.stop()

        // Typing in a document of the 10k Library.
        registry.focus(archive)
        archive.navigate(folder: "Area 0/Topic 0", documents: ["Area 0/Topic 0/Note 0.md"], pinned: true)
        await archive.waitForNavigation()
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        let editor = try XCTUnwrap(archive.preview.editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        var longestKeystroke = 0.0
        heartbeat.start()
        for index in 0..<200 {
            let start = CFAbsoluteTimeGetCurrent()
            editor.insertText(index % 20 == 19 ? "\n" : "k", replacementRange: editor.selectedRange())
            longestKeystroke = max(longestKeystroke, (CFAbsoluteTimeGetCurrent() - start) * 1000)
            try await Task.sleep(for: .milliseconds(30))
        }
        // Debounced preview, autosave and index work land after the last key.
        try await Task.sleep(for: .seconds(2))
        let typingStall = heartbeat.stop()
        _ = await archive.flushEditors()

        // Idle: nothing typed, nothing clicked.
        try await Task.sleep(for: .seconds(2))
        let idleSeconds = 10.0
        let cpuBefore = Self.cpuSeconds()
        let idleStart = CFAbsoluteTimeGetCurrent()
        try await Task.sleep(for: .seconds(idleSeconds))
        let idleCPU = (Self.cpuSeconds() - cpuBefore) / (CFAbsoluteTimeGetCurrent() - idleStart) * 100
        let memory = Self.memory()

        let report = String(
            format: """
                BENCH197 fixture: 10000 + 60 + 40 documents (generated in %.1f s)
                BENCH197 load: all three sections %.2f s, search indexes %.2f s, longest main-thread stall %.0f ms
                BENCH197 expand collapsed 10k section: %.0f ms, longest stall %.0f ms
                BENCH197 typing (200 keys, 10k Library): longest keystroke %.1f ms, longest main-thread stall %.0f ms
                BENCH197 idle CPU over %.0f s: %.2f %%
                BENCH197 memory: resident %.0f MB, footprint %.0f MB (test process before the window: %.0f / %.0f MB)
                """,
            Self.seconds(generated), Self.seconds(loaded), Self.seconds(indexed), loadStall,
            Self.seconds(expanded) * 1000,
            expandStall, longestKeystroke, typingStall, idleSeconds, idleCPU, memory.resident, memory.footprint,
            baseline.resident, baseline.footprint)
        print(report)
        try report.write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent("bench197.txt"), atomically: true,
            encoding: .utf8)
        XCTAssertLessThan(idleCPU, 1, "idle CPU")
        XCTAssertLessThanOrEqual(memory.resident, 1_536, "resident memory")
        XCTAssertLessThanOrEqual(longestKeystroke, 50, "a keystroke in the 10k Library")
        XCTAssertLessThanOrEqual(typingStall, 50, "main-thread stall while typing")
        for workspace in registry.workspaces { await workspace.releaseLibrary() }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
