import XCTest

@testable import SilkwebCore

/// #178: the permitted graph view. Hidden Documents are absent from every lookup, traversal, count, statistic,
/// truncation signal and cursor, and IDs never reveal whether a Document exists outside the grant.
final class PermittedKnowledgeGraphTests: XCTestCase {
    private var root: URL!

    private let project = "Memory/Projects/Silkweb"
    private let modified = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Permitted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    private func write(_ library: URL, _ path: String, _ text: String) throws {
        let url = library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func grant(_ library: URL, extra: [String] = ["Shared"]) -> AgentGrant {
        AgentGrant(
            project: "Silkweb", library: LibraryLocation(path: library.path), access: .read,
            extraReadFolders: extra, label: "Silkweb project")
    }

    private func writeGrants(_ library: URL, home: URL, extra: [String] = ["Shared"]) throws -> URL {
        let url = home.appendingPathComponent("grants/agent-grants.json")
        try AgentGrantFile(grants: [grant(library, extra: extra)]).write(to: url)
        return url
    }

    private func service(_ grants: URL, home: URL, clientRoots: [String]? = nil) -> AgentMemoryService {
        AgentMemoryService(
            session: AgentSession(project: "Silkweb", store: AgentGrantStore(url: grants), clientRoots: clientRoots),
            cacheDirectory: AgentMemoryService.defaultCacheDirectory(home: home))
    }

    private func memory(_ id: String, body: String) -> String {
        try! MemoryEnvelope(
            memoryID: id, type: "decision", project: "Silkweb", agent: "claude-code", session: "s-1",
            createdAt: AgentMemorySearchRequest.date("2026-10-06T15:00:00Z")!
        ).document(body: body)
    }

    /// The same permitted Documents in every variant. With `hidden`, the Library also holds a hub outside the
    /// grant that links the permitted Documents together, Documents linking to and from them, query terms and a
    /// `memory_id`, so a leak shows up as a difference.
    private func makeLibrary(_ name: String, hidden: Bool) throws -> URL {
        let library = root.appendingPathComponent(name).appendingPathComponent("Writing")
        try write(library, "\(project)/A.md", "# Alpha\n[c](C.md) [b](B.md) [hub](../../../Private/Hub.md) gate\n")
        try write(library, "\(project)/B.md", "# Beta\nflock gate [hub](../../../Private/Hub.md)\n")
        try write(library, "\(project)/C.md", "# Gamma\n[d](D.md)\n")
        try write(library, "\(project)/D.md", memory("mem_d", body: "delta\n"))
        try write(library, "Shared/E.md", "[a](../Memory/Projects/Silkweb/A.md)\n")
        if hidden {
            try write(
                library, "Private/Hub.md",
                "gate flock gate [a](../\(project)/A.md) [b](../\(project)/B.md) [d](../\(project)/D.md)\n")
            for index in 1...5 {
                try write(library, "Private/X\(index).md", "gate [a](../\(project)/A.md) [c](../\(project)/C.md)\n")
            }
            try write(library, "Private/Secret.md", memory("mem_secret", body: "canary gate\n"))
        }
        return library
    }

    /// The owner's full Library as the app indexes it: hidden Documents included, so only the view's own
    /// filtering keeps them out.
    private func wideGraph(_ library: URL) async throws -> KnowledgeGraph {
        let index = LibraryKnowledgeIndex(
            root: library, cacheDirectory: root.appendingPathComponent("AppCaches-\(UUID())"))
        try await index.reconcile(try await LibraryScanner.scan(root: library))
        return await index.graph
    }

    private func scope(_ library: URL) throws -> AgentScope {
        try AgentScope(grant: grant(library), createAllowed: false, caseSensitive: false)
    }

    private func paths(_ traversal: KnowledgeLookup<PermittedKnowledgeGraph.Traversal>) -> [String] {
        (traversal.value?.neighbors.map(\.path) ?? ["<not ready>"]).map { ($0 as NSString).lastPathComponent }
    }

    private func assertError(
        _ expression: @autoclosure () throws -> Any, _ expected: AgentAccessError, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) {
            XCTAssertEqual($0 as? AgentAccessError, expected, file: file, line: line)
        }
    }

    // MARK: Traversal

