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

- **The ordinary limit hit is a durable, structured record.** A synthetic assistant message with
  `isApiErrorMessage: true`, `error: "rate_limit"` and `apiErrorStatus: 429` is appended to the
  session's transcript. This path is therefore a transcript read, never screen scraping: the TUI
  chooser drawn over it ("Stop and wait for limit to reset / Upgrade your plan") is interactive
  dressing over a state the file already states exactly. The delegated-work exception below is
  deliberately weaker and needs a second key.
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
- **The rendered reset is never scheduling authority.** "resets 1:50am (Europe/Rome)" is
  locale-shaped prose; it can supply the human-facing hint (and, for the delegated exception, a
  clean sentence without the task wrapper), but the authoritative reset instant is `resetsAt`
  from the usage sources [`accounts.md`](accounts.md) already ranks. The transcript proves *that*
  the limit hit; the usage reading says *when* it lifts. (The specimen also shows why: the
  message blamed the session window while the toolbar pill was blaming the weekly Fable window —
  readings drift, the record does not.)

### The delegated-work exception has two keys

A second real specimen exposed a different provider edge: session `3149ae34` on 2026-08-23 was
still shown as working although its root terminal stood at the limit question. Its tail was:

```
11:49:59  assistant  stop_reason:"end_turn"              ← root completed
11:54:27  queue-operation enqueue <task-notification>
          status:"failed"
          summary:"Agent terminated early due to an API error:
                   You've hit your session limit · resets 4:50pm … · progress saved"
          root terminal: limit chooser / inline notice    ← no root synthetic 429 follows
```

The notification is a child outcome, not a root refusal. On its own it may never stop the parent:
the earlier `f3ad7546` specimen had a sidechain hit its limit and the root continued for another
five minutes. Conversely, the screen alone is untrusted presentation that can contain an agent
quoting these same words. Admission therefore requires both independent keys:

1. the newest completed root assistant (`stop_reason: "end_turn"`) is followed by a complete,
   failed task notification whose provider-failure summary is a recognised usage limit; and
2. the live root terminal positively parses as the exact chooser (one stop-and-wait option plus
   an upgrade option) or the exact inline notice (`resets … limit` or `/upgrade`).

`ClaudeTranscriptUsageLimit` returns the first key as a provisional `UsageLimitObservation`.
`LimitRecoveryCoordinator` checks the second through the existing `LimitChooserReading`, with the
same bounded write/paint retries used before chooser actuation, and only then creates the
`UsageLimitStop`. A newer root assistant supersedes the candidate. A root assistant ending on
`tool_use`, an ordinary task failure, a successful task that merely mentions limits, or any screen
other than the positive provider shape all fail closed. A rejected record identity is remembered
so the five-second poll does not screen-read it forever; a new notification receives a new attempt.

## Two layers, deliberately split

Detection and recovery are separate subsystems with separate owners, built concurrently and
meeting at one seam:

- **Detection** is `ObservedUsageLimit` → `ClaudeTranscriptUsageLimit` → `UsageLimitStop`: the
  capability-gated seam (`AgentCapabilities.transcriptUsageLimitRecord`, the
  `ObservedPermissionMode` shape), the `TranscriptFactReader`-backed reader, and the fact type.
  The newest *assistant* message record decides — a refusal stands until the provider produces a
  newer outcome. A newer user record is only proof that a retry was submitted locally; `/loop`
  can write it immediately before the provider repeats the same refusal. Sidechain refusals are
  excluded: a subagent running out of limit is a failed task to its parent, not the session
  stopping. A failed task notification after a completed root turn is retained only as a
  provisional `UsageLimitObservation`; it crosses into `UsageLimitStop` only when the live root
  terminal supplies the delegated-work exception's second key above.
