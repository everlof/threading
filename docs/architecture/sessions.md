# Sessions

Side chats, the shell drawer, naming, launching, resuming and importing.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

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
pasting a conclusion into the parent as a message, which is not built. And the first turn
replays the whole copied context, so forking a large conversation costs real tokens.

## The Shell

A shell is **not a kind of session**. It was one for most of this project's life — a sidebar row
beside the chats, with a title, a launch record, a branch field and an account slot it could
never use — for something with no conversation to resume, no transcript, nothing to import and
no scrollback that was ever persisted. Every one of those fields was a hole, and the code around
them was a run of branches saying *not for shells*: in the launcher, the replayer, the account
discovery, the usage service, the brand icons, the migration.

It is now a **drawer under the conversation** (`ShellDrawerViewController`, ⌃`), which is what
it always was in practice: a place to run a command *about* the conversation you are reading.
`AgentKind` is down to `.claude` and `.codex`, and `supportsResume`, `supportsAccounts` and
`supportsNativeUI` collapsed to `true` — that is the measure of how much of the model existed to
describe the absence.

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

Three decisions worth keeping (they predate the tabs and survived them):

- **It opens where the agent is**, not where the session started. A terminal session reports its
  directory over OSC 7, so `TerminalSession.effectiveWorkingDirectory` is asked at the moment the
  shell starts — an agent that has spent ten minutes inside a subpackage hands its shell that
  subpackage. The project folder is the fallback, which is also exactly right for a natively
  rendered conversation: no PTY to ask, and the CLI was launched there anyway. The container
  injects this as the drawer host's `directoryProvider`, since only it can ask the PTY.
- **It takes the session's resolved profile** (`ThemeAssignments.profile(for:)`) — the same call
  the agent's own terminal makes — so a themed session's drawer matches the surface above it.
- **The process is the feature.** A shell starts on first reveal (a drawer never opened costs
  nothing — and "revealed" means on screen, so fixtures never spawn one), survives session
  switches, and ends with its *tab* or its session. A shell that forgot its directory and
  history on every switch would be worse than the terminal beside it.

The pane is not a split view: the conversation fills it and the drawer is a strip taken off the
bottom, always installed and zero-high when closed, so every session surface pins its bottom to
the drawer's top and opening one is a change of constant. A split view would have brought its own
collapse behaviour, delegate and priorities, all of which would need arguing out of the way.

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
half-written prompt off the screen with it. A composer comes back through
`TerminalContainerViewController.restoreComposer`, which makes the existing composer visible
again rather than re-configuring it for the project — `showComposer` resets the agent, account,
model and checkout, and drops attachments, which are deliberately not drafts (see
[`persistence.md`](persistence.md)). Only what the chips *derive* is re-read
(`refreshDerivedState`), because Settings is exactly where those defaults change.

## Session Names

**A session is never named after its agent or account** — the row's icon slot and account chip
already carry both facts, so "Claude Code 2" as a name repeated them while saying nothing about
the conversation. `SessionNaming` holds the rules; three names remain, resolved by
`displayTitle`:

1. `customTitle` — an explicit rename, which wins and stops following the agent
2. `agentTitle` — the agent's own name for the conversation, by whichever transport last
   reported it: the terminal title while a PTY is attached, or the transcript's title records
   read when the session stops working — which is what names a *native* session and what
   survives a surface switch. Retained after the agent exits. (Stored under the old
   `terminalTitle` key, so existing records decode unchanged.)
3. `title` — derived from the **first prompt** (first line, capped): set at creation when the
   composer has the prompt, or by the first `UserPromptSubmit` hook report for a prompt typed
   straight into the terminal. Empty until then; the display falls back to "New Session".

Claude records both kinds of title in the transcript as different record types, measured
across this machine's transcripts rather than assumed: `ai-title` is the CLI's own name,
re-appended every turn (so the *last* one is current, and `SessionNaming` reads the file's
tail rather than scanning the conversation); `custom-title` is written by `/rename` — after a
mid-conversation rename both keep being appended, interleaved, so *presence* of a custom
title decides, not order. Codex records no title at all; its sessions keep their prompt name.

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
toolbar's page tab, and project and checkout rows all draw through `MorphingTitleLabel`. Two
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

## Launch and Resume

```
Select session → AgentLauncher.plan() → login shell → cd <project> && exec <agent>
                                                              ↓
                          agent exits → PTY torn down → session marked dormant
                                                              ↓
                  row stays in sidebar → select again → resume by agent session id
```

Launches go through a **login shell** because a GUI app does not inherit the user's
interactive `PATH`, and the agent CLIs live in `~/.local/bin` or a Node prefix.

Claude accepts `--session-id <uuid>`, so the id is minted up front. Codex has no equivalent,
so its id is read back from the `session_meta` record at the head of the rollout file it
writes under `~/.codex/sessions/`.

**The opening prompt is an operand, not a word.** Both CLIs take it as a trailing positional
argument, and both reject one that begins with `-` before the session exists: Claude answers
`error: unknown option '- Make sure all tests are green'` and exits 1, Codex answers
`unexpected argument '- ' found` and points at the fix in its own message. A bulleted opening —
a list of things to do, one per line — is an ordinary thing to type into the composer, and it
killed the launch a third of a second in; the app then showed the dormant placeholder, and
selecting the row again relaunched *without* the prompt, which is what the user saw. So
`ShellCommand` keeps the prompt apart from the flags (`append(operand:)`) and emits it last,
after a bare `--`. Last matters as much as the `--`: `routed` appends the MCP flags *around*
the command, so terminating options where the prompt used to sit would have fed
`--mcp-config` to the CLI as more prompt text.

**A reusable opening message is part of the first turn, not a turn on every launch.**
`AppSettings.newChatOpeningMessage` is optional app-wide context entered under Settings ▸
General. `SessionCoordinator` trims it and appends it after the task with one blank line, then
hands the combined text through the existing one-shot `pendingPrompt`: a terminal launch keeps
one trailing operand, while a Native launch sends the same string over its stream. Ordinary
sessions, side chats (including a plain fork with no question), cross-provider continuations,
and sessions started from the paired owner device all converge there.

The session title is still derived from the **per-chat task alone**. Otherwise one reusable
instruction would give every Codex chat the same prompt-derived title while waiting for the
agent to rename it — the opposite of what an instruction such as “give this chat a one-word
name” is for. Imports receive nothing because they are existing conversations, and resumes
receive nothing because the opening was already persisted in the provider transcript.

### Permission mode, per conversation

How much a session may do before it stops to ask, chosen in the composer, overridable from a
session's `⋯` menu, defaulted in Settings ▸ General. `AgentPermissionMode` owns the whole
translation; `AgentLauncher.permissionMode(for:)` resolves session → app default → nil.

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

| Mode | Claude `--permission-mode` | Codex `--ask-for-approval` / `--sandbox` |
|---|---|---|
| Manual | `manual` | `untrusted` / `read-only` — must ask to change anything |
| Plan | `plan` | `never` / `read-only` — reads, writes nothing, never interrupts |
| Accept Edits | `acceptEdits` | `untrusted` / `workspace-write` — edits in place, commands still gated |
| Auto | `auto` | `on-request` / `workspace-write` — the model decides when to ask |
| Don't Ask | `dontAsk` | `never` / `workspace-write` |
| Bypass Permissions | `bypassPermissions` | `never` / `danger-full-access` |

Six modes onto six *distinct* Codex configurations, which is what makes one shared vocabulary
honest rather than a menu with duplicate rows. The sandbox carries most of the meaning: Manual
and Accept Edits share an approval policy and differ only there. Codex has no plan concept, so
Plan is only the enforceable half — the menu says so rather than implying parity.

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

**The record is the launch mode, not a live mirror.** A terminal session's own Shift+Tab is
invisible to Threading, and changing the mode on a running session restates nothing — the flags
belong to the process. The broker is the exception, since it is ours: it re-reads the store on
every call. Claude does expose a `set_permission_mode` control request on the stream transport
(present in the binary beside `set_model`), so live switching on the native surface is a clean
follow-on rather than a rewrite.

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

## Close and Archive

Two row actions that read as near-synonyms and are near-opposites. **Close** acts on the
process: the agent stops, the terminal is released, and the row stays in the sidebar to be
resumed. **Archive** acts on the record: the row moves out of the sidebar into
Settings ▸ Archived, and the conversation is untouched either way.

**Archiving implies closing.** The sidebar lists only unarchived sessions, so an archived
session that kept its agent would be a process nothing lists and nothing can stop — the bug
this rule closed: the sidebar's Archive once flipped the flag and left the agent running
invisibly, while the remote archive route had discarded the process from the start. Both
routes now stop the agent first. Restoring implies nothing; a session comes back dormant.

Every action that interrupts a running agent — close, archive, move to another account,
continue with another provider, and the surface switch — confirms, and each states its own
consequence, because "where does the session go" is exactly what the verbs fail to say. Each is
a registered `ConfirmationPrompt` with a switch of its own. The original four were one setting,
`confirmsBeforeClosingRunningSession`, and that setting was wrong for exactly the reason their
alerts exist separately: someone tired of being asked about archiving had to stop being asked
about closing too. `AppSettings` carries a stored `false` from the old switch over to those four
on first launch; cross-provider continuation arrived later and has no legacy value to migrate
— see [design-system.md](design-system.md) for the register itself.

Applicability stays here rather than in the register: all five also require
`AgentRuntime.isRunning`, because a dormant session has nothing to interrupt, which is a fact
about the session and not a preference about the prompt.

**Continuation lineage is not provider lineage.** A side chat's `forkedFrom` points at a
provider-native child that can resume the same transcript semantics. A cross-provider session's
`continuedFrom` instead records which Threading row supplied a frozen handoff, with
`continuationSourceKind` retaining the decoder even if the source row is later deleted. The
snapshot belongs to the destination row and is removed with it (or its project), so a future
launch can regenerate the same bootstrap without depending on a mutable source transcript.

**Deleting asks whatever the session is doing**, which is what separates it from the four
above: they keep the session, and this one is the row itself going. It shipped for a long time
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
side chats, appearance and conduct, identity and housekeeping (Rename, Copy Session ID,
sharing, account moves, continuation), then Delete, with Extensions always last
(`RowExtensionCommandMenuTests` pins that). Theme and Permission Mode stay top-level because
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

Reading these files has two traps, both of which cost real coverage before they were fixed:

- **Never cap a record read at a fixed byte count.** A Codex `session_meta` line carries the
  project's instructions, so it runs to tens of kilobytes and grows with `AGENTS.md` — a 16 KB
  cap silently skipped 62% of rollouts, because a truncated line is not parseable JSON. Read
  until the record ends, and bound the *scan*, not the record.
- **The opening turn is not near the top.** Codex writes telemetry (`token_count`,
  `agent_reasoning`) ahead of the conversation, and compaction pushes the first user turn
  further still — past 500 KB in ordinary sessions. `forEachRecord` therefore streams and lets
  the caller stop, so the usual file costs one chunk while a buried turn is still found.

Titles come from the record that holds only what the user typed: Claude's `ai-title`, and
Codex's `event_msg`/`user_message` — *not* the `user`-role messages, which replay the CLI's
own instruction blocks. A transcript with no user turn is not offered at all: Codex writes a
rollout for its approval reviewer against the same project directory, and those are machine
turns nobody can meaningfully reopen.

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

Verify against disk rather than by eye — `~/.codex/sessions/**/*.jsonl` and
`<claude config>/projects/<slug>/` are the ground truth, and both are cheap to count. The
worktree rules resist real data (no subdirectory-launched chats exist here) so they are proven
against a built layout — main + nested + sibling worktrees — rather than only observed.
