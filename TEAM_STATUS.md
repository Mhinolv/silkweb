# Team Roadmap — v2 in progress (snapshot 2026-10-09)

**Start here after a context reset: read the newest Silkweb handoff, not this file.** Silkweb is the primary
source of truth for project memory (owner decision 2026-10-09):
`silkweb memory search --type handoff --limit 5` → `silkweb memory read --id <id>`, then `silkweb memory activity`.
Documents live in `Test_Library/Memory/Projects/Silkweb/{Handoffs,Progress,Memories}/`. GitHub
(**https://github.com/Mhinolv/silkweb**, milestone `v2`) is authoritative for issues and PRs. This file is only a
short secondary snapshot.

## Access
- Branches, PRs, merge gates and CI: see AGENTS.md › Team Roadmap Workflow (integration branch `main`).
- Run `gh` with `GH_TOKEN=$(gh auth token -u Mhinolv)`; never switch the global gh account.
- Repo-local Git identity: `Mark Hinojosa <73273673+Mhinolv@users.noreply.github.com>`. Never push `backup/pre-rewrite-*`.
- Team config, logs and lane worktrees: `.team/` (local, ignored). Skill: `~/.claude/skills/product-team/`.

## Team
| Role | Model |
|---|---|
| PM | Cursor composer-2.5-fast (`PM_CLI=claude` fallback) |
| UI/UX | Claude claude-opus-5-5 |
| Engineer | Claude Opus 5.5, medium (`ENG_CLI=claude`; owner decision 2026-10-07, don't switch to Codex) |
| QA | Claude claude-sonnet-5-5, plus snapshot PNGs captured outside the sandbox |
| Staff review | Codex `gpt-6-astra` (read-only, `codex_safe.sh`); Fable for second opinions |

## Active epics (v2)
| Epic | State | Next |
|---|---|---|
| #126 Agent memory vault | MVP shipped; #139, #186 await the owner's check | Later phases #140–#142 (blocked) |
| #173 Knowledge graph | #176, #177 merged; #178 in review (lane A) | #179 → #180 → #181 → #30, then #182–#184 |
| #193 Multiple Libraries (one per window) | #194 in progress (lane B) | #195 → #196 → #197 → #198 (all `ready`) |

Backlog (`needs-pm`): final-review P2s #112–#119 and features #12–#48, #71, #170, #172, #190, #192.

## Waiting on the owner
- #139: Claude same-key replay + Esc-cancel; one Codex run.
- #186: is the terminal-only safeguard on `grant init` enough?
- Knowledge-graph PM questions (centrality boost, 30-day archive, relation vocabulary, English-only eval, aliases
  later): needed before #180, #141, #183.

## Orchestrator rules (owner-specific; team-wide rules live in AGENTS.md)
- Parallel by default: up to 2 heavy lanes on non-overlapping issues; PM/UX/research run alongside. Merge one at a time.
- Tell the owner when a P0 bug skips UX.
- Slack the owner when each PR is created and merged. Write a Silkweb progress checkpoint at every milestone.
- At ~150k tokens of orchestrator context: write a Silkweb handoff with recovery steps and tell the owner to restart.
- Visible UI merges with `merge_pr.sh <n> --owner-check` (see AGENTS.md › Team Roadmap Workflow).

## Commands
- Board `status.sh` · Ticket `lane.sh <n>` · Merge `merge_pr.sh <n> [--owner-check]` (resume:
  `--resume-integration`) · Pre-fix `verify_prefix.sh` · Owner OK `owner_decision.sh <n> "OK — …" --close`
- Watcher: Monitor on `.team/agent_watch.sh` (re-arm every 30 min) · Lane logs: `.team/logs/tmux_lane-<n>.out`
- Owner build: `test_latest.sh`
