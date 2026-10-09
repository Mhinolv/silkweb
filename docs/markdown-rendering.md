# Markdown rendering contract (v1)

`MarkdownParser.parse` returns a Sendable semantic AST; `parseInline` parses a single
line. `HTMLRenderer.render` accepts source or an AST and returns an HTML **fragment**.
Neither parser nor renderer fetches resources. Full-document callers should parse
and render off the main thread and debounce editor updates. No saved formats change.

HTML uses `<article class="sw-doc">` (`sw-empty` for an empty document), headings,
paragraphs, emphasis, strong, inline/fenced code, quotes, lists, links, images and
rules. No inline styles are emitted. Extension class hooks are listed below; fenced
code uses a `language-…` hook. The first info-string word is filtered to ASCII letters, digits,
`_`, `+` and `-`; there is no highlighting. Ordinary lists retain paragraph wrappers and
ordered starting numbers; task-item leading text follows its checkbox directly. Soft breaks emit a newline with `.standard`, or `<br>`
with `.preserve`; two trailing spaces or a trailing backslash give a hard break.

| Source | Supported behavior / deliberate deviation from CommonMark |
| --- | --- |
| ATX headings | One to six hashes, up to three leading spaces; whitespace-separated closing hashes removed. Setext headings are not supported; dash underlines render as thematic breaks. |
| Emphasis / strong | Paired `*`/`_` and `**`/`__`, including triple markers and simple nested content; intraword markers are literal (`2*3*4`, `snake_case`). Complex adjacent delimiter runs do not implement CommonMark delimiter rules. |
| Code | Matching-length backticks; fenced backticks/tildes of length ≥3, including unclosed fences. Code is escaped and never parsed as Markdown. Indented code is not implemented. |
| Links / images | Inline labels, balanced destination parentheses (at most 32 levels), angle-delimited destinations and optional single/double-quoted titles. No reference links or entity decoding. HTTP(S) angle and bare autolinks plus bare `www.` links are supported; `www.` destinations use HTTPS. Trailing sentence punctuation and unmatched closing parentheses/brackets are excluded. Autolinks do not nest inside link labels. Backslash escapes supported. |
| Quotes / lists | Explicit `>` on every quoted line. Space-indented list children/continuations must align with the parent's content column. Ordered markers have at most nine digits. Tab-indented lists are supported: leading tabs advance to the next 4-column stop, so they nest like spaces (1.76). Lazy continuation and CommonMark tight/loose rules are not implemented. |
| HTML | Tag-shaped source, comments, declarations and processing instructions are escaped in `sw-raw-html` spans; comparison prose such as `1 < 2 and 3 > 2` stays plain escaped text. HTML inside code is ordinary escaped code. |
| Tables | Pipe headers followed by matching delimiter columns (at least three dashes). Leading/trailing pipes are optional for multi-column tables; one-column tables require a pipe. Escaped pipes remain literal, including in code spans. Short rows are padded, excess cells ignored. Inline formatting is supported. `sw-table-wrap` surrounds a semantic table with `thead`/`tbody`; optional `sw-align-left/center/right` classes apply to header and body cells. |
| Tasks / strike | List items beginning `[ ]`, `[x]` or `[X]` followed by whitespace/end render disabled checkboxes with `sw-task` on the item and `sw-task-list` on its list (including mixed/ordered lists). Paired `~~` emits `del`, including inline children. |
| Headings / TOC | `MarkdownDocument.headings` exposes level, plain text, ID and original UTF-16 source range (excluding newline, including quote/list prefixes). Direct ASTs without ranges report `NSNotFound`. Unicode letters/numbers are retained in lowercase slugs; other runs become hyphens; empty slugs use `section`. Duplicate/colliding IDs get numeric suffixes in document order. Standalone `[TOC]` emits `sw-toc` navigation, nested under the nearest preceding lower-level heading; missing levels do not create empty entries. No headings means no TOC output. Code remains literal. |
| Footnotes | `[^label]` and `[^label]: text`, with contiguous four-space-indented continuations. Labels are case-sensitive, without whitespace/brackets; first definition wins. Definition content supports inline Markdown and soft breaks, not separate block paragraphs/lists. First reference order assigns numbers. Missing definitions remain literal; unused definitions are omitted. Repeated references have distinct `fnref-N-K` IDs and individual back-links. Referenced definitions render once at the end in `sw-footnotes`, including cyclic references without recursion. |
| Unsupported | Reference-link definitions, wikilinks and other unsupported syntax remain visible. |
| Resource limits | Block/inline nesting stops at 32. Inline lookahead has a work budget proportional to each source line. On exhaustion the remaining source stays literal and escaped, with no truncation. |

