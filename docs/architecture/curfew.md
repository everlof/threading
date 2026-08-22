# Curfew

A scheduled *end* for a session: the moment Threading stops spending it on its own, the wind-down
that precedes it, and the bounded interrupts that enforce it against a loop.

Part of the [CLAUDE.md](../../CLAUDE.md) index. Shipped August 2026 from
[`feature-drafts/curfew.md`](../feature-drafts/curfew.md).

## The case, and the split

The 5-hour window resets at 04:00 while the user sleeps. They want a session to spend what is
left of *this* window overnight — driving it with the provider's own `/loop` or `/goal` — and not
eat into the fresh one. Threading could already schedule a start ([`scheduled-messages.md`](scheduled-messages.md))
and hold an account at a line of the user's own ([`accounts.md`](accounts.md)); it had no way to
schedule an end.

**"Keep working" stays with the providers; Threading owns "until".** Neither `/loop` nor `/goal`
has a wall-clock bound, and Threading must not supply one in-band: its lifecycle hooks stay silent
by design ([`session-activity.md`](session-activity.md)) — Claude reads a failing `Stop` hook as a
reason to keep going — and it never types into a terminal unattended except between turns. So the
pairing is the feature: the user runs the loop, Threading runs the clock and the fence.

## One deadline, three moments

A curfew is one deadline **T** with three consequences, each with a margin the user sets once in
Settings (margins are app-wide on purpose — per-session margins would be four popups on every
menu for a number almost nobody moves):

| Moment | What happens | Owner |
|---|---|---|
| **T − wind-down** (10 min) | A wrap-up message goes to the session — only if it has a turn in flight. An idle session has nothing to wrap up, and typing into it would *wake* it and spend usage. | `ScheduledMessage` with `Purpose.curfewWindDown` |
| **T** | **Hold.** Threading stops spending the session: the native outbox stops draining at the turn boundary, scheduled sends stand aside, `send_to_session`/resume/spawn are refused, the usage-window poke stands down. The keyboard still works — the tier-4 park's rule, and the strip says so. | `CurfewHoldPolicy` |
| **T + grace** (5 min) | **Interrupt** a turn still in flight: `ConversationTurnControl.interrupt` for a native chat, one Escape for a terminal. | `SessionCurfewCenter` |

**The deadline is the instance's identity.** `SessionCurfewState.deadline` is a `let`; a new
deadline is a new curfew that owes its wind-down again, announces its hold again and starts its
interrupt budget at zero. `ProjectStore.setCurfewRule(_:forSessionID:)` clears the state in the
same write as a changed deadline so SQLite never holds a deadline over somebody else's receipts.

The ladder is **conduct, not weather**: a held row wears the `RowConductSummary` mark rather than
the provider triangle, the strip is `LimitEscapeStripView` with `Offer.Source.curfew`, there is no
new `SessionActivity` case (the process really is idle), and **Lift Curfew** is always offered
because the rule is the user's own.

## The ladder is enforcement, and it is reason-neutral

Every hold Threading had before this stopped *Threading-initiated* sends. A loop re-submits from
inside the CLI, so a held session sails past any line until the provider refuses. The interrupt
ladder is what reaches into the process, and it was written with its trigger carried as a
*reason* rather than the word "curfew", so a custom-limit `enforce` tier can reuse it later
without retrofitting (see Follow-ups).

- **The first interrupt after T + grace fires regardless of who is watching.** That is the
  promise the user made to themselves.
- **Every later one fires only for a turn that started unwatched.** On each `SessionActivityDidChange`
  that raises `hasTurnInFlight`, the engine remembers `isWatched(id)` — `NSApp.isActive` and the
  session's surface visible — at that instant, and a turn recorded as watched is never
  re-interrupted. *A turn started in front of the user is theirs.* Without this a person typing a
  question at 07:00 would have Escape pressed on them.