    func testMultiHopTraversalNeverPassesThroughAHiddenDocument() async throws {
        let library = try makeLibrary("Wide", hidden: true)
        let wide = try await wideGraph(library)
        XCTAssertEqual(
            wide.links(to: "\(project)/B.md").value?.map(\.source).contains("Private/Hub.md"), true,
            "the fixture's hub links B in the owner's full graph")
        let view = PermittedKnowledgeGraph(graph: wide, scope: try scope(library))

        let two = try view.neighbors(of: ["\(project)/D.md"], budget: .init(hops: 2))
        XCTAssertEqual(paths(two), ["C.md", "A.md"], "D reaches A only through C; the hidden hub is no shortcut")
        XCTAssertEqual(
            two.value?.neighbors.map(\.hops), [1, 2])
        XCTAssertEqual(
            two.value?.neighbors.last?.reasons,
            [.init(kind: .linksTo, direction: .in, via: "\(project)/C.md")])
        XCTAssertEqual(two.value?.truncated, false)

        let fromA = try view.neighbors(of: ["\(project)/A.md"], budget: .init(hops: 2))
        XCTAssertEqual(paths(fromA), ["C.md", "B.md", "E.md", "D.md"])
        XCTAssertFalse(fromA.value!.neighbors.contains { $0.path.hasPrefix("Private/") })
        XCTAssertFalse(
            fromA.value!.neighbors.flatMap(\.reasons).contains { $0.via.hasPrefix("Private/") },
            "no reason names a hidden Document")

        XCTAssertEqual(try view.neighbors(of: ["\(project)/B.md"]).value?.neighbors.map(\.path), ["\(project)/A.md"])
        XCTAssertEqual(view.links(to: "\(project)/B.md").value?.map(\.source), ["\(project)/A.md"])
        XCTAssertEqual(
            view.links(from: "\(project)/A.md").value?.map(\.target), ["\(project)/C.md", "\(project)/B.md"])
        XCTAssertEqual(view.degree(of: "\(project)/A.md").value, .init(incoming: 1, outgoing: 2))
        XCTAssertEqual(view.document("Private/Hub.md"), .notFound)
        XCTAssertEqual(
            try view.neighbors(of: ["Private/Hub.md"]).value?.neighbors, [],
            "a hidden seed is no seed at all")
        XCTAssertNil(view.postings(for: "canary").value?.first)
        XCTAssertEqual(view.postings(for: "gate").value?.keys.sorted(), ["\(project)/A.md", "\(project)/B.md"])
        XCTAssertEqual(view.count, 5)
        assertError(try view.neighbors(of: ["\(project)/A.md"], budget: .init(hops: 3)), .invalidArgument("hops"))
        assertError(try view.neighbors(of: ["\(project)/A.md"], budget: .init(hops: 0)), .invalidArgument("hops"))
    }

    func testBudgetsCutOnlyPermittedNeighborsAndEdges() async throws {
        let library = try makeLibrary("Budget", hidden: true)
        let view = PermittedKnowledgeGraph(graph: try await wideGraph(library), scope: try scope(library))
        let seed = ["\(project)/A.md"]
        // A has exactly three permitted neighbors (C, B out; E in) and six hidden ones.
        XCTAssertEqual(try view.neighbors(of: seed, budget: .init(maxNeighborsPerDocument: 3)).value?.truncated, false)
        let capped = try view.neighbors(of: seed, budget: .init(maxNeighborsPerDocument: 2))
        XCTAssertEqual(paths(capped), ["C.md", "B.md"])
        XCTAssertEqual(capped.value?.truncated, true)
        XCTAssertEqual(try view.neighbors(of: seed, budget: .init(maxEdges: 3)).value?.truncated, false)
        let edges = try view.neighbors(of: seed, budget: .init(maxEdges: 2))
        XCTAssertEqual(paths(edges), ["C.md", "B.md"])
        XCTAssertEqual(edges.value?.truncated, true)
        let documents = try view.neighbors(of: seed, budget: .init(maxDocuments: 1))
        XCTAssertEqual(paths(documents), ["C.md"])
        XCTAssertEqual(documents.value?.truncated, true)
    }

