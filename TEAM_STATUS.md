# Team Roadmap — IN PROGRESS (checkpoint 2026-10-04 EDT)

**Read this first after a context reset.** Work is tracked on GitHub: **https://github.com/Mhinolv/silkweb**
(public; Issues + PRs; milestones `v1`, `v2`). Integration branch `team/roadmap` (pushed); `main` = baseline.
GitHub is authoritative — this file is a snapshot. Team state/logs: `.team/` (local, ignored).
The old beads tracker was removed on 2026-10-04; a full export is in `.team/beads-archive-2026-10-04.jsonl`,
and each migrated issue's body names its old `silkweb-N.M` id (map: `.team/beads_to_issues.json`).
Git identity (repo-local): `Mark Hinojosa <73273673+Mhinolv@users.noreply.github.com>`; history was rewritten
to it before the first push (local backups: `backup/pre-rewrite-main`, `backup/pre-rewrite-roadmap`, never push them).
`gh` runs with `GH_TOKEN=$(gh auth token -u Mhinolv)` (team.env `GH_ACCOUNT`); the global gh account is untouched.

## Team
| Role | Model |
|---|---|
| Research | Codex gpt-6-astra |
| PM | Cursor composer-2.5-fast (`PM_CLI=claude` fallback) |
| UI/UX | Claude claude-opus-5-5 |
| Engineer | **Claude Opus 5.5, medium — owner decision: until v1 is finished** (`ENG_CLI=claude`) |
| QA | Claude claude-sonnet-5-5 (+ snapshot PNGs captured outside the sandbox) |

## Board (v1) — see `status.sh` for live state
- **Merged, waiting for the owner's check (`needs-owner-check`):** #1 polish, #2 toolbar (full screen / hover /
  overlap), #3 search tint, #4 focus images dimmed, #5 compact tables, #6 recovery, #10 focus heading flash,
  #11 test isolation + sidebar scroller track + trailing images ("Always" scroll bars).
- **In the pipeline:** #49 snapshot harness fixtures (first ticket run end to end through the GitHub workflow).
- v2 issues #12–#48 are labelled `needs-pm`.

## Owner rules & decisions (binding)
- Pipeline for EVERY owner request/bug: Orchestrator stub issue (`needs-pm`) → **PM review** comment →
  **UX notes** (`## Design notes` + comment; only a P0 bug with no visible change may skip UX — tell the owner)
  → Engineer on the linked branch `<n>-<slug>` → draft PR using the PR template → QA comment on the PR
  (`qa-pass`/`qa-fail`) → Orchestrator verifies → merge → close.
- The orchestrator has authority to merge PRs and close issues once QA passes, CI is green and verification is done.
- Every PR must use `.github/pull_request_template.md`; the `PR template` check enforces it.
- Before accepting a regression fix, the Orchestrator runs the new test against the pre-fix code; it must FAIL there.
- Parallel lanes are encouraged when there is no material overlap.
- When the owner tests a build, say exactly which of their reports are IN that build and which are NOT yet.
- Ask the owner via `~/.claude/bin/claude-ask "<one line>"`.
- Product: tags in sidecar index only; first launch = Open Folder in Place + New Library; Trash browser in v2;
  inline editor images in v1; clean-room (behavior only, never MWeb code/CSS/assets).

## Mistakes this run (avoid repeating)
- Tests that didn't reproduce the bug passed while the bug remained. Always prove the test fails pre-fix.
- QA judged UI by code review; QA must view the snapshot PNGs.
- Headless agents ended their turn while builds ran in the background — builds/tests run in the foreground.
- A lane merge script deleted a branch after a failed merge — merge scripts abort on failure and clean up only on success.
- Snapshot scenarios that rely on the owner's uncommitted `Test_Library` files break on clean checkouts (#49).

## Commands
- Board: `~/.claude/skills/product-team/scripts/status.sh`
- Owner test build: `~/.claude/skills/product-team/scripts/test_latest.sh`
- Ticket: `tmux_run.sh eng-<n> run_ticket.sh <n>`; parallel: `lane.sh <n>` (run_in_background). Merge: `merge_pr.sh <n>`.
- Snapshots: `./scripts/snapshot.sh <dir>` (unsandboxed for WebKit).
