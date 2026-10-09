import XCTest

@testable import SilkwebCore

/// #177: the knowledge graph's records, adjacency, postings and incremental invalidation.
final class KnowledgeGraphTests: XCTestCase {
    /// An in-memory Library: text and a stamp per Document, plus empty Folders. A move keeps the stamp, an edit
    /// takes a new one, like a file's identity and date.
    private struct Fixture {
        var files: [String: (text: String, stamp: Int)] = [:]
        var folders: Set<String> = []
        var caseSensitive = false
        var nextStamp = 1

        mutating func write(_ path: String, _ text: String) {
            files[path] = (text, nextStamp)
            nextStamp += 1
        }

        mutating func move(_ from: String, to: String) {
            files[to] = files.removeValue(forKey: from)
        }

        var listing: KnowledgeGraph.Listing {
            var all = folders
            for path in files.keys {
                var parent = (path as NSString).deletingLastPathComponent
                while !parent.isEmpty {
                    all.insert(parent)
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
            return KnowledgeGraph.Listing(
                documents: files.keys.sorted().map { .init(path: $0, stamp: "\(files[$0]!.stamp)") },
                folders: all.sorted(), caseSensitive: caseSensitive)
        }

        func content(_ path: String) -> KnowledgeContent { KnowledgeContent(text: files[path]!.text) }
    }

    @discardableResult
    private func sync(_ graph: inout KnowledgeGraph, _ fixture: Fixture) -> [String] {
        let needed = graph.apply(fixture.listing)
        for entry in needed { XCTAssertTrue(graph.install(entry, content: fixture.content(entry.path))) }
        return needed.map(\.path)
    }

    private func fresh(_ fixture: Fixture) -> KnowledgeGraph {
        var graph = KnowledgeGraph()
        sync(&graph, fixture)
        return graph
    }

    /// The graph's edges for every Document are exactly the shared #176 rule's.
    private func assertMatchesResolver(
        _ graph: KnowledgeGraph, _ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line
    ) {
        let listing = fixture.listing
        var items: [String: MarkdownLinkResolver.Item] = [:]
        for folder in listing.folders { items[folder] = .folder }
        for document in listing.documents { items[document.path] = .document }
        let resolver = MarkdownLinkResolver(items: items, caseSensitive: fixture.caseSensitive)
        for (path, document) in fixture.files {
            let body: String
            switch MemoryEnvelope.parse(document.text) {
            case .missing: body = document.text
            case .envelope(_, let range): body = String(document.text[range])
            case .failure: body = ""
            }
            let expected = resolver.linksTo(MarkdownLinks.scan(body), from: path).map {
                KnowledgeEdge(kind: .linksTo, source: path, target: $0.target, section: $0.section)
            }
            XCTAssertEqual(graph.links(from: path).value, expected, path, file: file, line: line)
        }
    }

    // MARK: Content

    func testSectionsChunksAndTermsComeFromTheBodyAfterTheEnvelope() throws {
        let envelope = MemoryEnvelope(
            memoryID: "hb_gate", type: "decision", project: "Harbor", agent: "a", session: "s",
            createdAt: Date(timeIntervalSince1970: 0))
        var withClaims = envelope
        withClaims["supersedes"] = .list(["hb_old"])
        let body = """
            Intro café text.

            # Gate — décision
            Use `library.lock` here.
            ```
            # Not a heading
            ```
            ## Détails
            Deep [link](Other.md#Top).
            ### Leaf
            x
            ## Next
            y
            # Second
            z
            """
        let content = KnowledgeContent(text: try withClaims.document(body: body))
        XCTAssertEqual(content.memoryID, "hb_gate")
        XCTAssertEqual(content.supersedes, ["hb_old"])
        XCTAssertEqual(content.links, ["Other.md#Top"])
        let bytes = Array(body.utf8)
        func text(_ start: Int, _ end: Int) -> String { String(decoding: bytes[start..<end], as: UTF8.self) }
        XCTAssertEqual(
            content.sections.map(\.headings),
            [
                [], ["Gate — décision"], ["Gate — décision", "Détails"], ["Gate — décision", "Détails", "Leaf"],
                ["Gate — décision", "Next"], ["Second"],
            ])
        let sections = content.sections.map { text($0.start, $0.end) }
        XCTAssertEqual(sections[0], "Intro café text.\n\n")
        XCTAssertTrue(sections[1].hasPrefix("# Gate — décision\n") && sections[1].hasSuffix("## Next\ny\n"))
        XCTAssertTrue(sections[2].hasPrefix("## Détails\n") && sections[2].hasSuffix("### Leaf\nx\n"))
        XCTAssertEqual(sections[3], "### Leaf\nx\n")
        XCTAssertEqual(sections[5], "# Second\nz")
        // Chunks tile the body in order, each inside its innermost Section.
        var offset = 0
        for chunk in content.chunks {
            XCTAssertEqual(chunk.start, offset)
            let section = content.sections[chunk.section]
            XCTAssertTrue(section.start <= chunk.start && chunk.end <= section.end)
            offset = chunk.end
        }
        XCTAssertEqual(offset, bytes.count)
        XCTAssertEqual(content.chunks.map(\.section), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(content.headingTerms["decision"], 1)
        XCTAssertEqual(content.bodyTerms["library.lock"], 1)
        XCTAssertEqual(content.bodyTerms["lock"], 1)
        XCTAssertNil(content.bodyTerms["hb_gate"], "envelope text is never body text")
        XCTAssertEqual(content.bodyTerms["cafe"], 1)
    }

    func testLongSectionsSplitIntoChunksOnLineBoundaries() {
        let line = String(repeating: "word ", count: 30) + "\n"
        let long = String(repeating: "é", count: 3000)
        let body = "# Big\n" + String(repeating: line, count: 40) + long + "\n" + "tail\n"
        let content = KnowledgeContent(body: body)
        let bytes = Array(body.utf8)
        XCTAssertGreaterThan(content.chunks.count, 4)
        var offset = 0
        for chunk in content.chunks {
            XCTAssertEqual(chunk.start, offset)
            XCTAssertTrue(chunk.start == 0 || bytes[chunk.start - 1] == 0x0A, "chunks start on a line")
            let length = chunk.end - chunk.start
            let text = String(decoding: bytes[chunk.start..<chunk.end], as: UTF8.self)
            XCTAssertTrue(length <= KnowledgeContent.chunkBytes || !text.dropLast().contains("\n"))
            offset = chunk.end
        }
        XCTAssertEqual(offset, bytes.count)
        XCTAssertEqual(KnowledgeContent(body: "").chunks, [])
        XCTAssertEqual(KnowledgeContent(body: "\n\n# Only\n").sections.map(\.headings), [["Only"]])
    }

    func testMalformedEnvelopeLeavesNoSectionsLinksOrBody() {
        let text = "---\nschema: silkweb-memory/v99\nmemory_id: x\n---\n[a](A.md) body words"
        guard case .failure = MemoryEnvelope.parse(text) else { return XCTFail("fixture must be unreadable") }
        XCTAssertEqual(KnowledgeContent(text: text), .empty)
    }

    func testTokenizerKeepsIdentifiersWholeAndSplitsTheirParts() {
        XCTAssertEqual(
            KnowledgeTokenizer.tokens("Use `library.lock` (or notarytool), see hb_gate! Café-Bar 2.0."),
            [
                "use", "library.lock", "library", "lock", "or", "notarytool", "see", "hb_gate", "hb", "gate",
                "cafe-bar", "cafe", "bar", "2.0", "2", "0",
            ])
        XCTAssertEqual(KnowledgeTokenizer.tokens("...--//"), [])
    }

    // MARK: Graph

    func testEdgesPostingsAndDependenciesFollowCreateEditMoveDelete() {
        var fixture = Fixture()
        fixture.write(
            "Hub.md", "[a](Notes/A.md) [b](Notes/B.md#Part) [x](Missing.md) [img](Notes/A.md \"t\") ![i](Notes/A.md)")
        fixture.write("Notes/A.md", "# Alpha\nback to [hub](../Hub.md), [self](A.md), [web](https://x.com)")
        var graph = KnowledgeGraph()
        XCTAssertEqual(Set(sync(&graph, fixture)), ["Hub.md", "Notes/A.md"])
        XCTAssertEqual(graph, fresh(fixture))
        XCTAssertEqual(graph.links(from: "Hub.md").value?.map(\.target), ["Notes/A.md"])
        XCTAssertEqual(graph.links(to: "Hub.md").value?.map(\.source), ["Notes/A.md"])
        XCTAssertEqual(
            graph.postings(for: "alpha").value?["Notes/A.md"], KnowledgePosting(title: 0, heading: 1, body: 1))
        XCTAssertEqual(graph.postings(for: "hub").value?["Hub.md"]?.title, 1)
        XCTAssertEqual(graph.dependents["missing.md"], ["Hub.md"], "broken destinations are tracked")

        // Creating a broken link's target makes the edge, with no read of the linking Document.
        fixture.write("Notes/B.md", "# Part\n")
        XCTAssertEqual(sync(&graph, fixture), ["Notes/B.md"])
        XCTAssertEqual(
            graph.links(from: "Hub.md").value,
            [
                KnowledgeEdge(kind: .linksTo, source: "Hub.md", target: "Notes/A.md", section: nil),
                KnowledgeEdge(kind: .linksTo, source: "Hub.md", target: "Notes/B.md", section: "Part"),
            ])
        XCTAssertEqual(graph, fresh(fixture))
        fixture.write("Missing.md", "now here")
        sync(&graph, fixture)
        XCTAssertEqual(graph.links(from: "Hub.md").value?.map(\.target), ["Notes/A.md", "Notes/B.md", "Missing.md"])
        XCTAssertEqual(graph, fresh(fixture))

        // Renaming a Folder moves its Documents: nothing is read, links from and to them follow the new paths.
        fixture.move("Notes/A.md", to: "Ideas/A.md")
        fixture.move("Notes/B.md", to: "Ideas/B.md")
        XCTAssertEqual(sync(&graph, fixture), [])
        XCTAssertEqual(graph.links(from: "Hub.md").value?.map(\.target), ["Missing.md"])
        XCTAssertEqual(graph.links(from: "Ideas/A.md").value?.map(\.target), ["Hub.md"])
        XCTAssertEqual(graph, fresh(fixture))

        // A case alias on a case-insensitive volume resolves; a second spelling makes it ambiguous.
        fixture.write("Hub.md", "[a](ideas/a.md)")
        XCTAssertEqual(sync(&graph, fixture), ["Hub.md"])
        XCTAssertEqual(graph.links(from: "Hub.md").value?.map(\.target), ["Ideas/A.md"])
        fixture.write("Ideas/a.md", "twin")
        sync(&graph, fixture)
        XCTAssertEqual(graph.links(from: "Hub.md").value, [])
        XCTAssertEqual(graph, fresh(fixture))
        fixture.caseSensitive = true
        sync(&graph, fixture)
        XCTAssertEqual(graph.links(from: "Hub.md").value, [])
        XCTAssertEqual(graph, fresh(fixture))
        fixture.files["Ideas/a.md"] = nil
        fixture.caseSensitive = false
        sync(&graph, fixture)
        XCTAssertEqual(graph.links(from: "Hub.md").value?.map(\.target), ["Ideas/A.md"])
        XCTAssertEqual(graph, fresh(fixture))

        // A Folder at a link's path is no edge; deleting the target removes the edge and its postings.
        fixture.files["Ideas/A.md"] = nil
        fixture.folders.insert("Ideas/A.md")
        sync(&graph, fixture)
        XCTAssertEqual(graph.links(from: "Hub.md").value, [])
        XCTAssertEqual(graph.document("Ideas/A.md"), .notFound)
        XCTAssertNil(graph.postings(for: "alpha").value?["Ideas/A.md"])
        XCTAssertEqual(graph, fresh(fixture))
        assertMatchesResolver(graph, fixture)
    }

    func testRandomCreateEditMoveDeleteSequencesMatchAFullRebuild() {
        var generator = SplitMix(seed: 177)
        let paths = [
            "A.md", "a.md", "B.md", "Notes/B.md", "notes/b.md", "Notes/C.md", "Notes/Deep/D.md", "Archive/A.md",
            "Archive/Notes/C.md", "Ünï.md", "Notes/Ünï.md", "Space Name.md",
        ]
        let destinations = [
            "A.md", "a.md", "B.md", "../A.md", "Notes/B.md", "notes/b.md", "C.md#Intro", "../Notes/C.md",
            "Deep/D.md", "Notes", "Notes/", "Missing.md", "<Space Name.md>", "Space%20Name.md", "%C3%9Cn%C3%AF.md",
            "../../A.md", "https://example.com/A.md", "#Top", "Archive/Notes/C.md", "D.md",
        ]
        func text() -> String {
            var lines: [String] = []
            for _ in 0..<generator.next(4) {
                let destination = destinations[generator.next(destinations.count)]
                lines.append(generator.next(5) == 0 ? "![i](\(destination))" : "See [it](\(destination)) now")
            }
            if generator.next(3) == 0 { lines.insert("# Heading \(generator.next(9))", at: 0) }
            if generator.next(8) == 0 { lines.insert("---\nschema: silkweb-memory/v99\n---", at: 0) }
            return lines.joined(separator: "\n")
        }
        var fixture = Fixture()
        var graph = KnowledgeGraph()
        var linking = 0
        for step in 0..<400 {
            let existing = fixture.files.keys.sorted()
            let free = paths.filter { fixture.files[$0] == nil }
            switch generator.next(10) {
            case 0...2 where !free.isEmpty: fixture.write(free[generator.next(free.count)], text())
            case 3...4 where !existing.isEmpty: fixture.write(existing[generator.next(existing.count)], text())
            case 5...6 where !existing.isEmpty && !free.isEmpty:
                fixture.move(existing[generator.next(existing.count)], to: free[generator.next(free.count)])
            case 7 where !existing.isEmpty: fixture.files[existing[generator.next(existing.count)]] = nil
            case 8:
                let folder = ["Notes", "notes", "Empty", "Archive/Notes"][generator.next(4)]
                if fixture.folders.remove(folder) == nil { fixture.folders.insert(folder) }
            case 9 where generator.next(5) == 0: fixture.caseSensitive.toggle()
            default: break
            }
            // Sometimes the Library changes again before the first change was read.
            if generator.next(6) == 0 {
                _ = graph.apply(fixture.listing)
                if let path = fixture.files.keys.sorted().first { fixture.write(path, text()) }
            }
            sync(&graph, fixture)
            linking += graph.outgoing[.linksTo]?.count ?? 0
            XCTAssertEqual(graph, fresh(fixture), "step \(step)")
            if graph != fresh(fixture) { return }
        }
        XCTAssertGreaterThan(linking, 400, "the sequence exercises real edges")
        assertMatchesResolver(graph, fixture)
    }

    func testAChangedDocumentServesNothingFromItsPreviousRevisionUntilReread() {
        var fixture = Fixture()
        fixture.write("Source.md", "old words [t](Target.md)")
        fixture.write("Target.md", "target")
        fixture.write("Other.md", "[t](Target.md)")
        var graph = fresh(fixture)
        XCTAssertEqual(graph.links(to: "Target.md").value?.map(\.source), ["Other.md", "Source.md"])

        fixture.write("Source.md", "new words")
        let needed = graph.apply(fixture.listing)
        XCTAssertEqual(needed.map(\.path), ["Source.md"])
        XCTAssertEqual(graph.document("Source.md"), .notReady)
        XCTAssertEqual(graph.links(from: "Source.md"), .notReady)
        XCTAssertEqual(graph.links(to: "Target.md"), .notReady)
        XCTAssertEqual(graph.postings(for: "old"), .notReady)
        // Nothing of the old revision is left to serve, even to a caller reading the maps directly.
        XCTAssertNil(graph.postings["old"])
        XCTAssertNil(graph.outgoing[.linksTo]?["Source.md"])
        XCTAssertEqual(graph.incoming[.linksTo]?["Target.md"]?.map(\.source), ["Other.md"])
        XCTAssertEqual(graph.links(from: "Other.md").value?.map(\.target), ["Target.md"])

        // Content read for a listing that has moved on is dropped.
        let stale = needed[0]
        fixture.write("Source.md", "newest [t](Target.md)")
        let again = graph.apply(fixture.listing)
        XCTAssertFalse(graph.install(stale, content: KnowledgeContent(text: "new words")))
        XCTAssertEqual(graph.document("Source.md"), .notReady)
        XCTAssertTrue(graph.install(again[0], content: fixture.content("Source.md")))
        XCTAssertEqual(graph.links(to: "Target.md").value?.map(\.source), ["Other.md", "Source.md"])
        XCTAssertEqual(graph.postings(for: "newest").value?.keys.sorted(), ["Source.md"])
        XCTAssertEqual(graph.links(to: "Nowhere.md"), .notFound)
        XCTAssertEqual(graph, fresh(fixture))
    }

    func testRestoredRecordsResolveAgainstTheLibraryAsItIsNow() {
        var fixture = Fixture()
        fixture.write("A.md", "[b](B.md) [c](C.md)")
        fixture.write("B.md", "b")
        let saved = fresh(fixture)
        // While closed: C appears, B goes, A is unchanged.
        fixture.write("C.md", "c")
        fixture.files["B.md"] = nil
        var restored = KnowledgeGraph(records: Array(saved.records.values))
        XCTAssertEqual(sync(&restored, fixture), ["C.md"])
        XCTAssertEqual(restored.links(from: "A.md").value?.map(\.target), ["C.md"])
        XCTAssertEqual(restored, fresh(fixture))
    }

    func testIncrementalUpdatesStayFastAtTenThousandDocumentsAndOneHundredThousandEdges() {
        // Contract #175 benchmark shape: 10,000 Documents in 1,000 Folders, ~100,000 edges, plus a hub.
        let count = 10_000
        func path(_ index: Int) -> String { "F\(index % 1000)/Doc \(index).md" }
        var contents: [String: KnowledgeContent] = [:]
        var documents: [KnowledgeGraph.Listing.Document] = []
        for index in 0..<count {
            var content = KnowledgeContent.empty
            content.links = (1...10).map {
                "../" + path((index * 7 + $0 * 131) % count).replacingOccurrences(of: " ", with: "%20")
            }
            content.bodyTerms = ["term\(index % 500)": 2, "common": 1]
            if index % 100 == 0 { content.links.append("../Hub.md") }
            contents[path(index)] = content
            documents.append(.init(path: path(index), stamp: "s\(index)"))
        }
        documents.append(.init(path: "Hub.md", stamp: "hub"))
        contents["Hub.md"] = .empty
        let listing = KnowledgeGraph.Listing(
            documents: documents, folders: (0..<1000).map { "F\($0)" }, caseSensitive: false)
        var graph = KnowledgeGraph()
        let clock = ContinuousClock()
        let build = clock.measure {
            for entry in graph.apply(listing) { graph.install(entry, content: contents[entry.path]!) }
        }
        let edges = graph.outgoing[.linksTo]?.values.reduce(0) { $0 + $1.count } ?? 0
        XCTAssertGreaterThan(edges, 99_000)
        XCTAssertEqual(graph.links(to: "Hub.md").value?.count, 100)

        // One saved Document, then a renamed hub: only the affected links are resolved again.
        var edited = listing
        edited.documents[42].stamp = "edited"
        var update = clock.measure {
            for entry in graph.apply(edited) { graph.install(entry, content: contents[entry.path]!) }
        }
        var renamed = edited
        renamed.documents[count] = .init(path: "Hub 2.md", stamp: "hub")
        update = max(update, clock.measure { XCTAssertEqual(graph.apply(renamed), []) })
        XCTAssertEqual(graph.links(to: "Hub 2.md").value?.count, 0)
        XCTAssertEqual(graph.document("Hub 2.md").value?.path, "Hub 2.md")
        let query = clock.measure {
            for index in 0..<50 { _ = graph.links(from: path(index)); _ = graph.links(to: path(index)) }
        }
        print("Knowledge graph 10k/100k: build \(build), incremental \(update), 100 neighbor queries \(query)")
        XCTAssertLessThan(update, .milliseconds(500))
        XCTAssertLessThan(query, .milliseconds(50))
    }
}

/// Deterministic randomness for reproducible sequences.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Int(value % UInt64(bound))
    }
}
