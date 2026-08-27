# Reliability & Type Safety

The cross-cutting rules that keep a fast-moving product predictable. Read this before adding a
new persistence format, wire protocol, background queue, global service, or feature flag.
Subsystem documents still own their domain-specific decisions; this file owns how boundaries
fail.

## Dependency direction

Threading has one app target, but it must not behave like one undifferentiated module:

```
Foundation-only contracts        ThreadingRemoteKit / ThreadingExtensionKit
            ↓
Core state and policies          typed models, stores, launch and permission policy
            ↓
Application coordinators         session and agent-tool orchestration
            ↓
AppKit composition               windows, view controllers, Design components
```

The arrows describe knowledge, not necessarily Xcode targets yet. A lower layer does not reach
up to fetch a window or a concrete controller. The composition roots (`AppDelegate`,
`MainWindowController`, and dependency structs such as `AgentToolDependencies`) provide those
capabilities. The architecture lint rejects new singleton lookups from agent-command handlers;
add a narrow dependency instead.

Split a new package only when the compiler-enforced import boundary pays for its build and
maintenance cost. Wire contracts already meet that bar because two processes or products must
agree on them. Within the app, protocols and explicit dependencies are the first seam.

When one vocabulary crosses language runtimes, it has one declarative owner and generated
projections. Diagnostic events, fields, value classes, and report-source scope live in
`RemoteDiagnosticContract.json`; Swift and Worker TypeScript are generated and checked for
byte-for-byte freshness. A hand-maintained mirror is not a second authority. Runtime version skew
is explicit too: the public intake drops and counts unknown diagnostic vocabulary without storing
its values, while malformed structure and invalid known values still fail closed.

## Fail closed at every external boundary

An invalid value must not accidentally become a permissive or destructive default.

`scripts/check_failopen_defaults.py` enforces the narrowest mechanical form of that, and fails the
build on it: `Enum(rawValue: x) ?? .case` anywhere in the app, the phone app or a first-party
package. Give the type an explicit `unknown` case the way `RemoteLosslessStringToken` does, or
project it with an exhaustive `switch` that has no `default:` — the first keeps an unrecognised
value unrecognised, the second makes a new case upstream a compile error at the projection rather
than a silent downgrade to whichever case the author had in mind. A site that must keep its
fallback is allowlisted in the checker by path and enclosing declaration, with a reason that says
why an unrecognised value is safe as that case; an unreachable fallback names the invariant that
makes it unreachable, and the checker refuses both a perfunctory reason and an entry that no
longer matches a site.

- Distinguish missing, valid, unsupported-version, and corrupt persisted data. Corrupt data is
  quarantined; it is never interpreted as an empty store and overwritten.
- Decode wire envelopes into `Codable` value types. Arbitrary tool-owned JSON uses `JSONValue`,
  not `[String: Any]`, and container conversion is all-or-nothing.
- A failable or validating initializer is not a `Codable` invariant: synthesized decoding assigns
  stored properties directly. Types whose methods rely on normalized, non-empty or authority-safe
  fields implement `init(from:)` by decoding source fields and re-entering the authoritative
  initializer. Derived values are built there and omitted from the wire representation.
- Use distinct identifier wrappers and algebraic state (`ResumeState`, session lineage and
  configuration variants) where two strings or two `nil` values mean different things.
- Permission and capability lookups default to refusal. Unknown commands are not advertised or
  executed. Disabled commands are rejected at dispatch even if a stale client still calls them.
- Multi-party configuration changes need an agreement point. Persist, ask the runtime to apply,
  and roll back on rejection. If delivery makes runtime state unknowable, stop that runtime
  rather than reporting success from an ambiguous state.
- Replacements keep the last known-good tree until the new tree has moved and revalidated. If
  restoration itself fails, preserve the outgoing copy at a surfaced recovery path; cleanup
  must never delete the only known-good package.
- A directory-level read failure is an error, not an empty inventory. Preserve the last known
  good snapshot and surface the failure.

Fallbacks are allowed only when they preserve the operation's safety and are visible in logs or
the UI. `try?` is appropriate for best-effort cleanup of an already-abandoned staging file; it is
not appropriate for state writes, authorization, version checks, or user-requested operations.

An HTTP status is a class of failure, not its cause. Remote REST refusals carry a bounded
`RemoteErrorDTO` with a stable code; the status remains only the older-client fallback. The body
does not repeat localized prose, request data, paths, account identities or prompts. Clients map
known codes to localized action copy, preserve unknown future strings for diagnostics, and keep
authorization/not-found codes generic where precision would disclose scope. This is the REST
equivalent of the typed WebSocket refusals and prevents distinct validation guards from collapsing
to “HTTP 422” after URLSession discards the reason phrase.

