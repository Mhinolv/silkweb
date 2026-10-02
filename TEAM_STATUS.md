# Team Roadmap — IN PROGRESS (checkpoint 2026-10-01 22:32 EDT)

Epic **silkweb-1** (v1) on branch `team/roadmap` (main untouched; baseline `6cbab4d`). v2 roadmap: epic **silkweb-2** (35 tickets, custom HTTP integrations first). Team state/logs: `.team/` (local, git-excluded). Skill: `product-team`.

## Team
| Role | Model | Runner |
|---|---|---|
| Research | Codex gpt-6-astra | run_research.sh |
| PM | Cursor composer-2.5-fast | run_pm.sh |
| UI/UX | Claude claude-opus-5-5 | run_ux.sh |
| Engineer | Codex gpt-6.1-sol (medium); fallback Opus 5.5 ONLY if owner says so | run_ticket.sh |
| QA | Claude claude-sonnet-5-5 | run_ticket.sh |

## Board
**Closed (v1):** 1.1 1.2 1.3 1.4 1.5 1.6 1.7 1.8 1.9 1.10 1.11 1.12 1.13 1.15 1.16 1.17 1.19 1.20 1.26 1.28 1.29 1.30 1.31 1.32 1.33 1.34 1.35 1.36 1.37 1.38 
**In progress:** 1.42 offscreen screenshot harness — engineer attempt 1 running at checkpoint. Resume if interrupted: `git status`; if no 1.42 commit landed, `run_ticket.sh silkweb-1.42` (or `run_ticket.sh silkweb-1.42 <next-attempt>` to keep QA feedback).
**Held open for owner check:** 1.18 (preview) — closes together with 1.40 after owner confirms text+images render.
**Queued (PM-reviewed + UX notes done), in order:** 1.42 -> 1.40 (P0 blank preview) -> 1.39 (P0 idle redraw: placeholder + Search Library blinking) -> 1.44 (Outline hierarchy) -> 1.43 (visible media/ folder + migration) -> 1.41 (inline images in editor); then 1.45, 1.14, 1.21, 1.22, 1.23, 1.24, 1.27, 1.25 (final polish, depends on most).
**All open v1:** 1.14 1.18 1.21 1.22 1.23 1.24 1.25 1.27 1.39 1.40 1.41 1.42 1.43 1.44 1.45 

## Process rules (owner-set)
- Every owner request/bug — and any re-scoped ticket — goes Orchestrator draft -> PM review -> UX notes -> Engineer -> QA. Only a true P0 hotfix with no UI may skip UX (tell owner).
- After 1.42 lands: orchestrator runs `./scripts/snapshot.sh` UNSANDBOXED after each UI commit; QA must view the PNGs; blank/broken screen = FAIL. WebKit only runs outside the agent sandbox — orchestrator verifies real-WebKit tests.
- Orchestrator verifies new regression tests FAIL on the pre-fix build before accepting (done for 1.29, 1.35).
- Codex usage limit: pause, stash partial edits with a label, `~/.claude/bin/claude-ask "..."` the owner (they reset it). Never auto-switch to Opus.
- Ask the owner via `~/.claude/bin/claude-ask "<one line>"` (Slack #marks_claude_alerts, C0C6XQ0BJ00); read replies in that channel's threads. Notification hook alerts on permission prompts only.

## Owner decisions (also recorded as bd comments)
- v1 adds tabs/sessions + focus/typewriter; tags in sidecar index only; first launch offers Open Folder in Place + New Library; Import Copy in File menu.
- Trash browser stays v2; copied images go to visible media/<doc-id>/ (MWeb-style); inline editor images in v1 (1.41); Outline with visual heading hierarchy (1.44); Document Inspector links/media in v2 (2.34).
- Preview prioritized. Slack two-way via webhook; email ping removed.

## Needs owner eyeball
- Preview + images (after 1.40), placeholder/search steadiness (after 1.39), tabs chrome/session restore (1.26), slow-click rename, Quick Open/search UI.

## Gotchas this run
- QA sandbox can't run WebKit or deliver real mouse events offscreen — rely on snapshot harness + owner checks.
- Security-scoped bookmarks broke on every rebuild (fixed 1.36; app signed as com.silkweb.app).
- SwiftUI List drag/click issues -> document list is now a native AppKit table (1.37).
- Partial 1.37 attempt-3 edits are in `git stash` (reference only).
