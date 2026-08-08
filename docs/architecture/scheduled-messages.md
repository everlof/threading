# Scheduled Messages

Writing something now and sending it later — a reply to a session that exists, or the brief that
starts one that does not.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

## One record, two payloads

`ScheduledMessage` carries both cases, because they share a clock, a store, a strip and every rule
about what happens when the moment arrives. Splitting them would be two of everything below.

- **`.session(SessionID)`** — a reply, scheduled from the conversation's own composer.
- **`.newSession(ScheduledSessionPlan)`** — a session start, scheduled from the draft view. The
  plan is a **frozen copy** of every decision beside the brief: agent, login, model, effort,
  speed, branch, surface, permission mode. Not a reference to the composer — the chips will have
  moved on by Monday morning, and a plan that read them then would start whatever happened to be
  selected. Speed keeps the same three-state meaning as the composer: nil follows General when
  the session eventually starts, while Standard and Fast remain explicit conversation overrides.
  `AccountHandle` is deliberately not `Codable`, so the handle rides as `persistedSessionName` and
  is rebuilt with `init(storedName:)`, which is the spelling every other persisted copy uses.

**Images are unschedulable, and the composer says so rather than dropping them.** A pasted
screenshot is a file in a temporary directory, and a path written down now can name nothing by
Monday — the reason [`persistence.md`](persistence.md) already refuses to *draft* them. Scheduling
is that hazard with a longer fuse, so the affordance is disabled with its reason on the tooltip.

**The record keeps the instant and the words.** `dueAt` is an absolute `Date`; `intendedTimeZone`
and `intendedWallClock` are what the user actually chose. They disagree the moment a machine
changes zone — "tomorrow at 09:00" set in Stockholm and opened in New York fires at 03:00 while
every label relabels itself to 03:00, which would make the sheet's named time zone a promise the
record could not keep. `NSSystemTimeZoneDidChange` re-derives `dueAt` from the components. A
reset-anchored send is left alone: a window's boundary is an instant, not a time of day.

## The store is a file, and it is written on the mutation

`ScheduledMessageStore` is a `RecoverableFileStore` at `scheduled-messages.json`, criticality
`.userAuthored`, beside the drafts it is a longer-dated cousin of.

**A file rather than a row in `threading.db`.** Columns exist to be ordered by, filtered on or
joined, and nothing here is: it is a handful of records read whole at launch. What it does need is
the contract `DraftStore` and `SessionContinuityStore` already have — synchronous user-authored
writes, quarantine rather than deletion — because once the composer is cleared this is the only
copy of something somebody wrote. A scheduled message is a draft with a due time.

**Refuses rather than evicting.** Per-target and global ceilings, both stated as values
(`ScheduledMessageStore.Refusal`) so the strip and any later adapter word them their own way. A
queue that quietly forgets what somebody wrote is worse than one that says it is full.

**Pruned inside `ProjectStore` itself**, beside `ConversationHandoffStore.remove` and
`ExecutionAuditStore.remove`. Not from the sidebar's delete gesture, which is where
`SubagentStateStore`'s sweep lives: Settings ▸ Archived deletes sessions straight through
`removeSession` without going near the sidebar, and a send left behind would keep naming a session
that is gone.

**`init(directory:)` exists for the tests**, for `DraftStore`'s reason: the bundle is hosted in the
app, so a store that always resolved Application Support would have every run editing the
developer's own scheduled sends.

## The clock knows only when

`ScheduledMessageScheduler` is `SessionArchiveScheduler`'s shape one feature along: it announces
(`ScheduledMessageDidBecomeDue`) and `SessionCoordinator` performs. Nothing in Core knows about
sidebars, surfaces or launching, which is what keeps `check_architecture_boundaries.sh` satisfied
and what makes the rules testable with no live agent.

**`Date()` is the only authority.** Nothing counts elapsed intervals: a timer does not fire while
the machine sleeps, and one armed against uptime is wrong after an NTP step. The triggers exist to
make the comparison happen often enough, not to measure anything — a wake, an activation, a clock
step, a zone change, a store mutation, and one five-minute heartbeat while something is pending.

**Two notification centres, and the second is not optional.**
`NSWorkspace.didWakeNotification` is posted on `NSWorkspace.shared.notificationCenter`, never on
`.default`. A scheduler observing only the default centre compiles, runs, and silently never
re-evaluates after sleep — which is the single case the class exists for.
`ScheduledMessageSchedulerTests` posts the wake on the workspace centre precisely so that mistake
fails a test rather than a user's morning.

