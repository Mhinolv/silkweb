# Silkweb Design System (v1 foundation)

Every issue's design notes refer to this file. Where an issue's notes conflict with this file, this file wins unless the issue's notes say "overrides design system".

## 1. Principles
Silkweb should feel like a first-party Mac app: native controls, system colors, materials, and menus. There is no custom chrome. Writing comes first: the editor is calm, and chrome recedes. Every action is in the menu bar and every common action has a shortcut. Undo or Trash covers every mutation, and we never lose text. All originals are clean-room; do not reuse MWeb copy, icons, or themes.

## 2. Vocabulary (use exactly these words in UI)
| Use | Never |
|---|---|
| **Library** (the root directory) | Vault, Workspace, Notebook |
| **Folder** | Category, Group, Notebook |
| **Document** | Note, Article, Post, File (except in Finder-related copy) |
| **Tag** | Label, Keyword |
| **Trash** (always the macOS Trash) | Recycle bin, Delete permanently |
| **All Documents** (virtual sidebar view) | Inbox, Everything |
| **Include Subfolders**, **Move To…**, **Move to Trash**, **Reveal in Finder**, **Open Folder in Place…**, **New Library…**, **Import Folder Copy…**, **Quick Open**, **Search Library**, **Outline**, **Document Info**, **Editor / Split / Preview**, **Focus Mode**, **Typewriter Mode** | — |

Copy style: sentence case for messages and title case for menu items and buttons. Use curly quotes around names (“Drafts”). Show paths relative to the library with “ › ” separators (`Writing › Drafts`). Documents display without the `.md` extension.

## 3. Window and layout
- One main window built on nested `NSSplitViewController` splits with SwiftUI pane contents and three columns: **Sidebar** (folders and tags) | **Document list** | **Detail** (tab bar, editor and/or preview, status bar). An optional right **Inspector** (`.inspector`) has two segments: **Outline** and **Info**.
- Window: minimum 900×560, default 1200×760. Frame is autosaved.
- Column widths: sidebar min 180 / ideal 220 / max 320. List min 240 / ideal 300 / max 480. Detail min 420. Inspector min 200 / ideal 240 / max 320.
- Window title is the active document name. `navigationSubtitle` is the folder path. Content column title is the folder name. Content column subtitle is the count (“12 documents”).
- Sidebar layout:
```
LIBRARY
  [doc.on.doc]      All Documents        1,204
  [books.vertical]  My Library             12   ← root folder (dir name); root docs live here
     ▸ [folder]     Projects                8
     ▾ [folder]     Writing                 3
          [folder]  Drafts
TAGS                                           ← section hidden until a tag exists (1.21)
  [tag]             research                9
```
- Sidebar is an `NSOutlineView` bridge (source-list style). SwiftUI `OutlineGroup` can't do spring-loading, inline rename, or lazy expansion at 1k folders. Document list may be SwiftUI `List` or `NSTableView`, whichever handles 10k rows smoothly. Both support multi-selection.