## Concurrency ownership

The supported concurrency model has three kinds of owner:

- AppKit and mutable product stores are `@MainActor`.
- Immutable values crossing an executor are `Sendable`.
- A small number of socket/process adapters own mutable state on one named serial queue. They
  may be `@unchecked Sendable` only with a comment naming that queue and with every value read
  from another executor protected by a lock.

Do not use `@preconcurrency` or `@unchecked Sendable` to make a diagnostic disappear when the
type is ours. Add real `Sendable` conformance to wire values, isolate the reference type, or
move the mutation to its owner. Complete strict-concurrency checking is the project baseline and
the architecture lint prevents returning to targeted checking.

Escaping completions are part of the boundary. Mark one `@Sendable` when it crosses a queue or
actor, propagate that contract to the API that stores it, and make every terminal path complete
exactly once.

## Bounded work and observable failure

Every input-controlled collection needs a named budget: request bytes, frame bytes, buffered
process output, concurrent connections, pending sends, journal records, or cached entries.
Exceeding a budget returns a typed refusal or closes the untrustworthy transport; it never grows
until the process is unstable.

Enforce a directory budget while enumerating, before filtering, sorting or materializing the
result. `contentsOfDirectory(...).filter(...).prefix(n)` is not bounded: it has already allocated
every visible entry, and malformed names can hide valid entries beyond the prefix. Support-data
directories use a shallow lazy enumerator, count every visible entry, and fail closed with a typed
overflow once the directory budget is exceeded.

Use `ThreadingLogger` for live diagnosis and `EventLog` for the small set of durable lifecycle
facts needed to reconstruct a failure after restart. Logs must identify the subsystem and
stable identifiers, but must not copy prompts, bearer tokens, credentials, or arbitrary client
log text.

**Read a running child's output through `ChildOutputStream`, never `FileHandle.read(upToCount:)`.**
That count reads like a ceiling and is a *length to fill*: Foundation stays inside `read(2)` until
that many bytes arrive or the writer closes the pipe. A child that prints a burst and keeps running
therefore delivers nothing at all, and nothing reports it, because a blocked read is not a failure
anybody counts. This shipped: the since-retired HTTPS relay asked for 16 KB, its child printed
roughly 3 KB of banner with the published address inside it and then went quiet, so the very first
readability callback blocked for the life of the app. The tunnel was live and serving real traffic
the whole time; the settings page said "Preparing your pairing code / Connecting…" and iPhone
pairing was unreachable. `TailscaleServeTransport` reads the same way, which is why the type
outlived the transport it was written for. `BoundedChildProcess.captureSuffix`
is the deliberate exception: it drains a finite helper to EOF behind a `ChildProcessDeadline`, so
filling is what it wants.

The two obvious repairs are both wrong, which is why this is a type and not a line. `availableData`
has the right blocking semantics and reports failure by raising an Objective-C exception Swift
cannot catch — and so does `FileHandle.fileDescriptor` itself, on a handle closed underneath it,
which a reader racing `stop()` will hit. Trading a hang for a crash is not a fix. Caching the raw
descriptor instead avoids the exception and buys a worse bug: `readabilityHandler = nil` cancels
its source *asynchronously*, so a reader can still be mid-callback when the caller closes, and by
then the kernel may have given that number to an unrelated file. `ChildOutputStream` is a dispatch
read source over a non-blocking descriptor it owns: GCD's cancel handler runs after the event
handler has finished and never twice, so the close happens exactly once with nobody reading, and
`ChildOutputReader.read` returns an outcome rather than raising. Every teardown path cancels
explicitly rather than relying on `deinit`. `RemoteDoorReadinessTests` covers the burst, end of
file, a broken descriptor, and a spurious wake-up; the first fails by timeout if the primitive
changes back.

**A wait with no deadline is not a state, it is a hole in the ledger.** The same bug produced no
evidence anywhere — the diagnostics journal records `relayConnected` and `relayFailed`, and a
transport stuck in `.starting` reaches neither, so the one failure a support report most needed to
explain was the one it could not see. Any transport that can sit between "started" and "answered"
carries a timeout that converts silence into a stated reason, and a typed code beside the sentence
a person reads (`TailscaleReadinessIssue`) so a report groups by cause rather than by localised
prose. UI follows the same rule: a spinner is for work that is
still arriving, and a surface that is up but unusable gets its own copy and a retry, never the
progress branch — see `RemotePairingCardState`.

