# Subagents: chats that start chats of their own, on any provider

> Status: **phases 0–2 implemented 2026-10-18**; phases 3 and 4 remain. The durable decisions
> now live in [`control-plane.md`](../architecture/control-plane.md#subagents-delegation-without-a-grant)
> (authority, admission, report-back, lifecycle, the mail-first rule, every archive closing a
> tenure) and [`sessions.md`](../architecture/sessions.md#subagents-nest-the-same-way-under-their-own-agents-mark)
> (lineage and nesting). This draft keeps the research and what is still to build;
> [What shipped differently](#what-shipped-differently) lists where the implementation departed
> from the design below.

Extends [`control-plane.md`](../architecture/control-plane.md) (authority, delivery, agent mail),
[`sessions.md`](../architecture/sessions.md) (side chats, supervision lineage, launch) and the
[forks and asides draft](conversation-forks-and-quick-asides.md), whose provider-neutral lineage
this draft shares rather than duplicates.

## The problem

An agent in Threading cannot hand part of its work to another agent unless the user first
makes it a **Manager**. `spawn_session` is grant-derived (`ControlOperation.spawnSession` exists
only in `managerOperations`). An ordinary chat can list, message, steer and watch its project's
other chats, and archive or rename itself, and nothing else.

That conflates two relationships:

- **Managing** is responsibility for *other* chats in the project. The user confers it, and it
  reaches chats the manager did not start: it can adopt them, move their accounts, archive them
  and resume them.
- **Delegating** is a chat starting a helper for *its own* task: "have Codex review this diff",
  "let Claude write the migration while I keep going on the API". The helper is part of the
  parent's work. It needs no reach beyond itself, and the user should not have to hand out the
  wider authority to get it.

The provider-native answer, Claude's Task tool or Codex's own subagents, stays inside one
provider and one transcript. The point here is the other provider. A Threading subagent is a
**real chat**: its own `AgentSession`, on any runtime that can take a brief, visible, resumable,
and steerable by the user.

A second problem surfaced in the same investigation: agents still put their words straight into
other chats as user turns, although agent mail exists. Every surface that teaches an agent how to
reach another chat names `send_to_session` and none names `mail_send`:

| Surface | Where |
|---|---|
| MCP decision prefix | `MCPToolCatalog.swift` `decisionPrefix` |
| "Other sessions" group instruction | `MCPToolCatalog.swift` `authoredWorkspace` |
| `list_sessions` footer | `AgentToolCoordinator+WorkspaceCommands.swift` |
| Dragged-row brief | `SessionReference.swift` (`SessionReferenceBrief`) |
| Send Result to Parent | `SessionCoordinator.swift` (`askAgentToReportBack`) |

Since mail shipped (2026-10-03), Claude transcripts on the development Mac show **316
`send_to_session` calls against 217 `mail_send`**. Codex called neither. Subagents need a way to
report back, so this draft settles the channel first.

## What shipped differently

- **Native chat only.** The design admitted Codex terminals, and Claude terminals once
  measured. Report-back reads the reply a native transport captures, and a terminal's arrives
  only through hooks that not every runtime sends. So `admitSubagent` refuses a terminal plan
  (`subagentNeedsNativeChat`). Terminals are a phase 3 candidate once their Stop hook reports
  `last_assistant_message` reliably.
- **No mail for a turn without a reply.** The design mailed a one-line outcome ("stopped at its
  usage limit"). Mail's vouched header attributes every body to the sending agent, and that
  line would be the host's words under the subagent's name. Those edges are `watch_session`'s
  to report, and the tool says so.
- **A subagent's insertion is not incremental.** The design said the sidebar's fast append
  path would widen. A subagent is nested, and the append path places a row at the project's
  own level, so its insertion takes the project-structure path a side chat takes.
- **Undo is this run's.** The cascade restores what a parent's archive took during the same
  app run. A restore from Settings ▸ Archived after a relaunch restores the parent alone.
- **The archive toast does not yet count subagents** ("and 2 subagents"); phase 3.
- **The open questions were settled as recommended:**
  - user-typed turns are not mailed;
  - subagents are archived with their parent;
  - one level deep;
  - on by default, switched off in Settings ▸ Tools ▸ Subagents;
  - named "Subagent", with `SubagentChatDefaults` beside the providers' own `SubagentDefaults`.

## Product contract

1. **Any chat may start a subagent** in its own project, on any runtime that can take a brief
   unattended, without a grant. The user can switch this off per app in Settings ▸ Tools, like
   any other tool group.
2. **A subagent is a chat, nested under its parent.** It gets a sidebar row below the parent's,
   like a side chat. Unlike a side chat it keeps its **own agent mark**: a fork must run its
   parent's agent, but a subagent need not, and the mark is the one thing about it that differs.
   The hover card says *Subagent of …* and shows the brief.
3. **The parent's authority over it is narrow.** It can start it, message it, steer it, watch it,
   and archive it once settled. It cannot move the subagent's account, adopt chats it did not
   start, or reach anything a regular chat cannot. The user can open, type into, stop or archive
   a subagent like any other chat.
4. **Results come back as mail, in the subagent's own words.** When a turn the parent asked for
   completes, Threading stores the subagent's final reply as mail *from the subagent's mailbox*
   to the parent's. The parent is told mail is waiting and reads it with `mail_inbox`, under the
   header Threading vouches for. The child does not have to remember to report.
5. **Bounded mechanically**, not by prompt:
   - at most four live subagents per parent;
   - one level deep: a subagent cannot start subagents;
   - a start rate per parent;
   - the parent's permission mode as a ceiling;
   - the user's account limits and the parent's curfew apply at admission.
6. **Lifecycle follows the parent.** Archiving a parent archives its subagents with it, and
   Undo restores them together. Archiving a subagent ends the parent's responsibility for it.
7. **Agent-to-agent messages are mail.** `send_to_session`, which puts the body into another
   chat as a user turn, remains for the case where the *user* asked one chat to hand another a
   turn.

Not in scope: managers' `spawn_session` children stay top-level. A manager coordinates peers,
which is the distinction this draft draws. A row-less, one-shot "ask another agent" tool is a
separate, later phase ([Phase 4](#phase-4--a-row-less-one-shot-ask)) with its own measurements.

## What exists, and what it does not do

Research summary, so the design below can be checked against it.

**Spawn machinery is reusable.**
- `SupervisionCommandService.spawnSession` → `SpawnChildChoices` (Phase 0) →
  `ScheduledSessionPlan` → `SessionCoordinator.spawnSupervisedSession` →
  `startSessionUnattended` → `launchInBackground(sessionID:initialPrompt:)`.
- It rolls back the row and the supervision record when the launch fails.
- Admission is `WorkspaceControlPlane.admitSpawn`. It checks the stored grant, the 8-child cap,
  the permission and workspace-delivery caps, the caller's own limit, curfew and an optional
  `SpendCeiling`. There is no spawn rate limit and no depth check. Recursion is prevented today
  only because children never receive grants.

**Lineage is Claude-only and lives in the provider configuration.**
- `forkedFrom` is computed from `AgentSessionConfiguration.claude(…, origin: .forked(parent))`.
- The decoder refuses a fork parent on any other runtime.
- It persists inside the `session.data` JSON (key `forkParent`). Adding a field to `AgentSession`
  costs no SQL migration, and unknown keys are ignored by older builds.

**The sidebar already nests.**
- `attachSideChats` (`SidebarOutlineNodes.swift`) builds `SessionNode.childNodes` from
  `forkedFrom`, recursively.
- A missing parent leaves the row at project level, and a cycle is refused.
- `SessionRowView.applyAgentIcon` swaps the provider mark for `arrow.triangle.branch` because "a
  fork necessarily runs its parent's agent". That reasoning does not hold for a subagent.
- The incremental insert path requires `forkedFrom == nil`, and removal requires no children.
  Anything else rebuilds the project node.

**Supervision is the responsibility record, and it does not require a grant.**
- `Supervision {managerID, childID, brief, state, outcome}` and its bounded event stream are
  durable (SQLite v4/v5).
- A unique index enforces one active supervisor per child.
- `ControlGrantStore.adopt` checks only that invariant and the cap; the grant check lives in its
  callers in `WorkspaceControlPlane`. A parent that holds no grant can therefore hold a tenure.
- `subscribe_to_children` notices carry activity edges only, never content.
- `SupervisionEventKind.reportReceived` is declared and rendered but never emitted.

**Mail cannot be authored by the host, but can carry an agent's words on its behalf.**
- `MailboxKind` is `worker | session | person`, so there is no host mailbox.
- `mail_inbox` attributes every message to the sending agent.
- `MacMailDelivery.storeUndeliverable` already sends from a session with that session's text.
- An idle native chat receiving a notice starts a turn (`acceptAppMessage` → `.handedToTurn`).
  So mail saves the body and the weaker provenance, not the turn.

**A turn's final reply is already captured, but not kept.**
- `CompletedTurnSnapshotStore` keeps it in memory, generation-gated, up to 64 KiB.
  - Terminal: from the hook's `last_assistant_message`.
  - Native: from a completed `.turnFinished`.
- Its only consumer is the iPhone push preview, and it is lost on relaunch.
- `TranscriptReplay.latestAssistantTexts` reads the same thing back from Claude and Codex
  transcripts.

**The iPhone sees no lineage.** `RemoteSessionSummaryDTO` has no parent, fork or supervision
field, and the mobile dashboard groups flatly by project.

**Authority persistence has a downgrade trap.**
- A stored grant stores its exact operations as JSON. An older build decoding an unknown
  `ControlOperation` raw value marks the row corrupt and puts the whole store into
  `.recoveryRequired`.
- `managerOperations = Set(allCases)`, so any new case is persisted in every Manager grant
  conferred afterwards.
- `upgradeManagerRoleIfNeeded` recognises only the exact pre-`respondToPermission` set, so
  today's 16-operation grants would not gain a new case.
- `ControlGrantStore.isManager` treats any stored grant carrying a non-regular operation as a
  Manager.

**The decision prefix is full.** With every group on it measures 511 of its 512 characters
(`MCPInstructionDefaults.decisionPrefixCharacterLimit`), and
`MCPWireTests.testServerDecisionPrefixFitsTheLazyDiscoveryBudget` pins it, including the
substring `send_to_session`.

## Design

### Lineage: a provider-neutral parent on the session

Add a provider-neutral lineage to `AgentSession`, outside the provider configuration:

```swift
/// Where this chat came from, when another chat started it. Birth, not responsibility:
/// `Supervision` says who answers for it now; this never changes after creation.
enum SessionLineage: Codable, Equatable {
  case subagent(of: SessionID)
}
```

- It is persisted as a new optional key in the session JSON, so there is no migration, and older
  builds ignore it.
- The forks draft plans to move `forkedFrom` here as `.fork(of:)`. This draft does not, but the
  enum is shaped so that move is one case.
- Nesting reads one accessor, `nestingParentID = forkedFrom ?? lineage?.parentID`.
  `attachSideChats` and the two incremental sidebar paths switch to it, and keep their
  missing-parent and cycle handling.
- `SessionRowView` draws the fork glyph only for forks. A subagent keeps its provider mark, and
  its accessibility label reads "Subagent of …".
- `list_sessions` prints `(subagent of <id>)` beside the existing `(side chat of <id>)`.

### Responsibility: a supervision tenure held by the parent

Starting a subagent creates the ordinary `Supervision` record with the parent as supervisor, so
brief, state, outcome, events, `subscribe_to_children` and the one-supervisor invariant all
carry over. The tenure needs no new column: it is a subagent tenure exactly when the child's
lineage names the supervisor as its parent. That makes the existing convention, "only managers
supervise", an explicit rule in `WorkspaceControlPlane`. A tenure is admitted either from an
active Manager grant, or from the implicit subagent operation for a child the caller itself
starts.

User-facing wording follows the lineage, not the record:

- A subagent's hover says *Subagent of …*, not *Managed by …*.
- The manager's Chats tab and badge stay grant-gated (`isManager`), so a parent with subagents
  does not become a "manager" in the UI.

### Authority: implicit operations that are never stored

Add `ControlOperation.startSubagent`. Every chat holds it **implicitly**, beside
`regularProjectOperations`, and it is excluded from `managerOperations`. Nothing new is
persisted, so the downgrade trap and the exact-set upgrade dance are both avoided. Concretely:

- `managerOperations` becomes `Set(allCases).subtracting(implicitOnlyOperations)`.
- A test pins that no implicit-only operation is ever encoded into a grant.

The parent's reach over its subagents uses a new scope, `.lineageChildren(of: callerID)`,
resolved from the store at authorization time:

| Operation | Today | Subagent parent |
|---|---|---|
| list, send, steer, watch | project-wide, implicit | unchanged |
| `mail_send` | project-wide, implicit | unchanged |
| archive | self only | self **and own settled subagents** |
| start | manager only | **own subagents, implicit** |
| move account, adopt, resume, finish workspace | manager only | unchanged (no) |

Admission (`admitSubagent`), in the order the refusals should be read:

1. The caller is authorized for `startSubagent` and is not itself a subagent (depth 1).
2. The caller has fewer than **4** live subagents. This is separate from the manager's 8; a
   manager's subagents count toward both.
3. Start rate: at most **6 starts per parent per 10 minutes**, kept in memory like
   `recentSends`.
4. The plan's permission mode ranks at most the **parent's own current mode**. There is no
   grant to read a ceiling from, and a helper must not do what its parent may not.
5. Managed-workspace delivery is `keepForReview` only. A subagent does not merge on its own.
6. The parent's own-limit hold and curfew, as `admitSpawn` already applies.
7. Account admission through `SpawnChildChoices` and `resolveAccount`, unchanged from Phase 0.

### The tool: `start_subagent`

It goes in a new **Subagents** tool group (family `.workspace`, default on), not in Supervision:

- The group's switch is the user's off button.
- Its tools enter a provider's launch-time allowlist only when the group was enabled at launch,
  which is how every non-supervision group already works.
- Switching it off mid-session is enforced at `tools/call` admission.

```
start_subagent { brief, kind?, account?, model?, reasoning_effort?, fast_mode?,
                 uses_native_ui?, permission_mode?, managed_workspace? }
```

- **Choices** are `SpawnChildChoices`, so a child on the parent's runtime inherits its choices
  and a child on another runtime starts on that runtime's defaults.
- **Eligible runtimes** need a brief-taking unattended launch and a final reply Threading can
  read. Today that is Claude, Codex, Grok and Cursor on the native surface. On the terminal it
  is Codex, plus Claude only if its Stop hook reports `last_assistant_message` in the installed
  CLI version. That must be measured before Claude terminal subagents are admitted; until then
  they are refused.
  - OpenCode is refused: no native surface, no Threading bridge, no hook to report its reply.
  - The refusal names the reason, not a capability flag.
- **The brief** is wrapped in a Threading-framed header naming the parent, so the child knows who
  is waiting and that its final reply is sent back automatically.
- **The reply** names the child's id, runtime, login and model, and says the result will arrive
  as mail.

The tool's description and the group instruction say plainly what the provider-native subagent
does not:

- this is a *visible chat on any provider*, not an in-transcript helper;
- results arrive as mail, not as the tool's return value;
- `watch_session` or `subscribe_to_children` is how to wait without polling.

### Report-back: the subagent's own words, as its mail

When a subagent's turn completes (native: completed `.turnFinished`; terminal: a `turnFinished`
hook with `last_assistant_message`), and that turn was **opened by the parent** (the brief, or a
turn started by mail from the parent), Threading takes the final reply from
`CompletedTurnSnapshotStore` for that generation. It then stores it as mail **from the
subagent's mailbox to the parent's**:

- **Attribution is honest.** The text is the child agent's own reply, and the vouched header
  says it came from that agent. This is the same shape as `storeUndeliverable`, and it needs no
  host mailbox.
- **Delivery is the parent's.** The parent gets the ordinary notice for its surface and reads the
  body with `mail_inbox`. The body never becomes the parent's user turn.
- **Turns the user typed into the subagent are not mailed.** The user is talking to it directly.
  An open question below asks whether that should stay so.
- **Large replies are truncated** at the existing 64 KiB snapshot cap, which is above mail's
  32 KiB limit. The mail is cut at 32 KiB with a line saying so and pointing at the subagent's
  chat.
- **A turn that ends refused, interrupted, at a limit or exited** mails a one-line outcome from
  the same mailbox ("stopped at its usage limit"), so a parent waiting on mail is not left
  waiting forever.
- The supervision stream gets `reportReceived` at last, emitted here.

The mail chain fuse (50 messages per chain) bounds a long parent ↔ child exchange. Each new brief
starts a chain.

### Lifecycle

- **Archiving a parent** archives its unarchived subagents in the same action:
  - Working subagents are stopped, as archive already does for a running session.
  - The toast names the count ("and 2 subagents"), and Undo restores all of them.
  - Restoring the parent alone from Settings ▸ Archived offers its subagents with it.
- **Archiving a subagent**, by the user, by itself or by the parent, closes the tenure:
  - by the parent → state `.archived`;
  - otherwise → `.released` with outcome *Archived by the user* or *Archived by its agent*.
  - The child row moves to Archived, and the parent gets a one-line mail-free notice through its
    subscription, if it has one.
- **A subagent whose parent was deleted** follows the side-chat rule: it stays at project level,
  with its lineage kept for the record.

### The parent's timeline

`start_subagent`'s tool row renders as a session card, following the precedent of `ToolCall.chart`
and `ChartCardView`. The card shows:

- the child's title, agent mark and live state;
- an **Open** action, which `ConversationContextRailView`'s session chip lacks today.

This is the one new conversation component, so it carries the design-system obligations:
behaviour, accessibility, live theme switch and rendered-state tests.

### iPhone

Add an optional `parentSessionID` and a lineage kind to `RemoteSessionSummaryDTO`, behind a
`RemoteWireVocabulary` addition. The mobile dashboard then nests subagents under their parent.
A Mac that predates it sends neither field and the phone stays flat.

## Phases

Each phase ships on its own and leaves the system coherent.

### Phase 0 — fixes the research found (implemented)

Done 2026-10-18:

- **Cross-provider `spawn_session` copied the manager's settings.** A Claude manager spawning
  `kind: codex` handed the child its model, effort, fast mode and login, so Codex launched with a
  Claude `--model`. `SpawnChildChoices` now inherits only on the same runtime. It is recorded in
  `sessions.md`.
- **`spawn_session` could not start Grok, OpenCode or Cursor at all.** `resolveAccount` found no
  discovered logins and refused. Those runtimes now start on their standard login, and naming an
  account or a surface the runtime lacks is refused in words.
- **`mail_send` said chains deeper than four are refused.** The depth limit was removed; the
  fuse is 50 messages per chain. The controller's "Depth still bounds it" comment was corrected
  too.

Also done 2026-10-18, after first being reported here as open:

- **A managed child archived by anyone but its manager kept an active supervision.**
  - Only the manager-requested path calls `ControlGrantStore.archive(childID:by:)`.
  - A user-archived child therefore still counts toward the manager's 8 live children and stays
    in the Chats tab.
  - The fix must close the tenure as `.released`, not `.archived`, or Settings ▸ Archived would
    credit the manager.
  - It must close *after* the manager path's `onArchived`, because `SessionArchivedStateDidChange`
    fires before it.
  - The subagent lifecycle above depends on this.
- **Archiving a manager left its grant and active children in place.** An archived caller
  fails every control-plane call, but its children stayed *Managed by* it. The one-supervisor
  index then stopped any other manager adopting them. Archiving a manager now releases its
  children (outcome *Manager archived*) and keeps the grant, so a restore brings back the
  authority but not the fleet.
- `control-plane.md` said "Nine grant-derived tools"; the code maps ten (`respond_to_permission`).

### Phase 1 — mail is how agents talk to each other (implemented)

Independent of subagents, and small.

- **Rewrite the five teaching surfaces to lead with `mail_send`.**
  - The decision prefix has one free character, so the sentence is rewritten, not extended. For
    example, "For other chats: list_sessions, mail_send, watch_session." also saves room for
    Phase 2.
  - Update `testServerDecisionPrefixFitsTheLazyDiscoveryBudget` and
    `testServerDecisionPrefixOnlyNamesEnabledExceptionalCapabilities`.
- **Narrow `send_to_session`'s description** to "hand another chat a turn *because the user asked
  you to*". Agent-to-agent conclusions, briefs and questions go by mail. It keeps working; nothing
  is removed.
- **Send Result to Parent** asks the side chat to `mail_send` its conclusion.
- **The dragged-row brief** names `mail_send` for messages and keeps `list_sessions` and
  `watch_session`.
- **Measure.** Re-run the transcript count two weeks after shipping. Success is `mail_send` well
  ahead of `send_to_session`, and `send_to_session` calls that read as user-requested handoffs.

### Phase 2 — subagents (implemented)

- `SessionLineage`, nesting, the agent mark and the hover card.
- `startSubagent` as an implicit operation, the lineage-children scope, `admitSubagent`, and
  `start_subagent` in the Subagents group.
- Tenure creation, and report-back by mail.
- Phase 0's open supervision-lifecycle fix, the parent-archive cascade, and Undo.
- `USER_GUIDE.md`, `control-plane.md`, `sessions.md`, and an audit row in
  `CUSTOMIZATION_SURFACE_AUDIT.md`:
  - the row lives inside `sidebar.session-row@1`;
  - lineage, start authority and archive cascade are host-only.

### Phase 3 — surfaces

- The parent's session card.
- iPhone nesting.
- Optional usage attribution: the Usage dashboard can sum a parent's subagents, since they run
  on their own accounts.
- Commands for the user-facing actions: Open Parent, Stop Subagent and Archive with Subagents,
  following command-first actions.

### Phase 4 — a row-less one-shot ask

An `ask_agent { kind, question }` that runs a bounded, read-only headless turn on another
provider and returns its answer as the tool result. It should exist only if Phases 1–3 leave a
real gap, and only after measuring:

- **The calling provider's MCP tool timeout.** A synchronous call must finish inside it on both
  Claude and Codex. Measure it rather than assume a value.
- **Usage.** Headless runs are not attributed today. Their transcripts are counted unlabelled by
  the transcript scan. A delegated ask must be attributable to the parent.
- **The runner.**
  - Five features duplicate their own headless runner: settings search, commit message, change
    request text, icon research and the usage poke.
  - A sixth would be the moment to extract one, over `BoundedChildProcess`, with cancellation,
    which none of them has.
- **Read-only posture.**
  - Codex: `--sandbox read-only`.
  - Claude: an allowlist of read tools only.
  - Never the parent's permission mode.

## Scaling contract

- **Cardinality.** Per parent: ≤ 4 live subagents, unbounded archived ones over time. The
  sidebar nests only unarchived rows, so its cost is O(live children per row).
- **Frequency.**
  - A start is admitted at most 6 times per 10 minutes per parent.
  - Report-back is one mail per completed parent-opened turn.
  - Supervision events stay capped at 128 per tenure.
- **Exact interactions.**
  - Sidebar insert and remove must stay incremental for a subagent. The two fast paths widen from
    `forkedFrom == nil` to "has no nesting parent", and get a test asserting no project rebuild
    for an ordinary subagent insert.
  - Archive cascade is one store transaction and one notification per row, not a project reload.
- **Main actor.** Report-back reads an in-memory snapshot and hands the store write to
  `MacMailbox` (an actor). No transcript is read on main.

## Tests

- **Choices and admission.**
  - `SpawnChildChoicesTests` (exists).
  - `admitSubagent`: depth, the cap of 4, start rate, the parent permission ceiling, the
    workspace-delivery refusal, own limit and curfew, and an OpenCode refusal.
  - A test that no implicit-only operation is ever persisted in a grant, including one conferred
    after the new case exists.
- **Lineage.**
  - Encode and decode, and decoding with an older build's view (unknown key ignored).
  - Nesting, the missing-parent rule and cycle refusal, for subagents and for forks together.
- **Report-back.**
  - Native and terminal completions mail the final reply from the child's address.
  - A user-typed turn does not.
  - A truncated reply says so.
  - A refused or limited turn mails its outcome.
  - `reportReceived` is emitted.
- **Lifecycle.**
  - Parent archive cascades, and Undo restores the set.
  - A user-archived subagent closes its tenure as `.released`.
  - A manager-archived child is still `.archived` with its attribution, whichever order the
    notification and `onArchived` run in.
- **Catalogue.**
  - The Subagents group lists `start_subagent` for a regular chat.
  - Codex `enabled_tools` and Claude `--allowedTools` carry it at launch.
  - The decision prefix stays within budget.
- **Rendered state.** The nested subagent row (agent mark, not fork glyph) and the session card,
  light and dark.
- **UI scenario.** An XCUITest journey with fixture agents (`ui-scenario-testing.md`): a Claude
  parent starts a Codex subagent, the subagent completes, the parent's inbox holds its reply, and
  archiving the parent archives both.

## Open questions

1. **Should turns the user types into a subagent also mail the parent?** The recommendation is
   no: the user is talking to it, and the parent asked for nothing. The cost is that a parent
   does not learn the user steered its helper. Its `subscribe_to_children` notice still says a
   turn finished.
2. **Cascade, or float, when the parent is archived?** The recommendation is cascade with Undo,
   because a subagent is part of its parent's work. Side chats float today, and this draft does
   not change that.
3. **Depth 1?** The recommendation is yes for now. Depth is cheap to raise and expensive to
   un-ship.
4. **Default on?** The recommendation is on, because the bounds above are tighter than what a
   regular chat can already do with `send_to_session`. Settings ▸ Tools ▸ Subagents is the off
   switch.
5. **Name.** "Subagent" collides with the providers' own in-transcript subagents, which Threading
   already shows in the native timeline (`SubagentSummaryView`). The two are distinguishable,
   since one is a sidebar row and the other a timeline row, but the hover card and tool
   description must say which is which. An alternative is "Helper chat".