## 4. Visual tokens (system only)
- **Accent:** the user's system accent color (`Color.accentColor` with no override). There is no brand palette; the one brand color lives only in the app icon.
- **Colors:** semantic only: `labelColor`, `secondaryLabelColor`, `tertiaryLabelColor`, `quaternaryLabelColor`, `separatorColor`, `textBackgroundColor`, `controlBackgroundColor`, `quaternarySystemFill`, `linkColor`, `systemOrange` (warnings), `systemRed` (destructive/validation). Light and dark mode come free. Never hard-code hex in Swift. The preview CSS uses WebKit's `-apple-system-*` colors (1.18).
- **Materials:** `.bar` for the tab bar, banners, and status bar. Sidebar uses the default source-list vibrancy.
- **Typography (UI):** SwiftUI text styles only: `.body` (13pt), `.headline` (13pt semibold, list titles), `.subheadline` (11pt, secondary lines), `.caption` (10pt, paths/badges), `.title3` (Quick Open field). Use monospaced digits for counts.
- **Editor typography:** configurable (1.24). Default is the system proportional font at 15pt, line height 1.5×, max content width 720pt centered, horizontal inset ≥40pt, top inset 24pt. Code spans and blocks always use `.monospacedSystemFont` at 0.92× size.
- **Spacing:** 8pt grid. Sheet padding 20pt. Spacing between related controls 8pt; between groups 16–20pt. Toolbar and control sizes are system defaults. Small buttons in banners use `.controlSize(.small)`.
- **Symbols (SF Symbols, toolbar/sidebar only; macOS 15 context menus stay text-only):** All Documents `doc.on.doc`, library root `books.vertical`, folder `folder`, document `doc.text`, tag `tag`, new document `square.and.pencil`, new folder `folder.badge.plus`, sort `arrow.up.arrow.down`, editor `doc.plaintext`, split `rectangle.split.2x1`, preview `eye`, outline `list.bullet.indent`, info `info.circle`, warning `exclamationmark.triangle.fill` (systemOrange), missing library `externaldrive.badge.questionmark`, search `magnifyingglass`.

## 5. Shared components (reuse; don't reinvent)
1. **Empty/placeholder state.** Use `ContentUnavailableView` (symbol, title, one-sentence description, at most two actions). Use `ContentUnavailableView.search(text:)` for no-results.
2. **Editor Banner.** A strip under the tab bar inside the detail column. `.bar` material, min height 36pt, 12pt horizontal padding. Content: 14pt symbol, `.callout` message, trailing `.small` bordered buttons, optional close ✕. Used for save failures (1.5), conflicts and external deletes (1.11), and read-only files. It posts an accessibility announcement. At most one at a time; highest severity wins.
3. **Inline Rename Field.** Text field in place of the row label. Selects the base name (no extension). Return commits, Escape reverts, and clicking away commits if valid. Validation shows in a small popover anchored under the field with `systemRed` text; Return then beeps. Used by 1.6 and 1.21.
4. **Folder Picker.** A sheet with a filter field and a folder outline, used by Move To… (1.7) and import destination (1.10). Spec lives in 1.7.
5. **Alerts.** Use `NSAlert` or SwiftUI `.alert` with a short title (statement or question), an informative sentence, and verb buttons (“Move to Trash”, never “OK/Yes”). Escape = Cancel. Destructive buttons use `.destructive` role.
6. **Status Bar.** A 24pt `.bar` strip at the bottom of the detail column with `.caption` secondary text. Holds word counts (1.25) and the Focus/Typewriter chip (1.27).
7. **Inspector.** Right panel with a segmented header: **Outline** (1.18) | **Info** (1.21 tags, path, dates).

## 6. Keyboard shortcut map (single source of truth)
Before adding any shortcut, check it against this table. 1.25 audits the final map. Focus-dependent keys are marked †.

