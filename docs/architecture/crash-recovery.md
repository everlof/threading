# A Launch That Did Not Come Back

The app has three ways of knowing something went wrong before it could say so: a marker that
outlives the process, a ledger of how far each launch got, and a policy that reads the two. This
file holds all of it, plus what the app now *does* about it.

It exists because the mechanism spans six other documents and none of them owns it.
[`persistence.md`](persistence.md) keeps the ledger's file format and durability;
[`sessions.md`](sessions.md) keeps what a launch after a crash restores;
[`themes.md`](themes.md) keeps how a theme is restored; the window deferral it has to live beside
is in [`onboarding.md`](onboarding.md). Read this one before changing what a launch decides.

## The three records

**The marker** (`EventLog`) answers one question and answers it once: did the last launch come
back. It is written after the single-instance lock and removed only by the quit path, so a marker
still lying there means the process did not live long enough to quit.
`EventLog.PreviousLaunchOutcome` names the four answers, and `unclean` carries the `.ips` macOS
filed for that launch when one matched.

**The ledger** (`LaunchLedger`) answers how far each launch got: a `begin`, a line per startup
checkpoint, and an ending. Append-only JSONL over `O_APPEND` in its own directory under the
support folder. Its format, durability, tombstones and budget are `persistence.md`'s.

**The policy** (`CrashLoopPolicy`) is a pure function from that history to a typed decision. It
walks backwards from the newest launch and stops at a different build, at a launch that reached
`stable`, or at a pair outside the five-minute window. A clean quit, a logout, a reset relaunch and
an ending this build cannot name are skipped *through* rather than resetting the count: a quit
thirty seconds into a launch is not evidence that anything was fixed, and only ten interactive
minutes is.

## Opening a launch happens in two steps

The `begin` record carries the **mode**, and the mode is decided from the history the ledger
returns. One call could not do both without either deciding the mode before the history was read
or writing the record before the mode was known. So:

```
openLaunch(previousOutcome:) -> LaunchLedgerOpening    // read, tombstone, compact
        ↓ CrashLoopPolicy.decide, flags, Option, --recovery-mode
beginLaunch(opening, id:mode:)                          // append the one begin record
```

`LaunchLedgerOpening` carries its boot id and validity `fileprivate`, so it can be constructed only
inside `LaunchLedger.swift`: a `begin` cannot be appended by a caller who has not first read,
tombstoned and compacted. `beginLaunch` also requires that *this* ledger did the opening, which is
academic with one shared instance and exact once a supervisor holds a second one over the same
file. Both refusals are logged at error level — a sequencing regression otherwise leaves only the
*absence* of a record, which is what nobody notices during a live diagnosis.

Everything between the two steps reads and decides. Nothing between them writes.

## What the modes are

`LaunchModeResolver.resolve(decision:optionHeld:arguments:forceNormalOnce:)` is the whole entry
rule, pure and table-tested. Its precedence, in order, and why:

1. `--recovery-mode` on the command line.
2. Option held at launch (`NSEvent.modifierFlags`, read once — at
   `applicationDidFinishLaunching` no key event has been delivered, and the class property needs
   no accessibility grant).
3. The `forceNormalNextLaunch` one-shot.
4. `recommendRecoveryMode` / `recommendStoppingAutomaticWork`.
5. Normal.

The two explicit requests come first because somebody is standing there asking. **The one-shot
beating the crash-loop decision is the load-bearing one**: without it, the decision that put the
user into recovery would immediately overrule the button they pressed to leave it, and "Try Normal
Launch Once" would be inert. The one-shot is spent *before* the resolver is asked, whichever branch
wins, so one that was outranked is still one-shot.

Both manual paths work when the ledger cannot be read at all. That is most of why they exist: a
damaged or newer-format history stands the policy down, and a mode somebody asks for out loud must
not depend on a file being parseable.

`recommendStoppingAutomaticWork` enters **the same mode** with a different reason. The only thing
stronger than recovery is to start less, and recovery already starts nothing; a third mode would be
one nobody tested, and `CrashLoopPolicy` reads `launch.mode == .recovery` on a two-valued enum.
What changes is the sentence on screen and the demotion of the leading offer.

## What a recovery launch starts

`LaunchPlan` is the answer, built once and read at each step, so
`applicationDidFinishLaunching` names the reason it is skipping rather than restating the mode
twenty times — and so the whole rule is one table a test asserts without an application, a window
or a store.

| Still runs | Why |
|---|---|
| The single-instance lock, the marker, the ledger, the policy | Recovery owns the state like any other launch |
| `OrphanedAgentChildSweep` | It kills leftovers, which is recovery-aligned, and a leftover child holding a PTY is a plausible cause |
| `MetricKitDiagnostics`, `MainThreadStallMonitor` | Pure observation, and this is when it matters most |
| `AppThemeRefresh`'s observers, `AppIconPresenter` | Cheap; a recovery screen that ignores Increase Contrast is worse for its reader, and under System the icon resolves to the shipped one with no special case |
| The menu bar | Gated by `RecoveryModeCommandPolicy` |
| The legacy Application Support adoption | **Weighed, not refused** — see below |
| Sparkle | Unchanged: `AppUpdater` is lazily built on the first Help-menu validation, and a new build is a legitimate fix for a crash loop |

