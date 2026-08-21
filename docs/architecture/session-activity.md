# Session Activity

Deriving dormant/idle/working/awaitingUser/needsAttention, and the lifecycle hooks that replace
the inference.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

`SessionActivityTracker` derives `dormant` / `idle` / `working` / `needsAttention` from PTY
output, because an idle agent writes nothing at all — measured at zero bytes over 19s while
sitting at its prompt. This works for any program rather than one specific agent.

Five guards keep it honest:

- A **byte threshold** (`workingByteThreshold`), so the terminal echoing typed characters is
  not mistaken for work.
- A **quiet interval**, so gaps within a burst of output do not flicker the state.
- A **resize quiet period** (`noteTerminalResized`). Resizing sends `SIGWINCH` and full-screen
  terminal apps answer by repainting everything, which is a large burst of output that we
  caused. Suppression blocks a session *entering* `working`, but deliberately keeps an
  already-working session's timer alive — otherwise resizing mid-task would report it as
  finished.
- A **pointer quiet period** (`noteMouseReportForwarded`). When a program tracks the mouse, the
  wheel *and the pointer itself* are forwarded to it (see the fork's `MacTerminalView.scrollWheel`
  and `mouseMoved`) and it answers each report by repainting — the same we-caused-it output as a
  resize, extended by every event so a momentum gesture or a pointer sweep stays covered.
  Motion is the loud half: Claude Code turns on any-event tracking (`\e[?1003h`, pinned by
  `TerminalThemeBoundaryTests`), so moving the pointer across the terminal reports every cell it
  crosses and the CLI redraws the row under each one — a few cells of travel is already over the
  byte threshold. Before this covered motion, moving the mouse over a *finished* turn started
  the spinner, and on a session that reports its own turns it did the more specific damage of
  looking like the burst below: a hover highlight read as the user having answered a question
  where they stood.
- An **unattended-launch grace** (`noteUnattendedLaunch`). The startup relaunch (see
  [`sessions.md`](sessions.md)) boots sessions with nobody looking, where every earlier
  launch was a selection — so the tracker could assume boot output happens on screen, where
  it opens no flag. Unattended, the resume's repaint would read as a turn, go quiet, and
  land every restored session on `needsAttention` with a notification apiece. While the
  grace holds, nothing the process emits on its own raises a flag: output opens no inferred
  turn, a bell does not flag, and Claude's idle-prompt `Notification` — which a relaunched
  session sitting at its prompt is precisely the shape of — is ignored (it still latches
  `reportsOwnActivity`, since it does prove the hooks arrived). The grace ends at the first
  look, or at the first reported turn — the remote mirror can type into an unattended
  terminal, and from that turn on the session flags like any other.

The tracker reports an **attention episode** whenever work finishes or a terminal bell raises an
unread result, independently of who is looking. `AgentRuntime` gives that episode a monotonic
conversation generation in `SessionReadReceiptStore`, then projects `idle` / `needsAttention`
for the person reading the row. Operational states — `working`, `awaitingUser`, `limitReached`
and `dormant` — remain shared facts and are never changed by a receipt.

Read identity has one deliberate asymmetry:

- Every owner credential maps to `RemoteCollaborationParticipantDTO.ownerID`. Reading on the Mac,
  an iPhone or a browser therefore clears the result on every owner device.
- An accepted collaborator maps to their stable member id (with the share id as the legacy
  fallback). Their receipt is independent of the owner and every other collaborator. Random
  socket-scoped presence ids never enter durable state.

`session_attention` and `session_read_receipt` persist those generations in SQLite and cascade
with their session. The ledger loads once, lazily, and row projection is then O(1); opening a
local session or successfully attaching a remote live surface advances that identity's receipt.
Participants already viewing the conversation are recorded as having seen a result when it lands,
so the dot does not flash on another one of their devices. `RemoteSessionMirrorRegistry` observes
`SessionActivityDidChange` directly and sends an authorization-specific row delta; activity no
longer waits for an unrelated project-title or branch mutation to refresh the remote chat list.
An owner acknowledgement also removes the Mac's stable session notification unconditionally,
even when no receipt changed: after relaunch, macOS can still hold the prior process's request
while the new process has no in-memory alert edge to clear. Collaborator receipts never remove
the owner's notification.

**`limitReached` is the one state nothing here can infer.** A provider that refuses a turn over a
rate limit raises no hook — no turn began, none ended — and the CLI answers by printing a sentence
into its TUI, which this file's machinery sees as bytes and reads as work. The state is raised
from the session's own transcript instead, and everything about it — the reader, the tracker's
`limitPark`, the mark, and what may and may not lower it — lives in
[`limit-recovery.md`](limit-recovery.md). What belongs here is the boundary: it is the only
activity in this vocabulary that is not derived from output, hooks or visibility, and the only one
that is *evidence-cleared* rather than guess-cleared — being looked at lowers `awaitsUser` and
deliberately does not lower this.

Output arrives on the main queue (`LocalProcess` defaults its dispatch queue to
`DispatchQueue.main`), which is what lets the tracker use `Timer` safely.

Grok and OpenCode terminal sessions stay on this provider-neutral output inference. Threading does
not rewrite either runtime's configuration to install lifecycle hooks; adding the runtime does not
pretend that its repaint traffic has Claude/Codex's structured turn semantics.

**An agent that reports its own turns is believed instead.** All of the above is a proxy, and
the guards exist because it cannot tell thinking from repainting. When
`AppSettings.reportsClaudeLifecycleEvents` is on, `AgentLauncher.claudeCommand` writes a
per-session `--settings` file for *terminal* sessions too — lifecycle hooks only, and no
*brokering* `PreToolUse`, because a terminal session raises the CLI's own permission prompt and
intercepting it would replace a working prompt with a second one. `UserPromptSubmit`, `Stop`,
`Notification`, `SessionStart`, `SubagentStart`, and
`SubagentStop` curl back to the listener
(`MCPDefaults.lifecyclePathPrefix`), and `HookLifecycleRelay` hands each report to the session's
tracker. Verified end to end against CLI 2.1.217: the three ordinary events arrive in order,
carrying the prompt text. Terminal sessions additionally carry a *tool-scoped, observational*
`PreToolUse`/`PostToolUse` pair for the tools that ask the user outright — see "A runtime's own
'I am waiting'" below, which is where the difference between that pair and the broker is drawn.

Reporting is on by default to preserve the richer terminal state, but it is observational and
optional. Off with no Remote Control override means no Claude settings file at all; off with an
override writes that key without a `hooks` dictionary. Native Claude still writes `PreToolUse`
because its headless process has no CLI approval prompt, but does not write lifecycle hooks. The
native structured stream remains the source of turn and child state either way.

The child pair does not drive `SessionActivityTracker`; it feeds the provider-neutral
`SubagentSessionState`. Start supplies the child id/type, and Stop supplies its transcript path
and last assistant message. Claude native deliberately ignores these hook child ids because its
structured stream uses the spawning Agent tool-use id as the stable UI identity; mixing the two
would create duplicate children. Claude terminal uses the hooks. Codex uses its child thread id
in both app-server and hooks, so the hook can enrich either surface without a second row.

**Not every subagent hook is about a subagent.** Claude reports the *root* agent's own turn
through `SubagentStop` as well: the root's `agent_id`, an **empty** `agent_type`, an
`agent_transcript_path` under `<session>/subagents/` that the CLI never writes, and the parent's
own `last_assistant_message`. Threading accepted them, so the navigator filled with rows that
opened onto nothing and could not be dismissed — nothing retracts a discovered child. Measured
across five sessions' persisted navigators: 17 of 20 recorded children had this shape, every one
of them with no transcript on disk and the parent's own prompt or turn summary as its message,
while all three real children named their type (`Explore`, `Plan`) and had their transcripts.

`HookLifecycleReport.describesChildAgent` is the admission rule: a named `agent_type` is a child;
an unnamed one is admitted only when the reported transcript exists, and an already-tracked id is
always admitted so a child accepted at Start still receives its Stop. This is the terminal
analogue of the rule `ClaudeSubagentEvent` already applies natively — "an explicit non-agent type
must never become a child row" — and it holds for Codex too, since the contract above has Start
supplying the type and Stop supplying a path that, for a real child, is on disk. A child that
satisfies neither is by definition one that cannot be opened.

Refusing them at the hook only stops new ones: a navigator keeps its rows across relaunches, so
`SubagentStateStore.load` applies the same rule to what is already on disk. Swept on read rather
than behind a version bump — the file's shape did not change, only which rows belong in it, and
the next save writes the result.

Three things shape it, and each was wrong first or would have been:

- **The lifecycle endpoint never blocks**, unlike the permission one. These hooks fire on the
  agent's own turn boundaries, so any pause is latency before the user's prompt is answered, and
  nothing reads the reply — `routeLifecycle` responds `.accepted` before it parses the body, and
  the hook runs with a 2-second timeout.
