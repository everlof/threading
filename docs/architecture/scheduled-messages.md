# Scheduled Messages

Writing something now and sending it later — at a chosen time or when another agent finishes its
current turn — as a reply to a session that exists, or the brief that starts one that does not.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

## One record, two payloads, two triggers

`ScheduledMessage` carries both targets and both triggers, because they share a store, a strip and
every delivery rule. Splitting them would be two of everything below.

- **`.session(SessionID)`** — a reply, scheduled from the conversation's own composer.
- **`.newSession(ScheduledSessionPlan)`** — a session start, scheduled from the draft view. The
  plan is a **frozen copy** of every decision beside the brief: agent, login, model, effort,
  speed, branch, surface, permission mode. Not a reference to the composer — the chips will have
  moved on by Monday morning, and a plan that read them then would start whatever happened to be
  selected. Speed keeps the same three-state meaning as the composer: nil follows General when
  the session eventually starts, while Standard and Fast remain explicit conversation overrides.
  `AccountHandle` is deliberately not `Codable`, so the handle rides as `persistedSessionName` and
  is rebuilt with `init(storedName:)`, which is the spelling every other persisted copy uses.
  New records also carry a `reservedSessionID`: scheduling immediately creates the ordinary,
  unlaunched `AgentSession` that will eventually run. The optional encoding preserves records
  written before reservation existed; those legacy records still create their session at fire
  time.

- **`.time(TimeTrigger)`** — the original clock trigger: an absolute instant plus the wall-clock
  intent needed to survive a time-zone change.
- **`.sessionFinished(SessionID)`** — the end of the conversation's **current turn**, not the end
  of its process and not a guess made from a quiet terminal. It is offered only while that turn is
  in flight and only when the runtime reports its own turn boundaries. Agent-reported background
  work remains `.working`, so the condition is not satisfied while a subagent or other reported
  work is still outstanding.

