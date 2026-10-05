# Team Roadmap — IN PROGRESS (checkpoint 2026-10-05)

**Read this first after a context reset.** Work is tracked on GitHub: **https://github.com/Mhinolv/silkweb**
(public; Issues + PRs; milestones `v1`, `v2`). Integration branch `team/roadmap`; `main` = baseline.
GitHub is authoritative — this file is only a snapshot. Team state/logs live in `.team/` (local, ignored);
pre-GitHub history (beads export, old-id → issue map, 2026-10-03 bug review) is in `.team/archive/`.
`gh` runs with `GH_TOKEN=$(gh auth token -u Mhinolv)` (team.env `GH_ACCOUNT`); never switch the global gh account.
Git identity (repo-local): `Mark Hinojosa <73273673+Mhinolv@users.noreply.github.com>`; history was rewritten to it
before the first push (local backups `backup/pre-rewrite-main`, `backup/pre-rewrite-roadmap` — never push them).

## Team
| Role | Model |
|---|---|
| PM | Cursor composer-2.5-fast (`PM_CLI=claude` fallback) |
| UI/UX | Claude claude-opus-5-5 |
| Engineer | **Claude Opus 5.5, medium — owner decision: until v1 is finished** (`ENG_CLI=claude`) |
| QA | Claude claude-sonnet-5-5 (+ snapshot PNGs captured outside the sandbox) |

## Board (v1) — run `status.sh` for live state
- **Waiting for the owner's check (`needs-owner-check`):** #1, #2/#54 (full-screen toolbar), #3, #4, #5, #6, #11.
- **In progress:** #67 test preference leaks · #68 view buttons back to the right edge (owner chose Option A) ·
  #69 inspector Info/Outline switching (PR #73) · #70 list selection lag (+ select on mouse-down) ·
  #72 inspector redesign (owner chose Tags A + Outline B; starts after #69 merges).
- **v2:** #12–#48 (`needs-pm`), #71 typewriter key sounds.

## Owner rules & decisions (binding)
- Every owner request/bug: stub issue (`needs-pm`) → **PM review** → **UX notes** (only a P0 bug with no visible
  change may skip UX — tell the owner) → Engineer on branch `<n>-<slug>` → draft PR (template required) →
  QA comment on the PR → Orchestrator verifies (regression tests must fail on pre-fix code) → merge → close.
- The orchestrator approves and merges PRs; tell the owner when each PR is **created** (link) and **merged**.
- Items needing the owner's eyes merge with `--owner-check` (issue stays open until the owner OKs it).
- CI (macOS, ~15 min) runs once per ready PR / on the `run-ci` label / manually; never on drafts, branch pushes or
  doc-only PRs. Required checks on `team/roadmap`: the PR-template check.
- Parallel lanes are encouraged when there is no material overlap.
- When the owner tests a build, say exactly which items are IN it and which are NOT yet.
- Ask the owner via `~/.claude/bin/claude-ask "<one line>"`.
- Product: tags in sidecar index only; first launch = Open Folder in Place + New Library; Trash browser in v2;
  inline editor images in v1; clean-room (behaviour only, never MWeb code/CSS/assets).

## Lessons (avoid repeating)
- Prove regression tests fail on pre-fix code; QA "by review" is not proof.
- Headless agents end when their turn ends: full suites run via `.team/suite_start.sh` + repeated `.team/suite_wait.sh`.
- Timing-sensitive tests surface on slower CI runners — use condition waits (`waitUntil`), never fixed sleeps.
- Merge one PR at a time; editing a PR body re-runs the template check, so wait for checks after any edit.
- Keep the Mac awake (`caffeinate -dims &`) for long unattended runs.

## Commands (skill: `~/.claude/skills/product-team/`)
- Board `status.sh` · ticket `lane.sh <n>` (run_in_background) · merge `merge_pr.sh <n> [--owner-check]` ·
  owner OK `owner_decision.sh <n> "OK — …" --close` · owner build `test_latest.sh` · snapshots `./scripts/snapshot.sh <dir>`.
