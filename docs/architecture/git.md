# Git Layouts and Git Review

Reading git metadata off disk, and the per-session review pane.

Part of the [CLAUDE.md](../../CLAUDE.md) index. Forge detection, pull/merge requests, credentials
and managed publication live behind the separate
[source-control provider boundary](source-control.md); this file owns local Git only.

`GitInfo` reads git metadata from disk rather than shelling out. Three layouts matter, and
only the first has a `.git` *directory*:

| Layout | `.git` | Metadata lives at |
|---|---|---|
| Ordinary checkout | directory | `<root>/.git` |
| Linked worktree | file | `<repo>/.git/worktrees/<name>` |
| Submodule | file | `<super>/.git/modules/<name>` |

Worktrees and submodules store a **file** containing `gitdir: <path>`, so reading
`<root>/.git/HEAD` finds nothing — worktrees showed no branch at all until `gitDirectory(for:)`
started following that pointer. A git *subtree* needs no handling: it is merged content, and
looks exactly like an ordinary subdirectory.

`worktreeLocation(for:)` resolves a path once into both identities, and the accessors
(`worktreeIdentity`, `repositoryIdentity`, `worktreeName`) read from it. The two identities are
the `git-dir` / `git-common-dir` distinction: `worktreeIdentity` is the checkout's own git
directory (`<repo>/.git/worktrees/<name>`, or `<repo>/.git` for the main tree) and is stable
per checkout — it does not change when the branch does; `repositoryIdentity` trims the
`/worktrees/<name>` suffix so every checkout of a repo shares one identity, which is the
sidebar's grouping key. **`worktreeIdentity` is the durable key for "which checkout"; the
branch is only ever a display value.** A submodule keeps its own identity under `/modules/`,
correctly — it is a separate repository that happens to live inside another.

The sidebar groups **only when a repository has more than one checkout added**, so the common
single-checkout case keeps the flatter two-level layout. Grouped checkouts are labelled by
branch, since the repository name is already shown above them.

A branch belongs to a *checkout*, not to a repository: two worktrees of one repo are on
different branches simultaneously. A chat re-reads it when the agent stops working, which is
when an agent is most likely to have just switched. A standalone terminal updates it with its
cwd, from OSC 7 or the process-directory fallback, because the shell can move between added
projects while it remains live.

The composer's location chip therefore offers **checkouts, not branches**
(`ProjectStore.siblingCheckouts(of:)`): its menu opens with this checkout, any other added
checkout of the same repository, then `New Worktree…`, and the projects sit one layer in under
*Switch Project* — running here and going elsewhere are not the same act. It listed the repository's whole `git branch` output once,
which invited picking a branch nothing was standing on — the session then ran in the origin
checkout anyway while its record claimed the branch that was asked for. A branch with no
checkout is not a place a session can run; making one is what the worktree item is for.

That item lives *in the menu* rather than in a chip of its own, where it read as a state —
one of the selected choices in the row — when it is an action. It closes the run-here section
rather than opening the navigate-there one, because it is the row that does both: it makes a
place and then moves the composer to it.

A *session*, though, carries its own branch record (`AgentSession.branch`): captured at
creation, re-read by `ProjectStore.refreshBranch` at the same stopped-working moment, and —
by default — **followed while dormant**. The record froze while dormant once, on the argument
that a conversation happened on whatever was checked out at the time; in practice the frozen
answer misled about the thing the sidebar is for — a dormant session *resumes* onto whatever
its checkout is on now, and after a switch in another session the chat sat grouped under a
branch it would never run on again. `CheckoutBranchFollower` is the following: one
branch-scoped `GitCheckoutWatcher` per unique checkout (keyed by `worktreeIdentity`, watching
only the worktree's own `HEAD`, so builds and agent edits never wake it), applying a switch to
every chat and standalone terminal standing in that checkout via
`ProjectStore.refreshBranches(forCheckoutAt:)` — whether the mover was another session, the
shell drawer, a standalone terminal or a terminal outside Threading.
A detached reading is never applied on this path: a rebase detaches `HEAD` for seconds at a
time, and clearing every record for the flicker would regroup the sidebar twice per rebase; a
genuine detachment still lands per session at its own stopped-working moment. **Settings >
General > "Follow the checkout's branch"** turns the following off and restores the frozen
record, for whoever wants the sidebar to say where a conversation *happened* rather than
where it would resume. The record drives the sidebar's **branch grouping**
(`SidebarTreeBuilder`, `BranchGroupNode`): inside a project, chats and standalone terminals
sharing a branch gather
under a heading — the earns-its-level rule as repository grouping, applied one level down —
and once *any* branch has earned the level, lone branches earn headings too
(`AppSettings.groupsLoneBranches`, on by default). The base rule alone left a **mixed tree**:
a heading over the shared branch, and beside it a bare row whose different branch was
invisible without the hover popover — found by switching a live chat to a fresh branch and
watching it merely *leave* the master group. All-or-nothing labelling fixes that reading
while keeping the flat layout for a project with no shared branch at all, so the common
one-branch-per-chat project still pays no level per row; with the refinement off, the
original more-than-one rule stands alone. Rows with no recorded branch always stay directly
under the project, and a group takes its first child's position so the list keeps
its order. Toggleable via `AppSettings.groupsSessionsByBranch` (on by default; Settings >
General), and from where the grouping is *seen*: the **sidebar header's arrangement control**
(`PaneHeaderView` + the "use groups" glyph, opening grouping then `SidebarSessionOrder`
sorting — order added, recent activity, or name, pinned rows always first), a checked menu
item in the project-row and branch-heading context menus, and a gear that fades into a branch
heading's trailing slot on hover (the session rows' `⋯` crossfade mechanism, reused) opening
both grouping toggles plus an "All Settings…" door. The View menu carries the same two
toggles with rebindable chords (⌃⌘B and ⌥⌘B — b for branch at two depths of the same key;
`AppCommands`), stamped with their checkmarks in `AppDelegate.validateMenuItem`, which is the
menu bar's only stateful item. Branch headings are not selectable, collapse like projects
(state kept in-memory only — the groups themselves are transient), and the hover popover
prefers the session's recorded branch over the checkout's current one for the same reason the
record exists.

