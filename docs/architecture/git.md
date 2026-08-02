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
different branches simultaneously. A chat re-reads it when the agent stops working, which is
when an agent is most likely to have just switched. A standalone terminal updates it with its
cwd, from OSC 7 or the process-directory fallback, because the shell can move between added
projects while it remains live.

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

The collapsed body rule does **not** by itself make the file index cheap. Measurement showed
`NSStackView` eagerly laying out 1,000 collapsed headers took about 94 seconds. Progressive
20-row materialization reduced the first viewport to about 29 ms, but a deep walk still became
superlinear because every appended header remained in the stack.

File comparisons now use a **reusable `ThemedTableView`**. The complete file model is available
for immediate scrolling, while only viewport rows are constructed: the 1,000-file Debug fixture
creates 14 rows initially and 28 total after a direct jump to the end. That run opens in about
19 ms and the deep jump takes about 18 ms. A watched redraw preserves the scroll offset and
expansion overrides; lazily built bodies invalidate the table's automatic row-height cache.
The fixture and the `git.read.*`, `git.process`, `git.review.render`, and
`git.review.render-files` spans are documented in [`performance.md`](performance.md).

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

**The agent line says what the session's own CLI does not.** It carries the model, and where they
are knowable the effort and Fast state, under the checkout rows and above the children — the rows
reading outward from what the pane *is*: which branch, what changed in it, which agent is working
it, who it delegated to. It reuses the `cpu` mark the composer and the conversation's status row
already give the model chip, so one fact keeps one mark wherever it appears.

Which facts belong to the card is decided *before* it. A **native conversation** gets none: its
status row already carries model, effort and speed as chips directly above the composer, so the
card would say them twice in one view — the same rule the run spinner follows. A **terminal
session** gets whatever its status line leaves out, which `ClaudeStatusLineCoverage` answers by
running the account's own command (see
[`session-activity.md`](session-activity.md)); on the machine this was written against three of
four Claude logins print usage and nothing else, so the model appears nowhere until the card shows
it. `GitStatusOverlayView.ModelReading` is handed the decision rather than asked to make one — a
nil field means "do not say this", not "unknown" — which keeps a Claude-specific rule out of a
Git-shaped view and lets each part drop independently: a line of just "Fast" is correct for an
account whose status line names the model and effort but not the speed.

Two facts are withheld rather than guessed. **Fast mode is a reading only where Threading sets
it** — `appendCodexConversationOverrides` is Codex-only, and Claude's fast-mode state belongs to
its print transport (`AgentModels.defaultFastMode` returns nil for Claude and says why) — so a
Claude *terminal* session reports no speed at all. **Effort for a Claude terminal session is the
account's configured value**, what the CLI will inherit, which goes stale the moment the user
types `/effort`; when their status line prints effort the card hides its own, which is also the
case where the staleness would have shown. The transcript records what each turn actually ran at
and is the authoritative source where a conversation is being replayed — see
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
`.compactName` the Git Review changed-files pill uses for the same diff, so the two surfaces
agree. The accessibility label keeps the exact counts, joined by the separator the eye
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
turn-baseline→worktree, `commit^`→`commit` — and titles the sides accordingly, so the captions
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
