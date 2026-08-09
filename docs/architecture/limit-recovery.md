# Limit Recovery

What happens when the provider refuses a turn over a rate limit: detecting it, answering the
CLI's own chooser, and continuing by policy instead of stranding the session.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

## The moment, measured

Everything here was designed against a real specimen rather than the CLI's documentation, which
does not describe this state at all: session `a926e034` on CLI 2.1.223 hit its limit mid-plan on
2026-08-06, and its transcript records the whole shape.

```
20:12:11  assistant  (last real turn text)
20:12:11  system stop_hook_summary + turn_duration     ← ended normally
20:24:44  queue-operation ×2 → user                    ← queued wake submitted
20:24:46  assistant  error:"rate_limit" apiErrorStatus:429 model:"<synthetic>"
          text: "You've hit your session limit · resets 1:50am (Europe/Rome)"
20:24:46  system turn_duration                          ← file ends
```

Four facts fall out of it, and each is load-bearing:

- **The limit hit is a durable, structured record.** A synthetic assistant message with
  `isApiErrorMessage: true`, `error: "rate_limit"` and `apiErrorStatus: 429` is appended to the
  session's transcript. Detection is therefore a transcript read, never screen scraping: the TUI
  chooser drawn over it ("Stop and wait for limit to reset / Upgrade your plan") is interactive
  dressing over a state the file already states exactly.
- **The turn is over when the chooser appears** (`turn_duration` is written). So a recovery that
  stops the process — the account-routing policies below — never needs to answer the chooser at
  all.
- **`Stop` does not fire on the refused turn.** The 20:12 turn carries `stop_hook_summary`; the
  429 turn does not. The activity tracker therefore never hears a boundary, which is why a
  limited session strands showing `working` — the stuck spinner this subsystem also fixes.
  The same is true of *every other* failed request, and only the `429` half belongs here: an
  expired login or a dropped connection writes the same record shape with a different `error`,
  has no reset to wait for and no chooser to answer, and is ended by `ClaudeTranscriptTurnRefusal`
  instead — see [`session-activity.md`](session-activity.md). The two readers partition one
  record shape on `ClaudeTranscriptAPIError.isRateLimit`; detection here must stay narrow, because
  a login failure recovered as if the account were spent schedules a continuation against a
  window that was never the problem.
- **The rendered text is the one source never parsed.** "resets 1:50am (Europe/Rome)" is
  locale-shaped prose; the authoritative reset instant is `resetsAt` from the usage sources
  [`accounts.md`](accounts.md) already ranks. The transcript proves *that* the limit hit;
  the usage reading says *when* it lifts. (The specimen also shows why: the message blamed the
  session window while the toolbar pill was blaming the weekly Fable window — readings drift,
  the record does not.)

## Two layers, deliberately split

Detection and recovery are separate subsystems with separate owners, built concurrently and
meeting at one seam:

- **Detection** is `ObservedUsageLimit` → `ClaudeTranscriptUsageLimit` → `UsageLimitStop`: the
  capability-gated seam (`AgentCapabilities.transcriptUsageLimitRecord`, the
  `ObservedPermissionMode` shape), the `TranscriptFactReader`-backed reader, and the fact type.
  The newest *message* record decides — a refusal stands until the conversation says anything
  in either direction, which is also what clears it, so nothing has to remember when the
  refusal was. Sidechain refusals are excluded: a subagent running out of limit is a failed
  task to its parent, not the session stopping.
- **Recovery** is `LimitRecoveryCoordinator` + `LimitRecoveryPolicy` + `LimitChooserReading`:
  a poll at `UsageLimitDefaults.pollInterval` over the live sessions (`stat`-cheap — the
  reader's size gate skips any transcript that has not grown, and its changed-only callback
  means one refusal is handled exactly once), the policy switch, the chooser actuator, and the
  scheduled continuation.

The transcript path is derived, not discovered: Claude ids are minted up front
([`sessions.md`](sessions.md)), so `ClaudeTranscript.url` names the file from the account's
config directory and the project slug. Native sessions come through neither layer — the same
refusal arrives on the structured stream, owned by the conversation — and other runtimes are
excluded by the capability table, never by a `kind ==` branch.

## The tracker's fifth fact