Pinning is also a row state, not only an ordering rule. `SessionRowView` keeps a filled pin after
the title (the same mark the mobile dashboard uses), outside its replaceable content so an
extension-customized identity cannot erase host-owned state. The mark is an accessible image,
and on an emphasized selection it takes the selection's ink rather than drawing the accent on
the accent-filled row.

The branch is **not shown on the project row** — it lived there once as a subtitle, which read
as though the project *were* that branch, when a checkout's branch changes and one repo can
have several checkouts at once. It surfaces instead in the **session rows' hover popover**
(`SessionInfoPopoverViewController`) — sessions are what get selected and what run inside the
checkout — alongside the session's full title, its agent and account, the folder path, and,
when the checkout is a linked worktree, `GitInfo.worktreeName`. The one place the branch still
names a row is a *grouped checkout*, where it is the row's identity — the repository name is
already above it, so the branch is what tells the checkouts apart. The popover opens after a
short hover dwell so it does not flash while the pointer crosses rows, and it survives the
constant reconfigures of a working session's row, dismissing only on exit or reuse for a
different session.

## Git Review

A per-session **Review** tab in the display pane (`GitReviewViewController`, hosted as
`DisplayTab.Body.review` — the browser's live-view-controller shape, reused). View menu ▸
Git Review, ⇧⌘R.

It was read-only for its first version and no longer is; what survives of that rule is the
line between *reversible* and not. `GitIndexWriter` is the whole of the write half — stage,
unstage, commit — and there is **no discard**, because every other action here is undone by
the control beside it while throwing away a change an agent just made is undone by nothing.

Six modes behind one chip, and the default is not one of opencode's five: **Uncommitted**
(HEAD vs worktree, staged + unstaged + untracked) is what a user actually asks after an agent
turn — agents rarely commit mid-task, and splitting that answer across Unstaged/Staged made
the common case two reads. Unstaged, Staged, Last Turn, Branch and Commit complete the set.
Branch diffs from `merge-base(default branch, HEAD)` **to the worktree**, so uncommitted work
counts — a branch's `+362 −26` should not shrink when work is merely unstaged. On the default
branch itself the merge-base is HEAD and the mode degrades to Uncommitted, which is honest.
Commit mode is the history browser: a paged `git log --numstat` list (100 a page), one commit
opened into its own diff with Back returning to the list.

On an unborn branch, Uncommitted uses a repository-native empty tree as the missing HEAD and
still compares it to the worktree. It must not fall back to `--cached`: a newly staged file can
be edited again before the first commit, and the regular full-working-copy mode includes those
latest bytes.

The menu states the endpoints under every name — HEAD→working tree, index→working tree,
HEAD→index, turn start→turn end, merge base→working tree, or committed history — because
"staged" and "unstaged" alone are easy to read as filters rather than comparisons. Last Turn
renames itself **This Turn** while its selected turn is in flight. A second chip selects any
retained **Turn N**, newest first; the changed-files card in each conversation turn opens that
exact checkpoint instead of redirecting every old card to the newest one. Mobile exposes the five
working-copy comparisons and defaults to Uncommitted too; Commits remains the desktop history
navigator rather than pretending to be another compact diff mode.

The data layer (`GitReviewReader`) shells out on a dedicated queue and completes on main —
`GitWorktree`'s runner made async, following `ProjectIconResearch`'s shape. Every invocation
passes `--no-optional-locks`, so a *read never takes `index.lock`* out from under the agent
working in the same checkout, and `-c core.quotepath=false` so paths arrive literal. Diffs
add `--no-color --no-ext-diff --no-textconv`; parsing git's porcelain and unified-diff output
is `GitDiffParser`, pure functions with the fixture traps (C-quoted paths, the trailing tab
after a path with spaces, `\ No newline` markers, `-z` rename records) pinned by unit tests.

The executable remains the absolute system Git, while its child environment uses the PATH from
the user's login shell. Git itself does not need PATH discovery, but hooks, credential helpers,
filters and Git LFS do; inheriting launchd's GUI PATH made those programs disappear only inside
app-owned worktree and push operations. The resolved PATH is cached once per shell and explicit
per-operation overrides (such as the alternate index used below) are applied afterwards.

**`git diff` never mentions untracked files**, so the ordinary working-tree modes synthesize them:
`status --porcelain=v2 -z -uall` lists them individually and each becomes an all-added file
diff read in-process — not `diff --no-index` per file, which would spawn a process per file
in a freshly scaffolded project. Size-capped (256 KB), binary-sniffed by git's own NUL
heuristic. Last Turn does not synthesize: both of its endpoints are complete trees, so a file
untracked at either boundary is an ordinary tree entry and git reports its exact bytes.

**Each turn has two immutable trees written through a private alternate index.** The
real index is copied only for its tracked-file roster; `GIT_INDEX_FILE=<temporary>` plus
`git add -A -- .` overlays the exact worktree bytes and admits non-ignored untracked files,
then `git write-tree` records the result without touching the checkout's real index or worktree.
The start and authoritative end trees are published at
`refs/threading/turn-checkpoints/v1/<session UUID>/<checkpoint UUID>/{before,after}`. This is the
only namespace the checkpoint store can create or delete, and every deletion validates the full
shape again; branches, tags, remotes and every ref outside it are out of reach. The comparison is
the recorded tree→tree pair, never a historical start against today's worktree. This closes both
the temporal hole in the former in-memory Last Turn and the path-set hole of `stash create`:
modifying or
deleting a file that was already untracked at turn start is now visible, unchanged untracked
files are absent, and unborn repositories work the same as repositories with commits.

The snapshot is an **admission boundary**, not an activity-edge side effect. Native Chat holds
provider transport until `GitTurnBaselineStore.prepareTurn` publishes `before`. Terminal
`UserPromptSubmit`/turn-start hooks hold only that lifecycle HTTP response; the CLI cannot run
the turn's first tool until the tree is stored. Completion is a barrier too: native Chat holds
the provider's `turnFinished` event before applying it (and therefore before admitting a queued
message), while terminal Stop/turn-finished holds its HTTP response until `after` is published.
Stop is the provider's authoritative interactive-turn boundary even when it names work left
running: later background bytes are not silently folded into this turn or the next. Other
lifecycle hooks remain immediate. The
later entering-working notification consumes the prepared edge instead of capturing again;
an entering-working notification that arrives while preparation is still running consumes the
in-flight edge as well, so terminal repaint inference cannot start a later second capture;
an inferred terminal with hooks disabled still has the old entering-working path as a
best-effort fallback. Answering an agent question from `awaitingUser` resumes the existing
turn and keeps its original start. Captures run concurrently on their own queue, so neither
an open megabyte diff nor another session's slow checkout can delay turn admission. Starting a
capture always creates a new stable checkpoint identity; a failed capture records an explicit
unavailable turn rather than silently showing an older one. A transition left at
`capturingBefore`, `inProgress`, or `capturingAfter` across launch becomes **incomplete**, never
complete by inference. Likewise, a reporting provider process that exits without its authoritative
finish hook marks the active record incomplete; only non-reporting terminals retain the inferred
idle-edge final capture as their necessarily best-effort fallback.