- **The hook must stay silent.** Claude feeds a `UserPromptSubmit` hook's stdout back to the
  model as context and reads a failing `Stop` hook as a reason to keep going, so a lifecycle
  report that leaked either would change the conversation it only observes. Hence
  `>/dev/null 2>&1 || true`, which is load-bearing rather than tidy.
- **Reporting latches** (`reportsOwnActivity`), and output then stops driving the state at all.
  The two signals disagree by design: a working agent is quiet while it waits on the model and
  noisy after its turn ends while the CLI redraws its footer. Falling back per-event would
  flicker between them. `markRunning` clears the latch, because the settings file is written per
  launch and can fail — a latched tracker with no reports coming would sit idle forever.

**The turn and the question are separate facts, and collapsing them cost a whole run.** The
tracker used to hold one enum and let each report assign the state it thought followed, which
made `UserPromptSubmit` the *only* way back into `working`. But an agent asks for a permission
inside a turn it goes on to finish: `Notification` arrives mid-turn, the row goes to
`needsAttention`, the user answers — and nothing says `working` again until their next prompt.
Worse, the natural response to an attention dot is to open the session, and opening it cleared
the flag to `idle`, so the row went completely blank while the agent worked on. Found with three
sessions showing no indicator at all while still appending to their own transcripts; the sidebar
had been read as "the loader is broken", and the loader was fine.

So `SessionActivityTracker` now keeps `turnInFlight`, `awaitsUser` and `isDormant`, and `settle()`
is the single place that turns them into a `SessionActivity`. Three rules fall out of that:

- **`awaitingUser` and a bell raise the flag without touching the turn.** Where nothing reports,
  the bell still ends the inferred turn — it is the only boundary a shell has, and leaving the
  turn open would strand it `working` with no quiet timer left to stop it.
- **Being looked at lowers the tracker's process-local waiting flag and returns to the turn**, so
  a session asked-and-answered mid-turn goes back to `working`, while one that genuinely finished
  goes `idle` before its participant-specific unread receipt is projected onto the row.
- **Output may lower the flag, and may do nothing else.** Answering in place raises no hook at
  all, so a fresh burst inside a flagged turn is the only evidence the agent resumed. It is
  admitted on screen only — off screen the flag is the one thing saying the session is waiting,
  and nobody answers a prompt they are not looking at. It can never start or end a turn, which
  is what keeps the latch's guarantee intact.

**The same split is what lets the sidebar say *which* kind of attention a session wants.** The
flag raised inside an open turn is `awaitingUser` — a turn stopped dead — and the same flag with
the turn closed is `needsAttention`, a turn nobody has read. They cost the user different things,
and with ten sessions in the list only one of them is worth interrupting yourself for. The
distinction is free: it is the pair of facts `settle()` already holds. It also disambiguates a
report that used to be unreadable — Claude raises `Notification` both for a permission prompt and
once its prompt has sat idle a while, and the turn is what tells those apart. (The turn tells them
apart as *marks*. What tells them apart as *evidence* is the payload's `notification_type`, which
is a later fix — see "A pause the next notice quietly undid".)

### The trail a state change leaves

**A row can say a session wants you, and nothing anywhere could say why.** `needsAttention` has
three ways in — a turn that ended off screen, the runtime's own idle-prompt notice, a bell — set
in three different places, and from outside they are the same dot. Asked in August 2026 why a mark
had appeared on a session the user was looking straight at, the honest answer was a list of
candidates: the hooks are silent by design, `HookLifecycleRelay.deliver` records arrivals at
`debug` (not retained unless somebody turned the level on *first*), and a terminal session keeps
no execution-audit ledger. The state was derivable; the cause was gone.

So `settle()` takes a `SessionActivityCause` — named for the **input**, never the outcome — and
writes one `ThreadingLogger.session` line per change under `codes.threading:session`:

```
Activity idle -> needsAttention cause=turnFinished session=<uuid> visible=false turn=false
awaits=true asks=0 park=none paused=none reports=true unattended=false
```

Which is read back with, for a mark that appeared within the last half hour:

```bash
log show --predicate 'subsystem == "codes.threading" AND category == "session"' \
  --last 30m --info --style compact | grep Activity
```

Four decisions inside that, each of which was the alternative first:

- **`info`, not `debug`.** The question is always asked in the past tense. A level that has to be
  enabled before the thing it would have explained is a level that explains nothing, which is
  exactly what the existing per-hook `debug` line does today. Per-hook detail is still there for
  anyone streaming: `log stream --level debug --predicate 'subsystem == "codes.threading"'`.
- **Every fact the branch reads, not the two that moved.** `turnFinished` with `visible=false` is
  an unread mark; the identical cause with `visible=true` is a session going quietly idle. One
  input, two outcomes, and only the facts beside it tell them apart.
- **A reported cause that changes nothing is still a line** (`Activity held at …`). "The mark was
  already up when the second notice arrived" is what a row stuck flagged looks like from in here.
  Inferred causes are excluded: a session with no hooks settles on every burst of output, and the
  turn boundaries would drown in it.
- **The session id is on every line**, because a window holds dozens of trackers reporting the
  same six states. `unowned` marks a fixture, which legitimately has no session.

The cause is also kept as a value (`lastCause`), so `SessionActivityTrailTests` asserts the rule
rather than scraping `log show` — including the pair that motivated all of it: the same
`turnFinished` landing on `needsAttention` off screen and `idle` on screen, and
`awaitingUserReported` as the one cause that flags a session the user is watching.

Three consequences worth knowing before changing any of it:

- **The marks are ranked by what they cost, not by novelty.** Blocked is a filled dot in the
  warning role; unread is a hollow accent ring. Filled-versus-hollow carries the meaning on its
  own, so it survives Differentiate Without Colour — checked by rendering both and comparing the
  ink at the centre, since a colour-only distinction passes every assertion you would think to
  write about it.
- **`GitTurnBaselineStore` had to learn the difference.** It captures the Last Turn baseline on
  the edge into `working`, and answering a question mid-turn is now such an edge — re-baselining
  there would silently drop everything the turn had already changed. It skips the edge out of
  `awaitingUser`, which is the one that is a resumption rather than a start.
- **Extensions still see one state.** `ExtensionSessionActivity` is a published vocabulary an
  installed extension already switches on, so both map to `needs-attention` rather than handing
  every extension a value it has no branch for.

**A runtime's own "I am waiting" is late, vague and losable — so the tools that ask are named
instead.** The split above says a question inside an open turn is `awaitingUser`, and for a whole
release the sidebar still spun a loader at sessions that had stopped dead on a question. Three
things had to be true at once, and they were:

- **`Stop` never fires.** `AskUserQuestion` is a tool call *inside* the turn, so the turn really
  is open, and `settle()` reporting `working` was correct about the only fact it held.
- **The output heuristic is off.** The session latched `reportsOwnActivity` on its first hook, by
  design — so twenty seconds of a silent PTY no longer end anything.
- **The one signal left arrives late, if at all.** Claude reports a question through
  `Notification`, and in CLI 2.1.222 that notice is fired on a 6-second poll gated on
  `Date.now() - lastUserActivity >= 6000` — the *keyboard*, not the agent. Reading the question
  or arrowing through its options resets the clock, so the report a user is most likely to be in
  front of is the one that never comes. The bell would not have covered it either: Threading sets
  `TERM_PROGRAM=Threading`, which resolves Claude's notification channel to `no_method_available`,
  so nothing rings.

Measured by driving a real 2.1.222 through a PTY with every hook logging its payload. A question
left open produced **one** hook — `PreToolUse`, `AskUserQuestion`, at the moment it was called —
then nothing for as long as it stood, with `Notification` arriving late and typed
`permission_prompt`. Answering produced `PostToolUse` carrying the *same* `tool_use_id` as the
`PreToolUse`, and only then `Stop`. Both halves of the fix below are that trace.

And even when the notice did arrive, the session being *looked at* lowered it — correctly, for
what that flag means. `Notification` cannot say what it is waiting for, so answering a CLI's own
permission prompt, which happens in the terminal and raises no hook, is only visible as "the user
is here" or "output resumed". Both rules then fire on a question: the box repaints when it is
drawn and again on every arrow key.

So a second, narrower fact was added rather than weakening the first. `TurnBlockingTools` names
the tools whose *result is the user's answer* — `AskUserQuestion` and `ExitPlanMode` for Claude —
and `blockingAskOpened`/`blockingAskClosed` report the call itself through `PreToolUse` and
`PostToolUse`. That fact is exact, so it obeys neither of the guesses: `openAsks` is settled ahead
of `awaitsUser` and is cleared only by the call ending. Four things about it are load-bearing:

