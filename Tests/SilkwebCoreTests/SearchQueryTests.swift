import XCTest

@testable import SilkwebCore

/// #179: the shared query syntax and field-weighted BM25.
final class SearchQueryTests: XCTestCase {
    private func date(_ text: String) -> Date { AgentMemorySearchRequest.date(text)! }

    // MARK: Parser

    func testWordsPhrasesAndFiltersParseWithRepeatedKeysOrdAndKeysCaseInsensitive() {
        let parsed = ParsedSearchQuery(
            "flock  \"lock   file\" TAG:research type:decision Type:memory status:Open project:\"Side Work\" "
                + "after:2026-10-01 before:2026-10-08 after:2026-09-01 before:2026-10-03 gate")
        XCTAssertEqual(parsed.words, ["flock", "gate"])
        XCTAssertEqual(parsed.phrases, ["lock file"])
        XCTAssertEqual(parsed.free, ["flock", "lock file", "gate"])
        XCTAssertEqual(parsed.tags, ["research"])
        XCTAssertEqual(parsed.types, ["decision", "memory"])
        XCTAssertEqual(parsed.statuses, ["Open"])
        XCTAssertEqual(parsed.projects, ["Side Work"])
        // OR'd: the earliest `after`, the latest `before`.
        XCTAssertEqual(parsed.after, date("2026-09-01"))
        XCTAssertEqual(parsed.before, date("2026-10-08"))
        XCTAssertTrue(parsed.hasText)
        XCTAssertTrue(parsed.hasFilters)
        XCTAssertEqual(parsed.findText, "lock file")
        XCTAssertEqual(parsed.highlightTerms, ["flock", "lock file", "gate"])
        XCTAssertEqual(parsed.foldedText, "flock lock file gate")
    }

    func testMalformedSyntaxFallsBackToLiteralWordsAndNeverFails() {
        // Unknown keys (`folder:` until #32), bad dates and empty values are words.
        let unknown = ParsedSearchQuery("folder:Notes after:yesterday before:2026-13-45 tag: :alone")
        XCTAssertEqual(unknown.words, ["folder:Notes", "after:yesterday", "before:2026-13-45", "tag:", ":alone"])
        XCTAssertFalse(unknown.hasFilters)
        // An unclosed quote: the rest is plain words, quote included.
        let unclosed = ParsedSearchQuery("type:memory alpha \"beta gamma")
        XCTAssertEqual(unclosed.types, ["memory"])
        XCTAssertEqual(unclosed.words, ["alpha", "\"beta", "gamma"])
        XCTAssertEqual(unclosed.phrases, [])
        let unclosedValue = ParsedSearchQuery("project:\"Side Work")
        XCTAssertEqual(unclosedValue.words, ["project:\"Side", "Work"])
        XCTAssertTrue(unclosedValue.projects.isEmpty)
        // An empty phrase or quoted value stays literal.
        XCTAssertEqual(ParsedSearchQuery("\"\" x").words, ["\"\"", "x"])
        XCTAssertEqual(ParsedSearchQuery("tag:\"  \"").words, ["tag:\"  \""])
        // Edge inputs.
        for text in ["", " ", "\"", ":", "::", "\u{0}", "\n\t", "a\"b", "type:\"x\"y"] {
            let parsed = ParsedSearchQuery(text)
            XCTAssertTrue(parsed.phrases.isEmpty, text)
            XCTAssertEqual(parsed.free, parsed.words, text)
        }
        XCTAssertEqual(ParsedSearchQuery("type:\"x\"y").types, ["x"])
        XCTAssertEqual(ParsedSearchQuery("tag:tag:x").tags, ["tag:x"])
        XCTAssertFalse(ParsedSearchQuery("   ").hasText)
        XCTAssertEqual(ParsedSearchQuery("\"\"\"").words, ["\"\"", "\""])
    }

