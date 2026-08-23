# Sessions and Terminals

Side chats, standalone terminals, the shell drawer, naming, launching, resuming and importing.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

## The Runtime Capability Matrix

`AgentKind.capabilities` in `Models/Project.swift` is the **only** place a runtime is named to
decide what the host may do with it. Everything else asks `kind.supports(_:)`, and
`scripts/check_architecture_boundaries.sh` fails the build on a `kind == .claude`-shaped
comparison anywhere under `Sources/Threading` outside that file.

The rule exists because the alternative was measured rather than imagined. Fifteen such
comparisons had accumulated — the status line, the transcript title reader, the model reading,
Remote Control, the two Fast mechanisms, the leading-slash envelope, subagent identity — and
each one answered only for the runtimes that existed the day it was written. Grok and OpenCode
fell into the `else` of every one of them silently. There is no way to review that: the
question "what does OpenCode do here" has no single place to ask it.

Three mechanisms carry provider difference, and mixing them up is how the matrix rots:

| Mechanism | Owns | Example |
|---|---|---|
| `AgentCapabilities` | Static facts about the **runtime** | Claude draws a status line; Codex hooks and its app-server agree on a child's identity |
| Catalog data | Facts about the **account and model**, read at runtime | `AgentModelOption.reasoningLevels` decides whether the effort chip appears at all — no runtime is named |
| Optional protocols | Facts about a **live transport** | `FastModeConversation`, `ModelSwitchableConversation`, `SubagentReportingConversation` |

Prefer the lower two. The opening effort chip is entirely catalog-driven. A reply-time effort
chip additionally asks `ReasoningEffortConfigurableConversation`, because a model publishing
levels does not prove that an already-running transport has a live wire for changing them.

An exhaustive `switch` over `AgentKind` stays allowed and is often right — a transcript parser
or a launch line genuinely differs per runtime, and there the compiler makes a fifth case a
build error, which is the reminder the lint exists to reproduce for comparisons it cannot see.
What the lint cannot catch is the *same* allowed switch written twice, so keep one copy:
`SessionTranscript` is where "where is this session's file" is answered, after the replayer and
the migration check each carried their own identical dispatch over the two transcript readers.
Both would have needed editing to add a third, and neither would have failed to compile.

The corresponding base fact is `AgentCapabilities.transcriptReplay`: Claude and Codex have
measured local conversation JSONL that Threading can normalize. It intentionally excludes
OpenCode, whose supported export is enough for `.transcriptUsageIndex` but is not a replayable
conversation, and Grok, whose native history arrives over ACP `session/load` rather than a local
parser. `TranscriptReplayFormat` is the closed implementation set behind the capability. Replay,
subagent loading, title backfill and both import scans dispatch on that format instead of each
maintaining a Claude/Codex list; `AgentCapabilitiesTests` requires the set and capability to agree
exactly and requires narrower transcript-record capabilities to imply replay.

**A capability and the code it governs must not be able to drift.** `AgentCapabilitiesTests`
holds each pair to the other, because the failure mode is silent in both directions:

- `.forking` is granted, but `AgentSession.forkedConfiguration` has no case for the runtime —
  Fork appears in the menu and creates nothing.
- `.nativeUI` is granted, the composer offers the surface, `ConversationViewController` has a
  transport for it, and `ProjectStore.addSession` refuses the record. **This one shipped.**
  Choosing Grok with the conversation surface created no session and reported no error.
- `.terminalUI` is withheld — Cursor, whose two interfaces do not share a conversation store — and
  some surface still offers the Original UI choice, or `AgentLauncher` still builds a terminal
  command for it. The clamp in `AgentSession.resolvedNativeSurface` and the throw in
  `AgentLauncher.plan(for:in:)` are the two halves; `CursorACPProfileTests` holds both.
- `.headlessResearch` is granted, but `AgentLauncher.settingsResearchCommand` has no line for
  the runtime — the settings search's Ask AI button offers a provider it cannot run. The
  pairing test in `AgentLaunchQuotingTests` holds the claim to the delivery; the launch line
  itself and the scoped MCP endpoint it talks to are
  [`mcp-and-display.md`](mcp-and-display.md)'s.

That second bug is why session construction now lives in
`AgentSessionConfiguration.init?(kind:reasoningEffort:accountHandle:permissionMode:)`
rather than as a switch in the store. A rejection there means one of exactly two things: the
enum has no case that can represent the request, or the runtime lacks the capability the
request needs. Nothing in it is a rule about a runtime by name.

Reasoning effort has a second, narrower admission check in `ProjectStore.addSession`: an
explicit value must be one of the resolved model's `reasoningLevels`. Claude attaches the
installed CLI's documented session set (`low`, `medium`, `high`, `xhigh`, `max`) to every model
option and launches it with `--effort`; Codex uses each account's own model cache and launches a
`model_reasoning_effort` override. Grok and OpenCode publish neither a host-side catalog nor a
launch contract, so the composer invents no rows and the store accepts no explicit value.

Continuation lineage deliberately does **not** live in this provider-specific enum. Every
runtime can receive a provider-neutral `ConversationHandoff`; putting the source into the Claude
or Codex case made Grok/OpenCode continuations impossible to represent even after their delivery
mechanisms existed.

And it draws the line the store had blurred. A setting the runtime merely **ignores** is
clamped — `AgentSession.init` already drops `usesNativeUI` for a runtime without it. A setting
the runtime **cannot honour** is refused, because silently dropping an account handle would run
the conversation against a login the user did not pick. Grok's native surface was refused when
it should have been allowed, and OpenCode's was refused where clamping was the established
answer everywhere else; both now go through one rule.

## Side Chats

A **side chat** is a session forked from another: it opens carrying the parent's context and
keeps its own record, so a question can be asked without joining the conversation it asks
about. `⋯` on a session row offers **New Side Chat** and **Ask on the Side…**, the second
being the same fork with its question already asked, delivered through the composer's own
`pendingPrompt`.

The primitive is `--fork-session`, and every claim here was measured on Claude 2.1.217 rather
than inferred:

- It **copies the context into a new transcript** and leaves the parent's file untouched —
  which is what lets a side chat run *beside* a live session instead of queueing behind it.
  That is the difference from the surface switch, whose whole constraint is one live process
  per identifier.
- It **honours `--session-id` alongside it**, so the child's identifier is minted up front
  like any other Claude session and never has to be discovered.
- It records **no lineage**. The fork's copied records have their `sessionId` rewritten to the
  child's; the only trace of the ancestor was a stale snake-case `session_id` left on a single
  record. So `AgentSession.forkedFrom` is Threading's own bookkeeping, not something read back.

Claude only (`AgentKind.supportsForking`): `codex exec resume` takes an id and a prompt and
offers nothing else. Forging a Codex fork by copying its rollout is plausible — `SessionMigration`
already proves transcripts are portable client-side files — and unproven, so it is not offered.

`AgentLauncher.forkParent(for:in:)` decides, and reads the **project's own** sessions rather
than `ProjectStore.shared`: a fork resumes its parent's transcript, which is found through the
project's folder and the parent's account, so `ProjectStore.addSideChat` puts the child in the
parent's project and inherits both. The gate closes once `hasLaunched` — the fork is a birth,
not a mode, and from the second launch the child owns a transcript and resumes like anything
else. Without the parent's transcript on disk it falls through to an ordinary fresh launch,
the same rule the plain resume applies to itself.

In the sidebar a side chat nests under its parent (`SessionNode.childNodes`), and a session
row is expandable only once something was forked from it — the earns-its-level rule, one
level below branch grouping. The row takes a **fork glyph in place of the agent's mark**,
which it can afford: a fork necessarily runs its parent's agent and account, and its parent is
the row directly above, so the agent is the one thing there that cannot differ. The hover
popover spells the lineage out. Two records are tolerated rather than trusted, because
`projects.json` outlives any release: a **missing parent** leaves the row at the project level,
and a **cycle** is refused outright, since the outline view asks for children lazily and would
recurse forever.

What fork does *not* give is a merge back. Transcripts do not merge; the honest operation is
pasting a conclusion into the parent as a message, and both routes to it now exist. The agent's
is `send_to_session`, which delivers a side chat's conclusion to its parent as an ordinary,
provenance-prefixed turn (see [`control-plane.md`](control-plane.md)). The user's is the row's
**Send Result to Parent** — `SessionRenameRequest`'s twin (`SessionReportBackRequest`): one
line sent into the side chat naming the tool and the parent's id outright, because an agent
asked in prose to "tell your parent" answers in prose and the parent hears nothing. It is
absent rather than disabled unless the row is a side chat whose parent is still an unarchived
row, the agent is between turns, delivery would land (`SessionMessageDelivery.isReadyForDelivery`),
and the workspace tool group is on. And the first turn replays the
whole copied context, so forking a large conversation costs real tokens.

## Shell Drawers and Standalone Terminals

A shell is **not a kind of agent session**. It was one for most of this project's life — a sidebar row
beside the chats, with a title, a launch record, a branch field and an account slot it could
never use — for something with no conversation to resume, no transcript, nothing to import and
no scrollback that was ever persisted. Every one of those fields was a hole, and the code around
them was a run of branches saying *not for shells*: in the launcher, the replayer, the account
discovery, the usage service, the brand icons, the migration.

