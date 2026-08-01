# Onboarding

The first-launch walkthrough: its own window shown *instead of* the main window, four pages —
Appearance, Accounts, Conversations, Notifications — and one exit that reveals the app.

## The window comes first, the main window waits

`AppDelegate.applicationDidFinishLaunching` builds `MainWindowController` exactly as before —
every downstream consumer (`RemoteWorkspaceBridge`, the MCP handler seam, the permission
presenter, the extension host's shell-root provider) needs the controller *instance*, not a
visible window — and then decides which window to show: `OnboardingState.needsOnboarding`
swaps `showWindow(nil)` for an `OnboardingWindowController`. Nothing else in the launch
sequence moves.

**Session restore is the one gated step.** It used to run straight off the MCP listener's
start callback; restoring a session attaches a terminal, and a terminal must land in a
laid-out, on-screen view. `restoreSelectedSessionIfReady` therefore requires *both* facts —
`mcpServerHasStarted` and `!isOnboardingActive` — and whichever arrives second performs the
restore. On a true first launch it is a no-op (nothing is selected); the gate exists for the
walkthrough re-run and for upgrade paths.

**Completion order is load-bearing** (`onboardingDidFinish`): record the completion, **show
the main window, then close the walkthrough**. During first launch the walkthrough is the
app's only window and `applicationShouldTerminateAfterLastWindowClosed` answers true — closing
first would quit the app on the final click of its own setup. The same trap is why the
flow maps **Escape to Back, not close**: abandoning setup by closing the window *is* allowed
(and quits — nothing was recorded, so the walkthrough returns next launch), but not on a
reflex key. A Dock click mid-walkthrough re-fronts the walkthrough, not the hidden main
window (`applicationShouldHandleReopen`).

## The completed flag

`OnboardingState` (Core/Settings) stores an integer completion *version* in
**`PreferenceStore`**, not `UserDefaults.standard` — hosted tests build these controllers and
mark them completed, and the scratch suite is what keeps a test run from deciding what the
developer's own next launch shows (the `appThemeID` rationale).

Grandfathering is a one-time **recording**, not a standing veto: a store with projects and no
record at all belongs to someone who predates the walkthrough, so the first read writes the
record for them and answers no. From then on the record alone decides. That design is what
makes Advanced's **Clear Flag** possible — clearing writes an explicit **zero** rather than
removing the key, because a *missing* key with projects present is indistinguishable from the
upgrade case and would be silently re-grandfathered; the explicit zero is a record that says
"run again". The pure rule (`needsOnboarding(completedVersion:hasRecord:hasProjects:)`) and
the cleared-vs-never-set distinction are both held by `OnboardingStateTests`.

Settings ▸ Advanced ▸ **Welcome Tour** carries both spellings: **Show Again…** runs the
walkthrough immediately over the open main window (`AppDelegate.presentOnboarding`;
completion's `showWindow` is then a no-op, and the import page naturally offers only what is
not yet tracked), and **Clear Flag** arms the true first-launch path — deferred main window
and all — for the next launch. The row's detail line reflects the current record, which is
also the click's acknowledgement.

## Pages

Pages implement `OnboardingPage` (UI/Onboarding/OnboardingFlowViewController.swift): the flow
owns Back/Continue/skip, a page states its Continue title and whether it can be skipped, and
work done on the way forward lives in `pageWillContinue` — **skip is the same movement without
the work**, which is the entire difference between the buttons.

**Appearance** is deliberately first: every page is built from themed components under a
`ThemedWindowController`, so `AppThemeLibrary.apply` restyles the walkthrough the moment a
tile is clicked, and the rest of setup happens in the user's own taste. The grid draws every
stock theme with `ThemeSwatchImage.appSwatch` — a miniature window resolved for *that theme's*
appearance, so a dark chrome still previews the light themes light. Five columns of 104-point
swatches is a measured fit, not a preference (four of 128 clipped the first row).

**Accounts** presents `AgentAccountDiscovery`'s existing scan and adds the one check nothing
else does: `AgentCLIProbe` resolves `claude`/`codex` against the same login shell
`AgentLauncher` uses (`command -v`, the `ExternalAppLauncher.locate` shape), so the probe and
the launch cannot disagree about PATH. A missing CLI is a sentence and an install command
here, instead of `command not found` inside the first session's terminal. Each login also
carries the Accounts settings page's enable switch (`AccountPreferencesStore.setEnabled`,
same dimming, same `ProjectsDidChange` signal), so an unwanted login is dealt with where it
is first seen rather than remembered for later. The probe's "Found" answer is per-shell
truth: a machine with several installs (a native `~/.local/bin/claude` beside a stale
`/usr/local/bin` npm one) shows whichever the *login shell* resolves, because that is the one
a session will actually run.