Declaring a transport failed also ends its child. A transport this app has stopped tracking must
not be left publishing the loopback listener, since an address serving real traffic that nothing in
the app knows about is the shape of the original bug, not a convenient fallback. Recovery is the
user's explicit retry, and a test of one asks the kernel whether the process is gone rather than
asking the transport what it believes.

A feature is not stable merely because its happy path works. Before calling one stable, it has:

- a typed availability/error state that the UI can render;
- persistence and wire-version behavior, including older/newer/corrupt fixtures;
- bounded resource behavior and cancellation;
- focused tests for refusal and recovery, not only success;
- a support-report or durable event seam for failures that otherwise disappear;
- inclusion in the non-interactive CI and release gate.

## Three failure states, not two

`BrowserBaselineStore` is where "missing or corrupt" stopped being enough. A durable bundle written
by a *newer* build of the app is neither: quarantining it would mean a downgrade silently confiscated
data it simply cannot read, and listing it would mean decoding a shape this build does not know. The
store reads the schema version first, keeps a newer record untouched and counts it, and reports the
count so the UI can say so.

The same type carries the other half of the rule the SQLite store already states: when the recovery
itself fails — the damaged directory cannot even be moved aside — writing is *blocked* rather than
logged and continued. A store that cannot preserve what it is about to write over has one safe move,
and it is to stop.

Validation re-reads from disk rather than trusting the bytes still in hand. A short write, a full
disk and a truncated PNG all look like success at the call site; the failure they cause surfaces
weeks later as a record that will not decode.

## Shipping contract

`scripts/ci.sh` is the canonical non-interactive gate: structural policy, localization and theme
boundaries, the secret scan, SwiftLint, a generic-simulator build of the shipping iPhone app,
every local contract/runtime package, and the off-screen Mac app test plan under complete
concurrency checking. The generic destination type-checks the mobile target without booting a
CoreSimulator device, so this build does not take the simulator lane lock. GitHub Actions and
`scripts/release.sh` call the same entry point so local, CI, and shipping definitions cannot drift.

### The secret scan is the one gate that fails closed forever

`scripts/check_secrets.sh` runs gitleaks over *git*, never over the working directory. That is
not a preference: `gitleaks dir .` walks DerivedData, `.build`, `node_modules` and xcbuilddata
attachments, which measured 2.87 GB and 8m50s here and reported findings in artifacts nobody
can commit, against 125 MB and 26s for the entire history.

Two callers, two scopes. `ci.sh` scans the whole history, because CI is the release gate and
should prove the whole artifact. The pre-push hook scans only the range being pushed, which is
sub-second for an ordinary push, and it runs *before* the test level and *regardless of*
`THREADING_SKIP_TESTS` — the variable is named for what it skips, and skipping this one
deliberately means `git push --no-verify`.

The ordering is the point. Every other gate here catches something a later commit can repair.
This one does not: a credential pushed to a public remote is burned the moment it lands,
because GitHub keeps unreachable commits addressable by their sha and a force-push does not
remove them. So the response to a finding is **rotate first, rewrite second**, and the hook's
failure message says so rather than leaving the reader to work it out.

Policy is `.gitleaks.toml`, and it allows exactly two kinds of exception. A **path** is
allowlisted only when it cannot structurally hold one of our secrets: vendored upstream trees,
generated reference material, dependency caches. A **value** is allowlisted only when
publishing it is the point, and there is exactly one — Sparkle's public EdDSA key, which ships
in Info.plist because verifying an update requires it.

Everything else that is a false positive goes in `.gitleaksignore`, pinned by
`commit:path:rule:line`. That is deliberately the narrow instrument: a fingerprint does not
generalise, so the same shape appearing in a new commit still fails. Widening `.gitleaks.toml`
to silence one finding is how a scanner quietly stops scanning.

A scan that examines nothing must not read as a clean scan. gitleaks reports an unresolvable
revision on stderr and still exits 0 with "no leaks found", so the script resolves every
revision itself with `git rev-parse --verify` first and fails loudly when one does not exist.

The release script must preserve command exit status, verify the version read from the exported
bundle, inspect every nested executable's signing/runtime/timestamp/entitlements, and require a
clean worktree before notarization. An explicit emergency escape hatch may skip tests; a default
release never does.