That conclusion still applies to the shell that belongs to a conversation. It is a **drawer
under the conversation** (`ShellDrawerViewController`, ⌃`), which is what it always was in
practice: a place to run a command *about* the conversation you are reading.
`AgentKind` contains installed agent runtimes (`.claude`, `.codex`, `.grok`, `.openCode`), not
model providers. `AgentCapabilities` is the single feature matrix consumed by presentation code.
The standalone `grok` executable is a runtime with caller-minted UUIDs, a native ACP surface and
a faithful permission mapping; choosing an xAI/Grok model through OpenRouter is still an OpenCode
session. Grok and OpenCode currently have no Threading account routing or side chats; OpenCode is
terminal-only and leaves permissions to its richer policy.

A **standalone project terminal** is a different promise: a first-class sidebar destination
for work that is not subordinate to a conversation. `ProjectTerminal` is deliberately its own
small record rather than a third `AgentKind`: identity, displayed and custom titles, current
directory, branch, theme assignment and creation time, with none of the transcript, provider,
account, model, resume or import fields an `AgentSession` requires. A project's hover `+` opens
a menu on its press: **New Chat…** or **New Terminal**. It briefly opened the chat composer
directly on the press with this menu on a secondary click — "the common case is a chat, and it
should not cost a menu" — but clicking the project row itself already opens the composer, so
that press saved nothing while hiding the terminal behind a gesture nothing advertised. The
PTY begins when the terminal is first shown, is retained by
`ProjectTerminalRuntime` across sidebar switches, and ends when the row, project or app closes.
After a normal exit the row remains dormant and **Start Again** creates a fresh shell in its
last recorded directory. The record survives relaunch; process state and scrollback do not.

`TerminalSession` therefore carries a `TerminalInstanceIdentity`, not a conveniently converted
`SessionID`. Agent PTYs, a conversation's drawer shell, standalone project terminals and
fixture/ephemeral terminals are separate enum cases. History filenames derive from that typed
identity (`<session UUID>`, `shell-<session UUID>`, `terminal-<terminal UUID>`, or an ephemeral prefix),
and cleanup compares those stems rather than UUIDs from one model domain. The two legacy bare-UUID
forms are disambiguated by migrating known project-terminal files before cleanup; new domains
are explicitly namespaced so a coincident UUID cannot make one terminal inherit or preserve
another's history.

An agent terminal's presentation adapter is constructed in UI and registered with `AgentRuntime`
as an `AgentTerminalRuntimeSurface`; Core no longer constructs or retains its concrete view-
controller type. Remote frontends reach the PTY through the separately injected, Foundation-only
`RemoteTerminalApplicationCapability`, whose runtime query is supplied by the same `AgentRuntime`
instance at the application composition root. The capability exposes typed `SessionID`, bounded
screen seed, cheap grid/title/viewport state, capture, input and viewport operations—never a view,
terminal emulator or controller. These are live process mutations and create no persisted session
record; transport authorization, refusal and audit/replay ordering remain outside the runtime
surface.

Core owners see smaller faces of that adapter, never the aggregate or its controller:
`AgentTerminalInputSurface` carries paste/submit for context handoff and receipt-backed message
delivery; `AgentTerminalLimitRecoverySurface` adds only bounded visible lines and limit-park
mutations; extension process inspection asks `AgentRuntime` for an optional scalar root PID. A
stopped adapter is unavailable for input and chooser keystrokes, while limit recovery may still
lower its transcript-derived park. The dependency gate rejects a controller-returning lookup
anywhere in Core, including one whose concrete return type Swift would infer.

`ProjectTerminalViewController` accepts OSC 7 working-directory reports and also samples the
shell process directory, because not every shell emits OSC 7. The cwd remains live runtime state:
it drives the derived title, branch reading, execution directory and the folder used by **Start
Again**. It does **not** decide ownership. A terminal stays under the project where it was created,
even after `cd` enters another already-added checkout. Moving a shell is ordinary terminal work;
moving its durable row, inherited settings and remote project identity in response made navigation
change underneath the user without an explicit project action.

The sidebar's **Sort by Type** order is the deliberate way to gather the two row kinds. Its
directions are **Chats First** and **Terminals First**; direction changes the two stable groups,
not the order within either group. Branch grouping remains the outer semantic structure, so a
mixed branch heading applies the same type direction to its own children.

### What a terminal is called

Both surfaces were born saying the literal word **"Terminal"** and stayed that way — a sidebar
row per standalone terminal, a tab per drawer shell, none of them distinguishable from another.
The reason nothing ever replaced it is worth writing down, because it looks like a bug in the
plumbing and is not: **under Threading a stock `zsh` reports no title at all.** Apple's title
hook lives in `/etc/zshrc_Apple_Terminal`, and `/etc/zshrc` sources it only when `TERM_PROGRAM`
is `Apple_Terminal`; ours says `Threading`. Claiming Apple's value to inherit the hook is a lie
every other tool that branches on `TERM_PROGRAM` would then act on.

It would buy little anyway. Even inside Terminal.app that hook reports only the **directory**
(OSC 7) — Terminal composes the tab's name itself, from the directory and whatever is running.
`TerminalNaming` does the same, as a four-rung ladder:

1. `customTitle` — a rename, which wins and stops following, as it does for a conversation.
2. the **reported** title — OSC 0/2, from `vim`, `ssh`, `tmux`, anything that names its own
   window. A program that has said what it is has said it better than we can.
3. the **derived** name — the foreground command if one is running, else where the terminal is.
4. `"Terminal"`, which now names only a record whose shell has never run.

**A reported title has to be retired, or it goes stale.** Nothing resets a title here — the hook
that rewrites one at each prompt is Terminal.app's — so quitting `vim` would otherwise leave a
row named after the file forever. `TerminalSession` records *which foreground process group* set
the title and drops it when that group is gone. A title set while the shell itself was in front
is kept: a user whose `zsh` writes its own title at every prompt (oh-my-zsh does) has said what
they want, and clearing it would fight their config once a second.

**The derived name is stated relative to the project, not as the directory's last component.**
A terminal's row sits directly beneath its project's row, which already carries the folder name,
so a terminal at the project root would simply repeat the line above it. At the root it is the
shell's own name (`zsh`); below it, the path within the project (`Sources/Threading`, not
`Threading`, which is ambiguous the moment a project has two of them); outside any project, the
last two components, or `~`. The codebase reached this conclusion once before from the other
direction — `SessionNaming.isNoiseTitle` rejects an agent title equal to the project name or its
folder basename.

Three seams keep the cost off the hot paths. The foreground group is read with `tcgetpgrp` on
the pty, one syscall on the poll `ProjectTerminalViewController` was already running for the
cwd; `ProcessUtility.processName` — which copies the kernel's argument area — is called only
when that group *changes*. The project a row is named against is resolved once per tree build
and carried on `TerminalNode`; it is the same project that owns the terminal record, so a row
does not need another store lookup. And rung 3 is **computed, not stored**: a `cd` moves the name
with no write, and a dormant record cannot show the name of a command that stopped running two
launches ago.

**That foreground group is also the standalone terminal's working boundary.** The shell itself
stays alive at its prompt, so `TerminalSession.isRunning` cannot distinguish `sleep 10` from an
idle terminal, and PTY-output inference cannot see a silent command at all. The cached group
presence therefore drives the terminal row's themed spinner, independently of whether the
kernel yielded a printable process name. The same existing poll posts the targeted row refresh;
there is no second timer, process walk or output heuristic. Under the pointer the spinner yields
to the terminal action in the same fixed trailing slot, and on an emphasized selection it takes
the selection's ink rather than drawing accent on accent.

The drawer is a **tab host** (`DrawerHostViewController`) on the same model as the display
panel — `PaneTab` lists per session, a `ThemedTabStripView` along its top, a `+` for another
tab. The shell is its *default first tab*, auto-created the first time the drawer opens for a
session; the strip creates the kinds that are naturally many (shells, browsers), while the
singleton surfaces (review, info, files) keep their one home in the display panel. One host
controller serves every session and is installed in the band exactly once: a session switch
swaps which list it shows and re-parents nothing — the per-switch detach the old code did is
what used to separate a shell from its scrollback view. Drawer tabs and the open flag persist
in the session's panel payload (`PersistedTab.host == "drawer"`); the height persists app-wide
(`ShellDrawerHeight`), because a drawer height is window geometry, not a fact about a session.
`restoreIfNeeded` writes `PersistedTab.title` and then discards it on the way back in, rebuilding
each tab's name from the live surface. That was harmless while every shell tab was the constant
`"Terminal"` and is now the point: a restored tab has no process yet, and a name recovered from
the payload would be whatever the last session's shell happened to be running.

Three decisions worth keeping (they predate the tabs and survived them):

- **It opens where the agent is**, not where the session started. A terminal session reports its
  directory over OSC 7, so `TerminalSession.effectiveWorkingDirectory` is asked at the moment the
  shell starts — an agent that has spent ten minutes inside a subpackage hands its shell that
  subpackage. The project folder is the fallback, which is also exactly right for a natively
  rendered conversation: no PTY to ask, and the CLI was launched there anyway. The container
  injects this as the drawer host's `directoryProvider`, since only it can ask the PTY.
- **It takes the session's resolved profile** (`ThemeAssignments.profile(for:)`) — the same call
  the agent's own terminal makes — so a themed session's drawer matches the surface above it.
  And the same `TerminalPadding` inset, painted in the terminal's own background: the drawer's
  shell was the one flush terminal, its first row on the strip's rule and its first column on
  the pane's edge. Its host also observes `AppThemeDidChange` like the other two terminal
  panes, or a "Follow App Theme" session's margin would keep the old palette across an
  app-theme switch while the terminal repaints.
- **The process is the feature.** A shell starts on first reveal (a drawer never opened costs
  nothing — and "revealed" means on screen, so fixtures never spawn one), survives session
  switches, and ends with its *tab* or its session. A shell that forgot its directory and
  history on every switch would be worse than the terminal beside it.

The pane is not a split view: the conversation fills it and the drawer is a strip taken off the
bottom, always installed and zero-high when closed, so every session surface pins its bottom to
the drawer's top and opening one is a change of constant. A split view would have brought its own
collapse behaviour, delegate and priorities, all of which would need arguing out of the way.
The divider's grab strip overlaps the surface above it — the surface's bottom edge and the
strip occupy the same 5pt band — so a surface must also be attached *below* the divider in the
sibling order. It was slotted in directly under the git overlay instead, which covered the
seam's rule and swallowed the strip's hover, cursor and drags, and every drag test kept
passing because those drive the divider's callbacks rather than the pointer; the hit-test in
`ThemedControlTests` and the in-pane render in `ToolbarChromeRenderTests` now pin the seam
itself, and the rule draws at the strip's bottom edge — where the drawer actually begins —
rather than floating its own height above the tab strip.

That change of constant moves the way every pane in the window moves. The gestures — the
toggle, the drag spring, a moved-in tab's reveal — run it through `PaneTransition`
([`window-chrome.md`](window-chrome.md), *how a pane moves*), while a session switch applies it
instantly: the switch swaps the whole workspace at once, and the drawer sliding beside an
instant page change would animate a change of subject as if it were a change of state. An
animated close swaps the host off the session only in its completion — the tabs stay up while
the band slides away — guarded by a generation counter so a reopen mid-slide is not hidden by
the close it interrupted. The drawer's divider also shuts it like every other pane's: the
height constraint clamps at the floor while the pointer keeps going, so
`TerminalContainerViewController` keeps the unclamped running total during a drag, and the
release asks `PaneTransition.dragShutsPane` — the strip reports only deltas, which is also why
the drag-shut tests drive the container's two seams rather than synthesized events (a test
`NSEvent` cannot carry `deltaY`). A drawer shut this way reopens at the floor the drag reached,
never the overshoot, and the window is told through
`terminalContainerDidChangeShellDrawer` so the toolbar's toggle follows a change it did not
make.

**Existing shell sessions were dropped, not converted** — there was nothing to convert. The
version-1 → 2 state migration strips them before decoding, which it must: a kind the model no
longer has does not decode, and one undecodable session would otherwise fail the whole document.

## Why Sessions Are Not Tabs

The content pane's header names the current page with **one chip**
(`MainWindowController.pageTabView`), not a strip of open sessions. A strip was built and
then removed: switching a session swaps the *whole workspace* — the drawer, the display
panel, the sidebar's selection all pivot with it — so a row of session tabs sitting above
only the conversation claimed a narrower scope than what it actually switched, and it was a
second session switcher duplicating the sidebar's job. The sidebar is the switcher; the chip
names where you are (session, composer, or settings page — its identity is what lets a
rename morph), its × returns the pane to its empty state without touching the agent, and
quick back-and-forth is the history buttons' job (⌃⌘←/→, see `NavigationHistory`). Tabs
remain what they always were here: the *panel's* and the *drawer's* content.

**⌘W closes a tab or the page, never the session.** Stopping an agent is a bigger decision
than a reflex chord: `Close Session` kept its menu item and lost only the default binding
(stored overrides survive — they key on the command id). The chord runs on focus
(`focusedTabHost()`): inside the drawer or the panel it closes that strip's active tab;
anywhere else it closes the page on screen — settings back to what it covered, a session or
composer page to the empty pane.

**⌘, is a detour, so it ends where it started.** `MainWindowController` remembers the *page*
Settings opened over (`preSettingsPage`), not merely a session id: remembering only sessions
put the second ⌘, on the empty state whenever the pane held a composer, which took a
half-written prompt off the screen with it.

**Looking at something else and coming back is a detour too, and the composer is kept whole
across it.** `SessionComposerViewController.show(projectID:)` treats being pointed at the
project it *already holds* as a return rather than a change of project: the agent, account,
model and checkout just chosen stay chosen, the half-written prompt stays, and so do any
attached images — which are deliberately not drafts (see [`persistence.md`](persistence.md))
and therefore exist nowhere but in that composer. Re-configuring on the way back is what made
an attached screenshot disappear while the sentence describing it, restored from `DraftStore`,
stayed on screen. Only what the chips *derive* is re-read (`refreshDerivedState`): Settings is
where those defaults change, and a session can be read for long enough that a usage figure ages
out. The rule lives in the composer rather than in its callers, so every route back to it —
the sidebar, ⌘N, Back/Forward, Settings closing — gets it from one place.

That makes **starting a session the thing that empties the composer** (`start(with:)`), and
only once the session exists: the delegate answers whether one was made, which is the same
answer `DraftStore` is cleared on. A start that failed leaves the words where they can still be
used; a start that succeeded must not leave its opening prompt, and the images sent with it,
standing in a composer the user comes back to.

**The pane focuses whatever it puts on screen, and the composer is not an exception.** `attach`
hands a terminal the keyboard and `attachConversation` hands a native conversation's reply box
the caret, so a composer that arrived unfocused was the one surface asking to be clicked before
it could be used — and it is the surface reached by ⌘N, which is a request to type. Every entry
point focuses it: `showComposer` does so whether it configured the composer for a project it had
not held or put back the one it had. The caret lands **after** any restored draft
(`PromptView.focusAtEnd`).
`stringValue` deliberately leaves the selection at position 0 so a long draft is *read* from its
beginning, which is right while nothing is focused and wrong the moment something is: the next
keystroke would land in front of the user's own half-written sentence rather than continuing it.
Plain `focus()` keeps the caret where it is, and is what removing an attachment uses — handing
the editor back is not the user asking for the caret to move out of the middle of a sentence.

## The Composer

### Turn admission and completion checkpoints

A native prompt is not placed on the provider wire immediately after the composer accepts it.
`ConversationViewController` first mints the `ConversationMessageID`, asks
`NativeGitTurnAdmission` to publish the repository's before checkpoint, and passes that same id to
`stream.send(_:identifiedBy:)` from inside the gate. Direct sends and outbox hand-off use the
identical path.
If the transport refuses after preparation, the checkpoint is marked not admitted and collected;
it cannot become a numbered conversation turn or be reused by the next attempt.

The opposite boundary is equally ordered. A live `.turnFinished` event is held while the matching
after checkpoint is captured, then applied to the timeline with that checkpoint id in scope. The
changed-files card therefore binds to the exact turn that just settled, and an outbox message cannot
start until the final tree exists. Transcript replay skips capture: replay describes an already
finished provider history and must never manufacture new Git boundaries.

Terminal sessions use the provider hook's stable `turn_id` when present. Their turn-start HTTP
response is the admission fence and their authoritative turn-finished/Stop response is the
completion fence, including a Stop that reports work left running. Activity inference remains a
best-effort fallback for runtimes without hooks, but it creates its own honest record and never
adopts the preceding turn's refs.

The composer hangs from the pane's **bottom** edge — input below, room above, the shape every
chat product has taught — and the room above holds a **hero**: the Threading mark over a
greeting (`ComposerGreeting`). The greeting is deliberately inconsistent: when the calendar
offers a special (a holiday, a Friday, a weekend) it is taken ~60% of the time, otherwise the
time of day is mentioned ~40% of the time, and on an ordinary Tuesday most picks say nothing
about the clock at all. The rule lives in one place with the date as a *parameter* and the
randomness injected, so tests pass a fixed date and a seeded generator; production reads the
clock only at the call site. The hero hides below a height threshold
(`viewDidLayout`) — half a greeting peeking from behind the prompt reads as a defect.

**The line is minted on arrival and then held** (`chatGreeting`). It is a *welcome*: it belongs
to the composer being pointed at a project, not to any decision made on it afterwards. Asked for
each time the hero is restated it followed `refreshChips` instead — every chip's selection ends
there, and `refreshChips` restates the role, which owns the hero — so choosing a model, an effort
or a permission mode morphed the sentence over the box into a different one, which reads as the
app answering a choice it has nothing to say about. Returning to a project the composer already
holds keeps its line for the same reason it keeps the chips and the half-written prompt.

Choosing **Manager** replaces that greeting with what a manager is for — three lines rather than
one (`ComposerDefaults.managerGreeting`) — and the hero *morphs* between the two: it is one
`MorphingMultilineTitleLabel`, so the greeting becomes the brief's first line while the other two
morph in beneath it, and back out again on the way to a chat. It was two labels swapped by
`isHidden`, which cut between them in the one place on this screen the eye is already resting.
See [`design-system.md`](design-system.md) for why a block of lines is what morphs and a
paragraph is not.

**The prompt box carries the same control row the conversation replies with** — model, mode and
catalog-backed effort on the leading side of its bottom row, the account's usage reading and the
surface on the trailing side. The send is what differs: a brief is several lines, so Return
breaks the line and the send is the **Start session** button under the box, at the trailing end
of the row the import offer leads (`SubmitPlacement.outside`, and see
[`design-system.md`](design-system.md) for the commit that put it on the footer instead and took
Return away from the text). ⌘Return sends under every setting, drawn on the button's face; with
no project chosen the button and the box are disabled together with a stated reason.

**So it becomes that box rather than being replaced by it.** Starting a session swaps two whole
surfaces, and the box is the one thing on both of them, which makes an instant swap read as a
second screen arriving over the first. `ComposerHandoffAnimator` moves it instead: the composer's
picture fades where it stood, the box's picture travels from where it was to where the reply box
now is and crossfades into the real one, and the thread comes up under both — one animation group
at `Design.Motion.handoff`, one completion, and an end state identical to the swap it replaced.

It fires for exactly one route: a start made **in the composer** whose session is rendered
natively. `SessionCoordinator` marks the pane at the point that start succeeds
(`prepareComposerHandoff(for:)`) and the attach spends the mark, which requires the id to match
*and* the composer to still be the surface on screen. Every other attach clears it, so a terminal
start, a resume, a sidebar click, a remote start and a settings page are all the plain swap they
always were, and a mark can never be inherited by whatever is selected next. Anything taking the
pane mid-flight cancels the move onto its own end state and takes the ghosts with it. Under Reduce
Motion the token is zero and the same path lands instantly, building no ghost at all.

That also settled a height problem. A pane's content is a required minimum on the window, so
anything here that grows without bound grows the *window* — which the old usage panel did, one
bar per rate-limit window and one per metered model, off the bottom of the screen. The column is
bounded by construction now: a chip row, a box capped at `Design.Size.inputMaxHeight`, and a
one-line import offer under it. See
[`window-chrome.md`](window-chrome.md#a-pane-cannot-be-taller-than-its-window).

The first chip is the **location**: `<project> ▸ <checkout>` in a repository, the project alone
outside one. Its menu opens with the checkouts a session can run in — this one, each added
sibling (`ProjectStore.siblingCheckouts`), then *New Worktree…* — and the projects sit one
layer in under *Switch Project*, with the same subtitles (`~`-abbreviated folders) the project
chip used, followed by *Add Existing Folder…* / *Create New Folder…*. The nesting is not
decoration: picking a checkout routes *this* session and leaves the composer untouched, picking
a project navigates and resets every choice in it, and one flat list of places made the second
reachable by a mis-click aimed at the first (see
[`design-system.md`](design-system.md)). Selection routes through
the delegate to `sidebar.select(projectID:)` — the one path project selection already takes —
and the folder items reuse the coordinator's `addProject()`/`newProject()`. This is also what
replaced the idea of a "first project" onboarding page: with **no projects at all the empty
pane shows the composer itself in a nil-project mode** (`showEmptyState` →
`showComposer(projectID: nil)`) — prompt live, the send disabled and saying why, chip reading
"Choose a project…" and its menu flattened to the projects themselves, since choosing one *is*
the ask. Words typed before a project exists follow the composer into the project chosen
next (unless that project already holds a draft); a draft belonging to a project just left
does not leak back the other way. With projects present but nothing selected, the
"No Session Selected" placeholder stays — the composer is the way *in*, not the idle state.

The second chip is the **identity**: the agent's brand mark, and `<agent> · <login>` wherever
that agent has more than one login to choose between. Its menu is **one flat list of every
runtime's logins**, each carrying its runtime's mark and its usage reading (see
[`accounts.md`](accounts.md), which holds the reasoning and the `ComposerIdentity` contract). A
runtime gets a row of its own only where it offers no login to name. Choosing any row sets the
runtime and the login together and clears the model and effort — both belong to a catalog the
new login may not publish.

## Session Names

**A session is never named after its agent or account** — the row's icon slot and account mark
already carry both facts, so "Claude Code 2" as a name repeated them while saying nothing about
the conversation. `SessionNaming` holds the rules; three names remain, resolved by
`displayTitle`:

1. `customTitle` — an explicit rename, which wins and stops following the agent
2. `agentTitle` — the agent's own name for the conversation, from terminal presentation,
   transcript title records, or canonical provider metadata. It is what names a *native*
   session and what survives a surface switch, and is retained after the agent exits. (Stored
   under the old `terminalTitle` key, so existing records decode unchanged.) The slot carries a
   persisted `AgentTitleSource` with an explicit authority order: `reported < provider < chosen`.
   Codex's canonical name therefore survives its TUI re-asserting a stale OSC caption, while a
   name chosen through `set_session_name` survives every automatic source. Only another chosen
   name moves a chosen name.
3. `title` — derived from the **first prompt** (first line, capped): set at creation when the
   composer has the prompt, or by the first `UserPromptSubmit` hook report for a prompt typed
   straight into the terminal. Empty until then; the display falls back to "New Session".

The explicit rename is also the registry command `session.rename`, editable and bound to ⌘R by
default. The Project menu routes it to the selected session. With no session selected, the command
palette advances to a searchable session input and targets the chosen id directly; Close Session
uses the same path. The sidebar row, pane-header menu and terminal context menu keep their target-
specific route. Each draws the registry's current binding and keeps the same clear-to-follow-the-
agent rename contract. A rebind therefore changes both what fires and what every action menu
promises.

Claude records both kinds of title in the transcript as different record types, measured
across this machine's transcripts rather than assumed: `ai-title` is the CLI's own name,
re-appended every turn (so the *last* one is current, and `SessionNaming` reads the file's
tail rather than scanning the conversation); `custom-title` is written by `/rename` — after a
mid-conversation rename both keep being appended, interleaved, so *presence* of a custom
title decides, not order.

Codex's rollout JSONL still records no title. Current releases instead keep one canonical
`{id, thread_name, updated_at}` record per conversation in `<CODEX_HOME>/session_index.jsonl`;
`/rename` rewrites that index. Native app-server returns the same value as `Thread.name` and
publishes changes through `thread/name/updated`. Threading reads the native fields directly,
refreshes a terminal session's index after a quiet edge in TUI output, and scans each account's
index once at launch so a rename made while Threading was closed also reaches a dormant row. The
TUI's human confirmation sentence is never parsed.

**`ai-title` is written once and then almost never rewritten**, which is the fact the rest of
this section turns on. Counted across the twelve largest transcripts here: each carries 34–422
`ai-title` records, and **ten of the twelve hold a single distinct value**. The two that moved
moved exactly once, thousands of lines in — `"Commit changes"` → `"fork-session-feature"` at
line 813 of 3240, and a first-turn sentence → `"public-chat-web-ui"` at line 5896 of 7928 —
and neither has a `custom-title` record, so those are the CLI rewriting its own title rather
than a `/rename` misread. Re-reading the transcript therefore rescues a name that arrived after
a surface switch or was never read; it is **not** a way to make a name follow the work. A
session named after its opening message keeps that name while the conversation becomes
something else.

That is what `set_session_name` is for (see [`mcp-and-display.md`](mcp-and-display.md)), and
what the `⋯` menu's **Rename with Agent** asks for: one line sent into the running session
telling it to call that tool. The agent already holds the conversation, so the context has been
paid for once and this costs a short turn against a warm cache. Both alternatives pay again for
what the agent already knows — a fork copies the whole transcript and replays it cold (the same
cost noted under side chats above), and a headless `--print` run buys a fresh system prompt and
tool schemas in order to be told the same thing.

`SessionCoordinator.canAskAgentToRename` decides whether the item appears at all, and the third
of its three conditions is the one that is easy to miss:

1. an agent is running, or there is nothing to ask;
2. no turn is in flight — text sent into a working agent lands in whatever it has on screen, a
   permission prompt or a half-typed composer line;
3. the session tool group is switched on, or the agent has no `set_session_name` to call and the
   request would spend a turn on an instruction it cannot carry out.

It is **absent rather than disabled** when those fail: the menu already reads long, and none of
the three reasons is something a greyed row could say. The request itself names the tool
outright (`SessionRenameRequest`) rather than asking in prose — an agent asked in prose answers
in prose, since both CLIs have their own `/rename` and their own idea of a title, and the
sidebar would learn nothing. It is sent through the ordinary composer path, so it is echoed
into the transcript as a user turn: an instruction sent to an agent invisibly is one the user
cannot see, correct, or account for when the reply arrives, and this one spends their usage.
Native sessions take it over the stream; a terminal has no send-or-refuse, so the text is typed
into the PTY and a carriage return submits it — `\r`, not `\n`, which several TUI composers
insert as a line break and send nothing. The return goes in its **own write, a beat later**
(`SessionRenameRequest.submitDelay`): input arriving in one chunk is precisely what a TUI's
paste heuristic detects, so a return bundled with the text is "pasted content" — Claude Code
inserted it as a line break and the request sat unsent in its composer until the user pressed
Return themselves. Sent separately it is a keypress again.

**`launchName` is nil unless the user renamed the session**, and the `--name` flag is only
passed then. This is load-bearing: `--name` marks the conversation custom-titled in the CLI,
which sets its terminal title *and stops it generating `ai-title` records* (measured: 9 of 10
transcripts launched under a default name held none). Passing the old agent-derived default
name was therefore feeding "Claude Code 2" into the CLI's picker, echoing it back as the
terminal title, and switching off the very signal the sidebar prefers.

Agent titles that are really the product, account or project name ("Claude Code", the
account's alias, the folder Codex titles itself after) are ignored as noise rather than
stored (`SessionNaming.isNoiseTitle`), and titles are stripped of their leading decorative
glyph on the way in (`ProjectStore.strippingDecoration`). Claude Code reports titles like
`✻ testings`; that marker identifies the agent in a plain terminal tab, but the sidebar
already draws a status dot and an agent icon. A title consisting only of symbols is left
intact rather than reduced to nothing.

**A name that changes is morphed into its replacement, not swapped** — the sidebar rows, the
pane header's page name, and project and checkout rows all draw through `MorphingTitleLabel`. Two
rules decide when, and both exist because the animation is only honest about a *change to
something already on screen*:

- **Only the same record renamed animates.** A row holds the id it last drew and the string
  it last drew; a morph needs both to say yes. A first fill, a row reconfigured while an
  agent works, and a cell recycled from another session all land the name directly — the
  last would otherwise animate a transition between two unrelated conversations, which reads
  as a glitch. A *heading* never animates at all: its name is its identity, so a different
  name there is a different heading rather than a rename of this one.
- **The rename has to reach the view that is showing it**, which is what actually made this
  work and was two separate gaps. `ProjectsDidChange` fires for content edits as well as
  structural ones, and the sidebar answered every one with a full `reloadData()` — which
  hands each row back to the reuse pool, losing the very name the morph animates from. So
  `reload` compares a **structure signature** (identities and nesting, deliberately *not*
  names) and refreshes the rows in place when the tree's shape is unchanged, while
  `refreshRow` reconfigures the live view rather than reloading the row. Separately,
  `MainWindowController` observed *nothing*: the toolbar title was updated only from the
  terminal's own `sessionTitleChanged`, so a rename from the row's `⋯` menu never reached
  it at all and the tab kept the old name until the pane next changed.

`SessionNaming.backfillLegacyNames` runs once per launch and replaces what the old scheme
left behind: placeholder titles ("Claude Code 2", the account-alias variants) drop to empty
and are re-derived from the transcripts — the agent's own title where one exists, the first
prompt otherwise. Idempotent by construction: a backfilled session no longer carries a
placeholder title, so later launches skip it without reading anything.

The iPhone session header follows the same authority ladder through the catalogue's
`RemoteSessionSummaryDTO.title`. Its live session socket also carries a title, but that value is
the surface caption captured when the connection opened and may lag an explicit rename. It is a
bootstrap fallback only while the catalogue has no title; it never overrides the catalogue.

## Launch and Resume

```
Select session → AgentLauncher.plan() → login shell → cd <project> && exec <agent>
                                                              ↓
                          agent exits → PTY torn down → session marked dormant
                                                              ↓
                  row stays in sidebar → select again → resume by agent session id
```

Launches go through a **login shell** because a GUI app does not inherit the user's
interactive `PATH`, and the agent CLIs live in `~/.local/bin` or a Node prefix. It is also why
`AgentEnvironment` can *delete* rather than correct: anything the user genuinely sets is
re-exported by their own profile on the way back up, so what a filter removes is only ever what
the launcher left behind.

**And a launcher leaves behind more than a `PATH`.** `open` forwards its caller's environment
through LaunchServices, so a Threading opened from an agent's tool call — an ordinary thing to do
here — inherits that run's whole posture and hands it to every session under it. Measured on a
running app opened from a Codex shell: `CODEX_SANDBOX_NETWORK_DISABLED=1`,
`CODEX_PERMISSION_PROFILE=:workspace`, `CODEX_CI=1`, `CODEX_SHELL=1`, and the flattening a
non-interactive caller applies to everything it runs — `NO_COLOR=1`, `TERM=dumb`, `PAGER=cat`.
Every one of those describes a run that had already ended, and the sharp end is not cosmetic: a
Codex session launched inside the app was told its network was disabled by a sandbox that no
longer existed.

`AgentEnvironment.inheritedIdentityPrefixes` therefore names **families** — `CLAUDE_`, `CODEX_`,
`GROK_`, `OPENCODE_`, `AI_AGENT` — rather than variables. `CURSOR_` is deliberately **not** among
them yet, and the reason is worth keeping: that family carries run identity (`CURSOR_CHAT_ID`,
`CURSOR_CONVERSATION_ID`, `CURSOR_SANDBOX`) *and* credentials (`CURSOR_API_KEY`,
`CURSOR_AUTH_TOKEN`) under one prefix, while the exception mechanism below holds a single key per
runtime. Adding the prefix today would strip the login. It was written variable by variable and
the gap that produced is exactly the failure mode: `CODEX_THREAD` was listed and `CODEX_CI` beside
it was not, and nothing reports a variable that should have been dropped. The one exception is
`AgentKind.accountEnvironmentKey` — `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME`,
`OPENCODE_CONFIG_DIR` — which names *where a login lives* rather than who is running, and is how a
launch reaches an account other than the default. Reading it off `AgentKind` means a new runtime
arrives already covered. It is `String?`, because a login does not have to live in a directory:
Cursor's is in the system keychain, and pointing either `CURSOR_DATA_DIR` or `XDG_CONFIG_HOME` at
an empty directory still reports `authenticated`. Nil is the honest answer there, and it keeps an
inert invented name out of the one place this filter reads to decide what *not* to strip. What the terminal path adds on top of this — the colour and pager claims,
which are about a stream rather than a run — is in [`themes.md`](themes.md).

The MCP routing variables are the deliberate exception to stripping an inherited agent
identity: `AgentLauncher` creates them for the new child after filtering. They are per-process
routing, not inherited state from the parent.

Claude and Grok accept `--session-id <uuid>`, so the id is minted up front. Grok does not persist
that id while its first-login browser authentication screen is open, so `GrokSessionDiscovery`
polls the supported `grok sessions list` command and marks it resumable only after it appears.
Codex has no equivalent, so its id is read back from the `session_meta` record at the head of the
rollout file it writes under `~/.codex/sessions/`. OpenCode also assigns its own `ses_…` id; discovery polls
its supported `opencode session list --format json` command and selects the newest record for
the launching checkout. This intentionally avoids its private storage schema.

**A Threading-owned Codex terminal runs with `--no-alt-screen`.** Codex's default alternate
buffer deliberately has no terminal scrollback. It enables DEC alternate-scroll, but that mode
translates a wheel into Up/Down keys and Codex assigns those keys to composer history, not the
conversation transcript. On iPhone the visible frame therefore moved away to empty alternate-
buffer rows while the older conversation existed only in Codex's retained model. The CLI's
supported inline mode puts the rendered transcript in Threading's terminal-owned scrollback,
which is the same bounded record the Mac view and remote terminal protocol already mirror. The
flag belongs only to interactive terminal launches; native app-server and headless pipe transports
have no terminal buffer to configure. An already-running Codex process must be relaunched before
the launch contract can affect it.

**An identifier is not a conversation, so the resume branch asks the filesystem — and the
encoding it asks with is load-bearing.** Claude's id is minted before anything is written, so
`AgentLauncher` emits `--resume` only when `ClaudeTranscript.exists` finds the file and otherwise
falls through to a fresh `--session-id` launch. That fallthrough is only safe while the lookup is
right: relaunching with an id Claude has already used makes it exit 1 in under a second, and what
the user sees is a Resume button that does nothing, seven times in ninety seconds.

`ClaudeTranscript.projectSlug` is that lookup, and it had replaced `/` and nothing else. Claude
replaces **every character outside `[a-zA-Z0-9]`**, per UTF-16 code unit — measured, not inferred:
a folder named `slug probe_v1.2 åäö-🎉` is filed under `slug-probe-v1-2-------`, the astral scalar
contributing two dashes because it is two code units. Replacing separators alone is right for
`/Users/me/repo/thing` and wrong for everything else, and the wrongness is silent, because a
missing directory is indistinguishable from a session that never recorded anything. Every managed
workspace was in that state — they live under `Application Support`, and the space is not a
separator — along with any project folder carrying a dot, and `SessionImporter`, which had spelled
the same encoding a second time and so found nothing to import from those folders either. The
encoding now lives in `ClaudeTranscript` alone and `ClaudeTranscriptPathTests` holds the measured
cases.

The *directory* was never the bug: `AgentLauncher.plan` and `ProjectStore.executionProject` both
hand the transcript seam a `Project` copy whose `folderPath` is `session.workingDirectory(in:)`,
so a managed workspace is already addressed by the worktree it ran in rather than by the
repository it will merge back into. See [`managed-workspaces.md`](managed-workspaces.md).

**Claude, Codex, Grok and Cursor take the opening prompt as an operand, not a word.** The first two reject one that
begins with `-` before the session exists: Claude answers
`error: unknown option '- Make sure all tests are green'` and exits 1, Codex answers
`unexpected argument '- ' found` and points at the fix in its own message. A bulleted opening —
a list of things to do, one per line — is an ordinary thing to type into the composer, and it
killed the launch a third of a second in; the app then showed the dormant placeholder, and
selecting the row again relaunched *without* the prompt, which is what the user saw. So
`ShellCommand` keeps the prompt apart from the flags (`append(operand:)`) and emits it last,
after a bare `--`. Last matters as much as the `--`: `routed` appends the MCP flags *around*
the command, so terminating options where the prompt used to sit would have fed
`--mcp-config` to the CLI as more prompt text.

OpenCode's parser differs honestly: its opening is the value of `--prompt`, and a resume is
`--session <ses_…>`. Its optional model remains the provider-qualified OpenCode id passed to
`--model` (for example an OpenRouter model), not a new `AgentKind`.

**Cursor has no terminal contract, and that is the measurement rather than a gap.** Its
interactive CLI writes chats to `~/.cursor/projects/<slugified-cwd>/agent-transcripts/<uuid>/`
while `cursor-agent acp` writes `~/.cursor/acp-sessions/<uuid>/`, and neither store can read the
other's identifier: ACP answers `session/load` for a TUI chat with
`-32602 Session "…" not found`, and the TUI answers `--resume <an ACP id>` by opening a **blank
chat with no error at all** — measured against 2026.08.11-e8db854, with a TUI-created id resumed
in the same harness as the positive control. A surface switch is supposed to show one
conversation another way; here it would silently show a different, empty one. So
`AgentCapabilities.terminalUI` is the row Cursor does not have,
`AgentSession.resolvedNativeSurface` clamps its sessions to Native, and
`AgentLauncher.plan(for:in:)` throws `unsupportedTerminalConversation` rather than running a
command line that opens the wrong chat. Two smaller facts fell out of the same pass: its first
launch in any directory stops on a modal workspace-trust gate that ACP never raises, and its
prompt is an operand with the same leading-dash hazard as Claude's and Codex's
(`error: unknown option '- item one'`, fixed by `--`). The full record is §11 of
[the archived Cursor ACP measurements](../archive/research/CURSOR_ACP_FINDINGS.md).

Grok's terminal contract was measured against 0.2.118. A fresh TUI launch is
`grok --session-id <uuid> -- <opening>` and a later launch is `grok --resume <uuid>` with no
opening replay. Quitting its browser-login screen leaves the session fresh because the UUID is
not promoted until the public session list confirms it. `--model` is passed only when a session
has an explicit model; otherwise the live/custom catalog and `/model` inside Grok remain
authoritative.

**A reusable opening message is part of the first turn, not a turn on every launch.**
`AppSettings.newChatOpeningPrefix` and `newChatOpeningSuffix` are optional app-wide context
entered under Settings ▸ General, one field on each side of the task. `NewChatOpeningMessage`
trims all three parts, drops the empty ones, and joins what is left with one blank line in the
order prefix, task, suffix; `SessionCoordinator` hands the combined text through the existing
one-shot `pendingPrompt`, so a terminal launch keeps one trailing operand while a Native launch
sends the same string over its stream. Ordinary sessions, side chats (including a plain fork
with no question), cross-provider continuations, and sessions started from the paired owner
device all converge there.

Two fields rather than one because the halves are read differently: text before the task frames
how the work should be done, and text after it is an instruction about the answer — an order the
model reads as written, which no single field lets the user express without positioning the task
by hand. The suffix shipped first and keeps its original persistence key, `newChatOpeningMessage`,
so an instruction already stored survives the setting growing a second field.

The session title is still derived from the **per-chat task alone**. Otherwise one reusable
instruction would give every Codex chat the same prompt-derived title while waiting for the
agent to rename it — the opposite of what an instruction such as “give this chat a one-word
name” is for. Imports receive nothing because they are existing conversations, and resumes
receive nothing because the opening was already persisted in the provider transcript.

### Who owns the child processes

A natively rendered conversation is an ordinary child process with three pipes — no PTY, no
terminal. That made it the one launch path with nobody holding the other end when Threading
died: `AgentRuntime.terminateAll()` runs from `applicationShouldTerminate`, which a crash or a
`SIGKILL` never reaches, so the CLI reparented to launchd and stayed there — alive, unowned,
unreaped, holding a model conversation open, with nothing anywhere recording that it existed.

**PTY sessions are deliberately excluded, for as long as the app holds the master descriptor.**
SwiftTerm launches through `forkpty`, so that child already leads its own session with a
controlling terminal, and the kernel sends it `SIGHUP` when the master descriptor closes with the
app. The ending is already owned; a second mechanism over the top would only be a second thing to
get wrong. A PTY held open by the background host outlives the app on purpose, so the kernel owns
nothing there and that child *is* recorded — with `owner == .ptyHost`, which
`OrphanedAgentChildSweep.verdict` reads as `heldByHost` and skips before it probes the pid. The
record is there so a launch can name what is still running; the owner is what stops the same
launch killing it.

Three pieces close it for the native path, and all three are shared — there is no per-runtime
branch anywhere in them, because "this process is ours and it is still running" is not a fact
about which CLI is at the other end.

- **Its own process group.** `Process` cannot set one, which is the whole reason
  `AgentChildProcess` spawns through `ChildProcessSpawn` — `posix_spawn` with
  `POSIX_SPAWN_SETPGROUP` and a pgid of zero, the same primitive `ExtensionChildSpawner` was
  already built on. The child's group id is its pid, so `kill(-pid, …)` reaches it *and* the
  shells and subagents it started. Teardown signals the group: interrupting only the parent
  leaves a backgrounded fleet running, and teardown is reached for exactly when a fleet has run
  away. Closing stdin stays the first move on every transport that has one — Codex's app-server
  shuts down on end-of-input — so the group signal is the escalation, not the greeting.
- **Parent-side stdin cannot signal the app.** `AgentChildProcess` owns the writable end of every
  native child stdin pipe, so it applies `F_SETNOSIGPIPE` to that descriptor before exposing a
  `FileHandle`. This is descriptor policy, not ACP/Codex/Claude policy: a child may exit before
  initialization or between later writes under any of the three transports. A write then returns
  an ordinary failure (`EPIPE` through `FileHandle`) for the transport to settle; it must never
  deliver `SIGPIPE` to Threading's test host or shipping process. Failing to install that policy
  fails child construction. Early-exit and later-write process tests also pin one reap, one exit
  callback, and an empty ledger after settlement.
- **A ledger of what is live.** `AgentChildLedger` writes one small record per child under
  Application Support the moment it is spawned, and removes it the moment it is reaped. What
  survives a launch is whatever had not been reaped when it ended: after a clean quit, at most
  the children whose exit the app outran, all of them long gone by the time anyone looks; after
  a crash, the orphans themselves. The file cannot tell those apart and does not try — that is
  the sweep's job, and it is why the sweep verifies rather than assumes. The record carries the
  pid, the kernel's own start timestamp for it, the session id and the
  launched file's name — lifecycle facts, nothing about what was said. It is bounded
  (`maximumRecords`), written atomically through `RecoverableFileStore` at
  `.rebuildableCache`, and **missing, readable and unreadable stay three different answers**: a
  ledger nobody could read must never be acted on as "there were no children". Enrollment is
  part of launch, not telemetry after it: if the kernel identity cannot be read or the record
  cannot reach disk, `AgentChildProcess` terminates the new process group and throws. Letting the
  conversation run would create exactly the unowned child this layer exists to prevent.
- **A sweep at the next launch.** `OrphanedAgentChildSweep.run()` is called from
  `applicationDidFinishLaunching`, after `EventLog.beginLaunch()` — so it has somewhere to
  report — and before anything can start a conversation, because it decides by pid and a pid is
  only unambiguous while nothing new has been spawned. It sits below both the hosted-test
  bail-out and the single-instance lock: neither a test host nor an instance that lost the lock
  may signal processes it does not own. A verified orphan gets `SIGKILL` rather than the
  `SIGTERM` teardown uses — the grace period has already elapsed, however long ago the app died,
  and a deferred escalation would have to signal a group id whose leader may have been reaped
  in between.

**The pid is never enough.** macOS hands pids out again, so a record from a crash three days ago
may name a browser now. The sweep kills only on an exact match of the pid *and* the
`pbi_start_tvsec`/`pbi_start_tvusec` pair the kernel reports — microseconds included, because two
processes starting in the same second is ordinary at login. Everything else fails closed: a
start-time mismatch, an identity that could not be read, a process already gone, and an
unreadable ledger all mean *do nothing*, and every one of them is journalled to `EventLog`
alongside every kill. A sweep that quietly does nothing is otherwise indistinguishable from a
sweep that is broken.

Reading the start time immediately after `posix_spawn` is race-free for the same reason the
sweep needs it: a child is reaped exactly once, and until that reap the kernel cannot hand its
pid to anyone else. The reap itself is one `DispatchSourceProcess` and one `waitpid` on the
child's own serial queue, cancelling the source inside the handler — the arrangement the crash
of 22 July 2026 established, where a manual `waitpid` racing a still-registered source made
libdispatch treat `EV_VANISHED` as a fatal client bug.

**The background host is behind one hidden key, and it is off.** `AppSettings.ptyHostEnabled`
(`defaults write codes.threading ptyHostEnabled -bool true`) is registered in
`AppSettingDefinitions` with **no `presentations`**, so `remotePolicy` resolves `.hidden`: it
produces no Settings row and does not cross to the phone's settings mirror — the
`remoteViewportLeaseGraceSeconds` shape, reachable by `defaults write` and by a test. Off is §9
step 4 of `docs/feature-drafts/durable-sessions.md`, and there is a second, harder gate on top of
the rollout one. A launchd agent is **not** a supervised child of Threading, and macOS attributes
file access by directly spawned, supervised children (see [`permissions.md`](permissions.md)); the
one measured launchd datapoint in this repository is negative *and silent*. Whether an agent
spawned by `threading-ptyd` inherits Threading's grants is unanswerable on the machine the design
was written on, because `csrutil status` is disabled there and every arm of the experiment passed
trivially. Until that experiment has been run on a **SIP-enabled** Mac and the answer written into
`permissions.md`, defaulting this on risks agents that silently cannot read the user's files —
which reads to the user as the app breaking, not as a feature. Turning it on today still changes
nothing on its own: no session's PTY has moved yet. See [`pty-host.md`](pty-host.md).

### The sessions that come back on their own

Quitting with agents running keeps the records and loses the processes — that is the app's
premise — but it used to mean the next launch began as a sidebar of dormant rows, one resume
per click. `AppSettings.sessionRestorePolicy` (Settings ▸ General ▸ Startup) closes that loop:
`applicationShouldTerminate` records `AgentRuntime.runningSessionIDs` just before
`terminateAll`, and the next launch relaunches sessions in the background, so selecting one
attaches an agent that is already up instead of paying the resume on the click.
The rules, each of which is the answer to a way this goes wrong:

- **Every policy is a policy about a bound, and there are two of them.**
  `.runningAtLastQuit` (the default, and what the `restoresRunningSessions` toggle it replaced
  now migrates to) is bounded by evidence: the machine ran exactly those agents side by side a
  moment before the quit, so bringing the same set back returns it to a load it has
  demonstrably carried. `.recentlyUsed` is bounded only by `sessionRestoreLimit`, because a
  time window is not a bound — a heavy week is a heavy launch. Neither may become "every
  session in the sidebar": a store with forty dormant conversations must not boot forty CLIs at
  a couple of hundred megabytes each. `StartupSessionRelaunch.plan` also drops what was deleted
  or archived since, and orders most recently used first — the stagger means the last in line
  waits the whole line, so the session touched last goes first.
- **The window exists because the record is fragile, not because the record is wrong.** A
  reboot, a force quit, or a launch that erased the record (see below) leaves
  `.runningAtLastQuit` with nothing to bring back, and no later launch can recover it. Reading
  the conversations themselves survives all three, which is the choice a user who reboots often
  should have.
- **`.recentlyUsed` reads `AgentSession.lastUsedAt`, never `lastActiveAt`.** The runtime stamps
  `lastActiveAt` on launch and on exit, so a background relaunch marks every session it brought
  back as active today: a window read from it feeds itself its own last launch and never lets
  go of anything. Measured on a real store, the gap was days — seventeen sessions relaunched
  one morning read as active that morning while their transcripts had not been written to since
  the week before, and a three-day window selected all thirty-two sessions. `lastTurnAt` is
  stamped instead from the turn-start edge in `AgentSessionViewController`'s activity observer,
  which fires for a reported turn and an inferred one and cannot fire for a relaunch, and is
  coalesced through `ProjectStore.noteTurnStarted`. Records written before the field existed
  fall back to `lastActiveAt`, which is the second reason the limit exists: on the first launch
  after the update, the fallback makes every old session look recent, and the cap bounds that.
- **The record is consumed on read** (`StateManager.consumeRunningSessionIDs`), the same
  pattern as `EventLog`'s launch marker: only a clean quit rewrites it, so a list that
  outlived the launch that read it would relaunch sessions the user has since closed the
  first time that launch crashed. After a crash nothing auto-relaunches, which is the
  conservative direction. It is consumed even with the setting off, so enabling it later
  cannot act on a list from some earlier quit. `AppRelaunch.PreparedRelaunch.commit` skips the
  quit path deliberately — a reset comes back to nothing running.
- **Launches are staggered, one per `StartupRelaunchDefaults.staggerInterval`.** The
  expensive part of a launch is the agent CLI's own boot — a burst of CPU per process — and
  N of those fired together contend through the app's first seconds, which is also when
  `MainThreadStallMonitor` is already watching. Spread out, each launch's main-thread slice
  (the MCP config writes, building and laying out the surface) stays inside its own run-loop
  turn. The first launch waits a full interval too: that is the restored selected session's
  head start, and that session is excluded from the plan outright, because its own launch is
  a run-loop turn away and `hasTerminal` alone would race it.
- **A background surface is laid out at a real size *before* its PTY starts**
  (`TerminalContainerViewController.launchInBackground`). SwiftTerm clamps an unlaid-out
  grid to its 2×1 minimum rather than zero, so the deferred-launch gate — which waits for
  non-zero dimensions — passes, and `forkpty` takes 2×1 as the winsize: the agent's TUI
  boots into a two-column window. The frame used is the pane's own bounds, so the eventual
  attach is not even a resize.
- **Boot noise raises no flags.** Every launch before this one was made by selecting the
  session, so the activity tracker could assume boot output happens on screen. Unattended,
  the resume's repaint would read as a turn, go quiet, and land every restored session on
  `needsAttention` — one silent notification each. `noteUnattendedLaunch` grants a grace
  that ends at the first look or the first reported turn; see
  [`session-activity.md`](session-activity.md).

- **Closing the window is a quit, and takes the quit's path** (`MainWindowController`
  `windowShouldClose` asks the application to terminate and returns false). This is the bug
  the feature shipped with, and it made the whole thing look inert: `windowWillClose` called
  `AgentRuntime.terminateAll()`, and with
  `applicationShouldTerminateAfterLastWindowClosed` answering true, the close ran *before*
  the quit. `applicationShouldTerminate` then read an emptied runtime — so it warned about no
  running agents, killed a dozen mid-turn without asking, and recorded an empty list for a
  launch that duly relaunched nothing. Nothing in the plan above was wrong; it never received
  a candidate. Both close affordances (`WindowChromeButton`'s close role and the window
  menu's Close) consult `windowShouldClose` and close only on true, so a declined quit leaves
  the window untouched. `windowWillClose` keeps its teardown for a `close()` called in code,
  which never consults the delegate.
- **A launch that never read the record may not write over it.** The hazard is not a crash: an
  app opened and quit again inside a second — a rebuild-and-open cycle, a scripted launch, a
  second copy started by accident — relaunches nothing, has nothing running, and stamps "nothing
  was running" over the list the last real quit left. That is a permanent loss, because the
  record is the whole input to `.runningAtLastQuit`. It was found by reading a user's own
  journals: seventeen sessions live one evening, then about twenty sub-second launches the next
  afternoon, then those seventeen never came back and had sat dormant for two days.
  `StateManager.hasConsumedRunningSessionIDs` says whether this launch spent the record, and the
  quit writes an empty list only when it did (or when something really was running). The same
  hazard through the recovery door was already guarded; this is the ordinary-launch door. The
  `Quit` record carries `recordPreserved` so the two empty quits can be told apart.
- **A dormant row can say why it is dormant.** `StartupSessionRelaunch.Plan` carries a
  `SessionRestorationOutcome` for every unarchived session — restored, restore off, not running
  at the last quit, nothing recorded, outside the window (with when it was last used), or past
  the limit, or reattached from the background host — and `SessionRestorationLedger` holds them for
  the launch. The session hover card
  reads it under "Dormant · resumable" and names the settings page. Recorded rather than
  recomputed for two reasons: the answer belongs to the decision that was actually made, and a
  card built while the pointer rests on a row must not do work proportional to the whole store.
  The ledger forgets a session the moment it launches, because from then on its dormancy is its
  own agent's exit and the launch's reason would be a lie.
- **A session the background PTY host is still running is not a session to start.** With the
  hidden key on, a host-backed session is *detached* at the quit rather than terminated, so it goes
  on working while Threading is closed; `PTYHostReattach` asks the daemon what it is holding
  **before** `relaunchSessionsFromLastQuit` plans anything, and those ids leave the launch set with
  the outcome `.reattached` rather than `.restored`. Relaunching one would put a second agent on a
  conversation whose first never stopped. Three neighbouring answers fall out of the same list and
  are deliberately different: a child that *ended* while nobody was attached has its exit recorded
  and stays a dormant row, exactly as an in-process exit would have left it; a child held for a
  conversation that has since been deleted or archived is killed, because nothing can ever show it
  again; and a session a restarted daemon reports as `lost` is left to the ordinary relaunch, which
  resumes it from its transcript. With the key off — every launch until the TCC question above is
  answered — the whole step is decided on the calling turn without opening anything, so the plan
  and its ordering are exactly what they were. See [`pty-host.md`](pty-host.md#detach-and-reattach).
- **Both ends of the handshake are journalled**, because neither was, and that is why the
  above stayed invisible: the `Quit` record carries `runningSessions`, and the launch records
  `recorded` beside `relaunching`. The pair is what separates the three ways this comes to
  nothing — a quit that recorded none, a launch that read none, and a record whose only
  session was the selected one that `restoreSelectedSession` is already bringing back (the
  ordinary "recorded 1, relaunching 0", and the reason a one-session test of this feature
  looks like it did nothing).

Everything else is deliberately the ordinary machinery: the background launch uses the same
`AgentRuntime` caches and the same container delegate as a click, so the sidebar's dot, exit
handling and the eventual attach (`show` finds the surface cached and only attaches) cannot
drift from the selected path.

### The launch after a crash asks before it opens anything

`EventLog.beginLaunch` has always known that the previous launch died — its marker was still
lying there — and nothing consumed the fact. So the launch after a crash did what every other
launch does: reopened the previously selected session and ordered every detached browser window
back on screen. Both of those run *because the app started*, which is the wrong reason when the
last start ended by dying: the session that comes back may be the one that took the app down,
and it comes back silently, so the user's only evidence is the app dying a second time.

`EventLog.PreviousLaunchOutcome` is the fact, typed. `.clean`, `.unclean(crashReport:)`, and
`.unknown` — and *unknown* is load-bearing rather than a third way of saying nothing: no marker
**and** no journal is a machine the app has never run on, which is a first launch with nothing
to restore, not a crash worth mentioning. It replaced a `Bool?` that meant three things at three
call sites. `previousLaunchEndedCleanly` is now derived from it, because
`MacSupportReportDetails` reports the same fact in that older shape.

Two orderings inside `beginLaunch` are load-bearing:

- **The outcome is read before the retention sweep.** A missing marker is either "quit cleanly"
  or "never ran here", and only a surviving journal separates them, so the question has to be
  put while the evidence is still on disk. Pruning first, a machine left alone for longer than
  the fortnight retention window came back reporting that the app had never run on it.
- **The marker is consumed on read**, which it already was. That is where the one-shot lifetime
  comes from: nothing new is written down to give the notice one, and there is no new persistent
  state anywhere in this feature.

`LaunchRestorationPlan` maps the outcome onto what a launch may bring back, and
`LaunchRestoration` runs it. The split from `AppDelegate.restoreSelectedSessionIfReady` is
deliberate: the gate still decides **when** — `mcpServerHasStarted && !isOnboardingActive` — and
this decides **how much**. Hanging the offer off that same gate is also what keeps the notice out
of the three places it must never appear, none of which ever reach it: the onboarding walkthrough
(which defers the main window), the hosted test bundle (which returns before startup), and an
instance that lost the single-instance lock (which terminates above it). The actions are closures,
so the decision is tested without a window, an MCP listener or a store.

**The relaunch of the sessions that were running at the last quit is deliberately not part of the
decision.** It is already crash-safe by construction, for the reason recorded above: the record is
consumed on read by the launch that then crashed, so after a crash there is nothing left in it to
fire. Suppressing it here would instead hold back the ordinary case — a clean quit with agents
running — which is not what the notice is about. It also stays unconditional so that a list
written under one setting cannot fire under a later one.

The notice is `PaneNoticeView`, put up by `MainWindowController.presentUncleanExitNotice` through
`TerminalContainerViewController.showNotice` — a band between the pane's header and its content,
which **pushes** the content down rather than covering it. A band and not an alert: a launch that
stops to ask a question asks it before the user has asked the app for anything, and what it would
be asking about is the *previous* launch, so nothing is waiting on the answer. Restore performs
exactly the two calls that were held back, in the order `run` would have made them — the selected
session first, so the detached windows it brings with it are not built twice. The report is
*revealed* in the Finder rather than opened, because an `.ips` opens in Console and what someone
filing a bug needs is the file, ready to attach; the action is absent entirely when macOS filed
nothing, which is the ordinary case for a kill or a power loss.

**Two answers carry the band, and the reveal trails them.** Restore and Send to Developer are both
`secondary`; Show Crash Report is `tertiary` and sits last. Sending the report was tertiary too at
first, behind the Finder reveal, which read as a footnote to the one action on the band that only
helps if it is pressed — nothing about a crash reaches the developer unless someone presses it,
while revealing the file is the rarer, more technical thing to do with it. Neither of the two is
`primary`: a band that appears unasked has no claim on the screen's one primary action, which is
`PaneNoticeAction`'s default and the rule the whole component is built on.

The offer is one-shot **per launch**, held in memory on the `LaunchRestoration` instance. The gate
can fire twice in one launch (the walkthrough re-run from Settings ▸ Advanced finishes and asks
again), and a second run restores in full rather than holding the same workspace back again with
nothing on screen to say so.

Deliberately not here: a recovery mode, and any decision this file makes about repetition. A
launch after a crash is one held workspace and one band, and an interrupted prompt is never
resubmitted. Crashes *are* counted now, one layer down and without changing what this does:
`LaunchLedger` records how far each launch got and `CrashLoopPolicy` reads the run of them, and
the only thing that reaches here is which of two sentences the band carries
(`UncleanExitEscalation`). See [`persistence.md`](persistence.md).

A restart the user asked for is no longer one of the crashes. The reset flows leave without the
quit path, so the marker survived them and Reset Settings — which does not move the support
directory — read as an unclean exit here: held workspace, crash notice, for a button the user had
just pressed. `PreviousLaunchOutcome.intentional` restores in full and says nothing.

### Startup speed, per runtime and per conversation

Fast already had two per-conversation delivery mechanisms and no app-wide starting decision.
That gap mattered most for Codex: a user's `service_tier = "fast"` was inherited by every
Threading session, so the only way to stop paying for it was to change the account's own config
or switch each Native chat after it had started. Terminal Claude had the mirror-image hole: the
session record could hold `fastMode`, but only the Native control channel ever read it.

`AgentStartupSpeed` is the app-wide, per-runtime policy: **Agent's Setting**, **Standard**, or
**Fast**. Its two keys are deliberately unseeded. An absent or unrecognised value resolves to
Agent's Setting and writes no provider override, preserving every existing installation's
behavior. The other two remain explicit all the way to the provider: Standard is `false` for
Claude and `service_tier="default"` for Codex, because omission would immediately inherit an
account configured for Fast again.

`AgentLauncher.fastModeAtStartup` is the one resolution order: the conversation's persisted
`AgentSession.fastMode`, then `AppSettings.startupSpeed(for:)`, then nil. A per-conversation
choice therefore survives a later default change; a conversation that never chose follows the
current default on its next launch or resume. Grok and OpenCode have no measured Fast mechanism,
so the settings store returns Agent's Setting and the resolver returns nil for them rather than
letting a future runtime borrow another provider's key.

The opening draft and Native reply composer expose that persistence as the same three rows:
**Follow General Setting**, **Standard**, and **Fast**. The first is a real stored choice, not an
alias for whatever General says today; it remains nil so a later General change still reaches the
conversation. An immediate draft carries the optional value through the composer delegate into
`ProjectStore`, and `ScheduledSessionPlan` freezes it beside model and effort for a delayed start.
The chip title resolves the inheritance chain so it says what the chat will use, while the menu
still marks whether that answer is inherited or pinned.

Delivery covers both surfaces:

- Claude writes `fastMode` into the same per-session `--settings` JSON as its hooks and Remote
  Control on both Terminal and Native launches. The file is still written when hooks are off or
  the listener failed, because dropping an explicit Standard/Fast choice due to an unrelated
  telemetry failure would undo the user's setting. Native restates the value through
  `apply_flag_settings` once the stream is ready, keeping the live process aligned with the
  launch layer. A known non-Opus model is forced Standard rather than letting Claude's Fast
  setting silently switch away from an explicit model choice; an unnamed model honours Fast
  because the user's speed choice is the only answer available.
- Codex maps the resolved value onto the launch configuration for both its TUI and app-server.
  Fast also enables `features.fast_mode`; Standard sends the explicit `default` service tier.
  Native per-chat changes continue to ride `turn/start`, so they take effect on the next turn
  without restarting the app-server.

The reply chip's effective reading follows the same precedence (conversation, app default,
account/catalog, runtime fallback) — and it now *asks* `AgentModels.effectiveFastMode` rather than
restating three of its four steps. The two disagreed about the fourth: Claude's fast mode is a
live control-channel flag that starts off, so an unpinned Claude conversation is a known
**Standard** — which `effectiveFastMode` had always resolved and the chip reported as "Agent's
Setting". The account's own `fastMode` key is read through the same settings layers as the
permission mode, so a login that turned fast mode on for itself is no longer reported as Standard.
Only an unreadable Codex service tier — one that is neither Fast nor Standard — still has no name
to show. Choosing Follow General can apply an explicit General
Standard/Fast value through the same live or next-turn channel as a pinned value. If General is
Agent's Setting, there is no provider-neutral live reset operation; the record returns to
inheritance, a notice says that the running speed is unchanged, and the provider setting takes
over on the next start. The General setting remains a startup policy: changing it does not rewrite
a running session out from under an in-flight turn.

### Permission mode, per conversation

How much a session may do before it stops to ask, chosen in the composer, overridable from a
session's `⋯` menu, defaulted in Settings ▸ General. `AgentPermissionMode` owns the whole
translation; `AgentLauncher.permissionMode(for:)` resolves session → app default → nil.

**The whole translation, including which flags each runtime takes.** `launchFlags(for:)` returns
the `AgentLaunchFlag` values for one mode on one runtime; the launcher appends whatever it gets
back and knows nothing else about the mapping. That dispatch used to be a `switch session.kind`
in the launcher choosing among the per-runtime value properties here, which meant two files had
to agree and nothing said so — a runtime could be given its value property and no launcher
branch, or a branch naming the wrong axis, and both compiled. `AgentCapabilitiesTests` now holds
three invariants the split arrangement could not express: a runtime produces flags exactly when
it claims `.permissionModes`, every flag is well-formed, and a runtime that splits the idea
across independently-defaulted axes states *all* of them for *every* mode. Values are still
asserted where they always were — against the tokenized launch line in
`AgentPermissionModeTests`, which is the only place that proves the CLI receives them.

This surface is capability-gated to Claude, Codex, and Grok. Grok accepts the same six values
through `--permission-mode`, except that Threading's Manual is spelled `default` on its wire.
OpenCode's `opencode.json` has a richer
per-tool permission policy, and its `--auto` flag is not equivalent to any of the six modes;
Threading therefore shows no mode control and leaves OpenCode's configuration untouched.

**One vocabulary, Claude's**, because it is the only CLI that names a mode rather than a pair of
axes. The six and what they mean are read out of the CLI (2.1.220) rather than assumed — its
fallback table is one function, and it is not the one you would guess:

```js
if (mode === "auto")              return "classify";
if (mode === "bypassPermissions") return "allow";
if (mode === "dontAsk")           return "deny";
                                  return "ask";
```

**`dontAsk` denies — it does not approve.** It promises never to interrupt you and keeps the
promise by refusing the call and telling the model. Filing it with `bypassPermissions` as "the
dangerous two" is the obvious mistake; they are opposites that share a symbol in Claude's UI.
Note also that Claude's internal name for Manual is `default`, while the value its `--help`
documents and the flag accepts is `manual`.

| Mode | Claude `--permission-mode` | Codex approval / sandbox / reviewer |
|---|---|---|
| Manual | `manual` | `untrusted` / `read-only` / `user` — must ask to change anything |
| Plan | `plan` | `never` / `read-only` / `user` — reads, writes nothing, never interrupts |
| Accept Edits | `acceptEdits` | `untrusted` / `workspace-write` / `user` — edits in place, commands still gated |
| Auto | `auto` | `on-request` / `workspace-write` / `auto_review` — **Auto (Approve for me)**; a reviewer agent answers eligible boundary crossings |
| Don't Ask | `dontAsk` | `never` / `workspace-write` / `user` |
| Bypass Permissions | `bypassPermissions` | `never` / `danger-full-access` / `user` |

Six modes onto six *distinct* Codex configurations, which is what makes one shared vocabulary
honest rather than a menu with duplicate rows. Codex has a third independent axis beyond the
approval policy and sandbox: `approvals_reviewer`. Threading states it for every explicit mode so
a persistent Auto-review setting cannot silently turn Manual into automatic review. Auto is the
one provider-specific title — **Auto (Approve for me)** — because it deliberately selects the
reviewer agent. The sandbox still carries most of the remaining meaning: Manual and Accept Edits
share an approval policy and differ only there. Codex has no plan concept, so Plan is only the
enforceable half — the menu says so rather than implying parity.

**Nil is a third state, not "off".** It emits no flag, leaving Claude's `permissions.defaultMode`
and Codex's `config.toml` deciding — the same reasoning as `remoteControl` above, and the same
trap: a mode written to mean "no opinion" would override a config the user set deliberately, on
the one axis where being wrong either nags them all day or stops asking when it should not have.
The native Codex transport is the one exception: unstated, it keeps its fixed
`--sandbox workspace-write`, because a natively rendered session that inherited a read-only
`config.toml` would stop being able to edit and would say so only through failing tools.

**Threading honours the mode in its own broker too, because the CLI does not honour it for us.**
Measured: `PreToolUse` fires under `bypassPermissions` and `dontAsk` exactly as under `manual`.
So a natively rendered session in Bypass would still have been stopped by Threading's own sheet —
the app contradicting the mode chosen inside it. `PermissionPolicy.standingDecision(for:in:)`
answers for the three modes that promise something (Bypass allows, Don't Ask denies, Accept Edits
allows file changes and still asks about commands) and returns nil for Manual, Plan and Auto,
which are enforced inside the CLI and promise nothing about the sheet. Being wrong there costs an
extra question rather than an unasked-for action.

**The record is the launch mode, not a live mirror.** Changing the mode on a running terminal
session restates nothing — the flags belong to the process. The broker is the exception, since it
is ours: it re-reads the store on every call. Claude does expose a `set_permission_mode` control
request on the stream transport (present in the binary beside `set_model`), so live switching on
the native surface is a clean follow-on rather than a rewrite.

**A chip that inherits still names a mode.** Nil is a third *state*, but "Agent's Setting" was a
bad *label*: a control whose whole job is to say what the session will do, answering with the name
of a place to go and look. The chips now resolve the same way the model chip already did
(`ResolvedDefaultModel`) — name the value, qualify where it came from, and fall back to a generic
label only when no source can name one. `ResolvedPermissionMode` is that chain, in order of
authority:

1. `AppSettings.defaultPermissionMode`, which *becomes* the launch flag and so outranks the rest.
2. The runtime's own configuration. `ClaudeSettings.permissionMode` reads `permissions.defaultMode`
   across the CLI's four layers (managed → `settings.local.json` → project `settings.json` → the
   account's), first-match-wins, sharing one layer list with `ClaudeStatusLineSettings`. Codex
   states the same posture through approval, sandbox and reviewer values, so
   `AgentPermissionMode(codexApprovalPolicy:sandboxMode:approvalsReviewer:)` inverts the table
   above — exactly, never to the nearest mode. Approval and sandbox must be present; an omitted
   reviewer means Codex's documented `user` default. Consequently the ordinary
   `on-request`/`workspace-write` Auto preset is not misreported as **Approve for me**. Grok's
   `config.toml` states none of the six and OpenCode's policy is per-tool, so both answer nothing.
3. `ObservedPermissionMode` for this conversation, from memory only — `refreshConversationControls`
   runs per streamed event, so the background re-read stays with the surfaces that own one. Passed
   **only while the agent is running**, because that is the whole of what this source claims: the
   posture in force now. Past the exit it describes a process that is gone.
4. `ClaudeAccountLastRunPermissionMode`: the newest `permission-mode` record in this login's newest
   transcript. Evidence, not configuration, and marked `(last used)` rather than `(default)` for
   the same reason `ClaudeAccountLastRunModel`'s answer is.

**The first two state the next launch; the last two only report one, and the difference decides
what the app may do with the answer.** `Source.governsNextLaunch` is that line — an app-wide
default *becomes* `--permission-mode`, and the runtime reads its own configuration itself, while
nothing replays a mode out of a transcript. It shipped without the distinction and the failure was
the expensive direction: `PermissionModePresentation.rows` marks the inherited mode as the row
meaning *inherit*, which answers `nil`, and it was marking a **remembered** one. Choosing Auto in
the composer therefore recorded no choice, the launch line carried no flag, and the session started
in the CLI's own fallback — `{"permissionMode":"default"}` in its transcript — while the chip above
it read Auto. Fixed on both halves, and it is the fail-closed reading of each:

- Only a governing answer collapses into the inherit row. A report is an ordinary row that keeps
  its `(last used)` qualifier and **pins** the mode when chosen, and inherit gets its own
  "Use Agent's Setting" row beside it.
- Only a governing answer, or a posture a *running* agent is in, may title a chip
  (`ResolvedPermissionMode.nameableMode`). Where all that is left is a remembered mode, the chip
  says the agent decides and the tooltip still names what it last decided on.
- `AgentSession.permissionMode` decodes through its raw string, so a mode name a later build
  invents reads as "chose none" instead of throwing away the whole session record. Nothing then
  reaches the launch line, and the runtime asks before acting.

**One value is source-restricted, and the exception is load-bearing.** `auto` may be granted only
by a layer a repository cannot write — measured against 2.1.228, which *drops the key* rather than
falling through, so a project file's `auto` also discards the user's own mode. A reader that fell
through to the layer below would report a posture the session will not run in.

**The unset case is why step 4 exists — as a qualifier, not as a promise.** With no layer stating a
mode, the CLI chooses between `default` and `auto` on a server-side gate (`tengu_harbor_willow`,
plus an interactive-session test that `--print` fails). That is not a file, so it is not predicted:
on the machine this was written against, thirty-eight of forty recent transcripts had resolved to
`auto` while every settings file was silent and Claude's own settings screen would have said
`default`. Hard-coding `default` would have been wrong on every one of those forty sessions, so the
remembered mode stays — it names the row the user most likely wants and says where the name came
from. What it no longer does is *title* a chip, because the same gate answered `default` for the
session that found this bug: a thirty-eight-in-forty estimate is a good default to offer and a bad
posture to assert, and the two readings differ exactly when the app would be promising more access
than the launch will take.

**Reading the live posture back is a different question, and Claude answers it.** A terminal's own
Shift+Tab still tells Threading nothing, but Claude writes each assertion of the posture into the
session's transcript as `{"type":"permission-mode","permissionMode":…}`, so what a session is
*in* can be observed even though it cannot be set. `ObservedPermissionMode` is the seam every
reporting surface asks — never the record, since a posture read off a stale launch flag is the
one fact where being confidently wrong costs the most — and
`AgentCapabilities.transcriptPermissionModeRecord` is what a runtime claims to join it. Claude
only today; Codex, Grok and OpenCode record nothing equivalent and therefore report nothing. The
values that come back are Claude's own, `default` for Manual included, which is why
`AgentPermissionMode(externalValue:for:)` exists beside the flag values it inverts. See
[`git.md`](git.md) for the surface that shows it.

### Claude's Remote Control, per conversation

Claude Code has its own bridge to claude.ai and the Claude mobile app — unrelated to Threading's
Remote Access, which is this app's own server. It is normally an account-wide switch
(`/config` ▸ "Enable Remote Control for all sessions"), and Threading narrows it to one
conversation.

**Through the settings file, not a flag.** There is no `--no-remote-control`: the CLI offers
`--remote-control [name]` to opt *in* and nothing to opt out, and no environment variable
(measured against 2.1.220 — the `CLAUDE_CODE_REMOTE_*` variables all concern cloud-side
sessions). What it does read is `remoteControlAtStartup` from merged settings, ahead of its
global config:

```js
function i3o(){ return TI()?.settings.remoteControlAtStartup ?? Rt().remoteControlAtStartup }
```

So the value joins the per-session settings file Threading already writes and already passes as
`--settings` (`MCPSessionRegistry.writeHookSettings`). Nothing else had to change in the
command line, and because both Claude launch paths rewrite that file, the choice re-applies on
every **resume** rather than only on the launch that made it — which a `--settings` argument
assembled once would not have done. Verified with `claude doctor`, which validates the key
from a `--settings` path and rejects a non-boolean.

**Three states, twice.** `AppSettings.claudeRemoteControl` is the default for new sessions and
`AgentSession.remoteControl` is one conversation's override, and both distinguish *off* from
*no opinion*. Only an absent key defers to the user's own `/config`; writing `false` to mean
"we have not decided" would silently override a choice they made in the CLI, so `nil` survives
from the setting all the way to the JSON rather than collapsing into a boolean anywhere on the
way. `AgentLauncher.remoteControlAtStartup(for:)` is the one place the two are resolved.

The one asymmetry worth knowing: the settings file is written even when the MCP listener has
no port. Losing the hooks costs accurate activity reporting, but dropping the key would
connect a conversation the user had switched off, and that must not depend on whether an
unrelated listener came up.

Threading cannot display what "follow" resolves to — the value lives in the account's own config
and an unset one resolves server-side — so the inherit menu item says *Use Claude's Setting*
rather than naming a value it would be guessing.

### The background PTY host, per conversation

An agent session's pty can live in `threading-ptyd` — a per-user daemon that owns the `forkpty`
child, its output ring, its window size and its exit status, and owns nothing else — instead of in
this process. The point of moving it is that a process the app does not own can outlive the app.
The whole design is [`pty-host.md`](pty-host.md); what belongs here is the choice and what it
costs.

**Three states, twice, again.** `AppSettings.ptyHostEnabled` is the hidden global — no
`presentations`, so it produces no Settings row and does not cross to the phone's settings mirror;
`defaults write codes.threading ptyHostEnabled -bool true` is how it is turned on — and
`AgentSession.backgroundHost` is one conversation's override. `PTYHostPolicy.hostsSession` reads
session, then global, then off, and `nil` survives to the JSON rather than collapsing into a
boolean, so a record written before the field existed reads as "no opinion". It ships **off**: the
question of how macOS attributes file access for a launchd agent's children has not been answered
on a SIP-enabled Mac, and until it is, an agent under the daemon might be an agent that cannot
read the user's files.

**Version 1 hosts agent sessions only.** Not project terminals, not shell drawers, not ephemeral
terminals — those poll `tcgetpgrp` on a descriptor a host-backed session does not have, and the
`foreground` frame that replaces it is wired up for the one surface that has been measured. There
is **no `AgentKind` capability** for this and there must not be: whether a session has a pty is
already `kind.supports(.terminalUI)`, and host-backing is a fact about the surface rather than a
static fact about a runtime.

**Nothing else about the session changes while it is attached.** The same
`EmojiFixedTerminalView` renders the same bytes — a render test compares the two paths pixel for
pixel — activity still counts `onOutput`'s bytes, OSC 0/2 titles still arrive through the emulator,
`shellPid` still comes back from the daemon so the working directory and the process inspector go
on answering, and the remote mirror still taps `onOutputBytes` where it always did. What is
*absent* is the pty descriptor: `foregroundIsAnotherProgram()` and the title's owner read the
daemon's pushed `foreground` frame instead of `tcgetpgrp`.

**Until reattach lands, stopping a host-backed session kills it.** There is no way to hand one
over yet, and an agent still working in a session no surface can reach is worse than one that
ended. Every way the host can be unavailable — off, not installed, not running, the wrong version
— is an ordinary in-process launch and one journal line saying which.

## Close and Archive

Two row actions that read as near-synonyms and are near-opposites. **Close** acts on the
process: the agent stops, the terminal is released, and the row stays in the sidebar to be
resumed. **Archive** acts on the record: the row moves out of the sidebar into
Settings ▸ Archived, and the conversation content is untouched either way.

There is deliberately **no third thing between them** — no settled shelf, no snooze, nothing that
files a row away on a timer. The case for one, and why the answer here is a presentation-only
filter over the activity marks rather than another lifecycle state, is
[`docs/decisions/automatic-settling.md`](../decisions/automatic-settling.md). One rule from it is
worth carrying at this level: nothing derived may reach `ProviderArchiveSync`. Archive stops a
process and mutates provider state, and it happens because a person or a finishing agent's own
handshake asked for it.

### The provider archive boundary

Archive is provider-backed only where the capability matrix says the runtime exposes a
**reversible** retained-conversation archive. `AgentCapabilities.providerArchive` belongs to Codex:
its `archive` / `unarchive` commands move rollout files between the account's `sessions/` and
`archived_sessions/` stores. Claude Code and Grok expose resume and destructive delete surfaces,
but no archive operation. OpenCode is the subtler non-capability: its UI and session PATCH can set
`time.archived`, while the current public CLI has only list/delete and the PATCH schema offers no
way to clear that timestamp again. A one-way archive is not Threading's Archive/Restore contract;
its record therefore stays local too. Archive must never be translated into Delete, and Undo must
never claim to restore a provider state it cannot reach. The capability check is the seam —
lifecycle code does not rediscover provider identity.

`ProviderArchiveSync` owns all four mutation routes: sidebar/Undo, Settings ▸ Archived, remote
access, and an agent-requested archive. A Codex action is atomic from the user's perspective: the
agent is stopped first when needed, the account-routed provider command runs, and only success
commits `isArchived`. Failure leaves the retained flag unchanged and is surfaced to the initiating
UI or remote caller. Local-only runtimes pass through the same service and commit immediately.
`AgentAccountRouting` is shared with `AgentLauncher`, so both the default account's explicit
`env -u CODEX_HOME` and an alternate account's `CODEX_HOME=<path>` remain identical for launch and
lifecycle commands.

Changes from another Codex client are reconciled at launch and each
`NSApplication.didBecomeActiveNotification`. The synchronizer batches filesystem reads per
account, locates the recorded UUID in the active and archived rollout trees without opening
transcript bodies, and ignores missing or ambiguous observations rather than guessing. Each
session persists `lastSynchronizedArchiveState` as the base of a three-way merge:

- when only the provider differs from the base, its external action is mirrored into Threading;
- when only Threading differs, its retained action is pushed to Codex;
- when both already agree, that value simply becomes the new base;
- on the first observation, where chronology is unknowable, archive-if-either wins. Archive is
  reversible, while silently resurfacing a conversation is the surprising migration.

Successful background changes emit `SessionArchivedStateDidChange`, which refreshes every window
and clears a pane whose current session was filed elsewhere. The synchronized write is batched in
`ProjectStore.synchronizeArchiveStates` so one activation produces one save and one store change
notification rather than one of each per session.

**Archiving implies closing.** The sidebar lists only unarchived sessions, so an archived
session that kept its agent would be a process nothing lists and nothing can stop — the bug
this rule closed: the sidebar's Archive once flipped the flag and left the agent running
invisibly, while the remote archive route had discarded the process from the start. Both
routes now enter the same synchronizer, which stops the agent first. Restoring implies nothing;
a session comes back dormant.

**Archiving does not ask. It acts, says so, and offers the way back.** It carried a registered
confirmation for as long as the interruption was the only thing that could be said about it,
and that alert stopped everyone who meant it in order to catch the one who did not — twice a
day for anybody who files chats away as they finish. Nothing archiving does is beyond reach:
the row comes back, the conversation resumes by the same id, and the only thing genuinely lost
is the turn in flight, which is what closing costs too. So the surface moved to the other side
of the action. `SessionCoordinator.archiveToast` builds a receipt carrying the three facts the
alert used to ask with — which session, that its agent stopped, and that it is now in
Settings ▸ Archived — plus **Undo**, and the sidebar floats it above its own footer for six
seconds (`ToastPresenter`, see [design-system.md](design-system.md)).

The undo restores the record and puts the row back. It re-selects the session only if the
archive took it *off screen*, since undoing a stray click must not move somebody off what they
were doing; and it does not relaunch the agent, because archiving stopped it exactly as closing
does and starting a process is a heavier thing than a click being taken back. The session
returns dormant, with Resume on its placeholder.

For a provider-backed archive, “took it off screen” is decided when the provider command commits,
not when that potentially slow command began. A newer sidebar selection owns the pane and an older
archive completion must not replace it with the empty state. The lifecycle event may already have
cleared the archived page before the initiating coordinator receives completion; in that case the
sidebar's still-selected session identity is the evidence Undo uses. If selection already names
another session at that commit, neither the completion nor its Undo may move focus back.

`ConfirmationPrompt.archiveRunningSession` was removed rather than left switched off: a case
nobody asks still ships a Settings row for a question that no longer exists. The line the
register now draws is written beside the remaining lifecycle cases — **a prompt is right where
the way back is a different action the user has to know to take, and wrong where the way back
can be handed to them.**

The other actions that interrupt a running agent — close, move to another account, continue
with another provider, and the surface switch — still confirm, and each states its own
consequence, because "where does the session go" is exactly what the verbs fail to say. Each is
a registered `ConfirmationPrompt` with a switch of its own. They were one setting,
`confirmsBeforeClosingRunningSession`, and that setting was wrong for exactly the reason their
alerts exist separately: someone tired of being asked about one had to stop being asked about
the others too. `AppSettings` carries a stored `false` from the old switch over to them on first
launch; cross-provider continuation arrived later and has no legacy value to migrate — see
[design-system.md](design-system.md) for the register itself.

Applicability stays here rather than in the register: each also requires
`AgentRuntime.isRunning`, because a dormant session has nothing to interrupt, which is a fact
about the session and not a preference about the prompt.

### The session that archives itself

"Commit this and then close the session" is one instruction, and the second half of it used to
be the user's to carry out after the agent had finished the first. `archive_session` is that half
— an MCP tool in the **Session lifecycle** group that files away the session the call arrived on.
The session is not an argument: the MCP URL carries the identity (see
[`mcp-and-display.md`](mcp-and-display.md)), so an agent can end its own conversation and no
other.

**The delay is the feature.** Archiving stops the agent, and an agent stopped inside its own tool
call never receives the result of that call — the process dies mid-turn, the user loses the answer
they were waiting for, and the last thing on screen is a half-written reply. So the tool arms
`SessionArchiveScheduler` and returns at once, the agent writes its final message as usual, and
the archive lands `SessionArchiveDefaults.settleDelay` after the turn ends. Which is also the only
order in which the instruction reads the way it was said.

**The turn's end is the app's existing answer to "is it finished".** The scheduler watches
`SessionActivityDidChange` and fires on the edge out of `hasTurnInFlight` — the same edge the
attention notifications already treat as a finished turn. For a session whose agent reports its
own boundaries that edge is the agent saying so; for one still on the output heuristic it is a
guess, and this is no better or worse than everything else built on that guess (see
[`session-activity.md`](session-activity.md)). Two rules follow from the guess being fallible: a
session that goes quiet and starts writing again *disarms* the settle rather than being archived
mid-turn, and a request that never becomes due is dropped after
`SessionArchiveDefaults.requestExpiry` rather than being spent on some later, unrelated turn —
which is the one way this could archive a session nobody asked it to. `cancel_session_archive`
takes a pending request back; it deliberately cannot un-archive a session that has already gone,
because that way back belongs to the user, on the receipt.

**The receipt says who acted, and holds longer for it.** `agentArchiveToast` is the same band as
the clicked archive with two differences, and both come from the same fact: nobody clicked
anything. It names the agent — a row that leaves the sidebar on its own is the one report where
"what happened" without "who did it" is the wrong half of the sentence, and the name is also the
only part saying this was not a misclick — and it carries the agent's own one-line reason, which
is the only thing on the band the user cannot work out for themselves. It holds for
`ToastDefaults.unattendedDwell` instead of six seconds, because the six are measured from a click
and the user has been reading something else since they asked for this. The Undo is identical:
same action, same restore, same rule about re-selecting only what was on screen — and where two
of these land close together, the second band waits for the first rather than replacing it. An
agent that files two sessions away in one turn owes the user two ways back, not the later one;
the queue and its bound are `ToastPresenter`'s (see [`design-system.md`](design-system.md)).

Nothing about the archive itself differs — `SessionCoordinator.archiveAtAgentRequest`, the row,
Settings, and remote access all hand the state change to `ProviderArchiveSync`, so the agent's
route cannot quietly grow a second set of rules about provider state, stopping the process, or
emptying the pane. The scheduler stays in Core and knows nothing about sidebars: it announces
`SessionArchiveRequestDidBecomeDue`, and the coordinator that already owns every other lifecycle
decision observes it directly rather than having the window controller relay it back down.

### Manager is a role, and supervision is the lineage

The project composer offers `Chat` and `Manager` as roles, but the stored session remains the same
`AgentSession` in both cases. Starting a manager creates the ordinary session and confers a durable
project grant before launch, so its first MCP initialization sees the correct catalogue. **New
Manager…** is the preset path; an existing row can be given or stripped of the same role through
**Make Manager** / **Revoke Manager Role**. Only user-authored commands confer authority, and
revocation leaves the conversation intact.

`Supervision` — manager id, child id, brief, assignment, state and outcome — is distinct from
`forkedFrom` and `ConversationHandoff`. It means **who is currently responsible for this chat**,
not where the transcript came from. Spawn creates it atomically with the child; adoption attaches
an existing project chat; release, archive, completion and manager revocation close it without
rewriting history. Its bounded `SupervisionEvent` stream is the recovery record after manager
context compaction or application relaunch.

The user-visible surfaces all project that record. A manager row and its pane header carry the
quiet group role mark; the hover card says how many chats it manages. A child hover card says
**Managed by …** and shows the brief, but the sidebar does not decorate every child. Selecting a
manager adds the host-owned **Chats** tab, whose virtualized rows read the supervision store rather
than the manager transcript. Moves leave a dismissible PaneNotice with Undo, and manager-archived
children retain **by <manager>** attribution in Settings ▸ Archived. Lifecycle notices in either
transcript are Threading-framed; a brief written by the manager keeps the cross-session provenance
header.

**Customization boundary.** The manager mark and start-composer presentation remain inside the
existing `sidebar.session-row@1` and `composer.session-start@1` component shells, so extensions may
still use those contracts' established properties and protected slots. The **Chats** tab,
Make/Revoke commands, Tools and Advanced grant controls, and Archived attribution are deliberately
host-only: they display or mutate effective authority, and allowing replacement could conceal a
grant, misstate who performed an action, or remove the user's revocation path. Threading retains
grant issuance and revocation, scope and refusal decisions, supervision lifecycle, audit
provenance, confirmation, and navigation even where the surrounding row or composer presentation
is customizable.

Targeted archive is the same delayed `SessionArchiveScheduler` operation described above, now
authorized against the child and refused while it is working. Because that refusal means the child
has already settled when the request is recorded, the scheduler begins the settle grace from its
current state; it does not wait for a future activity edge an idle child may never produce. A child
that starts again during the grace disarms the timer and is archived only after that later turn
ends. Targeted rename still protects a title the user wrote. Resume is native-chat only — a dormant
terminal may open on a prompt that requires the user, so it cannot be woken unattended. Spawn
reuses `ScheduledSessionPlan`, including managed-workspace delivery and permission-mode caps,
rather than defining another launch vocabulary.

**Continuation lineage is a durable path, not a launch-mode bit.** A side chat's `forkedFrom`
points at a provider-native child that can resume the same transcript semantics. A cross-provider
session instead owns a `ConversationHandoff`: ordered provider/model endpoints ending at itself,
including stable Threading session ids and title snapshots. `continuedFrom` and
`continuationSourceKind` remain computed compatibility views of the direct source, and the encoder
continues to write their old keys so older builds can still read a new two-hop record.

Repeated handoffs extend the path rather than replacing it. It is capped at sixteen endpoints;
compaction retains the origin and newest suffix and records the exact omitted count. The native
conversation renders a compact **Context handoff** divider, the sidebar hover card wraps the
retained full path, and the divider's direct source endpoint navigates when that row still exists.
Deleting or renaming an ancestor cannot rewrite provenance: each destination owns its frozen copy.

The context snapshot is provider-neutral too. Claude/Codex transcripts are reduced through
`TranscriptReplay`; Grok uses its documented `grok export`; OpenCode uses its documented
`opencode export` JSON. Visible dialogue and bounded tool context are retained, private reasoning
is omitted, and a continuation handed off again prepends the prior normalised snapshot while
dropping the bootstrap/history-tool exchange that transported it. The result is capped at one
million characters and stored under the destination id. The snapshot belongs to that destination
row and is removed with it (or its project), so a future launch can regenerate the same bootstrap
without depending on a mutable source transcript.

The character budget is not trusted as a byte budget. The durable handoff envelope is encoded and
refused above 8 MiB, and reopened through the same bounded reader. An oversized current-format file
does not become “no context”; legacy provider snapshots may still take the streaming
`TranscriptReplay` compatibility path, which never requires a whole-file allocation. Provider
exports are likewise read through a 32 MiB result ceiling, with only the final 64 KiB of stderr
retained for a visible failure.

Delivery follows runtime capability. Claude/Codex Terminal and all native Chat surfaces read
pages from the session-scoped `conversation_history` tool. OpenCode receives the JSON snapshot as
its documented `--file` attachment. Grok Terminal, whose TUI offers no ephemeral MCP registration
or file flag, receives the newest bounded context inline. This is the only deliberately lossy
transport; the durable snapshot and lineage remain complete within their stated bounds.

**Deleting asks whatever the session is doing**, which is what separates it from everything
above: they keep the session, and this one is the row itself going — the case a toast could not
serve, because there would be nothing left to undo it with. It shipped for a long time
with no confirmation at all, beside a Close that had one — which read as Delete being the
lesser of the two. Its sheet says what survives, because "Delete" reads as the conversation
going with the row and it does not: the CLI's own transcript stays on disk and can be imported
again. Removing a *project* does not route through `removeSession`; it discards its sessions
itself under its own single confirmation, so nothing asks twice.

**Quitting with agents running asks too, and that prompt is suppressible**, because a session
outliving its terminal is the premise of the whole app: the conversations are kept and resume
on the next launch, so quitting is nearer to closing a session than to deleting one, and only
the turn in flight is lost. Two guards matter. It stays quiet when nothing is running — a
confirmation on every quit would be asking about nothing most of the time, which is how a
prompt teaches people to dismiss it. And it stays quiet when the *system* started the quit:
`applicationShouldTerminate` is the same entry point for Cmd+Q and for a logout, restart or
shutdown, and a modal on the second path is what makes macOS report "Threading prevented
logout". `AppDelegate` reads `NSWorkspace.willPowerOffNotification` for that rather than the
quit Apple Event's reason — one documented name, where a subtly wrong descriptor keyword fails
silently in the direction of blocking a shutdown.

**The `⋯` menu reads in groups, and the set-once items fold.** It had grown to seventeen
top-level items with a twelve-item unbroken run in the middle — every conditional item just
appended — so `populateSessionActions` now states its groups: lifecycle (Pin, Archive, Close),
side chats, appearance and conduct, identity and housekeeping (Rename, the Copy fold,
sharing, account moves, continuation), then Delete, with Extensions always last
(`RowExtensionCommandMenuTests` pins that).

**The Copy fold gathers what is needed *elsewhere*, and it copies two ids under two names,
never one under a fallback.** "Copy Session ID" used to copy `externalIdentifier` — the
agent's transcript id where one existed, Threading's own `SessionID` otherwise — so the
string on the pasteboard meant a different thing on different rows, invisibly. **Copy ▸**
(`sessionCopyEntry`, a pure builder tests call with resolved inputs) now holds **Agent
Session ID** (the transcript id, absent rather than disabled until the agent has named the
conversation), **Threading ID** (`AgentSession.threadingIdentifier`, the lowercased
`SessionID` every app-side surface — settings file, MCP route, history file, extension
context, journal — is keyed by), **Worktree Path** (the project's `folderPath`, which is
exact: a session has no per-checkout override — routing to another worktree files it under
that checkout's *project*), and **Transcript Path** (`SessionTranscript.url(for:in:)`,
resolved at build because presence is the decision — the same cost `moveToAccountEntry`
already pays through `canMigrate` — and absent for runtimes without a reader). For Claude and
Grok the two ids are the same string because Threading mints the id; Codex and OpenCode name
themselves, and the Threading id is the one that survives `Continue with…` and account moves
intact. A standalone terminal carries the same fold — its `TerminalID` and the owning project's
worktree path, resolved on the click so a project move cannot leave an already-open menu stale.
Theme and Permission Mode stay top-level because
they are reached for repeatedly; what folds behind **Session Options** is what is set once and
left alone — Interface, Claude Remote Control, Mute Notifications, Attachments. Three details
are load-bearing: the fold's members carry their own targets, because the builder's retarget
loop walks only the top level; an absent group folds its separator away rather than leaving two
in a row (`addGroupSeparator`); and the toolbar's Context button gave up its "Session Options"
tooltip so the fold's name means one thing.

All of this lives in `SessionCoordinator`: the row menu once discarded the process itself,
skipping the confirmation the same action asked for as Cmd+W, which is why the sidebar
delegates lifecycle decisions instead of touching `AgentRuntime` directly. The requests are
built separately from being asked so tests can hold their wording to what the action does
(`SessionLifecycleConfirmationTests`).

## Session Import

`SessionImporter` discovers conversations started outside Threading by reading the transcripts
the CLIs already keep, so a session can be adopted into a project and resumed by id.

**The offer follows the discovery, and fades in.** The composer's import button is a picture of
`importable`, so nothing can change what was found without the row saying so. A scan takes a
couple of seconds, which means the button arrives under a pane the eye has already stopped
moving over — switched on at full strength it reads as a blink beside the send, so the arrival
is a `Design.Motion.standard` fade. Withdrawal is not: every route that takes the offer away —
another project, a scheduled edit borrowing the slot — has already replaced what the rest of the
row says, and fading a stale count out over it would be the offer lingering after it stopped
being true. That also leaves the button's resting opacity at full, which is what the only
animation here ends at, so an arrival interrupted by anything at all still settles where it
belongs and there is no generation to track.

Reading these files has two traps, both of which cost real coverage before they were fixed:

- **Never cap a record read at a fixed byte count.** A Codex `session_meta` line carries the
  project's instructions, so it runs to tens of kilobytes and grows with `AGENTS.md` — a 16 KB
  cap silently skipped 62% of rollouts, because a truncated line is not parseable JSON. Read
  until the record ends, and bound the *scan*, not the record.
- **The opening turn is not near the top.** Codex writes telemetry (`token_count`,
  `agent_reasoning`) ahead of the conversation, and compaction pushes the first user turn
  further still — past 500 KB in ordinary sessions. `forEachRecord` therefore streams and lets
  the caller stop, so the usual file costs one chunk while a buried turn is still found.

**A transcript's modification date is not when its conversation happened.** Both CLIs write
bookkeeping into transcripts long after the fact — Claude re-appends `last-prompt` and
`bridge-session` records, none of them timestamped, and a launch rewrites them across a whole
directory at once — so mtimes collapse onto whenever an agent was last started rather than
spreading out over when people were talking. The sheet showed this project seven conversations
reading "4 min ago", sorted above one another by nothing: their last real turns were eight to
nine hours apart and exactly one was live. `SessionImporter.lastActivity` reads *backwards*
from the end for the newest record that carries a timestamp, which is both the right answer and
a cheap one — the bookkeeping is precisely what has no timestamp, and 273 of this project's 276
Claude transcripts answer within 7 KB of the end (the deepest Codex rollout, 220 KB). The scan
is bounded by `ImportDefaults.activityTailLimit` and falls back to the modification date, so a
transcript with nothing stamped in its tail is not read to the top. Onboarding's whole-disk
scan reads it the same way, where the value also decides what starts pre-checked.

**One row per conversation, not per copy of it.** A conversation moved between logins exists
under both accounts and is found under both: 13 of this project's were offered twice, identical
but for which copy had been written to last, and both rows resume the same transcript.
`SessionImporter.deduplicated` keeps the newest, run over the list already sorted, so the
surviving row belongs to the account whose copy has the most in it. Identity is
`ImportableSession.id` — kind and transcript id — the same rule `GlobalSessionScan.grouped`
dedupes on; the per-project path simply had no equivalent.

**The sheet adopts several at once, and a selection outlives a search.** Rebuilding a project's
history means taking a search's worth of conversations at a time, so the table takes multiple
selection and `ProjectStore.importSessions` writes them in one save — one notification, one
sidebar reload, which is what keeps a large import from stuttering. The chosen ids are held by
the controller rather than by the table, because `reloadData` selects nothing: search, take,
search again, take more, and the earlier choices are still there. What that costs is a
selection the current query can hide, so the Import button carries the count — it is the only
thing on screen saying that six conversations are about to be adopted when one row is visible.

**What is still not offered: Grok and OpenCode.** `discover` scans every
`TranscriptReplayFormat`, currently Claude and Codex, so a Grok conversation
(`~/.grok/sessions/<url-encoded cwd>/<id>/`) cannot be adopted by any path in the app, and neither
can an OpenCode session. Both runtimes are otherwise first-class, and both keep their
conversations behind boundaries this local replay format does not claim — Grok's listing is a CLI
command rather than a directory of transcripts, while OpenCode's supported export currently
feeds usage accounting rather than conversation replay.

Titles prefer the provider's retained name: Claude's `ai-title`, or Codex's account-wide
`session_index.jsonl`. The first real user prompt is the fallback, read from Codex's
`event_msg`/`user_message` — *not* the `user`-role messages, which replay the CLI's own
instruction blocks. A transcript with no user turn is not offered at all even if an index name
exists: Codex writes a rollout for its approval reviewer against the same project directory, and
those are machine turns nobody can meaningfully reopen.

**A chat is attributed by which worktree it ran in, not by a raw path.** Every transcript
records the directory it launched in — Codex's `session_meta.cwd`, and Claude's per-record
`cwd` (the project-slug directory name is a *lossy* encoding, since two different paths can
slug alike, so the recorded path is the authority). `belongs(cwd:folder:worktree:)` resolves
that path to its worktree via `GitInfo.worktreeIdentity` and admits it only when it is the
project's folder, or a subdirectory *of the same checkout*. This is what keeps a worktree
nested inside the folder — the common `<repo>/.git`-adjacent layout, e.g.
`sonda/.claude-worktrees/SONDA-348` — *out* of the parent project: it is a separate checkout
with its own git directory, on its own branch. The equal-path case, which is almost every
rollout, is settled without touching disk. This mirrors how opencode anchors a session
(`rev-parse --git-dir` vs `--git-common-dir`), read off disk rather than by shelling out.

**The sheet is searchable by identifier, and every row wears one.** A busy project offers
hundreds of conversations whose titles are the agent's own summaries of itself, so three of them
beginning "Refactor the" is the ordinary case rather than the pathological one — and the id is
the only thing about a past conversation that is exact. When something else already named the
conversation (a hook's log, a `--resume` in a shell's history, another window), the reader is
holding an id and nothing else; before this the sheet had no way to accept one. Matching is
`contains` over the whole id, so a fragment copied out of the middle of a path works too.

The row shows `ImportLayout.identifierLength` characters of it, in a column of its own down the
trailing edge — git's eight, and a column rather than a tail on the detail line so the eye can
skip it entirely and then, when the query *is* an id, read straight down it. A fixed prefix is
the obvious implementation and is wrong on its own: matched in the middle, the row would come
back with nothing highlighted, which reads as the sheet having found it for some other reason.
So the window slides to the match and says so with a leading ellipsis. The matched run is drawn
by `SearchMatchLabel`, whose "a query containing the whole line marks all of it" rule is what
makes eight shown characters answer honestly to a pasted thirty-six-character query.

Verify against disk rather than by eye — `~/.codex/sessions/**/*.jsonl` and
`<claude config>/projects/<slug>/` are the ground truth, and both are cheap to count. The
worktree rules resist real data (no subdirectory-launched chats exist here) so they are proven
against a built layout — main + nested + sibling worktrees — rather than only observed.