- **Bounded**: at most `CurfewDefaults.maximumInterrupts` (3), never two inside
  `reinterruptSpacing` (30 s). A provider loop that survives three is a fact to tell the user,
  not a thing to fight forever: the curfew **gives up**, records it, and posts the one actionable
  `AttentionAlert` this feature has ("Kept working after 3 interrupts"). Every other state is
  silent — the strip names it and there is nothing to act on.
- **Stopping the agent is an opt-in escalation, off by default.** `CurfewPreferences.stopsAgentOnGiveUp`
  replaces the give-up alert with `AgentRuntime.terminate(sessionID:)`, which deliberately keeps
  the terminal so its final output stays visible; never `discard`, which tears the view down. The
  row stays, the pane keeps the conversation, and **Resume Session** — the dormant pane's existing
  affordance — brings it back. The default stays interrupt-only because the user wants to come
  back and read what happened.
- **Escape is capability-gated.** `AgentCapabilities.escapeInterruptsTerminalTurn` (Claude,
  Codex — read through `kind.supports`, never a new `supportsX` property) plus
  `AgentRuntime.reportsOwnTurns` plus a tracker reporting a turn in flight are all required before
  `TerminalDefaults.interruptSequence` is typed — so Escape never lands on a restore or question
  chooser, and never twice at an idle prompt (where Claude Code opens its rewind chooser). A
  runtime without the flag gets the hold only, and the strip says *"Threading cannot tell whether
  this session is working, so it only stops delivering messages."* **The keystroke's effect on the
  installed CLIs is recorded as owed, not measured** — see Measured and owed.

### Hold: one decision, the same seams

`CurfewHoldPolicy.hold(sessionID:in:at:)` is the single predicate, in `CustomLimitParkPolicy`'s
shape, asked beside the custom-limit hold at every seam the tier-3/4 rules already use:

| Seam | Rule |
|---|---|
| Outbox drain (`flushOutboxIfReady`) | refuses to hand over while held — except an item whose `origin == .curfewWindDown` |
| Scheduled send (`standAsideForCurfew`) | `CurfewStandAside.decide`: a quiet-hours hold re-arms a clock-triggered send to the window's end without counting a rearm; a session curfew leaves it `.waiting` with the hold's sentence, re-offered on `CurfewDidChange`; a finish-triggered send waits rather than being pinned to an edge that may never recur; the wind-down passes |
| Control plane (`heldByCurfew`) | `ControlRefusal.targetHeldByCurfew(reason:)` at `send`, `admitResume`, and the *manager's* own curfew at `admitSpawn` — checked after `heldByOwnLimit` and after the scope checks, so a caller learns nothing about a session out of scope |
| Usage-window poke | `UsageWindowHold.quietHours(until:)`, last in the guard table |

Both holds are consulted independently, so "stop at 70 % of the weekly, or at 04:00, whichever
first" needs no option: set the account rule and the curfew. When both stand, the strip shows the
louder fact — provider refusal, then the user's limit, then the curfew.

## The wind-down is a scheduled message

Filed by the engine as an ordinary `ScheduledMessage` — custody, delivery, the strip row, the
failure sentence are all the ones every other send has. Three things are its own:

- **Two exemptions and no more.** It passes the curfew's hold (the hold exists to stop the session
  spending itself; this one turn is what buys back the commit and the handoff an interrupt is
  about to cut off) and it is **not** exempt from the user's custom limit, which is a budget
  rather than a bedtime. Never deduplicated against a user-authored record.
- **Deliverable until T + grace + wind-down**, because on a terminal the wrap-up only becomes
  typeable once the interrupt has produced the activity edge — after the deadline by construction.
  Past that it fails with *"Its curfew passed before the session was free."* rather than arriving
  in the morning to ask an idle agent to stop.
- **It rides the outbox with `ConversationOutbox.Item.origin = .curfewWindDown`**, threaded from
  `deliverScheduled` through `SessionMessageDelivery` with defaulted parameters so no other caller
  changed. Steering was considered and rejected: the text is a countermand ("end the loop"), and
  steered text arrives beside tool results where models read override-shaped instructions as
  injection. Queued behind the turn it is a turn of its own.