URLs allow absolute HTTP(S), mailto links (not images), fragments and local relative
paths (including attribute-escaped ampersands in relative queries/fragments).
Unknown/active schemes, controls, backslashes, malformed percent encoding,
network-path references and absolute local paths are blocked. Image-only `data:`
URLs allow PNG/JPEG/GIF/WebP MIME types with valid base64 payloads up to 4 MiB of
encoded data. SVG, other data formats, malformed/oversized payloads and all data
links are blocked. Blocked destinations emit only the label/alt in `sw-blocked-link` with the
specified explanatory title. Attributes and text are always escaped, including
input ampersands; input HTML entities are displayed literally.

File URLs require `Options.libraryRoot`. Relative parent paths require both
`libraryRoot` and `documentURL`; the document and resolved destination must stay
inside that root. Symlinks are resolved through the nearest existing ancestor,
including for missing files; dangling symlinks are rejected. These checks consult
filesystem metadata but never read note/asset contents. Future preview resource
handlers must enforce containment again at load time (files can move after rendering).

Remote HTTP(S) images retain `<img>` inside `sw-remote-image`. Consumers **must block
network loading** (1.18) before displaying this fragment; producing HTML does not
load images. CSS, CSP/resource handlers, export and print are owned by their tickets.

Document-list snippets walk this AST, omit thematic breaks/fence markers, skip a
matching leading title heading and retain the existing 512-byte grapheme limit.
Row summaries also walk table/task nodes and remove paired literal task/strike delimiters
for compatibility with existing list behavior.

## Links: one grammar, one resolver (#176)

`MarkdownLinks.scan` runs this parser and records every link and image it renders, with
UTF-16 source ranges, plus reference definitions (`[label]: destination`, which render as
text). Code spans, fenced code (including in lists and quotes) and escaped syntax produce
nothing. Link-like text the parser leaves as text (wikilinks, HTML `href`/`src`, malformed
or unbalanced links, stray `](`) is reported separately, outside code and escapes.
The preview, the link index and the move/rename rewrite all read links from this scan.

`MarkdownLinkResolver` resolves a destination as the preview does: the renderer's
destination rules first, then the path relative to the linking Document's Folder, with
percent-decoding (`%2F` is a separator), `.`/`..`, and query and `#fragment` removed. The
status identifiers are fixed:

| Status | When | `links_to` edge |
| --- | --- | --- |
| `resolved` | One library item: a byte-exact spelling; else the only Unicode-equivalent spelling; else, on a case-insensitive volume, the only case-folded spelling | Inline link to another Markdown Document only |
| `anchor` | Empty path: `#fragment`, `?query` or nothing | No |
| `missing` | Inside the library, no match (a single case alias on a case-sensitive volume) | No |
| `ambiguous` | Several Unicode- or case-folded matches and no exact spelling, on either kind of volume | No |
| `outsideLibrary` | `..` above the root, or a symbolic link on the path | No |
| `external` | `http(s)` with a host, `mailto:`, allowed `data:` images | No |
| `unsupported` | Reference definitions, folders, `file:` and absolute paths, blocked schemes, malformed encoding, paths with `&` | No |

Images are never edges. Edges are de-duplicated per target and section (the decoded
fragment). The preview opens a Document only for `resolved` (`LibrarySnapshot.document(linkedAt:)`
applies the same spelling rule); `ambiguous` beeps like `missing`.

The rename rewrite updates every link, image and reference definition the scan reports,
keeps the author's form (angle brackets, title, query and fragment, relative paths; a path
written readably stays readable, otherwise new names are percent-encoded) and keeps the
author's Unicode normalisation for unchanged names. It lists, and leaves as written,
destinations with backslash escapes or malformed encoding, paths above the root, ambiguous
targets of a move, and the unsupported syntax above. Differences from the earlier rewrite
grammar, now matching the renderer: balanced parentheses and Unicode spaces in bare
destinations are rewritten (were listed); an escaped `!` before a link no longer hides the
link; links on 4-space-indented "fence" lines outside lists are rewritten (no indented code);
links in table cells (including after `\|`), headings, footnote definitions and quotes are
rewritten; escaped `](` is no longer listed; Unicode names are no longer rewritten in
decomposed form.
