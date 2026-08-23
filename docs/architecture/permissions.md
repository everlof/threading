# Permissions & Entitlements

What the OS grants Threading, how each grant is actually obtained, and the three things that were
assumed wrong before they were checked.

## The shape

The app is **unsandboxed** with the **Hardened Runtime on**. The sandbox is not a choice that
can be revisited: a PTY cannot be opened, and a login shell cannot be launched, from inside it.

`Sources/Threading/Resources/Threading.entitlements` is the shipped set. `Threading-Debug.entitlements`
is the Debug configuration's. The Debug build is ad-hoc signed when no development team is set,
so it must not carry restricted `com.apple.developer.*` entitlements: static `codesign --verify`
accepts that combination, but taskgated kills it before `main`.

| Entitlement | Why | Configurations |
|---|---|---|
| `com.apple.security.cs.disable-library-validation` | Extension bundles are signed by other identities | both |
| `com.apple.security.cs.allow-unsigned-executable-memory` | JIT for the in-process WASM extension runtime | both |
| `com.apple.security.get-task-allow` | Lets a debugger attach | **Debug only** |

## get-task-allow is decided twice, and only one of them is this file

Both configurations pointed at one entitlements file, so the shipped set requested
`get-task-allow` — the entitlement that lets any process attach a debugger to an app holding
GitHub tokens and model API keys in the Keychain. Splitting the file removes the *request*.

That is only half of it. Xcode also **injects** `get-task-allow` whenever it signs with an
Apple Development certificate, which is what automatic signing picks for a `build` action.
Verified by inspecting
`Build/Intermediates.noindex/Threading.build/Release/Threading.build/Threading.app.xcent` — the
key is present there even though the entitlements file no longer contains it.

So a locally built `-configuration Release` is development-signed and still carries the key. It
is not a shipping artefact. The distributable comes from `scripts/release.sh`, which archives
and exports with `Developer ID Application`; that export has the hardened runtime, a secure
timestamp, and no `get-task-allow`, and the script fails rather than hand a bundle to
`notarytool` that lacks any of the three. See
[`releasing.md`](releasing.md) for why distribution signing cannot live in the build settings.

Do not "fix" a local Release build by putting the key back in the entitlements file.

## A restricted entitlement is not a setting, and one was tried

The entitlements above are *unrestricted*: any signature may carry them. Most
`com.apple.developer.*` keys are **restricted** — they must be backed by a provisioning
profile, or AMFI refuses to spawn the process. This is not a launch-time warning but a kill:
`amfid` logs "The file is adhoc signed but contains restricted entitlements" and the app
never runs.

Measured with `com.apple.developer.usernotifications.communication` (July 2026, macOS 26),
wanted so attention banners could wear the project's icon in place of the app icon. Three
walls, each verified: a dev build carrying the key dies at spawn as above; without the key, a
properly signed probe's `INSendMessageIntent` rewrite posts without error and the system
draws the generic icon anyway; and Apple issues the capability to iOS-family targets only, so
neither our Developer ID export nor a macOS development profile can ever hold it. The
supported remainder — the icon as a banner *attachment* — is what shipped; see
[`session-activity.md`](session-activity.md).

## TCC attributes a child process to the responsible parent

This is the load-bearing fact about this app's permissions, and the reason the Privacy page
exists at all.

macOS attributes file access by a directly spawned, supervised child to the app that spawned it.
Threading launches the agent CLIs, so a file Claude or Codex reads is approved against *Threading's*
grant, and the prompt names Threading. The same rule is what makes companion executables work:
`ExtensionCompanionSystemPermissions.swift` requests Screen Recording and Accessibility from the
host rather than letting the child attempt an unpromptable request, and its error copy names the
System Settings entry the user must actually approve.

The consequence for the Info.plist: `NSDesktopFolderUsageDescription`,
`NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`,
`NSRemovableVolumesUsageDescription` and `NSNetworkVolumesUsageDescription` are the only place
the user is told *why*, and they apply to unsandboxed apps too — the file dialog does not excuse
them, because the process that trips the gate later is the agent, not the open panel.

## The Local Network permission is in play, for one reason: Bonjour