| Skipped | Why |
|---|---|
| Extension appearance contributions, the host service, enabled packages, the three MCP/identity slots | Recovery starts no extensions; an unfilled slot means every component draws its own answer |
| `AttentionAlertCenter` | It can raise a permission dialog, and nothing here can produce an alert to justify one |
| `AgentWorkloadMonitor`, `LimitRecoveryCoordinator` | They watch live sessions; there are none |
| `cleanupOrphanedHistoryFiles`, `clearLegacySessionState` | Both delete |
| `ProjectIconDiscovery`, `CheckoutBranchFollower`, `SessionNaming.backfillLegacyNames` | All three write into the store or the support directory |
| `AccountUsageMenu.prefetch`, `AccountEmailProbe`, `ProjectStatsService` | Subprocesses and network for information nothing here shows |
| `UsageWindowPoker` | It starts a real agent turn on a schedule, which is the clearest "automatic work" in the launch |
| `RemoteAccessCoordinator`, `RemoteWorkspaceBridge` | A tunnel child and a socket, plus the seam a phone drives the window through |
| `ArtifactScanService` | A disk survey |
| The MCP listener, its handler, the permission presenter, `HookLifecycleRelay` | No session will ever read `--mcp-config`. Skipping the listener also means `restoreSelectedSessionIfReady` never runs, so no restoration and neither scheduled-message service starts. That gate carries its own `plan.restoresWorkspace` guard anyway, because it is where a future third caller would arrive |
| The onboarding walkthrough | Recovery wins over a first launch that crash-loops; the completion flag is untouched, so it returns next launch |
| The stability timer | `stable` is a claim that the app works, and a launch that started nothing has not made it. Arming it would mean ten minutes in recovery erases the count that put the user there |
| `ProjectStore` writes | Seeded at construction, because `load()` takes a write of its own |

**The migration is weighed rather than refused.** Skipping the pre-rename adoption would open on an
empty sidebar, which reads as data loss and is the worst possible message on a crash screen — but
it is also the one part of a launch that moves someone's database around. So the ledger decides: a
counted launch that recorded no checkpoint at all never reached `migrationDone`, which is the one
shape of evidence that makes the adoption itself the suspect. The checkpoint is recorded either
way, with a detail saying which happened.

## What a recovery launch does not write

Two records are load-bearing here and both are left exactly as found.

**The running-sessions record.** The quit path skips `saveRunningSessionIDs` in recovery. Nothing
was running, so the list it would write is empty — and writing an empty list over what the last
clean quit recorded is how a user who dropped into recovery to look at something loses the sessions
the *next* normal launch was going to bring back. It is not consumed here either, because the read
hangs off the MCP listener's callback. Leaving it alone at both ends is what preserves it end to
end.

**The theme.** `AppThemeLibrary.restore(_:)` pins System under `.recovery`, in memory. Nothing in
`restore` writes, today or after — the write lives in `apply`, which records even a pick that
changes nothing on screen — so "recovery cannot re-persist the theme" is bought by taking that path
and never this one. System rather than "the stored choice if it happens to be stock": a stock theme
carrying a `WindowChromeStyle` opts the window into the app-drawn frame, which is a great deal of
launch-time machinery and a plausible place to die.

**The Appearance page therefore selects the stored choice, not what is in force.** That is the trap
this decision exists to avoid: with the ring on System, clicking the entry that already looks
selected would record System over the user's theme. A pick made deliberately on that page still
records — what recovery forbids is the *launch* writing a theme nobody chose — and a note under the
card says which theme is saved.

## The one-shot flags

`Launch/launch-flags.json`, beside the ledger. Two flags, both one-shot:
`forceNormalNextLaunch` and `disableExtensionsNextLaunch`.

**A file, not `PreferenceStore`.** The onboarding flag's rule is about a preference set on a
settings page with the app running normally; these are written immediately before the prepared
relauncher commits and deliberately leaves without the quit path every store hangs its final save
on. `UserDefaults` is asynchronous to disk, `cfprefsd` holds the domain, and
`synchronize()` is deprecated. The file also has to survive Reset Settings while being taken by
Reset Everything, which a file under `Launch/` does by construction — and it inherits that
directory's hosted-test redirection, so a test cannot arm the developer's own next launch.

The helper is started *before* the one-shot is armed and waits behind a private commit pipe. A
launch failure leaves this process alive and reports the error; a helper that dies before commit
causes the flag to be disarmed again. Thus a failed button press cannot make some later ordinary
launch unexpectedly consume “Try Normal Launch Once.”

