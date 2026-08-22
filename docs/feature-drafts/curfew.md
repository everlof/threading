# Curfew: a scheduled end for a session

> Status: **in progress** (August 2026). This draft is the implementation spec; steps land in
> order and each is reviewed and green before the next begins. When the slice ships, the durable
> decisions move to `docs/architecture/curfew.md` and this file becomes a pointer.

## Context

Threading can schedule a *start* — a message or a new session at a wall-clock time, at a usage
window's reset, or when another conversation finishes (`docs/architecture/scheduled-messages.md`).
There is no way to schedule an *end*. The case that prompted this: the 5-hour window resets at
04:00 while the user sleeps; they want a session to spend what is left of the current window
overnight (driving it with the provider's own `/loop` or `/goal`) and **not** eat into the fresh
window after the reset.

"Keep working until" stays with the providers. Threading owns **"until"**: the clock, the fence and
the graceful wind-down. Neither `/loop` nor `/goal` has a wall-clock bound of its own — the pairing
is the feature.

### Decisions already made (do not reopen)

- **Interrupt by default; stopping the agent is an opt-in escalation.** The default ladder never
  terminates — the user wants to come back and read the chat/terminal. A Settings choice ("If it
  keeps working after 3 interrupts: Notify me / Stop the agent") arms the escalation: on give-up
  the engine calls `AgentRuntime.terminate(sessionID:)`, which deliberately **keeps the terminal
  so its final output stays visible** (`AgentRuntime.swift:732`) — never `discard`. The row stays
  in the sidebar, the pane keeps the conversation, and resuming reuses the existing
  **Resume Session** affordance (`TerminalContainerViewController.showDormantState`, ~L1717–1747)
  rather than growing a second one. A native conversation's timeline is persisted and replays, so
  "see where it left off" is native behaviour there too.
- **Margins: wind-down 10 min before, grace 5 min after**, both editable.
- **Settings holds defaults + optional standing quiet hours** that every session inherits;
  session/project override with nil-means-inherit (the `LimitRecoveryResolution` pattern).
- Conduct, not weather: `RowConductSummary` mark, `LimitEscapeStripView` with a new source,
  no new `SessionActivity` case. **Lift Curfew** is legitimate because the rule is the user's own.
- Out of scope for this slice: iPhone mirroring/mutation (no scheduled-message DTO exists today),
  project-specific quiet-hours windows, per-session wrap-up text.

## The shape

One deadline **T** per session, three consequences, each with a margin:

| Moment | Consequence | Reuses |
|---|---|---|
| **T − wind-down** | A wrap-up message goes to the session — **only if it has a turn in flight** (an idle session has nothing to wrap up, and typing into it would wake it and spend usage). Default text: *"Your curfew is at {time}. End any loop or goal you are running, commit what is safe, write what is left to a handoff note, then stop."* | An ordinary `ScheduledMessage` with `Purpose.curfewWindDown`; store, strip, custody and delivery for free |
| **T** | **Hold**: Threading stops spending the session on its own — outbox stops draining at the turn boundary, scheduled sends stand aside, `send_to_session`/resume/spawn refused, usage-window poke stands down. The keyboard still works (tier-4 park rule; copy says so). | `CustomLimitParkPolicy` / `CustomLimitBounds.hold` consumers, one new predicate |
| **T + grace** | **Interrupt** a turn still in flight. Native → `ConversationTurnControl.interrupt`. Terminal → one Escape through `AgentTerminalInputSurface.insertTerminalText` (new: today only `\r` and chooser digits are ever typed) | `AgentRuntime.runningTerminalInputSurface(for:)`, `ConversationViewController.stopCurrentTurn()` |

**Bounded re-interrupts, only for unwatched turns.** A provider loop re-submits from inside the
CLI, so a held session that starts a new turn after T+grace is interrupted again on the activity
edge — but only when **nobody is watching** (`!NSApp.isActive || !tracker.isVisible`, the
`ScheduledMessageNotifier` rule), never for a native composer-submitted turn, at most
`maximumInterrupts = 3` with `reinterruptSpacing = 30 s`. After that the curfew **gives up**,
records it, and — by the Settings choice — either posts one actionable `AttentionAlert` ("Kept
working after 3 interrupts", the default) or **stops the agent**: `AgentRuntime.terminate`, final
screen kept, receipt `.stoppedAgent`, strip clause "stopped 04:12". A turn started in front of
the user is theirs.

**Escape is capability-gated.** New `AgentCapabilities.escapeInterruptsTerminalTurn` (Claude,
Codex). It is typed only when `kind.supports(.escapeInterruptsTerminalTurn)` (no new `supportsX` property — the capability file reserves those for the original seven), `AgentRuntime.reportsOwnTurns(sessionID:)` is
true and the tracker reports a turn in flight — so Escape never lands on a restore/question
chooser. Otherwise the session gets the hold only and the strip says *"Threading cannot tell
whether this session is working, so it only stops delivering messages."*

**The wind-down stays deliverable until T + grace + wind-down**, exempt from the curfew hold, so
an interrupted agent still gets one turn to commit and write the handoff. Native: it lands in the
outbox as an item with `origin: .curfewWindDown`, which the held drain lets through. Terminal:
`.busyTerminal` → `.waiting` → typed between turns when the interrupt produces the activity edge.
Past that window it fails with *"Its curfew passed before the session was free."*

**Lifted explicitly only** (strip / menu). Quiet-hours curfews also end when the window ends.
Hand-typed turns do not lift it.

## Domain model

**`Sources/Threading/Models/SessionCurfew.swift`** (new; rides in the session JSON payload — no
SQLite migration, `ProjectDatabase.swift:90-99`)

```swift
enum CurfewRule: Equatable, Sendable { case exempt; case until(Date) }   // nil on a record = inherit
// hand-Codable via a tagged Stored form; unknown kind decodes as nil (AgentSession.swift:1129-1137 rule)

enum CurfewOrigin: Codable, Equatable, Sendable { case session; case quietHours(endsAt: Date) }

struct CurfewReceipt: Codable, Equatable, Sendable {
    enum Event: String, Codable { case windDownSent, windDownSkippedIdle, windDownFailed,
                                    held, interrupted, gaveUp, lifted, ended }
    let event: Event; let at: Date; let detail: String?
}

struct SessionCurfewState: Codable, Equatable, Sendable {
    let deadline: Date                 // instance identity — a new T resets the state
    var origin: CurfewOrigin
    var windDownMessageID: ScheduledMessageID?
    var interruptCount: Int; var lastInterruptAt: Date?
    var liftedAt: Date?; var gaveUpAt: Date?
    var receipts: [CurfewReceipt]      // capped at CurfewDefaults.maximumReceipts = 8
}

enum CurfewDefaults { windDownMargin 600, grace 300, maximumInterrupts 3, reinterruptSpacing 30,
                      maximumReceipts 8, timePlaceholder "{time}", windDownText, symbol "moon.zzz",
                      windDownMarginChoices [nil,5,10,15,30 min], graceChoices [nil,0,5,10,15 min],
                      quietHoursStartMinute 4*60, quietHoursEndMinute 8*60 }
```

- `AgentSession`: `var curfewRule: CurfewRule?`, `var curfewState: SessionCurfewState?` —
  CodingKeys, `decodeIfPresent` (rule through its raw stored form), `encodeIfPresent`.
- `Project`: `var curfewRule: CurfewRule?` — the setter refuses `.until` at project scope.
- `ProjectStore`: `setCurfewRule(_:forSessionID:)`, `setCurfewRule(_:forProjectID:)`,
  `updateCurfewState(_:forSessionID:)` — the `setLimitRecoveryPolicy` shape
  (`ProjectStore.swift:947-962`, `ProjectMutationResult`).

**`Sources/Threading/Core/Settings/CurfewSettings.swift`** (new; `UsageWindowSettings` shape —
`RecoverableDefaultsStore<CurfewPreferences>` over `PreferenceStore`, key `curfewPreferences`,
`.preference` criticality, posts `CurfewSettingsDidChange`)

```swift
struct QuietHours: Codable, Equatable, Sendable {
    var isEnabled: Bool; var startMinute: Int; var endMinute: Int   // end <= start crosses midnight
    func window(containing now: Date, calendar: Calendar) -> DateInterval?   // also checks yesterday's start
    func nextWindow(after now: Date, calendar: Calendar) -> DateInterval?
}
struct CurfewPreferences: Codable, Equatable, Sendable {
    var windDownMargin: TimeInterval?   // nil = off
    var grace: TimeInterval?            // nil = never interrupt
    var windDownText: String
    var quietHours: QuietHours
}
```
All window arithmetic through `Calendar` (`date(bySettingHour:minute:second:of:)`,
`date(byAdding: .day ...)`) — never `+ 86_400`; the DST tests in `ScheduledTimePresetsTests` are
the fixtures.

**`Sources/Threading/Core/Settings/CurfewResolution.swift`** (new; `LimitRecoveryResolution`
shape, store passed as a parameter)

```swift
enum CurfewScope { case session, project, app }
struct ResolvedCurfew { deadline, origin, windDownMargin?, grace?, windDownText
    var windDownAt: Date?; var interruptAt: Date?; var windDownDeliverableUntil: Date; var endsAt: Date? }
enum CurfewResolution {
    struct Answer { let scope: CurfewScope; let curfew: ResolvedCurfew? }
    static func resolve(session:project:preferences:state:now:calendar:) -> Answer   // pure
    static func inherited(beyond:project:preferences:now:calendar:) -> ResolvedCurfew?
    @MainActor static func answer(forSessionID:in:now:) / inherited(beyondSessionID:in:now:) / answer(forProjectID:in:now:)
}
```
Chain: session `.exempt` → none; session `.until(T)` → curfew; project `.exempt` → none; quiet
hours enabled → the window containing `now`, else the next one; else none. `state` enters for one
reason: a lifted quiet-hours instance (`state.deadline == window.start && liftedAt != nil`)
resolves to none until `endsAt`. A lifted one-shot clears its own rule.

**`Sources/Threading/Core/Session/CurfewHoldPolicy.swift`** (new; `CustomLimitParkPolicy` shape) —
`hold(sessionID:in:at:) -> CurfewHold` (`.clear` / `.held(since:curfew:state:)`), `isHeld`,
`holdReason`. **The one decision** every consumer, strip and row asks.

**`Sources/Threading/Core/Session/CurfewReceiptWords.swift`** (new; `CustomLimitReceipt` shape —
L10n lives here, the engine stays wordless): `holdReason`, `stripSentence` ("Curfew since 04:00 ·
wrap-up sent 03:50 · interrupted 04:05 ×2" / cannot-tell / gave-up variants), `conductStatement`,
`windDownText(template:deadline:)` (`{time}` via `ScheduledTimePresets.time`),
`windDownFailureReason`, `gaveUpAlertBody`.

**Smaller additions**: `ScheduledMessage.Purpose.curfewWindDown` (existing `?? .userAuthored`
decode covers old files); `ScheduledSessionPlan.curfew: ScheduledCurfewPlan?`
(`enum ScheduledCurfewPlan { case at(Date); case atQuietHours }`, optional → back-compatible);
`ConversationOutbox.Item.origin: Origin = .user` with `.curfewWindDown`;
`TerminalDefaults.interruptSequence = "\u{1b}"`; `EventLog.Category.curfew`;
`AgentCapabilities.escapeInterruptsTerminalTurn`; events `CurfewDidChange(sessionID)`,
`CurfewInterruptRequested(sessionID)`, `CurfewSettingsDidChange` beside their owners.

## The engine — `SessionCurfewCenter`

`Sources/Threading/Core/Session/SessionCurfewCenter.swift` (new), mirrors `SessionSnoozeCenter`
(`SessionSnooze.swift`): **one process timer, persisted state is the truth, `Date()` is the only
authority**, `rebuildAndMaterialize()` on `start()`. Observes `NSSystemClockDidChange`,
`NSSystemTimeZoneDidChange`, `NSApplication.didBecomeActiveNotification`,
`NSWorkspace.didWakeNotification` **on `NSWorkspace.shared.notificationCenter`**
(`ScheduledMessageScheduler.swift:120-124` — the mistake its test exists for),
`SessionActivityDidChange` (per-session O(1) evaluation), `CurfewSettingsDidChange`,
`ProjectsDidChange`, `ScheduledMessagesDidChange` (wind-down receipts).

Everything injectable: `projectStore`, `scheduledMessages`, `settings`, `now`, `calendar`,
`activity`, `reportsOwnTurns`, `isWatched: (SessionID) -> Bool`, `performers`
(`interruptNative` = post `CurfewInterruptRequested`; `interruptTerminal` = insert Escape via
`AgentRuntime.shared.runningTerminalInputSurface(for:)`; `postGaveUpAlert`), both notification
centres, `eventLog`. **No UI type is named** — the native interrupt is announced and
`SessionCoordinator` performs it (the `LimitAccountResumeRequested` pattern; Core's ratchet on
`ConversationViewController` is exact). `start()` refuses under `XCTestCase` with default
dependencies (the `UsageWindowPoker` lock — this types into terminals).

Evaluation of one session at `now`:
1. Resolve; no curfew → nothing pending. New `deadline` → fresh state. Quiet window closed →
   receipt `.ended` once.
2. **Wind-down**: `windDownAt <= now < deliverableUntil`, no wind-down receipt → turn in flight ?
   file the `ScheduledMessage` (due now, `.wallClock`) : receipt `.windDownSkippedIdle`. Past the
   window with the record still owed → `store.fail` with the curfew's own sentence.
3. **Hold**: `now >= deadline`, no `.held` receipt → receipt `.held`, post `CurfewDidChange`.
4. **Interrupt**: at `interruptAt` with a turn in flight → interrupt (native / gated Escape /
   nothing). Later turn starts while held → only if unwatched and not composer-submitted, spacing
   honoured, count < 3; else `.gaveUp` + alert — or, when `stopsAgentOnGiveUp`, the `stopAgent`
   performer (default `AgentRuntime.shared.terminate(sessionID:)`), receipt `.stoppedAgent`, and
   the alert says "Stopped after 3 interrupts" instead. The engine's trigger is carried as a
   *reason* (curfew today; a custom-limit park later) so the ladder can be reused by an
   account-rule `enforce` tier without retrofitting.
5. Persist state in one `updateCurfewState` write; journal each receipt to `EventLog(.curfew)`.
Then re-arm the timer at the nearest pending moment across sessions.

Public: `setCurfew(_:forSessionID:)`, `lift(sessionID:)`, `noteInterruptOutcome(sessionID:receipt:)`,
`refreshAfterClockChange()`, `evaluateAll()`, `state(for:)`, `canTellWorking(sessionID:)`.
On launch nothing is typed (every session is dormant); a hold that began while shut materializes
dated T, a wind-down whose window passed fails with *"Threading was not running"*.

## Hold integration — one change per consumer

| Consumer | Change | Wording |
|---|---|---|
| Outbox drain `ConversationOutboxCoordination.swift:86-92` | `guard !CurfewHoldPolicy.isHeld(sessionID:) \|\| next.origin == .curfewWindDown`; observe `CurfewDidChange` → `flushOutboxIfReady` + `refreshLimitEscapeStrip` | strip states it |
| Scheduled send `SessionCoordinator+ScheduledMessages.swift` after `standAsideForCustomLimit` | `standAsideForCurfew`: skip `.curfewWindDown`; held target with `endsAt` → `replace(rescheduled(to: endsAt))` not counting a rearm; else `relinquish(waitingBecause:)` **without** `noteWaiting` (so `waitingRetryWindow` cannot fail it with the wrong sentence); scheduler observes `CurfewDidChange` → `evaluate()` | "Held by this session's curfew since 04:00" |
| Control plane `WorkspaceControlPlane.swift:53,298,544,574` | `Dependencies.heldByCurfew: (SessionID) -> String?`; `ControlRefusal.targetHeldByCurfew(reason:)` | `ControlRefusalWords`: "… The user set a curfew on this session; it lifts when they lift it." |
| Usage-window poke `UsageWindowPlan.swift:174,231` | `Input.quietHoursUntil: Date?` → `UsageWindowHold.quietHours(until:)`, last in the guard table | "Standing down for quiet hours until %@." |
| Limit recovery | none — its continuation is a `ScheduledMessage` and inherits the stand-aside | — |
| `SessionCoordinator.swift:55-85` | observe `CurfewInterruptRequested` → `environment.agentRuntime.conversation(for:)?.stopCurrentTurn(completion:)` → `noteInterruptOutcome`; `stopCurrentTurn` gains an optional completion | — |
| `AttentionAlerts.swift` | `case curfew` + `postCurfewGaveUp(sessionID:interrupts:)` (actionable: opens the session, strip offers Lift); withdrawn on lift | "Kept working after its curfew" |

## UI

### Presets and the shared menu
`ScheduledTimePresets.swift`: `curfewWallClock(now:calendar:locale:)` — "In an hour" (reuse
`roundedHourAhead`), "In 3 hours", "Tonight at 23:00" (suppressed once past); and
`curfewUsageResets(usage:metering:now:locale:)` — same windows as `usageResets` but
`date: resetsAt` exactly (**no `resetPadding`** — it points the wrong way for an end).

`UI/Views/CurfewMenu.swift` (new, `ScheduleMenu` shape): `Choice = at(Date) | atQuietHours(Date) |
exempt | inherit | lift | custom`; rows: wall-clock presets (`titleDetail` rule), reset presets
(subtitle), "At quiet hours (04:00)" when configured, "Exempt from quiet hours" / "Follow quiet
hours" (or "No curfew") with `isSelected` from the **resolved** answer, "Lift Curfew" when held,
"Custom time…" → `ScheduleMomentPickerViewController.present(over:title: "End this session",
confirmTitle: "Set Curfew")`. Used by the draft view, the chat chip and the sidebar fold.

### Draft view — understandable while writing a prompt
- A second `ThemedIconButton` beside the clock (`SessionComposerViewController.swift:207-231`):
  `moon.zzz`, accessibility **"End this session at a time"**, `presentsMenu = true`, id
  `composer.session-start.curfew`, same compression priority; re-point the constraints that pin
  to `scheduleButton.leadingAnchor` (L161, L188). The press always opens the menu — like the clock,
  a refusal is a disabled row with the sentence, never a dead button.
- `curfewChip: ChipView` among the footer chips, present **only when chosen** (the
  `managedWorkspaceDeliveryChip` precedent — insert/remove, not `isHidden`): title **"Until 04:00"**,
  tooltip states the whole ladder *"Ends at 04:00 · wrap-up at 03:50 · interrupted after 04:05"*,
  click reopens the menu; `.inherit` removes it.
- `frozenPlan(in:reserving:)` (`SessionComposerScheduling.swift:163-186`) carries
  `curfew: selectedCurfew`; `adopt(_:)` restores it.
- **Armed when the session actually starts, never before**: the immediate Start path calls
  `SessionCurfewCenter.shared.setCurfew(.until(T))` after the session is created (resolve
  `.atQuietHours` to the next window start then); a scheduled start arms it in
  `startScheduledSession` right after `startSessionUnattended` (`SessionCoordinator.swift:1038`).
  The waiting placeholder row is not under curfew.
- `TerminalContainerViewController.scheduledConfiguration(_:)` (L1601-1614) appends "ends 04:00"
  so the placeholder reads *"Starts Monday 09:00 · ends 12:00"*.

### Existing sessions
- **Sidebar fold** (`ProjectSidebarSessionActions.swift`): `curfewEntry(for:)` appended in
  `sessionOptionsEntry` after `limitRecoveryEntry`; `chooseCurfew` writes nil-when-matching-inherited
  (`chooseLimitRecovery` L1194-1213 rule); `.lift` → `SessionCurfewCenter.shared.lift`. Project
  row gets "Exempt from quiet hours / Follow quiet hours" one scope out. `SessionActionMenuDefaults`:
  `curfewMenuTitle = "Curfew"`, symbol `moon.zzz`.
- **Chat chip** (`ConversationViewController.swift:451-465`, `setFooterControls` L1207):
  `curfewChip` shown only while a curfew resolves ("Until 04:00" → "Curfew since 04:00"), same
  menu; the schedule chevron stays "send later" only.
- **Strip** (`LimitEscapeStripView.swift`): `Offer.Source.curfew`, `curfewLine`, `onLiftCurfew`;
  conduct mark instead of the triangle (L188-189), button **"Lift Curfew"** (L394-409), no wait,
  no dismiss (a standing state has the lift, not a ✕), `continuePressed` routes (L427-433).
  `ConversationViewController.refreshLimitEscapeStrip` (L596-617): provider refusal > park >
  curfew. `AgentSessionViewController` (L282-304): `suggestionStore.offer ?? curfewOffer()`,
  observe `CurfewDidChange`. Gallery: held / interrupted ×2 / cannot-tell stories.
- **Row mark** (`RowConductSummary.forSession(_:in:)` L109-116): held → prepend "Held by curfew
  since 04:00" (louder first); armed one-shot → "Curfew at 04:00"; `.exempt` only when quiet hours
  apply; nothing when matching inherited. `SessionInfoPopover` gets the line through `conductLine`.

### Settings — understandable on the page
Section **"Quiet Hours & Curfews"** on the Usage Windows page
(`UsageWindowPreferencesViewController.rebuild()` L57-85, between `limitRecoverySection` and
`accountsSection`), built from `SettingsUI.section/row/fullRow/note/popUp/toggle/textField`:

1. `SettingsUI.note`: *"A curfew ends a session's spending at a time you choose — from the
   composer when you start a session, or from a session's menu. Before it, Threading asks the
   agent to wrap up; at the time it stops sending on its own; after a grace it interrupts whatever
   is still running. You keep the conversation and can continue it by hand. Quiet hours are a
   curfew every session follows daily unless it is exempt."*
2. **Send a wrap-up before the curfew** — popup Off / 5 / 10 / 15 / 30 min
3. **Interrupt a turn still running** — popup Never / At the curfew / 5 / 10 / 15 min after
4. **Wrap-up message** — full-row text field, note *"{time} is replaced by the curfew time."*
5. **Quiet hours** — toggle, subtitle *"Every session is held between these times unless it is exempt."*
6. **From** / **To** — `timePopUp(selecting:range:action:)` (L285-299) at 30-minute steps, enabled
   only while the toggle is on
6b. **If it keeps working after 3 interrupts** — popup: "Notify me" (default) / "Stop the agent",
   subtitle "Stopping keeps the conversation on screen; Resume Session brings it back." Stored as
   `CurfewPreferences.stopsAgentOnGiveUp: Bool` (decoded with a default so stored records predating
   it read as Notify)
7. `detailRow(symbol: moon.zzz, title: "Tonight")` — the live sentence the popups produce:
   *"Wrap-up at 03:50 · held from 04:00 · a turn still running at 04:05 is interrupted · lifts 08:00."*

Writes go through `CurfewSettings.shared.preferences` (read-modify-write); page observes
`CurfewSettingsDidChange` → `rebuild()`. `SettingsPages.swift:296-308` search terms: curfew,
quiet hours, wind-down, wrap-up, interrupt.

## Steps (each builds and passes `scripts/test.sh` alone)

| # | Step | Tests | Parallel |
|---|---|---|---|
| 1 | Model, defaults, `CurfewSettings`, `CurfewResolution`, `CurfewReceiptWords` | **`SessionCurfewModelTests`**: rule round-trip + unknown kind → nil; `QuietHours.window` inside/outside/midnight/spring-forward/fall-back; resolution chain; lifted quiet instance; `ResolvedCurfew` moments incl. grace nil; receipt cap | — |
| 2 | `AgentSession`/`Project` fields, `ProjectStore` setters | store tests: applied/unchanged/refused (`.until` on a project); old payload decodes; unknown rule kind decodes | 1 |
| 3 | `Purpose.curfewWindDown`, `ScheduledCurfewPlan`, `Item.origin`, `interruptSequence`, `EventLog.Category.curfew`, capability flag, events | Codable: plan without `curfew` decodes; purpose round-trips; `ConversationOutboxTests` origin default | 1, 2 |
| 4 | Presets + `CurfewMenu` | `ScheduledTimePresetsTests`: 3 hours, tonight suppressed, reset date == `resetsAt`; **`CurfewMenuTests`**: rows, checkmark reads resolved, Lift only when held | 5, 8, 12 |
| 5 | `CurfewHoldPolicy` + the consumers + refusal words | **`CurfewHoldTests`** (pure, before/at/after T, window end); `WorkspaceControlPlaneTests` via `makePlane(heldByCurfew:)` for send/resume/spawn; `UsageWindowPlan` row order; stand-aside relinquishes without `noteWaiting`, wind-down passes, held outbox drains only the wind-down | 4, 8, 12 |
| 6 | `SessionCurfewCenter`, coordinator observer, alert, `AppDelegate` start beside `SessionSnoozeCenter.shared.start()` | **`SessionCurfewCenterTests`** (`SessionSnoozeTests` fixture: private `ProjectStore`, `ScheduledMessageStore(directory:)`, scratch `CurfewSettings`, injected clock/activity/performers/centres): wind-down only with a turn in flight; skipped-idle; failed past window; `.held` at T; native interrupt once; terminal Escape only with capability + `reportsOwnTurns`; re-interrupt only unwatched, spacing, stops at 3 with alert; lift scoping; relaunch materializes without typing; **wake on the workspace centre**; zone change re-resolves quiet hours; `start()` refuses under XCTest with defaults | — |
| 7 | Strip source, both hosts, gallery | `LimitEscapeStripTests`: conduct mark, "Lift Curfew", no wait/dismiss, routes to `onLiftCurfew`, spoken label; gallery render light/dark; theme-switch case | 9, 10, 11 |
| 8 | Row conduct + popover | `RowConductSummaryTests`: held first, armed, exempt only under quiet hours, nothing when inherited | 4, 5, 12 |
| 9 | Sidebar fold (session + project) | `SessionRowActionsTests`: fold present, nil-when-inherited writer, Lift when held | 7, 10, 11 |
| 10 | Chat chip | footer tests: absent without curfew, "Until 04:00" with one, reopens menu | 7, 9, 11 |
| 11 | Draft button, chip, frozen plan, arming (immediate + fire time), placeholder line | composer tests: button label, chip only when chosen, `frozenPlan`/`adopt`; `ComposerWindowFitTests`; a fired plan arms the reserved session and a waiting one is not held; `ScheduledSessionPlaceholderRenderTests` | 7, 9, 10 |
| 12 | Settings section + search terms | `UsageWindowSettingsRenderTests`: section present, popups select stored values, From/To disabled while off, PNGs light/dark at both widths | 4, 5, 8 |
| 13 | Strings (`Localizable.xcstrings` + sv, appended in insertion order), `docs/architecture/curfew.md` + CLAUDE.md row, USER_GUIDE.md ("Curfew" under Sessions near *Limit recovery*, a line under *Settings ▸ Usage Windows*), `CUSTOMIZATION_SURFACE_AUDIT.md` | localization lint via an ordinary build | after all |

Critical path: 1 → 2 → 3 → {4, 5, 8, 12} → 6 → {7, 9, 10, 11} → 13. Steps 6 and 11 are the large ones.

## Verification

- `scripts/test.sh` after every step; `scripts/test.sh all` before committing.
- An ordinary `xcodebuild` runs the boundary lints: no `ConversationViewController` in new Core
  files, no `kind ==`, `SessionCoordinator*` via `environment.*`, every `Logger` interpolation with
  `privacy:`, L10n keys with `sv`.
- **Measure Escape against the installed CLIs before shipping** (the repo's rule for every
  keystroke feature): a running Claude Code turn → `[Request interrupted by user]` settles the
  tracker; a Codex turn → `turn_aborted`. Confirm a second Escape is never sent at an idle prompt
  (it opens Claude's rewind chooser) — the spacing and the in-flight gate are what prevent it.
- End to end, in the built app: set a curfew "In an hour" on a native chat with a `/loop`
  running, shorten the margins in Settings, watch the strip move through *wrap-up sent* → *held*
  → *interrupted*, confirm the outbox holds, `send_to_session` from another chat is refused with
  the curfew sentence, and **Lift Curfew** releases it. Repeat on a terminal session; confirm the
  wrap-up is typed between turns after the Escape. Quit Threading across T, relaunch, confirm the
  receipts say so and nothing was typed.
- Renders: gallery stories for the three strip states and the Settings section PNGs reviewed in
  both appearances.

## Risks and open points

1. **Escape per CLI** — see Verification; Escape on a permission prompt denies it (also ends the
   turn — acceptable as "interrupt"), stated in the doc.
2. **Wind-down on a native transport that cannot queue** — falls to `.waiting` like a terminal;
   stated honestly.
3. **Wind-down vs. the user's own limit** — exempt from the curfew stand-aside only;
   `standAsideForCustomLimit` still applies (default: no exemption; note in the doc).
4. **Quiet hours edits while held** — a moved start is a new instance; a held session may be
   released if moved later. Journalled; acceptable.
5. **Remote-controlled terminal** — `TerminalSession.insertText` already refuses while a remote
   participant holds input; the attempt is counted and journalled as "input held remotely".
6. **`AttentionAlert` is `CaseIterable`** — the new case touches every switch (compiler lists them).
7. **Follow-ups**: iPhone summary field + `curfew` route; project-specific quiet windows;
   per-session wrap-up text; `CustomLimitTier.enforce` — run this same ladder while one of the
   user's own account rules holds (the "stop at 70% even if looping" case), reusing the engine's
   reason seam; a `UserPromptSubmit` enforcement hook that blocks a loop's re-submission in-band
   at zero spend (Claude-first, measured — a blocked prompt must not strand the tracker);
   per-session ceilings stay with `usage-aware-accounts.md` §C.