`SessionActivityTracker` gains `limitPark`, beside `pausedOnOwnWork` and for the same reason:
it is a genuinely new fact, not a longer turn and not a question ("the turn and the question are
separate facts" — [`session-activity.md`](session-activity.md)). The two shapes it was not:

- **Not an `openAsks` entry.** That set is exact-fact territory — a call closed by its own hook.
  Nothing ever closes the chooser: answering it raises no hook, so the mark would never come
  down.
- **Not `awaitsUser` inside an open turn.** Being looked at lowers that flag and returns to the
  turn — and a latched session has no quiet timer left, so one glance would re-strand it in
  `working` forever, which is the exact bug being fixed.

`limitPark` has two live values and `settle()` ranks them under `openAsks`:

- **`flagged`** — the limit hit and no recovery is armed (policy `flagOnly`, or a recovery that
  refused). Settles to **`limitReached`**, its own `SessionActivity` case with its own mark: see
  "The mark" below. It was `awaitingUser` first, which was wrong twice over — the filled dot
  promises an approval that does not exist, and it is a state the row drops the moment anybody
  glances at it.
- **`recovering`** — the chooser is answered and a continuation is scheduled. Settles to `idle`:
  the process really is sitting at its prompt, nothing is owed, and nothing should light the
  workload beam or post a notification. The mark exists to explain an *unexplained* stop, and the
  composer's scheduled-message strip already names this one. It outranks `pausedOnOwnWork`
  deliberately — work the 429'd turn left running cannot wake a limited agent, and `working`
  would be a lie the sidebar holds for hours.

The park clears on the next turn start, on `noteLimitCleared()`, and `markRunning`/`markDormant`
reset it with the rest of the process-scoped facts. Detection ends the stranded turn itself
(`turnInFlight = false`) — the transcript's `turn_duration` is the boundary the missing `Stop`
never delivered.

**Nothing lowers the park by guessing.** Two guesses were tried and removed: being looked at, and
an output burst in front of the user. Both were borrowed from `awaitsUser`, where they are the
best evidence available — but a limit is not a question the user can answer by arriving. *Both*
of the CLI's chooser options leave the account exactly as spent as it was, and the CLI repaints
around the chooser whatever is picked, so either guess would draw an ordinary idle row for a
session that still cannot run. The park is lowered by evidence instead: `noteLimitCleared()`,
raised by `LimitRecoveryCoordinator` when the reader answers nil, which happens exactly when the
transcript records a newer message.

## The mark

`SessionActivity.limitReached` is drawn by `ThemedWarningMark` — a triangle in
`Design.Status.negative`, its corners taken from the theme's control radius and capped at a
fraction of the triangle's own side (three arcs at `Design.Radius.control` would meet and round
the shape into a blob; a style that squares its panels draws this sharp).

It is a triangle and not a third dot because the two dots are ranked *against each other* by
fill — blocked versus unread, both meaning "this session wants you". A stop the user cannot
answer is a different kind of fact, and a different silhouette is what keeps it legible under
Differentiate Without Colour. It does not fade in, unlike the dots: they mean something just
happened and the eye should catch it, while this one is read minutes or hours later by somebody
wondering where a session went.

The row's hover popover carries the sentence — "Stopped · usage limit resets 1:20pm
(Europe/Rome)", the provider's own words for the reset, never reformatted into the Mac's locale
(see `UsageLimitStop`). `list_sessions` says "stopped at its usage limit" so an agent routing work
can tell it from a session that will answer when poked, and the mobile mirror gets the state by
name over the wire.

**No notification.** Every `AttentionAlert` is a change the user can act on; there is no action
behind this one, and the window resets when it resets. The edge into `limitReached` clears a
stale alert and says its piece on the row.

## The policy

