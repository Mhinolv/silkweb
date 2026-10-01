# Silkweb product research: an offline MWeb rebuild

Research date: 2026-10-01. Installed reference: MWeb 4.8.2 (1148). Scope: read-only bundle inspection and built-in web search; no applications launched, GUI tools used, personal notes accessed, or MWeb implementation/assets copied.

## Executive Summary

Build one native Mac writing library whose hierarchy is the actual directory hierarchy. MWeb already offers nested categories **and** a separate Folders mode with real filesystem operations. The defensible gap is the separation of its category-based note library from its file-based workflow, not an absence of folders everywhere. Silkweb should combine folder ownership, tags, search, and editing in one place.

The checked-out product really is a skeleton: one version constant, one SwiftUI text window, and one version test. There is no existing editor or library to preserve. The proposed 25-ticket sequence delivers safe storage first, folder organization next, then writing, preview, retrieval, export, and polish. This is a proposed Core release, not full MWeb parity. Advanced publishing is excluded; advanced renderers and book exports are explicitly Later.

Evidence legend: **D** = documented behavior in official/bundled help; **L** = local metadata or localization evidence (feature surface, not a runtime test); **I** = recommendation/inference; **U** = unverified. Core/Later/Skip are Silkweb product recommendations, not MWeb license tiers. No claim of runtime verification is made.

## MWeb Overview

