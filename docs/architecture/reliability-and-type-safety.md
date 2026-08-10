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

## Fail closed at every external boundary

An invalid value must not accidentally become a permissive or destructive default.

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
boundaries, SwiftLint, every local contract/runtime package, and the off-screen app test plan
under complete concurrency checking. GitHub Actions and `scripts/release.sh` call the same entry
point so local, CI, and shipping definitions cannot drift.

The release script must preserve command exit status, verify the version read from the exported
bundle, inspect every nested executable's signing/runtime/timestamp/entitlements, and require a
clean worktree before notarization. An explicit emergency escape hatch may skip tests; a default
release never does.