**Conversations** runs `GlobalSessionScan` — `SessionImporter`'s direction inverted. The
project-scoped importer answers "what ran in this folder"; onboarding has no folders yet, so
the scan enumerates everything each enabled account holds and derives the folder from each
conversation's recorded `cwd`. The recorded path is authoritative; a Claude transcript
without one is skipped (the slug directory is a lossy `/`→`-` encoding). Grouping resolves
each cwd to its **worktree root** (`GitInfo.repositoryRoot`, memoized cwd→root — the
`TranscriptUsageService` lesson), so a chat in a subdirectory lands with its checkout and a
chat in a nested worktree lands with *that* worktree. Conversations whose folder no longer
exists are counted and said, not silently dropped. The list itself is **flat, newest first
across every folder** — the grouping is import bookkeeping, not something the user triages
by, so folder header rows (tried first) were dropped: a wall of checkout paths asked the
user to reason about projects before they had any. The last 48 hours
(`GlobalSessionScan.precheckWindow`) start checked; Continue creates/reuses a project per
group (`addProject` dedups by path) and adopts the checked conversations through
`ProjectStore.importSessions` — the batch exists because the single `importSession` saves and
notifies per call, and a heavy user's import would stutter through hundreds of sidebar
reloads. Because the accounts page sits before this one and can now switch logins off, the
scan result is cached against the *enabled-account set* that produced it; coming forward
after a toggle rescans (generation-guarded) instead of showing a list a disabled login fed. Adopted sessions are `.resumable` with their account handle, so resume routes
`--resume`/`codex resume` through the right `CLAUDE_CONFIG_DIR`/`CODEX_HOME` exactly as
composer-imported ones always have.

Discovery is fail-closed about completeness. Enumeration failures are carried in
`GlobalScanResult` as a bounded list plus an omitted count, and the page labels the result
incomplete before offering any empty/fresh-account conclusion. Successful conversations remain
selectable — one unreadable account does not discard the others — but a permissions or I/O
failure can never be interpreted as proof that no conversations exist.

**Notifications** shows the three `AttentionAlert` kinds as rows whose toggles are **disabled
until macOS grants permission** — visible so it is clear what could be configured, inert so
nothing pretends to be on. "Enable notifications" requests authorization with the same
options as `AttentionAlertCenter.post`, the only other caller. Skipping keeps the app's
stated position — the permission dialog appears beside the first notification with a reason
to exist — with zero changes: the page never touches `AttentionAlertCenter`. TCC posts
nothing when a grant flips, so while the page is up the status is polled on a 3-second timer
plus app activation, the `PrivacyPreferencesViewController` watcher. A denied status turns
the button into a System Settings deep link; one function draws every state so a mid-page
flip cannot leave half the controls describing the old one.

## What onboarding deliberately does not do

- It never fires a permission prompt unbidden — the notifications ask is behind an explicit
  button, and no other permission is touched (`permissions.md` still holds).
- It writes no behavioural settings besides what the user toggles on the notifications page
  after granting. Three-state settings (`defaultPermissionMode`, `claudeRemoteControl`) are
  not offered — collapsing "no opinion" into a boolean would override CLI configuration.
- It does not create a "first project" — with nothing imported, the main window opens onto
  the composer's nil-project mode (see [`sessions.md`](sessions.md), "The Composer"), which
  is the richer version of that page.