- **It is observational, on the hook a broker also uses.** A terminal session raises the CLI's own
  permission prompt, and this must not become a second one — so the entry is scoped by a
  `matcher` to the asking tools, points at the lifecycle endpoint (which answers `.accepted`
  before it parses), and ends in `>/dev/null 2>&1 || true`. Claude reads a `PreToolUse` hook's
  exit status as a permission decision; the `|| true` is what keeps this one silent. A native
  session brokers on the same key, so `appendHooks` **accumulates** entries per hook name — the
  assignment it replaced would have dropped one of the two. Both surfaces register the pair, like
  every other lifecycle hook: `applyLifecycle`'s tracker guard stays the single place that decides
  who consumes a report, and a rendered conversation — which reads the tool out of its own stream
  and has no tracker — drops these exactly as it already drops `Stop`.
- **`PostToolUseFailure` is registered beside `PostToolUse`.** Escape is reported as an interrupt
  and fires nothing else; a session listening only for the answer would keep the blocked mark for
  the rest of the turn while the agent worked on. The two hooks carry the same `tool_use_id` as
  the `PreToolUse` that opened the ask, which is what closes an ask with its own call rather than
  with the next tool of the same name.
- **The turn boundaries still outrank it.** `Stop` and the next `UserPromptSubmit` clear
  `openAsks`, so a lost close ends with its turn instead of stranding the mark. Duplicate and
  orphaned reports converge because it is a set: inserting twice is one entry, removing something
  absent is nothing.
- **A runtime that names no asking tool installs no hook.** `HookRegistration.matched` returns
  `.unsupported` for an empty tool list rather than writing an unmatched entry — one would report
  every `Read` and every `Bash` as a turn stopped on the user. Codex 0.144.6, Grok and OpenCode
  name none today: each approves a *command* mid-work, which is the other kind of ask. Adding one
  is a line in `TurnBlockingTools` and its hook names in `codexRegistration`; nothing downstream
  needs to learn about it.

**A `Stop` is the end of a turn, not the end of the session — and the agent says which.** An
agent that backgrounds a test run ends its turn at once ("queued; will report when it lands"),
and the CLI wakes it a minute later by submitting the task's completion as a prompt of its own.
Read as a finish, that `Stop` posted *Finished its turn* and dropped a completed mark on a
session that then went on talking. Found in one transcript three times in six minutes — 11:07,
11:09 and 11:12, each about 45 seconds ahead of the wake that followed it.

The fact was already in the payload. Claude's `Stop` carries `background_tasks`, and the CLI's
own description of the field is the reason it is read: it exists so a hook can tell *"session is
done"* from *"session is paused waiting for background work to wake it"*. It lists shells,
detached children, MCP monitors and workflows whose status is `running` or `pending`, and is an
empty array when there are none — measured against 2.1.220 by ending a turn on top of a
`sleep 45`. Codex 0.144.6 sends no such key, so its sessions read zero and behave as they did.

`pausedOnOwnWork` is therefore a **fourth fact rather than a longer turn**, and the distinction
is the one the split above already paid for: the turn is what a `Notification` is read against,
so borrowing it here would make Claude's idle-prompt notice — which holds nothing up — arrive
looking like a blocked turn. Two rules follow:

- **It keeps the session out of `idle` without opening a turn.** `settle()` reports `working`,
  because "still going" is what the sidebar has to say and there is no third mark worth
  teaching every reader of `SessionActivity`.
- **It suppresses the unread mark too, not just the notification.** A turn ended on top of its
  own running work has said nothing for the user to read, so `noteTurnFinished` leaves
  `awaitsUser` down even off screen.

**A pause the next notice quietly undid.** Keeping the flag down at the boundary is only half of
it, because sixty seconds later the CLI raises one itself: `messageIdleNotifThresholdMs` is
60 000 in 2.1.238, and when it expires Claude fires `Notification` saying *"Claude is waiting for
your input"*. `noteAwaitingUser` raised `awaitsUser` for it, `settle()` ranks `awaitsUser` above
`pausedOnOwnWork`, and the row therefore fell out of `working` into `needsAttention` for a session
nobody was asking anything of. Reported as *"it showed no activity for 1–2 minutes, even if it had
subagents working"*, and caught twice in one morning on the same session, whose child ran for
eighteen minutes:

```
08:26:45 Activity working -> needsAttention cause=awaitingUserReported … turn=false paused=true
08:27:54 Activity needsAttention -> working cause=seen                 … turn=false paused=true
```

`paused=true` on both edges is the whole defect: the app was holding the fact that knew better and
let a notice that names no question outrank it. Opening the session was the only thing that
cleared it — which is what made it look like a rendering fault rather than a state one — and it
dropped again on the next quiet stretch. Off screen the same edge also spent an attention episode,
so the session that had handed back nothing got an unread mark and a notification for it.

**`settle()`'s ranking is not the bug and is not what changed.** A genuine question *should*
outrank a pause: an agent stopped on a permission prompt is blocked whatever else it left running,
and reordering the branches would bury a real ask behind a subagent. The wrong step is upstream of
it — raising `awaitsUser` for a notice that never claimed anyone was being asked — so that is
where the fix goes.

**The fix reads the notice's type, and it refuses a notice only where refusing it cannot lose
anything.** Two narrowings, both the same instinct:

- **`idle_prompt` only, not every notice.** The payload has carried `notification_type` all along
  — the 2.1.222 trace above recorded a `permission_prompt` in it — and nothing here read the
  field, so an idle prompt and a permission prompt were the same fact to Threading.
  `HookNotificationKind` recognises exactly `idle_prompt`; everything else, **including a payload
  that names no type and a type a later CLI invents, is `.unspecified` and still flags**. The
  asymmetry is the one `BackgroundWorkKind` already makes: a spurious mark is noise, while a
  swallowed permission prompt is a session waiting for an answer nobody knows it wants — and a
  terminal session has no other signal for one, since `blockingAskOpened` is scoped to the tools
  that ask outright and a `Bash` approval is not among them.
- **A `delegated` pause only, not every pause.** So the tracker keeps the pause's *kind*
  (`TurnPause`) rather than a boolean, read straight off the same payload. A subagent is bounded
  by construction: it ends, its result re-enters the conversation, and the row corrects itself
  with nobody typing — so a suppressed notice costs nothing. Standing work promises none of that,
  since `npm test` and `npm run dev` are the same entry, and a session parked on one is exactly
  where a late *"nothing is happening here"* is worth keeping. `BackgroundWorkLedger` still owns
  whether there is a pause at all; only the reason is new.

So suppression is opt-in twice over, and a build that stopped recognising the field would behave
exactly as every build did before it. The pause reason is on the trail line too — `paused=none` /
`delegated` / `standing` where it used to be a boolean — because the boolean could not say which
kind, and the rule above turns on exactly that.

**A refused notice still leaves a line.** `noteAwaitingUser` settles either way, so the trail
carries `cause=awaitingUserReported` with the state held where it was — because *"why did no mark
appear"* is asked in the past tense exactly as often as its opposite, and a hook that arrives,
changes nothing and is invisible afterwards is the shape this whole trail exists to stop. The
unattended grace's refusals are now on the record for the same reason.

`SessionActivityTracker.honoursAwaitingUserNotice` is that rule, and it is **one rule with two
readers**: the tracker asks it before raising the flag, and `AgentRuntime` asks it before
recording the notice as a reason to wake a snoozed session. A notice must not be too weak for the
sidebar and loud enough to end a snooze at the same time. Folding the unattended grace into the
same predicate keeps a restored session's idle prompt out of Snooze as well, which is what
`SessionSnoozeCenter.record` already says it is for: a *new* edge, not old state a relaunch
happened to re-read.

The bell is not a second way in for Claude here, and deliberately stays untyped: Threading sets
`TERM_PROGRAM=Threading`, which resolves Claude's notification channel to `no_method_available`,
so nothing rings. `recordBell` therefore keeps flagging whatever the pause says — an unattributed
BEL from some other program on the PTY is exactly the notice that should stay loud.

**Being in flight is not enough, and `BackgroundWorkLedger` is why.** The obvious rule — any
in-flight work keeps the session out of `idle` — is right for a test run and wrong for a dev
server: a process that lives for hours would hold *every* later turn open behind it and silence
the session for as long as it ran. But "will this speak again" is true of everything in the
list, because both CLIs wake a session when a background task ends, so it separates nothing.
Two facts do, and **the kind is asked first**:

- **Delegated work always pauses.** A subagent or a workflow is bounded by construction and its
  result re-enters the conversation, so a turn that ends while one runs has handed nothing to
  the user — however many turns ago it was started.
- **Standing work pauses only when it is new.** A shell or a monitor may stand indefinitely and
  nothing in the payload says which. So work the agent started **in the turn that just ended**
  is the reason that turn ended early, and that is the pause; work **carried over** from an
  earlier turn is parked, and the turn really did hand back.

So the ledger keeps the ids of the *standing* work that was already in flight at the previous
boundary, and a boundary pauses the session when it carries delegated work or brings new
standing work. Both surfaces carry identities and kinds for exactly this —
`background_tasks[].id`/`type` on the hook, `tasks[].task_id`/`task_type` on the stream — and
both hold their own ledger, reset with the process. Traced against the transcript that started
this: three consecutive turns each queued a *new* task, so all three paused correctly; a fourth
turn with only the old task still running would not have.