**Started behind the relaunch's two gates**, from `restoreSelectedSessionIfReady` rather than
`applicationDidFinishLaunching`: a scheduled start reads the MCP port for `--mcp-config`, and one
firing into the window onboarding is still deferring gets a PTY in a pane nobody will see.

## Nothing is sent that the clock passed while the app was closed

There is **no grace window and no automatic late delivery**. Threading is not a server. Anything
whose moment passed while it was not running becomes `.missed`, is reported once
(`ScheduledMessagesWereMissed`), and waits for the user — the strip shows it with **Send now**
beside it. The rule is one sentence: *the app does not send what the clock passed while it was not
watching.*

A separate `.waiting(reason)` covers the other half — due *while* the app is running but not yet
deliverable. Those keep trying for as long as the app runs and stay visible while they do;
undelivered at quit, they join the next launch's missed set.

## Delivery, and the question a woken session asks

The performer **claims before it acts**: `ScheduledMessageStore.claim` is an atomic take, because
in the app there is one `SessionCoordinator` but the hosted test bundle builds
`MainWindowController` in a good many test methods. `SessionArchiveRequestDidBecomeDue` survives
that only because re-archiving is idempotent; a send is not.

| Target at fire time | What happens |
|---|---|
| Native chat, running | `SessionMessageDelivery.deliver` — sent, or queued visibly behind the turn |
| Terminal, between turns | typed, Return in its own write |
| Either, mid-turn | `.waiting`, retried on the activity edge — **only** where the agent reports its own turns |
| Dormant, native | `launchInBackground(sessionID:initialPrompt:)` — laid out offscreen, never takes the pane |
| Dormant, terminal | **`.waiting`. Never typed into.** See below |
| `.newSession` | plan re-validated, session created, launched in the background |

**Waking a dormant session is a deliberate departure from
[`control-plane.md`](control-plane.md).** Slice one refuses to resume a dormant target because
"resuming is the user's decision, made by selecting the row" — exactly right for one agent
messaging another. Here the actor *is* the user, and the decision was made in advance and in
writing; a scheduled send that would not wake a session is useless in the overnight and weekend
cases it exists for.

**A woken terminal is never typed into, and this is the sharpest rule here.** `AgentLauncher`
omits the opening prompt on `--resume` — verified against the installed CLI, where nothing in
`claude --help` answers the restore question non-interactively — so a resumed TUI can only be
*typed* into. And a resumed Claude comes up on its own question about whether to summarise the
conversation or read it in full. Answering that question with the user's message, unattended and
unseen, is the outcome worth refusing over. The app cannot even tell the two states apart:
[`session-activity.md`](session-activity.md)'s unattended-launch grace deliberately ignores the
idle-prompt `Notification` that would distinguish "at its prompt" from "on a question". **Absence
of evidence is not readiness.** A fresh `.newSession` start is unaffected — its brief rides the
command line, and there is no restored conversation to ask about.

**A frozen plan is re-validated before it runs.** `SessionCoordinator.targetProjectID` falls back
to the base project when a named checkout is gone, which is right for a composer somebody is
looking at and wrong for an unattended 09:00 start that would then run in the wrong folder. The
branch, the folder's existence and the account's discoverability are each re-checked; any of them
missing fails the send visibly.

## Presets, including the one Slack would never have

`ScheduledTimePresets` is pure — a function of `(now, calendar, locale)` and a usage reading — so
every rule is a test and none of it lives in a view.

- **In an hour**, rounded up to the next five minutes. The one a coding-agent composer wants most:
  *start on this after my meeting*.
- **Tomorrow at 9:00**, and **Monday at 9:00** — suppressed on Sunday, where it would name
  tomorrow twice. One moment under two names is a bug in a menu, not a choice.
- **When the 5-hour / weekly window resets**, with the absolute time *and* the remaining span.

**`Calendar` does the arithmetic, never `+ 86_400`.** "Tomorrow at nine" the day before a
daylight-saving transition is 23 or 25 hours away, and the seconds-arithmetic version is silently
an hour wrong twice a year — in the direction that matters, since the whole point of the preset is
to land at the start of a working day. Both transitions are tests.

### The reset presets

Everything needed was already modelled: `AccountUsage.Window` carries `resetsAt`,
`windowDuration` and `compactName`, `UsageDefaults` names `5h` and `7d`,
`AccountUsageService.usage(for:)` answers **synchronously from cache** so the menu builds without
a round trip, and `UsageFormat` already writes these strings for the popover.