The ref makes the objects durable; `git-turn-checkpoints.json` makes their ownership and meaning
durable. Each record connects project, logical and execution checkouts, repository and worktree
identities, session, ordinal, stable native/provider turn ids, both refs and hashes, capture status,
failure and timestamps. Reading proves that the current checkout has the recorded repository
identity, each exact ref still exists, and it still resolves to the recorded tree. A missing or
replaced ref is an explicit unavailable checkpoint — the loose object hash is not accepted as a
fallback. Any current checkout of the same repository can read the pair, which is why a managed
worktree's history remains readable through the logical checkout after disposal.

Ref publication and collection are serialized per repository identity, not globally: two sessions
sharing a repository have ordered ref transactions, while unrelated repositories never wait on one
another. Retention keeps 50 records per session and 1,000 total. Overflow and permanent deletion
remove exact recorded refs first and metadata after successful removal; an unavailable repository
keeps the cleanup record so it is retryable. Archive/Restore retain both because the owning session
still exists. Only permanent session/project deletion collects them. Normal startup also enumerates
the private namespace in every reachable catalog repository and removes well-formed app refs that
no metadata record owns. That reconciliation is what keeps retention bounded after metadata
quarantine or an exit between the two halves of collection; it cannot name a branch, tag, remote,
or any ref outside the private prefix.

Rendering shares the `NativeDiffCore` model with edit tools, but not their view-tree shape.
`DiffView` still gives a short conversation edit one AppKit row per line. Git Review uses
`GitReviewDiffTextView`: one selectable TextKit document per hunk, with the same syntax roles,
wrapping and exact per-line context anchors. Change washes are a cached vertical display list:
TextKit fragments are merged into contiguous added/removed runs when width changes, and drawing
binary-searches to the visible runs. Per-paragraph backgrounds made TextKit recompute wash geometry
while scrolling. The washes are also frozen colours derived from the surface underneath, so a
virtual row resolves them inside its own effective appearance and resolves them again when it joins
a window or that appearance changes; ambient drawing state during row construction must never be
cached into the document. This distinction is load-bearing — 400 line views are acceptable nowhere
in a disclosure that must change height synchronously.

`GitReviewFileRow` is `ToolCallView`'s collapse pattern per file, and **bodies build only when a
virtual table row is materialized**. In both views **the open body is excluded from the
header's click-to-toggle** (each one's `NSGestureRecognizerDelegate`): the body is selectable
text carrying its own per-line context actions, and a click that placed a caret used to *also*
collapse the card — hundreds of points of table re-laid themselves and the pane leapt under the
pointer, reported as "clicking a line moves the whole window". Only the header row toggles. Text files start expanded, so the first visible file is ready
to read; an expanded offscreen file is only model state and constructs no text surface. Image
comparisons retain explicit disclosure because opening one fetches and decodes two endpoint blobs.
A manual close is an `expansionOverride` and survives watched refreshes. The mode persists with the tab
(`PersistedTab.mode`); restore builds the controller but runs no git until the tab is actually
shown, the browser's deferred-load rule.

The collapsed body rule does **not** by itself make the file index cheap. Measurement showed
`NSStackView` eagerly laying out 1,000 collapsed headers took about 94 seconds. Progressive
20-row materialization reduced the first viewport to about 29 ms, but a deep walk still became
superlinear because every appended header remained in the stack.

File comparisons now use a **reusable `ThemedTableView`**. The complete file model is available
for immediate scrolling, while only viewport rows are constructed: the 1,000-file Debug fixture
creates 14 rows initially and 28 total after a direct jump to the end. That run opens in about
19 ms and the deep jump takes about 18 ms. A watched redraw preserves expansion overrides and
anchors the first visible **file path plus its within-row offset**, not the old document pixel:
generated files inserted above the viewport therefore move the row without moving the reader.
The existing table and unchanged visible TextKit rows survive a refresh. Only inserted/removed
path identities are reconciled, and only materialized or exactly measured paths are deep-compared;
offscreen rows have no view to reload and read the replacement model when they eventually mount.
The table does not use AppKit automatic heights for file rows: that path
double-counted a large `NSTextView` during its first fitting pass and retained a 12,082pt row for
a 6,082pt card. Offscreen rows use cheap width-aware model estimates (line count, wrapping and
hunk headers); a materialized row replaces its estimate with exact TextKit height keyed by width.
This both preserves virtualization and keeps the scrollbar stable before the last viewport. Pane
resize invalidates all estimates together while visible rows remeasure.

Two operations are prohibited during `NSScrollView`'s live-scroll transaction. A checkout result
coalesces to the newest phase and applies after momentum ends, and deferred exact-height reports
are ignored until the resting viewport is known. Mutating table rows or calling
`noteHeightOfRows` between momentum events made the pane appear to steal the wheel even when the
individual operation was not a long hang. The end notification applies the newest model first,
then measures only the rows that survived into the resting viewport.
The table's sole column is fitted by `SoleColumnFitting` on the list itself, not by this pane;
an autoresizing column does not otherwise follow the clip width, which left full-pane rows
drawing as narrow intrinsic cards. **It was fitted here, from `viewDidLayout`, and that is the
one place it cannot be.** The pane is laid out while git is still reading, and
`documentView = fileTableView` arrives afterwards — a document-view swap deep inside a scroll
view lays out no controller root, so `viewDidLayout` never ran again and the column kept
`NSTableColumn`'s 100pt default. Every file card was 76pt wide in a 900pt pane, wrapping source
three characters to a line, with no constraint broken and nothing logged. See the design-system
note of 2026-08-06 for why the repair belongs to the list.

