# Team Roadmap — v2 IN PROGRESS (checkpoint 2026-10-07)

**Read this first after a context reset.** Work is tracked on GitHub: **https://github.com/Mhinolv/silkweb**
(public; Issues + PRs; milestones `v1` **closed**, `v2` open). The integration branch is `team/roadmap`; `main` is the baseline.
GitHub is authoritative; this file is only a snapshot. Team state and logs live in `.team/` (local, ignored), and
pre-GitHub history is in `.team/archive/`. Run `gh` with `GH_TOKEN=$(gh auth token -u Mhinolv)` (`GH_ACCOUNT` in
team.env); never switch the global gh account. The repo-local Git identity is
`Mark Hinojosa <73273673+Mhinolv@users.noreply.github.com>`. Never push the local backups `backup/pre-rewrite-*`.

## Team
| Role | Model |
|---|---|
| PM | Cursor composer-2.5-fast (`PM_CLI=claude` fallback) |
| UI/UX | Claude claude-opus-5-5 |
| Engineer | **Claude Opus 5.5, medium.** Owner decision 2026-10-07: stays for v2 (`ENG_CLI=claude`) |
| QA | Claude claude-sonnet-5-5, plus snapshot PNGs captured outside the sandbox |
| Staff review | Codex `gpt-6-astra` (read-only, `codex_safe.sh`), and Fable for second opinions |

## Status
- **v1: done** (milestone closed 2026-10-07, 98 issues). The final Staff Engineer review fixes #101–#111, #124, and
  the owner's close-out reports #148 and #150–#154 all passed the owner's checks.
- **v2 first priority: the agent memory vault, epic #126.** Research is in `.team/review/v2-agent-vault-astra.md`.
  The MVP is tickets #129 → #139 in dependency order (contract and signed helper, grants, cross-process writes,
  envelope, create and receipts, retrieval, CLI, MCP, in-app activity, agent skill packages, qualification). Later
  phases are #140–#142.
  - Owner decisions (#126/#129): a direct signed helper (no App Store); agents create notes freely, while edits and
    reorganisation go through reviewed proposals; nothing is deleted automatically; the official Swift MCP SDK is
    allowed (pinned); the default read scope is the project's Memory folder; the MVP supports local disk only.
- **Rest of v2:** the final-review P2s (#112–#119) and the feature backlog (#13–#48, #71). Proposed order: vault MVP
  → reliability/polish → writing/Preview → organisation → safety → export/integrations. Multiple libraries
  (one per window) were discussed; it isn't filed yet.

## Owner rules & decisions (binding)
- Every owner request or bug: stub issue (`needs-pm`) → **PM review** → **UX notes**. Only a P0 bug with no
  visible change may skip UX, and the owner must be told. Then: Engineer on branch `<n>-<slug>` → draft PR
  (template required) → QA comment and `qa-pass` label → the Orchestrator proves the regression test fails on the
  pre-fix code → merge → close.
- The orchestrator approves and merges. The owner is alerted in Slack when each PR is **created** and **merged**:
  `notify_owner` in `open_pr.sh`/`merge_pr.sh` does this; post a manual `claude-ask` otherwise.
- Items that need the owner's eyes merge with `--owner-check`, and the issue stays open until the owner OKs it.
  Items the owner says they won't test close on QA, the pre-fix proof and a green post-merge suite.
- At most 2 heavy lanes at once (build/suite). Parallel lanes are fine when they don't touch the same files.
- When the owner tests a build, say exactly which items are in it and which aren't yet.
- Agents never launch GUI apps. The owner runs `test_latest.sh`, or explicitly asks the orchestrator to.
- Clean-room: behaviour only, never MWeb code, CSS or assets.

## CI and merge gates
- CI (`.github/workflows/ci.yml`): `classify` → `build-format` (macos-26, Xcode 26.2) → `ci-gate`, which is required
  together with `PR template / check`. Docs-only and draft PRs pass `ci-gate` without the macOS build. Tests run
  locally only.
- `merge_pr.sh` refuses to merge unless:
  - the `qa-pass` label is present and bound to the head SHA (later commits may only be base merges);
  - bugs carry `FAILS-PRE-FIX` evidence;
  - required checks come from a CI run newer than the PR being marked ready.

  It merges one PR at a time under a lock, then runs the full suite on the merged commit in `.team/integration`.
  A red suite sets the barrier until `--clear-integration "<reason>"`. `--resume-integration [--owner-check]`
  finishes a merge that was interrupted after it had already merged on GitHub.
- `verify_prefix.sh` proves a test fails on the old code. When a test needs new seams, build the pre-fix tree by
  hand: keep the seams, revert the logic, and record the evidence in `.team/prefix_<n>`.

## Lessons (avoid repeating)
- Prove regression tests fail on pre-fix code; QA "by review" is not proof. Unit-testing a policy function isn't
  enough when the real path (WebKit, AppKit) never calls it; drive the real view (#109 → #148).
- WebKit tests are skipped in the agent sandbox, so only the post-merge suite catches WebKit regressions.
- Timing tests flake when two heavy suites overlap. Clear the barrier only with evidence: rerun alone and check
  what the change touched.
- Keep the Mac plugged in with the lid open. `caffeinate -i` doesn't stop lid-close sleep, and a sleep stalls
  suites and kills agents mid-turn.
- Test output is block-buffered, so a quiet log isn't necessarily a hang; check CPU and the log size first.
- GitHub sometimes returns 500s on writes while reads work: retry the label, comment or close in a loop, and never
  skip a gate.
- Background jobs stop at 2 h. Lanes survive in tmux; merges resume with `--resume-integration`.

## Commands (skill: `~/.claude/skills/product-team/`)
- Board: `status.sh` · Ticket: `lane.sh <n>` (run_in_background; `RESUME_AT_PR=1 lane.sh <n> <attempt>` after a
  failed push) · Merge: `merge_pr.sh <n> [--owner-check]` · Owner OK: `owner_decision.sh <n> "OK — …" --close`
- Owner build: `test_latest.sh` · Snapshots: `./scripts/snapshot.sh <dir>` · Watcher: `.team/agent_watch.sh` (Monitor)