    func testFilterOnlyQueriesHaveNoTextNoFindTextAndNoHighlights() {
        let parsed = ParsedSearchQuery("type:decision tag:research")
        XCTAssertFalse(parsed.hasText)
        XCTAssertTrue(parsed.hasFilters)
        XCTAssertNil(parsed.findText)
        XCTAssertEqual(parsed.highlightTerms, [])
        XCTAssertEqual(parsed.rankingTerms, [])
        XCTAssertTrue(parsed.matchesText(title: "anything", body: ""))
        XCTAssertFalse(parsed.matchesTitle("anything"))
        XCTAssertEqual(ParsedSearchQuery("alpha beta").findText, "alpha beta")
    }

    func testUnicodeTermsFoldCaseAndDiacriticsAndIdentifiersStayWhole() {
        let parsed = ParsedSearchQuery("Café \"Naïve Résumé\" 日本語 library.lock")
        XCTAssertEqual(parsed.words, ["Café", "日本語", "library.lock"])
        XCTAssertEqual(parsed.phrases, ["Naïve Résumé"])
        XCTAssertEqual(parsed.foldedWords, ["cafe", "日本語", "library.lock"])
        XCTAssertEqual(parsed.foldedPhrases, ["naive resume"])
        XCTAssertEqual(
            parsed.rankingTerms, ["cafe", "naive", "resume", "日本語", "library.lock", "library", "lock"])
        XCTAssertTrue(
            parsed.matchesText(
                title: searchFold("Notes"), body: searchFold("a CAFÉ, a naïve\n  résumé, 日本語 library.lock")))
        XCTAssertFalse(parsed.matchesText(title: "", body: searchFold("café naïve and résumé 日本語 library.lock")))
        XCTAssertEqual(ParsedSearchQuery("ÉTÉ été").rankingTerms, ["ete"])
    }

    func testPhrasesNeedAdjacentWordsAcrossAnyWhitespace() {
        XCTAssertTrue(ParsedSearchQuery.contains("the lock file is here", phrase: "lock file"))
        XCTAssertTrue(ParsedSearchQuery.contains("the lock\n\n\t file", phrase: "lock file"))
        XCTAssertFalse(ParsedSearchQuery.contains("the lock, file", phrase: "lock file"))
        XCTAssertFalse(ParsedSearchQuery.contains("file lock", phrase: "lock file"))
        XCTAssertFalse(ParsedSearchQuery.contains("lockfile", phrase: "lock file"))
        // A later occurrence of the first word completes the phrase.
        XCTAssertTrue(ParsedSearchQuery.contains("lock x lock lock file", phrase: "lock file"))
        XCTAssertTrue(ParsedSearchQuery.contains("anything", phrase: ""))
        XCTAssertTrue(ParsedSearchQuery.contains("one", phrase: "one"))
        XCTAssertFalse(ParsedSearchQuery.contains("", phrase: "one"))
        XCTAssertTrue(ParsedSearchQuery.contains("a b c d", phrase: "b c d"))
        XCTAssertFalse(ParsedSearchQuery.contains("a b c x d", phrase: "b c d"))
        XCTAssertTrue(ParsedSearchQuery.contains("日本語 テキスト", phrase: "日本語 テキスト"))
    }