**Age alone was the first rule, and it went blind on exactly the work it most needed to see.** A
background subagent is in flight at every boundary until it finishes, so by age it is new once
and carried over forever after: the session showed `working` for the first turn after the child
was spawned and `idle` for every turn after that, while the child worked on. Reported as "no
progress circle, but a sub agent working", and measured on CLI 2.1.224 in a session that spent
13 minutes that way — `turn_duration` records at 20:04, 20:12, 20:15 and 20:17 each carrying
`pendingBackgroundAgentCount: 1`, the same child in `background_tasks` at all four Stops, and
only the first raising the mark. It is worse off screen, where the same boundary also hands the
session an unread mark and a *Finished its turn* notification for a turn whose child has not
reported. The app knew the whole time: `SubagentSessionState` held that child at `working` from
its `SubagentStart`, and by design that never reaches the tracker.

`BackgroundWorkKind` reads the kind, and **it knows both spellings** because the two surfaces
disagree: the hook sends the friendly label from Claude's own schema (`subagent`, `shell`) and
the stream sends the raw discriminant (`local_agent`, `local_bash`). That is the same thing
`ToolIdentity` does for tool names — the behaviour is ours, the spelling is the provider's.
Anything unrecognised reads as standing, which is the safe direction: a kind wrongly called
delegated holds `working` for as long as it runs, while one wrongly left standing is judged by
age, exactly as everything was before kinds were read at all. So a task type a later CLI invents
behaves no worse than it does today.

Classifying the command instead (`npm run dev` is long-lived, `npm test` is not) was the
obvious alternative and is worse. It is a name-matching guess where an exact fact is already in
the payload, it covers only `shell` tasks and not subagents or monitors, and being wrong in the
long-lived direction re-opens the very bug this closes. Reading the task *type* is not that
guess: it is the same payload, one key over from the id.

What it still holds open is a turn that starts standing work and is never followed by another
turn. Nothing further happens in that session to notify about, so what remains is a working
mark beside a session that does in fact still have something running — which is what the CLI's
own footer says for exactly as long.

The native surface has the same bug and a better signal: the stream sends
`system` / `background_tasks_changed` carrying the whole in-flight list on every change, so
`ConversationViewController` holds a level rather than reconstructing one. It is recorded and
deliberately **not** announced — work can only be backgrounded from inside a turn, so the rise
never changes the activity, and the fall lands in the gap between a task finishing and the CLI
waking the agent, where announcing it would post *Finished its turn* microseconds before the
turn resumed. `noteTurnBoundary()` reads the level, and it is called on the status *edge* only:
a status restated without one — a re-init, a model change — is not a boundary and must not
spend the ledger's judgement on a turn that never ended.