Threading's own listeners never needed it. `MCPServer` and `ExtensionHostService` set
`requiredLocalEndpoint` to `127.0.0.1` and bind nothing else; `RemoteAccessServer` binds loopback
the same way and, for each way in the owner switched on, one listener per routable address, each
pinned to one address and never `0.0.0.0`. Listening for and accepting incoming TCP does not
require Local Network access (Apple's TN3179 table), which is why the LAN door worked before
discovery existed. The `0.0.0.0` handling in `ListeningPort.swift` is about detecting what a
*user's* dev server binds to, a feature and not one of our own binds.

What does require it is **advertising**: registering the `_threading._tcp` service that lets a
phone find a moved Mac is a Bonjour operation, and every Bonjour operation needs the privilege.
Measured on macOS 26 (see `docs/REMOTE_ACCESS.md`, Discovery): the same binary registers when
run from a terminal (exempt) and silently registers nothing as a launchd agent (not exempt), with
no alert shown. So `Sources/Threading/Resources/Info.plist` carries `NSLocalNetworkUsageDescription`
and `NSBonjourServices` for the Mac target, the mobile target carries the same pair (the array
through its own `Info.plist` beside the folder), and the phone additionally needs the permission
for unicast to a same-subnet private address, which iOS gates on the same prompt. Denial on the
Mac means the announcement is withdrawn and the phone falls back to the advertised address list;
denial on the phone is a named failure state with the Settings deep link.

**The attribution rule still applies to children.** An agent that curls a LAN address, resolves a
`.local` name, or starts a dev server the network reaches trips the gate as a child of Threading,
and macOS names the parent. It is not forecast: unlike `screencapture` there is no command that
means it (any `curl` might), and macOS 13 and 14 have no Local Network list for a status row to
point at.

## Reporting a grant must not cost a prompt

`SystemPrivacyStatusReader` reads Accessibility with `AXIsProcessTrusted()` — the option-free
call, never `AXIsProcessTrustedWithOptions` with the prompt flag — and Screen Recording with
`CGPreflightScreenCaptureAccess()`. Both are non-prompting by construction. Notification
settings come from `getNotificationSettings`, which also does not prompt; only
`requestAuthorization` does, and that stays in `AttentionAlerts`.

The folder grant has no such API. Rather than probe it — which would put a system prompt on
screen because someone opened a settings page — `SystemPrivacyStatus.askedWhenNeeded` says so.
That case exists for this reason and is not a fallback for "unknown".

The system calls are injected into the reader, following
`SystemExtensionCompanionPermissionAuthorizer`, so a test asserts on stated inputs rather than
on whatever the developer's machine happens to have approved.

`immediateStatus(of:)` is the same readings without the callback, and returns nil for the two
that cannot answer synchronously — the folder grant, which has no non-prompting API at all, and
notifications, which has one but only through `getNotificationSettings`. It exists because the
forecast below runs inside a permission decision, which is holding a CLI blocked while it thinks.

## The page has to keep reading, because nothing tells it

`refresh()` ran on `loadView` and on `viewWillAppear`, and neither of those is when the answer
changes. macOS posts nothing when a TCC grant is flipped, and the page *invites* the flip: the
row reads "You allow Threading in System Settings", the button opens that exact pane, and coming
back left the word still saying "Not allowed" until the page was navigated away from and back —
`viewWillAppear` does not fire for a page that never left.

So `viewDidAppear` starts watching and `viewWillDisappear` stops, and watching is two things
because one does not cover the other:

- `NSApplication.didBecomeActiveNotification` answers the common path immediately. A poll alone
  would leave the stale word up for an interval at exactly the moment the user came back to read
  the new one.
- A 3-second poll covers the rest. A TCC dialog is put up by another process, so an approval
  given to one an *agent* raised can land without Threading ever having resigned active.

Both are torn down together — a settings page is cached and kept alive after being navigated
away from (`TerminalContainerViewController.showSettingsPage`), so a timer left running is one
that runs for the rest of the app's life. `refreshIfVisible` guards on `view.window != nil`
rather than `isVisible`, because every test in this target builds an *unshown* window.

The page also only writes a row whose answer has changed. Rewriting four identical labels twenty
times a minute re-announces each one to VoiceOver for nothing.

## A prompt the user did not ask for, from an app that is not doing the thing

The most-reported surprise in this app is not on the Privacy page at all. An agent runs
`screencapture`, and because of the attribution rule above macOS puts up **"Threading.app would
like to record this computer's screen and audio."** The dialog names the wrong program, does not
say which of six open sessions caused it, and does not say what it was trying to do.

Threading cannot intercept a TCC prompt — it is raised by another process, after the child has
already made the call. The only place to explain it is *before* the command runs, which is where
`PermissionBroker` is already standing with every tool call held open by `PreToolUse`.

`SystemGrantForecast` reads the command and names the grant it is about to need.
`PermissionBroker.decide` consults it **ahead of every other rule, including the modes that
promise not to interrupt**: no mode Threading offers can promise macOS stays quiet, so none of
them is a reason to let that dialog arrive unexplained. `MainWindowPermissions` presents the
sheet — a window sheet rather than an inline card, because the grant belongs to the application
and the dialog it is warning about is itself application-modal.

Four rules keep it from becoming the nuisance it is meant to remove:

- **Only grants that can be read without prompting.** Screen Recording and Accessibility are
  forecast; Files & Folders is not, and its absence from `SystemGrantForecast` is deliberate. A
  folder forecast could only be a guess, and a wrong guess is a card in front of a grant given
  two years ago — the same unearned interruption, wearing our badge instead of the system's.
- **Only when the grant is missing.** The status read is what turns a forecast into a certainty.
- **Once per grant per run.** `briefedGrants` matters in exactly one case: the user let the
  command run and then pressed Deny on the *system* dialog. macOS remembers that and never asks
  again, so without the set the next `screencapture` would be briefed forever for a prompt that
  can no longer appear. Approving at the system prompt needs no bookkeeping — the status read
  then says `.allowed`. A *declined* briefing is not recorded, because the command never ran and
  so macOS was never asked.
- **Not in `dontAsk`.** Approving a briefing *is* the tool's approval — the sheet already shows
  the command, the session and the agent, which is strictly more than the ordinary card, and a
  second sheet behind the first is how people learn to click through both. That makes the mode
  matter: briefing a `dontAsk` session would turn the one mode that promises to refuse rather
  than interrupt into an allow. `briefingApplies(in:)` is pure so the matrix is testable without
  a store or a sheet.

The matching is naive on purpose, the way `ShellCommandPolicy`'s is — segments split at
operators, wrappers like `sudo` stepped over, the executable's directory stripped — but it is
*not* a security decision, and being wrong costs one unnecessary card or one unexplained prompt.
`osascript` is the one case read further in: it is how an agent inspects a window as readily as
how it clicks a button, and only the second needs Accessibility. Driving System Events without
one of those verbs asks macOS for **Automation** instead — a different gate, with no readable
status, and so not one this forecasts.

Terminal sessions are outside all of this. `brokersPermissions` is false for them
(`AgentLauncher`), so there is no `PreToolUse` hook and no call to see coming; a terminal agent's
system prompt still arrives the way it always did.

A brokered session whose *app* has gone is refused a step earlier, in the hook rather than in the
broker: the generated `PreToolUse` command falls through to a typed deny
(`MCPDefaults.hookBrokerCommand`) so an agent still running with Threading closed is told why in
words instead of being blocked in silence. The two layers and why they stay separate are in
[`native-conversations.md`](native-conversations.md).

## A manager may answer one exact child request, not set child policy

A user-appointed manager has to be able to clear the condition an attention notice reports. A
cross-session message cannot do that: native-chat input queues behind the permission card, so
asking the blocked child to answer itself leaves both sessions waiting. The manager-only
`respond_to_permission` tool therefore has two explicit phases over the existing permission-card
boundary:

1. With `session_id` only it returns the active card's provider-neutral evidence and opaque
   request id. This is the same byte-bounded projection a paired client receives; raw provider
   arguments do not cross into the control plane, and an oversized diff carries `canDecide =
   false` with a local-review reason.
2. With that exact `request_id` and `allow` or `deny`, it settles only that card. There is no
   manager form of **Allow for Session**, and the manager cannot answer its own card.

`WorkspaceControlPlane` re-reads the durable grant, scope, target, current evidence and request id
on the decision call. Revocation is therefore immediate. A card that settled or was replaced
between inspection and response refuses the stale answer rather than applying it to the new one;
the card itself repeats the exact-id and once-only gate at settlement. The execution audit records
the decision as manager-authored, with manager, target, request and decision identities. An
attention notice is only a reason to inspect—it is never evidence for an approval.

## The page is an inventory, not a checklist

Accessibility and Screen Recording read "Not allowed" on any machine that has never installed a
capturing or input-driving companion, and that is the correct resting state. Green marks a live
grant; nothing marks the absence of one. A red dot beside Screen Recording would be reporting a
problem that does not exist, and would push a user toward granting something no installed
component wants.

Status is carried by a word, not by the dot — colour alone fails the accessibility rule in
`docs/THEME_BOUNDARY.md`, and each row states title and status together to VoiceOver.
