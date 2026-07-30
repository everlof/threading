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

## The Local Network permission is not in play, and the check is the point

The obvious reading of Remote Access — a listener, a phone on the same Wi-Fi — says the app
needs `NSLocalNetworkUsageDescription`. It does not, and adding the string would have documented
a permission the app never requests.

All three of Threading's listeners set `requiredLocalEndpoint` to `127.0.0.1`:
`RemoteAccessServer`, `MCPServer`, and `ExtensionHostService`. Loopback is exempt from the
local-network gate, and the phone arrives over an **outbound** relay connection rather than
across the LAN. The `0.0.0.0` handling in `ListeningPort.swift` is about detecting what a
*user's* dev server binds to — a feature, not one of our own binds.

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

## The page is an inventory, not a checklist

Accessibility and Screen Recording read "Not allowed" on any machine that has never installed a
capturing or input-driving companion, and that is the correct resting state. Green marks a live
grant; nothing marks the absence of one. A red dot beside Screen Recording would be reporting a
problem that does not exist, and would push a user toward granting something no installed
component wants.

Status is carried by a word, not by the dot — colour alone fails the accessibility rule in
`docs/THEME_BOUNDARY.md`, and each row states title and status together to VoiceOver.