A **model-scoped** window wins when it is the one metering what this session will run — offering
the account's weekly window while `7d Fable` is spent would name the wrong clock. A window with no
`resetsAt`, or one already expired, is **absent** rather than disabled: the same silence every
other usage surface keeps when there is nothing to report. The moment aimed at is the reset **plus
a minute**, because landing on the same second the provider rolls its counter is a send racing it.

### When the window has not actually reset

`resetsAt` is a reading — refreshed on an interval, sometimes served from a local cache, and it
moves. So a reset-anchored send can arrive to find the window still spent, and there is no single
right answer. All three ship, chosen in **Settings ▸ Usage Windows**
(`ScheduledResetPolicy`, stored through `PreferenceStore` for the reason that page's own settings
are):

| | |
|---|---|
| **Send it anyway** | Predictable; a stale reading wastes the turn |
| **Wait once** *(default)* | Stand aside once for the new moment, then deliver regardless |
| **Wait until it resets** | Keep standing aside, bounded by `maximumResetRearms` so a misreported window cannot become an unbounded chase |

## Where it appears

**The chevron beside the send, in chat.** `PromptView.scheduleMenuProvider` — **nil means no
chevron**, which is what keeps the inspector's note and Help ▸ Report a Problem exactly as they
were. It is drawn only while the glyph is a Send: in `.working` the glyph is a Stop, and a chevron
welded to a Stop reads as "stop, in other ways", which is not a sentence.

**A clock button on the draft view's action row**, beside Start. Deliberately *not* a `ChipView`:
out here a chip joins the row above the box that answers where and who and nothing else, and in
the box's footer it would claim to be something the session runs *with*, which scheduling is not.
An icon that opens a menu is the same gesture the chevron makes, in the place the send already is.
A split Start button was the other candidate and was rejected: `ThemedButton` has none of
`drawsSurface`/`isRaised`/`surfaceStateDidChange`, so welding a chevron to a filled accent plate
means teaching every button in the app to stop drawing its own surface.

**`ScheduledMessageStripView`, above the composer** — and deliberately *not* rows in
`ConversationOutboxRailView`. That rail computes a drag's index across every pending row and hands
it to `ConversationOutbox.movePending`, which counts in outbox terms, so scheduled rows mixed in
would shift every drag by however many sat above — silently, because `movePending` clamps rather
than refuses. Its `Row.id` is a `ConversationMessageID`, and one flag gates draggability, removal
*and* editing together, so "ordered by the clock, still removable" is not a state it can express.

**An empty strip leaves the column rather than hiding in it.** A hidden arranged view is detached
from a stack's layout but is still a subview with constraints of its own, and that was enough to
pull the draft view's column off the pane's width — which
`ComposerWindowFitTests.testTheColumnFillsThePaneUpToItsCap` caught. A view with nothing to say
leaves the room.

## What this deliberately does not do

- **No MCP `schedule_message`.** [`control-plane.md`](control-plane.md) sequences queue/steer/wait
  as slice three; the store is shaped so an adapter drops in later.
- **No mirroring to iOS or the browser.** The outbox itself does not cross
  `RemoteConversationSnapshotDTO` today, so scheduled rows staying on the Mac keeps one rule rather
  than two. Noted as a *not yet*: `ConversationOutbox`'s own header states that a queue has to
  cross RemoteKit.
- **No recurrence.** "Every weekday at 9" is a different feature with different failure modes.
- **No shell drawers or standalone project terminals as targets.** They are `TerminalID`
  destinations with no turn model to deliver against.
- **No scheduled side chats.** `ScheduledSessionPlan` cannot express "side chat of X".

## A bug this found on the way in

`SessionMessageDelivery` took the chat branch on a conversation that *existed* without asking
whether it was *running*. `TerminalContainerViewController` deliberately keeps a
`ConversationViewController` after its agent exits, so `AgentRuntime.conversation(for:)` goes on
answering for a session with no process: `submit` fell through its `stream.canSend` guard into
`enqueue`, which accepted the text and answered true, and `hasTurnInFlight` is false for a dead
session — so `deliver` reported `.sentNow` for a message no transport had, which then died with
the in-memory outbox on the next resume. **`send_to_session` had been losing cross-session messages
that way**, and a scheduled send would have deleted its own durable record on the strength of that
answer. Both `deliver` and `surface` now ask `isRunning`, symmetrically, and
`SessionMessageDeliveryTests` holds it.
