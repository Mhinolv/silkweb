# Personal Library and Test_Library

How to keep your own writing and the repo's `Test_Library` open side by side in one Silkweb window.
Menu names and shortcuts follow `docs/design-system.md` §6.

## Why two Libraries

Your writing lives in a folder of your own (for example `~/Documents/Writing`). The repo's
`Test_Library/` is the sample blog used for manual testing during development. Keep them apart, so
testing never touches your notes, and open both at once: each open Library is a **section** in the
sidebar of the same window.

## Create or open a Library

- **File › New Library…** (⌥⌘N) creates an empty Library in a new folder.
- **File › Open Folder in Place…** (⌘O) opens an existing folder as it is; the files stay where they are.
- With nothing open, the welcome screen offers the same two choices as cards.
- **File › Import Folder Copy…** (⇧⌘I) is different: it copies a folder's files into the current Library.

## Add Test_Library as a second section

1. With your personal Library open, choose **File › Open Folder in Place…** (⌘O) again.
2. Pick the repo's `Test_Library` folder. It's added below your Library as a second section and becomes
   the current Library.

Opening a folder that's already open doesn't add it twice; Silkweb selects its section instead.

## Switch between Libraries

- Click any row in a section; that section becomes the **current Library**.
- Pick a tab that belongs to the other Library; its Library becomes current.
- Choose it from **File › Open Recent ▸** (open sections are checked) or from **Recent Libraries** on the
  welcome screen.

New Document, New Folder, Move To…, Import Folder Copy… and the document list always act on the current
Library. Its section header is drawn in the primary text colour, and the status-bar path starts with its name.

## Close a section

Choose **Close Library** from the section header's context menu, or **File › Close Library** (no shortcut)
for the current Library. Silkweb asks first if one of its tabs has unsaved changes, then saves and closes
only that Library's section and tabs. The files stay on disk, and the Library stays in Open Recent.
Closing the last section shows the welcome screen.

## Shared vs per Library

| Global (app) | Per Library (path) |
|---|---|
| Settings: theme, fonts, editor | documents, folders, tags, search index, Agent Activity, Move To… recent folders, session/tabs, agent grants |

Per-Library data lives in the Library folder itself (plain files plus a hidden `.silkweb/` folder), so
it travels with the folder. The one tab strip can mix Libraries; while it does, each tab shows
“ · <Library>” after its title.

## Search scope

- **Search Library** (⇧⌘F) searches the current Library: All Documents, or the selected “Folder”. While
  another Library is open, the scope bar adds an **All Libraries** segment. Each new search starts with
  the current Library.
- **Quick Open** (⇧⌘O) searches the current Library. Its **All Libraries** toggle is off each time it opens.

## Agent memory

Agent grants point at one Library path, so each Library needs its own grant (see
[Setting up a grant](agent-memory.md#setting-up-a-grant-186)). `silkweb grant init` refuses to repoint an
existing grant to another Library: use a new project key (`--project`) for the other Library, or edit
`~/Library/Application Support/Silkweb/agent-grants.json` by hand. Copying a `Memory/` folder from one
Library to the other is optional and manual.

## Moving a Library later

1. Quit Silkweb.
2. Move the folder in Finder, then relaunch.
3. The section shows “Not Found”. Right-click its header and choose **Locate…**, then pick the folder's
   new place. On the welcome screen a missing recent shows “Not found”.

**Settings › Library › Choose Library…** also points the current section at another folder. Agent grants
keep the old path: edit `agent-grants.json` or add a grant under a new project key, as above.
