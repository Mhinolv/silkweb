# Silkweb agent packages

These packages let Claude Code, Codex CLI and Gemini CLI use Silkweb as a project's memory: recall
before work, checkpoint progress, and create new documents without ever replacing one. Each client
gets the same workflow, the `silkweb-memory` skill, plus the `silkweb` MCP server, which serves the
six `memory_*` tools.

Names, folders, refusals and guarantees are defined in the
[agent memory contract](../docs/agent-memory.md). This page only covers installing the packages.

```text
agent-packages/
  README.md                                   this page
  shared/silkweb-memory.md                    the workflow (the only file to edit)
  claude/skills/silkweb-memory/SKILL.md       Claude Code skill
  claude/CLAUDE.fragment.md                   block for CLAUDE.md
  codex/skills/silkweb-memory/SKILL.md        Codex skill
  codex/AGENTS.fragment.md                    block for AGENTS.md
  gemini/silkweb-memory/                      Gemini CLI extension
    gemini-extension.json                     manifest with the MCP server
    GEMINI.md                                 block loaded as context
    skills/silkweb-memory/SKILL.md            Gemini skill
    commands/silkweb/recall.toml              /silkweb:recall
    commands/silkweb/checkpoint.toml          /silkweb:checkpoint
```

Run the commands below from the root of this repository.

## Placeholders

| Placeholder | Replace with | Example |
|---|---|---|
| `<SILKWEB_HELPER>` | The helper's absolute path. Clients don't expand `~`. | `/Users/me/.local/bin/silkweb` |
| `<GRANT_ID>` | The grant's project key (or its label) | `Silkweb` |

The commands below use the example values. Replace them with your own.

**Use user scope.** Every install below registers the server for your user account. Don't put the
`silkweb` server in a project's `.mcp.json`, `.codex/` or `.gemini/` settings, or in a repository's
`.agents/` folder: those are usually committed, and the entry contains your helper path and project
key.

## Before you start

### 1. Install the helper

