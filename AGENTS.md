# Silkweb — Agent Brief

## Product Overview
Silkweb is a **native macOS app for writing Markdown documents offline**. It is a clean-room rebuild
of the feature set of MWeb (`/Applications/MWeb.app`, v4.8.2, by coderforart) — an offline Markdown
editor / note library the product owner uses today. Silkweb must match MWeb's core writing experience
and **fix its biggest weakness: no real folder structuring**. In Silkweb, the library is a tree of
nested folders the user can create, rename, move (drag & drop), and delete, and documents live in them.

Principles: offline-first, no accounts or backend, fast on large libraries, keyboard-friendly,
looks and behaves like a first-class Mac app (sidebar / list / editor, native menus and shortcuts).

### Clean-room rule (important)
MWeb is a commercial third-party app. Study its **behavior, UI, menus, settings, documentation and
file formats** to learn what to build — but **never copy its code, binaries, nib/storyboard files,
images, icons, themes/CSS, help text, or name/branding** into this repo. Write everything fresh.
Do **not** open or read the product owner's personal MWeb library/notes content (e.g. anything under
`~/Library/Containers/*MWeb*` or iCloud document folders); schema/structure only if needed, never note text.

## Tech Stack
- Swift 6 toolchain (Swift 5 language mode), SwiftUI + AppKit where SwiftUI falls short
  (e.g. `NSTextView`-based editor, `NSOutlineView` if needed). macOS 15+.
- SwiftPM package, no Xcode project. No third-party dependencies unless an issue explicitly allows it.

## Build & Test
- Build (also bundles `build/Silkweb.app`): `./scripts/build.sh`
- Unit tests: `./scripts/build.sh test`
- Offscreen UI PNGs: `./scripts/snapshot.sh <out-dir> [scenario ...]` (all scenarios by default).
  This runs an XCTest host with activation prohibited and windows never ordered on screen; it does
  not launch Silkweb. Captures are 1400×900 points at the host's backing scale, in light and dark.
  `manifest.json` records pixel dimensions, scale, status and timeout/error details per capture.
  Preview/split PNGs contain native panes only and are marked `unavailable in this environment`
  in the agent sandbox. Run outside the sandbox to capture WebKit via `takeSnapshot`; failures
  produce a nonzero exit and manifest diagnostics. This captures current behavior, including
  existing UI defects; it does not apply fixes or use golden baselines.
  The sandbox denies LaunchServices registration: AppKit may report policy `-1` despite the
  prohibited request. This unregistered XCTest host is allowed only inside the sandbox and
  noted in the manifest; outside it, the harness requires `.prohibited`.
  To add a scenario, append a `SnapshotScenario` configuration in
  `Tests/SilkwebAppTests/SnapshotHarness.swift`; extend its state driver for new interactions.
  The harness copies `Test_Library` into disposable temporary directories and generates local
  and remote image references, an empty document, and a read-only encoding fixture there.
- Build and unit tests work inside the agents' sandbox (caches are kept under `.build/`). Always use these scripts,
  never bare `swift build`.

## Architecture Map
| Area | Location |
|---|---|
| Package manifest | `Package.swift` |
| Core logic (models, library/folder storage, markdown processing, search, export) — **no UI imports** | `Sources/SilkwebCore/` |
| App (SwiftUI scenes, views, AppKit bridges, menus/commands) | `Sources/Silkweb/` |
| Unit tests for core | `Tests/SilkwebCoreTests/` |
| Build / bundling scripts, Info.plist | `scripts/` |
| Owner's manual-test library (sample blog). **Agents: do not modify**; unit tests use their own temp fixtures | `Test_Library/` |
| Design system: naming, look, **keyboard shortcut map** (source of truth — check before adding any shortcut) | `docs/design-system.md` |

Put anything testable in `SilkwebCore` and cover it with XCTest. The app target stays thin.

## Persistence Rules
- The library is a **directory on disk**: real nested folders = Silkweb folders; each document is a
  plain `.md` file (UTF-8). Users must be able to read their notes without Silkweb.
- App-only metadata (ordering, tags cache, pinned, timestamps if not derivable) goes in small JSON
  sidecar/index files. Version every persisted JSON format and decode tolerantly (defaults for missing
  keys) so **files saved by earlier builds still load**.
- Writes are atomic (write temp + replace). Never lose user text: autosave, and no destructive
  operation without confirmation or Trash.

## Performance Rules
- Must stay responsive with 10,000 documents / 1,000 folders. Index and search off the main thread.
- No expensive work per keystroke on the main thread (debounce preview rendering, saving, indexing).

## GUI Regression Rule
QA cannot launch the app, so a crash in AppKit/SwiftUI view code is invisible to the pipeline. Any ticket that
adds or changes an AppKit view subclass, layout override (`setFrameSize`, `layout`, `viewDidMoveToWindow`,
`updateNSView`) or other view-lifecycle code must add an offscreen test in `Tests/SilkwebAppTests/`
(`@testable import Silkweb`) that builds the real view and exercises the lifecycle (load content, resize sweep).

## Team Roadmap Workflow (multi-agent)

A multi-agent team works the roadmap epic. Roles:

| Role | Responsibility | Output |
|---|---|---|
| Orchestrator | Supervises, prioritizes, assigns, commits for the engineer, final approver | Closes issues |
| Product Research | Studies MWeb in depth (+ competitors for folder UX) | `research.md` |
| Product Manager | Turns research/requests into beads issues with acceptance criteria | beads issues under one epic |
| UI/UX | Design notes in each issue's `design` field | beads design notes |
| Engineer | Implements one issue at a time and builds | changes + COMMIT FILES block |
| QA | Verifies against acceptance criteria and comments | PASS / FAIL report + beads comment |

Rules:
- Work happens on the branch `team/roadmap`; never on main. No remote ⇒ "push" means commit on that branch.
- One issue per commit: `<id>: <summary>`. Stage only the files changed for that issue (+ `.beads/issues.jsonl`). Never `git add -A`.
- The Engineer does not close issues. QA does not modify source. Only the Orchestrator closes issues.
- For this epic, **QA PASS + Orchestrator approval replaces the manual user-test gate** (delegated by the product owner). Product-owner decisions are recorded as issue comments and override the original acceptance wording.
- No agent may use browser/Chrome/computer-use/GUI automation tools, and no agent launches GUI apps (including MWeb or Silkweb).