**The table is `.plain`, and the pane owns its only margin.** `NSTableView.Style.automatic`
resolves to `.inset` here, which keeps 16pt at each side of a row and 10pt above the first one.
Added to the pane's own inset that put every file card 40pt in while the header's mode chip
started at 12, so the diff read as a column floating inside a wider one. `.plain` with no
intercell width hands the row the table's full width, leaving `GitReviewVirtualRowHost` to state
the single inset — the same `Spacing.inset` the stack path gives its commit rows. It is also why
"is the column as wide as the table yet?" is the wrong test for whether a fit is still owed:
under `.inset` the column can never equal the table's width, so that guard never holds and every
layout pass re-fits. `SoleColumnFitting` keys on the *list's* width instead.

**The gap between cards hangs under each one, not around all of them.** `intercellSpacing` is
`.zero` and the host insets its content at the bottom instead, because AppKit splits the
intercell height: half above every row *including the first*, which put the top of the list 3pt
below the margin the sides were on. The vertical rhythm is `Spacing.inset` from the tab strip to
the chip, `Spacing.inset` from the chip to the first card, `Spacing.small` between cards.

The header sits on that margin at both ends: the chip's pill is its own ink, and the `···`
is pulled out by its `opticalHorizontalInset` so the glyph — not the hover surface around it —
lands where the cards end. Back does the same on the leading side when a commit is open, which
is why its visibility goes through `setBackVisible(_:)` rather than `isHidden` directly.
`GitReviewViewTests` holds all of it — chip, cards, overflow, and both gaps — to one measure.
The diff totals beside the chip use the same locale-aware compact notation as the status card;
their tooltip retains the exact grouped values, and their accessibility label speaks the exact
file, addition, and deletion totals. There is no second totals pill over the bottom of the diff:
only the shared down-arrow appears while the reader is away from its end.
The fixture and the `git.read.*`, `git.process`, `git.review.render`, and
`git.review.render-files` spans are documented in [`performance.md`](performance.md).

The publish strip follows the same ownership rule one level down: its repository copy is the
leading run and its policy chooser, open action, and next transition are the trailing run of one
`ControlRowView`. The row owns their height and optical centreline across themes. A repository
state with no transition — **Default branch**, **Branch pushed**, or an unavailable provider — is
copy, not a disabled primary button. The distinction is semantic and visible: hard-print themes
remove a disabled button's action depth while a live chooser keeps its shadow, so presenting a
fact as a button put neighbouring surfaces on two different elevation rules.
The strip also owns a pane inset below it while visible. When collapsed, its zero-height bottom
already marks the ordinary chip-to-list inset; keeping a permanent second inset would double that
gap, while omitting the conditional one joins the visible strip and the first file card into one
slab.

A file row's **right-click opens it in an editor at the first line the diff changes** — the
primary click still belongs to the row's own job, opening and closing the body. This is the
only surface in the app that knows which line the reader is looking at, which is what makes it
worth the wiring; the pane resolves the absolute path (a diff carries only a checkout-relative
one) and the row picks the line. See [`external-apps.md`](external-apps.md) for why it is the
*new* numbering, and why a file this comparison deletes offers no menu at all.

**Staging is offered by two modes of six**, and the rule is not a UI preference: a patch
applies to the index only when the index is what the diff was measured *from*. Unstaged
(index → worktree) stages hunks, Staged (HEAD → index) unstages them by applying the same
patch `--reverse`, and Uncommitted (HEAD → worktree) can speak about whole files but not
hunks — its hunk offsets describe a baseline the index may already have moved past. Branch,
Last Turn and Commit compare things that are not the index at all. `GitStaging.capability(for:)`
holds it in one place; `GitPatch` rebuilds a one-hunk patch from the parsed model, since the
pane no longer has the bytes, and passes `\ No newline at end of file` through unprefixed —
dropping it silently re-adds a newline the file never had.

**The composer can draft its own message** (`CommitMessageComposer`, the sparkle beside the
field): one read-only sandboxed `codex exec` one-shot on the default account —
`ProjectIconResearch`'s pattern, including its gates: manual only, because the run spends
the user's usage; offered only where a Codex login exists; one run per repository at a time.
The staged diff is fetched fresh at click (what is staged is what will be committed), capped,
and travels with the ten newest commit subjects so the draft matches the repository's own
voice rather than a generic convention — a `feat:` prefix in a repo of plain sentences is a
wrong answer even when it is a good message. `GitReviewCommands.recentSubjects` exists
because `log()` always pays for `--numstat` and a hundred-commit page, rightly for the
history browser and wastefully for a voice sample. Busy-ness lives on the controller like
the message itself — the composer row is rebuilt on every re-read. Failures land in the
pane's own notice line, never an alert.

Reads and writes share `GitProcess`, which is where the pipe handling, the timeout and the
oversized-output guard live; the writes drop `--no-optional-locks`, because a write needs the
lock it is about to take. Losing that lock to the agent's own git is its own failure case
(`GitFailure.indexLocked`) rather than a generic error: the answer is to try again, not to
fix anything. The commit composer is a `PromptView`, and the message lives on the controller
rather than in it — staging re-reads the pane, which rebuilds the composer, so a message kept
in the view would be lost with every stage.

The tab **watches the checkout** (`GitCheckoutWatcher`, FSEvents) rather than polling. Two
paths are watched, since a linked worktree's `index` and `HEAD` live in
`<repo>/.git/worktrees/<name>` and its refs in `<repo>/.git/refs` — neither under the checkout.
`GitWatchFilter` is where the traps are and is pure, so they are tested: nearly everything a
git command writes is its own bookkeeping, `.lock` files are git announcing a write rather
than making one, and only `index`, `HEAD`, `refs/` and their kin mean the diff changed. This
is also the second reason `--no-optional-locks` matters: without it a read would refresh the
index, the watcher would see it, and the pane would re-read itself forever.

Teardown follows FSEvents' required order: stop, invalidate, release. `Stop` synchronously
prevents another callback and `Invalidate` removes the dispatch-queue schedule. Clearing the
queue explicitly before invalidating is not an extra safety step — the framework documents
that state as an error, and it has crashed inside FSEvents while releasing a long-lived stream.

