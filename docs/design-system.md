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
| **section** (an open Library in the sidebar), **current Library** (the section holding the selection), **Close Library**, **Open Recent**, **Recent Libraries** (#195) | Workspace, Vault, Tab group |

Copy style: sentence case for messages and title case for menu items and buttons. Use curly quotes around names (“Drafts”). Show paths relative to the library with “ › ” separators (`Writing › Drafts`). Documents display without the `.md` extension.

## 3. Window and layout
- One main window built on nested `NSSplitViewController` splits with SwiftUI pane contents and three columns: **Sidebar** (folders and tags) | **Document list** | **Detail** (tab bar, editor and/or preview, status bar). An optional right **Inspector** (`.inspector`) has two segments: **Outline** and **Info**.
- Window: minimum 900×560, default 1200×760. Frame is autosaved.
- Column widths: sidebar min 180 / ideal 220 / max 320. List min 240 / ideal 300 / max 480. Detail min 420. Inspector min 200 / ideal 240 / max 320.
- Compact unified toolbar: items share the traffic-lights row (`.unifiedCompact`, about 38 pt, no title row). Library group leading (Hide Sidebars, New Document, Sort By, Filter by Tag), then a flexible empty gap, then the view group trailing (View Mode, Show Outline, Show Document Info). No path, no count and no title in the bar (#91: the path lives in the status bar, §5.6). Layout: AppKit places the items (after the traffic lights, or after the sidebar column); Silkweb never moves them while any traffic light shows. The gap is the flexible part (an empty item the toolbar controller sizes, since macOS 15 has no SwiftUI flexible toolbar spacer): it fills the room the other items leave, up to the bar's edge or the titlebar area AppKit reserves over the Outline inspector, and gives way first (lowest overflow priority, 16 pt minimum); below 900 pt Filter by Tag overflows into » first, then Sort By; no button goes into » at 900 pt or wider. Only in full screen or with every window button hidden do the items slide to a 12 pt leading inset (0.2 s, none under Reduce Motion), and only where AppKit lets the row take the freed room: after a sidebar-column section, or once AppKit refuses the wider row, they keep AppKit's placement so the trailing items keep their edge (#54). The trailing Info glyph ends 12 pt from the bar's edge, or 12 pt before the inspector's titlebar area, mirroring the leading inset, windowed and in full screen (#68). The toolbar never auto-hides in full screen. The window title (Window menu and AX) remains the document name and `navigationSubtitle` the count; neither is visible in the bar (1.65, #91).
- Sidebar layout: one **section** per open Library (#195, Finder-style), in the order they were added, even when only one is open:
```
My Library                        ⌄   ← section header (current Library: labelColor)
  [doc.on.doc]      All Documents (1,204)
  [books.vertical]  My Library (12)     ← root folder (dir name); root docs live here
     ▸ [folder]     Projects (8)
     ▾ [folder]     Writing (3)
          [folder]  Drafts (0)
▾ [tag]             Tags (2)          ← sibling of library root; always present, including Tags (0) (1.21)
    [tag]           draft (3)
    [tag]           research (9)
Kyoto                             ⌄   ← another section (secondaryLabelColor)
  [doc.on.doc]      All Documents (310)
  …
```
- Section header (#195): an `NSOutlineView` group row with the folder name, 11 pt semibold, no symbol, count or thread guide; the current Library's header in `labelColor`, the others `secondaryLabelColor` (#224: kept, since it is the only cue for the current Library while its section is collapsed). Every header except the first sits close under the section above: the title's midline at most 20 pt below that section's last row (the source list's own 13 pt above a group row plus a 21 pt header row whose title sits at its top; the first header is a lone row's 28 pt). The native Show/Hide chevron collapses the whole section (its selection is kept; its folders and Tags keep their expansion for when it shows again). **Collapse All Libraries** / **Expand All Libraries** (#225; View ▸ after Hide Sidebars, and the header menu) act on every section, the current one included: instant, no animation, selection, scope, tabs and list unchanged, one session save. With fewer than two sections the View items are disabled and the header menu has none; each is disabled when it would change nothing. No shortcut and no Option-click variant (Option-click natively expands all descendants). Context menu: Reveal in Finder (Locate… when the Library can't open), a separator, Collapse All Libraries, Expand All Libraries and another separator (two or more sections only), Close Library (text only). AX: a group labelled “<name> library”, value “current” on the current Library. The rows under a header are exactly a lone Library's rows, including the `books.vertical` root row even though it repeats the header's name (#224): it is the only scope and drop target for root-level documents and folders, and headers can't be selected. The list, editor, tabs, the footer `+` and every command act on the current Library. Selecting a row in another section makes it current.
- Adding a section (⌘O, ⌥⌘N, welcome, Open Recent): an open folder (canonical path) is focused (expanded, its remembered scope selected and scrolled into view) with no alert; a new one is checked first, appended and made current; a failure alerts (“Name” couldn’t be opened. / created.) and changes no section. Settings ▸ Choose Library… replaces the current section in place. Close Library asks first when any of its tabs has unsaved changes (owner decision 2026-10-09), saves, then closes only its tabs; a failed save alerts and closes nothing. Closing the last section shows the welcome screen, which lists up to five **Recent Libraries** (missing ones tertiary, “Not found”).
- Nested rows hang from 1.5 pt `SilkwebThread` guides with 6 pt rounded elbows (16 pt per level, guide = centre of the parent's chevron slot; geometry in `ThreadGuides`); leading native chevrons tinted `tertiaryLabelColor`. The selection capsule alone marks the scope shown in the list (no coral node, owner decision in 1.65); that row's AX value appends “current folder” (1.63).
- Sidebar counts are inline after the name: a space and the direct count in parentheses, `secondaryLabelColor`, same font as the title with monospaced digits, `(0)` shown. The name truncates first; the count never clips. No trailing count column.
- Tags scroll in the same tree after the library root’s last visible descendant. The group count is distinct tags; child counts are documents. The group is a keyboard focus stop without changing document scope. Disclosure, double-click, and arrow keys expand/collapse; window session saves expansion (default expanded, selected tags reveal their group). Tag rows support inline rename and delete, but no drag/drop.
- Info tags (#72, Tags A): applied tags are 22 pt capsule chips on the pane (`SilkwebSelection` fill, 12 pt sage text, a quiet tertiary × that brightens on hover), followed inline by an always-visible “Add tag…” field over one `separatorColor` hairline; no bezel box. The native focus ring surrounds the tag area only while typing. A tag on only some selected notes is a mixed chip with a dashed sage outline and no fill; clicking its name applies it to all of them. The × (or Space / VoiceOver press, or ⌫ in the empty field) removes the tag from every selected note. Return, Tab (with text), comma and leaving the field commit typed names; the completion list offers library tags not yet on every selected note. **Suggested** lists the six most recently applied library tags (naturally sorted; usage-count fallback for older indexes) that are not on any selected note, as outlined “+ tag” pills (checkbox role) that apply on click, so each tag appears once. Named tag undo. Recency lives only in the versioned sidecar. Suggested hides when empty. Read-only libraries keep the chips without × and disable the field and pills. Caption: “Saved in Silkweb’s index, not in the file.”
- Info chips wrap at the column width minus 24 pt in 22 pt lines with 6 pt gaps; the field takes the rest of the last line (at least 80 pt, else its own line). The area grows with its tags and the Info pane scrolls; following rows retain 16 pt spacing.
- Sidebar is an `NSOutlineView` bridge (source-list row metrics, opaque pane background). SwiftUI `OutlineGroup` can't do spring-loading, inline rename, or lazy expansion at 1k folders. Document list may be SwiftUI `List` or `NSTableView`, whichever handles 10k rows smoothly. The sidebar is single selection; the document list supports multi-selection.
- Document list rows (1.64): title 13 semibold, `date · location` 11 secondary (location only when the scope spans folders: All Documents, a tag, Include Subfolders; head-truncated, the date never truncates), two-line 12 pt excerpt (17 pt line height; “No additional text” in tertiary); fixed 96 pt rows, text 12 pt inside the capsule; capsule selection. No date groups, list header or thumbnails. Search results use the same metrics.

## 4. Visual tokens
- **Accent:** Silkweb sage (`SilkwebAccent` #3F7D64 / #7FC0A4) for Silkweb-drawn selection, links and tag tints. Coral (`SilkwebCoral`) is only for unsaved state: the dot on tabs with unsaved changes (and the status bar's “Not Saved”, 1.25). Settings ▸ Appearance names its well “Unsaved dot” (1.65). Native focus rings follow the system accent. 1.24 makes the accent user-selectable. (1.62; all redesign tokens live in `PaneBackground.swift`: `SilkwebPaneBackground`, `SilkwebAccent`, `SilkwebSelection`, `SilkwebSelectionInactive`, `SilkwebCoral`, `SilkwebThread`, each with Increase Contrast values. R2–R4 add no new colour values.)
  The original sage, cream and coral Silk Tree app icon is generated by `scripts/make_icon.swift` (silkweb-1.53).
- **Colors:** semantic only: `labelColor`, `secondaryLabelColor`, `tertiaryLabelColor`, `quaternaryLabelColor`, `separatorColor`, `textBackgroundColor`, `controlBackgroundColor`, `quaternarySystemFill`, `linkColor`, `systemOrange` (warnings), `systemRed` (destructive/validation). Light and dark mode come free. The sole exception is the named dynamic `SilkwebEditorHeading` color, used for headings in the editor, the live preview and HTML export: light #2A6A86, dark #86BCD6, increased contrast #1F5570 / #A6D3E6. The preview CSS uses WebKit's `-apple-system-*` colors (1.18). The redesign tokens above are the other named exceptions (1.62); the live preview takes the surface and sage link colour from CSS variables, while export and print keep the portable colours.
- **Materials:** none in the window. Every pane uses the single `SilkwebPaneBackground` color, #FBFBFA / #1E1F21 (system text background under Increase Contrast): sidebar, document list, tab bar, editor, preview, Inspector, banners, status bar, toolbar/titlebar, and empty/welcome screens. Panes are separated only by `separatorColor` thin dividers and hairlines. Selection is a capsule (1.62): sidebar and list rows draw a rounded fill 10 pt from the column edges (radius 6 sidebar, 8 list), `SilkwebSelection` when focused in the key window and `SilkwebSelectionInactive` otherwise, with `labelColor` text (never white-on-accent); a focused capsule tints the folder icon and count suffix sage; Increase Contrast adds a 1 pt sage outline. The Outline current row (#72) uses the same `SilkwebSelection` capsule (radius 6, 1 pt sage outline under Increase Contrast, VoiceOver value “current”) with no bar. The Outline shows one Silkweb-drawn capsule, on the keyboard selection while the Outline is focused and on the caret’s section otherwise. Leaving the Outline drops its keyboard selection. The List’s own fill is suppressed, and the text stays `labelColor`. The capsule is `SilkwebSelection` in the key window, focused or not, and `SilkwebSelectionInactive` in a background window (#90). (1.56; the token is defined once in `PaneBackground.swift`, the swap point for 1.24.)
- **Typography (UI):** SwiftUI text styles only: `.body` (13pt), `.headline` (13pt semibold, list titles), `.subheadline` (11pt, secondary lines), `.caption` (10pt, paths/badges), `.title3` (Quick Open field). Use monospaced digits for counts. **Outline (#72, thread tree):** headings use one 13 pt size (H1 semibold, H2 regular, H3+ `secondaryLabelColor`; the current row `labelColor`), single-line with tail truncation and the full title as a tooltip. Hierarchy comes from the sidebar’s 1.5 pt `SilkwebThread` rails and 6 pt-radius elbows, 12 pt per level (depth capped at 4) in fixed 28 pt rows so rails join across rows. Image rows hang from the thread with a 16×12 thumbnail and a 12 pt secondary label. Above the list: the heading/image count summary and a hairline, no section header.
- **Editor typography:** source-style, configurable (1.24). Default is Menlo Regular 15pt (fallback `.monospacedSystemFont` 15), line height 1.6×, paragraph spacing 0, max content width 660pt centered, horizontal inset set in Settings ▸ Editor, 24–120pt (default 48pt), top inset 16pt. The preview stays fixed at 660px with 16px 48px 80px padding (`preview.css`) and doesn't follow the Settings inset; that mismatch is known. Every run uses the body size. Headings are bold in `SilkwebEditorHeading` and are not resized in the editor; graduated sizes appear only in Preview and Outline. Markdown markers remain visible in `tertiaryLabelColor`; heading prefixes are regular weight. Inline code uses the body font on a `quaternarySystemFill` chip; fenced code uses `secondaryLabelColor` without a background. Tabs span four spaces. The insertion caret is drawn in `NSColor.textColor` (it follows appearance and Increase Contrast; it is not the accent color). Its height is the ascender plus descender of the font at the caret, sitting on the text baseline, not the full line height. The width is the system default.
- **Spacing:** scale 4 · 8 · 12 · 16 · 20 · 24 · 32 · 48 (`Spacing`). Sidebar rows are 28pt; the tab strip is 32pt; the status bar is 26pt; editor horizontal inset 48pt. Sheet padding 20pt. Spacing between related controls 8pt; between groups 16–20pt. Toolbar and control sizes are system defaults. Small buttons in banners use `.controlSize(.small)`.
- **Symbols (SF Symbols, toolbar/sidebar only; macOS 15 context menus stay text-only):** All Documents `doc.on.doc`, library root `books.vertical`, folder `folder`, document `doc.text`, tag `tag`, new document `square.and.pencil`, new folder `plus` (the sidebar footer's Add menu: New Folder / New Document), sort `arrow.up.arrow.down`, editor `doc.plaintext`, split `rectangle.split.2x1`, preview `eye`, outline `list.bullet.indent`, info `info.circle`, warning `exclamationmark.triangle.fill` (systemOrange), missing library `externaldrive.badge.questionmark`, search `magnifyingglass`.

## 5. Shared components (reuse; don't reinvent)
1. **Empty/placeholder state.** Use `ContentUnavailableView` (symbol, title, one-sentence description, at most two actions). Use `ContentUnavailableView.search(text:)` for no-results. In list-column empty states (`ColumnEmptyState`, 10 pt horizontal inset) the actions (`ColumnEmptyActions`) sit side by side when they fit and otherwise stack, centred and as wide as the widest label; the title may wrap (#153).
2. **Image placeholders (shared by editor 1.41 and preview 1.40):** "Missing image: <path>", "Image outside library: <alt>", "Remote image not loaded: <alt>" — small labelled chips, left-aligned with the text column.
3. **Editor Banner.** A strip under the tab bar inside the detail column. Pane color + hairline (bottom edge), min height 36pt, 12pt horizontal padding. Content: 14pt symbol, `.callout` message, trailing `.small` bordered buttons, optional close ✕. Used for save failures (1.5), conflicts and external deletes (1.11), and read-only files. It posts an accessibility announcement. At most one at a time; highest severity wins.
3. **Inline Rename Field.** Text field in place of the row label. Selects the base name (no extension). Return, Tab and Shift-Tab commit. Clicking away commits if the name is valid; otherwise the old name returns and the message appears under the row. Escape reverts. Validation shows in a small popover anchored under the field with `systemRed` text; an invalid Return or Tab then beeps and keeps the field open. Used by 1.6 and 1.21.
4. **Folder Picker.** A sheet with a filter field and a folder outline, used by Move To… (1.7) and import destination (1.10). Spec lives in 1.7.
5. **Alerts.** Use `NSAlert` or SwiftUI `.alert` with a short title (statement or question), an informative sentence, and verb buttons (“Move to Trash”, never “OK/Yes”). Escape = Cancel. Destructive buttons use `.destructive` role.
6. **Status Bar.** A 26pt strip, pane color + hairline (top edge), 16pt horizontal padding, at the bottom of the detail column while a document is open. Three zones (#91): the **path** leads (`statusPath`), the counts sit on the bar's true midline (`statusCounts`, filled by 1.25), and the Focus/Typewriter chip (1.27) and save state trail in `.subheadline` secondary: “Saved” / “Edited” / “Not Saved” (coral) / “Read-only”. Path: `Library › Vanlife › Settling In`, the open document's real folder (a root document shows `Library › Untitled`), no count; folder crumbs 11 pt regular secondary as links that select the folder like a sidebar click (the document stays open), the document title 11 pt medium `labelColor` and never a link, `chevron.right` 8 pt semibold tertiary separators, 4 pt hover padding. Truncation ladder: cap crumbs at 140 pt, fold ancestors after the root into a `…` menu, fold the root, middle-truncate the title to 80 pt. Narrow rules, in order: the chip and save state never shrink; the path takes the room up to the centred counts less 12 pt and runs its ladder; a folded path that still doesn't fit pushes the counts off-centre toward the trailing side (12 pt from both neighbours); the counts then drop the characters segment and tail-truncate; last they hide. Zones never overlap (`StatusBarArrangement`). With no document open or the status bar hidden (⌘/), no path shows anywhere (the Info inspector still lists it); Preview-only still shows it. VoiceOver: a “Path” group with the full path as its value, crumbs as buttons (“Vanlife, folder”); order Path, Document statistics, Writing modes, Save state. Only save failures and their recovery are announced.
6a. **Tab bar (1.65): hairline folder tabs, coral dot = unsaved.** A 32pt strip of 28pt tabs, bottom-aligned under a 4pt gap, 110–220pt wide, 12pt titles. The active tab has a 1pt `separatorColor` outline on its top, left and right edges (6pt top corners, `labelColor` 40% under Increase Contrast) and an open bottom: the strip's bottom hairline runs everywhere except under it, so it joins the editor. Inactive tabs have no outline, `secondaryLabelColor` titles, and a `quaternarySystemFill` hover clipped to the tab shape. × sits at the leading edge on hover and on the active tab. An unsaved document shows a 6pt `SilkwebCoral` dot 6pt after its title, also on hover. Preview tabs stay italic. No fill beyond the surface.
7. **Inspector.** Right panel with a segmented header: **Outline** (1.18; thread tree #72) | **Info** (1.21 tags as chips + Suggested #72, path, dates). Outline focus (#89): a click on a row jumps and focuses the editor at the heading; ↑/↓ and Return work once the Outline is focused (Tab or a click on its background), and Return keeps it focused. ⎋ returns focus to the editor.

## 6. Keyboard shortcut map (single source of truth)
Before adding any shortcut, check it against this table. 1.25 audits the final map. Focus-dependent keys are marked †.

| Menu | Command | Shortcut | Ticket |
|---|---|---|---|
| Silkweb | Settings… | ⌘, | 1.24 |
| File | New Document | ⌘N | 1.6 |
| File | New Folder | ⇧⌘N | 1.6 |
| File | New Library… | ⌥⌘N | 1.4 |
| File | Open Folder in Place… | ⌘O | 1.4 |
| File | Open Recent ▸ (up to 10, ✓ on open sections, Clear Menu) | — | #195 |
| File | Quick Open… | ⇧⌘O | 1.20 |
| File | Open in New Tab | ⌘T | 1.26 |
| File | Import Folder Copy… | ⇧⌘I | 1.10 |
| File | Close Tab / Close Window | ⌘W / ⇧⌘W († ⌘W closes a tab only while the library window is key; otherwise the front window) | 1.26 |
| File | Close Library (the current Library's section and tabs; after Close Window) | — | #195 |
| File | Save (flush autosave now) | ⌘S | 1.5 |
| File | Rename… | ↩ † (sidebar/list focused; no menu key equivalent) | 1.6 |
| File | Move To… | ⌃⌘M † (sidebar/list focused) | 1.7 |
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
| Format | Shift Right / Shift Left | ⌘] / ⌘[ (Tab / ⇧Tab indent lists and selected lines; Tab elsewhere inserts the Settings ▸ Editor indent, default 4 spaces) | 1.12 |
| Format | Insert Table… | ⌃⌘T | 1.14 |
| View | Editor ↔ Preview toggle | ⌘R | 1.18 |
| View | Split Editor and Preview | ⌘4 | 1.18 |
| View | Show Outline / Show Document Info | ⌘7 / ⌘8 | 1.18 / 1.21 |
| View | Hide/Show Sidebars (folders + document list together) / Toolbar / Full Screen | ⌃⌘S / ⌥⌘T / ⌃⌘F (system) | 1.4 |
| View | Collapse All Libraries / Expand All Libraries (every sidebar section; after Hide Sidebars; disabled with fewer than two sections or nothing to change) | — | #225 |
| View | Show Status Bar | ⌘/ | 1.25 |
| View | Sort By ▸ Name / Date Modified / Date Created | ⌃⌥⌘1 / ⌃⌥⌘2 / ⌃⌥⌘3 | 1.9 |
| View | Include Subfolders | — (menu checkbox) | 1.9 |
| View | Focus Mode / Typewriter Mode | ⌃⇧⌘F / ⌃⇧⌘T | 1.27 |
| View | Bigger / Smaller / Actual Size (editor text) | ⌘+ / ⌘− / ⌘0 | 1.24 |
| Go | Folders / Documents / Editor (move focus) | ⌥⌘1 / ⌥⌘2 / ⌥⌘3 | 1.4 |
| — | Return focus to the editor (preview when Preview shows alone) | ⎋ † (Outline/Inspector focused; no menu item. Sheets, popovers, the find bar, rename and tag fields keep their own Esc) | #89 |
| Window | Show Next / Previous Tab | ⌃⇥ or ⇧⌘] / ⌃⇧⇥ or ⇧⌘[ | 1.26 |
| Window | Close Other Tabs | ⌥⌘W | 1.26 |

Deliberately unassigned: ⌘1–⌘9 tab selection (⌘4/⌘7/⌘8 are view commands) and ⌘U (Markdown has no underline). ⌃⌘Q is the system lock screen; never use it. Format commands are disabled unless the library window is key and its editor is first responder; Save and the tab items in Window need the library window key (#104).

## 7. Accessibility baseline (every ticket, not just 1.25)
- Every icon-only control has an `accessibilityLabel` and a `.help()` tooltip using the menu wording.
- Every drag-and-drop action has a menu/keyboard equivalent (Move To…).
- Use semantic colors (apart from the editor-heading exception in §4), which gives contrast in both appearances. Never convey state by color alone.
- Respect Reduce Motion (no spring/expand animations) and Full Keyboard Access (visible focus rings, Tab order outside the editor: sidebar → list → editor → inspector; in the editor Tab edits indentation, and pane focus uses ⌥⌘1/2/3; ⌃⇥ cycles tabs, §6).
