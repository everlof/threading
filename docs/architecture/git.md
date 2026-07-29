# Git Layouts and Git Review

Reading git metadata off disk, and the per-session review pane.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

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
different branches simultaneously. It is re-read when a session stops working, which is when
an agent is most likely to have just switched, rather than by polling.

The composer's branch chip therefore offers **checkouts, not branches**
(`ProjectStore.siblingCheckouts(of:)`): this checkout, any other added checkout of the same
repository, then `New Worktree…`. It listed the repository's whole `git branch` output once,
which invited picking a branch nothing was standing on — the session then ran in the origin
checkout anyway while its record claimed the branch that was asked for. A branch with no
checkout is not a place a session can run; making one is what the worktree item is for.

That item lives *in the menu* rather than in a chip of its own, where it read as a state —
one of the selected choices in the row — when it is an action. One control, one question:
which checkout does this session run in.

A *session*, though, carries its own branch record (`AgentSession.branch`): captured at
creation, re-read by `ProjectStore.refreshBranch` at the same stopped-working moment, and —
by default — **followed while dormant**. The record froze while dormant once, on the argument
that a conversation happened on whatever was checked out at the time; in practice the frozen
answer misled about the thing the sidebar is for — a dormant session *resumes* onto whatever
its checkout is on now, and after a switch in another session the chat sat grouped under a
branch it would never run on again. `CheckoutBranchFollower` is the following: one
branch-scoped `GitCheckoutWatcher` per unique checkout (keyed by `worktreeIdentity`, watching
only the worktree's own `HEAD`, so builds and agent edits never wake it), applying a switch to
every session standing in that checkout via `ProjectStore.refreshBranches(forCheckoutAt:)` —
whether the mover was another session, the shell drawer, or a terminal outside Skalman.
A detached reading is never applied on this path: a rebase detaches `HEAD` for seconds at a
time, and clearing every record for the flicker would regroup the sidebar twice per rebase; a
genuine detachment still lands per session at its own stopped-working moment. **Settings >
General > "Follow the checkout's branch"** turns the following off and restores the frozen
record, for whoever wants the sidebar to say where a conversation *happened* rather than
where it would resume. The record drives the sidebar's **branch grouping**
(`SidebarTreeBuilder`, `BranchGroupNode`): inside a project, sessions sharing a branch gather
under a heading — the earns-its-level rule as repository grouping, applied one level down —
and once *any* branch has earned the level, lone branches earn headings too
(`AppSettings.groupsLoneBranches`, on by default). The base rule alone left a **mixed tree**:
a heading over the shared branch, and beside it a bare row whose different branch was
invisible without the hover popover — found by switching a live chat to a fresh branch and
watching it merely *leave* the master group. All-or-nothing labelling fixes that reading
while keeping the flat layout for a project with no shared branch at all, so the common
one-branch-per-chat project still pays no level per row; with the refinement off, the
original more-than-one rule stands alone. Sessions with no recorded branch always stay
directly under the project, and a group takes its first session's position so the list keeps
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

The data layer (`GitReviewReader`) shells out on a dedicated queue and completes on main —
`GitWorktree`'s runner made async, following `ProjectIconResearch`'s shape. Every invocation
passes `--no-optional-locks`, so a *read never takes `index.lock`* out from under the agent
working in the same checkout, and `-c core.quotepath=false` so paths arrive literal. Diffs
add `--no-color --no-ext-diff --no-textconv`; parsing git's porcelain and unified-diff output
is `GitDiffParser`, pure functions with the fixture traps (C-quoted paths, the trailing tab
after a path with spaces, `\ No newline` markers, `-z` rename records) pinned by unit tests.

**`git diff` never mentions untracked files**, so the working-tree modes synthesize them:
`status --porcelain=v2 -z -uall` lists them individually and each becomes an all-added file
diff read in-process — not `diff --no-index` per file, which would spawn a process per file
in a freshly scaffolded project. Size-capped (256 KB), binary-sniffed by git's own NUL
heuristic.

**Last Turn's baseline is `git stash create`** — an unreferenced commit that mutates no ref,
no index, no worktree; empty output means clean, so HEAD is the baseline. Captured by
`GitTurnBaselineStore` on the *entering-working* edge (fed from the same
`sessionStateDidChange` hook that refreshes the branch), because a baseline taken at stop
would fold the user's own between-turn edits into the next turn. In-memory only: the snapshot
is gc-prunable, and a persisted hash whose object has vanished is a worse answer after
relaunch than "No turn recorded yet" — a pruned baseline is detected by `rev-parse --verify`
and reported as expired, not as an error. `stash create` omits untracked files, so the
baseline records the untracked path *set*: files untracked then and still untracked now are
not the turn's work. The residual gap — edits to a file already untracked at turn start —
shows only in Uncommitted, and that is accepted.

Rendering reuses the diff machinery: `DiffView` gained a second initializer for numbered
`GitDiffLine`s (one number column, new side falling back to old — a dual gutter spends a
narrow pane's width on bookkeeping) while the edit-tool path renders pixel-identically.
`GitReviewFileRow` is `ToolCallView`'s collapse pattern per file, and **bodies build on first
expand** — a collapsed file costs one header row, which is what bounds a multi-thousand-line
branch diff. Small files auto-expand (≤200 lines each, ≤600 cumulative). The mode persists
with the tab (`PersistedTab.mode`); restore builds the controller but runs no git until the
tab is actually shown, the browser's deferred-load rule.

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

The selected session's **floating status card** is fed by `GitChangeMonitor`, a smaller
read-side coordinator over that same watcher. It serializes summary reads and remembers one
trailing refresh when a new write lands mid-read, so a burst always ends on a reading taken
after its last write. Idle, the card says branch and `+N −M`. While a **native conversation's**
turn is active it keeps that exact monitor alive but changes the presentation to a working orb,
structured plan position when available, changed-file count and `+N −M`. The totals are still the
checkout's uncommitted totals — not a count inferred from Edit tools — and clicking either
Git presentation opens Git Review. When the session has children, a separately clickable
working/done segment joins the same line and opens the Subagents display-pane tab. It remains
visible even when there is no Git sentence to show, making the surface a session status card
rather than forcing child navigation back into the conversation.

The mark sits closer to the branch name than the sentence's own gap between name and counters,
so it reads as belonging to the name rather than as a third item in the row — and it sits on the
same optical line, which took a fix in the label helper rather than in the card (see
`design-system.md`).

The card is also an **extension surface**: `session.corner-card@1` exposes one display-only
slot whose ID is the placement — `top-trailing` today, `top-leading` reserved for a future
leading card — deliberately named after the corner rather than after git, since the card may
carry more than the checkout's reading one day. Extension rows render below the summary line
and the card grows downward; with the slot empty the collapsed constraint reproduces the
original single-line geometry exactly, which is what keeps the render tests honest. Rows ride
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
top of a terminal: at `ink.surface`'s 14%, with the view itself at 85% for "quiet at rest", a long
branch name and a line of the agent's answer were legible through each other. Its fill is now
flattened against the backdrop (`WindowBackdrop.opaque`) so it keeps the role's colour without the
role's transparency, and the resting quiet moved to the card's contents. Pinned by
`ThemedIndicatorsTests.testTheGitCardOccludesThePaneTextItFloatsOver`.

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
turn-baseline→worktree, `commit^`→`commit` — and titles the sides accordingly, so the tags over
the image say *which* two things are compared. A side git does not hold comes back nil rather
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
