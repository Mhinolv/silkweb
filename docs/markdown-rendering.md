# Markdown rendering contract (v1)

`MarkdownParser.parse` returns a Sendable semantic AST; `parseInline` parses a single
line. `HTMLRenderer.render` accepts source or an AST and returns an HTML **fragment**.
Neither parser nor renderer fetches resources. Full-document callers should parse
and render off the main thread and debounce editor updates. No saved formats change.

HTML uses `<article class="sw-doc">` (`sw-empty` for an empty document), headings,
paragraphs, emphasis, strong, inline/fenced code, quotes, lists, links, images and
rules. Standard elements have no styles/classes except fenced code's
`language-…` hook. The first info-string word is filtered to ASCII letters, digits,
`_`, `+` and `-`; there is no highlighting. Lists retain paragraph wrappers and
ordered starting numbers. Soft breaks emit a newline with `.standard`, or `<br>`
with `.preserve`; two trailing spaces or a trailing backslash give a hard break.

| Source | Supported behavior / deliberate deviation from CommonMark |
| --- | --- |
| ATX headings | One to six hashes, up to three leading spaces; whitespace-separated closing hashes removed. Setext headings are not supported; dash underlines render as thematic breaks. |
| Emphasis / strong | Paired `*`/`_` and `**`/`__`, including triple markers and simple nested content; intraword markers are literal (`2*3*4`, `snake_case`). Complex adjacent delimiter runs do not implement CommonMark delimiter rules. |
| Code | Matching-length backticks; fenced backticks/tildes of length ≥3, including unclosed fences. Code is escaped and never parsed as Markdown. Indented code is not implemented. |
| Links / images | Inline labels, balanced destination parentheses (at most 32 levels), angle-delimited destinations and optional single/double-quoted titles. No reference links, autolinks or entity decoding. Backslash escapes supported. |
| Quotes / lists | Explicit `>` on every quoted line. Space-indented list children/continuations must align with the parent's content column. Ordered markers have at most nine digits. Lazy continuation, tabs as list indentation, and CommonMark tight/loose rules are not implemented. |
| HTML | Angle-delimited source is escaped in `sw-raw-html` spans, including tags/comments/autolinks; other text is always escaped. HTML inside code is ordinary escaped code. |
| Extensions | Table rows with leading/trailing pipes, task-list lines, reference/footnote definition lines remain literal paragraph text. Strike, TOC, wikilinks, other unsupported syntax remain visible; no tables/tasks/footnotes/TOC semantics until 1.17. |
| Resource limits | Block/inline nesting stops at 32. Inline lookahead has a work budget proportional to each source line. On exhaustion the remaining source stays literal and escaped, with no truncation. |

URLs allow absolute HTTP(S), mailto links (not images), fragments and local relative
paths. Unknown/active schemes, controls, backslashes, malformed percent encoding,
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
Row summaries alone remove task/strike delimiters for compatibility with existing
list behavior; these extensions stay literal in the HTML output.
