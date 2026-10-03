# Markdown documents

Threading's standalone Markdown window is host-only document UI, independent of projects and
agent sessions. `MarkdownEditorWindows` is the one owner reached by the File menu, command
palette and application-open URL delivery. Reopening a file raises its existing window; file
reads resolve symlinks on the worker so aliases converge on the same document.

The vertical `ThemedSplitView` places plain, undoable `ThemedTextView` source on the left and
native `MarkdownView` on the right. Preview uses exactly the conversation renderer and its
CommonMark subset: headings, paragraphs, fenced code, simple lists, quotes, emphasis, links and
pipe tables. It does not add a WebKit Markdown engine. The secondary window keeps native macOS
caption hardware, following detached-browser and gallery policy; all content, controls, text
selection, divider and scrolling belong to the current theme and respond to live changes.
The split view owns its direct pane frames; Auto Layout only owns each pane's contents.
`ThemedTextScrollView.fillsViewport` sizes the empty source after clip-view tiling, making the
complete source pane clickable. Finite code and table blocks reserve scrollbar chrome through
`ThemedScrollView.heightToFitContent`, so classic themes cannot hide the final line or row.

Document keys are scoped to the key editor window before the application menu handles them:
⌘N new, ⌘O open, ⌘S save, ⇧⌘S Save As and ⌘W close. The application command register exposes
the same host operations without competing default global chords. The main window retains its
existing ⌘N/⌘O/⌘S/⇧⌘S meanings. The source header also exposes Save.

## File authority and lifetime

`MarkdownEditorFileStore` serializes regular-file reads, UTF-8 decoding, byte encoding and
coordinated atomic writes away from the main actor. Reads are capped at 1 MiB plus one sentinel
byte; invalid UTF-8 and non-regular files are refused. Source is never silently truncated.
Saves compare the current disk bytes with the exact opened/last-saved bytes before replacing
the file. An external edit refuses the save and offers Save As in the refusal copy; the editor
keeps the unsaved text. Save As uses the system panel's explicit overwrite decision, and saving
to the same path retains the baseline check. Edits made while a write is pending remain dirty
after the submitted snapshot is saved.

Close and quit review dirty documents using the non-suppressible `.closeMarkdownDocument`
choice. Cancel and failed/cancelled saves preserve the open editor. Quit reviews precede every
agent/store shutdown operation and recheck document revisions so another edit during a later
window's question cannot be discarded by stale consent. Drafts are in memory, with explicit
saves to user-selected files; window and draft restoration are not part of this surface.

## Scaling contract

Expected source is a note or README of 1–64 KiB. The stress fixture drives 20,000 blocks
(560,000 bytes), and accepted input is bounded at 1 MiB. Source editing is TextKit's document
surface; preview planning is a serial actor's value-only scan. Coalescing happens before this
worker, cancelled requests check cancellation, and a generation check prevents stale results
from replacing a newer preview. Mounting, theme rebuild and layout materialize only the native
renderer page (48 source blocks / 96 source lines, with its existing nested list/table budgets).
A block above 32 KiB pauses the preview before any attributed document or block views are
constructed. All source remains readable, editable and saveable. Layout and scrolling perform
no file work or whole-source scans.

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

The preview worker reads at most 1 MiB plus one sentinel byte, closes the handle before display,
and refuses non-regular files and invalid UTF-8. It selects at most 256 blocks, 128 KiB of source
and 32 KiB per block before attributed styling. Larger documents show an explicit excerpt notice;
this preview does not claim to show the complete source. Source planning and file/theme I/O are
serial worker operations. Only bounded font/inline styling is main-actor work.

The host publishes two resolved light/dark theme snapshots, capped at 16 KiB, into the signed
`SMQ3E8Y57T.codes.threading.markdown` App Group at launch and theme changes. The extension reads
that snapshot without starting the app; it contains presentation only, never source, session
state or file paths. Missing snapshots use System light/dark. Preview colours, family names,
radii and static grid/dot patterns follow the theme; bespoke assets, animation and process-local
custom font registration are deliberately outside the Quick Look contract. UI scenarios do not
publish into the user's shared container. Document editing, saves, conflicts and default-handler
registration remain host-owned.
