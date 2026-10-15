# Silkweb

Silkweb is a native macOS app for writing Markdown offline. Your Library is a folder on disk: real nested
folders, with each document as a plain UTF-8 `.md` file. You can read your documents without Silkweb.

## Install

1. Download `Silkweb-<version>.dmg` from the [latest release](https://github.com/Mhinolv/silkweb/releases/latest).
2. Open the DMG and drag **Silkweb** onto the **Applications** shortcut.
3. Open Silkweb from your Applications folder.

Silkweb needs macOS 15 or later on a Mac with Apple silicon. The app is signed with a Developer ID and
notarized by Apple.

## Features

- **Library:** a sidebar, a document list and an editor. Create, rename, move (drag and drop) and delete
  nested folders. Tags, pinned documents and All Documents.
- **Multiple Libraries:** each Library is a section in one sidebar, with one tab strip and an All Libraries
  search scope.
- **Editor:** Editor, Split and Preview modes. Inline images, outline, focus mode and typewriter mode.
  Autosave and recovery drafts.
- **Search:** full-text search with ranked results and filters (`tag:`, `type:`, `after:`). Quick Open
  (⇧⌘O).
- **Export and print:** HTML and PDF.
- **Agent memory:** coding agents (Claude Code, Codex, Gemini CLI) read and write documents through the
  `silkweb` helper. A grant sets the folders that each agent can read, create and update. The Agent
  Activity view shows what each agent did.

Silkweb works offline. It has no accounts and no backend.

## Agent memory helper

The `silkweb` helper is not in the DMG. Build it from source (see below). The build puts it at
`build/helper/silkweb`.

- Contract, commands and MCP tools: [`docs/agent-memory.md`](docs/agent-memory.md)
- Setup for Claude Code, Codex and Gemini CLI: [`agent-packages/`](agent-packages/)

## Build from source

You need Xcode 26.2 (Swift 6.2.3). The exact versions are in `.toolchain-versions`.

```sh
./scripts/build.sh          # builds build/Silkweb.app and build/helper/silkweb
./scripts/build.sh test     # runs the unit tests
./scripts/format.sh --check # checks the format
```

Silkweb is a SwiftPM package. There is no Xcode project. To make a release DMG, see
[`docs/release.md`](docs/release.md).

## Project layout

| Path | Contents |
|---|---|
| `Sources/SilkwebCore/` | Logic: Library storage, Markdown, search, export, agent memory. No UI. |
| `Sources/Silkweb/` | The app: SwiftUI and AppKit views, menus and commands. |
| `Sources/SilkwebHelper/` | The `silkweb` agent helper (CLI and MCP server). |
| `Tests/` | XCTest suites and the sample Library for tests. |
| `scripts/` | Build, test, format, snapshot and release scripts. |
| `docs/` | Design system, keyboard shortcuts, agent memory and release docs. |