`--settings` **layers rather than replaces** (measured: with one `SessionStart` in the file, two
`SessionStart` hooks fire — ours and the user's own), so this does not disable whatever the user
already has wired into their agents.

**The activity states also feed the composer's ambient beam.** `AgentWorkloadMonitor`
(started from the real app startup like the alert center below) recomputes one aggregate on
every `SessionActivityDidChange` — how many sessions are in `.working`, and whether any of
them runs at the top of its provider's announced reasoning ladder — and posts
`AgentWorkloadDidChange` only on a real change. `.working` alone counts: a session waiting on
the user is not work in progress, and counting it would hold the beam lit for exactly the
sessions where the user is the reason nothing is happening. The drawing side is
`AgentActivityBeamView`; see [`design-system.md`](design-system.md) and
[`dependencies.md`](dependencies.md).

The same monitor owns a theme-independent `AgentIntensity` envelope for presentations that need
more than the beam's stepped count. Its quiet floor is still exact workload — 30% for one
`.working` session and 10% for each additional session, bounded at full scale. Meaningful live
events then pulse into the headroom and decay exponentially: terminal sessions contribute only
output bursts already admitted by `SessionActivityTracker` (not launch paint, resize/pointer
repaint, echo below the working threshold, or a finished turn's redraw), while native sessions
contribute text/thinking deltas and semantic assistant/tool/plan/background edges. Replay and turn
receipts contribute nothing. Byte sizes are compressed logarithmically and no token count enters
the model: provider token reporting arrives too late, is not universal, and would make verbosity
look like compute power. A session must still be `.working` when its pulse arrives, and the
envelope clears immediately when the final worker settles. `AgentIntensityDidChange` publishes
that bounded presentation value alongside the exact count and top-effort fact.

**An unfinished turn may also hold one process-wide idle-sleep assertion.**
`ActiveTurnSleepInhibitor` is started with the other real-app activity consumers and follows
`hasTurnInFlight`, not `.working`: a permission or question inside a turn is still unfinished,
so sleeping there can lose exactly the response the user is being asked to give. An agent process
alive at its prompt holds nothing. The General-page switch is off by default, and changing it
acquires or releases immediately.

The service keeps a set of in-flight session ids. One initial scan admits work that predates its
observer; each later `SessionActivityDidChange` updates one set entry, and the last edge out of
flight releases the single `kIOPMAssertPreventUserIdleSystemSleep` assertion. This is deliberately
idle **system** sleep only: display sleep and forced sleep such as closing a MacBook lid remain
macOS's. `TerminalSessionDidEnd` clears a terminal that disappears without another activity edge.
`AgentRuntime.discard` also posts the common activity event after either renderer has left its
runtime map, so a discarded native conversation projects `.dormant` even though it has no
terminal-end callback. The quit path stops the service before tearing runtimes down.

**The activity states also feed macOS notifications** (`AttentionAlerts.swift`), and the
split above is what makes them worth having: `awaitingUser` posts with sound (a turn stopped
dead), `needsAttention` posts silently (unread), and the *visible* session finishing while the
app is inactive posts too — that case exists because the visible session settles to `idle`
precisely so it needs no in-app flag, and a native conversation reports `idle` off screen as
well. `AttentionAlertPolicy` is the pure judgement, tested as a matrix; `AttentionAlertCenter`
owns delivery. Three rules keep it honest: the `.finished` alert is gated on
`AgentRuntime.reportsOwnTurns` (a shell's working→idle is a quiet timer expiring, and
notifying on each `ls` would bury the rest); banners are suppressed while the app is frontmost
(`willPresent` returns nothing — in-app, the sidebar mark and the permission card are the
cues); and every alert is withdrawn the moment it stops being true — the edge out of an
attention state, the session coming on screen (`setVisibleSession` →
`sessionWasViewed`), or the app coming back to the front over the visible session. Hygiene is
half the feature. `start()` runs only from the real app startup, which is what keeps
`UNUserNotificationCenter` and its permission prompt out of the test host.

**A banner carries the project's icon as an attachment** (`AttentionAlertIcon`), on the
trailing side — the leading slot is the app's and cannot be taken. That was measured, not
assumed (July 2026, macOS 26): the one sanctioned replacement is a communication
notification's sender avatar, and it dead-ends twice — the
`com.apple.developer.usernotifications.communication` entitlement is *restricted*, so AMFI
refuses to spawn a dev-signed build that requests it, and a signed probe app whose
`updating(from:)` rewrite posted without error still rendered the generic icon, because
Apple grants that capability to the iOS family only. Details in
[`permissions.md`](permissions.md). Two rules the attachment must keep: it attaches a *copy*,
because scheduling an attachment **moves** the file into the system's store and the original
is `ProjectIconStore`'s; and a failed copy drops the icon, never the banner — the icon is
decoration, not payload.

**Which of the three arrive is the user's, on four levels**, because the kinds are not equally
welcome — being blocked is work stopping, a turn ending in the background is the chatty one —
and one switch forces a choice between all of it and none of it. `notifiesOnAttention` stays
the master, an outer gate rather than a fallback: it is what people reach for meaning "silence,
all of it", so a per-session exception must not outlive it. Under it sit a toggle per
`AttentionAlert` (stored as the *disabled* set, so a kind added later needs no defaults
migration), the sound (separate from the banner it rides on — wanting to see that a turn is
blocked without being pinged is a real answer), and `notificationsMuted` on the session and its
project. Those two are `Bool?` for the reason the theme's are: **inherit has to be a state**, or
a session inside a muted project offers an Unmute that does nothing. `AttentionAlertScope`
resolves session → project → not muted; the row menus write `nil` where the answer already
matches the project, so the session keeps *following* it. The judgement stays split: the
policy reads the state edge, `AttentionAlertCenter.wants` reads the preferences, and an edge
whose alert is unwanted **withdraws** rather than doing nothing — the notification already on
screen described the old state either way. Muting is not a settings change, so the row menus
call `preferencesChanged()` themselves: `ProjectStore` knows nothing about notifications and
should not learn.

**Which sound it makes is a file name, and the name is resolved twice** (`SoundChoice.swift`).
`UNNotificationSound(named:)` does not take a path: it takes a file name that a *system* process
looks up later, in the app bundle and then `~/Library/Sounds`, `/Library/Sounds`,
`/System/Library/Sounds`. Three things follow, and all three were measured with a probe app on
macOS 26.5 rather than assumed:

- **A name that resolves nowhere posts the banner in silence.** There is no fallback of the
  system's own — the log says `Tone with identifier 'X' is neither in of the collections for
  system or iTunes tones` and nothing plays. So `SoundChoice.notificationSound()` checks the
  search paths itself and hands over `.default` when the file has gone. A stored choice whose
  file was deleted therefore degrades to the macOS tone rather than to nothing, and the picker
  shows `macOS Alert Sound` for it, because that is what will actually be heard.
- **A `/System/Library/Sounds` name works**, so the built-in choices ship no audio: the picker
  lists what the machine has, and a macOS release that adds or drops one changes the list with
  no code change. `SuggestedNotificationSounds` names five of them (Submarine, Glass, Purr,
  Ping, Tink) to put above the rest — short, mid-bright, unstartling — because a list of
  fourteen is a list nobody reads to the end of and several of the fourteen are novelty stings.
- **A file copied into `~/Library/Sounds` works too**, which is what Add a Sound does. That is
  macOS's folder, not Threading's: the copy also appears in System Settings' alert-sound list,
  an existing file of the same name is never overwritten (identical content is reused,
  different content takes `name 2`), and removing one is a Finder delete rather than an
  affordance this app has to own. The extension is checked against what `UNNotificationSound`
  documents (AIFF, WAV, CAF) *and* the bytes are opened with `NSSound`, because an extension is
  a claim — a mislabelled file would otherwise become a selectable sound that plays nothing.

**The terminal bell is a different sound with a different owner** (`TerminalBell.swift`), and
was not ours at all until now. `TerminalViewDelegate` ships a *protocol-extension* default —
`bell(source:) { NSSound.beep() }` — so a delegate that does not implement the method is not
choosing the system beep, it simply never had a say. `TerminalSession` now implements it, which
is the entire switch: the extension's version stops being called and `TerminalBell` answers.

It is deliberately **not** filed under the notification switches, and its card on the General
page is separate for the same reason: none of them apply. A notification is Threading noticing
something for you, so the master switch, the three kinds and a project's mute each get a say. A
bell is a program writing one byte down the PTY — muting a project does not gag its terminal,
and the bell rings whether or not the session needs anyone. Putting it in the Notifications card
would have made that card's copy false.

Four consequences worth knowing:

- **Both sounds are one `SoundChoice`, and Off is one of its values.** They were two enums:
  the bell had an Off case and the alert did not, because a "Play a sound" checkbox already
  said that for the alert. Once silence became a value the picker offers, the checkbox had
  nothing left to say and two types carried one idea, so the alert's picker gained Off and the
  checkbox retired (`SoundChoice.swift`). What still differs is what `system` *means* — the
  macOS notification tone for an alert, the system alert beep for a bell — which is the kind's
  business rather than the choice's. The stored form is `silent`, `system`, or `file:` and the
  name; the prefix keeps the two reserved words out of the file-name namespace for good, and
  the decode still reads both older dialects (the bell's bare name beside the same two words,
  the alert's bare name or nothing at all).
- **The cause comes first, then one ring.** Both halves of a bell leave the view through the same
  hook — `EmojiFixedTerminalView.bell` → `onBell` — and the order inside it is now *noticed, then
  heard*: `TerminalSession` asks its delegate (`terminalSessionDidReceiveBell`), which records the
  activity edge and answers with the `SoundEvent` that names **why** it rang, and then rings once
  with that cause. It used to ring first and tell the delegate afterwards, with `ring()` knowing
  neither the session nor the reason.
  Three properties are deliberate. The ring belongs to the session rather than to the delegate,
  so a conformer that implements nothing — `ProjectTerminalViewController`, `ShellDrawerViewController`,
  anything else holding a `TerminalSession` — still rings, at the bell kind's own level, exactly
  as loudly as before; nothing goes silent because somebody forgot a method. It rings **once**,
  in one place. And that place knows both the session and the cause, which is the seam the
  double-sound fix below is built on.
- **Silenced is not unnoticed.** The sound and the activity edge are still separate answers to
  one bell: `recordBell()` moves the state whatever the sound resolves to, so a bell set to Off
  still ends the inferred turn and still raises the session's hand in the sidebar.
- **A bell in a background session used to make two sounds**, and the suppress seam is now real
  — pointing the opposite way from how it was drafted. A bell that is actually *heard* leaves a
  note (`AudibleBellRegister`, one `SessionID → Date` map, pruned on touch), written inside
  `TerminalBell`'s play step; `AttentionAlertCenter.stateAlertSound` reads it and posts the
  banner with **no sound** when a bell spoke for that session inside the window
  (`TerminalBellDefaults.audibleBellWindow`, 0.5 s — 2.5× the bell's own limiter, so it covers
  a stalled main-actor turn without reaching a genuinely later alert). The banner, the icon,
  the sidebar's hand and the Notification Center entry are untouched.
  It reports this way round because of *when* each half decides. The draft assumed the alert
  center could report a sounding delivery for the bell to hold against, and it cannot: the ring
  is synchronous inside `onBell`, while the alert's decision is a main-actor turn later — the
  center observes the activity edge through a `Task`, and its `post` reads the project icon off
  disk, which must not land on the PTY's byte path. A guard at the ring would therefore never
  see its own edge's registration and would only swallow the *next* bell.
  The error direction is also better this way. Every uncertainty leaves the **alert** sounding —
  no note, an expired one, a bell the gate held, one the limiter rejected, one resolved to
  `silent`, one from a standalone terminal, which has no alert to collide with anyway. Nothing
  in the seam can quiet a bell, so the failure the finding feared — a bell going missing for
  reasons the user cannot see — is structurally impossible; the worst case is the pair itself.
  `postRequestedUpdate` deliberately does not ask: an update the user told an agent to send is
  not an echo of a bell.

**Why a bell rang is a reading of state that already existed.** `recordBell` returns one of four
`SoundEvent` cases, classified in fixed precedence — `launch → agentVisible → otherProgram →
agentAsking` — from the same three facts its one assignment was already made of. The causes
overlap (another program can ring in a visible session, or during a boot), so the order is the
contract: visibility outranks attribution because the sound's job is telling you what you cannot
see. `bell.otherProgram` is the only heuristic, and it costs a *fresh*
`ProcessUtility.foregroundProcessGroup(ofPTY:shellPid:)` — never the once-a-second reading that
names a terminal, which can be a full second stale — so it is asked only when the resolution
chain holds an entry for that event specifically (`SoundResolution.attributesOtherPrograms`).
Without one it would resolve to the same sound as `bell.agentAsking` and buy a distinction nobody
could hear.

**Which sound any of it makes is `SoundResolution`,** a pure chain shared by the bell and the
alerts, three scopes narrowest first and three levels inside each:
`scope[event] → scope[kind] → scope[all] → next scope out → a per-event built-in table`. The
scopes are the chat's record, then its project's, then the app — a standalone terminal reads
`terminal → project → app` instead — with `AgentSession`, `Project` and `ProjectTerminal` each
carrying one optional `soundOverrides: [String: String]?` (keys: `SoundEvent` raw values plus
the reserved `all`/`bell`/`alert`; values: `SoundChoice` stored strings). The map stays raw at
the storage boundary and every writer read-modify-writes it whole, so a key written by a later
build survives being read and written here; absent — the common case — a record contributes no
scope at all. The app scope is the two existing pickers at the kind level and an unseeded
`soundEventChoices` map beneath them; it deliberately has **no `all`**, because the pickers are
its outermost say. The table at the bottom **is** the pre-scoping behaviour written down: every
bell is the system alert beep, `alert.blocked` and `alert.requestedUpdate` are the macOS tone,
and `alert.unread`, `alert.finished` and `alert.scheduledMessage` are silent. Those three are
*opt-in*: an entry broader than the event applies to them only when it is `silent`, so a broad
stroke can quiet an event that has never sounded but can never voice one. Only an entry naming
the event does that. The limiter is consulted **before** any of it — a rejected bell walks no
chain and `stat`s no file, which a storm used to pay for per byte.

**Which record a bell belongs to is `SoundOwner`,** read off `TerminalInstanceIdentity` at the
one ring site: agent sessions and their shells resolve as the session, a standalone terminal as
its terminal record, an ephemeral surface as nothing — and nothing goes silent for lacking a
record, it just resolves at the app scope the way every bell once did. A terminal resolves
through its **`homeProject`**, not the cwd-derived project the theme menus use: `displayProject`
runs `GitInfo.worktreeIdentity`, a child process, and a bell arrives as fast as a program can
write a byte. The submenu reads the same scope, so what it says is what rings.

**The writers store nil where the value matches what would have been inherited** — the mute
item's rule, applied at every scope — so a chat keeps *following* its project, and a later
change there still reaches it. The one-click *Sounds* submenu (beside Theme on all three row
kinds, `ProjectSidebarSoundMenu.swift`) writes only `scope[all]`; its *Inherit* item names the
inherited answer through `SoundResolution.uniformAnswer` **only when every voiced event agrees**
(opt-in events abstain), goes plain when they differ — the ordinary state right after migration,
since the app's bell and alert tones differ — and label and writer read the same function, so
they cannot disagree. Its *Customize… / Customize (N Events)…* item is a door to the sheet and
never clears anything: a menu item that silently discards configured choices is a trap, so
clearing lives on the sheet's *Reset All*, a surface that shows what is being reset.

**The Customize sheet is one sheet at every scope** (`SoundCustomizeViewController`), because
the difference between scopes is answered by `SoundScope` — the storage seam that knows a
record keeps its whole say in one map while the app's is spread across two preferences and the
event map. Each row's *Inherit* parenthetical is `SoundResolution.inherited(_:at:beyond:)`:
resolution with only that row's own entry removed, everything else standing, which is also the
exact expression its writer compares against. At the app scope the word is **Default**, the
theme scope's word for the same position, and the two kind rows are literally the page pickers'
storage. *Reset All* drops a record's **whole map, unknown keys included** — a scope with
nothing left to say must be indistinguishable from one that never said anything, and a later
build's key left behind would keep answering in the chain something the sheet did not show.
Settings' **Custom sounds** section is the audit: a live scan of the store (no cache, capped
before any view is built), one row per scope carrying an override, each a *Reset* and a door to
its sheet. Project and standalone-terminal rows name a non-inherited sound in their tooltip. A
session row keeps no tooltip by design, so its hover card names the override beside the branch
configuration. Absent overrides add no line.

**The global silence gate is a gate, not a scope** (`AppSettings.silencesAllSounds`): it writes
to no override map, so releasing it gives every scope back the answer it already had. The bell
checks it **ahead of the limiter** — a silenced storm costs one Boolean per `BEL` and must not
consume the window, or the first bell after the gate opens would be the one swallowed — while
the alert paths inherit it from one seam, the `@MainActor` conveniences over the pure chain
(the chain itself stays gate-free). Banners still post, the sidebar still raises its hand.
Auditions bypass it deliberately: a sound picked in a list is an explicit ask to hear it, and a
picker that played nothing would read as broken. Three surfaces write the one Boolean — the
speaker at the sidebar footer's trailing edge (audible speaker while open; slashed speaker plus
the selected surface while silenced), the mirrored Settings row, and Threading ▸ Silence Sounds
(⇧⌘S, `AppCommand.Group.system`, which Recovery Mode allows wholesale) — and all three follow
`AppSettingsDidChange` rather than each other. macOS Focus cannot do this job: it silences
notification sounds but not the bell, which the app plays itself through `NSSound`.

**The gate reaches a third sound** (`SystemAlert.swift`). Beside the bell and the alert, the app
beeps when it cannot do what it was just asked to do: a menu item with no folder behind it, a back
step with nothing behind it, a Quick Look that will not open, a tab that cannot be selected. That
beep was written out longhand at fifty-eight call sites, so the gate — which reaches
`SoundResolution` and `TerminalBell` — silenced two of the app's three sounds and left the most
frequent one audible. It is the one shape of bug a silence switch does not survive: the user asks
for quiet, hears a beep, and concludes the setting is broken. `SystemAlert.refuse()` is now the
single way to make it, and it asks `SoundResolution.isSilenced` rather than reading the setting,
so there is one seam and not two.

It is a **gate and not a choice**: no `SoundEvent` case, no scope chain, no picker row. This is the
platform's refusal tone rather than a sound anybody selected, and the only question worth asking of
it is whether the app may be heard at all. Nothing visual is implied either — a refusal the user
has to understand still needs words where they are looking, and this is only the sound that goes
with them. `scripts/check_architecture_boundaries.sh` fails the build on a bare `NSSound.beep()`
anywhere outside `SystemAlert` and `SoundPlayer`, because fifty-eight call sites is what a rule
with nothing enforcing it looks like after a year.

**An automated run makes none of it** (`AutomatedRun.swift`), refusal and bell alike. The two lanes are two
processes and need two answers. `scripts/test.sh fast` and `all` host the test bundle *inside* the
shipping app on the developer's own machine, which `StateManager.isHostedTest` already names — and
a test drives exactly the branches this sound lives on, since a fixture has no window, no folder
and no browser, so every refusal was audible in the room from a process with nothing on screen to
account for it. `scripts/test.sh ui` loads no test class into the app at all; what it leaves is the
disposable Cocoa home the runner builds, so the scenario marker `UIScenarioBootstrap` already fails
closed without is the honest signal there. `TerminalBell.ring` reads the same value beside the
user's gate, so a fixture writing `BEL` down a PTY is held for the identical reason. Both answers
stay out of `SoundResolution.isSilenced` deliberately: the sidebar's speaker and the Settings row draw the
*user's* answer, and a scenario screenshotting a silenced app would be photographing a state
nobody is in. The exemption is the beep, not the judgement — `AttentionAlertCenter` and
`ScheduledMessageNotifier` already refuse to post under test for the same reason.


The stored preference is `attentionAlertSound`, unseeded: an absent key is the macOS tone, which
is a real answer rather than a missing one. `AttentionAlertCenter.chosenSound(for:sessionID:)` is
the one place that reads it, since the two posting paths had already drifted into asking half the
question each — and it is now one question rather than two, because `silent` is a value of the
answer. All three alert paths ask it with their own event: the state alerts, the requested update,
and `ScheduledMessageNotifier`, whose banner is silent as an *answer* now rather than as an
omission. `AttentionAlert.sounds` is gone with them — whether a kind sounds was a property of the
alert, and it is a row of the terminus table.
The retired checkbox carries over once, in `AppSettings.migrateAttentionAlertSoundSwitch`: an
unchecked box becomes `silent`, a checked one writes nothing, and the old key is removed, which
is what makes the migration its own marker. **Choosing in the picker plays the sound**, the way
every alert-sound list does; Off and the default item are the two that cannot, because macOS's
notification tone lives in a private framework rather than in a folder a name resolves in, and
the system beep is a different sound.

**Clicking one opens its session through the sidebar**, on the same path as a local click —
`SessionNotificationOpened` → `ProjectSidebarViewController.select`. That path fails *silently*
by construction: a row that is not on screen has no index, `row(forItem:)` answers `-1`, and
every guard along the way reads that as "nothing to do", so the app simply stays where it was.
So the arrival has to open every level above the row first, and the chain is longer than the
sidebar looks — repository heading, project, branch heading, and the session a **side chat**
was forked from. That last level was missed, which meant a notification from a side chat the
user had folded away switched to nothing at all. `SidebarTreeBuilder.ancestors(of:in:)` walks
it, from the roots down rather than up from the row, because `NSOutlineView.parent(forItem:)`
only answers for an item it has already been asked to display. Settings is the other way in
from off screen: it replaces the session list entirely, so the arrival leaves it the way Back
does.

`Notification` is the one event with no Codex equivalent in 0.144.6, which is why
`HookLifecycleEvent.codexEventName` is optional and pinned by a test.

**Codex reports the same events, and everything hard about it follows from one difference:**
it has no `--settings` flag. Hooks live in `<CODEX_HOME>/hooks.json`, one file per *account*,
shared by every session — and owned by the user. Measured on 0.144.6: `codex exec` does fire
hooks, and the payload is Claude's apart from the spelling — `session_id`, `turn_id`,
`transcript_path`, `cwd`, `hook_event_name`, `prompt`, and `last_assistant_message` on `Stop`.

**An interrupted terminal turn is the exception.** Measured on Codex 0.147.0: submitting a
prompt fires `UserPromptSubmit`, but pressing Stop returns the TUI to its prompt without firing
the configured `Stop` hook. The rollout states the missing edge exactly as an `event_msg` whose
payload is `turn_aborted`, carries the same `turn_id`, and says `reason: "interrupted"`. Without
that edge, the hook latch correctly refuses to fall back to terminal silence and the session
stays `working` forever; the same stale fact also keeps `watch_session` and sibling delivery
gates waiting.

The `.transcriptInterruptedTurnRecord` capability gives Codex terminals this fallback. The
controller remembers the hook's validated `transcript_path` and, after a PTY output burst settles,
revalidates one `TranscriptFactReader` against it. The common path is a background `stat`; growth
scans one bounded tail chunk, and the callback moves state only when the newest lifecycle boundary
is the structured interruption for the tracker's active turn id. It never parses the red
"Conversation interrupted" presentation string. Matching the id is load-bearing: the read is
asynchronous, so a late result from turn A must not stop a newer turn B. The admitted edge settles
through `SessionActivityTracker`, exactly like `Stop`, which is why the sidebar, alerts, control
plane and waiting deliveries all agree again.

The reader is **single-flight with a trailing wave**, not "ignore while busy". A file can append
its last lifecycle record after an in-flight scan took the size snapshot but before that scan
returns. The output callback for that append may be the final callback of the turn; discarding it
leaves the cached size and activity state behind forever. Requests that overlap a scan therefore
coalesce into exactly one follow-up scan, while every waiting caller receives the changed fact.
The size snapshot comes from current filesystem attributes, not `URL.resourceValues`: Foundation
caches requested resource keys on a reused URL value, which turns an append-only transcript's old
size into a permanent answer and defeats the invalidation the reader is built around.

**A refused request is the same hole, on Claude.** Measured on CLI 2.1.226 against this app's own
session `e7a26edf`: `UserPromptSubmit` fired at 12:26:02.464, an expired login was recorded 23 ms
later as `{"type":"assistant","isApiErrorMessage":true,"error":"authentication_failed"}` carrying
"Login expired · Please run /login", a `system`/`turn_duration` was written beside it, and no
`Stop` ever came. The turn start had already latched the session, so the sidebar drew a spinner
for a conversation that had stopped — the same stale fact, from a third direction. Neither
existing fallback covered it: `.transcriptInterruptedTurnRecord` is Codex's and reads
`turn_aborted`, and `ClaudeTranscriptUsageLimit` admits only `rate_limit`/`429`, deliberately, so
a network fault or a login is not treated as a spent account.

`.transcriptRefusedTurnRecord` gives Claude terminals the fallback, and it is the *complement* of
the limit reader over one record shape: `ClaudeTranscriptAPIError` holds the parse and the
newest-message walk, `ClaudeTranscriptUsageLimit` takes `isRateLimit`, `ClaudeTranscriptTurnRefusal`
takes the rest. Split any other way, the two would disagree about what a rate limit is the first
time a CLI version moved a key — and disagreement means a login failure recovered as if the
account were spent, or a spent account quietly marked unread.

Two rules are load-bearing there. The refusal carries the failing record's **`uuid`**, because the
reader calls back only when the answer *moves* and an expired login refuses every turn with the
same class and the same sentence; the intervening user record cannot be relied on to reset it,
since the failure lands half a second after the prompt, inside one settled output burst. And
admission is matched to the turn by a **generation count** rather than a provider turn id, because
Claude's payload names no turn at all: `SessionActivityTracker.turnGeneration` counts turns begun,
the output callback reads it when its background scan starts, and a result that outlived its turn
is refused. It settles exactly like `Stop` — a visible session goes `idle`, an off-screen one takes
the unread mark. Not `limitReached`: nothing here says the account is spent, and a row claiming so
sends the user to a usage dashboard to explain a login.

**An interrupted turn is the same hole again, and Claude's is the fourth instance of it.** Measured
on CLI 2.1.238 against this app's own session `a056a54c`: `UserPromptSubmit` fired, the user pressed
Escape, and at 06:17:52.733Z the CLI appended one record and stopped —

```json
{"type":"user","uuid":"5ec9af64-…","interruptedMessageId":"msg_011CeFQXqQY5Z7Ur3FJfZckF",
 "message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}
```

— and no `Stop` followed. The row was still drawing a spinner two hours later, for a conversation
the user had stopped themselves. `.transcriptInterruptedMessageRecord` and
`ClaudeTranscriptInterruption` close it, on `ClaudeTranscriptAPIError`'s newest-message walk and the
generation match the refusal reader uses, settling exactly like `Stop`.

It is deliberately **not** the same capability as Codex's `.transcriptInterruptedTurnRecord`,
because the two records differ in the one way that matters to a late asynchronous read: Codex names
the turn it aborted, so its reader can prove which turn the result belongs to, while Claude names
only the assistant message it cut off — and names nothing at all when the interrupt beat the first
token, measured on 2.1.222. So Claude's reader matches `turnGeneration` instead, and admits the
marker sentence as well as `interruptedMessageId`: a reader insisting on the id declines every
interrupt pressed before the model spoke, which is the interrupt a user is most likely to press.
The cost of admitting the sentence is one shape it cannot tell apart — a user who types the marker
verbatim as their own prompt — which ends that prompt's turn a beat early and leaves the session
correctly idle.

**Both of Claude's fallbacks are asked on the terminal-output quiet edge**, in one
`scheduleClaudeBoundaryRefresh` rather than a timer per fact: the two readers answer off the same
tail of the same file, for the same session, on the same burst. That is also the bug the fourth
instance uncovered — the refusal fallback shipped wired to `noteReportedCodexTranscript`, behind a
guard only Codex passes, so it had never run for a single Claude session. A fallback for a runtime
that cannot reach its own entry point is worse than none, because the reader, the capability and
the tests all pass while the hole stays open. The Claude schedulers hang off
`terminalSession(_:didProduceOutputOf:)` beside Codex's, and both are gated on
`reportsOwnActivity` and a turn actually being in flight, so a session sitting at its prompt does
no work at all.

- **Routing is by environment, not by file.** `MCPDefaults.portEnvironmentKey` and
  `sessionTokenEnvironmentKey` are exported by `routed(_:for:)` and read by the hook command,
  which is what lets one shared file attribute every session correctly. Verified that a hook
  inherits the launch environment.
- **Which is also what keeps the file *stable*.** Codex pins a trusted hook by hashing its text,
  so a URL carrying today's port would revoke the user's trust on every app launch.
  `CodexHookInstaller` therefore rewrites only on a real change, and a second install returns
  false.
- **`CodexHookInstaller` merges rather than replaces**, marks its own entries with
  `MCPDefaults.hookMarker`, and removes only those on uninstall. This machine's own
  `~/.codex/hooks.json` was written by another tool, which is why that is a rule and not a
  nicety.
- **The pre-rename marker is ours too, but a known old command is not rewritten.** The product
  rename changed the launch environment from `SKALMAN_*` to `THREADING_*` and the marker from
  `# skalman-lifecycle` to `# threading-lifecycle`. Codex trusts the hash of the command text,
  so replacing a working old command would revoke the approval needed to fix the activity bug.
  Launches with the integration enabled export both vocabularies with identical values instead;
  the installer recognises the exact commands the old release generated and leaves them
  byte-for-byte intact. An unknown
  command carrying the old marker is still replaced, and uninstall removes either generation.
  `AppSettings` carries the old install opt-in only when the current domain has no choice. It
  also carries an old trust-bypass `true` while installation remains enabled: that is the same
  explicit launch posture the user chose before the bundle-id rename, not a new default. Any
  current value wins.
- **The command guards on the token** (`[ -n "$THREADING_SESSION_TOKEN" ]`), because the file is
  read by every Codex run under that account, including the ones the user starts themselves.

Both halves are opt-in and separate (`AppSettings.installsCodexHooks`,
`bypassesCodexHookTrust`), because only the second has a security cost: installing writes to a
file the user owns, while `--dangerously-bypass-hook-trust` un-gates *every* hook in that folder
rather than only ours — and an agent can write to `hooks.json`. The safe path is one manual
approval in the Codex TUI, which the stable-text rule is what makes viable.
The hosted XCTest process never runs the installer against a discovered account: launch-plan
tests run inside the shipping app and otherwise inherit the developer's real `CODEX_HOME`.

`SessionStart` also **replaces `CodexSessionDiscovery`'s job**: it hands over `session_id`
already attributed by the token in the URL, where discovery watches the rollout directory and
matches on a launch timestamp. `AgentRuntime.adoptReportedIdentifier` only updates a session
still `awaitingIdentifier`, so Claude's own report — of an id Threading minted — is a no-op.

**Codex brokers permissions on the same hook, and honours the answer.** Measured on 0.144.6: a
`PreToolUse` reply of `permissionDecision: deny` stops the tool outright — the run logs
`PreToolUse Blocked`, the file was not written, and the reason reaches the model, which then
explains itself in its own words. Its payload names the tool with the same `tool_name` /
`tool_input` keys Claude uses, so `MCPServer.routePermission` parses both unchanged. What
differs is the *vocabulary* inside: the tool is `apply_patch` and its argument is a
`*** Begin Patch` envelope, which is the same mismatch `TranscriptReplay.normalised` and
`CodexPatch` already exist to absorb.

`ToolIdentity` knows **both vocabularies**, which is what the type is for — a behaviour,
independent of the provider spelling that introduced it. Codex's names were taken from 1008 real
rollouts rather than from a list, which is the only reason the long tail was found:
`exec` / `exec_command` / `shell_command` / `write_stdin` → `.bash`, `apply_patch` → `.edit`
(a patch has old *and* new text, so it feeds the same `DiffView`), `view_image` → `.read`,
`update_plan` → `.plan`. Everything Codex-specific — spawning agents, goals, simulators — stays
`.unknown` on purpose, because mapping a tool onto an identity also hands it that identity's
permissions.

**This fixes rendering, not prompting, and the difference is worth stating.** Measured across
those rollouts: 59,335 of 64,785 calls (92%) previously drew as unrecognised tools and now carry
the right glyph and diff — but only 204 (0.3%) become auto-allowed. 82% of all Codex tool calls
are shell execution, which legitimately prompts.

That asymmetry is Codex's, not ours: Claude has distinct `Read` / `Grep` / `Glob` tools that the
allowlist can admit, while Codex reads files by shelling out. So the *command* has to be read,
which is what `ShellCommandPolicy` does — the same thing Codex's own `untrusted` approval policy
does, and the only way one tool name covering both reading and writing can be judged at all.

**It is built to be wrong in one direction only.** A missed approval costs a click; a wrong one
runs something destructive unasked. So the allowlist is short and explicit, and anything that
could reach a command the policy never sees is refused outright: redirection, substitution,
backgrounding, a leading variable assignment, an absolute path in place of a bare name. Splitting
on operators is deliberately naive, and that is safe *because* it is naive — a `;` inside a
quoted argument splits into a segment whose first word is not allowlisted, so the line is refused
rather than admitted.

**Naming a command is not enough, and for a long time this file said it was.** The allowlist was
described as holding "only commands with no write mode at all", with `find`, `git` and `sed`
carrying their own rules. That claim did not survive being checked against the binaries. Every
one of these was on the allowlist, classified read-only, and auto-approved without a prompt:

- `fd -x`, `-X`, `--exec`, `--exec-batch` — run an arbitrary command per match. The `find` rule
  next to it tested `hasPrefix("-exec")`, which none of `fd`'s spellings begin with.
- `rg --pre=CMD` and `--hostname-bin=CMD` — execute CMD.
- `sort -o FILE`, `tree -o FILE`, `git diff --output=FILE`, `yq -i` — write an arbitrary path.
- `uniq IN OUT` — writes its second *operand*, with no flag to spot at all.

Two things follow. Each allowlisted command now carries the flags that turn it into a writer or
an executor, named per command because the same spelling is harmless elsewhere — `-o` prints only
the match to `grep` and writes the result to `sort`, so banning it outright would make the most
common search in the corpus prompt. And long flags match exactly or up to their `=`, never by
bare prefix: `rg --pretty` starts with `--pre`, and refusing it would break an ordinary read.

**Arguments are read unquoted.** Separately and worse, every rule here is a prefix test against
the line *as typed*, while the shell runs it with the quotes stripped — so `find . "-delete"` and
`find . -delete` are one call, and only the second was refused. Verified against the real
binaries: the quoted form removed the file. Arguments now have one layer of matching quotes
stripped before any rule sees them. The command *name* keeps its quotes, so unquoting can only
ever refuse more, never admit more.

Three further rules came from measuring 5,165 real Codex commands rather than from reasoning, and
each was wrong first:

- **`sed` had to be admitted, narrowly.** `sed -n '1,220p' file` is how Codex *reads* — 42% of
  its shell calls — and refusing it left the classifier admitting 20% of real traffic. It is
  also the one allowlisted command that can write (`-i`, `-f`, a `w` in the script), so the
  *script itself* must be a bare line range ending in `p`. Of 2,650 real calls, none used `-i`
  or `-f`.
- **`&&` is a chain, not a hazard.** Banning the character outright made a chain of reads
  prompt, which is most of them; every link is vetted independently instead, and a *lone* `&`
  is still refused because it detaches what came before it.
- **`sed -n '10,$p'` prompts anyway**, and is left prompting: the `$` ban runs first and cannot
  tell `$p` inside single quotes from a variable without tracking shell quoting. Refusing a rare
  legitimate form is the price of not having to be right about quoting.

Together those take real-world coverage from 20% to **59%**, measured by
`ShellCommandPolicyCorpusTests` running the policy over this machine's own rollouts — the unit
tests pin the rules, that one pins the thing the rules exist for, and it fails if a change
quietly undoes the measurement. A second corpus test asserts nothing destructive is ever
admitted.

The `PreToolUse` entry is written **unconditionally** and guarded on
`MCPDefaults.brokerEnvironmentKey`, which only `streamPlan` exports. Installing it per-surface
was the obvious alternative and is wrong: `hooks.json` would be rewritten every time a session
changed surface, and every rewrite costs the user's trust decision. An entry that is inert
until an environment variable appears is how one shared file serves two surfaces.

**A hook is invisible by construction**, which is the same problem `ProjectIconResearch` has and
is answered the same way: every run leaves a record. `EventLog.Category.hooks` is the durable
half, and it is deliberately *not* fed per turn — the boundaries themselves go to
`ThreadingLogger` at `.debug`, which is the live `log stream` view, while the journal keeps only
what a report weeks later would need:

- **The one transition that matters** — a session going from inferring its state to being told
  (`AgentRuntime.applyLifecycle`). "Did the hooks reach this session at all" is the first
  question any bug report raises, and this is the only line that answers it.
- **Every rejected report** — an unknown token, an unnamed event, an empty body. A report that
  arrived and was refused looks exactly like a hook that never ran, and the causes are
  unrelated.
- **A rewritten `hooks.json`**, because a rewrite is the moment the user's Codex trust decision
  stopped applying. It is the answer to "these worked yesterday".
- **A launch with no listener port**, which silently disables the whole feature.

`HookOutcomeLog` covers the one failure the app cannot otherwise see: a hook that never
*reaches* the listener leaves nothing here, because nothing arrived — while the agent sits on a
blocked tool. `--include-hook-events` is passed for that and only that, and Claude's
`hook_response` carries the `outcome`, `exit_code` and `stderr` this side never observed
(verified against a hook made to exit 7). It is read outside `StreamEvent`, which is a pure
function feeding the conversation's rendering: a diagnostic nothing draws does not belong in the
model the views are built from. The parsing is split from the logging so the decisions are
testable, and a *missing* `outcome` counts as a failure — the schema belongs to the CLI, and a
renamed field should make the journal noisy rather than quietly stop reporting.

One bug worth keeping: every command reads stdin **before** its guard
(`threading_payload=$(cat)`). A guard that returns without reading leaves Codex writing the event
into a pipe nobody drains, and it is the *unrouted* runs — the user's own terminal sessions —
that would pay for it. Found by a probe whose hook posted an empty body, and pinned by a test.

## The account's own status line

Claude draws a status line from its **interactive TUI** only. The runner is driven by an Ink
component's effects and renders into a `<Text>` in that tree, so a native conversation — which
runs `--print --output-format stream-json` and mounts no TUI — never invokes the command at all.
(The guards inside the runner itself are `disableAllHooks` and workspace trust; the print-mode
answer comes from the component never mounting, not from a check in the runner.) So a terminal
pane may already be showing the user facts a native pane never is.

**Threading does not ask what the line prints, and that is the current decision rather than an
omission.** `ClaudeStatusLineCoverage` used to run the account's own command with a truthful
payload and search the output for values the app already held, so the session's status card
(see [`git.md`](git.md)) could add only the facts the line left out. It worked, and it was not
worth what it cost: a subprocess per unseen command on a surface that refreshes on every session
switch, a `UserDefaults` cache keyed on the command and the CLI version, a payload document kept
in step with the CLI's schema, and a match rule whose *only* failure direction was hiding a fact
the user had asked to see — a script that abbreviated "Opus 5" past recognition duplicated it,
and one that printed something unrelated containing the branch name erased the branch. What it
bought was one fact appearing twice inside one pane. **The card now shows every fact it can
extract, always**, and duplication is accepted as the cheap outcome. `ClaudeStatusLineSettings`
is what is left: settings resolution, which reads files and runs nothing.

Two findings from that work are worth keeping, because they constrain anyone who reaches for a
probe again. **Coverage could not be read off the configuration** — the command is the user's own
program with the user's own authority, and the line on the machine this was written against
ignored the `total_lines_added` and `rate_limits` handed to it, printing `+1699 -331` and `5h 0%`
from its own `git diff --numstat` and `curl` instead. And **a status line is commonly a caching
bridge**: the one here writes `~/Library/Application Support/Claudex/ClaudeStatus/<profile>.json`,
which is the file `ClaudeUsageCache` reads back for the account's usage. An early design probed by
substituting sentinel values to see which were echoed; against a bridge that would have cached
Threading's own fiction and fed it back as the account's usage. Anything that runs the user's
status line passes only truth.

**The line can be suppressed** (`suppressesClaudeStatusLine`, off by default, on the General page
beside the hook switches). The override rides the same per-session `--settings` file as the hooks,
which was *verified* to outrank every writable layer for this key — and it must be shaped
`type: "command"`, because `type: "none"` fails the CLI's schema and a failing settings file is
skipped **whole**, permission hooks included. The account's own command keeps running inside
`ClaudeStatusLineSettings.silencedCommand`'s wrapper with both streams discarded: these commands
are commonly the caching bridges described above, and hiding the line must not starve what they
feed (verified — the wrapped bridge still wrote its heartbeat while printing nothing). Terminal
launches only — a native pane never mounts the component, so its settings file says nothing
about it.

Precedence follows the CLI's, which for this key is **not** a merge: a managed policy replaces the
user's `statusLine` outright, and below that `.claude/settings.local.json`,
`.claude/settings.json` and the account's `settings.json` override most-specific-first. Only
`type: "command"` resolves; any other shape draws nothing, so there is nothing to silence.
