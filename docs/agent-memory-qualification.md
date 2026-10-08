# Agent Memory MVP Qualification (#139)

```text
Gate: P1 slice of #126 (agent memory MVP)
Contract: docs/agent-memory.md, contract_version 1
Last run: 2026-10-08
```

This is the release gate for the agent memory MVP. Each row says how a scenario is exercised, what the owner
must see in the app, and what the helper (`silkweb memory …` or `silkweb mcp`) must report. Automated rows
name the XCTest (all run by `./scripts/build.sh test`). Manual rows have numbered steps.

No row adds UI or copy. Expectations reuse the save gate (#131), create and receipts (#133), Agent Activity
and Info (#137), and today's Editor Banner, conflict banner and recovery banner.

**The P1 gate is open only when every row below passes and the Privacy sign-off row is checked.**

## Privacy sign-off

| Scenario | How | Expected in app | Expected for helper | Result/date |
|---|---|---|---|---|
| Retrieved memory may be sent to the client's cloud model provider. | Owner records a decision on #126. | — | — | [ ] **Open: waiting for the owner's decision on #126** |

## Dirty buffers

| Scenario | How | Expected in app | Expected for helper | Result/date |
|---|---|---|---|---|
| Agent creates and a same-key retry in the open Document's Folder while it has unsaved text | `AgentQualificationWorkspaceTests.testUnsavedTextSurvivesAgentCreatesRetriesAndAnExternalEdit` | Text, caret, focus, tabs and selection unchanged. Status **Edited**, window edited dot on. New rows insert unselected, and no “ 2” row from the retry. Agent Activity counts 2. No banner, no recovery strip, no announcement. After the other writer lets go, autosave writes only the owner's text. | `created`, then `"replayed": true` / `duplicate` for the retry | Pass 2026-10-08 |
| Real external edit to the open file while it has unsaved text | Same test | Conflict banner ““Owner draft” was changed outside Silkweb while you were editing.” with **Compare…**, **Keep My Version**, **Use Disk Version**. Buffer kept, status **Not Saved**, disk keeps the other app's text. Announced once, also when agent creates trigger more watcher ticks. | — | Pass 2026-10-08 |
| Relaunch with unsaved text while agents create (app closed and open) | `AgentQualificationWorkspaceTests.testRecoveredTextSurvivesAgentCreatesAcrossARelaunch` | Recovery banner “Silkweb recovered unsaved changes to this document.” with the recovered text. Agent rows (made while closed and after reopening) arrive without autosaving, moving the selection or announcing. **Keep Recovered Text** then saves it. | `created` / `duplicate` | Pass 2026-10-08 |
| Agent receipt arrives while a human Document is open and focused | `AgentActivityWorkspaceTests.testOffscreenLoadResizeAndReceiptArrivalKeepFocusSelectionAndTabs` (#137) | Focus, caret, selection and tabs unchanged; the Agent Activity row appears. | — | Pass 2026-10-08 |
| Autosave waits for the gate; edits typed meanwhile join the commit | `LibraryGateTests.testAutosaveWaitsQuietlyAndSavesEditsTypedDuringTheWait` (#131) | Stays **Edited** while waiting. | — | Pass 2026-10-08 |
| Visual: edited Document stays open while an agent row arrives in its Folder | Snapshot `agent-qual-dirty-open` (light, dark) | Coral tab dot, **Edited**, the new row above the selected Document. | — | Captured 2026-10-08 |

## Concurrency

| Scenario | How | Expected in app | Expected for helper | Result/date |
|---|---|---|---|---|
| Retry from a second session while the first create of that key is mid-publication | `AgentQualificationTests.testRetryRacingAnInFlightCreateOfTheSameKeyPublishesOnce` (regression: fails with the gate removed) | One row, no “ 2” copy. | First `created`, retry `"replayed": true` with the same receipt | Pass 2026-10-08 |
| Owner adds a Tag while a helper create commits | `AgentQualificationTests.testAppTagCommitDuringHelperCreateKeepsTheTagAndTheNewIdentity` (regression: fails with the gate removed) | The Tag stays; the new Document keeps the identity in its receipt. | `created` | Pass 2026-10-08 |
| Six helper processes, each retrying one shared key, while the app keeps tagging | `AgentQualificationTests.testParallelHelperProcessesKeepDocumentsTagsAndReceipts` (the built `SilkwebHelper`) | Exactly one row per create; all 20 Tags kept; Agent Activity count equals the receipts. | Every process exits 0; the shared key is created once and replayed 17 times; 19 receipts, each matching the index | Pass 2026-10-08 |
| Concurrent creates for one name, concurrent retries of one key | `AgentCreateTests.testConcurrentCreatesForTheSamePathNeverReplaceEachOther`, `…testConcurrentRetriesOfOneKeyPublishOnce` (#133) | Owner's file untouched. | Distinct “ 2”… names; one publish per key | Pass 2026-10-08 |
| App save vs helper commit, tag commits, scans vs helper writes | `LibraryGateTests` (#131) | No lost text or Tags; contention is never a conflict. | `library_busy` with `retryAfter` after 5 s | Pass 2026-10-08 |
| Visual: save while another process holds the gate | Snapshot `save-gate-busy` (#131) | Existing banner with “Another Silkweb process is updating this library. Silkweb will try again.” | — | Reused |
| Visual: receipt arrives with another agent Document open | Snapshot `agent-receipt-arrives` (#137) | Selection and tabs unchanged. | — | Reused |

## Failures

| Scenario | How | Expected in app | Expected for helper | Result/date |
|---|---|---|---|---|
| App save, disk full | `SaveCoordinatorTests.testFailureSweepRetainsOriginalDraftAndRecoveryAcrossLaunches`; snapshot `save-disk-full` | Banner “Silkweb couldn’t save “Name”. Your text is safe in this window.” with the detail “There isn’t enough space on the disk. …”, **Try Again** / **Save a Copy…**, status **Not Saved**, text kept, recovery draft written. | — | Pass 2026-10-08 |
| App save, permission denied | `AgentQualificationWorkspaceTests.testPermissionDeniedSaveKeepsTextWithTheBannerAndAnnouncesOncePerAttempt` (real read-only Folder); snapshot `save-permission-denied` | Same banner with “You don’t have permission to write to “Folder”. …”, **Not Saved**, text kept. Announced once per failed attempt (also after **Try Again**). Saves once writable. | — | Pass 2026-10-08 |
| Helper create, disk full | `AgentQualificationTests.testDiskFullBeforePublishCreatesNothingAndCanBeRetried` (injected `ENOSPC`/`EDQUOT`) | Nothing in the sidebar, list, search or Finder. | `disk_full` (exit 74), “There isn’t enough space on the disk. Nothing was created.”; the same key creates once space is freed | Pass 2026-10-08 |
| Helper create, permission denied (destination Folder or `.silkweb/` read-only) | `AgentQualificationTests.testPermissionDeniedCreatesNothingAndCanBeRetried` | Nothing appears. | `permission_denied` (exit 74); receipt `abandoned`; the same key creates once writable | Pass 2026-10-08 |
| Client cancellation (MCP) | `AgentMCPTests.testCancellationSkipsQueuedCallsAndLetsStartedCreatesFinishSilently`, `…testEOFReturnsZeroAfterInFlightWorkSettles` (#136) | At most one row; never half a file. | No response to the cancelled call (no error code); a retry with the key replays | Pass 2026-10-08 |
| Crash mid-publication (after the journal, publish, index or receipt step) | `AgentQualificationTests.testCrashMidPublicationIsInvisibleToTheAppAndSettlesOnTheNextCreate`; `AgentCreateTests` failure injection (#133) | The app scan shows no recovery strip and nothing from `.silkweb/`; zero rows before publish, exactly one after. | The next create settles it silently (`abandoned` or `reconciled`); the retry replays or creates once | Pass 2026-10-08 |
| App opens after a helper crashed while it was closed | `AgentQualificationWorkspaceTests.testInterruptedPublicationOpensSilently` | No recovery strip, no alert, no banner, no announcement; the published Document is one ordinary row. | — | Pass 2026-10-08 |
| Receipt can't be written after publish | `AgentCreateTests.testReceiptWriteFailureKeepsThePublishedDocument` (#133) | The Document stays. | `write_failed`; the retry replays as `reconciled` | Pass 2026-10-08 |
| Files saved by earlier builds | `AgentCreateTests.testReceiptsAndLimitsDecodeTolerantly`, `SaveCoordinatorTests.testRecoveryTolerantDefaultsAndFutureVersionRejection` | Older index, receipts, grants and recovery drafts still load. | — | Pass 2026-10-08 |

## Real clients (manual)

Run once per client with the app **closed**, then again with Silkweb open on the Library and an unsaved edit in
a Document under `Memory/Projects/<Project>/Progress`. Setup for every client:

1. `./scripts/build.sh`, then `ln -sf "$PWD/build/helper/silkweb" ~/.local/bin/silkweb`.
2. Write `~/Library/Application Support/Silkweb/agent-grants.json` with one `read-create` grant for a
   scratch Library (see `docs/agent-memory.md` › Spike, step 3).
3. Install the client's package from `agent-packages/README.md`.
4. Record the client's version in the Result column.

| Scenario | How | Expected in app | Expected for helper | Result/date |
|---|---|---|---|---|
| Claude Code | 1. `claude --version`. 2. Ask: “Save a progress checkpoint for this session in Silkweb memory.” 3. Ask it to repeat the save with the same request key. 4. Ask: “What do we know about the helper spike?” 5. Cancel a save mid-call (Esc), then ask it to save again. | One new row per checkpoint in Progress, unselected; open editor, caret and **Edited** unchanged; Agent Activity count +1. | `memory_create` succeeds; the repeat is `duplicate`; search finds it; the cancelled save leaves at most one row | [ ] version ___ |
| Codex | Same steps with `codex` (`codex --version`). | Same. | Same | [ ] version ___ |
| Gemini CLI | Same steps with `gemini` (`gemini --version`). | Same. | Same | [ ] version ___ |
| Grant turned off mid-session | With any client: set `revoked_at` in the grants file, then ask for another save. | No new row. | `grant_revoked`; the skill says “Checkpoint not saved (grant_revoked).” and keeps the handoff in chat | [ ] |
| Disk full / read-only Library (optional) | Make the Progress Folder read-only (`chmod 555`), ask for a save, then restore it. | No new row; the open editor is untouched. | `permission_denied`; the skill keeps the handoff in chat and doesn't retry | [ ] |

## Regression evidence

The concurrency rows fail on the pre-fix code. With `LibraryGate.withLease` reduced to `return try body()`
(no gate: the code before #131, which #133's create relies on), `AgentQualificationTests` failed 3 of 6:

- `testAppTagCommitDuringHelperCreateKeepsTheTagAndTheNewIdentity`: the helper's identity was lost (`nil`).
- `testRetryRacingAnInFlightCreateOfTheSameKeyPublishesOnce`: the retry's recovery abandoned the live attempt,
  which then failed with `write_failed`.
- `testParallelHelperProcessesKeepDocumentsTagsAndReceipts`: helper processes exited 74 (`write_failed`).

The announcement rows fail without #139's fix in `DocumentSession.announce`: the conflict was announced 9
times instead of once, and **Try Again** announced its failure twice.