- **Recovery** is `LimitRecoveryCoordinator` + `LimitRecoveryPolicy` + `LimitChooserReading`:
  a poll at `UsageLimitDefaults.pollInterval` over the live sessions (`stat`-cheap — the
  reader's size gate skips any transcript that has not grown, and its changed-only callback
  means one refusal is handled exactly once), the bounded confirmation of a provisional task
  failure, the policy switch, the chooser actuator, and the scheduled continuation.

Recovery reaches a terminal through `AgentTerminalLimitRecoverySurface`: bounded visible lines,
keystroke insertion, and the two limit-park mutations. The UI adapter delegates those operations
to its terminal and tracker; Core never obtains `AgentSessionViewController`, `TerminalSession`, or
a view. Running-only lookup gates chooser input, while the allocated-surface lookup remains
available to lower a transcript-derived park after a process exits.

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

The park clears on `noteLimitCleared()`, and `markRunning`/`markDormant` reset it with the rest of
the process-scoped facts. A turn start deliberately does **not** clear it: `UserPromptSubmit`
means the CLI accepted a local prompt, and both `/loop` and a scheduled continuation can raise it
before a still-spent account writes another refusal. Detection ends the stranded turn itself
(`turnInFlight = false`) — the transcript's `turn_duration` is the boundary the missing `Stop`
never delivered.

**Nothing lowers the park by guessing.** Two guesses were tried and removed: being looked at, and
an output burst in front of the user. Both were borrowed from `awaitsUser`, where they are the
best evidence available — but a limit is not a question the user can answer by arriving. *Both*
of the CLI's chooser options leave the account exactly as spent as it was, and the CLI repaints
around the chooser whatever is picked, so either guess would draw an ordinary idle row for a
session that still cannot run. The park is lowered by evidence instead: `noteLimitCleared()`,
raised by `LimitRecoveryCoordinator` when the reader answers nil, which happens exactly when the
transcript records a newer assistant outcome. Repeated refusals carry their transcript record identity, so
a loop that receives the same provider sentence again is a new stop rather than an unchanged
cached value.

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

