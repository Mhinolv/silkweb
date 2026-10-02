# Team Roadmap — IN PROGRESS (checkpoint 2026-10-02 00:32 EDT)

**Read this first after a context reset.** Epic **silkweb-1** (v1) on branch `team/roadmap` (main untouched; baseline `6cbab4d`). v2 = epic **silkweb-2** (34 tickets; custom HTTP integrations first, P1). Team state/logs: `.team/` (local). Skill: `~/.claude/skills/product-team`. Ticket details: `bd show <id>` (read COMMENTS — owner decisions live there).

## Team
| Role | Model |
|---|---|
| Research | Codex gpt-6-astra |
| PM | Cursor composer-2.5-fast |
| UI/UX | Claude claude-opus-5-5 |
| Engineer | Codex gpt-6.1-sol, effort medium (Opus fallback ONLY if owner asks) |
| QA | Claude claude-sonnet-5-5 (+ snapshot PNGs captured by run_qa.sh outside the sandbox) |

## Board (v1)
**Closed:** 1.1 1.2 1.3 1.4 1.5 1.6 1.7 1.8 1.9 1.10 1.11 1.12 1.13 1.15 1.16 1.17 1.19 1.20 1.26 1.28 1.29 1.30 1.31 1.32 1.33 1.34 1.35 1.36 1.37 1.38 1.39 1.42 1.44 

**Held open — waiting for OWNER GUI check (do not close without it):**
- **1.48 (P0) editor stops scrolling / caret can't reach end of long notes.** Fix committed 0a549e1 (ensureLayout + sizeToFit 150 ms after edits; root cause = TextKit lazy viewport layout left the text view frame far shorter than the text, present since 1.5). QA PASS, BUT the orchestrator proved the new LongEditorTests also PASSES on pre-fix code → test does not reproduce the bug. Ask owner to test a long note. If still broken: next attempt must first write a test that FAILS on 964b537.
- **1.40 (P0) blank preview** — fixed (custom URL scheme, 7765e89); snapshots preview/split went timeout→ok; real-WebKit test passes unsandboxed. Owner hasn't confirmed live yet. Open question: preview-mode PNG looked mangled (chrome cut + duplicated scaled preview) — harness compositing or real Preview-only layout bug; ask owner whether Cmd-R preview-only fills the window. Close **1.18** together with 1.40.

**Queued, PM-reviewed + UX notes done, in order:**
1. **1.49** sidebar counts INLINE after the name, MWeb-style "Travels (2)", (0) for empty (owner decision; replaces right-aligned badges that drifted on resize)
2. **1.46** pin Search Library field + Outline header to the top in empty states; "1 document" pluralization
3. **1.47** clean editor: Menlo 15 default (MWeb's pref), headings same size as body, bold, teal heading color (light #2A6A86 / dark #86BCD6), dim # markers
4. **1.51** preview typography: less top padding, H1 divider, tighter heading spacing, H5/H6 ~body size, preview headings use the 1.47 teal
5. **1.50** always show the tab bar when a document is open (hide with none); editor top inset 24→16 pt
6. **1.43** copied images go to visible `media/<doc-id>/` (MWeb-style) + migrate `.silkweb-assets`
7. **1.41** images shown inline in the editor below their line
8. Then P2: **1.45** lossy tab-session decode, **1.14** table insert, **1.21** tags (+ per-tag sort prefs), **1.22** HTML export, **1.23** PDF/print, **1.24** settings (Menlo first, line height 1.6 default), **1.27** focus/typewriter, **1.25** final polish/a11y/word counts (depends on most)

## Owner rules & decisions (binding)
- Pipeline for EVERY owner request/bug, and any re-scoped ticket: Orchestrator drafts (root cause + required tests) → **PM review** → **UX notes** → Engineer → QA (+snapshots) → Orchestrator verifies → close. Only a pure P0 bug with no UI may skip UX (tell owner).
- Before accepting a regression fix, the Orchestrator runs the new test against the pre-fix code; it must FAIL there.
- When the owner tests a build, say exactly which of their reports are IN that build and which are NOT yet (they mistook queued tickets for regressions on 2026-10-02).
- Codex usage limit → pause, stash partial work with a label, `~/.claude/bin/claude-ask` the owner; they reset it; never auto-switch to Opus. On resume, pop the stash and run `run_ticket.sh <id> <n+1>` with a fix note to continue the partial work.
- Ask the owner via `~/.claude/bin/claude-ask "<one line>"` (Slack #marks_claude_alerts via webhook). The current Claude account's Slack connector is NOT connected, so replies come in the terminal / Remote Control (session link was Slacked). Notification hook alerts on permission prompts only.
- Product: tags in sidecar index only; first launch = Open Folder in Place + New Library; Trash browser in v2; inline editor images in v1; MWeb-style clean editor + preview; clean-room (behavior only, never MWeb code/CSS/assets).

## Mistakes this run (avoid repeating)
- Tests that didn't reproduce the bug passed while the bug remained (1.32/1.34 clicks, 1.37 drag, 1.48 scrolling). Always prove the test fails pre-fix.
- QA judged UI by code review; preview was blank for a whole ticket (1.18). Fixed by the snapshot harness (1.42) — QA must view PNGs.
- Tickets filed straight to the Engineer without PM/UX (1.28–1.44). Now always routed.
- Ordering-only beads deps on tickets held open for owner checks block `close_next.sh` — remove the dep at close.
- `sed` with "/" in replacement text broke PM prompts — use Python to build prompts.
- Security-scoped bookmarks + ad-hoc signing broke library reopen (fixed 1.36).

## Commands
- Owner test build: `~/.claude/skills/product-team/scripts/test_latest.sh`
- Next ticket: `close_next.sh <prev> "<reason>" <next>` then `tmux_run.sh eng-<id> run_ticket.sh <id>` (run_in_background). Snapshots: `./scripts/snapshot.sh <dir>` (unsandboxed for WebKit).