    func testACancelledTraversalReturnsNoPartialResults() async throws {
        let library = try makeLibrary("Cancel", hidden: false)
        let view = PermittedKnowledgeGraph(graph: try await wideGraph(library), scope: try scope(library))
        var checks = 0
        XCTAssertThrowsError(
            try view.neighbors(of: ["\(project)/A.md"], budget: .init(hops: 2)) {
                checks += 1
                return checks > 2
            }
        ) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try view.neighbors(of: ["\(project)/A.md"]) { true }) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testOnlyUnreadPermittedDocumentsMakeTheViewNotReady() throws {
        let library = root.appendingPathComponent("Pending")
        var graph = KnowledgeGraph()
        let listing = KnowledgeGraph.Listing(
            documents: [
                .init(path: "\(project)/A.md", stamp: "a"), .init(path: "Private/Hub.md", stamp: "h"),
            ],
            folders: [], caseSensitive: false)
        let needed = graph.apply(listing)
        graph.install(needed[0], content: KnowledgeContent(body: "[h](../../../Private/Hub.md) gate"))
        XCTAssertFalse(graph.isReady, "the hidden hub is still unread")
        let view = PermittedKnowledgeGraph(graph: graph, scope: try scope(library))
        XCTAssertTrue(view.isReady, "a hidden unread Document never makes permitted answers wait")
        XCTAssertEqual(view.links(to: "\(project)/A.md"), .ready([]))
        XCTAssertEqual(view.postings(for: "gate").value?.keys.sorted(), ["\(project)/A.md"])
        XCTAssertEqual(view.statistics.value?.documents, 1)

        var unread = KnowledgeGraph()
        unread.apply(listing)
        let waiting = PermittedKnowledgeGraph(graph: unread, scope: try scope(library))
        XCTAssertEqual(waiting.document("\(project)/A.md"), .notReady)
        XCTAssertEqual(try waiting.neighbors(of: ["\(project)/A.md"]), .notReady)
        XCTAssertEqual(try waiting.resolve(.path("\(project)/A.md")), .notReady)
    }

    // MARK: Differential

    /// Two Libraries whose permitted Documents are identical and whose hidden Documents differ give the same
    /// answers, end to end through the helper and through the view over the owner's full graph.
    func testHiddenContentNeverChangesVisibleTitlesCountsOrTruncation() async throws {
        let plain = try makeLibrary("Plain", hidden: false)
        let busy = try makeLibrary("Busy", hidden: true)
        let budgets: [PermittedKnowledgeGraph.Budget] = [
            .init(), .init(hops: 2), .init(maxNeighborsPerDocument: 2), .init(hops: 2, maxEdges: 4),
            .init(hops: 2, maxDocuments: 3),
        ]
        let seeds = ["A", "B", "C", "D"].map { "\(project)/\($0).md" } + ["Shared/E.md"]

        func answers(_ view: PermittedKnowledgeGraph) throws -> [String] {
            var lines: [String] = []
            for seed in seeds {
                for budget in budgets {
                    lines.append("\(seed) \(budget): \(try view.neighbors(of: [seed], budget: budget))")
                }
                lines.append("\(seed) in \(view.links(to: seed)) out \(view.links(from: seed))")
                lines.append("\(seed) degree \(view.degree(of: seed))")
            }
            for term in ["gate", "flock", "canary", "delta", "alpha"] {
                let postings = view.postings(for: term).value?.sorted { $0.key < $1.key }
                lines.append("\(term): \(postings.map { "\($0)" } ?? "not ready")")
            }
            lines.append("stats \(view.statistics) count \(view.count) ready \(view.isReady)")
            lines.append("mem_d \(view.documents(memoryID: "mem_d")?.map(\.path) ?? [])")
            return lines
        }

        // The helper end to end: graph, snapshot, cursors and search.
        let plainHome = root.appendingPathComponent("Plain")
        let busyHome = root.appendingPathComponent("Busy")
        let plainService = service(try writeGrants(plain, home: plainHome), home: plainHome)
        let busyService = service(try writeGrants(busy, home: busyHome), home: busyHome)
        let plainView = try plainService.permittedGraph()
        let busyView = try busyService.permittedGraph()
        XCTAssertEqual(try answers(plainView), try answers(busyView))
        XCTAssertEqual(plainView.snapshot, busyView.snapshot, "hidden Documents never change the snapshot")
        let neighbors = try XCTUnwrap(try plainView.neighbors(of: [seeds[0]], budget: .init(hops: 2)).value).neighbors
        let plainPage = try plainView.page(neighbors, cursor: nil, limit: 2, request: "A")
        let busyPage = try busyView.page(neighbors, cursor: nil, limit: 2, request: "A")
        XCTAssertEqual(plainPage.nextCursor, busyPage.nextCursor)
        XCTAssertEqual(Array(plainPage.items), Array(busyPage.items))
        for query in ["gate", "", "canary", "flock gate", "nothing"] {
            XCTAssertEqual(
                try plainService.search(AgentMemorySearchRequest(query: query)),
                try busyService.search(AgentMemorySearchRequest(query: query)), "search “\(query)”")
        }
        XCTAssertEqual(try busyService.search(AgentMemorySearchRequest(query: "gate")).total, 2)

        // The owner's full graph, filtered by the view. (Scanning gives the Documents app IDs, so it runs last.)
        let plainWide = PermittedKnowledgeGraph(graph: try await wideGraph(plain), scope: try scope(plain))
        let busyWide = PermittedKnowledgeGraph(graph: try await wideGraph(busy), scope: try scope(busy))
        XCTAssertEqual(try answers(plainWide), try answers(busyWide))
        XCTAssertEqual(try answers(plainWide), try answers(plainView))
    }