- The record is filed one second ahead of `now` (`CurfewCenterDefaults.windDownLead`):
  `ScheduledMessageStore.add` refuses `dueAt <= now`, and a record for *this* instant is exactly
  that. The default text names the loop on purpose — *"End any loop or goal you are running,
  commit what is safe, write what is left to a handoff note, then stop"* — and is deliberately
  not localized: it is a message to a coding agent, editable in Settings.

## Resolution: three scopes, and the standing window

`CurfewResolution` follows `LimitRecoveryResolution` — narrowest first, **absent means inherit,
not none**, the chain pure and the store passed as a parameter:

- **Session**: `.exempt`, or `.until(Date)` — an instant, not a time of day, because the whole
  feature exists for the hours the user sleeps across; never re-anchored on a zone change.
- **Project**: `.exempt` only. `setCurfewRule(_:forProjectID:)` refuses `.until` — a moment on a
  checkout would keep ending chats created weeks later at a time nobody chose. A stored one
  decodes and falls through.
- **Settings**: `QuietHours` — two minutes-of-day, `end <= start` crossing midnight (the ordinary
  case), all arithmetic through `Calendar.nextDate(after:matching:)` so the two nights a year that
  are 23 or 25 hours long keep their wall-clock ends and a 02:30 start that does not exist opens at
  03:00. The resolved curfew is the window containing `now`, else the next one — a window that has
  not opened is still the deadline the session is running towards.

Writers store **nil where the answer matches what would have been inherited** (`chooseLimitRecovery`'s
rule), so a chat keeps following its checkout and Settings. Quiet hours produce a new instance
every night, keyed by its start; **lifting** one writes `liftedAt` on the state rather than
`.exempt` on the record, so "not tonight" cannot become "never", and the lifted instance still
arms the timer for its window's end.

## The engine

`SessionCurfewCenter` is `SessionSnoozeCenter` one feature along: **one process timer, the
persisted state is the truth, the injected clock is the only authority.** The timer re-arms at the
nearest pending moment across sessions and only makes the comparison happen; nothing counts
elapsed time. It observes clock and zone changes, app activation, `NSWorkspace.didWakeNotification`
**on the workspace centre** (the `ScheduledMessageScheduler` lesson), `SessionActivityDidChange`
for the per-session O(1) edge, and the settings and store change events.

- **Core announces, the coordinator performs.** A native interrupt is `CurfewInterruptRequested`,
  performed by `SessionCoordinator` through `stopCurrentTurn(completion:)` and reported back via
  `noteInterruptOutcome` — a `.failed` receipt still counts, because the *attempt* is what is
  bounded. The terminal Escape and the stop-agent escalation go through `AgentRuntime`'s existing
  seams, so no Core file names a controller.
- **At launch nothing is typed.** Every session is dormant, so `hasTurnInFlight` is false; a hold
  that began while the app was shut materializes dated at the deadline, a wind-down whose window
  passed fails with *"Threading was not running."*, and `.ended` is written on the outgoing
  quiet-hours instance before the new one takes over (a closed half-open window never resolves, so
  the receipt had nowhere else to live).
- **Refuses to start under a hosted test bundle** with default dependencies, for the reason
  `UsageWindowPoker` and `LimitRecoveryCoordinator` do: it types into terminals. `CurfewSettings`
  is `PreferenceStore`-backed for the same reason — a test that switched quiet hours on would arm a
  nightly Escape on the developer's own copy.

## Receipts, and the morning read

A curfew acts while nobody is watching, so what it did is the product, not diagnostics.
`SessionCurfewState.receipts` keeps the last `maximumReceipts` (8) events — wind-down
sent/skipped/failed, held, interrupted ×n, gave up, stopped, lifted, ended — on the session's own
JSON payload (no SQLite migration: [`persistence.md`](persistence.md)). Decoding is lenient twice
over: an unknown rule kind reads as "never chose" through `CurfewRule.Stored`, and an unknown
receipt event drops that one receipt rather than the log, because losing a line is a smaller loss
than losing the fence. Every receipt also goes to `EventLog(.curfew)`.

