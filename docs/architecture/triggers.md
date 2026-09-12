# Triggers

Triggers are Threading's provider-neutral `listen → match → start an agent` feature. A source
reports bounded facts; an immutable trigger revision supplies the project, instructions and
authority. Event content is never executable configuration.

## Ownership

The app is the sole owner of `triggers.db` and of every session launch. `TriggerStore` keeps
source installations, trigger definitions, immutable revisions, accepted events and run
receipts in its own SQLite database. Event and run creation commit atomically, with uniqueness at
both the source-event key and `(trigger, revision, event)` run key.

`threading-triggerd` is a separate per-user launch agent. It owns only source polling, provider
cursors, backoff, a bounded file inbox and health receipts. It never opens `triggers.db`, matches
rules, chooses projects, reads repository files or starts an agent itself. The app publishes a
credential-free source configuration, the daemon writes normalized `TriggerEvent` envelopes,
and a distributed notification asks the app to drain them. If Threading is not running, the
daemon opens it without activation and repeats the notification.

The first adapter is Sonda's read-only review-required feed. Its stable case ID and review cycle
become the event identity and revision; its cursor is committed only after every returned event
has been written to the inbox. The model and store do not know Sonda semantics, and unsupported
`sourceType` values are deliberately left out of daemon configuration until an adapter exists.

## Authority

Activation names one exact immutable `TriggerRevision`. Agents may inspect sources and triggers,
create disabled drafts, and propose that revision for activation through the built-in Trigger MCP
tools. Only the host approval sheet activates it. Credentials are entered only in the Sources UI,
stored in Keychain, and never returned through MCP or placed in prompts.

Every run has two possible stages:

1. Assessment starts in the provider's native conversation surface with Plan/read-only
   permission. The opening prompt separates host instructions from untrusted event evidence.
2. A `straightforwardFix` result may start a second turn only when the activated revision already
   grants `assessThenFix`. Threading changes that same session to local edit permission, verifies
   an existing checkout is clean or uses an isolated managed worktree, and sends a host-authored
   fix prompt.

The grant ends at local edits and tests. Trigger runs cannot push, deploy, open a change request,
write back to the source or acquire a source resource. Those remain separate future authorities.
The configured maximum runtime is armed as the session's curfew across both stages.

## Queue and recovery

`TriggerEngine` performs typed AND matching and decides whether a new run is immediately
`received` or held by quiet hours/concurrency. Pre-launch holds are re-evaluated at startup, after
settlement, after a source resumes, and once per minute. Only queued runs with no session or start
time may return through the opening dispatch. The assessment-to-fix handoff has its own durable
`fixQueued` state, remains active for concurrency accounting, and is resumed at that boundary after
a restart. A stage interrupted while its prompt may already have been delivered settles for
attention instead of guessing, duplicating work, or accidentally restarting assessment.

At launch, `TriggerRuntime` republishes daemon configuration, posts already-received dispatches,
then drains the daemon inbox. Later inbox notifications ingest, acknowledge and dispatch in that
order. Redelivery is safe because acceptance is durable and idempotent. One source failure cannot
stop polling another; per-source status files provide healthy, backoff and authentication-needed
receipts to the UI.

## Surfaces

The sidebar's **Triggers** destination has three pages:

- **Triggers** shows drafts, the active event kind and execution authority, and provides exact
  activation plus pause/resume controls.
- **Activity** shows durable run state and bounded results even when no session started.
- **Sources** connects the first adapter, overlays daemon health, and pauses or resumes polling.

This destination and its approval sheets are host-only security surfaces. Extensions may observe
only future explicitly published facts; they cannot replace credentials, authority or run-state
presentation. The seven built-in MCP tools are the supported agent automation seam: three lists,
disabled draft creation, host-approved activation, and session-bound assessment/final reporting.

Questions, phone replies and images do not need a Trigger transport. A Trigger launches an
ordinary session, so existing attention notifications, authenticated remote conversation routing
and session-owned attachments remain the continuation path. Quick push replies and source
resource fetching are later additions, not implicit v1 authority.

## Files

- `Models/TriggerModels.swift` — identities, typed events, revisions and run states
- `Core/Triggers/TriggerStore.swift` — SQLite ownership and durable idempotence
- `Core/Triggers/TriggerEngine.swift` — matching, holds, recovery and app dispatch
- `Core/Triggers/TriggerDaemonBridge.swift` — config/inbox/status/Keychain/launch-agent seams
- `Targets/TriggerDaemon/` — the polling helper and launch-agent property list
- `UI/Triggers/TriggerCenterViewController.swift` — the host-owned destination
- `UI/Windows/SessionCoordinator+Triggers.swift` — two-stage ordinary-session lifecycle
- `UI/Windows/MainWindowTriggerTools.swift` — built-in MCP application actions

The cross-process Keychain access group is a signed-Release contract. Unsigned/ad-hoc Debug builds
can compile and render the feature but cannot prove ServiceManagement registration or credential
sharing; validate those two behaviors on a signed build.

**A locally auto-installed build is not that build either.** `keychain-access-groups` is
profile-backed, and the auto-installer deliberately names no provisioning profile, so it derives
the app's and the daemon's entitlement files with the group removed — the build the developer runs
all day therefore cannot read a source credential across the process boundary, and
`TriggerSourceCredentialStore` asks for a group it does not have. Credential sharing is provable
only on a profile-signed release from `scripts/release.sh`. The release path carries the group
without any change: the Developer ID profile's entitlements dict already lists it. See
[`releasing.md`](releasing.md#keeping-applications-on-master) — the first version of
this entitlement broke the auto-install loop for three days because the derivation matched only
`com.apple.developer.*`.
