# Silkweb Agent Memory Contract

```text
contract_version: 1
Last reviewed: 2026-10-07 (#129)
```

This is the source of truth for how coding agents (Claude Code, Codex, Gemini and other local MCP
clients) read and create memory in a Silkweb Library. Later tickets (#130–#139) link here instead of
redefining names, layout or guarantees. Changing a rule here means bumping `contract_version`.

## Overview

- One native executable, `silkweb`, with two entry points that share one UI-free service in
  `SilkwebCore`:
  - `silkweb mcp`: a long-lived **stdio** MCP server launched by the agent (#136). It doesn’t
    listen on a port, and there’s no HTTP transport.
  - `silkweb memory …`: one-shot CLI commands that print JSON (#135).
- The helper works while the Silkweb app is **closed**. No daemon runs in the background. When the app
  opens again, it picks up the new documents from disk like any other external change.
- Agents read only what the owner grants, which by default is the project’s `Memory` folder. In MVP
  they can create new documents but never edit, replace, move or delete existing ones.
- Memory is ordinary Markdown in ordinary Folders, so the owner can read it without Silkweb.
- **Local storage doesn’t mean local processing.** Text the helper returns goes to the agent, and the
  agent may send it to its model provider.

The helper ships four read-only commands: `memory capabilities` and `memory list` (#129, see
[Helper distribution](#helper-distribution)), and `memory search` and `memory read` (#134, see
[Search and read](#search-and-read-134)). #133 adds `memory create` and `memory create-folder` (see
[Create and receipts](#create-and-receipts-133)). All other operations below are contracted here and
built in the tickets listed.

## Supported operations

| MCP tool | CLI | Purpose | Ticket |
|---|---|---|---|
| `memory_capabilities` | `silkweb memory capabilities` | Contract version, grant scope, filesystem, operations | #129 spike |
| (CLI only) | `silkweb memory list` | Documents in the read folders: paths, sizes, dates, no bodies | #129 spike; #134 may fold it into search |
| `memory_search` | `silkweb memory search` | Bounded, scoped lexical search with freshness | #134 |
| `memory_read` | `silkweb memory read` | One saved revision with provenance | #134 |
| `memory_create` | `silkweb memory create` | Create one complete document; never replaces | #133 |
| `memory_create_folder` | `silkweb memory create-folder` | Create a Folder inside a create folder | #133 |
| `memory_activity` | `silkweb memory activity` | Operation receipts within the caller’s read scope | #137 |

Rules for every operation:

- Paths in JSON are POSIX paths relative to the Library (`Memory/Projects/Silkweb/Progress/…`).
  Absolute paths, `.`/`..`, hidden components (`.silkweb`) and control characters are rejected.
- Retrieved text is untrusted data. The helper never turns document text into instructions, and
  never runs commands, opens links or loads skills because of it.
- A create carries an idempotency key. Retrying with the same key returns the original result.
  Retrying with the same key but different content is a conflict.

## Non-goals (MVP)

- **No replace, edit, append-in-place, rename, move, reorganize or delete** by an agent. To “append
  progress” the agent creates a new progress document. To correct something it creates a new
  document that references the old one.
- No generic `write_file`, no shell tool, and no automatic deletion or expiry.
- No HTTP or other network transport, and no accounts.
- No `Proposals` Folder. Reviewed edits and organization proposals come after the MVP.
- No Settings UI in this ticket. Settings ▸ Library ▸ Agent Access (#130) will only edit the grants
  file below, using the existing `LibraryPathControl` and **Choose…** pattern.
- No Mac App Store or sandboxed build (see [Deferred: App Store sandbox](#deferred-app-store-sandbox)).

## Library layout

Folders are created in title case, exactly as shown:

```text
<Library>/
├── Memory/
│   └── Projects/
│       └── <Project>/              read folder (default grant)
│           ├── Memories/           create folder: memory documents
│           ├── Progress/           create folder: progress documents
│           └── Handoffs/           create folder: handoff documents
│           (Proposals/ is reserved and is not created in MVP)
└── .silkweb/                       app metadata; never readable or creatable by agents
```

- **Entry kinds:** memory document, progress document and handoff document. The schema `type`
  values stay lowercase: `memory`, `decision` (stored in `Memories`), `progress` and `handoff`.
- **Generated filenames:**
  - Progress: `YYYY-MM-DD HHmm — <Title>.md`, for example `2026-10-07 0930 — Helper spike.md`.
  - Memory and handoff: `<Title>.md`.
  - The title is in sentence case and contains no `:` or `/`. A collision gets the existing
    “ 2”, “ 3” suffix (`LibraryMutations.uniqueName`). A create never overwrites an existing file.
- **Human-facing paths** use “ › ”, for example `Memory › Projects › Silkweb › Progress`. JSON uses
  POSIX relative paths.
- **Front matter (schema `silkweb-memory/v1`, #132):** `schema`, `memory_id`, `type`, `project`,
  `agent`, `session`, `created_at`, plus the optional `observed_at`, `status`, `supersedes` and
  `review_after`. The helper assigns `memory_id` and `created_at`. `agent` and `session` are
  claims, not authentication. Tags stay in Silkweb’s index (`.silkweb`) and are not a YAML key.
  Review, pin and archive state belongs to the human and lives in app metadata. Unknown keys are
  kept. Documents that are malformed or use a newer schema still open as plain text. See
  [Envelope](#envelope).

## Envelope

Every document an agent creates starts with a portable front matter envelope, schema
`silkweb-memory/v1` (#132, `MemoryEnvelope` in `SilkwebCore`). The rest of the file is ordinary
Markdown, so the document still reads like any other Silkweb Document.

On disk the envelope is a leading `---` line, one `key: value` per line, a closing `---` line, one blank
line, then the body. The body starts with `# <Title>`, matching the generated filename.

| Key | Required | Value | Set by |
|---|---|---|---|
| `schema` | Yes | `"silkweb-memory/v1"` | Helper |
| `memory_id` | Yes | Quoted string, the portable identity | Helper |
| `type` | Yes | `"memory"`, `"decision"`, `"progress"` or `"handoff"` | Agent |
| `project` | Yes | Quoted project key from the grant | Helper |
| `agent` | Yes | Quoted string, a claim, not authentication | Agent |
| `session` | Yes | Quoted string, a claim, not authentication | Agent |
| `created_at` | Yes | Quoted ISO 8601 UTC timestamp, `"2026-10-06T15:00:00Z"` | Helper |
| `observed_at` | No | Quoted ISO 8601 UTC timestamp | Agent |
| `status` | No | Quoted string | Agent |
| `supersedes` | No | Flow list of `memory_id` strings, `[]` or `["a", "b"]` | Agent |
| `review_after` | No | Quoted ISO 8601 UTC timestamp | Agent |

An annotated v1 progress document, `Progress/2026-10-07 0930 — Helper spike.md`:

```markdown
---
schema: "silkweb-memory/v1"
memory_id: "mem_01JA2B3C4D5E6F7G8H9J0K1L2M"
type: "progress"
project: "Silkweb"
agent: "claude-code"
session: "2026-10-07-a"
created_at: "2026-10-07T09:30:00Z"
status: "in-progress"
supersedes: []
x-source-ticket: "#129"
---

# Helper spike

Objective: prove the helper reads the Library with the app closed.

Next action: wire `memory_create` (#133).
```

- The first twelve lines are the envelope. The v1 keys are written in the order of the table above, then
  unknown keys (here `x-source-ticket`) in their original order, byte for byte.
- The blank line after the closing `---` separates the envelope from the body. Creating the document
  inserts the envelope and that blank line, and never changes the body bytes.
- The Document list skips a well-formed envelope, so this row reads “Objective: prove the helper reads
  the Library with the app closed. …”. The editor shows the envelope as plain, editable text.
  Preview, Outline, word count and export render it as ordinary Markdown for now (#137).

### Silkweb envelope subset

The envelope is read with the **Silkweb envelope subset**, not a YAML parser:

- Keys are `[A-Za-z_][A-Za-z0-9_-]*`, at the start of the line, with no repeats.
- Values are double-quoted strings (escapes `\"`, `\\`, `\/`, `\n`, `\t`, `\r`, `\uXXXX`),
  single-quoted strings, plain strings without `: ` or ` #`, flow lists (`[]`, `["a", "b"]`) or block
  lists (`- item` lines) of strings. A key with no value is an empty string. Silkweb always writes
  double-quoted strings and flow lists.
- Blank lines inside the envelope are ignored. There are no comments, anchors or nested maps.
- An unknown key whose value is outside the subset (for example a nested map) is kept byte for byte and
  reported as unparsed. The same thing under a v1 key makes the envelope malformed.

### Reading rules

- **No envelope.** A document that doesn’t start with `---`, or whose front matter has no
  `silkweb-memory` schema (front matter from other tools, a leading thematic break), is an ordinary
  Library Document. Tools report `"envelope": null`, and that isn’t an error.
- **Malformed or newer.** The document still opens as plain text and is never rewritten or truncated.
  Tools report one of these errors, with no document text:

  | `error.code` | Message |
  |---|---|
  | `envelope_malformed` | The front matter in “Name” couldn’t be read (line 4). The document is unchanged. |
  | `envelope_schema_newer` | “Name” uses schema “silkweb-memory/v2”, which this version of Silkweb doesn’t support. The document is unchanged. |

- **Creating.** The helper validates the envelope before writing it. A missing or invalid v1 field is
  `envelope_invalid_field` (“The front matter field “type” is missing or invalid.”). Only the create
  pipeline ever writes an envelope. Opening, editing and autosaving never reserialize it, and agents
  can’t edit an existing envelope in MVP (#140).

### Ownership

- `memory_id` is the portable identity. It stays with the file, also when it’s copied outside Silkweb.
- The app index (`.silkweb/index.json`) owns the native document UUID and Tags. Neither is an
  envelope key. A `tags` or `id` key is just an unknown key that Silkweb keeps but never reads.
- Review, pin and archive state belong to the human and live in versioned app metadata (`.silkweb/`),
  never in the envelope.

## Grants

Grants live **outside the Library**, so a document inside it can’t widen its own access:

```text
~/Library/Application Support/Silkweb/agent-grants.json
```

```json
{
  "version": 1,
  "grants": [
    {
      "project": "Silkweb",
      "library": { "version": 1, "path": "/Users/me/Writing" },
      "access": "read-create",
      "extra_read_folders": ["Reference/Silkweb"]
    }
  ]
}
```

- `version` is the file format version. A helper refuses files from a newer version
  (`unsupported_grants_version`). Missing keys decode to defaults, so files from earlier builds
  still load.
- `project` is the exact project key and a single Folder name. Agents choose a grant by project,
  but naming a project never grants access by itself. Access comes only from this file.
- `library` is the same versioned `LibraryLocation` the app saves (a `path`, plus an optional
  `bookmark`). The helper resolves it the same way the app does, and never writes the file back.
- `access` is `read` or `read-create`. An unknown value is treated as `read`.
- **Default template:**
  - Read folders: `Memory/Projects/<Project>/`, plus any `extra_read_folders`. Extra read folders
    are read-only, relative to the Library, and validated like any other path.
  - Create folders: `Memory/Projects/<Project>/Memories`, `…/Progress` and `…/Handoffs`, and only
    for `read-create` grants on a qualified filesystem.
- Containment is checked per path component and compared like APFS: Unicode normalization never
  matters, and case is ignored unless the Library’s volume is case-sensitive.
  `Memory/Projects/Silkweb2` isn’t inside `Memory/Projects/Silkweb`. Symbolic links and hidden items
  are never followed or listed.
- MCP roots and client names may narrow a grant but never widen it.

### Profiles, limits and revocation (#130)

The grant file above stays `version: 1`. These keys are optional, so files saved by the #129 spike
still load unchanged:

```json
{
  "access" : "read",
  "created_at" : "2026-10-07T09:30:00Z",
  "extra_read_folders" : [],
  "label" : "Silkweb project",
  "library" : { "path" : "/Users/me/Writing", "version" : 1 },
  "limits" : { "max_create_bytes" : 262144, "max_read_bytes" : 1048576, "max_results" : 200, "requests_per_minute" : 120 },
  "project" : "Silkweb",
  "revoked_at" : "2026-10-08T17:00:00Z"
}
```

- **Profiles:** `read` is shown as **Read Only** and `read-create` as **Read and Create**. `read-only`
  is accepted as another spelling of `read`. Read Only allows capabilities, list, search, read and
  activity inside the read folders. Read and Create adds create and create-folder, only inside the
  create folders. Agents can’t replace or delete anything with either profile.
- The template is called **Project memory** (see the default template above).
- `label` is the owner-facing name used in messages. When it’s empty, it’s “<Project> project”.
- `limits` bound one document read (`max_read_bytes`), the rows one search, list or activity page
  returns (`max_results`) and the operations per rolling minute in one helper session
  (`requests_per_minute`). `max_create_bytes` (#133) bounds one created document, front matter included.
  A missing or non-positive value uses the default shown.
- `revoked_at` turns the grant off. Any non-null value counts, even one that can’t be parsed. Removing
  the date (or the `null` value) turns it back on. Silkweb writes this file atomically with sorted keys.
- **Revocation fails closed on the next operation.** Before every operation the helper checks the
  grant file’s modification date, inode and size, which costs one `stat`, and re-reads the file when
  any of them change. After the owner turns a grant off, removes it or deletes the file, the session’s
  next operation gets `grant_revoked`. A narrower profile or fewer folders apply on the next operation
  too. An operation that was already authorized finishes, and a create publishes atomically (#133),
  so it’s either complete or absent, never half-written.
- **Scope filtering comes first.** Search, list and activity drop out-of-scope documents before
  ranking, counting, faceting or building snippets. Totals, “N more”, tag counts and activity rows
  cover only in-scope documents, so an empty in-scope result looks the same whatever lies outside.
- **On disk,** every path is opened one component at a time below the Library root without following
  links, so a Folder swapped for a link between the check and the use can’t redirect a read. Reads
  accept only regular files. The Library root itself may be a link the owner chose.
- **MCP roots** are intersected with the grant: a client root inside a granted folder narrows it, a
  granted folder inside a client root stays as it is, and anything else (including invalid roots) is
  dropped. An empty list grants nothing.

### Refusals

`error.code` values are stable. Messages are sentence case with curly quotes, and never include
document text or the requested target.

| Code | Message |
|---|---|
| `out_of_scope` | That location is outside this grant’s read folders (Memory › Projects › Silkweb). For creates, “create folders” and the create folders. Whether the target exists is never revealed. |
| `create_not_allowed` | This grant is Read Only. Ask the owner to switch it to Read and Create. (On an unqualified filesystem: This Library isn’t on a local disk, so agents can only read it.) |
| `invalid_path` | Paths must stay inside the Library and can’t use “..”, links or special files. One message for traversal, links, special files and `.silkweb` paths. |
| `excluded_name` | Agents can create only Markdown documents, never instruction files or reserved Folders. |
| `grant_revoked` | Agent access “Silkweb project” was turned off. Ask the owner to turn it back on. |
| `rate_limited` | Too many requests. Try again in N seconds. |
| `too_large` | That document is larger than this grant’s read limit (1 MB). For creates: This document is larger than the grant allows (256 KB). Nothing was created. |
| `not_found` | There’s no document at that location. (Only for targets inside the scope.) |

The Settings ▸ Library ▸ Agent Access section and the commands that set grants up come later
(#135); they only edit this file.

## Filesystems

**Owner decision (2026-10-07): the MVP supports local-disk Libraries only.** iCloud Drive, Dropbox and
network volumes are qualified later.

| Library on | `filesystem` | Reads | Creates |
|---|---|---|---|
| Local APFS or HFS+ volume | `qualified` | Yes | Yes, if the grant is `read-create` |
| iCloud Drive (`~/Library/Mobile Documents`) | `unqualified` | Yes | No |
| File Provider sync, such as Dropbox or Google Drive (`~/Library/CloudStorage`) | `unqualified` | Yes | No |
| Network volume (SMB, AFP, NFS), or a FAT/exFAT disk | `unqualified` | Yes | No |

`memory_capabilities` reports the classification. On an unqualified filesystem, `create_roots` is
empty. Reads stay available because reading can’t lose text. The helper can’t detect older sync
clients that mirror an ordinary local folder without File Provider, so don’t grant such a Library.

## Durability and the human-text guarantee

> Agent operations through Silkweb never silently overwrite an existing human document or discard
> a dirty editor buffer. When there’s an unresolved conflict, both texts are kept.

**Scope.** The guarantee holds when every writer is a cooperating Silkweb writer (the app and the
`silkweb` helper, contract version 1 or later) and the Library is on a **qualified local
filesystem**. It doesn’t cover:

- other programs running as the same user that edit the files directly,
- storage or hardware failure,
- keystrokes typed just before a machine crash that hadn’t been autosaved yet,
- unqualified filesystems.

How the write path keeps it (built in #130–#133):

1. Resolve the grant and check the destination is inside a create folder.
2. Validate the content, schema, size and idempotency key.
3. Stage the complete UTF-8 file on the same volume as the destination.
4. Publish without replacing anything (exclusive create). A name collision gets the next “ 2” name.
5. Write an operation receipt under `.silkweb/`. A crash between steps 4 and 5 is reconciled on the
   next start. A published document is never deleted because its receipt failed.
6. Report success only after the document is durably on disk.

The app keeps its dirty-buffer protection. An external change never replaces unsaved editor text,
and conflicts keep both versions.

### Coordination (#131)

Cooperating writers (the app and the helper) serialize every **commit** through one gate per
Library. Scans and reads never wait for it.

- **The gate** is an exclusive `flock` on `<Library>/.silkweb/library.lock` (`LibraryGate`). The
  lock file holds the holder’s pid while it’s held and is emptied on release. It lives under
  `.silkweb/`, so nothing appears in the Library tree, and the app’s watcher ignores it.
- **Held for:** a document replacement from its revision check to its rename, and every
  read-modify-write of `.silkweb/index.json`: tag edits, new Folder or document, rename, move,
  Move to Trash and Put Back, and the scan’s index commit. Staging a file happens before the gate.
- **Scans** enumerate outside the gate. Before writing identities, the app re-reads the index inside
  the gate. If it changed since the scan started (a **stale snapshot**), the scan runs again from the
  new index. The third attempt enumerates inside the gate, so a busy Library still converges. Only the
  app sets an undecodable index aside, and it does that inside the gate too.
- **Headless reads** (`LibraryScanner.scan(…, writesMetadata: false)`) never rename, repair or write
  anything, never create `.silkweb/` or the lock file, and never wait for the gate. Identities for
  documents the index doesn’t know yet are temporary. Index recovery and the recovery strip stay
  app-only and show on the next app open.
- **Waiting:** a writer waits up to **5 seconds**. In the app the wait happens on `SaveCoordinator`,
  never on the main thread. The document stays **Edited** while it waits, and edits typed meanwhile go
  into the same commit. After the wait the app uses its existing save-failure banner with the detail
  “Another Silkweb process is updating this library. Silkweb will try again.”, keeps the text, writes
  the recovery draft and retries autosave on its own. Library operations use their usual failure
  alert with the same detail. Contention is never a conflict, so a “(Conflict …)” copy is made only
  when the revision really changed.
- **Crashes and stale locks:** the kernel releases a `flock` when its process exits or crashes, so
  a lock can’t outlive its holder, and no lease timeout or lock breaking is needed. A pid left in
  the lock file means the last holder died while holding the gate. The next holder takes over
  silently and gets that pid as `staleHolder`, for the helper’s diagnostics only (never in a
  document). Commits are atomic renames, so a crash leaves the old file or the new one, never a mix.
- **Where it doesn’t lock:** if `.silkweb/` can’t be created or the volume has no `flock` (a
  read-only Library, some network volumes), the lease is non-exclusive and the write itself decides.
  Unqualified filesystems aren’t covered by the guarantee anyway (see [Filesystems](#filesystems)).

Helper errors for coordination (stable `error.code`):

| Code | Title | Message |
|---|---|---|
| `library_busy` | Library Busy | Silkweb is updating this library. Try again in a moment. The JSON error includes `retry_after` (seconds). |
| `stale_snapshot` | Library Changed | The library changed while this request ran. Try again. (Retried internally first, then reported only if the retries run out.) |

## Search and read (#134)

`memory_search` and `memory_read` are the agent's read path. They work with Silkweb closed, never take
the Library gate, never write to the Library and never wait for the app. The CLI (#135), MCP server
(#136) and skills (#138) present the fields below as they are and don't rename them.

```sh
silkweb memory search --project Silkweb [--query <text>] [--type decision,memory] [--status <s,…>] \
  [--created-after 2026-10-01] [--created-before 2026-10-08] [--filter-project Silkweb] [--limit 10]
silkweb memory read --project Silkweb --path "Memory/Projects/Silkweb/Memories/Use flock.md" \
  [--cursor <nextCursor>] [--expected-revision sha256:…]
```

### Search request

- `query`: text, may be empty. Every word must appear in the title (the filename) or the body; matching
  ignores case and diacritics, like the app.
- `project`: optional, and must be the grant’s own project, otherwise `out_of_scope`. It keeps documents
  whose envelope `project` matches, plus documents without an envelope inside `Memory/Projects/<Project>`.
- `type`: a list of `memory`, `decision`, `progress` or `handoff`. `status`: a list, compared without
  regard to case. Once either is set, documents without an envelope drop out.
- `createdAfter` (inclusive) and `createdBefore` (exclusive): `2026-10-07` (midnight UTC) or an ISO 8601
  timestamp, compared with `created_at`. Documents without an envelope use their modified date.
- `limit`: default 10, at most 50, and never more than the grant’s `max_results`.
- **Scope comes first.** Only documents inside the read folders are matched, ranked, counted or excerpted.

### Search response

`results`, `total` (matching in-scope documents before `limit`), `index`, and `message` when there are
no results. Each result has these fields, in this order:

| Field | Value |
|---|---|
| `title` | The filename without `.md` |
| `path` | Library-relative POSIX path |
| `documentId` | The app index’s native UUID, or `null` until the app has seen the document |
| `memoryId` | Envelope `memory_id`, or `null` |
| `revision` | `sha256:` + hex digest of the file’s bytes |
| `type`, `project`, `status`, `agent`, `session`, `createdAt` | Envelope values as written, or `null` |
| `modified` | ISO 8601 UTC |
| `review` | `reviewed`, `unreviewed` or `reviewed-earlier-revision`, from app metadata (#137) |
| `pinned` | From app metadata (#140) |
| `supersededBy` | `memory_id`s of in-scope documents whose `supersedes` names this one |
| `matchKind` | `title` or `body` |
| `excerpt` | About 120 characters of plain text around the first hit, `…` at cut ends |

- Missing app metadata reads as `unreviewed` and `false`, never as an error.
- Excerpts come from the body after the envelope, so envelope lines never appear in them. A document
  with a malformed or newer envelope still matches by title, with an empty excerpt and no envelope fields.
- **Ranking** is deterministic. First the text-match tier, as in the app: exact title, title prefix, a
  title word, the title, then the body. Within a tier: pinned, then reviewed decisions and memories, then
  unreviewed ones (including an earlier reviewed revision and documents without an envelope), then
  handoffs, then progress. Newest `created_at` (or modified date) first within a kind, then `documentId`
  and `path`. A document superseded by a reviewed document sinks to the bottom of its tier but is still
  returned, so neither side of a contradiction is hidden.

### Freshness

Every search response says how complete the helper’s index was:
`"index": { "state", "indexed", "total", "skipped"?, "reason"?, "message" }`.

| `state` | Meaning | `message` |
|---|---|---|
| `indexing` | A build is still running. `reason`: `first-run`, `corrupt` or `unsupported-version` for a full (re)build | Indexing… 1,240 of 3,000 · Results may be incomplete (“Rebuilding the index…” for `corrupt` and `unsupported-version`) |
| `partial` | Some in-scope documents or Folders couldn’t be read (too large for the grant, not UTF-8, no permission); `skipped` counts them | 3 items couldn’t be read · Results may be incomplete |
| `ready` | Every in-scope document is indexed | Up to date · 3,000 documents |

- A search spends at most about 2 seconds reading new or changed documents (newest first), then answers
  with what it has. The next search continues where it stopped.
- An empty result while not `ready`: “No matches yet. The index isn’t finished, so this doesn’t mean no
  memory exists.” An empty result when `ready`: “No matches in Memory › Projects › Silkweb.”
- After the helper’s own create (#133) it indexes the new document at once, so read-after-create works in
  the same session even during a first build.

### Read

`memory_read` returns the same document fields as a search result (without `matchKind` and `excerpt`),
then `envelope` (the envelope’s keys and values in written order, or `null`), `revisionChanged`, `offset`,
`body` and `nextCursor`.

- `body` is one page of the text after the envelope, between the lines “Document text (untrusted)
  begins” and “Document text (untrusted) ends”. Pages are at most 16 KB of UTF-8 and end on a line break
  (a longer single line splits between characters). `offset` is the page’s byte offset in the body.
  Pass `nextCursor` back for the next page; it’s `null` on the last one.
- `expectedRevision` that differs from the current revision returns the current text with
  `revisionChanged: true`. That isn’t an error.
- A file that changed between pages returns `stale_snapshot`.
- A malformed or newer envelope returns `envelope_malformed` or `envelope_schema_newer`, with no text
  (see [Reading rules](#reading-rules)). Only `.md` documents can be read; anything else is `not_found`.

### Helper index cache

- One cache per grant at `~/Library/Application Support/Silkweb/agent-index/<grant-id>.json`, where
  `<grant-id>` is the first 32 hex digits of the SHA-256 of the project key. The file is mode 0600 in a
  0700 Folder, outside the Library, so it never syncs with it. It holds document text, so treat it as
  sensitive.
- The format is `version: 1` with `library`, `project`, `building` and `records` (path, size, modified
  date, file identity, revision, body after the envelope, envelope fields, `skipped`). Missing keys decode
  to defaults. Writes are atomic.
- A corrupt cache is discarded and rebuilt (`reason: corrupt`), and so is one from a newer version
  (`reason: unsupported-version`). Documents are never touched. A cache for another Library is a fresh
  `first-run`.
- The helper never reads or writes the app’s `.silkweb/search-index.json`. It only reads
  `.silkweb/index.json` for `documentId`, without repairing or creating anything (#131).
- When the grant is turned off or removed, the next search or read deletes its cache.
- Performance (AGENTS.md): with 10,000 documents in 1,000 Folders inside one grant, a search from a
  cached index answers in well under a second; a first build is bounded by the 2-second budget per search.

Errors for search and read, in addition to the [refusals](#refusals):

| Code | Title | Message |
|---|---|---|
| `invalid_argument` | Invalid Request | The option “type” isn’t valid. (Also `limit`, `cursor` and the dates.) |
| `unreadable` | Can’t Open Document | That document isn’t UTF-8 text. |
| `envelope_malformed`, `envelope_schema_newer` | Can’t Read Front Matter | See [Reading rules](#reading-rules). |
| `stale_snapshot` | Library Changed | The library changed while this request ran. Try again. |

## Create and receipts (#133)

A create publishes exactly one new Document and never replaces anything (`AgentCreateService` in
`SilkwebCore`):

```sh
silkweb memory create --project Silkweb --key 7f3c-checkpoint-1 --type progress \
  --title "Helper spike" --agent claude-code --session 2026-10-07-a --body-file - < body.md
silkweb memory create-folder --project Silkweb --path "Memory/Projects/Silkweb/Progress/Sprint 1"
```

- **Where it goes:** `--type` picks the entry folder (`memory` and `decision` → `Memories`,
  `progress` → `Progress`, `handoff` → `Handoffs`), or `--folder` names a Folder inside a create
  folder. Missing Folders are made on demand in the case given (the defaults are title case) and get
  identities in the app index like any new Folder. `create-folder` is idempotent: an existing Folder
  returns `"created": false`.
- **Name:** the [generated filename](#library-layout). A taken name gets the next “ 2”, “ 3” suffix,
  re-checked atomically at publish (`RENAME_EXCL`), so a create never replaces a file and never fails
  because the name is taken.
- **Text:** the helper writes the v1 envelope (`memory_id`, `created_at` and `project` are its own),
  one blank line, then the body. A body that doesn’t start with `# <Title>` gets that heading. A body
  that brings its own Silkweb envelope is refused (`envelope_malformed` or `envelope_invalid_field`).
- **What appears:** one new Document, through the app’s normal watcher refresh. Selection, scroll,
  caret and the open editor don’t change, and nothing opens.

**Commit order.** Everything below holds the [Library gate](#coordination-131):

1. Interrupted creates are recovered (below).
2. The key’s receipt is checked: same payload → replay, different payload → `idempotency_conflict`.
3. The complete file is written to `.silkweb/agent-staging/<attempt>.md` and flushed.
4. The intent `<attempt>.json` is written next to it (operation, key, digests, destination Folder,
   `memory_id`, document UUID).
5. The staged file is renamed into place without replacing (exclusive create) and the Folder is flushed.
6. The document UUID is added to `.silkweb/index.json` (skipped if the index is unreadable or
   newer, which the app recovers).
7. The receipt is written to `.silkweb/agent-events/<operationId>.json`, then the intent is removed.

Nothing in `.silkweb/` appears in the tree, list or search, and the watcher ignores it.

**Idempotency.** `operationId` is derived from the grant and the key, so a retry finds its receipt by
name. The payload is everything the agent chose (type, title, body, folder, agent, session and the
optional envelope fields), but not `--client`.

- Same key, same payload: no new file and no change to the existing one. The original receipt comes
  back with `"replayed": true` and `"outcome": "duplicate"`, and `path` is the document’s **current**
  path, found through its index UUID (so renames and moves are followed). `path` is `null` when the
  owner trashed or deleted it, or moved it outside the read folders. It’s never recreated.
- Same key, different payload: `idempotency_conflict`, and nothing on disk changes.
- A key whose earlier create was `abandoned` or `refused` can be retried, with any payload.

**Recovery** runs silently before every create, under the gate. It never deletes, renames or
rewrites a published Document, and never uses the recovery strip or an alert. The helper notes what it
recovered on stderr only.

| Found in `agent-staging/` | Meaning | Recovery |
|---|---|---|
| Intent and its staged file | Never published | Receipt `abandoned`, then the staged file and intent are removed. The agent retries. |
| Intent without its staged file | Published | The document is found by index UUID, then by `memory_id` in its Folder. Receipt `reconciled` (with the path, or `null` if it’s gone), then the intent is removed. |
| Intent whose key already has a published receipt | Only the cleanup was lost | The intent is removed. |
| Staged file or temporary file without an intent | Never published | Removed. |
| Intent that can’t be read | Unknown | Left alone. |

A receipt that can’t be written leaves the published document and its intent in place, and the
create reports `write_failed`. The next create (or a retry with the same key) records it.

**Receipt** (`version: 1`, sorted keys, every key present, decoded tolerantly; never body text):

| Key | Value |
|---|---|
| `operationId` | `op_` + 32 hex characters |
| `idempotencyKey`, `grantId`, `client`, `agent`, `session` | As given; `grantId` is the project key |
| `createdAt` | The envelope’s `created_at`, or when the receipt was recorded |
| `destination` | Library-relative POSIX path at publish, or `null` |
| `documentId` | The app index UUID, or `null` |
| `memoryId` | The envelope’s `memory_id`, or `null` |
| `contentDigest` | `sha256:` + hex of the published bytes, or `null` |
| `requestDigest` | `sha256:` + hex of the payload |
| `byteCount` | Bytes published |
| `outcome` | `created`, `duplicate`, `reconciled`, `abandoned` or `refused` |
| `refusal` | The `error.code` of a `refused` create, otherwise `null` |

An unknown `outcome` from a newer build counts as published, so a retry can never duplicate a
document. `duplicate` is the outcome a replay reports; the stored receipt keeps its original outcome.

**Output.** `{"outcome": …, "replayed": …, "path": …, "receipt": {…}}` on stdout, exit 0.

**Create codes** (reusing `create_not_allowed`, `out_of_scope`, `invalid_path`, `excluded_name`,
`library_busy` and the envelope codes):

| Code | Message |
|---|---|
| `idempotency_conflict` | This request key was already used with different content. Nothing was changed. Use a new key. |
| `too_large` | This document is larger than the grant allows (256 KB). Nothing was created. |
| `write_failed` | Silkweb couldn’t finish writing to the Library. Nothing was replaced. Try again with the same key. |
| `invalid_request` | The request key must be 1 to 200 characters, without control characters. (Also: unreadable or non-UTF-8 text.) |

## Safety exclusions

- **Instruction and configuration files can never be created by an agent:** `AGENTS.md`, `AGENT.md`,
  `CLAUDE.md`, `CLAUDE.local.md`, `GEMINI.md`, `mcp.json` and `.mcp.json`, compared without regard
  to case. Agents can create only `.md` documents, and only inside the create folders.
- `.silkweb/` and other hidden items can’t be read, listed or created by agents.
- Symbolic links and special files are skipped.
- Errors and messages never include document text.
- Receipts are an operational audit trail, not tamper-proof evidence of who did what.
- Skills (#138) save short conclusions, not credentials, environment dumps or transcripts. They never
  tell the user to turn off an agent’s sandbox.

**Message copy.** Machine output is JSON on stdout. Human messages go to stderr in sentence case,
with curly quotes around names. Library failures reuse the app’s titles, **“Library Not Found”** and
**“Can’t Open Library”**. Grant failures use **“No Agent Access”**. Out-of-scope messages name the
grant’s scope, never the requested target (see [Refusals](#refusals)).

| Exit | Meaning | stdout |
|---|---|---|
| 0 | Success | Result JSON |
| 1 | Failure | `{"error": {"code": "…", "title": "…"}}` |
| 64 | Usage error | Nothing; usage text on stderr |

Error codes: `no_grants_file`, `invalid_grants_file`, `unsupported_grants_version`, `no_grant`,
`invalid_grant`, `library_not_found`, `library_unreadable`, `library_busy`, `stale_snapshot`
([Coordination](#coordination-131)), `invalid_argument` ([Search and read](#search-and-read-134)), plus
the per-operation [refusals](#refusals) and the [create codes](#create-and-receipts-133).

## Helper distribution

Silkweb v2 ships **directly**, outside the Mac App Store. Neither the app nor the helper is
sandboxed. The helper is a separate executable kept **outside the app bundle**, so updating or moving
`Silkweb.app` can’t break agent configs. Agents always launch it from one stable path:

```text
~/.local/bin/silkweb   →  symlink to the signed helper binary
```

### Who prompts for what

- **App Sandbox:** doesn’t apply, since neither binary is sandboxed in v2.
- **Agent sandbox:** Codex, Claude Code and Gemini each limit what their subprocesses can do. The
  Library path has to be allowed by that agent’s own sandbox and approval settings. Silkweb never
  asks the user to turn a sandbox off.
- **macOS privacy (TCC):** a Library inside Documents, Desktop, Downloads, iCloud Drive, or on a
  removable or network volume can trigger a privacy prompt. **macOS attributes that prompt to
  the app that launched the helper (Terminal, iTerm, or the agent’s app), not to Silkweb.** Approve
  it once for that app in System Settings ▸ Privacy & Security ▸ Files and Folders. A Library
  elsewhere in your home folder, such as `~/Writing`, doesn’t prompt.

### Spike: app-closed access in Terminal (macOS 15+)

Run these once from the repository root. Each step shows its expected output.

1. Build. This also signs the helper ad hoc into `build/helper/silkweb`.

   ```sh
   ./scripts/build.sh
   ```
   ```text
   bundled build/Silkweb.app
   bundled build/helper/silkweb
   ```

2. Install it at the stable path.

   ```sh
   mkdir -p ~/.local/bin && ln -sf "$PWD/build/helper/silkweb" ~/.local/bin/silkweb
   ~/.local/bin/silkweb version
   ```
   ```json
   {
     "contract_version" : 1,
     "helper_version" : "0.1.0"
   }
   ```

3. Write the grant, using the Library you want agents to use.

   ```sh
   mkdir -p ~/Library/Application\ Support/Silkweb
   cat > ~/Library/Application\ Support/Silkweb/agent-grants.json <<'EOF'
   {"version":1,"grants":[{"project":"Silkweb","library":{"path":"/Users/me/Writing"},"access":"read-create"}]}
   EOF
   ```
   (No output.)

4. Quit Silkweb (⌘Q), then ask the helper for its scope.

   ```sh
   ~/.local/bin/silkweb memory capabilities --project Silkweb
   ```
   ```json
   {
     "access" : "read-create",
     "contract_version" : 1,
     "create_roots" : [
       "Memory/Projects/Silkweb/Memories",
       "Memory/Projects/Silkweb/Progress",
       "Memory/Projects/Silkweb/Handoffs"
     ],
     "filesystem" : "qualified",
     "helper_version" : "0.1.0",
     "library" : "/Users/me/Writing",
     "limits" : {
       "max_create_bytes" : 262144,
       "max_read_bytes" : 1048576,
       "max_results" : 200,
       "requests_per_minute" : 120
     },
     "operations" : [
       "capabilities",
       "list",
       "search",
       "read",
       "create",
       "create-folder"
     ],
     "project" : "Silkweb",
     "project_folder_exists" : true,
     "read_roots" : [
       "Memory/Projects/Silkweb"
     ]
   }
   ```
   If `Memory/Projects/Silkweb` doesn’t exist yet, `project_folder_exists` is `false`. The spike never
   creates it.

5. List the granted documents, still with Silkweb closed.

   ```sh
   ~/.local/bin/silkweb memory list --project Silkweb
   ```
   ```json
   {
     "documents" : [
       {
         "modified" : "2026-10-07T09:30:00Z",
         "path" : "Memory/Projects/Silkweb/Progress/2026-10-07 0930 — Helper spike.md",
         "size" : 412
       }
     ],
     "project" : "Silkweb"
   }
   ```

6. Check that out-of-scope requests are refused.

   ```sh
   ~/.local/bin/silkweb memory list --project Other; echo "exit $?"
   ```
   ```text
   {
     "error" : {
       "code" : "no_grant",
       "title" : "No Agent Access"
     }
   }
   No Agent Access: There’s no grant for the project “Other”.
   exit 1
   ```

`--grants <file>` points the helper at another grants file, which is useful for testing. The
automated version of these steps is `Tests/SilkwebCoreTests/AgentMemoryTests.swift`. Its
`testBuiltHelperBinaryRunsHeadless` launches the built binary as a separate process, with no app
running.

### Release signing (direct distribution)

Local builds are signed ad hoc and never quarantined, so Gatekeeper doesn’t check them. A release
build is signed with the owner’s Developer ID and notarized:

```sh
codesign --force --options runtime --timestamp -i com.silkweb.helper \
  -s "Developer ID Application: <Name> (<TEAMID>)" build/helper/silkweb
ditto -c -k build/helper/silkweb silkweb-helper.zip
xcrun notarytool submit silkweb-helper.zip --keychain-profile <profile> --wait
codesign --verify --strict --verbose=2 build/helper/silkweb
```

A bare Mach-O binary can’t be stapled, so Gatekeeper checks its notarization online the first time it
runs. For offline first runs, ship it in a signed installer package that is stapled with
`xcrun stapler staple`. The package installs the helper and creates the `~/.local/bin/silkweb`
symlink. The helper needs no entitlements.

## Deferred: App Store sandbox

A Mac App Store build, or any sandboxed build with a helper that inherits its sandbox, is **out of
v2 scope**. No prototype is planned.

Why: a sandboxed app’s security-scoped access belongs to that app’s process. Apple’s embedded-helper
guidance covers helpers that the containing app launches itself, which inherit its sandbox. A helper
that an agent launches as a stdio subprocess doesn’t inherit the app’s grants. Supporting that would
need its own entitlement, bookmark and XPC design, plus a separately granted companion. That would be
weeks of work with no v2 benefit, since v2 ships directly.

References:

- [Embedding a command-line tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)
- [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)

If this is revisited, the grants file format above stays the contract, and only the way access is
obtained changes.

## Dependency exceptions

Silkweb otherwise allows no third-party dependencies.

- **Swift MCP SDK** ([modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk))
  is an allowed exception, used only by the `silkweb mcp` entry point (#136). #136 pins an exact
  version in `Package.swift`, records it here, reviews and commits its transitive packages in
  `Package.resolved`, and keeps the SDK out of `SilkwebCore` and the app target. Nothing is
  downloaded at run time (no `npx`/`uvx`).
- **YAML: no dependency.** Front matter uses the **Silkweb envelope subset**, a restricted, documented
  subset parsed in `SilkwebCore` (#132, see [Silkweb envelope subset](#silkweb-envelope-subset)). It
  supports one key per line, quoted strings, ISO 8601 timestamps as quoted strings, and flow (`[]`) or
  block (`- item`) lists of strings. Anything else is kept as text and reported as unparsed, not
  guessed at. It’s never described as general YAML support. A real YAML parser would need a second
  exception here first.

## Glossary

- **Library:** the root directory the owner chose. Never “vault” or “workspace”.
- **Folder / Document / Tag:** the design-system terms (§2). An agent’s entries are Documents,
  never “notes”.
- **Memory document:** a short, reusable statement (a decision, constraint, preference or verified
  workaround), with evidence. `type: memory` or `decision`, stored in `Memories`.
- **Progress document:** a checkpoint covering objective, completed work, evidence, blockers and next
  action. `type: progress`, stored in `Progress`.
- **Handoff document:** what the next session needs to resume. `type: handoff`, stored in `Handoffs`.
- **Project:** a key in the grants file, and the Folder `Memory/Projects/<Project>`.
- **Grant:** the owner’s entry in `agent-grants.json` that binds a project to a Library, an access
  level and its read and create folders.
- **Read folders / create folders:** the Library-relative folders a grant may read from or create in.
- **Qualified filesystem:** a local APFS or HFS+ volume outside iCloud Drive and File Provider sync
  folders. Only these carry the human-text guarantee.
- **Cooperating writer:** the Silkweb app or `silkweb` helper following this contract.
- **Helper:** the `silkweb` executable at `~/.local/bin/silkweb`, kept outside the app bundle.