MWeb is a Markdown editor, note library, and publishing application for macOS/iOS/iPadOS. Its Mac architecture is advertised as AppKit. The installed Info.plist identifies `com.coderforart.iOS.MWeb`, version 4.8.2, build 1148, minimum macOS 10.13. The executable contains Intel and Apple Silicon architectures. Official Pro pricing currently advertises $34.99 lifetime; that is a web-store offer, not a verified entitlement or purchase price for this installed edition. [Official overview](https://www.mweb.im/), [release notes](https://www.mweb.im/download).

Local inspection establishes:

- Document registrations: Markdown (`net.daringfireball.markdown`), TextBundle (`org.textbundle.package`), plain text/data. Registered filename extensions include md, markdown, mdown, mkd, mdwn, rmd, rst, txt, text, taskpaper, tex. Registration does **not** prove specialized rendering for every extension.
- URL schemes include `mwebapp`, `mweblib`, and authentication callback schemes. A URL scheme is not evidence of an unrestricted automation API.
- Linked system libraries include AppKit/Cocoa, WebKit, JavaScriptCore, SQLite, CoreData, CloudKit, ImageIO, Security, StoreKit, Quartz, and PDFKit (arm64 listing). Linkage alone cannot identify which library implements each feature.
- Resource directories identify MathJax, Mermaid, ECharts, highlight.js, Prism, flow/sequence diagrams, Viz, Turndown, editor themes, preview styles, and static-site templates. Their presence does not prove all remain active. Current docs explicitly describe MathJax, Mermaid and ECharts; the 4.8.2 release notes report Mermaid 11.14.0. No KaTeX evidence found in the inspected filenames.
- No `Contents/Frameworks` or `Contents/PlugIns` directory exists in this installed bundle. No `NSServices` declaration appeared in Info.plist. Thus no bundled Quick Look/Share extension was found; this does not establish what other installed apps provide.
- Info.plist declares unrestricted App Transport Security loads. The entitlement command produced no readable entitlement payload; sandbox status is **U**, not inferred from bundle ID. CloudKit linkage and documentation establish a sync capability, not its configured state.
- Resources include English, Simplified Chinese, and Traditional Chinese localization files, `Main.storyboardc`, `Library.storyboardc`, and named settings/export/editor dialogs. Nib/storyboard **names only** were inspected, never their compiled contents. JS/CSS/theme/template filenames were inspected, not implementation contents.

### Repository and issue audit

Read `AGENTS.md`, `Package.swift`, all three Swift source/test files, and listed repository files including hidden paths outside build/git output. `README.md` is absent; no release/review documents were found. The initial branch is `team/roadmap` with a clean worktree.

`bd list --status=open` failed because there is no `.beads` directory; `.beads/issues.jsonl` is also absent. **There are no locally inspectable issue IDs to exclude or reference.** This is not proof that another worktree or external tracker has no tickets. The PM must deduplicate again when importing this roadmap; this research creates no issues and initializes no tracker.

## Feature Inventory

Local evidence references below: **L1** Info.plist; **L2** English Localizable.strings; **L3** resource names; **L4** linked libraries; **L5** preference key names only; **H** bundled English help. See Sources for exact paths. Short menu labels identify the surface; descriptive text below is original paraphrase.

### Library, organization, search, and tags

| Capability | MWeb evidence and behavior | Silkweb decision |
|---|---|---|
| Local library | D/H: library has `docs`, `mainlib.db`, and publishing metadata; categories/tags live in DB | **Core:** real folders and `.md`; versioned JSON for app metadata (#1) |
| Nested categories | D/H, L2: parent/subcategories; notes can belong to several categories | **Core:** replace ownership with exactly one physical parent; tags provide multiple classifications (#2–8, #21) |
| External folders | D/H: separate Folders window; create, rename, delete files/folders; per-root media settings | **Core:** unified library root, no second organizational mode (#4–8) |
| Sorting | L2: title, creation/modification date both directions, custom drag order | **Core:** name/date sort and counts (#9); **Later:** manual ordering |
| Pinning | L2: pin/unpin note commands | **Later:** not required for basic folder navigation |
| Trash | L2: library Trash and permanent-empty warning; external folder deletion uses system Trash | **Core:** macOS Trash, never silent permanent deletion (#8) |
| Document references | D/H: copy note link and command-click navigation; L2: links/backlinks surface | **Core:** standard relative file links and safe movement (#7, #15); **Later:** backlink browser |
| Tags | D: document information edits tags; library/category tag filters | **Core:** editable tags with folder-scoped filtering (#21) |
| Library search | D: full text in library and external folders, quick search; category/title/tag constraints | **Core:** cancellable text/title/folder search (#19–20); **Later:** advanced query grammar |
| In-document find | L2: find, next/previous, replace, replace all | **Core:** native find/replace (#13) |
| Import | D/H: Markdown files/folders; folder import can bring referenced images | **Core:** preserve imported nested structure and local assets (#10) |
| Export library/category | D: category export can create directories; category PDF/ePub compilation | **Core:** files already portable; **Later:** compilation/batch export |
| Quick Note | H/L2: quick capture window/global shortcut; recurring note intervals | **Later:** ordinary New Document first |
| Recovery and backup | D/L2: local backup preferences, version browsing, library restore; settings describe up to three backup destinations | **Core:** atomic autosave and conflict preservation (#3, #5, #11); **Later:** scheduled snapshots and history UI |

### Editor

| Capability | MWeb evidence and behavior | Silkweb decision |
|---|---|---|
| Markdown source editing | D/H: source remains visible; formatting assists via Syntax menu/toolbar | **Core:** NSTextView source editor with undo and selection preservation (#5, #12) |
| Syntax styling | D/L2: theme entries for headings, links, code, footnote definitions/references | **Core:** incremental Markdown styling (#12); **Later:** broad embedded-language highlighting |
| Formatting commands | D/H/L2: heading levels, emphasis, strong, strike, quote, code, links, lists, math | **Core:** common constructs via shared menu/toolbar commands (#12); **Later:** math UI |
| Lists/indentation | L2: indentation, spaces instead of tabs, automatic ordered-list numbering | **Core:** list continuation and indent/outdent (#12); **Later:** whole-list renumbering |
| Tables | D/H: table insertion and editing; local labels expose row/column/alignment actions | **Core:** insert a rectangular pipe table and edit it as source (#14); **Later:** graphical cell editor |
| Images/attachments | D/H: paste/drag/import images; editor display modes include inline, thumbnail, overlay, hidden | **Core:** local paste/drop and relative links; preview displays assets (#15, #18); **Later:** inline image layout modes |
| Paste | D/H/L2: normal paste, plain text, PNG, HTML-to-Markdown; network image download | **Core:** plain text and image paste (#5, #15); **Later:** HTML conversion; **Skip:** automatic remote retrieval |
| Image width | D/H: MWeb-specific width suffix in alt text | **Later:** optional import compatibility; do not make proprietary syntax the default |
| Focus/typewriter | L2: focus toggle and scrolling threshold preference | **Later:** precise dimming behavior is U without runtime observation |
| Word/character counts | L2: whole document and selection totals | **Core:** debounced counts (#25) |
| Spelling/substitutions | L2: native spelling/grammar, automatic correction, smart punctuation, replacement, speech | **Core:** standard text services through NSTextView (#5); **Later:** dedicated settings for each |
| Date/time insertion, image combination | L2 and release notes: insertion commands; H: multiple images combined | **Later:** convenience tools |

### Preview and rendering

| Capability | MWeb evidence and behavior | Silkweb decision |
|---|---|---|
| Base Markdown | D/H: CommonMark-oriented implementation | **Core:** explicitly bounded grammar first (#16); full CommonMark conformance is **Later**, not promised by a regex renderer |
| GFM and extensions | D/H: strike, task lists, tables, footnotes | **Core:** these named extensions (#17). Footnotes are a separate extension; do not call them part of the formal GFM specification |
| Split/preview-only | D/H: editor/preview toggle and simultaneous panes | **Core:** three view states (#18); scroll synchronization **Later** |
| Outline / TOC | D/H: heading/asset outline, dock left/right or floating; `[TOC]` | **Core:** heading navigation and generated TOC (#17–18); extra placements/assets **Later** |
| Code blocks | D/H, L3: fences and code coloring resources; L2: optional preview line numbers | **Core:** readable escaped code blocks (#16); language coloring/line numbers **Later** |
| Math | D/H: MathJax; code-style math and optionally dollar delimiters; equation numbering settings | **Later:** a separate renderer issue must explicitly allow an independently obtained dependency |
| Diagrams/charts | D/H: Mermaid and ECharts; L3 also has legacy flow/sequence/Viz assets | **Later:** Mermaid first if justified; active legacy behavior **U** |
| Themes | D/H: light/dark editor and preview themes; custom CSS support | **Core:** fresh system-aware light/dark styles (#24); custom theme authoring **Later** |
| Line breaks, autolinks, typography | L2: newline rendering, automatic links, smart punctuation, figure captions | **Core:** explicit newline policy and autolinks (#16–17); extra typography **Later** |
| Raw HTML | Full behavior/security policy **U** in this inspection | **Core:** escape unsupported/raw active content; no document scripts or network loads (#16, #18) |

### Import, output, publishing, sync

| Capability | MWeb evidence and behavior | Silkweb decision |
|---|---|---|
| Markdown / TextBundle | L1/L2: document types; Markdown/TextBundle export entries | **Core:** Markdown folder interoperability (#1, #10); **Later:** TextBundle |
| HTML export | D/H: a single HTML file can embed local images | **Core:** self-contained single-document HTML with original styling (#22) |
| PDF | D/H/L2: single or multiple notes, theme/font options and TOC; 4.8.2 expands theme choice | **Core:** single-document print/PDF (#23); **Later:** books and custom pagination |
| RTF / rich-text copy | D/H: sharing into rich-text apps including images | **Later** |
| DOCX | D/H/L2: native export limitations for images (local alert also mentions LaTeX); optional installed Pandoc route | **Later:** do not promise lossless Word export |
| ePub | D/H/L2: single/category export, title/author/cover inputs | **Later:** dedicated packaging work |
| Image export | D/H/L2: export/copy rendered document image | **Later** |
| Non-Markdown import | DOCX/ePub inbound conversion not established by export commands | **U; Later only after evidence and scope** |
| Blogging | L2/L3: WordPress, Blogger, Medium, Tumblr, Ghost, Evernote, WizNote, Yuque, SSPAI dialogs | **Skip:** online publishing; resource presence does not verify current service APIs |
| Image hosting | L2: S3 and several regional/custom upload providers | **Skip** |
| Static-site generation | D/H/L3: site categories, themes, build output and scripts | **Skip** for this writing rebuild, although generation itself can be offline |
| Script/Pandoc integration | D/H/L2: configurable external scripts | **Skip** in Core; no automatic tool execution |
| Cloud sync | D: MWeb 4 uses CloudKit private storage, distinct from older iCloud Drive library storage | **Skip:** Silkweb adds no account or sync service. User-managed disk locations do not imply sync correctness |
| Mobile apps | D: iOS/iPadOS edition | **Skip:** macOS 15+ rebuild only |

### Settings, menus, shortcuts, and windows

| Surface | Evidence | Silkweb classification |
|---|---|---|
| General/editor preferences | L2/L5: line width/spacing/insets, image display, ordered lists, tab spacing, clickable links, quick-note shortcuts | **Core:** text font/size/spacing/width (#24); remaining preferences **Later** |
| Appearance | L2/L5: system light/dark matching, separate theme names, editor/preview/UI font choices | **Core:** appearance + editor/preview typography (#24); multi-font/theme editor **Later** |
| Library/backup | L2: choose existing/new library, location, backup targets and timing | **Core:** choose root (#4); automated backup **Later** |
| Rendering settings | L2/L5: math, TOC, newline handling, code line numbers | **Core:** TOC/newline policy; advanced toggles **Later** |
| Publishing/extensions | L2: service configuration, site variables, scripts, preference import/export | **Skip:** services/scripts; preference transfer **Later** |
| Main menus | L2: File, Edit, Syntax, Actions, View, Publish, Window, Help, app settings | **Core:** native File/Edit/Format/View/Window/Help and export actions as features land; Publish **Skip** |
| File/Edit commands | L2/H: new/open/save, reveal in Finder, undo/redo, find/replace, substitutions, transformations | **Core:** relevant native commands (#4–5, #13); verify enabled state with focus |
| Layouts | H/L2: separate Library and Folders windows; source, preview, split; outline docking; editor-only/full screen | **Core:** one sidebar/list/editor window with pane toggles (#4, #18); extra windows/layouts **Later** |
| Tabs/session | H/L2: replaceable preview tab; editing/double-click makes it fixed; reorder/close subsets; reopen session | **Later:** one selected document first, then dedicated tab/session ticket |

Verified **documented** shortcuts (H and official editor/search docs): Cmd-N new note; Cmd-L library; Cmd-E external folders; Cmd-O quick search within those modes; Cmd-R edit/preview toggle; Cmd-4 split; Cmd-7 outline; Cmd-8 document information; Control-Shift-T table insertion. Local table labels additionally show Tab for next cell and Cmd-U for adding a row. These are context-dependent, not a complete live keymap. Remaining syntax shortcut assignments and any user overrides are **U**. Silkweb should preserve conventional macOS Cmd-O for opening files/root and use Cmd-Shift-O for quick open; this is a deliberate proposal, not claimed MWeb parity. [Editor reference](https://www.mweb.im/en-mweb-editor), [search reference](https://www.mweb.im/en-mweb-quick-search).

## Folder Structuring Gap & Recommended Model

### What MWeb actually lacks

MWeb's category tree is hierarchical, but a document can have multiple category memberships. Membership and custom ordering therefore need database semantics rather than a single path. Its library documentation describes a `docs` directory and category/tag database; category export materializes a hierarchy later. Separate Folders mode exposes actual filesystem organization. Its bundled start guide explicitly documents adding, deleting, and renaming folders, so claiming that MWeb cannot make folders would be false. [Library documentation](https://www.mweb.im/en-mweb-library), [external-folder documentation](https://www.mweb.im/15306237915264).

**Inference:** the product-owner pain is that the main note-library experience does not make each category a real folder that owns its files. The owner's exact failing interaction, whether in Library or Folders mode, remains an open question. We did not test cross-mode parity, folder drag collision handling, symlink behavior, empty-folder preservation, or link repair in MWeb. No personal library inspection was necessary.

### Recommended Silkweb contract

- **One root, actual paths:** any user-chosen directory can be a library. Documents are UTF-8 `.md` files with one parent. Real directories persist even when empty. Tags are independent of location. Offer All Documents as a virtual view clearly distinct from a folder.
- **Metadata:** a versioned `.silkweb` index stores IDs, tags and view preferences, decodes absent keys tolerantly, and can rebuild filesystem-derived entries. Do not put document bodies in the index. App moves preserve IDs; external identity ambiguities must not silently attach one note's tags to another.
- **Tree:** sidebar is a folder outline with disclosure controls and keyboard navigation. Show direct document count by default; label recursive totals separately. Selecting a folder lists its direct documents; an explicit Include Subfolders switch controls recursive retrieval.
- **Create/rename:** contextual and menu commands target the selected parent. Reject empty, reserved, separator-containing and colliding names, including case-only rename edge cases on case-insensitive volumes. Renaming the file does not silently rewrite its first heading.
- **Move:** drag documents/folders onto a folder; destination highlight and spring expansion clarify the target. Move To… offers a searchable keyboard-accessible folder picker. Prevent cycles, moving root, path escape, and silent overwrite. First release offers cancel or a unique name on collision; no implicit merge.
- **Links/assets:** define relative Markdown destinations early. Before moving, compute affected supported file links; save dirty text and apply rewrites with recoverable staging. Preserve unsupported syntax and report unresolved links. Central `.silkweb-assets/<document-id>/` assets avoid asset relocation when folders move; links remain relative and readable by other tools. Do not automatically delete shared assets.
- **Delete:** move folders with their complete contents to macOS Trash, including empty folders. Explain descendant deletion for nonempty folders; never offer hidden permanent erasure. Keep a dirty buffer on failure. Finder restoration plus rescan is first-release recovery; an in-app trash browser is Later.
- **Sorting:** natural filename order in tree; document name/created/modified ascending/descending in list, stable tie-breakers, per-folder remembered choice. Manual ordering is Later; disk filenames never encode display order.
- **Import:** distinguish Open Folder in place from Import Copy. Copy nested Markdown and local referenced assets into the chosen destination, preserve empty subfolders, preview collisions and unsupported files, never overwrite or modify the source. Detect references outside import root and report them rather than reading arbitrary files.
- **External changes:** background reconciliation handles Finder creates/moves/deletes. Dirty-document conflict handling preserves both versions. Do not follow symlink cycles or traverse outside the root implicitly.
- **Scale:** tree enumeration, indexing, search and link scans run off the main thread. Debounce autosave/preview; never reread the library on every keystroke. Test using synthetic 10,000-document/1,000-folder fixtures, not the owner's library.

## Competitor Notes (folder UX)

These are verified relevant alternatives, not a market-share ranking. Prices are displayed USD offers checked on the research date; regional taxes and editions vary. Weaknesses below compare against **Silkweb's intended design**, since today's skeleton is not competitive.

| Competitor / relationship | Platform and price | Target user / standout | Folder UX and relative tradeoff |
|---|---|---|---|
| **MWeb — direct reference** | Mac, iPhone/iPad; Pro web-store lifetime $34.99; mobile/installed-edition pricing not established | Markdown writers needing a library and publishing | Categories and separate folder mode divide the workflow; borrow its three-pane writing flow, not category ownership. [Overview](https://www.mweb.im/) |
| **Typora — direct editor** | macOS, Windows, Linux; $14.99, up to 3 devices, 15-day trial | Writers wanting rendered editing, math/diagrams, exports | Real tree/list, drag moves, file-operation undo with limitations, Finder reveal and external-change refresh. Native tags absent in documented file management. Borrow clear tree operations. [Product](https://typora.io/), [file management](https://support.typora.io/File-Management/) |
| **Obsidian — adjacent knowledge workspace** | Desktop and mobile; free local use, optional Sync from $4/month annually | Linked-note/knowledge-base users; links, graph, canvas and plugins | Vault file explorer supports nested folders and file/folder CRUD/drag moves. Strong direct model reference. Greater configuration surface is a product-fit tradeoff (I), not a measured usability defect. [Product](https://obsidian.md/), [pricing](https://obsidian.md/pricing), [file explorer](https://obsidian.md/help/plugins/file-explorer) |
| **iA Writer — direct writing tool** | Mac $49.99, Windows $29.99; iPhone/iPad $49.99 separately | Prose writers seeking focused editing | Current Mac release notes document expandable tree/list navigation, contextual creation in subfolders and drag moves. Multiple library locations are useful; per-platform purchasing adds cost. No claim that it lacks deep folders. [Pricing](https://ia.net/writer/pricing), [Mac listing](https://apps.apple.com/us/app/ia-writer/id775737590?mt=12) |
| **Bear — adjacent note library** | Mac/iPhone/iPad; free local tier; Pro $2.99/month or $29.99/year | Apple note takers; nested tags and rich note organization | Slash-delimited tags create a hierarchy; they are not on-disk ownership folders. Tag export can create nested directories, which is different from editing a folder of files in place. [Product/pricing](https://bear.app/), [nested tags](https://bear.app/faq/nested-tags/), [tag export](https://bear.app/faq/export-your-tags/) |

### Feature Matrix

**Y** verified; **L** limited/separate mode; **P** paid tier; **U** not verified in this survey; **—** absent in inspected Silkweb code. Do not interpret U as a missing feature. Columns focus on the rebuild's core workflows, not every specialist capability.

| Product | Real nested file tree | Library organization | Markdown writing | Preview/rendering | Search | Local images | Portable output |
|---|---|---|---|---|---|---|---|
| MWeb | L: Folders mode | Categories + tags | Y: source + assists | Split, math, diagrams | Full text + quick | Y | MD/HTML/PDF; DOCX limits; ePub |
| Typora | Y | Tree/list; no native tags | Y: rendered/source | Math/diagrams | Global + quick | Y | PDF; extended converters |
| Obsidian | Y | Folders + tags/links | Y | U: exact renderer parity | U in inspected sources | U | Plain-text files; other export U |
| iA Writer | Y: current Mac | Locations/tree/list | Y | U: exact parity | U in cited release listing | U | U in inspected sources |
| Bear | No ownership-folder model | Nested tags | Y | U: exact parity | P: image/PDF search; ordinary search details U | U | MD free; HTML/PDF/DOCX/ePub Pro |
| Silkweb now | — | — | — | — | — | — | — |
| Silkweb Core proposal | Y | Folders + tags | Source + assists | Bounded grammar + split | Full text + quick | Y | MD/HTML/PDF |

Matrix evidence is the linked official competitor material above and MWeb inventory references. No plugin ecosystem was audited; no performance superiority is asserted.

## Gap Analysis

Every proposed missing area was checked against the actual source, not inferred from the product brief. Audit command: `rg -n -i 'folder|document|editor|markdown|search|tag|export|save|preview' Sources Tests`, followed by full reads of all Swift files. No feature implementations were found. `SilkwebCore.swift` contains only a version constant; `SilkwebApp.swift` only a Text in WindowGroup; tests only assert a nonempty version. Package.swift declares no dependencies.

| Verified gap | Actual code evidence | Roadmap coverage |
|---|---|---|
| Persistence, folder tree, mutations, metadata | Core file contains no storage/model types | #1–3, #6–11 |
| Sidebar/list/document selection | App has only a label | #4, #9 |
| Editing, saving, find, formatting, tables, assets | No text view, document buffer, commands or asset handler | #5, #12–15 |
| Markdown rendering, outline, preview | No parser, renderer or WebKit bridge | #16–18 |
| Search and tags | No index/query/tag types | #19–21 |
| Export | No exporter or print bridge | #22–23 |
| Preferences and keyboard/accessibility polish | No settings scene or feature commands | #24–25; feature-specific commands ship earlier |

Open-issue exclusions: none can be named because the local issue store is absent. All 25 entries are proposals, not already-created tickets. No competitor-driven request for accounts, hosted AI, collaboration, or publishing has been added.

## Rebuild Roadmap — Recommended Features

Build order takes precedence over numerical priority. **S** = narrow change; **M** = one coherent subsystem or UI slice; **L** = substantial single subsystem needing careful review, not a promise of a one-day implementation. Every entry is one independently buildable change. `Core/` below means `Sources/SilkwebCore/`, `App/` means `Sources/Silkweb/`; listed filenames are proposed, not existing. Any testable logic gets XCTest in `Tests/SilkwebCoreTests/<area>Tests.swift` alongside its ticket.

1. **Disk library model and tolerant metadata — L, P1; dependencies: none.** Problem: notes need a durable, tool-independent home. MWeb reference: library files plus category database. Behavior: enumerate one root into folder/document models off-main; UTF-8 reads; stable app IDs; versioned JSON defaults and rebuildable derived index; no implicit symlink traversal. Files: `Core/LibraryModels.swift`, `LibraryScanner.swift`, `LibraryMetadata.swift`. Verify nested/empty folders, malformed metadata recovery, older JSON and synthetic large-tree enumeration.

2. **Safe folder/file mutation engine — M, P1; dependencies: 1.** Problem: organizing notes must not overwrite files. MWeb reference: external-folder management. Behavior: create/rename/move primitives with collision, root containment, cycle and case-only rename handling; produce a change set for UI. No UI yet; before link support, movement concerns only unlinked text. Files: `Core/LibraryMutations.swift`, mutation tests. Verify collisions leave both originals intact.

3. **Atomic document save coordinator — M, P1; dependencies: 1.** Problem: interrupted/failed saves lose writing. MWeb reference: editable local notes and recovery workflow; its atomic-write implementation is U. Behavior: serialized per-document writes, temporary replacement, revision token, recoverable draft on failure; dirty state clears only on success. Files: `Core/DocumentStore.swift`, `SaveCoordinator.swift`, tests with injected filesystem failures.

4. **Three-pane library shell — M, P1; dependencies: 1.** Problem: the app cannot navigate a library. MWeb reference: category/list/editor arrangement. Behavior: root chooser, folder outline, direct-child document list, selection and read-only document placeholder; keyboard tree navigation and clear empty/error states. Files: `App/SilkwebApp.swift`, `LibraryWorkspace.swift`, `FolderSidebar.swift`, `DocumentList.swift`. Build the usable shell before editor integration.

5. **Native text editor with autosave — L, P1; dependencies: 3, 4.** Problem: users cannot write safely. MWeb reference: source-first writing and native editing commands. Behavior: NSTextView bridge, Unicode/IME, undo/redo, plain-text paste, native spelling; debounced save and flush before selection/close; save failures retain buffer and prevent silent loss. Files: `App/MarkdownTextView.swift`, `DocumentSession.swift`, `AppCommands.swift`; pure buffer/save scheduling tests in Core.

6. **Create and rename from the library — M, P1; dependencies: 2, 5.** Problem: empty library offers no writing entry point. MWeb reference: new note/category and external-folder context commands. Behavior: new folder/subfolder/document in selection, editable filename, validation messages and Finder reveal; save before rename, stable selection afterward. Files: `App/LibraryCommands.swift`, `FolderSidebar.swift`, `DocumentList.swift`. Verify filesystem effects and save/rename sequencing.

7. **Folder and document moves with link planning — L, P1; dependencies: 2, 5, 6.** Problem: folders cannot reorganize work reliably. MWeb reference: category drag management and external-folder tree; link-repair parity U. Behavior: internal drag/drop and Move To… share one transaction; prevent cycles/overwrites; preserve IDs and supported relative Markdown destinations through a preflight rewrite plan, with staged rollback. Files: `Core/MovePlan.swift`, `MarkdownDestinations.swift`, `App/MovePicker.swift`, sidebar/list drop delegates. Tests: descendant moves, links inside/outside moved subtree, dirty source, failure recovery. Limit rewrite grammar explicitly; unsupported links are reported.

8. **Trash-based deletion — M, P1; dependencies: 2, 5, 6.** Problem: deletion must be reversible. MWeb reference: library Trash versus external system Trash. Behavior: system Trash for docs/folders, descendant summary for nonempty folders, flush dirty state, preserve selection sensibly; no permanent-delete command. Files: `Core/DeletionPlan.swift`, `App/TrashService.swift`, `LibraryCommands.swift`. Test plans and failures; synthetic integration target only.

9. **Folder counts and document sorting — S, P1; dependencies: 4, 6, 8.** Problem: users cannot understand or scan a hierarchy. MWeb reference: title/date/custom sorts. Behavior: direct counts, explicit recursive mode, natural folder names and name/created/modified document sorting, per-folder preferences. Files: `Core/LibraryPresentation.swift`, `App/FolderSidebar.swift`, `DocumentList.swift`. Test counts and deterministic ties; manual order excluded.

10. **Copy-import of a Markdown folder — M, P1; dependencies: 2, 6, 7.** Problem: existing files cannot enter the managed workflow safely. MWeb reference: folder import with images. Behavior: preview copy plan, preserve nesting/empty directories, copy supported local assets, reject silent replacement, report unsupported/external references; source untouched. Files: `Core/ImportPlan.swift`, `FolderImporter.swift`, `App/ImportSheet.swift`. Test nested fixtures, asset references, duplicate names and interrupted import cleanup.

11. **Reconcile Finder changes and preserve conflicts — L, P1; dependencies: 3, 5, 7.** Problem: real files can change outside Silkweb. MWeb reference: folder workflow; its exact conflict policy U. Behavior: filesystem notifications plus debounced background rescan, clean-buffer reload, dirty conflicts retain both versions; detect external deletions without discarding drafts. Files: `Core/LibraryReconciler.swift`, `App/LibraryWatcher.swift`, `ConflictSheet.swift`. Test external write during save and rename/delete scenarios with synthetic files.

12. **Markdown styling and formatting commands — L, P1; dependencies: 5.** Problem: plain text alone lacks the core Markdown writing assistance. MWeb reference: Syntax menu and toolbar. Behavior: incremental headings/emphasis/code/link styling; selection-safe bold/italic/strike, heading, quote, list, link and code commands; list continuation/indentation. Files: `Core/MarkdownEditing.swift`, `MarkdownTokens.swift`, `App/MarkdownTextView.swift`, `FormatCommands.swift`. Test Unicode ranges, IME boundaries, undo grouping and touched-range processing; no full language highlighter.

13. **Find and replace in a document — S, P1; dependencies: 5.** Problem: long documents are hard to revise. MWeb reference: native find/replace menu. Behavior: NSTextFinder-backed Cmd-F, next/previous, replace/all with undo; selection remains visible. Files: `App/MarkdownTextView.swift`, `AppCommands.swift`. Native integration verification; do not build a second search engine.

14. **Pipe-table insertion — S, P2; dependencies: 12.** Problem: hand-typing table scaffolding is tedious. MWeb reference: table insertion/editing dialog. Behavior: choose rows/columns/alignment and insert a valid source table as one undo action; bounded dimensions. Files: `Core/MarkdownTable.swift`, `App/TableInsertSheet.swift`. Test dimensions, alignment and escaping. Graphical editing of existing cells deferred.

15. **Local image and attachment insertion — M, P1; dependencies: 5, 7.** Problem: pasted illustrations should remain available offline after organization. MWeb reference: paste/drop images and local media paths. Behavior: clipboard image/Finder drop copies into document-ID asset directory and inserts a relative link; attachments use ordinary links; never uploads. Files: `Core/AssetStore.swift`, `App/EditorPasteHandler.swift`. Test collisions, percent-encoded filenames, paste undo and move-link preservation; no automatic asset garbage collection.

16. **Bounded Markdown-to-HTML renderer — L, P1; dependencies: 12.** Problem: writing has no readable output. MWeb reference: CommonMark source rendering. Behavior: original parser for documented subset: paragraphs, headings, emphasis/strong, escaped code, links/images, quotes, simple nested lists, rules; escape raw HTML and disallow active URL schemes. Preserve unsupported constructs as text; explicitly document deviations rather than claiming full conformance. Files: `Core/MarkdownParser.swift`, `MarkdownAST.swift`, `HTMLRenderer.swift`, fixture tests. A full CommonMark engine needs separately authorized dependency scope or more tickets.

17. **Tables, tasks, footnotes and TOC rendering — M, P1; dependencies: 16.** Problem: common MWeb documents lose structural information in preview. MWeb reference: extended Markdown and TOC. Behavior: extend renderer with pipe tables, task markers, strike, autolinks, footnotes and deterministic heading IDs/TOC. Files: `Core/MarkdownExtensions.swift`, `HTMLRenderer.swift`. Test escaped pipes, duplicate headings, missing footnotes and malformed syntax. This extends one rendering subsystem; no math/diagram engine.

18. **Offline preview and heading outline — M, P1; dependencies: 15, 17.** Problem: users cannot read or navigate rendered notes. MWeb reference: split/preview and outline modes. Behavior: WKWebView bridge, editor/preview/split toggles, debounced latest-result-only rendering, local asset access, heading navigation; no automatic network requests or document JS. Files: `App/PreviewView.swift`, `PreviewCoordinator.swift`, `OutlineView.swift`, fresh `App/Resources/preview.css`. Test generation ordering/local URL boundaries; scroll sync deferred.

19. **Background library search index — M, P1; dependencies: 1, 3, 11.** Problem: 10,000 notes cannot be searched synchronously per keypress. MWeb reference: full-text search. Behavior: derived title/body index, incremental updates, cancellable queries, folder scope; in-memory or rebuildable local persistence, no backend. Files: `Core/SearchIndex.swift`, `SearchQuery.swift`. Test edits/moves/deletion invalidation and benchmark synthetic 10,000-note queries with main-thread work checked separately.

20. **Search results and quick open — M, P1; dependencies: 4, 19.** Problem: users need a keyboard route to the right note. MWeb reference: quick search within Library/Folders. Behavior: results with matching snippet/path, global or subtree scope, title-first quick-open panel, keyboard selection and focus restoration. Files: `App/SearchView.swift`, `QuickOpenPanel.swift`, commands. Test query/result generation logic; no advanced query language.

21. **Tags as a second organization axis — M, P2; dependencies: 1, 19, 20.** Problem: one folder cannot express every topic. MWeb reference: tag editor and tag-filtered library. Behavior: metadata tags with suggestions, add/remove/rename tag, filter intersected with folder/search; notes remain in one actual folder. Files: `Core/TagStore.swift`, `App/TagEditor.swift`, `TagSidebar.swift`. Test metadata migration, moves preserving tags and combined predicates; no inline hashtag rewriting.

22. **Self-contained HTML export — M, P2; dependencies: 15, 17.** Problem: recipients need a readable document without Silkweb. MWeb reference: HTML output embeds local images. Behavior: export one HTML file with original print/read styling and embedded supported images, deterministic encoding and clear missing-asset errors; choose destination, never silently overwrite. Files: `Core/HTMLExport.swift`, `App/ExportCommands.swift`. Test offline output, escaping and image embedding; no website generator.

23. **Print and save a single document as PDF — M, P2; dependencies: 18.** Problem: users need a fixed-layout deliverable. MWeb reference: PDF export dialog. Behavior: print-ready rendered document through native print/PDF flow, images and page margins; escape content consistently with preview. Files: `App/PrintCoordinator.swift`, `PrintCommands.swift`, original print CSS. Validate synthetic multi-page/table/image documents; multi-document compilation deferred.

24. **Writing and appearance settings — M, P2; dependencies: 5, 18.** Problem: default typography may not suit prolonged writing. MWeb reference: font/spacing/width and light/dark preferences. Behavior: settings scene for editor font/size/spacing/width, system/light/dark appearance and explicit line-break policy; persist defaults tolerantly and update editor/preview without replacing text. Files: `Core/WritingPreferences.swift`, `App/SettingsView.swift`, editor/preview style adapters. Test old/default values and preference bounds.

25. **Keyboard/accessibility completion and document statistics — M, P2; dependencies: 6, 7, 8, 9, 13, 18, 20, 21, 22, 23, 24.** Problem: frequent writing actions need consistent keyboard access and feedback. MWeb reference: menus, editor focus and word/selection counts. Behavior: complete menu validation/shortcuts, focus traversal and accessible labels across existing surfaces; debounced word/character counts. Files: `Core/DocumentStatistics.swift`, `App/AppCommands.swift`, existing workspace views. Test count definitions on Unicode/CJK, command routing and non-GUI accessibility structure. This is integration polish, not permission to defer basic accessibility until the end.

### Release boundaries and validation

Core rows map to the numbered tickets; all advanced features intentionally marked Later are excluded from this release. Math, Mermaid, full CommonMark conformance, tabs, focus/typewriter, backups/history UI, HTML paste, TextBundle, rich text, DOCX and ePub each need a focused follow-up issue. No third-party dependency is silently assumed. If the owner requires math/diagrams in the first release, replace lower-priority slices and explicitly allow independently sourced renderers in those issues; never extract them from MWeb.

Each code ticket must run `./scripts/build.sh` and appropriate `./scripts/build.sh test`; never bare `swift build`. Core failure-path tests use temporary synthetic libraries. GUI launching/automation is prohibited for this team, including QA; build/tests/static review can pass under that constraint, but runtime interaction fidelity remains unverified and must not be reported as visually tested. Only the Orchestrator closes issues after QA PASS and approval. This research changes no source and therefore does not run a build.

## Open Questions for the Product Owner

1. Is the pain specifically MWeb Library categories, or a failing operation in its Folders window? The proposed unified model addresses the former without falsely claiming MWeb lacks the latter.
2. Is the proposed Core release sufficient without math/Mermaid, full CommonMark conformance, tabs, focus/typewriter and DOCX/ePub? Which is a daily necessity? No owner note content is needed to answer.
3. Should the initial library open an existing directory in place by default, or start with a new folder and offer Import Copy? Both should remain explicit.
4. Are sidecar tags acceptable, or must tags travel inside Markdown front matter? The proposal avoids altering document text; a portable front-matter contract is separate scope.
5. Confirm system Trash plus Finder restoration for v1, direct folder counts, and name/date sorting without manual order.
6. Is migration via MWeb's own Markdown folder export sufficient? Multiple category memberships can become duplicate exported files; automated DB migration would require a separate clean-room specification and synthetic fixtures.
7. Does switching to standard Cmd-O and Cmd-Shift-O matter more than copying MWeb's contextual Cmd-O behavior?

These questions do not block storage or shell work under the stated defaults. They are decisions to record in future issue comments, not assumptions about the owner's data.

## Sources

### Official web sources consulted

- [MWeb overview and price](https://www.mweb.im/)
- [MWeb 4.8.2 release notes](https://www.mweb.im/download)
- [Library structure, categories, tags and sync](https://www.mweb.im/en-mweb-library)
- [External-folder mode](https://www.mweb.im/15306237915264)
- [Editor](https://www.mweb.im/en-mweb-editor)
- [Search](https://www.mweb.im/en-mweb-quick-search)
- [Export](https://www.mweb.im/en-mweb-export)
- [Typora product/pricing](https://typora.io/)
- [Typora folder operations](https://support.typora.io/File-Management/)
- [Obsidian product](https://obsidian.md/), [pricing](https://obsidian.md/pricing), [file explorer](https://obsidian.md/help/plugins/file-explorer)
- [iA Writer pricing](https://ia.net/writer/pricing), [Mac App Store release listing](https://apps.apple.com/us/app/ia-writer/id775737590?mt=12)
- [Bear product/pricing](https://bear.app/), [nested tags](https://bear.app/faq/nested-tags/), [export tags](https://bear.app/faq/export-your-tags/)

The attempted iA `https://ia.net/writer/support/library/mac-library` open returned an error; it is not relied on. Current Mac release text provides the tree-navigation evidence. Official marketing is evidence of advertised functionality, not comparative performance or customer demand measurements.

### Local sources inspected

- `/Users/markhinojosa/Projects/Silkweb/AGENTS.md`
- `/Users/markhinojosa/Projects/Silkweb/Package.swift`
- `/Users/markhinojosa/Projects/Silkweb/Sources/SilkwebCore/SilkwebCore.swift`
- `/Users/markhinojosa/Projects/Silkweb/Sources/Silkweb/SilkwebApp.swift`
- `/Users/markhinojosa/Projects/Silkweb/Tests/SilkwebCoreTests/SilkwebCoreTests.swift`
- `/Applications/MWeb.app/Contents/Info.plist` (**L1**, `plutil -p`).
- `/Applications/MWeb.app/Contents/Resources/en.lproj/Localizable.strings` (**L2**, parsed metadata, settings and feature labels). Other localization filenames were listed, not translated exhaustively.
- `/Applications/MWeb.app/Contents/Resources/` (**L3**, filenames and directory structure only for code/assets/compiled UI): `Main.storyboardc`, `Library.storyboardc`, preferences/export/editor `.nib` names, `assets/mathjax`, `assets/mermaid`, `assets/echarts`, `assets/highlightjs`, `assets/prism`, `assets/flowseq`, `assets/viz`, `assets/turndown`, `assets/EditorThemes`, `assets/themes`, `assets/SiteThemes`, `previewCSS`, `pdf.css`, `epub.css`.
- `/Applications/MWeb.app/Contents/MacOS/MWeb` (**L4**, `otool -L` linkage metadata only; no disassembly or implementation strings extraction).
- Preference domain `com.coderforart.iOS.MWeb` (**L5**): `defaults export … -` parsed in memory and **only top-level key names printed**. Values, paths and bookmarks were not displayed or used. Examples: `editorFontInfo`, `editorLineSpacing`, `editorContentMaxWidth`, `documentOutlineDisplayType`, `isRenderTOC`, `isEnableMath`, `isLibraryStoreIniCloud`. Names reveal configuration surface, not current values.
- Bundled public help text (**H**), parsed as prose without scripts/styles: `/Applications/MWeb.app/Contents/Resources/help/en-mweb-start.html`, `en-mweb-editor.html`, `en-markdown.html`, `en-mweb-export.html`. These describe intended behavior and may lag release-specific details; current release notes supersede conflicts.
- `codesign -d --entitlements :- /Applications/MWeb.app` returned no readable entitlement payload. No conclusion about sandbox status drawn.

No personal MWeb container, iCloud folder, database, or note file was opened. The library schema/layout description comes from published documentation, not the owner's files. No proprietary source, CSS, theme, binary, help prose, image, icon or branding asset was copied into this repository.