    // MARK: Cursors and caches

    func testNarrowedRootsOrGrantFoldersExpireCursorsAndScopeKeyedCaches() throws {
        let library = try makeLibrary("Cursors", hidden: true)
        let home = root.appendingPathComponent("Cursors")
        let grants = try writeGrants(library, home: home)
        let wide = service(grants, home: home)
        let items = ["one", "two", "three"]
        let first = try wide.permittedGraph().page(items, cursor: nil, limit: 1, request: "q")
        XCTAssertEqual(Array(first.items), ["one"])
        let cursor = try XCTUnwrap(first.nextCursor)

        // Same scope and Documents: the cursor pages on, and a change to a hidden Document doesn't touch it.
        try write(library, "Private/X1.md", "changed [a](../\(project)/A.md)")
        try write(library, "Private/New.md", "new")
        let second = try wide.permittedGraph().page(items, cursor: cursor, limit: 1, request: "q")
        XCTAssertEqual(Array(second.items), ["two"])
        XCTAssertNotNil(second.nextCursor)
        // A cache rebuilt from the same Documents names the same snapshot.
        let restarted = service(grants, home: home)
        XCTAssertEqual(
            Array(try restarted.permittedGraph().page(items, cursor: cursor, limit: 1, request: "q").items), ["two"])

        // Another request, a malformed cursor, or one past the end.
        assertError(try wide.permittedGraph().page(items, cursor: cursor, limit: 1, request: "other"), .cursorExpired)
        assertError(try wide.permittedGraph().page(items, cursor: "g1.x", limit: 1), .invalidArgument("cursor"))
        assertError(
            try wide.permittedGraph().page(items, cursor: cursor, limit: 0, request: "q"), .invalidArgument("limit"))

        // Narrower MCP roots: the cursor expires and the graph is a fresh one for the narrower scope.
        let narrow = service(grants, home: home, clientRoots: [project])
        let narrowView = try narrow.permittedGraph()
        assertError(try narrowView.page(items, cursor: cursor, limit: 1, request: "q"), .cursorExpired)
        XCTAssertEqual(narrowView.document("Shared/E.md"), .notFound)
        XCTAssertEqual(narrowView.links(to: "\(project)/A.md").value, [])
        XCTAssertEqual(narrowView.count, 4)
        let manifest = try JSONDecoder().decode(
            KnowledgeCacheStore.Manifest.self,
            from: Data(contentsOf: narrow.knowledgeCacheURL.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.library, library.path + "\nSilkweb\n" + narrowView.scope.key)
        XCTAssertNotEqual(narrowView.scope.key, try wide.permittedGraph().scope.key)
        // Back to the wider scope: the narrow cache isn't reused for it.
        let widened = try service(grants, home: home).permittedGraph()
        XCTAssertEqual(widened.count, 5)
        XCTAssertEqual(widened.links(to: "\(project)/A.md").value?.map(\.source), ["Shared/E.md"])

        // The owner removes a grant folder: the same session's cursor expires on its next request.
        let fresh = try wide.permittedGraph().page(items, cursor: nil, limit: 1, request: "q").nextCursor
        _ = try writeGrants(library, home: home, extra: [])
        let edited = try wide.permittedGraph()
        assertError(try edited.page(items, cursor: fresh, limit: 1, request: "q"), .cursorExpired)
        XCTAssertEqual(edited.document("Shared/E.md"), .notFound)

        // A changed permitted Document expires it too; the first page afterwards is fresh, with no flag.
        let before = try edited.page(items, cursor: nil, limit: 1, request: "q").nextCursor
        try write(library, "\(project)/B.md", "# Beta\nchanged\n")
        let changed = try wide.permittedGraph()
        assertError(try changed.page(items, cursor: before, limit: 1, request: "q"), .cursorExpired)
        XCTAssertEqual(Array(try changed.page(items, cursor: nil, limit: 1, request: "q").items), ["one"])

        XCTAssertEqual(AgentAccessError.cursorExpired.code, "invalid_argument")
        XCTAssertEqual(AgentAccessError.cursorExpired.title, "Invalid Request")
        XCTAssertEqual(
            AgentAccessError.cursorExpired.message, "That cursor has expired. Search again without “cursor”.")
    }

    /// Files saved before this change: a checkpoint keyed by Library and project only is another scope's cache,
    /// rebuilt silently from the helper's index.
    func testACheckpointFromBeforeScopeKeysIsRebuilt() throws {
        let library = try makeLibrary("Earlier", hidden: false)
        let home = root.appendingPathComponent("Earlier")
        let helper = service(try writeGrants(library, home: home), home: home)
        try KnowledgeCacheStore(directory: helper.knowledgeCacheURL, library: library.path + "\nSilkweb").publish([
            KnowledgeRecord(
                path: "\(project)/Ghost.md", stamp: "ghost", documentID: nil, content: KnowledgeContent(body: "ghost"))
        ])
        let view = try helper.permittedGraph()
        XCTAssertEqual(view.document("\(project)/Ghost.md"), .notFound)
        XCTAssertEqual(view.count, 5)
        XCTAssertEqual(view.links(to: "\(project)/A.md").value?.map(\.source), ["Shared/E.md"])
    }

    // MARK: IDs and paths

    func testUnknownAndOutOfScopeIDsAreIndistinguishable() throws {
        let library = try makeLibrary("IDs", hidden: true)
        let home = root.appendingPathComponent("IDs")
        let inScope = UUID()
        let hidden = UUID()
        let metadata = library.appendingPathComponent(".silkweb/index.json")
        try FileManager.default.createDirectory(
            at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(
            LibraryMetadata(IDsByPath: ["\(project)/A.md": inScope, "Private/Secret.md": hidden])
        ).write(to: metadata)
        let helper = service(try writeGrants(library, home: home), home: home)
        let view = try helper.permittedGraph()

        XCTAssertEqual(try view.resolve(.documentID(inScope)).value?.path, "\(project)/A.md")
        XCTAssertEqual(try view.resolve(.memoryID("mem_d")).value?.path, "\(project)/D.md")
        XCTAssertEqual(try view.resolve(.path("\(project)/C.md")).value?.path, "\(project)/C.md")

        // By ID: unknown and out of scope are the same `not_found`.
        assertError(try view.resolve(.documentID(hidden)), .notFound)
        assertError(try view.resolve(.documentID(UUID())), .notFound)
        assertError(try view.resolve(.memoryID("mem_secret")), .notFound)
        assertError(try view.resolve(.memoryID("mem_unknown")), .notFound)
        XCTAssertEqual(view.document(id: hidden), view.document(id: UUID()))
        XCTAssertEqual(view.documents(memoryID: "mem_secret")?.count, 0)
        // The read path keeps its own identical refusal.
        assertError(try helper.read(AgentMemoryReadRequest(path: "", documentID: hidden)), .notFound)
        assertError(try helper.read(AgentMemoryReadRequest(path: "", documentID: UUID())), .notFound)

        // By path: decided from the string, so an existing and a missing hidden path read the same.
        let outside = AgentAccessError.outOfScope(view.scope.readRoots)
        assertError(try view.resolve(.path("Private/Secret.md")), outside)
        assertError(try view.resolve(.path("Private/Missing.md")), outside)
        assertError(try view.resolve(.path("\(project)/../../../Private/Secret.md")), .invalidPath)
        assertError(try view.resolve(.path("\(project)/Missing.md")), .notFound)
    }
}