`LimitRecoveryPolicy`, chosen in Settings ▸ Usage Windows, stored through `PreferenceStore` for
the same reason that page's other settings are: a feature that types into terminals and spends
rate limit unattended must not fire from a hosted test run (`LimitRecoveryCoordinator.start()`
also refuses outright under `XCTestCase`, the poker's second lock). **The default is
`flagOnly`.** Automatic recovery types into the user's session and spends their quota with
nobody watching; that is opted into, never discovered.

- **`flagOnly`** — detection still runs (it is what un-strands the tracker), the session reads
  `limitReached` and wears the mark, the user decides. Exactly today, minus the stuck spinner and
  plus a row that says why.
- **`waitForReset`** — answer the chooser with stop-and-wait, park, and schedule the
  continuation for the binding window's reset (below).
- **`resumeVia(account)` / `resumeOnBestAccount`** — *designed, not yet built.* Migrate the
  conversation (`SessionMigration` — the transcript is client-side state, verified in
  [`accounts.md`](accounts.md)) and continue immediately under a login with headroom. "Best" is
  the enabled same-provider login whose metering windows all have headroom, ranked by **pace
  deficit** — `elapsedFraction − usedFraction`, the account furthest behind its linear burn,
  taking each account's worst window. Three guards are part of the design: the target's reading
  is force-refreshed before migrating (a stale cache must not move a conversation onto a spent
  login — while still honouring the 429 pacing in `AccountUsageService`); a policy whose
  precondition fails degrades to `none` behaviour and says why, never silently escalating to a
  different escape; and a per-session recovery budget is enforced below the rules, so a defect
  above cannot turn this into an account-hopping loop.

Never, under any policy or parse result: the chooser's "Upgrade your plan" option. No automated
path may spend money.

## The chooser is answered by label, never by position

The specimen shows stop-and-wait as option 1, preselected; the user who asked for this feature
remembers it as option 2. Whichever memory belongs to which CLI version, that disagreement is
the specification: `LimitChooserReading` parses the visible terminal buffer, finds the row whose
label contains "Stop and wait", and emits *that* row's digit and Return — or, when the
selection marker already sits on it, Return alone. Any other screen — labels missing, wording
changed, a different question entirely — reads as *no chooser*, and the session simply flags.
Wrong in one direction only, the [`session-activity.md`](session-activity.md) shell-policy rule:
a missed recovery costs what today costs; a wrong keystroke types into someone's session.

### The stop has a second shape, and it needs no keystrokes

Measured on a second specimen (2026-08-07): when the limit lands as a *background workflow*
wraps up, the CLI draws no chooser at all — the sentence is printed inline under the finished
workflow ("You've hit your session limit · resets 1:10pm (Europe/Rome)" over "/upgrade to
increase your usage limit.") and the session is already back at its ordinary prompt. The
transcript record is the same either way, so detection cannot tell the shapes apart; **the
screen read is what tells**, and `.notice` is its third outcome: nothing to answer, recovery
skips the keystrokes and goes straight to the schedule.

The notice is recognised positively, never as "chooser missing", and only after the option scan
found nothing. Its two marks are chosen to be unconfusable with the chooser: the reset clause's
own spelling `resets ` — which the chooser's stop row ("…for limit to **reset**") never
contains, so a wrapped or half-drawn chooser cannot pass for the notice and be scheduled around
while it stands — and the slash-command hint `/upgrade`, where the chooser's option has no
slash. The reset clause additionally requires "limit" on the same row, so an agent's own prose
about resets does not pass on one word.

## Continuation rides scheduled messages

The `waitForReset` continuation is a `ScheduledMessage` — "continue", targeted at the session,
due at the binding window's `resetsAt` plus the same one-minute margin
[`scheduled-messages.md`](scheduled-messages.md) already applies, for the same racing reason.
Everything hard about the moment is already solved there and is reused, not rebuilt: delivery
types into a live terminal between turns in its own write; a send arriving to find the window
still spent follows `ScheduledResetPolicy` (wait-once by default, bounded by
`maximumResetRearms`); and a send whose process died goes `.waiting` in the strip rather than
being typed into a woken terminal — that subsystem's sharpest rule, which recovery inherits
rather than weakens. A resumed TUI comes up on its own restore question, and answering *that*
unattended is the outcome worth refusing over.

## Every step leaves a record

A recovery is invisible by construction — it acts precisely when nobody is watching — so it
follows the hooks' rule: `EventLog.Category.limitRecovery` journals what a bug report weeks
later would need, and the live narration goes to `ThreadingLogger` at `.debug`:

- the detection, with the record's error string and the session it belongs to;
- the tracker repair (stranded turn ended, park applied);
- the chooser read — including the refusals, *with the rows it saw*, because "it did nothing"
  and "it read a screen that was not the chooser" are unrelated bugs that look identical;
- every keystroke sent, spelled out;
- the schedule created (due instant, window, account) or the store's refusal;
- and the delivery outcome, which scheduled messages already journal on their side.

The one failure mode this cannot see — the poll itself never running — is covered by logging
its start, so an absent detection is distinguishable from an absent poller: a journal with
refusal records but no recovery entries indicts the coordinator, and a live log without the
start line indicts the launch wiring.