    func testFiltersUseTheMemorySearchRules() {
        let typed = ParsedSearchQuery("type:Decision type:memory status:open")
        XCTAssertTrue(typed.admits(type: "decision", status: "OPEN", project: nil, path: "a.md", date: nil))
        XCTAssertTrue(typed.admits(type: "memory", status: "open", project: nil, path: "a.md", date: nil))
        XCTAssertFalse(typed.admits(type: "progress", status: "open", project: nil, path: "a.md", date: nil))
        // No envelope: drops out for type and status.
        XCTAssertFalse(typed.admits(type: nil, status: nil, project: nil, path: "a.md", date: nil))
        XCTAssertFalse(typed.admits(type: "memory", status: nil, project: nil, path: "a.md", date: nil))

        let project = ParsedSearchQuery("project:silkweb project:\"Side Work\"")
        XCTAssertTrue(project.admits(type: nil, status: nil, project: "Silkweb", path: "x.md", date: nil))
        XCTAssertTrue(project.admits(type: nil, status: nil, project: "side work", path: "x.md", date: nil))
        XCTAssertFalse(
            project.admits(type: nil, status: nil, project: "Other", path: "Memory/Projects/Silkweb/a.md", date: nil))
        // Without an envelope project: inside that project's Folder.
        XCTAssertTrue(
            project.admits(type: nil, status: nil, project: nil, path: "Memory/Projects/Silkweb/a.md", date: nil))
        XCTAssertTrue(
            project.admits(type: nil, status: nil, project: nil, path: "Memory/Projects/Side Work/b/c.md", date: nil))
        XCTAssertFalse(
            project.admits(type: nil, status: nil, project: nil, path: "Memory/Projects/Silkweb2/a.md", date: nil))
        XCTAssertFalse(
            project.admits(
                type: nil, status: nil, project: nil, path: "memory/projects/silkweb/a.md", date: nil,
                caseSensitive: true))

        let dates = ParsedSearchQuery("after:2026-10-01 before:2026-10-08")
        XCTAssertTrue(dates.admits(type: nil, status: nil, project: nil, path: "", date: date("2026-10-01")))
        XCTAssertTrue(dates.admits(type: nil, status: nil, project: nil, path: "", date: date("2026-10-07T23:59:59Z")))
        XCTAssertFalse(dates.admits(type: nil, status: nil, project: nil, path: "", date: date("2026-10-08")))
        XCTAssertFalse(dates.admits(type: nil, status: nil, project: nil, path: "", date: date("2026-09-30T23:59:59Z")))
        XCTAssertFalse(dates.admits(type: nil, status: nil, project: nil, path: "", date: nil))

        let tags = ParsedSearchQuery("tag:Research tag:ideas")
        XCTAssertTrue(tags.admits(tags: ["research"]))
        XCTAssertTrue(tags.admits(tags: ["IDEAS", "x"]))
        XCTAssertFalse(tags.admits(tags: ["research-old"]))
        XCTAssertFalse(tags.admits(tags: []))
        XCTAssertTrue(ParsedSearchQuery("x").admits(tags: []))
    }