The same ledger is read in three places: the strip (*"Curfew since 04:00 · wrap-up sent 03:50 ·
interrupted 04:05 ×2"*, plus the cannot-tell clause and the give-up), the row's conduct line
(held leads everything — a held row looks idle and is not — then park, then recovery, then
mute, then an armed or exempt curfew, and an exemption speaks only where a standing window would
otherwise have held it), and the session popover.

## Where it appears

- **Draft view**: a moon beside the clock ("End this session at a time") opens `CurfewMenu`;
  the choice becomes a footer chip ("Until 04:00", tooltip = the whole ladder) present only when
  chosen, frozen into `ScheduledSessionPlan.curfew` as a *plan* (`.at(Date)` or
  `.atQuietHours`, resolved at fire time — a plan that wrote down Tuesday's 04:00 and fired on
  Thursday would name a deadline before its own session started). **Armed when the session
  actually starts, never while the row waits**; a moment already passed is journalled and skipped.
  The waiting placeholder's configuration line carries "Until 04:00".
- **Existing sessions**: the sidebar's Session Options fold gains **Curfew** (same shape as
  *When the Limit Is Reached*, checkmark on the *resolved* answer), the project row offers
  Follow/Exempt only when quiet hours are configured, and the native chat shows the same chip
  while a curfew resolves.
- **Presets** mirror the start ones — "In an hour", "In 3 hours", "Tonight at 23:00", "At quiet
  hours (04:00)", "Custom time…" — and **"Until the 5h window resets" lands on `resetsAt`
  exactly**: the start presets' one-minute padding exists so a *send* lands after the provider
  rolls its counter; on an end it points the wrong way.
- **Settings ▸ Usage Windows ▸ Quiet Hours & Curfews**: the explanation, the two margins, the
  wrap-up template, the give-up choice, the quiet-hours toggle with From/To, and a live *Tonight*
  sentence built by a pure helper so the ladder the popups produce is readable before anything
  runs.

## Persistence and compatibility

- A `Purpose.curfewWindDown` in `scheduled-messages.json` is a **downgrade cost**: an older build
  decoding an unknown raw purpose throws `dataCorrupted` and, because the file is decoded whole,
  quarantines every scheduled send. Measured, not assumed; the old-file → new-build direction is
  covered by the `?? .userAuthored` fallback.
- `CurfewPreferences.stopsAgentOnGiveUp` decodes with a default so stored preferences predating it
  read as Notify; the other fields decode exactly as synthesized.
- `ScheduledSessionPlan.curfew` is optional so older plans decode as endless sessions.

## Measured and owed

- DST: both Stockholm transition nights are tests for the quiet-hours window, the deadline
  presets and the engine's re-resolution on a zone change.
- **Owed before this is relied on overnight:** the Escape keystroke against the currently
  installed Claude Code and Codex — one Escape ends a running turn and returns to the prompt
  (`[Request interrupted by user]` / `turn_aborted` settle the tracker), and a second never reaches
  an idle prompt. The capability row cites the existing transcript evidence and says so.

## Out of scope and follow-ups

- iPhone: no scheduled-message or curfew projection exists on the wire; a held session shows as
  idle there. `RemoteSessionSummaryDTO.curfew` + a `curfew` route follow the `limit-recovery`
  handler's shape.
- Project-specific quiet windows; per-session wrap-up text.
- **`CustomLimitTier.enforce`** — run this same ladder while one of the user's own account rules
  holds ("stop at 70 % even if looping"), through the engine's reason seam.
- A **`UserPromptSubmit` enforcement hook** that blocks a loop's re-submission in-band at zero
  spend — Claude-first, measured, and only once a blocked prompt is shown not to strand the
  activity tracker.
- Per-session ceilings stay with [`feature-drafts/usage-aware-accounts.md`](../feature-drafts/usage-aware-accounts.md) § C.