Build Silkweb and link the helper to its stable path, as in
[Spike: app-closed access in Terminal](../docs/agent-memory.md#spike-app-closed-access-in-terminal-macos-15)
steps 1 and 2. Then check it:

```sh
/Users/me/.local/bin/silkweb --version
```

### 2. Create the grant

Run `grant init` yourself, in Terminal. It asks for the Library folder, the project key and the access
profile, then adds the grant to `~/Library/Application Support/Silkweb/agent-grants.json`:

```sh
/Users/me/.local/bin/silkweb grant init
```

Or give every answer as an option, so it asks nothing:

```sh
/Users/me/.local/bin/silkweb grant init --library ~/Writing --project Silkweb --access read-create
```

- `--access` is `read-create` (Read and Create), `read-create-update` (Read, Create and Update: agents
  may also update documents an agent created) or `read` (Read Only).
- It keeps the other grants in the file, and running it again with the same answers changes nothing.
  It never widens an existing grant: more access, another Library, or turning a grant back on. To do
  that, edit the file as shown below. Going from Read and Create to Read Only is allowed.
- It never creates anything in the Library. If the Library isn't on a local APFS or HFS+ disk, the
  grant is still saved, with a warning: agents can read it, but creating stays off.
- `--dry-run` shows the grant and the commands without saving anything.
- **Saving needs a terminal.** An agent's shell isn't one, so an agent that runs `grant init` can't
  give itself access. Agents' skills tell them never to run it.

When it's done, it prints the `claude mcp add`, `codex mcp add` and Gemini CLI commands from
[Install](#install) with your helper path and project key filled in.

#### Editing the file by hand

Labels, limits and extra read folders aren't set by `grant init`; edit the file for those. If the file
doesn't exist yet, save this template as `agent-grants.json` in
`~/Library/Application Support/Silkweb/` and set `project`, `label` and `library.path`. If it already
exists, add only the object inside `grants` to its list and keep the other grants.

```json
{
  "version": 1,
  "grants": [
    {
      "project": "Silkweb",
      "label": "Silkweb project",
      "library": { "version": 1, "path": "/Users/me/Writing" },
      "access": "read-create",
      "extra_read_folders": [],
      "limits": {
        "max_create_bytes": 262144,
        "max_read_bytes": 1048576,
        "max_results": 200,
        "requests_per_minute": 120
      }
    }
  ]
}
```

- `project` is the Folder name under `Memory/Projects` and the `<GRANT_ID>` you use below.
- `access` is `read-create` (Read and Create), `read-create-update` (Read, Create and Update) or `read`
  (Read Only).
- To turn the grant off, add `"revoked_at": "2026-10-08T17:00:00Z"` (any date). Agents are refused on
  their next operation.

### 3. Check the grant

```sh
/Users/me/.local/bin/silkweb memory capabilities --grant Silkweb --pretty
```

The result shows your `label` (“Silkweb project”), `profile` and `read_roots`. If it shows an error
instead, its message says what's missing.

## Install

Each client keeps its own configuration. The steps add the `silkweb` server with the client's own
command and copy the skill into the client's own skills folder. Nothing else in your configuration
changes.

### Claude Code

Add the MCP server for your user:

```sh
claude mcp add --scope user silkweb -- /Users/me/.local/bin/silkweb mcp --grant Silkweb
```

Install the skill:

```sh
mkdir -p ~/.claude/skills
```

```sh
cp -R agent-packages/claude/skills/silkweb-memory/ ~/.claude/skills/silkweb-memory
```

Add the fragment to your user `CLAUDE.md` (replace `Silkweb` with your project key):

```sh
{ echo; sed 's|<GRANT_ID>|Silkweb|' agent-packages/claude/CLAUDE.fragment.md; } >> ~/.claude/CLAUDE.md
```

**Check it worked.** Start `claude` in any folder:

1. Run `/mcp`. The `silkweb` server is connected and lists the eight tools: `memory_capabilities`,
   `memory_search`, `memory_read`, `memory_create`, `memory_create_folder`, `memory_update`,
   `memory_activity` and `grant_request`.
2. Ask “Call memory_capabilities.” The answer includes your grant label, “Silkweb project”.
3. Ask “Which skills do you have?” The list includes `silkweb-memory`.

### Codex CLI

Add the MCP server. Codex saves it in your user `~/.codex/config.toml`:

```sh
codex mcp add silkweb -- /Users/me/.local/bin/silkweb mcp --grant Silkweb
```

Install the skill in your user skills folder:

```sh
mkdir -p ~/.agents/skills
```

```sh
cp -R agent-packages/codex/skills/silkweb-memory/ ~/.agents/skills/silkweb-memory
```

Add the fragment to your user `AGENTS.md` (replace `Silkweb` with your project key):

```sh
{ echo; sed 's|<GRANT_ID>|Silkweb|' agent-packages/codex/AGENTS.fragment.md; } >> ~/.codex/AGENTS.md
```

**Check it worked.** Start `codex` in any folder:

1. Run `/mcp`. The `silkweb` server lists the six `memory_*` tools.
2. Ask “Call memory_capabilities.” The answer includes your grant label, “Silkweb project”.
3. Run `/skills`, or ask “Which skills do you have?”. The list includes `silkweb-memory`. If it
   doesn't, your Codex release may read user skills from `~/.codex/skills` instead; copy the skill
   there too and record that release in [Tested versions](#tested-versions).

### Gemini CLI

Gemini CLI installs the whole package as one extension, `silkweb-memory`: the MCP server, the
`GEMINI.md` block, the skill and two commands. Fill in the placeholders in a temporary copy first.

```sh
cp -R agent-packages/gemini/silkweb-memory/ "$TMPDIR/silkweb-memory"
```

```sh
sed -i '' -e 's|<SILKWEB_HELPER>|/Users/me/.local/bin/silkweb|' -e 's|<GRANT_ID>|Silkweb|' "$TMPDIR/silkweb-memory/gemini-extension.json" "$TMPDIR/silkweb-memory/GEMINI.md"
```

```sh
gemini extensions install "$TMPDIR/silkweb-memory"
```

Gemini CLI copies the extension into your user extensions folder, so the temporary copy can go:

```sh
rm -r "$TMPDIR/silkweb-memory"
```

**Check it worked.** Start `gemini` in any folder:

1. Run `/mcp`. The `silkweb` server lists the six `memory_*` tools.
2. Ask “Call memory_capabilities.” The answer includes your grant label, “Silkweb project”.
3. Run `/extensions`. The list includes `silkweb-memory`. `/silkweb:recall` and `/silkweb:checkpoint`
   are available as commands.

## Update

Update after pulling a new version of this repository. Your other skills, servers and instruction-file
text stay as they are.

**Remove the old block first.** Each fragment sits between `<!-- silkweb-memory:begin v1 -->` and
`<!-- silkweb-memory:end -->`. Check that both lines are there exactly once before you remove it:

```sh
grep -n 'silkweb-memory:' ~/.claude/CLAUDE.md
```

This deletes only the lines from the begin marker to the end marker, and keeps a copy of the old
file as `CLAUDE.md.bak`:

```sh
sed -i.bak '/<!-- silkweb-memory:begin/,/<!-- silkweb-memory:end -->/d' ~/.claude/CLAUDE.md
```

### Claude Code

1. Remove the old block from `~/.claude/CLAUDE.md` as shown above.
2. Repeat the skill and fragment steps from [Install](#claude-code). Copying the skill replaces only
   `~/.claude/skills/silkweb-memory`.
3. Only if the helper path or grant changed, replace the server:

   ```sh
   claude mcp remove --scope user silkweb
   ```

   Then run the `claude mcp add` command from Install again.

### Codex CLI

1. Remove the old block from `~/.codex/AGENTS.md`:

   ```sh
   sed -i.bak '/<!-- silkweb-memory:begin/,/<!-- silkweb-memory:end -->/d' ~/.codex/AGENTS.md
   ```

2. Repeat the skill and fragment steps from [Install](#codex-cli).
3. Only if the helper path or grant changed, replace the server:

   ```sh
   codex mcp remove silkweb
   ```

   Then run the `codex mcp add` command from Install again.

### Gemini CLI

Uninstall the extension, then repeat all of the Gemini CLI install steps:

```sh
gemini extensions uninstall silkweb-memory
```

## Uninstall

Each step removes only what these packages added.

### Claude Code

```sh
claude mcp remove --scope user silkweb
```

```sh
rm -r ~/.claude/skills/silkweb-memory
```

Then remove the block from `~/.claude/CLAUDE.md` as shown in [Update](#update).

### Codex CLI

```sh
codex mcp remove silkweb
```

```sh
rm -r ~/.agents/skills/silkweb-memory
```

```sh
sed -i.bak '/<!-- silkweb-memory:begin/,/<!-- silkweb-memory:end -->/d' ~/.codex/AGENTS.md
```

### Gemini CLI

The extension holds the server, the `GEMINI.md` block, the skill and the commands, so one command
removes all of them:

```sh
gemini extensions uninstall silkweb-memory
```

Uninstalling never touches your Library. Documents agents created stay where they are. To stop all
agents at once, turn the grant off in `agent-grants.json` (see [Create the grant](#2-create-the-grant)).

## Tested versions

Silkweb doesn't pin minimum client versions. A row is filled in once that client has been qualified
end to end with these packages (#136, #139).

| Client | Version tested | Skill found | MCP tools listed | Remarks |
|---|---|---|---|---|
| Claude Code | Not yet qualified | — | — | User scope (`--scope user`). |
| Codex CLI | Not yet qualified | — | — | User skills folder: `~/.agents/skills` (`~/.codex/skills` in earlier releases). |
| Gemini CLI | Not yet qualified | — | — | Installed as the `silkweb-memory` extension. Some releases list skills only when skills are turned on in Gemini CLI settings; the `GEMINI.md` block and `/silkweb:` commands work without them. |

### Not used

Silkweb's workflow uses only the skill, the instruction-file block and the `silkweb` MCP server. These
client features may store their own memory, but Silkweb doesn't read, write, link or import any of them:

- Claude Code auto-memory and its memory files (**unsupported dependency: Silkweb never relies on it**).
- Codex memories (**unsupported dependency: Silkweb never relies on it**).
- Gemini CLI `save_memory` and its memory-file tools (**unsupported dependency: Silkweb never relies on it**).
- Experimental Gemini CLI features, including experimental skills and extension settings
  (**unsupported dependency: Silkweb never relies on it**).
- Any other experimental or preview memory feature in these clients (**unsupported dependency: Silkweb
  never relies on it**).

## Changing the workflow

Edit only `shared/silkweb-memory.md`, then regenerate the three `SKILL.md` copies:

```sh
./scripts/agent_packages.sh
```

`./scripts/agent_packages.sh --check` reports a copy that drifted. `AgentPackagesTests` fails the
test suite when a copy drifts, a fragment loses its markers, or shipped text breaks the copy rules.
Bump the marker version (`begin v2`) only when a block's meaning changes; the Update steps remove any
version.
