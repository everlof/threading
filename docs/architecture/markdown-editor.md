# Markdown documents

Threading's standalone Markdown window is host-only document UI, independent of projects and
agent sessions. `MarkdownEditorWindows` is the one owner reached by the File menu, command
palette and application-open URL delivery. Reopening a file raises its existing window; file
reads resolve symlinks on the worker so aliases converge on the same document.

The vertical `ThemedSplitView` places plain, undoable `ThemedTextView` source on the left and
native `MarkdownView` on the right. Preview uses exactly the conversation renderer and its
CommonMark subset: headings, paragraphs, fenced code, simple lists, quotes, emphasis, links and
pipe tables. It does not add a WebKit Markdown engine.

The parser and block views are shared; the *setting* is not. `MarkdownPresentation.document`
gives the editor what a chat answer deliberately flattens — distinct H1–H4 sizes
(`Design.Typography.documentHeading`), `Spacing.large` above a heading and `Spacing.medium`
between blocks — while `.conversation` keeps the transcript's single heading step. Rendered
prose is centred at `Design.Size.readableWidth`; both panes start their first line
`Spacing.large` below the band. The source stays one monospaced face: `MarkdownSourceHighlighter`
only recolours structural marks (heading hashes, list/quote markers, fences, rules, table pipes,
emphasis and code delimiters, link brackets and targets) to tertiary ink, never font or
metrics, so caret geometry and the code font's recorded role are untouched and the dynamic
inks follow a live theme switch. Underscores are not tinted: they are more often `snake_case`
than emphasis. The header carries a quiet word count (runs holding a letter or digit, so
Markdown's own marks are not words) and a tertiary Save.

**The preview follows the page being edited.** A README longer than one bounded page used to
return the preview to page one on every keystroke. The worker maps the caret's source line to
the page holding it (`Markdown.sourceBlockLines`), the reader's scroll position survives an
edit on the same page, and a theme rebuild keeps the page on screen. Loading a document puts
the caret at its start, because assigning `NSTextView.string` leaves it after the last
character. New windows cascade from the key editor instead of stacking exactly over it. The secondary window keeps native macOS
caption hardware, following detached-browser and gallery policy; all content, controls, text
selection, divider and scrolling belong to the current theme and respond to live changes.
The split view owns its direct pane frames; Auto Layout only owns each pane's contents.
`ThemedTextScrollView.fillsViewport` sizes the empty source after clip-view tiling, making the
complete source pane clickable. Finite code and table blocks reserve scrollbar chrome through
`ThemedScrollView.heightToFitContent`, so classic themes cannot hide the final line or row —
and only while the block is wider than the pane, so a block that fits draws no empty trough.

Document keys are scoped to the key editor window before the application menu handles them:
⌘N new, ⌘O open, ⌘W close, ⌘S save and ⇧⌘S Save As. One table,
`MarkdownEditorDefaults.documentShortcuts`, drives both the window's dispatch and what the menu
bar shows. While an editor is key, `applyShortcutBindings` prints those chords on the File items
(a person's own binding for one of them wins) and takes them off the main window's commands —
New Session, Open In, Close Tab, Toggle Sidebar, Silence Sounds — which get them back when the
editor stops being key. Before that the editor took the keys silently while View still printed
⌘S beside Toggle Sidebar. Save, Save As and Close are unavailable while a sheet or close
question is up, so a menu key cannot start a second sheet. The source header also exposes Save.

## File authority and lifetime

`MarkdownEditorFileStore` serializes regular-file reads, UTF-8 decoding, byte encoding and
coordinated atomic writes away from the main actor. Reads are capped at 1 MiB plus one sentinel
byte; invalid UTF-8 and non-regular files are refused. Source is never silently truncated.
Saves compare the current disk bytes with the exact opened/last-saved bytes before replacing
the file. A file that changed since is never replaced by an ordinary save: the non-suppressible
`.replaceChangedMarkdownDocument` choice offers Replace (`replaceOnDisk`) or Save As…, and
Cancel keeps the unsaved text. Save As uses the system panel's explicit overwrite decision, and
saving to the same path retains the baseline check. Edits made while a write is pending remain
dirty after the submitted snapshot is saved.

**The file is shared with agents.** `MarkdownDocumentWatcher` watches the open path with two
non-recursive vnode sources — the file (in-place writes) and its folder (an atomic save's new
inode, a rename, a delete) — and costs one `stat` per coalesced event; a recursive FSEvents
stream would have watched the whole home directory for a note kept there. Only a moved `stat`
signature reaches the main actor, where the bytes are read off-main and compared with the
baseline, so the editor's own saves change nothing. An unedited document follows the file as one
undoable edit of only the span that differs, keeping caret and scroll. Unsaved edits are never
replaced: a `PaneNoticeView` above the source offers Reload, itself undoable. A file moved or
deleted keeps the document open and dirty, and Save writes it back. A file that can no longer
be read here (over 1 MiB, invalid UTF-8) says so and leaves saving to the replace choice.

Close and quit review dirty documents using the non-suppressible `.closeMarkdownDocument`
choice. Cancel and failed/cancelled saves preserve the open editor. A close or quit pressed
while a save is in flight waits for it and then asks only if something is still unsaved;
refusing made ⌘Q during a save do nothing. Quit review precedes every agent/store shutdown
operation and answers with `.terminateLater`: the sheets run, then
`reply(toApplicationShouldTerminate:)` carries the rest of the termination decision. The first
version cancelled the quit and called `terminate` again, which also cancelled a logout or
restart that had asked to quit. Drafts are in memory, with explicit saves to user-selected
files; window and draft restoration are not part of this surface.

## Scaling contract

Expected source is a note or README of 1–64 KiB. The stress fixture drives 20,000 blocks
(560,000 bytes), and accepted input is bounded at 1 MiB. Source editing is TextKit's document
surface; preview planning is a serial actor's value-only scan. Coalescing happens before this
worker, cancelled requests check cancellation, and a generation check prevents stale results
from replacing a newer preview. Mounting, theme rebuild and layout materialize only the native
renderer page (48 source blocks / 96 source lines, with its existing nested list/table budgets).
A block above 32 KiB pauses the preview before any attributed document or block views are
constructed. All source remains readable, editable and saveable. Layout and scrolling perform
no file work or whole-source scans. The word count and caret line are computed by the same
worker. Source tinting re-colours only the paragraphs an edit touched, reading the storage's
own `mutableString` (bridging `textStorage.string` copied the whole document on every
keystroke). A loaded document tints its first 64 KiB synchronously and the rest in 64 KiB
slices, one per main-actor turn; an edit made before the slices finish moves the remainder.

`MarkdownEditorTests.testStressPreviewKeepsOnlyOneBoundedNativePage` reports preparation/mount,
layout and live-preview-view count through the shipping controller. Behavior tests cover undo,
dirty state, theme preservation, large-block refusal and bundle capability. File tests cover
UTF-8, bounds and conflicting external writes. The UI journey edits, cancels a dirty close,
saves and reopens through the real File menu and panels. `markdown-editor` is the targeted UI
evidence entry for the production window under System light/dark, Cyberpunk and Windows 98.

## Opt-in file association

The bundle advertises `.md`/`.markdown` and a separate `.mc` Markdown alias as alternate editor
capabilities. Settings → Markdown has one explicit Make Default action for each type. The
operating system is the preference's owner; the page reads its actual handler whenever visited,
and `NSWorkspace.setDefaultApplication` runs only on the user's action. Launch never changes or
reasserts the handler. macOS can require its own confirmation. Finder's Get Info → Open With →
Change All changes the handler afterwards. No test invokes system registration.

Extensions do not receive document source, URLs, save authority, registration authority or a
replacement slot. Theme presentation is reusable Design vocabulary; all document mutations,
exact file identities, conflict checks, unsaved decisions and system-handler changes stay
host-owned.

## Finder Quick Look

`ThreadingMarkdownPreview.appex` is a sandboxed macOS Quick Look preview extension embedded in
`Threading.app/Contents/PlugIns`, independent of the user's default editor. It declares the same
Markdown UTIs and uses the modern data-based `QLPreviewProvider` API. The OS owns the Quick Look
window, preview-provider selection and enabling/disabling the extension. No legacy generator or
Finder injection is installed.

`Packages/ThreadingMarkdownKit` owns the existing native block and inline parser, including its
32-level recursion limit and HTTP/HTTPS-only link policy. The app supplies resolved fonts and
inks through `MarkdownStyle`; conversation heading fonts still resolve in the conversation
surface. Quick Look presents those exact parsed blocks and runs as semantic HTML. Headings,
quotes, lists, tables and fenced code become readable document structure. Raw HTML is escaped,
there are no scripts or external images, and a content-security policy forbids resource loads.

Emphasis is read from the parser's font traits through system faces that always have bold
and italic; the theme's family is CSS's to draw. Detecting through the theme's own family
erased emphasis wherever it lacks those faces — Windows 98's has neither. The backdrop pattern
is painted on the root element so it covers the whole canvas, a diagonal grid is drawn with
repeating stripes (a rotated gradient in a square tile draws corner notches, not lines), and
code falls back through `ui-monospace` rather than WebKit's Courier when Quick Look cannot load
the theme's code family.

The preview worker reads at most 1 MiB plus one sentinel byte, closes the handle before display,
and refuses non-regular files and invalid UTF-8. It selects at most 256 blocks, 128 KiB of source
and 32 KiB per block before attributed styling. Larger documents show an explicit excerpt notice;
this preview does not claim to show the complete source. Source planning and file/theme I/O are
serial worker operations. Only bounded font/inline styling is main-actor work.

The host publishes two resolved light/dark theme snapshots, capped at 16 KiB, into its
`codes.threading.markdown-preview-theme` preferences domain at launch and theme changes. The
sandboxed extension reads that one domain through a
`temporary-exception.shared-preference.read-only` entitlement, without starting the app; it can
neither write it nor read any other domain. The snapshot contains presentation only, never
source, session state or file paths. This was first an App Group, which is profile-backed: the
Developer ID profile did not authorize it, so every auto-install from the commit that added it
failed and a release would have too. The exception needs no profile; the Mac App Store refuses
temporary exceptions, which costs nothing for an app that runs unsandboxed for its PTYs. Missing snapshots use System light/dark. Preview colours, family names,
radii and static grid/dot patterns follow the theme; bespoke assets, animation and process-local
custom font registration are deliberately outside the Quick Look contract. UI scenarios do not
publish into the user's preferences. Document editing, saves, conflicts and default-handler
registration remain host-owned.