    func testHighlightRangesCoverWordsAndWholePhrasesButNeverFilters() {
        let text = "Research notes: two words and research again"
        let ranges = SearchNavigation.matchRanges(in: text, parsing: "tag:research \"two  words\" notes")
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["two words", "notes"])
        // Quick Open keeps literal whitespace terms.
        XCTAssertEqual(SearchNavigation.matchRanges(in: text, query: "tag:research").count, 0)
        let (snippet, snippetRanges) = searchSnippet(
            text, terms: ParsedSearchQuery("tag:research \"two words\"").highlightTerms)
        XCTAssertEqual(snippetRanges.map { (snippet as NSString).substring(with: $0) }, ["two words"])
    }

    // MARK: BM25

    func testBM25MatchesTheFormulaWithFieldWeightsAndScopeLocalStatistics() {
        // A: title "alpha", body "beta". B: title "gamma", body "beta beta alpha".
        let statistics = KnowledgeTermStatistics(
            postings: [
                "alpha": ["A": KnowledgePosting(title: 1), "B": KnowledgePosting(body: 1)],
                "beta": ["A": KnowledgePosting(body: 1), "B": KnowledgePosting(body: 2)],
            ],
            lengths: ["A": KnowledgePosting(title: 1, body: 1), "B": KnowledgePosting(title: 1, body: 3)])
        let scores = KnowledgeBM25.scores(terms: ["alpha"], candidates: ["A", "B"], statistics: statistics)
        // df 2 of N 2.
        let idf: Double = log(1.0 + 0.5 / 2.5)
        // Title: tf 1 at the average length (1), weight 3.
        let titleTF: Double = 3.0 / (0.25 + 0.75 * 1.0)
        // Body: tf 1 in 3 tokens against an average of 2, weight 1.
        let bodyTF: Double = 1.0 / (0.25 + 0.75 * 1.5)
        XCTAssertEqual(scores["A"]!, idf * titleTF * 2.2 / (titleTF + 1.2), accuracy: 1e-12)
        XCTAssertEqual(scores["B"]!, idf * bodyTF * 2.2 / (bodyTF + 1.2), accuracy: 1e-12)
        XCTAssertEqual(scores["A"]!, 0.2865, accuracy: 0.0001)
        XCTAssertGreaterThan(scores["A"]!, scores["B"]!, "a title hit outweighs the same body hit")

        // Several terms add up, per term, in the given order: deterministic to the last bit.
        let both = KnowledgeBM25.scores(
            terms: ["alpha", "beta", "alpha"], candidates: ["B", "A"], statistics: statistics)
        let again = KnowledgeBM25.scores(
            terms: ["alpha", "beta"], candidates: ["A", "B", "A"], statistics: statistics)
        XCTAssertEqual(both, again)
        XCTAssertGreaterThan(both["B"]!, scores["B"]!)

        // Scope-local: a Document outside the candidates changes nothing, and alone A has no competitor.
        var wider = statistics
        wider.postings["alpha"]?["Hidden"] = KnowledgePosting(title: 9, body: 40)
        wider.lengths["Hidden"] = KnowledgePosting(title: 9, heading: 5, body: 900)
        XCTAssertEqual(KnowledgeBM25.scores(terms: ["alpha"], candidates: ["A", "B"], statistics: wider), scores)
        let alone = KnowledgeBM25.scores(terms: ["alpha"], candidates: ["A"], statistics: wider)
        XCTAssertEqual(alone["A"]!, log(1 + 0.5 / 1.5) * 3 * 2.2 / (3 + 1.2), accuracy: 1e-12)
        XCTAssertNil(alone["B"])

        // Unindexed candidates don't count; no candidates, no terms or no postings score nothing.
        XCTAssertEqual(
            KnowledgeBM25.scores(terms: ["alpha"], candidates: ["A", "B", "Unread"], statistics: statistics), scores)
        XCTAssertEqual(KnowledgeBM25.scores(terms: ["alpha"], candidates: [], statistics: statistics), [:])
        XCTAssertEqual(KnowledgeBM25.scores(terms: [], candidates: ["A"], statistics: statistics), [:])
        XCTAssertEqual(KnowledgeBM25.scores(terms: ["zzz"], candidates: ["A"], statistics: statistics), [:])
    }

    func testBM25RanksTitleThenHeadingThenBodyOnRealContent() throws {
        var graph = KnowledgeGraph()
        let documents = [
            ("Flock.md", "Nothing here.\n"),
            ("Heading.md", "# Flock\n\nNothing here.\n"),
            ("Body.md", "Nothing here but flock.\n"),
            ("Other.md", "Unrelated text.\n"),
        ]
        let listing = KnowledgeGraph.Listing(
            documents: documents.map { .init(path: $0.0, stamp: $0.0) }, folders: [], caseSensitive: false)
        for entry in graph.apply(listing) {
            graph.install(entry, content: KnowledgeContent(text: documents.first { $0.0 == entry.path }!.1))
        }
        let terms = ParsedSearchQuery("FLOCK").rankingTerms
        let scores = KnowledgeBM25.scores(
            terms: terms, candidates: documents.map(\.0), statistics: graph.termStatistics(for: terms))
        let order = scores.sorted { $0.value > $1.value }.map(\.key)
        XCTAssertEqual(order, ["Flock.md", "Heading.md", "Body.md"])
        XCTAssertNil(scores["Other.md"])
        // The permitted view drops hidden postings and lengths.
        let scope = try AgentScope(
            grant: AgentGrant(project: "P", library: LibraryLocation(path: "/tmp/Library"), access: .read))
        XCTAssertEqual(
            PermittedKnowledgeGraph(graph: graph, scope: scope).termStatistics(for: terms),
            KnowledgeTermStatistics())
    }
}