`LimitRecoveryPolicy`, stored through `PreferenceStore` for the same reason that page's other
settings are: a feature that types into terminals and spends rate limit unattended must not fire
from a hosted test run (`LimitRecoveryCoordinator.start()` also refuses outright under
`XCTestCase`, the poker's second lock). **The default is `flagOnly`.** Automatic recovery types
into the user's session and spends their quota with nobody watching; that is opted into, never
discovered.

- **`flagOnly`** — detection still runs (it is what un-strands the tracker), the session reads
  `limitReached` and wears the mark, the user decides. Exactly today, minus the stuck spinner and
  plus a row that says why.
- **`waitForReset`** — answer the chooser with stop-and-wait, park, and schedule the
  continuation for the binding window's reset (below).
- **`resumeVia(account)` / `resumeOnBestAccount`** — migrate the conversation (`SessionMigration` —
  the transcript is client-side state, verified in [`accounts.md`](accounts.md)) and continue
  immediately under a login with headroom. "Best" is the enabled same-provider login whose metering
  windows all have headroom, ranked by **pace deficit** — `elapsedFraction − usedFraction`, the
  account furthest behind its linear burn, taking each account's worst window. The ranking is
  `LimitEscapeRanking`, written for the interactive escape below and not duplicated here: the
  arithmetic that decides where a conversation goes is the same arithmetic whoever asked for it.
  `armAccountResume` is what the policy adds, and its three guards are the ones this design always
  stated:
  - the **target's reading is force-refreshed** before anything moves, and eligibility is decided on
    that — a stale cache must not move a conversation onto a login that is also spent, while the 429
    pacing in `AccountUsageService` is still honoured, so an unattended recovery cannot become a way
    to hammer a usage endpoint. The choice is made on fresh readings in Core; the press path's own
    re-check on the chosen login then runs unchanged, which is the guard staying in one place
    rather than being written twice;
  - a **failed precondition degrades to `flagOnly` and says why**, never silently escalating to a
    different escape. A pinned login that is spent is reported as *that* login being spent; the
    strip then offers whichever login now ranks best, for a press. `resolveResumeTarget` refuses
    five shapes by name, and each carries two sentences — the journal's diagnosis and the strip's
    explanation;
  - a **per-session budget** (`LimitRecoveryBudget`) sits below the rules, so a defect above cannot
    turn this into a login-hopping loop. It is a rolling window rather than a lifetime count,
    because a defect loops in seconds while a legitimate long-running chat may exhaust several
    logins over a week, and it is spent at the *attempt*: the failing shape is the more likely
    defect.

  Two smaller decisions the shipped version records. **No modal on an unattended failure** —
  `moveSessionWithoutConfirmation` grew `alertingOnFailure` because a sheet nobody dismisses stops
  the whole app until somebody comes back; the failure goes to the journal and to the strip
  instead. And **the park says `recovering` while the readings land**, not `flagged`: the triangle
  explains a session nothing is being done about, and a row that flashed it mid-migration would be
  answering its own question wrong. `standDown` lowers it, which is the state the triangle is for.

  **Rendered conversations are deliberately out of scope**, exactly as they are for `waitForReset`:
  nothing recovers a native conversation automatically (see "One store, both surfaces"), so all
  three acting policies belong to the terminal detection path and that surface stays the `flagOnly`
  case with a strip. Extending policy-driven recovery there is one change for all of them, not a
  capability the newest two should quietly acquire on their own.

Never, under any policy or parse result: the chooser's "Upgrade your plan" option. No automated
path may spend money.

### Where the move lands, and why it is not typed into

`SessionMigration.move` discards the process before it copies the transcript, so an automatic
migration always ends with the agent stopped. What happens next is inherited from
[`scheduled-messages.md`](scheduled-messages.md) rather than decided here, and the inheritance is
the point: the continuation is an ordinary `ScheduledMessage`, so a session whose pane was showing
is relaunched by `reopenIfShowing` and typed into between turns, while a background session's send
reports `.noLiveSurface` and waits **visibly** — Threading does not wake a terminal to type into it,
because a resumed TUI comes up on its own restore question and answering that unattended is the one
outcome worth refusing over. The unattended policy therefore buys the *move* — the conversation is
on a login with room, and its "continue" is filed — and the last step waits for the session to be
opened. That is a smaller promise than "it carries on while you sleep", and it is the one the rules
above can actually keep.

### It is chosen at three scopes, and the narrow one is the point

`LimitRecoveryResolution` resolves a chat's answer narrowest-first — the session, its checkout,
then Settings — and **absent means inherit, not copy**, the rule `ThemeResolution`,
`AttentionAlertScope` and `SoundResolution` all follow. `LimitRecoveryCoordinator` consults it
where it used to read `LimitRecoveryPolicy.current`, which is the whole of the change: one line,
because the policy was only ever read in one place.

The reason it is not a single global switch is the paragraph above, read the other way round. A
setting that arms unattended typing is opted into — and a switch that can only arm *everything*
is the broad statement, so it stays off and the feature goes unused. "This long-running chat
carries on at reset, my other five do not" is the narrow one, and narrow is the safer default
shape for a permission, not the more dangerous one.

**A list of outcomes, with the scope state still only in the record.** It was a checkbox while
there were two answers, and four do not fit on one: stopping, waiting for the reset, and the two
that move the conversation are alternatives to each other, so the item in the session menu's
Options fold and its twin on the project row are now a fold — **When the Limit Is Reached**, named
after the condition, because a fold carrying one of its own rows' names reads as that row being
switched on. Nothing else about the rule changed. The writers still store **nil where the wanted
value already matches what would have been inherited** — `chooseLimitRecovery`, and the mute item's
rule before it — so a chat keeps *following* its project and Settings, and a later change there
still reaches it. The check still reads the **resolved** answer rather than the record's own field,
because an unmarked list on a chat that will in fact continue by itself states the opposite of what
happens.

The iPhone's owner-only Chat Settings sheet is another writer of that same chat-scoped record, not
a mobile recovery engine. The Mac sends the resolved answer as one optional scalar, the phone
chooses among the same outcomes, and the server writes nil when the requested answer equals the
project/app inheritance. Detection, chooser answering, scheduling, ranking, migration budgets and
diagnostics therefore remain on the Mac. Guest summaries omit the answer and guest mutations are
denied.

**Only a chat's own menu names a login.** `resumeVia` carries an `AccountID`, and a login belongs
to exactly one runtime while a checkout hosts chats of several and Settings speaks for all of them
— so those two scopes offer `LimitRecoveryPolicy.runtimeNeutralChoices`, whose third entry means
"whichever of *that chat's* logins has room" and is well defined everywhere. Within the chat's fold
the two gates are also different questions, deliberately: the ranked answer is gated on the
*capability* (`kind.supportsAccounts`), so a chat with a single login can still arm it, while the
per-login rows come from `SessionMigration.destinations` and appear as logins do. A pinned login
that has since gone is the one answer the list cannot show, and then nothing is checked — which is
the truth, and the same state the policy stands down over.

**The rows say so.** `RowConductSummary` marks a sidebar row that carries a non-inherited
*conduct* setting — this policy and `notificationsMuted` — and `SessionInfoPopover` names which.
The line is deliberate: a theme and a sound announce themselves the moment they act, so marking
rows for those would light up most of the sidebar and say nothing, while these two act precisely
when nobody is watching and their surprise is always "why did that happen, or why didn't it?".
The mark is compared against the **inherited** answer rather than tested for non-nil, so a record
holding a value that matches what it would have inherited anyway draws nothing — a row claiming
to differ while behaving identically is worse than no mark. It is materialized on the
`pinnedIndicator` terms, so the ordinary row pays no image, constraints or stack slot for it.

## The interactive escape

The same choice, offered as a strip over the refused session's composer and pressed by hand:

> ⚠ Limit reached · resets 9:40pm (Europe/Rome)  ·  **Continue as Nova Hartley · 5h 12% · 7d 40%**  ·  ✕

**It needs no settings opt-in, and that is not an oversight.** The reason the automatic policies
are opted into is stated above: they type into the user's session and spend their quota *with
nobody watching*. A press is the watching. Everything the automatic version needs permission
for — stopping the agent, moving the conversation, spending a second login's window — is named on
the button's own face before it is pressed, so a confirmation sheet behind it would only ask the
user to agree with what they just read. `SessionCoordinator.moveSessionWithoutConfirmation` exists
for that caller and for the policy's, and it alerts only for the first (`alertingOnFailure`);
`moveSession` keeps `.moveRunningSessionToAccount`, because the sidebar's **Move to Account**
submenu names a login and says nothing about stopping an agent.

The **per-session recovery budget** is not needed here and is deliberately absent. It exists so a
defect above the rules cannot become an account-hopping loop; a loop needs somebody pressing a
button once per hop, which is a user changing their mind rather than a bug.

**The press and the policy run one routine**, which is `armWaitForReset`'s rule in the other
direction: `performLimitEscape` takes a `LimitEscapeTrigger` and an optional login, so the four
steps below are the same steps either way. The trigger changes exactly two things — the modal, and
who is told when it fails (`LimitRecoveryCoordinator.noteAutomaticResumeFailed`, because the park
is Core's fact and the move is not) — plus one thing a named login forces: `retarget` points the
standing record at the login the policy chose before the busy line is drawn from it, since
`resumeVia`'s login need not be the one the ranking offered and a strip reading "Continuing as
Nova Hartley…" over a conversation going somewhere else is the misstatement `busy` is named rather
than counted to avoid.

### The ranking is pure, and it is the automatic policy's

`LimitEscapeRanking` takes accounts, readings and a model as values and answers with an order —
`preferred(among:)`'s shape, for `preferred(among:)`'s reason: a rule that decides where somebody's
conversation goes is testable with no home directory to scan and no network to answer.

- **Candidates** are `SessionMigration.destinations(for:)`: the enabled logins of the session's own
  runtime, minus the one that refused. That list is already capability-gated, which is why nothing
  in this feature names a provider — a runtime that routes no accounts offers none and the strip
  never appears.
- **Eligibility** is decided on every window metering the session's *effective* model — the
  account's own windows and the model-scoped ones together, `bindingWindow`'s list rather than
  `peakWindow`'s. All of them must sit below `LimitEscapeDefaults.headroomFraction`, which **is**
  `UsageDefaults.warningFraction` rather than a second number beside it: an account the pill
  already tints as pressured is not a place to move a conversation that has just run out, and two
  thresholds a few points apart would eventually disagree about one login on one screen.
- **Three shapes are refused rather than guessed at**: a login with no reading, a login whose
  reading names no windows, and a window whose `resetsAt` has passed. The last is the subtle one —
  a stale percentage describes the *previous* window ([`accounts.md`](accounts.md)) and is very
  likely to be generous, which is exactly why it must not be believed by the one reader that would
  move a conversation on the strength of it.
- **The order is pace deficit**, `elapsedFraction − usedFraction`, taken on each account's *worst*
  metering window, furthest behind its own burn first. The same comparison `weeklyAheadOfPace`
  already makes for the usage-window poke, and the reason it is not "the emptiest account": 40%
  spent four hours into a five-hour window has more left in practice than 30% spent in the first
  hour. A window whose length the provider did not state contributes a deficit of zero rather than
  a number invented from one side of the subtraction. Ties keep the order the candidates arrived
  in, so an unchanged discovery order cannot make the offer flicker between two logins.

### The strip carries the refusal, not only the escape

`LimitEscapeSuggestion`'s account half is **optional**, and that is the record's whole shape. It
began as "one login to escape to", which meant `compute` answered nil where nothing had headroom
and `refusalStands` cleared the entry — so a session with a single login got no strip at all, and
the sidebar's triangle was the only thing saying it had stopped. Waiting for the reset needs no
second account, so the *refusal* is what the record is about and the login is one of its two
answers. Three things follow, and the third is a capability the old shape could not express:

- a single-account session gets a strip, carrying **Wait for Reset** alone;
- dismissal, the busy state and the problem sentence keep working for it, because they live on an
  entry that now always exists;
- `update`'s re-rank **upgrades** a refusal that had no login into one that does, the moment a
  candidate's reading arrives with headroom. It bailed before, having no entry to update.

`busy` names *which* answer is running (`LimitEscapeAction`) rather than counting a Boolean. Both
controls dim while either runs — the second would act on the same refusal — but only the pressed
one says so: a strip reporting "Continuing as Nova Hartley…" because somebody pressed the button
beside it would be naming a login change that is not happening.

**The button and the standing option are worded differently on purpose**, and were not at first.
Sharing one name looked right — one behaviour, one name — and read wrong: "Continue at Reset" is
an outcome, which is what an option in a menu should be, and on a strip opening with "Limit
reached" it turned into a mode the reader was being asked to switch on, over a session where
switching it on could no longer change anything. The strip instructs (**Wait for Reset**), the
context-menu option states (**Continue at Reset**), and
`LimitEscapeStripTests.testTheButtonInstructsWhileTheStandingOptionStates` keeps a later tidy-up
from merging them back.

### Arming a refusal that already stands

`LimitRecoveryCoordinator.armWaitForReset(for:)` is the policy's own routine reached by hand, and
deliberately not a second implementation of it. Three things differ, each because a press is
watched where a policy is not:

- **Failures speak.** `standDown` still leaves the session exactly where `flagOnly` would and still
  journals the reason, but a press also gets the sentence on the strip it came from. It must not
  call `offerEscape` there: recomputing the suggestion files a *new* refusal over the standing one,
  which clears the dismissal and wipes the very sentence being written.
- **No terminal is not a failure.** A rendered conversation has no chooser to answer, so the
  keystrokes are skipped and only the schedule is made — the `.noticeOnly` path, which already
  models "nothing to answer, schedule anyway". The surface is asked of the record
  (`usesNativeUI`) rather than probed for.
- **Success clears the offer**, because from then on the pending send is the fact and the
  composer's scheduled-message strip is what names it.

Whether the wait is on offer at all is `hasOwedContinuation(for:)` — **one predicate, two
readers**: the arm guards on it and the strip is drawn from it, so the button cannot offer
something the code behind it would decline.

### One store, both surfaces

`LimitEscapeSuggestionStore` holds the standing refusal and the offer computed from it, keyed by
session, **in memory only** — a refusal is a fact about a live process, the transcript still says
so on the next launch, and restoring an offer would be answering a question nobody re-asked.

Codex workspace plans use a second vocabulary for the same stop: "workspace is out of credits"
and the structured `usageLimitExceeded` error. Its native app-server session turns the explicit
non-retrying error into a failed terminal event, and `UsageLimitStop` recognises the credits
wording even though it carries no reset hint. That puts the row in `limitReached` and feeds this
same store; it must not fall back to idle merely because the provider named shared credits rather
than a timed limit.

Both producers call the same entry point. `LimitRecoveryCoordinator` calls `refusalStands` from
both places `noteLimitParked(recoveryArmed: false)` lands — the `flagOnly` branch and `flag()`,
which is where `waitForReset` degrades to — and from nowhere else, since an armed recovery already
has a plan. `ConversationViewController` calls it where the stream's own refusal sets `usageLimit`:
nothing recovers a rendered conversation automatically, so that surface is permanently the
`flagOnly` case this is written for. Both call `refusalCleared` on the same edge that clears the
park.

Two more edges close the loop. Detection **warms** every candidate's reading through
`AccountUsageService.refresh` at the moment the refusal is read, because that is minutes before
anybody looks at the strip and it is the only moment a fetch has time to land; and
`AccountUsageDidChange` re-ranks the standing refusals with the answer, over a set that is almost
always empty. A re-rank keeps the dismissal — it is the same refusal — while a *new* refusal
clears it, which is the whole of the dismissal rule: ✕ waves away one refusal, not the state of
being refused.

### The press

1. The button goes busy so a second press cannot start a second migration.
2. The **target's** reading is force-refreshed and eligibility asked again. This is the guard the
   automatic design states, unchanged: a cached figure must not move a conversation onto a login
   that is also spent. `AccountUsageService.refresh(_:force:settled:)` is the receipt that made it
   possible — it fires when the reading is as fresh as the account's pacing allows, including
   immediately when the endpoint's own `notBefore` refuses the fetch, because a user pressing a
   button must not be a way to spend a rate limit faster.
3. A target that turns out to be spent **degrades and says so**: the sentence states it, the button
   dims keeping the fresh reading it was refused on, and no other login is chosen. A better
   candidate becomes a new offer at the next reading, pressed the same way this one was — which is
   the policy rule "never silently escalating to a different escape", with the user in the loop.
4. The move runs through `SessionCoordinator`, which reopens the pane (`reopenIfShowing`) exactly
   as the menu route does, and keeps its failure alert. The copied transcript carries the source
   account's refusal at its tail, but that is already-observed output rather than a refusal by the
   destination account: `ObservedUsageLimit.transcriptWasMigrated` records the installed copy's
   exact byte boundary at the new path, while `LimitRecoveryCoordinator.accountWasMigrated`
   clears the old login's park and standing suggestion. Both halves are necessary: seeding the
   destination reader nil-to-nil intentionally raises no changed-value callback, so without the
   explicit in-memory invalidation a delayed account-usage reading can re-rank the source refusal
   after the move and offer the login the conversation just left.
5. The continuation is a `ScheduledMessage` — `LimitRecoveryDefaults.continuationText`, due
   `LimitEscapeDefaults.continuationDelay` from now, wall-clock anchored. **Not typed**: everything
   hard about typing into a just-relaunched TUI is already solved in
   [`scheduled-messages.md`](scheduled-messages.md) and is inherited rather than restated — a send
   arriving mid-turn parks `.waiting` and is retried on the activity edge, and a send whose process
   is gone waits visibly rather than being typed into a woken terminal. The delay is not the
   safety; it only spares the store an attempt that could not have landed. The anchor is
   deliberately `wallClock` and not the window's reset: the window this send is aimed past belongs
   to the account it is *leaving*.

Everything above journals to `EventLog.Category.limitRecovery` in the same style as the rest of
this subsystem: the suggestion with its account, deciding window and reading; the absence of one;
the dismissal; the press; and each of the three ways the press can end.

### The recovery ribbon

`LimitEscapeStripView` is the specialized actionable pane ribbon (`UI/Design/`), drawn from the
store and reporting both gestures back — the one-direction rule `ScheduledMessageStripView`
states. It shares `PaneNoticeView`'s full-width ground, closing rule, height, inset and push-not-
cover placement. It remains a separate component because its offer changes in place while work is
in flight and because its two gestures are limit-recovery intentions rather than generic notice
actions. It owns its ground for the same reason as `PaneNoticeView`: in a terminal pane the surface
behind it is the *terminal's* palette, which the app theme knows nothing about.

The condition and the action form one leading run; only dismissal sits at the opposite edge. The
first layout let the sentence absorb every spare point while pinning the action beside dismissal,
so a wide terminal turned one choice into two islands hundreds of points apart. The condition uses
the control text role and label ink rather than caption/secondary: it is the premise of the action,
not metadata underneath it.

Its hosts put it directly below the pane header, spanning the whole pane, and the conversation or
terminal begins below it. Each host swaps one of two content-top constraints as the offer arrives
or leaves, so the ribbon never overlays content and the PTY resizes exactly once per transition.
This placement is independent of the composer: a provider refusal normally exits the agent and
hides the prompt, and the former composer-retained placement consequently left the recovery row
floating deep inside the empty conversation.

When the constrained Codex account reports banked reset inventory, the ribbon adds **Use Reset**
beside its existing wait or account-migration action. That button enters the shared banked-reset
confirmation and account single-flight; it never spends directly from the ribbon. After Codex's
authoritative post-read shows headroom, Threading releases every already-existing `continue on
reset` message for that exact account, including other chats that were waiting on it. It creates
no scheduled message for a chat that did not already owe one.

This is deliberately host-only extension surface. The host retains refusal detection, suggestion
ranking, migration, scheduling, the in-flight state and dismissal; the native presentation uses
the shared design-system ribbon vocabulary and exposes no extension replacement seam.

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
The refusal first force-refreshes its account and waits for that refresh's settlement before
selecting the binding window; starting an asynchronous refresh and immediately consulting the old
cache can aim a five-hour refusal at a fuller seven-day window. The record's `.limitRecovery`
purpose and refusal identity make deduplication exact: the same refusal reuses its continuation,
while a newer refusal replaces the obsolete recovery plan. A user-authored reset preset never
counts as either one. When the provider produces a newer successful outcome before the due time,
the refusal has cleared and the promise is already fulfilled, so the store cancels that app-owned
continuation in one commit; leaving it armed would type an unsolicited `continue` later and could
also suppress the next real recovery.
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
- provisional background-task evidence, including whether the live terminal confirmed or
  rejected it and the bounded screen sample on rejection;
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