**Consumption rewrites rather than deletes**, leaving both booleans explicitly false plus
`consumedByLaunch`. There is no "cleared versus never set" question to answer here; what the
positive record buys is a support report that can say a forced-normal launch was armed by one
launch and spent by another, which is the whole "and then *that* one crashed too" story.

**A clear that fails means the flag is not honoured.** A one-shot that cannot be cleared is a
permanent setting, and a permanent "always launch normally" is the crash-loop protection switched
off with nothing on screen to say so. Failing this way costs one more crash and one more press.

The extensions flag **never touches `enabledIdentifiers`**. That is what makes "for the next launch
only" true by construction rather than by a promise: no extension is disabled, so there is no state
for a later launch to inherit. The next normal launch that honours it puts a band in the pane
saying so, because an app whose extensions have silently stopped appearing is indistinguishable
from one that lost them.

## If the forced-normal launch also crashes

Its `begin` says `mode: normal`, because it was. The policy counts it as an ordinary consecutive
unexpected exit — two crashes plus this one is three — and answers `recommendRecoveryMode`, **not**
`recommendStoppingAutomaticWork`, since the newest counted launch was not the recovery one. The
recovery launch in between ended `intentional(.recoveryRelaunch)` and is skipped transparently. The
flag is spent, so the app returns to recovery rather than looping through normal launches.

`LaunchRestorationPlan` treats that exit reason as **holding the workspace back**, which is the
opposite of what it does for `.reset`. Both are deliberate restarts; the difference is that the
reason for this one is that the app has been dying, so the launch comes up normally with the
workspace one press away rather than reopening, under the user, whatever took it down. This is why
`IntentionalExitReason` is an enum and not a `Bool`.

## The surface

`RecoveryModeView`, in `UI/Views` and composed from `UI/Design` — not added to it. A component
under `UI/Design` owes an interactive Component Gallery story, and rightly: that directory is
vocabulary a second pane repeats. This is one screen, in one place, under one condition, which is
`SessionPlaceholderView`'s position exactly.

It lives **inside the main window**, in the terminal pane. `applicationShouldTerminateAfterLastWindowClosed`
answers true, so a window of its own would recreate the trap onboarding's completion order exists to
avoid; the main window is always built here, and only its `showWindow` is gated. Living in the pane
also keeps the sidebar beside it, which is the point — the first thing somebody in a crash loop
wants is evidence that their projects are still there.

A `PaneNoticeView` band with **no dismissal** sits above it. That is the most standing condition
there is: the only thing that ends it is a relaunch, and without the band the surface would be a
screen the user could navigate away from and never get back.

The screen says why it came up (one sentence per reason), how far the launch that died got (the
checkpoint, in words — the raw case name is a fact about this code, not copy), and offers, in
order: **Try Normal Launch Once** · **Continue in Recovery Mode** · Reveal Crash Report when there
is one · then, under a rule, **Disable Extensions for Next Launch** · **Reset Window Layout** ·
**Create Support Report** · **Move App Data Aside**. Every offer maps to a primitive that already
existed; none required a new subsystem.

**Cut: a support *bundle*.** A zip of journals, ledger and `.ips` files is a new subsystem with its
own redaction question — the journals hold prompts, commands and paths — and getting redaction
wrong in a file people email is the worst place to be quick. The existing share-safe support report
already carries the crash-loop decision, the ledger read, MetricKit payloads and the privacy
grants.

## What the pane does with a click

Recovery lists and selects but opens nothing: a row that could not be clicked would be a list
pretending to be a picture, so the pane says so in words instead. The composer is diverted to the
surface, because a form whose one button starts a session is worse than the screen explaining why.

That is the *visible* refusal. The load-bearing one is at each surface's own start —
`AgentSessionViewController.launch`, `ConversationViewController.launch`,
`ProjectTerminalViewController.startIfNeeded`, `ShellDrawerViewController.startIfNeeded` — which is
the last line before a process exists and the one line every other route crosses: a remote resume,
a scheduled send, a relaunch, an MCP tool. A route recovery did not anticipate stops there.

`RecoveryModeCommandPolicy` is asked only about `AppCommand`s. The platform's own group is allowed
wholesale rather than enumerated, because a recovery mode that could ever disable Quit or Copy is a
worse failure than any it is trying to contain; the menu bar's non-command items are untouched by
construction. What survives of ours: the sidebar toggle and its three arrangement switches, and
Check for Updates.

## The checkpoint that is not readiness

`recoverySurfaceShown` is recorded one run-loop turn after the surface is in the window, so a launch
that dies drawing its own recovery screen is distinguishable from one that died before the window —
the two are the same absence otherwise, and telling them apart is the whole reason a supervisor
would read this file.

It answers **false** to `isReadiness`. Readiness stays keyed from `firstWindowVisible` alone: this
one says which *kind* of window came up, not that one did, and readiness must have exactly one
claimant or `CrashLoopPolicy.isWithinWindow` depends on which record a reader happened to look at.
A trail carrying the recovery checkpoint without `firstWindowVisible` is a launch whose window never
proved itself, and the conservative reading of such a trail is the window-exempt one.