**Images ride along as copies.** They were refused outright at first, and the reason was sound as
far as it went: a pasted screenshot is a file in a temporary directory, and a path written down
now can name nothing by Monday — the reason [`persistence.md`](persistence.md) already refuses to
*draft* them. But that is an argument against keeping *the path*, not against keeping the
picture. `ScheduledAttachmentStore` takes a copy at the moment of scheduling, so the record stops
depending on anything outside it surviving the wait. See [Custody](#custody) below.

**A time trigger keeps the instant and the words.** `dueAt` is an absolute `Date`;
`intendedTimeZone` and `intendedWallClock` are what the user actually chose. They disagree the
moment a machine changes zone — "tomorrow at 09:00" set in Stockholm and opened in New York fires
at 03:00 while every label relabels itself to 03:00, which would make the sheet's named time zone
a promise the record could not keep. `NSSystemTimeZoneDidChange` re-derives `dueAt` from the components. A
reset-anchored send is left alone: a window's boundary is an instant, not a time of day.

The trigger is encoded as part of the durable record. The decoder also accepts the original
top-level `dueAt` / time-zone / wall-clock shape and turns it into `.time`, so installing this
version does not strand existing scheduled drafts.

## The store is a file, and it is written on the mutation

`ScheduledMessageStore` is a `RecoverableFileStore` at `scheduled-messages.json`, criticality
`.userAuthored`, beside the drafts it is a longer-dated cousin of.

**A file rather than a row in `threading.db`.** Columns exist to be ordered by, filtered on or
joined, and nothing here is: it is a handful of records read whole at launch. What it does need is
the contract `DraftStore` and `SessionContinuityStore` already have — synchronous user-authored
writes, quarantine rather than deletion — because once the composer is cleared this is the only
copy of something somebody wrote. A scheduled message is a draft with a durable release
condition.

**Refuses rather than evicting.** Per-target and global ceilings, both stated as values
(`ScheduledMessageStore.Refusal`) so the strip and any later adapter word them their own way. A
queue that quietly forgets what somebody wrote is worse than one that says it is full.

**Disk commits before memory.** Every add, replacement, state transition and removal is built as
a candidate array, synchronously written and read-back verified by `RecoverableFileStore`, and
only then installed in memory and announced. A failed add returns `.writesBlocked`; other failed
mutations leave the last durable state current. Because an unattended delivery must subsequently
record either waiting, failure or completion, the store also stops returning due work and refuses
new claims once persistence disables writes. Continuing to send after that point could duplicate
a message on the next launch or delete its only copy in memory while the disk still calls it due.

**Pruned inside `ProjectStore` itself**, beside `ConversationHandoffStore.remove` and
`ExecutionAuditStore.remove`. Not from the sidebar's delete gesture, which is where
`SubagentStateStore`'s sweep lives: Settings ▸ Archived deletes sessions straight through
`removeSession` without going near the sidebar, and a send left behind would keep naming a session
that is gone.

**`init(directory:)` exists for the tests**, for `DraftStore`'s reason: the bundle is hosted in the
app, so a store that always resolved Application Support would have every run editing the
developer's own scheduled sends.

## Custody

`ScheduledAttachmentStore` owns the bytes behind `ScheduledMessage.attachments`, in
`scheduled-attachments/<message id>/<slot>/<name>` beside `scheduled-messages.json`.

**Beside the record, not inside it.** The record's whole contract is a synchronous verified write
on every mutation; inlining megabytes of PNG would make each of those writes proportional to the
pictures rather than to the words. So the JSON keeps the names and this keeps the bytes.

**A slot per image, so nothing is renamed.** Two screenshots can both be `Screenshot.png`, and
renaming one breaks the two things downstream that read the name: a pasted image is recognised by
its `threading-attachment-` prefix, and the attachments pane shows a dropped file under the name
it already had. `slot` and `name` are stored apart rather than as one relative path, because a
single string decoded off disk is one `../` away from naming somewhere else — the name is
re-sanitized on the way out as well as on the way in.

**Refuses rather than taking a short set.** A send that quietly lost one of three pictures is
worse than one that was refused: the composer still holds all three when custody is asked for, so
a stated refusal is the only outcome that leaves the user able to act. Anything already copied is
removed on the way out. Bounded by `ScheduledAttachmentDefaults` — a count *and* an aggregate byte
ceiling, because a per-image cap is not an aggregate cap.

**Released by `ScheduledMessageStore`'s own mutations**, never by the surfaces that ask for them:
`remove`, `forget(sessionID:)`, `forget(projectID:)` and `retainOnly` each drop what leaves, and
`load` sweeps directories no record names — the record and its pictures are two writes, and a
quit between them strands one. The release happens *after* the commit: a failed write leaves the
record current, and a record whose pictures had already gone is a send that can no longer be sent.

**The sweep spares what this run is still in the middle of.** Those same two writes leave a
window where the bytes exist and nothing names them, which is indistinguishable from an orphan —
and `ScheduledMessageStore.shared` is constructed lazily, so the *first* schedule of a run can be
what triggers `load`, whose sweep then lands inside that window. The record went to disk naming
two files deleted a microsecond earlier. `ScheduledAttachmentStore` therefore keeps an in-memory
`inFlight` set — ids it has taken custody for and not yet released — and `retainOnly` keeps the
union. It is memory-only for `claimed`'s reason: it describes what this process is in the middle
of, not what is durable, so a later launch correctly sees a genuinely stranded directory as
stranded. Caught end-to-end from the composer, not by a unit test: the two stores only meet in the
app.

**Custody moves before the words do.** At fire time the pictures are recorded against the
receiving session through `PromptAttachment.handOver` — the same door the composer's own images
use, which is what puts them in the attachments pane — and it is the *session's* copies whose
paths go into the prompt. Naming our own would hand the agent a path that stops existing the
moment `complete` deletes the record. Repeatable on purpose, since a delivery that finds its
target busy is retried and `SessionAttachmentStore` matches a second mention by source path.

**Editing — and Send now for a scheduled reply — detaches rather than borrows.** `detach` *moves*
the files to the temporary directory and hands those paths to the composer, because what comes
back has to be exactly what a freshly pasted image is: the composer will hold the path, send it,
and take custody again if the message is scheduled a second time. Lending our own file would leave
the composer pointing into a directory the very next `remove` deletes. Start now for a scheduled
session is different: it runs the same reserved conversation, so its normal fire-time handover
keeps custody intact.

**The conversation surface was losing them silently.** Only the draft view ever refused an
attached image; chat read the text and the context, left the pictures in the box, and then cleared
it — so a reply scheduled with a screenshot attached arrived without one and nothing said so.

## The scheduler announces; the coordinator performs

`ScheduledMessageScheduler` is `SessionArchiveScheduler`'s shape one feature along: it announces
(`ScheduledMessageDidBecomeDue`) and `SessionCoordinator` performs. Nothing in Core knows about
sidebars, surfaces or launching, which is what keeps `check_architecture_boundaries.sh` satisfied
and what makes the rules testable with no live agent.

**`Date()` is the only authority.** Nothing counts elapsed intervals: a timer does not fire while
the machine sleeps, and one armed against uptime is wrong after an NTP step. The triggers exist to
make the comparison happen often enough, not to measure anything — a wake, an activation, a clock
step, a zone change, a store mutation, and one five-minute heartbeat while clock work or a
blocked delivery is pending. An armed finish trigger does not run a timer; its activity edge is
the authority and polling would add no information.

**A finish trigger has a different authority: the runtime's turn edge.**
`SessionActivityDidChange` is examined only for a watched session that reports its own turns. The
scheduler first remembers that this run of Threading observed `hasTurnInFlight`, then satisfies
the condition on the later false side. The receipt matters because `SessionStart` deliberately
posts the same notification even when an idle state did not move; after relaunch that is a
snapshot, not the missing finish edge. `hasTurnInFlight` includes agent-reported background work,
per [`session-activity.md`](session-activity.md), and it does not read `.awaitingUser` as
completion. Inferred terminal quietness is never enough for an unattended send.

The picker and the activity edge race in one narrow place: a chosen turn can end after the sheet
was populated but before the durable record is added. The scheduling surface therefore performs
one explicit settled-snapshot check immediately after the write. Normal startup does **not** do
that check; a conversation merely looking idle after Threading relaunches is not evidence that it
finished while Threading was away. The record waits for a later observed authoritative turn end.

**Two notification centres, and the second is not optional.**
`NSWorkspace.didWakeNotification` is posted on `NSWorkspace.shared.notificationCenter`, never on
`.default`. A scheduler observing only the default centre compiles, runs, and silently never
re-evaluates after sleep — which is the single case the class exists for.
`ScheduledMessageSchedulerTests` posts the wake on the workspace centre precisely so that mistake
fails a test rather than a user's morning.

**Started behind the relaunch's two gates**, from `restoreSelectedSessionIfReady` rather than
`applicationDidFinishLaunching`: a scheduled start reads the MCP port for `--mcp-config`, and one
firing into the window onboarding is still deferring gets a PTY in a pane nobody will see.

## Nothing is sent for a time the app missed while it was closed

There is **no grace window and no automatic late delivery**. Threading is not a server. Anything
whose moment passed while it was not running becomes `.missed`, is reported once
(`ScheduledMessagesWereMissed`), and waits for the user — the strip shows it with **Send now**
beside it. The rule is one sentence: *the app does not send what the clock passed while it was not
watching.*

A separate `.waiting(reason)` covers the other half — due *while* the app is running but not yet
deliverable. Those keep trying for as long as the app runs and stay visible while they do;
undelivered at quit, they join the next launch's missed set.

Finish-triggered messages have no clock moment to mark missed. They survive relaunch without
being released by a dormant snapshot, and remain armed until Threading observes a later matching
turn end. If the watched conversation is deleted first, the words are preserved and the row
becomes `.failed` with that reason; deleting the destination still removes messages addressed to
it, as before.

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
| `.newSession` | plan re-validated, reserved session launched in the background; legacy records create one first |

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

## A scheduled start is a real waiting conversation

Scheduling from the draft surface immediately reserves an ordinary `AgentSession` with the
plan's stable id and frozen launch configuration. That gives the intent a durable place in the
sidebar before any process exists. Selecting its row does not launch it: the conversation pane
shows a bounded scheduled-state surface with the brief, configuration, and the exact automatic
cause — a wall-clock time, the named usage reset and its expected time, or the named conversation
whose current turn must finish. It also offers **Start now** and **Cancel schedule**. The sidebar
row says **Scheduled**, suppresses archive, and exposes those same two lifecycle actions.

The schedule remains the authority. Removing it also removes the empty reservation; starting it
claims the schedule and launches that same session id, so the row does not disappear and return as
a different conversation. A managed workspace is still provisioned at launch rather than at
reservation: waiting should not consume a worktree, and launch-time validation is what prevents a
deleted branch or folder from silently changing the target.

## Presets, including the one Slack would never have

`ScheduledTimePresets` is pure — a function of `(now, calendar, locale)` and a usage reading — so
every rule is a test and none of it lives in a view.

**A wall-clock offer states its time beside the title, not under it.**
`ThemedMenuMetrics.heights` gives every row in a run the height of the tallest kind in it, which
is right for a group of logins where some carry a scoped window and reads as a defect here: "In an
hour" is the only wall-clock offer whose title does not already say the time, so its one subtitle
stretched "Tomorrow at 09:00" and "Monday at 09:00" into 46pt rows holding a single line each.
`ThemedMenuItem.titleDetail` exists for exactly this and says so in its own comment. A reset offer
keeps its subtitle — "14:30 · resets in 4h 37m" is two facts rather than a qualifier, and it sits
in its own run behind a separator, which is what makes the change of height legible.

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

**It is pressable even when it cannot be used**, because the refusal *is* the answer. There are
four reasons a start cannot be scheduled — no project, nothing written, more pictures than
custody accepts, and a store that refuses the record — and `scheduleEntries` states the first
three as a single disabled menu row, in the words the user should read, on the grounds that
"nothing happened when I clicked it" is the worst of them. Disabling the button defeated exactly
that: the press never arrived, so the sentence survived only on a tooltip, and what reached the
user was a dim glyph and a question ("why is this disabled for me?"). The tooltip still carries
the reason for a pointer that pauses; the press now carries it for everyone else. The
missing-project case is one of the three rather than an empty menu, and it borrows the composer's
own `chooseProjectFirstReason` so the screen states one blocker once. An attached image used to be
one of these refusals outright; see [Custody](#custody).

**“When a conversation finishes…” in both schedule menus.** The row is enabled only when at
least one live conversation has a current turn with an authoritative finish signal. It opens a
searchable sheet naming the conversation, project and agent. Candidate discovery value-scans the
stored projects once; expected scale is 2–12 live turns against the sidebar's 5,000 stored-session
stress case. The table creates only viewport rows, and filtering a large live set runs away from
the main actor before the value model is replaced.

**“Custom time…” is a sheet with two lists, and used to be an alert with two pop-ups.**
`ScheduleMomentPickerViewController` replaced `ScheduleMessageAlert` because the dropdown could
not work where that alert put it: `ThemedMenuPresenter` draws its panel *inside the window it was
opened from*, and a `ThemedAlert` is a borderless panel sized to its own two lines of text — so a
day's ninety-six quarter hours opened with room for **one and a half rows**, and the sheet under
them was barely wider than the two buttons. Growing the alert does not fix it; no dialog a
dropdown opens inside is tall enough for that list. Lists that *are* the sheet scroll rather than
open, keep type-to-select (`typeSelectStringFor`), and show fifteen answers at once.

Two rules live in `ScheduleMomentOptions`, which is pure so both are arithmetic rather than
something only a screenshot disproves. **A moment already gone is not offered** — the store
refuses `dueAt <= now` with `.inThePast`, so today's spent quarter hours are dropped and a today
with none left leaves the day list rather than sitting there selected beside an empty column.
**`Calendar` places the wall-clock hour**, via `date(bySettingHour:minute:second:of:)`: minutes
added to midnight put nine o'clock at ten on the Sunday the clocks move forward, which is the
same trap the presets document one section up. The sheet opens on nine o'clock where the nearest
day still has it and on that day's next quarter hour otherwise; the list's highlighted row is
that moment, which is why the lists do *not* set `allowsEmptySelection = false` — a list that
refuses an empty selection re-picks its first row after a reload and posts it late enough to
overwrite the sheet's own choice.

**A day row centres its pair by constraint, not by the stack.** A vertical `NSStackView` built
from `init(views:)` puts everything in its leading gravity area, which for a vertical stack is the
top — so the name and its date sat against the row's top edge with all of `dayRowHeight`'s spare
height under them. Every assertion passed; what it looked like was a selection plate with its text
shoved into the corner, and a first row whose name touched the panel's own border. `dayRowHeight`
states a floor as well as a computed height, so the spare space is real and has to be spent
deliberately rather than all at one end.

**`ScheduledMessageStripView`, above the composer** — and deliberately *not* rows in
`ConversationOutboxRailView`. That rail computes a drag's index across every pending row and hands
it to `ConversationOutbox.movePending`, which counts in outbox terms, so scheduled rows mixed in
would shift every drag by however many sat above — silently, because `movePending` clamps rather
than refuses. Its `Row.id` is a `ConversationMessageID`, and one flag gates draggability, removal
*and* editing together, so "store-ordered, still removable" is not a state it can express.

**An empty strip leaves the column rather than hiding in it.** A hidden arranged view is detached
from a stack's layout but is still a subview with constraints of its own, and that was enough to
pull the draft view's column off the pane's width — which
`ComposerWindowFitTests.testTheColumnFillsThePaneUpToItsCap` caught. A view with nothing to say
leaves the room.

**A scheduled start says that it starts automatically.** The generic timing sentence is enough
above a conversation composer, where the destination already exists and the verb is “send.” On
the draft surface the still-visible primary action says “Start session,” so a receipt that only
said “When … finishes” looked like a condition waiting for that button. Draft rows use
`ScheduledTiming.automaticStartSentence`; once scheduling clears the brief, the outside Start
button follows `PromptView.isSubmissionAvailable` and becomes disabled. The receipt and the
action therefore agree: Threading will start the reserved conversation automatically, while Start
is only for a new brief typed into the now-empty box. The reserved sidebar conversation makes the
same promise more concrete: opening it shows the trigger and Start now, never an empty chat that
might or might not require the draft surface's button.

**A row states its height; a floor alone is not a height.** The row stated only `height ≥ 26`,
and the draft view's column has a second free height above it — the hero region soaks up
whatever the pane does not need. Two free heights is an ambiguous layout, and the engine parked
the pane's slack in whichever it liked: scheduling a start on the next 5-hour reset drew the
row's labels over the chip row while its remove button floated forty points below them. The row
now prefers exactly `rowHeight` at `.defaultHigh` over the required floor, with required `≥` top
pins on its members so genuinely taller content still grows it honestly — stretching the row
costs something, growing the hero costs nothing, and the slack has one home.
The remove button is aligned to the summary label's ink, not to the abstract row bounds: the
xmark's square image is geometrically centred inside its target, while the type's visible weight
sits above its frame centre, and equal frame centres left the x visibly below the item it removes.
`ComposerWindowFitTests.testAScheduledRowStaysOneLineRatherThanAbsorbingThePanesSlack` holds it.

## What this deliberately does not do

- **No MCP `schedule_message`.** [`control-plane.md`](control-plane.md) sequences queue/steer/wait
  as slice three; the store is shaped so an adapter drops in later.
- **No mirroring to iOS or the browser.** The outbox itself does not cross
  `RemoteConversationSnapshotDTO` today, and the remote protocol has neither a scheduled-state
  projection nor its lifecycle actions. `RemoteSessionAccess` therefore withholds reserved
  sessions until they start, keeping list, resume and WebSocket attach under the same rule. Noted
  as a *not yet*: `ConversationOutbox`'s own header states that a queue has to cross RemoteKit.
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
