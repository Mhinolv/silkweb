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
  WebKit is disabled automatically for Codex sandbox markers or an unregistered host (policy
  `-1` after requesting prohibited activation), including agent hosts without Codex markers.
  Set `SILKWEB_SNAPSHOT_NO_WEBKIT=1` to explicitly capture native panes only in other restricted
  environments; preview/split captures receive the same unavailable status.
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
QA cannot launch the app or deliver real mouse events, and WebKit does not run inside the agent sandbox. Therefore:
- Any ticket that adds or changes an AppKit view subclass, layout override (`setFrameSize`, `layout`,
  `viewDidMoveToWindow`, `updateNSView`) or other view-lifecycle code must add an offscreen test in
  `Tests/SilkwebAppTests/` (`@testable import Silkweb`) that builds the REAL view hierarchy and exercises the
  lifecycle (load content, resize sweep, mode/tab switches).
- A regression test for a reported bug must FAIL on the pre-fix code and pass with the fix. The Orchestrator
  verifies this; a test that also passes on the broken build does not prove the fix (happened with 1.34, 1.48).
- UI changes are checked visually: `run_qa.sh` captures `./scripts/snapshot.sh` PNGs outside the sandbox before
  QA, and QA must open the relevant light/dark PNGs. Add a snapshot scenario for every new UI state.
- Interaction feel (drag, caret movement, live resize) still needs a product-owner check before closing.

## Team Roadmap Workflow (multi-agent)

A multi-agent team works the roadmap on GitHub: **https://github.com/Mhinolv/silkweb** (Issues + PRs;
milestones `v1`, `v2`). Roles:

| Role | Responsibility | Output |
|---|---|---|
| Orchestrator | Supervises, prioritizes, assigns, commits for the engineer, opens PRs, final approver | Merges PRs, closes issues |
| Product Research | Studies MWeb in depth (+ competitors for folder UX) | `research.md` |
| Product Manager | Turns research/requests into GitHub issues with acceptance criteria | Issue body + `**PM review**` comment |
| UI/UX | Design notes for each issue (bugs too, unless P0 with no visible change) | `## Design notes` section + `**UX notes**` comment |
| Engineer | Implements one issue at a time on its linked branch and builds | changes + COMMIT FILES block + PR body |
| QA | Verifies the PR against the acceptance criteria | `QA RESULT: PASS/FAIL` PR comment + `qa-pass`/`qa-fail` label |

Flow labels (exactly one at a time): `needs-pm` → `needs-ux` → `ready` → `in-progress` → `in-review` →
`needs-owner-check` (or closed). Plus `bug`/`feature`, `P0`–`P3`, `owner-request`, `blocked`.

Rules:
- Integration branch is `team/roadmap`; never commit to main. One issue = one branch `<n>-<slug>` cut from
  `team/roadmap` = one PR into `team/roadmap`.
- Commits: `#<n>: <summary>`. Stage only the files changed for that issue. Never `git add -A`.
- Every PR uses `.github/pull_request_template.md` (Issue / What changed / How it was tested / Screenshots);
  the `PR template` check fails otherwise. Use `Refs #n` instead of `Closes #n` while the owner still has to check it.
- Merge requires: `qa-pass`, green CI, a passing template check, and (bugs) the regression test proven to fail on
  the pre-fix code. Closing keywords don't fire on `team/roadmap`, so the Orchestrator closes issues explicitly.
- `CI / build-and-test` runs only when a PR is opened ready or leaves draft, on the `run-ci` label, or via
  `workflow_dispatch` — never on draft pushes, later pushes, or branch pushes — and only if the PR touches `Sources/`,
  `Tests/`, `Package.*`, `scripts/` or `ci.yml` (doc-only PRs have no CI check and count as passing). To re-run:
  `gh pr edit <n> --remove-label run-ci; gh pr edit <n> --add-label run-ci`.
- The Engineer does not close issues or merge. QA does not modify source. Only the Orchestrator merges and closes.
- For this epic, **QA PASS + Orchestrator approval replaces the manual user-test gate** (delegated by the product owner).
  Product-owner decisions are recorded as issue comments and override the original acceptance wording.
- No agent may use browser/Chrome/computer-use/GUI automation tools, and no agent launches GUI apps (including MWeb or Silkweb).
- History before the GitHub move used a local tracker; old commits say `silkweb-1.NN`. The mapping to issue
  numbers is in each migrated issue's body.