| Menu | Command | Shortcut | Ticket |
|---|---|---|---|
| Silkweb | Settings… | ⌘, | 1.24 |
| File | New Document | ⌘N | 1.6 |
| File | New Folder | ⇧⌘N | 1.6 |
| File | New Library… | ⌥⌘N | 1.4 |
| File | Open Folder in Place… | ⌘O | 1.4 |
| File | Quick Open… | ⇧⌘O | 1.20 |
| File | Open in New Tab | ⌘T | 1.26 |
| File | Import Folder Copy… | ⇧⌘I | 1.10 |
| File | Close Tab / Close Window | ⌘W / ⇧⌘W | 1.26 |
| File | Save (flush autosave now) | ⌘S | 1.5 |
| File | Rename… | ↩ † (sidebar/list focused; no menu key equivalent) | 1.6 |
| File | Move To… | ⌃⌘M | 1.7 |
| File | Reveal in Finder | ⌥⌘R | 1.6 |
| File | Move to Trash | ⌘⌫ † (sidebar/list focused) | 1.8 |
| File | Export ▸ HTML… / PDF… | ⇧⌘E / ⌥⌘P | 1.22 / 1.23 |
| File | Page Setup… / Print… | ⇧⌘P / ⌘P | 1.23 |
| Edit | Undo / Redo / Cut / Copy / Paste / Select All | standard | 1.5 |
| Edit | Paste and Match Style | ⌥⇧⌘V | 1.5 |
| Edit ▸ Find | Find… / Find and Replace… | ⌘F / ⌥⌘F | 1.13 |
| Edit ▸ Find | Find Next / Previous / Use Selection for Find / Jump to Selection | ⌘G / ⇧⌘G / ⌘E / ⌘J | 1.13 |
| Edit ▸ Find | Search Library… | ⇧⌘F | 1.20 |
| Edit | Spelling and Grammar | ⌘: / ⌘; | 1.5 |
| Format | Bold / Italic / Strikethrough / Inline Code | ⌘B / ⌘I / ⇧⌘X / ⌃⌘C | 1.12 |
| Format | Link / Image… | ⌘K / ⌃⌘I | 1.12 / 1.15 |
| Format ▸ Heading | Heading 1–6 / Body Text | ⌃⌘1…⌃⌘6 / ⌃⌘0 | 1.12 |
| Format | Quote / Bulleted / Numbered / Task List / Code Block | ⌘' / ⌥⌘U / ⌥⌘O / ⌥⌘X / ⌃⇧⌘C | 1.12 |
| Format | Shift Right / Shift Left | ⌘] / ⌘[ (Tab / ⇧Tab indent lists and selected lines; Tab elsewhere inserts 4 spaces) | 1.12 |
| Format | Insert Table… | ⌃⌘T | 1.14 |
| View | Editor ↔ Preview toggle | ⌘R | 1.18 |
| View | Split Editor and Preview | ⌘4 | 1.18 |
| View | Show Outline / Show Document Info | ⌘7 / ⌘8 | 1.18 / 1.21 |
| View | Toggle Sidebar / Toolbar / Full Screen | ⌃⌘S / ⌥⌘T / ⌃⌘F (system) | 1.4 |
| View | Show Status Bar | ⌘/ | 1.25 |
| View | Sort By ▸ Name / Date Modified / Date Created | ⌃⌥⌘1 / ⌃⌥⌘2 / ⌃⌥⌘3 | 1.9 |
| View | Include Subfolders | — (menu checkbox) | 1.9 |
| View | Focus Mode / Typewriter Mode | ⌃⇧⌘F / ⌃⇧⌘T | 1.27 |
| View | Bigger / Smaller / Actual Size (editor text) | ⌘+ / ⌘− / ⌘0 | 1.24 |
| Go | Folders / Documents / Editor (move focus) | ⌥⌘1 / ⌥⌘2 / ⌥⌘3 | 1.4 |
| Window | Show Next / Previous Tab | ⌃⇥ or ⇧⌘] / ⌃⇧⇥ or ⇧⌘[ | 1.26 |
| Window | Close Other Tabs | ⌥⌘W | 1.26 |

Deliberately unassigned: ⌘1–⌘9 tab selection (⌘4/⌘7/⌘8 are view commands) and ⌘U (Markdown has no underline). ⌃⌘Q is the system lock screen; never use it. Format commands are disabled unless the editor is first responder.

## 7. Accessibility baseline (every ticket, not just 1.25)
- Every icon-only control has an `accessibilityLabel` and a `.help()` tooltip using the menu wording.
- Every drag-and-drop action has a menu/keyboard equivalent (Move To…).
- Use semantic colors only, which gives contrast in both appearances. Never convey state by color alone.
- Respect Reduce Motion (no spring/expand animations) and Full Keyboard Access (visible focus rings, Tab order outside the editor: sidebar → list → editor → inspector; in the editor Tab edits indentation, and pane focus uses ⌥⌘1/2/3 or ⌃Tab).