The selected session's **floating status card** is fed by `GitChangeMonitor`, a smaller
read-side coordinator over that same watcher. It serializes summary reads and remembers one
trailing refresh when a new write lands mid-read, so a burst always ends on a reading taken
after its last write. Idle, the card says branch, changed files and `+N −M`. While a **native
conversation's** turn is active it keeps that exact monitor alive and promotes the first line to
the structured plan position when one is available. The totals are still the checkout's
uncommitted totals — not a count inferred from Edit tools — and clicking either Git presentation
opens Git Review. When the session has children, a separately clickable working/done segment
joins the card and opens the Subagents display-pane tab. It remains visible even when there is
no Git sentence to show, making the surface a session status card rather than forcing child
navigation back into the conversation.

**The terminal owns the ground around the card; the active app theme owns the card itself.** It
is an opaque rectangular interpretation of `AppTheme.Material.PopoverStyle`, resolved by
`ThemedFloatingSurfaceChrome`: the same surface role, edge or bevel, depth, density, and semantic
glyph family as a popover, without an anchor arrow. System keeps the modern card; Windows 98 gets
the pale square infotip surface with a dark flat edge, no ambient shadow, compact spacing, and
one-bit branch/change/model marks; the other period themes recover their authored hard bevels;
Neo Brutalism and Claymorphism recover their material shadow construction. The content uses
the theme's chrome ink on that opaque fill, while added and removed totals keep their semantic
hues through `Design.Diff.on(fill)`. A terminal palette can therefore colour everything around
the card without leaking through it or turning application chrome into a terminal-native widget.

**The monitor's first read also drives a sidebar spinner, and its lower is delivered to the
session it was raised for — never to whoever is on screen.** The raise (`.gitStatus` in
`SessionLoadingState`) used to be lowered only by `onInitialReadComplete`, guarded on the
session still being current; but the completion holds the monitor weakly and the monitor dies
with the selection, so switching sessions before the first read of a big checkout landed left
the abandoned row's spinner raised for the rest of the app's life. Diagnosed as "ghost
activity": the row draws the same orb for *loading* as for *working*, so a leaked raise reads
as an agent forever busy in a chat where nothing is happening. Now `updateGitChangeMonitor`
lowers the previous session's raise as part of tearing its monitor down, the completion lowers
unconditionally, and `SessionLoadingState.lowerExpired` sits under all of it as a sweep
(`SessionLoadingDefaults.maxHold`) that ends any raise nobody lowered and journals whose it
was — an expiry taken is a raiser that leaked, and the log line is its only trace.

**The pointer lights the rows that act, and only those.** The card carries three destinations and
two facts — Git Review, the Subagents tab, the sharing pane, the agent line, and any extension row
— and for all of them the answer to the pointer was the same: the whole view lifted from 85% to
full. That lift is the card waking up and it stays, but it said "all of this is clickable" about a
card most of which is not, and the pointing hand over the *whole* card said it a second time, on a
card holding no Git sentence at all where a click did nothing. The Git rows now raise a wash
(`ink.surfaceHover`, the weight the children row already lifts to) under the words that open Git
Review — **one rect, under the row the pointer is on**. Drawn as one union the branch and the
counters read as one *fact*, and they are two; each wash hugs its own line (`washRect(for:)`),
with less growth than the button convention exactly where the two rects would otherwise fuse
across the gap they share. Both rows lit together at first, on the reasoning that they are one
destination — but a hover answers *where the pointer is*, and the destination is what the click
is for; lighting the counters because the pointer is on the branch reports a pointer that is not
there. So the hover state is the row (`hoveredGitRow`), not a flag. The click and the cursor
rect stay on the union (`gitRegion`) so the gap between the rows is not a dead zone — a hover
promising a destination the click does not deliver is worse than no hover, and the reverse is
too. That union being larger than the two rows put together is why the wash falls back to the
nearest row: the gap, the padding grown past it, and the ground beside whichever row is the
shorter word all click through, so all of them light something. The two button rows lift themselves, as controls always did; the audience row
was being handed neither `contentTintColor` nor `hoverFill`, so it drew in AppKit's own label tier
and lifted to nothing — inert by omission rather than by design. The card also answers
`accessibilityPerformPress` now: it has called itself a button since it first carried a receipt,
and a button that cannot be pressed is a label wearing the wrong role.

