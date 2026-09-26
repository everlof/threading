# Opt-in Sentry diagnostics

## Decision

Threading's macOS and iOS applications may send bounded operational diagnostics to Sentry only
after an explicit, device-local opt-in. The default is off. This is a crash, hang and performance
diagnostic channel, not product analytics: it has no stable user identity, event stream, feature
usage counters or terminal content.

The consent control is deliberately host-owned. Threading owns whether the SDK is running and
which data can leave the process; an extension may not replace or relabel that state. Turning the
control off closes the SDK immediately. A later launch does not initialize Sentry unless the
stored consent is still on. Tests never initialize it.

This is a narrow revision to the earlier rejection in
[`feature-drafts/analytics.md`](../feature-drafts/analytics.md). The broader analytics proposal
remains a draft and retains its separate consent and first-party-ingest requirements.

## Process boundary

Only the two top-level applications link and initialize `sentry-cocoa`:

- `Threading.app` owns macOS crash handling and receives structural warning/error records from
  `MacRemoteDiagnostics`.
- `ThreadingMobile.app` owns iOS crash handling and receives structural warning/error records from
  `MobileDiagnostics`.

`threading-ptyd`, Linux binaries, launch agents, extension helpers, plug-ins, the MCP bridge, the
simulator helper and the iOS widget do not link or initialize Sentry. Those processes report
bounded lifecycle outcomes to their owning app or to local support journals. Only warning and
error records observed by an owning app can reach Sentry; a hard standalone helper or Linux crash
therefore leaves termination and reconnect evidence, not a helper-native stack. A second SDK
instance would add another crash handler, cache and release identity while separating the failure
from the owning application's context. Future Linux diagnostics must follow the same owner relay
rather than adding a direct endpoint.

## Signals

The enabled channel is intentionally small:

| Signal | Policy |
|---|---|
| Native crashes and uncaught exceptions | Enabled in the owning app; stack frames retained for symbolication, exception values redacted |
| System-attributed hangs | MetricKit enabled; legacy SDK hang detector disabled |
| Performance traces | Automatic app lifecycle/UI-load instrumentation, sampled at 15% in production |
| Profiles | Trace-bound profiling, sampled at 5% in production |
| Typed remote diagnostics | Warning and error records only; fixed event name and allowlisted structural tags |
| Release-health sessions | Disabled; the channel does not emit an app-open event stream |
| Logs, metrics and breadcrumbs | Dropped |
| Network, file and Core Data spans | Disabled |
| Screenshots, view hierarchy and replay | Disabled |
| Raw MetricKit payloads | Disabled |

Debug builds sample traces and profiles at 100% so the integration can be verified before a
release. This does not override consent.

Automatic transaction names are replaced with one fixed per-platform name. Child spans are kept
only for the SDK's fixed app lifecycle, app start and UI-load operations; their descriptions,
tags and arbitrary data are removed. This keeps timing and profiling value without exporting a
screen, project, session or resource name.

## Payload boundary

Every error and transaction passes through an allowlist sanitizer. It removes users, requests,
server names, breadcrumbs, arbitrary extras, errors' textual descriptions, thread names and all
contexts except the SDK's app, OS, runtime and trace contexts. Source filenames, source context
and frame variables are removed; native image paths are reduced to their basename so dSYM
symbolication still works. Non-diagnostic messages and non-diagnostic tags are removed.

The typed diagnostic relay accepts only warning/error events, uses the generated
`RemoteDiagnosticEvent` name, and forwards only these token fields:
`kind`, `transport`, `result`, `code`, `status`, `environment`, `capability`, `surface`, `phase`,
`networkStage`, `networkProtocol`, `networkPath`, `connectionReused`, `wave`, `reason`, and
`detail`. A value must be a 1–64 byte ASCII machine token. Trace IDs, host/peer/session
pseudonyms, origins, counts, timings and all extra report fields are excluded even though some
are valid in the local support journal.

Never add prompts, commands, terminal output, paths, URLs, repository names, account/session
identifiers, screenshots, view hierarchy, raw logs or user-authored strings to this channel.
Adding a signal or field requires updating this document and the sanitizer tests first.

Sentry's project must also have server-side IP address storage disabled. Client-side
`sendDefaultPii = false` remains required but is not a substitute for that project setting.

## Release and verification gate

A shipping archive must identify its release and upload the corresponding dSYMs. CI credentials
belong in the CI secret store, never source control. The shipping contract is:

- the SDK and CI use Cocoa's semantic identity
  `<bundle-id>@<CFBundleShortVersionString>+<CFBundleVersion>` byte-for-byte;
- `scripts/release.sh --notarize` creates/finalizes that release, associates the full-history
  commit range and uploads the same archive's dSYMs plus developer source context;
- `scripts/publish_release.sh` records the deploy only after the GitHub release and Sparkle feed
  are live (`production`, `beta` or `nightly`); and
- `SENTRY_AUTH_TOKEN` comes from the release machine or GitHub Actions secret store. The release
  fails loudly if the token, CLI, dSYM or server-side processing is missing.

`scripts/sentry-release.sh` is the shared implementation for local and GitHub release lanes.
The applications use separate projects: `threading/threading-macos` for macOS and
`threading/threading-ios` for iOS. Changing the macOS slug requires updating both workflow
environments together. The iOS app uses its own bundle-derived release identity, and its future
App Store archive lane must set `SENTRY_PROJECT=threading-ios` and invoke the same prepare/deploy
sequence from the archive it uploads. No iOS archive is published by the current Mac release
workflow.

Before creating remote state, the script lists the configured organization and requires the
selected project to be visible. It rejects credentials that `sentry-cli` reports as bound to a
different organization, so an ambient token for another product cannot silently publish a
Threading release elsewhere.

A release is not verified until:

1. both app targets build and their consent surfaces render in the real product shell;
2. privacy tests prove default-off behavior and sanitizer removal;
3. one explicitly enabled debug verification event reaches the intended Threading project;
4. its component, environment and release are correct and its payload contains no excluded data;
5. a native test crash resolves to readable source frames using the uploaded dSYM; and
6. the project has IP storage disabled and a bounded alert policy.

The debug-only `THREADING_SENTRY_VERIFY=1` launch environment emits a fixed structural event after
the SDK starts. It does nothing unless the device-local preference is already enabled.
