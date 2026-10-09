# Silkweb Knowledge Graph Retrieval Contract

```text
retrieval_contract_version: 1
Last reviewed: 2026-10-08 (#175)
```

This contract fixes the vocabulary, scope rules, compatibility promises, budgets and evaluation set
for the knowledge-graph tickets in #173 (#176–#184, #140–#142, #30, #32). Those tickets link here
and use these names as they are; they never rename them. Grants, envelopes, `memory_search` and
`memory_read` stay defined in [`agent-memory.md`](agent-memory.md). This document only adds to them.
Changing a rule here means bumping `retrieval_contract_version` (see [Versioning](#versioning)).

## Overview

- The Markdown files are the source of truth. Every index, adjacency list and score is a
  **disposable cache** built from them. Deleting a cache only costs a rebuild and never loses a
  relation. (Obsidian works the same way: links and backlinks are navigation built from the files,
  not extracted truth. Silkweb copies the behaviour only.)
- Agents get **evidence, not answers**. Retrieval returns Documents and Sections with their path,
  revision and the reason they were included. It never writes a summary that claims something the
  files don’t say.
- **Scope comes first** for every computation, exactly as in `agent-memory.md` › Grants.
- The default `memory_search` keeps its #134 behaviour. Graph and ranked retrieval are opt-in modes
  (see [Compatibility](#compatibility-memory_search-v1)).

## Units

| Unit | Identity | Notes |
|---|---|---|
| **Document** | `path` (Library-relative POSIX), plus `documentId` (app UUID, may be `null`) and `memoryId` (envelope, may be `null`) | One `.md` file. Every result, relation end and citation names a Document by `path`. |
| **Section** | Its Document’s `path` and `revision`, `headings` (the heading texts from the top level down to this Section) and `range` (UTF-8 byte offsets `[start, end)` in the body after the envelope) | The text under one heading, up to the next heading of the same or a higher level. Text before the first heading is a Section with `headings: []`. |

- Ranking and relations work on Documents. Sections are the unit for passages and citations: a
  later context bundle (#181) quotes Sections, never arbitrary character windows.
- A citation is valid only for the `revision` it names. A tool re-reads a file and checks the
  revision before quoting it. If the file changed, the tool either retries once or leaves the Section
  out and says so.
- Envelope text is never part of a Section. A Document whose envelope is malformed or newer has no
  Sections and matches by title only (#132 reading rules).
- **Naming.** Human-facing copy says **Document** and **Section**, never “note”, “chunk” or “node”
  (`design-system.md` › Naming). “Chunk” may appear only in internal type names.

## Relations

Four relation kinds. These identifiers and labels are fixed:

| `kind` | Graph edge? | Stored in the index? | Comes from | Label, outgoing / incoming (#30, #184) |
|---|---|---|---|---|
| `links_to` | **Yes** | Yes | An explicit Markdown link or a resolved wikilink | “Links to” / “Linked from” |
| `supersedes` | **Only when the owner accepted it** | The claim, plus the acceptance from app metadata | The envelope `supersedes` list (`memory_id`s) | “Replaces” / “Replaced by” |
| `mentions` | No | No, computed on demand | The plain-text title of another Document, not inside a link | “Unlinked mention” |
| `similar` | No | Never | Lexical (and, after #142, optional semantic) similarity | “Related” |

**Only `links_to` and accepted `supersedes` are graph edges.** Nothing else is traversed, counted as
a backlink or shown as a link. “Related” is reserved for `similar`. A shared Folder, Tag, project or
session is not a relation. It may be a filter or a small ranking signal, but it never appears as a
relation or as “Related”.

### `links_to`

- **Sources:** inline links `[text](target.md)` (including `<target with spaces.md>`,
  percent-encoding and a `#fragment`), reference links, and wikilinks `[[Name]]`, `[[Name|alias]]`
  and `[[Name#Heading]]`. The target is a Library-relative path after resolution.
- **Not edges:** images, external URLs, links inside code spans or code blocks, links to
  non-Markdown files, links from a Document to itself, and links in the envelope.
- **Resolution (#176):** a relative path resolves from the linking Document’s Folder. A wikilink
  resolves by Document name. A link that resolves to no Document (broken) or to more than one
  (ambiguous) is not an edge. It is reported as a link diagnostic on its source Document.
- Several links from one Document to the same target are one edge. A link with a `#fragment` keeps
  the heading as the edge’s `section`.
- Silkweb reads, resolves and rewrites wikilinks, but writes standard Markdown links (#173 owner
  decision, #182).

### `supersedes`

- An envelope `supersedes` value is a **claim** by the Document’s author. A claim alone is never an
  edge, never demotes the Document it names and is never shown as “Replaces”.
- The claim becomes an edge only when the owner **accepts** it (#173 owner decision, #141). The
  acceptance names the revision of the superseding Document. Editing that Document voids the
  acceptance until the owner accepts again. Reviewing a Document doesn’t accept its claims.
- An accepted successor accompanies or comes before its predecessor in current-context results. A
  direct lookup still returns the predecessor itself. Historical queries can still retrieve it.
- **Compatibility note:** `memory_search` v1 (#134) sinks a Document superseded by a *reviewed*
  Document to the bottom of its tier. That rule stays in the default mode (see
  [Compatibility](#compatibility-memory_search-v1)). Graph-era modes use acceptance instead.

### `mentions` and `similar`

- `mentions` are computed when asked for (Document Info, #30), from the permitted set only. They are
  suggestions to link and are never stored or traversed.
- `similar` is ephemeral. It is computed per request, never stored as an edge, never traversed,
  and never establishes truth, chronology, permission or review state.

### Retrieval reasons

Every result a graph-era tool returns (#180, #181) carries `reasons`: a list of
`{ "kind", "direction", "via" }`.

- `kind` is one of the four kinds above.
- `direction` is `out` (this result is the target, like “Links to”) or `in` (this result is the
  source, like “Linked from”).
- `via` is the `path` of the permitted Document the relation was reached from.

A direct text match keeps the existing `matchKind` field and adds no reason. The order of `reasons`
follows the traversal order.

## Scope

- **Scope first.** Candidates, BM25 statistics (document frequencies, average lengths), traversal,
  in-degree, mentions and similarity are all computed over the Documents the grant can read, after
  MCP roots and request filters narrow them. A hidden Document never changes a score, a count, a
  truncation signal or a budget.
- **No hidden titles, counts or edge existence.** An edge to an out-of-scope Document is simply
  absent. It never shows as “1 hidden link”, and a backlink count counts permitted sources only.
- **No hidden hops.** Every intermediate Document on a path must be permitted. A hidden Document can’t
  connect two permitted ones.
- **Document text is not redacted.** A permitted Document’s own text may contain a link to an
  out-of-scope path. That text is returned like any other text, but no tool resolves the link,
  reports a title for it or says whether it exists.
- **Refusals reuse #130 word for word.** A graph request that starts from an out-of-scope path
  returns `out_of_scope`: “That location is outside this grant’s read folders (Memory › Projects ›
  Silkweb).” One that starts from an out-of-scope ID returns `not_found`, like an unknown ID (#178).
  Whether the target exists is never revealed.
- Hidden items and symbolic links are never followed or listed, as in `agent-memory.md` › Grants.
- Caches and query caches are keyed by the effective scope and are never shared across grants.

### Permitted graph

Every helper retrieval goes through one permitted graph view (#178, `PermittedKnowledgeGraph`). A
narrowed grant reads like a smaller Library, never like a Library with holes in it:

- Out-of-scope Documents are **absent**. There are no placeholders, “1 hidden link”, `null` titles or
  `hiddenCount`/`omitted` fields.
- `total`, degrees and link counts, `index.indexed`/`index.total`, `skipped`, and truncation signals
  (`nextCursor`, `truncated`, budget notes) are computed on the permitted Documents only. A path that
  connects only through a hidden Document doesn’t exist; it isn’t reported as blocked or over budget.
  A hidden Document that is still being indexed never makes a permitted answer wait.
- Empty results reuse the `memory_search` messages. There’s no scope-specific variant.
- **IDs** (`documentId`, `memoryId`, graph seeds): unknown and out-of-scope both return `not_found`
  with the same code, title, message and exit status. **Paths** keep `out_of_scope`, decided from the
  path string before the disk is touched; `invalid_path` stays the one message for links, `..` and
  substitution. See `agent-memory.md` › [Refusals](agent-memory.md#refusals).
- **Cursors** name the effective scope, the permitted Documents’ revisions and the request. One from
  wider roots, an edited grant, or a permitted Document that has changed since fails with
  `invalid_argument` (“That cursor has expired. Search again without “cursor”.”), one message for
  every reason. A change to a hidden Document never expires one. The first page afterwards is fresh,
  with no warning or flag. A read cursor keeps `stale_snapshot` for a changed file, and a revoked
  grant stays `grant_revoked`.
- **Caches** are keyed by the effective scope: narrower MCP roots or grant folders start a fresh graph
  in the grant’s `<grant-id>.knowledge/` instead of reusing one built for a wider scope.
- **Cancellation** returns the existing MCP cancellation response with no partial results.
- The app’s own backlinks and graph (#30, #184) show the owner’s full Library and are not filtered.

## Ranking signals

The signals below are allowed. The numbers are **starting points from the #173 research**, not
tuned values. They change only through evaluation on the development split (see
[Evaluation set](#evaluation-set)).

| Signal | Starting point | Notes |
|---|---|---|
| Lexical | Field-weighted BM25, `k1 = 1.2`, `b = 0.75`, title 3, heading 2, body 1 (#179) | Exact identifiers stay whole tokens as well as their parts. No stemming of identifiers. |
| Graph | One hop through `links_to` (both directions), optional second hop, decay `0.5^(hops-1)`; weights: accepted `supersedes` 1.0, `links_to` 0.7 (#180) | Hubs (high in-degree) expand less. |
| Fusion | Weighted reciprocal-rank fusion, constant 60; lexical 1.0, graph 0.6, semantic 0.8 | Missing ranks contribute zero. |
| Lifecycle | Accepted superseded: strong demotion | Claims never demote. |
| Review and pin | Reviewed current revision, pinned: small boosts | A pin never cancels an accepted supersession. |
| Type and recency | Type prior per query intent; recency half-life 14 days for progress, 30 for handoffs, much weaker for decisions | Future-dated claims get no extra boost. |
| Centrality | Capped log in-degree from distinct permitted sources | Small weight; removed if it biases toward popular Documents. |

Policy rules sit above any formula:

- A direct lookup (exact title, path or `memory_id`) returns the requested Document, including a
  stale one and any permitted successor.
- An unreviewed claim can’t demote reviewed evidence.
- Ties break deterministically, as in #134: by `documentId`, then `path`.
- Every ranked mode reports a `ranking_version` string. Changing any weight changes it.

## Compatibility (`memory_search` v1)

The default `memory_search` request, with no new parameter, keeps every #134 rule in
`agent-memory.md` › Search and read:

- Every word must appear in the title or the body after the envelope, ignoring case and diacritics.
- Same filters, scope rule, limit, ranking tiers and tie-breaks, result fields and field order,
  `total` (matching in-scope Documents before `limit`), freshness and `message` strings.
- The `memory_id`, envelope keys and links aren’t searchable text in this mode.

`RetrievalBaselineTests` freezes this: the ranked paths and totals of all 200 golden queries are
compared with `docs/knowledge-graph-eval/baseline-134.json`, and any change fails the suite.

New behaviour is **opt-in**:

- A new mode is a new request parameter, for example `mode: "ranked"` (BM25, #179) or
  `expand: "links"` (#180), or a new tool such as `memory_context` (#181). An unknown value is
  `invalid_argument`. Nothing changes for callers that don’t send it.
- A response from a new mode echoes `mode`, `ranking_version` and `retrieval_contract_version`.
- `total` never counts Documents found only by expansion. Expanded results are listed separately,
  each with its `reasons`.
- `memory_capabilities` gains `retrieval_contract_version` and `retrieval_modes` when the first mode
  ships (#179). Clients feature-detect these fields and never assume a mode from the helper version.
- Files saved by earlier builds keep loading: the helper’s `agent-index` cache stays `version: 1`
  until a ticket changes it. Any new graph or BM25 cache is versioned, decodes tolerantly, and is
  discarded and rebuilt when it’s from a newer version (as in `agent-memory.md` › Helper index cache).

## Budgets

These are **targets** from the #173 research, not measurements. The reference machine is an M1 with
16 GB on macOS 15. The benchmark fixture has 10,000 Documents, 1,000 Folders, about 100 MB of
Markdown, 50,000 Sections and 100,000 explicit edges, plus a separate high-degree hub fixture.

| Operation | Warm p95 target |
|---|---:|
| Backlinks or one-hop neighbors, 50 results | ≤ 50 ms |
| BM25 search, 50 results | ≤ 100 ms |
| Graph expansion and reranking | ≤ 50 ms |
| Revision check and packing | ≤ 150 ms |
| `memory_context` end to end, resident MCP, no embeddings | ≤ 400 ms |
| Semantic context after model warm-up | ≤ 650 ms |
| Cached one-shot CLI search | ≤ 1 s |
| Saved change reflected | ≤ 1 s after the file event |
| Cold or large refresh | Honest `indexing` status within about 2 s, then incremental |

Work limits per request: 10–20 seeds; one hop by default and two at most; at most 200 candidate
Documents, 1,000 examined permitted edges and 20 ordinary neighbors per seed. A context bundle
defaults to about 4,000 tokens, at most 12 Documents and two Sections per Document, with an
independent byte ceiling. Work is bounded by bytes and edges, not just Document counts. Tools
report latency by stage: enumeration, cache decode, parse, rank, file reads and serialization.

## Evaluation set

The golden set lives in `docs/knowledge-graph-eval/`:

| File | Contents |
|---|---|
| `library.json` | The fixture library (`version: 1`): `project`, named `grants` and `documents` |
| `dev.json` | Development split (`version: 1`, 120 queries) |
| `heldout.json` | Held-out split (`version: 1`, 80 queries) |
| `baseline-134.json` | The raw #134 run: ranked paths, totals and latency per query, the summary, resources |

All files use sorted keys. The fixture library is generated into a temporary folder by
`RetrievalBaselineTests`, never into `Test_Library/`. It holds 71 Documents for the project
“Harbor”: decisions, memories, progress and handoffs with envelopes; plain Documents; Markdown links
and wikilinks (with an alias, a broken link and a 21-link hub); five supersession chains; ten
malformed-metadata cases; eight prompt-injection Documents (`"injection": true`); and ten
Documents outside the default grant (a sibling project `Harbor2`, a prefix sibling `HarborArchive`,
another project, private journal notes, a hidden `.drafts` Folder, and reference Folders). Every
Document outside a grant carries a unique `canary` string. Grant `harbor` reads
`Memory/Projects/Harbor`; grant `harbor-reference` adds `Reference/Harbor`.

Each query has `id`, `query`, `category`, `grant`, `expected` (the evidence Documents, by path) and
`forbidden` (paths that must never appear). `expected` lists every Document needed for a complete
answer, so a multi-hop query names two or three.

| `category` | Queries | What it probes |
|---|---:|---|
| `exact` | 30 | Titles, identifiers (`library.lock`, `notarytool`), `memory_id`s |
| `paraphrase` | 35 | The same need in other words (“stop two processes writing the library at the same time”) |
| `multi-hop` | 25 | Evidence split across linked Documents, backlinks and two-hop chains |
| `supersession` | 25 | Accepted successors, unaccepted claims, an acceptance voided by an edit, historical lookups |
| `malformed-metadata` | 20 | Malformed, newer, foreign, BOM and CRLF front matter; duplicate keys; bad values |
| `injection-neighbor` | 20 | Prompt injection in Documents that look highly relevant |
| `scope-leak` | 25 | Answers that exist only outside the grant; positive controls with `harbor-reference` |
| `unanswerable` | 20 | No in-scope Document answers; `expected: []` |

**Splits.** Within each category, two of every five queries (in authoring order) are held out: 80
held-out and 120 development queries. Implementation tickets tune only on `dev`. They report
held-out results as aggregate gates and never change a held-out query, its `expected` list or the
fixture to improve a score. Changing the set bumps its `version` and re-records the baseline in the
same PR, with the reason.

**Metrics** (per category and overall, per split):

- **Recall@k** (k = 5, 10, 20): the share of `expected` found in the top k, averaged over queries
  with evidence.
- **MRR@10:** 1 / rank of the first expected Document in the top 10, or 0.
- **Evidence complete:** every expected Document is in the top 10.
- **No results:** queries that returned nothing. That’s the right outcome for `unanswerable`.
- **Injection first:** queries with evidence where an injection Document ranks above the first
  expected Document.
- **Scope:** a leak is a forbidden or out-of-grant path, or an out-of-grant canary in a title or
  excerpt, anywhere in the returned results. Every query is checked, and the result is written as
  “0 leaks / N probes”, never as a rate.
- **Latency:** the median of five warm runs per query, then p50 and p95 across the category. Also
  recorded: per-stage medians, cold build time, cache size and process peak memory.

**Release gates** for any new mode: 0 leaks on every query; no stale-as-current failure on the
supersession fixtures; every citation names a valid revision; no material regression on `exact`; and
a clear held-out improvement before a mode becomes a default anywhere. #142 additionally requires at
least +10 points of Recall@10 on held-out `paraphrase`.

## Baseline (#134)

`memory_search` contract v1, default request, `limit: 50`, both fixture grants, review state from the
fixture. Recorded 2026-10-08 on a Mac16,5 (16 cores, 48 GB, macOS 15.7.9) in the test process.
Raw results: `docs/knowledge-graph-eval/baseline-134.json`.

**Development (120 queries)**

| Category | Queries | Recall@5 | Recall@10 | Recall@20 | MRR@10 | Evidence complete | No results | Injection first | p50 ms | p95 ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `exact` | 18 | 0.889 | 0.889 | 0.889 | 0.833 | 89% | 2 | 0 | 2.35 | 2.85 |
| `paraphrase` | 21 | 0.048 | 0.048 | 0.048 | 0.048 | 5% | 20 | 0 | 2.19 | 2.27 |
| `multi-hop` | 15 | 0.000 | 0.000 | 0.000 | 0.000 | 0% | 15 | 0 | 2.33 | 2.76 |
| `supersession` | 15 | 0.400 | 0.400 | 0.400 | 0.433 | 33% | 7 | 2 | 2.28 | 2.78 |
| `malformed-metadata` | 12 | 0.917 | 0.917 | 0.917 | 0.917 | 92% | 1 | 0 | 2.25 | 2.38 |
| `injection-neighbor` | 12 | 0.792 | 0.792 | 0.792 | 0.792 | 75% | 0 | 3 | 2.31 | 2.87 |
| `scope-leak` | 15 | 1.000 | 1.000 | 1.000 | 1.000 | 100% | 13 | 0 | 2.24 | 2.70 |
| `unanswerable` | 12 | — | — | — | — | — | 12 | 0 | 2.16 | 2.34 |
| **Overall** | 120 | 0.479 | 0.479 | 0.479 | 0.474 | 46% | 70 | 5 | 2.26 | 2.68 |

Scope: 0 leaks / 15 probes (all 120 queries checked).

**Held-out (80 queries)**

| Category | Queries | Recall@5 | Recall@10 | Recall@20 | MRR@10 | Evidence complete | No results | Injection first | p50 ms | p95 ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `exact` | 12 | 0.917 | 0.917 | 0.917 | 0.917 | 92% | 1 | 0 | 2.35 | 2.82 |
| `paraphrase` | 14 | 0.000 | 0.000 | 0.000 | 0.000 | 0% | 14 | 0 | 2.27 | 2.36 |
| `multi-hop` | 10 | 0.033 | 0.033 | 0.033 | 0.100 | 0% | 9 | 0 | 2.17 | 2.37 |
| `supersession` | 10 | 0.000 | 0.000 | 0.000 | 0.000 | 0% | 9 | 0 | 2.24 | 2.54 |
| `malformed-metadata` | 8 | 0.625 | 0.625 | 0.625 | 0.625 | 62% | 3 | 0 | 2.21 | 2.48 |
| `injection-neighbor` | 8 | 0.500 | 0.500 | 0.500 | 0.438 | 50% | 0 | 4 | 2.31 | 2.74 |
| `scope-leak` | 10 | 1.000 | 1.000 | 1.000 | 1.000 | 100% | 7 | 0 | 2.26 | 2.56 |
| `unanswerable` | 8 | — | — | — | — | — | 8 | 0 | 2.33 | 2.52 |
| **Overall** | 80 | 0.359 | 0.359 | 0.359 | 0.362 | 35% | 51 | 4 | 2.27 | 2.62 |

Scope: 0 leaks / 10 probes (all 80 queries checked).

`scope-leak` recall covers only its positive controls (queries with `expected` evidence under
`harbor-reference` or in scope). `unanswerable` has no evidence, so only “No results” applies.

**Observations**

- **All-words matching.** Recall@5, @10 and @20 are equal: a query either matches a few Documents or
  none. 121 of 200 queries return nothing, which is right for all 20 `unanswerable` queries but
  wrong for nearly every `paraphrase` and `multi-hop` query. No single Document holds every word of
  a question whose evidence spans linked Documents.
- **Identifiers.** `memory_id` lookups (`hb_gate`, `hb_cache_v2`, `hb_pdf_v1`) find nothing because
  the envelope isn’t searchable text.
- **Supersession.** Natural-language lifecycle questions mostly return nothing. Where they do match,
  an unaccepted claim (“Last writer wins for conflicts”) or an injection Document can rank first.
- **Malformed metadata.** Documents with `envelope_malformed` or `envelope_schema_newer` match by
  title only (#132). Body queries for them return nothing. Front matter behind a byte order mark
  reads as no envelope. An unknown `type` or a non-timestamp `created_at` still reads as an
  envelope. `baseline-134.json` records the reading outcome of each fixture Document.
- **Injection.** 7 of 20 `injection-neighbor` queries rank an injection Document above the evidence.
  Retrieved text is untrusted (see `agent-memory.md` › Supported operations); ranking must not reward
  it.
- **Scope.** 0 leaks / 25 probes, with all 200 queries checked. Sibling-prefix projects, hidden
  Folders, links to out-of-scope Documents and canaries never surface.
- **Latency and resources.** The 71-Document fixture answers in about 2.3 ms warm (p95 under
  3 ms). Per-stage medians: grant check under 0.01 ms, refresh walk about 1.5 ms, ranking about
  0.85 ms. A cold build takes 20–35 ms. The cache is about 35 KB, and peak memory for the whole test
  process is 66 MB. These figures don’t predict the 10,000-Document budget; the scale check stays in
  `AgentMemorySearchTests` and later tickets measure against [Budgets](#budgets) on the benchmark
  fixture.

## Versioning

| Change | Version |
|---|---|
| A new opt-in mode, request parameter, result field, tool or relation `kind` | `retrieval_contract_version` + 1 |
| Renaming or removing a `kind`, label, field or mode | Not allowed. Add a new one and deprecate the old one. |
| New weights or signals inside an existing mode | `ranking_version` changes; held-out gates rerun |
| Any change to the default `memory_search` matching, ranking, `total` or fields | `contract_version` in `agent-memory.md` + 1, a new `baseline-134.json` and an owner decision |
| A change to the golden set or the fixture library | The file’s `version` + 1 and a re-recorded baseline in the same PR |
| A new or changed cache format | That cache’s own `version`, with tolerant decoding and a rebuild on a newer version |

To re-record the baseline, delete or empty `baseline-134.json` and run
`./scripts/build.sh test --filter RetrievalBaselineTests`. It writes a new file and fails once; the
next run compares. Update the tables above from the new file in the same change.