**The card can be switched off, and withdraws on its own when the pane is too narrow for it.**
It floats *over* the terminal rather than beside it, so what it costs is the text underneath —
a corner at a comfortable width, a lid on a pane dragged narrow. Two answers decide whether it
is on screen and they are deliberately separate: `hasContent` (any row survived the last
rebuild) and `isAllowedOnScreen` (the user's switch, and whether there is room). Only the second
animates — a card with no branch is absent because there is nothing to show, which nobody
watches; a card the user dismissed is a transition they asked for.

The room test is `GitStatusOverlayDefaults.maximumPaneShare`: the card withdraws when it would
take more than **half** the pane. A share rather than a minimum width, because the card's width
*is* the branch name's — a long name on a middling pane is exactly as tight as a short name on a
narrow one, and one rule answers both. It is measured against the card's `fittingSize`, not its
frame: a withdrawn card has been laid out at that size all along, and asking the frame makes the
answer depend on itself — the card returns, which makes it wide, which sends it away again.
`TerminalContainerViewController.viewDidLayout` is the single place both halves are re-asked,
because a layout pass is what a divider drag and a rename of the branch have in common.

The switch is `StatusCardVisibility`, through `PreferenceStore` for the same reason
`DisplayPaneWidth` is, and it is read as an *optional* — absent has to mean on, and
`bool(forKey:)` cannot tell "switched off" from "never asked". The header button reflects the
**standing choice** rather than what is on screen, so a card withdrawn for width still reads as
on: the button says what the next press does, and a press on a narrow pane cannot be answered by
showing a card there is no room for. The button sits in the session-actions group beside Shell
and Panel — it belongs to the *pane*, not the window, so it is not an `NSToolbar` item; see
[`window-chrome.md`](window-chrome.md).

The transition is a fade plus one step of lift toward the edge the card hangs from
(`Motion.appear` / `Motion.vanish`, eased out arriving and in leaving). Both are needed: alpha
alone over live terminal text reads as the text brightening rather than as a card leaving,
because what arrives underneath is moving too. The lift is a **layer transform**, not the
constraint that positions it — the card's place in the pane is the same place while it is away,
and an animated constraint would be a second opinion about it that outlives the fade. A
generation counter guards the completion: toggling twice inside `Motion.vanish` otherwise let a
stale completion hide a card that had since been asked back.

**Every row is one height, and the card states it.** `rowPadding` is the air a row keeps around
its own words; `rowHeight` is `textRowHeight + rowPadding * 2`; the hover wash paints exactly
that, and the two button rows are **constrained** to it. Before, nobody stated it and the card
had two rhythms: a text row's line box is 15pt, a plain `ThemedButton` pads itself to 22, and the
wash grew by whatever `rowGap` had left over — which was 2. So the lit row came out 19pt, *shorter
than the control sitting under it*, and read as shrink-wrap on the text rather than as a row
lighting up. `childrenRowInset` is now `rowPadding` rather than a measurement taken off
`intrinsicContentSize`: asking the control what height it chose was asking the wrong party, and
its answer became the number the card had to work around.

`rowGap` follows from that rather than being picked: it has to carry two neighbouring washes
**and** the hairline that keeps them from fusing, so it is at least `rowPadding * 2 + hairline`.
At `small` it could not, which is why the wash was clamped — the gap was setting the padding,
backwards. The `min` in `washRect(for:)` is the guard that says so out loud, not the rule.

**The card's rows are set at the control size**, `numericControl(weight: .medium)` — one role for
branch, counters, agent line and both button rows, so the stack holds one line box and one column.
It was the detail size, which reads as a footnote *about* the pane rather than as the pane's own
status, on a surface floating over a terminal at whatever size the user set that to. Moving it also
turned `GitStatusOverlayDefaults.height` from a literal 26 into `verticalInset * 2 + textRowHeight`:
26 was an 11-point line plus its insets, so it was already out for anyone running the app's text
scale above 100%, and it feeds the pill radius.

**The card draws no spinner.** It used to promote its first line with a working orb, and that
orb was the third one on screen: a terminal session's CLI draws its own a few lines below, and
a native conversation animates one beside its status. It was also the only one sitting on the
*terminal's* palette rather than the app's, so its accent was a colour the theme never chose —
which reads as a stray mark rather than as a state. The plan position is the promotion now, and
the row's mark changes with it (`checklist` for a plan, the branch mark otherwise), which is the
job the orb was doing badly. `AppSettings.workingOrbStyle` still drives the conversation's orb.

**Every row leads with a mark, and the marks share one column.** Three readings stacked at the
same left margin read as three sentences; the same three with `⑂`, `±` and the children mark in
one column read as a list. The column is the slot a titled `ThemedButton` draws its own symbol
in (`ThemedButton.markSlotWidth`), because one of the rows *is* one — the children line — so the
text rows carry that button's `opticalHorizontalInset` as a stack edge inset rather than as a
constraint. Insetting the frames instead of pulling the button outward is deliberate: a control
hanging outside its parent's bounds is unclickable along the overhang, which would have made the
children row's own mark a dead strip. The counters line reads left to right like every other
row: the file count, then `+N −M` a `Spacing.medium` step after it. The totals used to be held
to the card's trailing edge by a flexible spacer, on the theory that a list wants two columns —
but the card is only as wide as its longest row, so on a long branch name that spacer opened a
hole halfway across the counters line and nowhere else, and a lone right-aligned reading has
nothing above or below it to line up with.

The **file count is no longer run-only**. It used to appear as "N files changed" during a turn
and vanish when the turn ended; it is now the label the counters row wants beside its totals in
both states, which is one presentation to learn instead of two.

**One row per fact**, stacked. The card is pinned to the pane's trailing edge under a
360-point ceiling, and every fact that joined the line took its width from the branch name —
which truncates in the middle, so a busy run ate the one thing that says which checkout this
is. Each fact now keeps the full width and the card grows downward instead, the direction it
has room in and the one its extension slot already grew in. On a **detached head** there is no
first line to draw, so the counters row leads with its own mark — the reason each row owning a
mark is worth the column it costs. The **agent line** can lead too (a detached head with a clean
tree), and so can the children row.

**The card is padded, not banded, and that is a fix.** Its rows sit at their own heights with
`verticalInset` above the first and below the last and `rowGap` between each pair; one line of
the card's own type inset top and bottom *is* the pill, so a one-row card is the same shape
whichever of the four rows is the one showing. It used to centre whichever row led in a 26-point
band and leave the rest bare in a stack spaced at zero, which meant the gap under the leading row
was that band's own half-padding and every gap below it was nothing: a card showing branch,
counters and agent line came out 6 / 0 / 0, the branch floating alone with the other two stuck
together underneath. The band also had to *move* — to the counters row on a detached head, to the
agent line on a clean one — three special cases for a padding the card can simply have.

The measures have been stepped up once since: `tight` gaps inside `small` insets fixed the
rhythm and still read as text pressed against the card's own border — called "too tight
vertically" twice in review — so the card now sits on `small` gaps inside `medium` insets, the
gap still inside the inset so the rows read as a list in a card. The single-row pill grows with
it, deliberately: one geometry whatever the row count is the rule the padding replaced the band
to get.

The children row is the one row that pads itself, because it is a `ThemedButton` sized around a
hit target rather than a line of text. Wherever it meets an inset or a gap, that inset or gap
gives its padding back (`childrenRowInset`), so what the reader sees lands on the same rhythm as
every other row instead of a step below it.

**The agent line says which agent is working this checkout, and how.** It carries the model, and
where they are knowable the permission mode, the effort and the Fast state, under the checkout rows
and above the children — the rows reading outward from what the pane *is*: which branch, what
changed in it, which agent is working it, who it delegated to. Within the row the order is the
composer's own — model, then posture, then how it thinks, then how fast — so one fact keeps one
place wherever it is shown. It reuses the `cpu` mark the composer and the conversation's status row
already give the model chip, so one fact keeps one mark too.

**Fast mode is a bolt, not a word, and only when it is on.** The row ends on `speedMark` — the same
`bolt.fill` the composer's speed chip carries — set in the qualifiers' `tertiary` weight so it does
not read as a warning. The word "Fast" spent a sixth of a 360-point row saying what the symbol says
at a glance; standard speed draws nothing at all, because it is what every session runs at unless
something says otherwise and a dimmed or crossed-out bolt would be a second state to learn. The
spoken label keeps the word, in the bolt's place at the end of the phrase: a symbol read aloud is a
fact lost rather than a fact shortened. Under a period theme the bolt is the hand-drawn one-bit
`ClassicGlyph.speed` rather than an SF Symbol, like every other mark on the card. Moving speed last
also settled a disagreement the fixtures had been carrying: the row claimed the composer's order
while putting speed between posture and effort, which no runtime could reach and so nothing on
screen contradicted.

Which facts belong to the card is decided *before* it. A **native conversation** gets none: its
status row already carries model, effort and speed as chips directly above the composer, so the
card would say them twice in one view — the same rule the run spinner follows. A **terminal
session** gets everything the pane can extract, whether or not its own status line already prints
one of them. It used to get only what the line left out, which `ClaudeStatusLineCoverage` answered
by running the account's command and matching values Threading already held; that probe is gone
and [`session-activity.md`](session-activity.md) records why. The short version: it spent a
subprocess and a cache per session switch to avoid a fact appearing twice in one pane, and its
only failure direction was hiding a fact the user had asked to see. Duplication is the cheap
outcome; a missing model is not. `GitStatusOverlayView.ModelReading` is still handed the decision
rather than asked to make one — a nil field means "do not say this", not "unknown" — which keeps a
runtime-specific rule out of a Git-shaped view and lets each part drop independently.

**The permission mode is the one fact taken only from observation.** Nothing in the app used to
show it at all: the session's `⋯` menu and Settings ▸ General state what the *next* launch will
ask for, the native composer's chip belongs to a surface a terminal does not have, and a terminal
posture the user Shift+Tabbed into was invisible to Threading entirely. Claude writes each
assertion of it into the session's transcript, so the card reads it back through
`ObservedPermissionMode` — the provider-neutral seam, gated on
`AgentCapabilities.transcriptPermissionModeRecord`, which Claude alone claims. The launch record is
deliberately **not** a fallback: Bypass Permissions shown from a flag the user has since cycled out
of is a promise the app cannot keep, so an unobservable runtime, an unreadable transcript and a
session that has not started all show no posture rather than a stale one. All six modes show,
Manual included, because a posture that is only ever drawn when it is unusual is one nobody learns
to look for.

It is also the one fact no status line could ever carry, which is measured rather than assumed:
the CLI's own payload builder in 2.1.222 spreads `model`, `workspace`, `output_style`, `cost`,
`context_window`, `exceeds_200k_tokens`, `fast_mode`, `effort`, `thinking`, `rate_limits`, `vim`,
`agent`, `remote`, `pr` and `worktree` into the document a status line reads, and no posture — a
command cannot print what it was never handed. Claude's TUI does draw the posture in its own
footer for three of the modes (`accept edits on`, `plan mode on`, `auto mode on`, with the default
posture labelled with an empty string), which the card repeats knowingly: the modes the footer
stays silent about are the ones worth saying most.

One fact is withheld rather than guessed. **Fast mode is a reading only where Threading sets
it** — `appendCodexConversationOverrides` is Codex-only, and Claude's fast-mode state belongs to
its print transport (`AgentModels.defaultFastMode` returns nil for Claude and says why) — so a
Claude *terminal* session draws no bolt whatever its CLI is doing, which is the honest answer
rather than a guess with a symbol on it. **Effort for a Claude terminal session is its
explicit opening choice, then the account's configured value**; the former is pinned with
`--effort`, while either reading goes stale the moment the user types `/effort`. It is shown
anyway: it is the best answer this surface has, and a blank where the effort belongs is not more
truthful than a stale one. The transcript records what each turn actually ran at and is the
authoritative source where a conversation is being replayed — see
[`native-conversations.md`](native-conversations.md).

**The model has a third source, and it is the transcript.** The two configuration sources both
describe what was *chosen*: `session.model` is what the user pinned in the composer, and
`AgentModels.defaultModel` reads `"model"` from the account's `settings.json`. A login that
leaves the choice to the CLI sets neither — `~/.claude-vlundborg/settings.json` here carries
`effortLevel` and no `model` — and Claude then resolves its own default from a layer this app
does not read, so the card sat beside a session visibly running Opus 5 and could say only "Extra
High". `ClaudeTranscriptModel` reads the newest `message.model` back out of the session's own
transcript, which observed rather than configured and is the only one of the three that moves
when the user types `/model`.

Three properties make that affordable, and each is a cost it would otherwise have. The scan runs
**backwards and capped** (`JSONLReader.forEachRecordFromEnd`): the model is on assistant records
and a transcript ends on whatever the last tool wrote, so the answer is near the end and almost
never on the last line — `lastRecord`'s answer — while reading forwards would walk a whole
conversation to reach its end. It **never touches the disk on the main thread**: `known(at:)`
answers from memory so the card paints on selection, and even the size check that decides whether
to re-read happens on the background queue. And it **calls back only on a change**, because
`ProjectsDidChange` fires for the terminal titles agents rewrite constantly, and a completion per
event would redraw the card for an answer that had not moved. A tail made of nothing but tool
output answers nothing rather than reading a 250 MB file — duplicating a fact is the safe
direction for a guess here, but inventing one is not.

One consequence worth stating: a session in a **non-git folder** now shows a card where it
previously showed none, because the model is a fact the pane has even when the checkout is not
one. The card was already a session status card rather than a Git one — children alone have kept
it on screen since the subagent receipt joined it.

**Drawn counts are abbreviated**, `+4.2K`, in the reader's own notation — the same
`.compactName` the Git Review header uses for the same diff, so the two surfaces agree. The
accessibility label keeps the exact counts, joined by the separator the eye
sees as a line break: an abbreviation read aloud is a number lost rather than a number
shortened. The file count itself stays exact in both places; it is small enough to read at a
glance and it carries the plural of the noun beside it.

A row's mark sits closer to its words than the counters row's two readings sit to each other, so
it reads as belonging to them rather than as an item of its own — and it sits on the
same optical line, which took a fix in the label helper rather than in the card (see
`design-system.md`). The test that pins that pair measures the ink in the card's top 26 points
held clear of its border: at eight samples per point the border's antialiased skirt is ink
too, and the range it used to measure ran to the card's own edges — so both ranges were pinned
to the border and the assertion compared the card's edges with themselves.

The gaps themselves are pinned by a test of their own, on the laid-out frames rather than on the
ink: the rows share one font and therefore one line box, so equal frame gaps are equal gaps
between the words. The children row is measured back down to that line box first, since its frame
is deliberately taller.

The card is also an **extension surface**: `session.corner-card@1` exposes one display-only
slot whose ID is the placement — `top-trailing` today, `top-leading` reserved for a future
leading card — deliberately named after the corner rather than after git, since the card may
carry more than the checkout's reading one day. Extension rows render below the card's own
rows and it grows downward for them too; with the slot empty the collapsed constraint
reproduces the native geometry exactly, which is what keeps the render tests honest. Rows ride
the card's own visibility, share the contents' resting alpha and hover lift, and stay
display-only. Built-in Git and Subagents segments may have distinct destinations, but an
extension row still cannot add a competing control. The contract's reasoning lives with the
extension docs
(`docs/extensions/CUSTOMIZATION_SURFACE_AUDIT.md`).

A **terminal** session never gets that second presentation, though its activity is known: the CLI
draws its own spinner and working word a few lines below the card, so an orb and "Working…" in the
corner were the same sentence twice in one view. There the card stays the branch card for the
whole run, saying the one thing the terminal does not — the checkout's live totals.

The card **occludes**, which took two corrections. It sits at the pane's top-right corner over
whatever the pane is showing, and under a native conversation that is text rather than the empty
top of a terminal: at the old backdrop-derived surface's 14%, with the view itself at 85% for
"quiet at rest", a long branch name and a line of the agent's answer were legible through each
other. The theme-owned surface role is now flattened against the theme ground before it reaches
the layer, and the resting quiet belongs only to the card's contents. Pinned by
`ThemedIndicatorsTests.testTheGitCardUsesOpaqueThemeChromeAboveThePane`.

Auto-refresh forced two things that manual refresh never did. **The reader's place is kept** —
the scroll offset survives a reload of the same surface (a mode switch or an opened commit is
a different page and starts at the top), and `expansionOverrides` records what the user opened
or closed by hand so a re-read does not close what is being read. And a paged-into history or
an opened commit **does not follow the checkout** at all (`followsCheckout`): both are
immutable or append-only, so re-reading them costs the reader their place for nothing.

**Diffs are syntax highlighted** by `Syntax`, a hand-written lexer with a table of languages
(`SyntaxLanguages`) — the same reasoning as `Markdown`: a diff row needs a string told from a
comment, not a grammar, and the project depends only on SwiftTerm. An unknown extension
renders plain rather than guessed at, because a wrong guess colours half a line and reads as a
bug in the diff. State is carried down the **two sides separately**, since a diff interleaves
two versions of a file and one running state would let a `/*` deleted from the old side comment
out the new side. `Design.Syntax` has four hues and a dimming, and deliberately no red or
green: both already mean removed and added here, and a red string literal inside a green added
line says two contradictory things at once. Highlighting also changes the *base* colour —
highlighted code is label-coloured and leaves the wash and the gutter to say what happened to
the line — which is per view, not per row, so one file never mixes the two conventions. The
tool rows and permission cards feed the same `DiffView` with the path they are editing, so an
edit in a conversation is highlighted by the same table.

**The history draws a graph** (`GitCommitGraph`, `GitGraphRailView`). Lanes are assigned from
`%P` rather than by parsing `git log --graph`'s ASCII art, which is drawn for a fixed-width
terminal — reading pixels back out of it to draw them again is a lossy round trip through
someone else's renderer. A lane is a slot waiting for a particular commit: a commit takes the
lane waiting for it, its first parent inherits that lane, and every further parent opens a new
one, which is why a merge fans out downward and a branch converges upward. Free lanes are
reused leftmost so the graph stays narrow, and lanes waiting for parents beyond the page run
off the bottom honestly. The commit rows lost their fill and gained a hover to make room for
it: a rail broken once per row reads as a history that stops and restarts, so the list closes
its gaps, and a hundred filled slabs was the tool-row problem again anyway.

**An image change opens into a comparison, not a "binary" dead end.** A binary row whose path
says raster image (`GitReviewFileRow.rasterImageExtensions` — SVG stays out on purpose: it is
text, and its diff says more than a render of it would) becomes expandable, its meta reads
"image" instead of "binary", and its body is the design system's `ImageCompareView` (wipe,
fade, difference, side by side). The bytes come from `GitReviewReader.endpointFilePair`, which
states each mode's two endpoints as addresses one file can be read from — the same pairs the
diff commands imply: HEAD→worktree, index→worktree, HEAD→index, merge-base→worktree,
turn-start→turn-end, `commit^`→`commit` — and titles the sides accordingly, so the captions
beside the image say *which* two things are compared. A side git does not hold comes back nil rather
than failing the pair: that is what added, deleted and untracked look like, and half a pair is
still worth showing. Two accepted gaps, both from the parser's binary collapse
(`UnifiedDiffParser` checks `isBinary` first, so a binary add/delete/rename loses its mode
lines): a renamed binary presents as added, and added-vs-deleted cannot be told apart from
`change` alone. Blob reads follow `repositoryFile`'s containment discipline (symlinks resolved,
root prefix proved) without its ls-files membership check — these paths come from git's own
diff output. Fetches happen on first expand only, the same lazy rule as the text bodies, and an
image row never auto-expands: its line count is zero, and the auto-expand budget is a line
budget. Untracked images matter twice here — most screenshots exceed the 256 KB synthesis cap,
so they arrive as `.untracked` with no hunks rather than as sniffed `.binary`, and the row
treats both the same.

`NSTextField.label(attributed:)` exists because of a bug this work surfaced: a field created
empty measures itself empty, and assigning `attributedStringValue` afterwards changes what is
drawn without changing what was measured — so every `+N −M` counter in the pane was laying out
four points wide and drawing nothing. Assigning attributed text also turns wrapping back on,
and a wrapping field has no intrinsic *width* at all, which is what let Auto Layout squash it.
`GitReviewRenderTests` is what found it: the same fixture-to-PNG idea as the conversation
renders, for the same reason — a claim about colour on a coloured wash cannot be checked by
reading assertions about token ranges.
