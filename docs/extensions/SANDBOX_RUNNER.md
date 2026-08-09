# Design note: the supported extension sandbox runner

Status: design accepted, implementation staged. Updated 2026-07-24.

## Why this exists

`ExtensionSandboxPolicy` launches every extension through `/usr/bin/sandbox-exec` with a
generated Seatbelt profile. That is enough to prove the platform — it fails closed, it is
capability-specific, and it is isolated behind one type — but it cannot be the distribution
boundary:

- `sandbox-exec` is deprecated and its profile language is unversioned and undocumented.
- The profile is authored by us at runtime, so a mistake in string building is a containment
  bug rather than a policy bug.
- Nothing about the containment is signed, so nothing about it survives an attacker who can
  already write to the app's own support directory.

The replacement is a **separately signed, App Sandboxed helper** that the extension `execve`s
out of. Manifests, SDK APIs, capability names, the JSONL process protocol, and host-token
behaviour do not change. What changes is what bounds the child. (This note first specified an
XPC service; see "Settled" below for the measurements that chose otherwise, and read that
before §1 and §4.)

## The shape in one paragraph

The app keeps every decision it already makes — inspect the package, resolve the executable,
mint the process generation, authorize the host token, decide the capability set. It then
spawns the helper with the file descriptors the extension will use: stdin, stdout, stderr, and
one pre-connected host-broker socket. The helper validates what it was asked to run and
`execve`s it **in place**. **Nothing sits between the app and the extension** — not a relay, not
a supervisor, not even a second process: after the exec they are one pid.

```
Threading.app (unsandboxed)
  │  inspect package, authorize token, create pipes + socketpair
  │  posix_spawn with fds 0/1/2/3 installed
  ▼
threading-extension-helper  (App Sandboxed, signed, no network)
  │  sandbox already applied at its own launch; validate; execve in place
  ▼
extension executable  (same pid, same fds, still sandboxed)
  fd 0/1  JSONL protocol      → ExtensionProcessSession
  fd 2    diagnostics         → DiagnosticCapture
  fd 3    host broker socket  → ExtensionHostService
```

## Settled: an exec-in-place helper, not an XPC service

This note originally specified an XPC service. That was reconsidered and **measured**, and the
measurements chose against it. Everything below §1 that still describes XPC is kept only where
it describes containment; where it describes *ownership* or *descriptor transfer* it is
superseded by this section.

The alternative is:

```
Threading.app (unsandboxed)
  │  inspect package, authorize token, create pipes + socketpair
  │  posix_spawn the helper with fds 0/1/2/3 already in place
  ▼
threading-extension-helper  (signed with App Sandbox entitlements)
  │  sandbox applies at its own launch; validate the request; execve in place
  ▼
extension executable  (same pid, same fds, still sandboxed)
```

What that removes, all of it accidental to XPC rather than essential to containment:

- **§1's ownership problem.** The helper `execve`s in place, so the pid the app spawned *is*
  the extension. The helper additionally lowers `RLIMIT_NPROC` before the exec, so an extension
  cannot create a descendant which outlives that pid. `waitpid`, `Process.terminationHandler`,
  the runner's kill list and its crash-recovery file — none of it is needed.
- **§4's descriptor transfer.** The app spawns with the descriptors already installed; nothing
  crosses an XPC boundary, so there is no `FileHandle`-over-XPC step to get right.
- **The exit-reporting message**, and with it the reason `ExtensionChildProcess` had to latch a
  status at all.

What XPC would buy that this does not: launchd-managed lifecycle, a long-lived broker that
could outlive one launch, and Apple's blessed pattern for privilege separation. None of those
are load-bearing here — the app is unsandboxed, already supervises processes, and wants the
child to *be* the extension.

The cost is that the app must spawn with a descriptor beyond the standard three, which
`Process` cannot do. `ExtensionChildSpawner` exists for that and is tested; it is the one piece
both designs need, which is why it was built before this question was settled.

### What was measured

An ad-hoc-signed probe, run outside Xcode, on macOS 26.5. Each row is an observation, not an
inference:

| Question | Result |
|---|---|
| Does App Sandbox survive `execve` into a different binary? | **Yes.** The helper was denied `~/.bashrc`; so was the `/bin/bash` it exec'd into. |
| Can a bare signed Mach-O be App Sandboxed? | **No.** It traps at launch — see below. |
| Can a sandboxed helper `execve` a package with no exception? | **No.** `execve` → `EPERM`. |
| …with a home-relative read-only exception naming it? | **Yes.** The target ran. |
| Is the exec'd extension still contained? | **Yes.** Reads its own package; denied its home, denied writing its package, denied writing `/tmp`. |

That last row is the whole design in one line: the extension **runs from its package, can read
it, and has no writable path anywhere** — with no profile written by us at runtime.

Three findings worth carrying:

- **A bare executable with `com.apple.security.app-sandbox` traps at launch** with
  `Unable to get bundle identifier because Info.plist from code signature information has no
  value for kCFBundleIdentifierKey`. The helper must carry an embedded `Info.plist`
  (`-sectcreate __TEXT __info_plist`) with a `CFBundleIdentifier`. This is the single most
  likely way to build the helper and have it appear simply broken.
- **The exception is what grants the exec**, proven by the negative case rather than assumed:
  the same binary signed without it failed `execve` with `EPERM`.
- **App Sandbox rewrites `$HOME` to the container.** An extension's idea of home is a directory
  Threading does not use and should not start using; storage is brokered precisely so nothing
  depends on it.

## Decisions

### 1. Who launches and owns the child

**The app does, throughout.** It `posix_spawn`s the helper with every descriptor already in
place (`ExtensionChildSpawner`); the helper validates, applies nothing of its own — the sandbox
was applied to it at launch by its entitlements — and `execve`s the extension **in place**. The
pid the app spawned is the pid the extension runs as, so `waitpid` works, the exit arrives the
way it always has. `ExtensionChildSpawner` gives the launch its own process group and signals
the whole group on termination as defence in depth; the helper's inherited hard
`RLIMIT_NPROC = 1` is the primary rule, and the compiled probe asserts `posix_spawn` is denied.
There is therefore no descendant that can detach and become an orphan on disable or uninstall.

`ExtensionChildProcess` still latches its exit status. That was written for the XPC shape and is
kept because it is correct anyway, and because `SpawnedChildProcess` reaps from a
`DispatchSourceProcess` where the same race exists.

<details>
<summary>Superseded: the XPC ownership design</summary>

The **runner** launches it and owns it. The app cannot `waitpid` a process it did not fork, so
exit status arrives as an XPC message rather than as `Process.terminationHandler`. Ownership
follows from that:

- The runner keeps one record per spawned child: pid, the app's request id, and the connection
  that asked for it.
- If the app's XPC connection invalidates — the app quit, crashed, or was killed — the runner
  sends `SIGTERM` then `SIGKILL` to every child it spawned for that connection. An app crash
  therefore cannot leave an orphaned extension holding a live host token.
- If the runner itself dies, its children are reparented to `launchd` and would survive, so the
  runner spawns each child in **its own process group** and the app treats a runner
  invalidation as a terminal error for every generation, revoking the tokens immediately. The
  next spawn request restarts the runner (`launchd` relaunches XPC services on demand) and the
  first thing a fresh runner does is kill any process group recorded in its own crash-recovery
  file.

`ExtensionProcessSession` keeps its supervision logic unchanged. What it loses is the
`Process` object; see the launch abstraction below.

</details>

### 2. Helper and child entitlements

Two signed helper executables ship inside `Threading.app/Contents/Helpers/`, differing in exactly
one entitlement:

| Executable | Entitlements |
|---|---|
| `threading-extension-helper` | `com.apple.security.app-sandbox`, read-only home-relative exception for `Library/Application Support/Threading/Extensions/Packages/` |
| `threading-extension-helper-network` | the same, plus `com.apple.security.network.client` |

Each **must carry an embedded `Info.plist` with a `CFBundleIdentifier`** — measured: without one
the sandbox cannot resolve a container and the process traps at launch before `main` runs.

Deliberately absent from both, and each absence is load-bearing:

- `com.apple.security.network.server` — an extension must never accept an inbound connection.
- `com.apple.security.files.user-selected.*` and `files.downloads.*` — an extension has no
  document surface, so an open panel in an extension's process would be a confused deputy.
- `keychain-access-groups` — secrets are brokered; see §6.
- `com.apple.security.cs.disable-library-validation` and `cs.allow-jit` — a package must not be
  able to load unsigned code into its own process.
- `com.apple.security.temporary-exception.files.home-relative-path.read-write` — see §5. No
  extension gets a writable filesystem grant at all.

Two variants rather than one is the price of App Sandbox expressing network access at signing
time. It is a **static two-way choice**, made from `ExtensionCapability.networkClient` alone,
and every finer distinction stays with the host broker, which already authenticates
capabilities per token. A third variant would be a smell: the answer to "we need another
helper" is almost always "that authority belongs in the broker".

The extension keeps the helper's sandbox across `execve` — measured, see above. That inheritance
is the whole containment mechanism, and it is what removes our runtime profile string from the
trusted computing base.

### 3. Executable and package validation

The app validates first — `ExtensionBundleInspector` already resolves the executable, refuses
one that escapes the package root, and refuses a package containing symbolic links. The helper
**re-validates independently** (`ExtensionRunnerValidator`), because a broker that trusts its
caller's paths is a convenience, not a boundary:

- the package root must be a directory directly inside the app-owned `Packages/` directory,
  with the `.threadingextension` extension and no path traversal after standardization — and
  *directly* inside, since a package nested in another package's directory would inherit that
  package's read grant;
- the executable must resolve, after symlink resolution, to a runnable regular file inside that
  root, so a symlink within the package cannot launder a path outside it;
- the argument vector must be exactly one known entry mode (`--threading-register` or
  `--threading-serve`), so the helper is not a general-purpose exec service;
- no `DYLD_*` environment name is forwarded — an injected library runs with the extension's
  authority and would make the containment irrelevant to what actually executes.

**What that last check does and does not protect**, measured rather than assumed: setting
`DYLD_INSERT_LIBRARIES` on the *helper's own* launch runs the injected constructor before the
helper's `main`, and it does so even under Developer ID signing with hardened runtime
(`flags=0x10000(runtime)`). The helper still refuses to launch the extension, so nothing reaches
the extension — but code did run in the helper first. The check therefore protects the
**extension** from a poisoned environment, not the helper from its parent. That is acceptable
because the only process that can set the helper's environment is Threading itself, which is
unsandboxed and already fully privileged; a compromise there is not a compromise this boundary
was ever meant to contain.

The read-only grant is the outer bound regardless: a path the helper was wrongly persuaded to
accept still cannot be exec'd unless it lies under the entitlement, which was measured.

Once packages carry provenance (see `HANDOFF.md` §2), the helper also checks the package
signature before exec, and reports the failure as a distinct error so Settings can say "this
package's signature no longer matches" rather than "launch failed".

### 4. stdin/stdout JSONL bridging and backpressure

There is none, and under the helper design there is nothing to transfer either. The app creates
the pipes it already creates and `posix_spawn`s the helper with them already installed
(`ExtensionChildSpawner`), so:

- the existing per-line cap, drain queues, and `DiagnosticCapture` are unchanged;
- a slow reader applies pipe backpressure to the extension itself, not to a middle process;
- no process between the app and the extension ever holds extension data, so none has size
  limits of its own to get wrong;
- `POSIX_SPAWN_CLOEXEC_DEFAULT` means the extension inherits exactly the descriptors it was
  given and nothing the app happened to have open — asserted by test, not assumed.

The helper `execve`s in place, so the descriptors it was spawned with are the ones the extension
runs with. Nothing is passed across a process boundary at all.

### 5. Storage, and the one place App Sandbox is weaker

Today the child writes its key-value and cache directories itself, and the generated Seatbelt
profile grants exactly those two paths. App Sandbox cannot express "this child may write this
one directory": a home-relative read-write exception would grant the whole
`Extensions/Storage/` subtree to every extension, and an extension that guessed a sibling's
identifier could read it. That would regress boundary 6.

So **storage stops being a filesystem grant and becomes broker traffic**:

- `ExtensionKeyValueStore` is already bounded (2048 keys, 1 MiB total). Its implementation gained
  a second backing that speaks `/v1/storage/kv` on the host connection. The public SDK API did
  not change shape — including staying **synchronous**, because storage has always been a
  blocking API and an extension's serve loop is an ordinary `readLine` loop. The transport
  therefore offers a `sync` exchange alongside the `async` one, over the one serialized queue.
- The **host writes through the SDK's own `ExtensionKeyValueStore`**, directory-backed, so there
  is one implementation of the on-disk format rather than a host copy that can drift from the
  one extensions were tested against. A brokered write lands exactly where the granted-directory
  write would have, so changing launcher does not strand existing state.
- `ExtensionStorageEnvironment.keyValueDirectory` and `.cacheDirectory` are no longer exported
  to a runner-launched child. They remain for the experimental policy so that the two launch
  paths can be compared during the transition.
- `ExtensionCacheStore` replaces handing out a directory, with the same two backings and one
  API. A **name is one path component**, validated on both sides, because the broker takes it
  from a request body and a broker that trusted its caller's path would be an arbitrary-write
  primitive rather than a cache. `ExtensionCache.directoryURL()` survives as the experimental
  launcher's raw grant, and reports `unavailable` under the runner.
- The **100 MiB cache ceiling is checked per write**, not only at launch. A brokered extension
  never restarts to have its cache reclaimed, so a launch-time sweep alone would let it grow
  unbounded for as long as the app stays open.

The result is that a runner-launched extension has **no writable path anywhere**, which is a
stronger statement than the current profile can make.

One decision here was revised while implementing it. This note originally proposed brokering
cache files by **passing a descriptor back** for each opened file. That needs `SCM_RIGHTS`,
which is ancillary data the HTTP framing cannot carry — so it would mean a second, out-of-band
framing on the same socket, which is exactly the "two request readers" hazard §4 exists to
avoid. Cache is instead a **bounded byte API keyed by name**, like KV: entries are capped at
4 MiB so one still fits a single request after base64 has inflated it by a third. An extension
that genuinely needs to stream gigabytes needs the durable large-file surface `HANDOFF.md`
lists as a possible addition, not a cache Threading is free to delete at any moment.

### 6. Exact host-broker connectivity

The child talks to the host over an **inherited socket, not a port**.

The app creates a `socketpair(AF_UNIX, SOCK_STREAM)`, keeps one end, and passes the other to
the runner, which installs it as the child's fd 3. `ExtensionHostConnection` gains a descriptor
mode: when `THREADING_EXTENSION_HOST_FD` is present it speaks the same request/response protocol
over that descriptor; when only `THREADING_EXTENSION_HOST_URL` is present it uses loopback HTTP
as it does today. The bearer token, the extension identity derived from it, the generation
binding, and every capability check are unchanged.

This is a better boundary than the port, not merely a sandbox workaround:

- there is no port to guess, so a second process running as the user cannot reach the broker at
  all — today it must merely fail authentication;
- the non-network runner needs no network entitlement to be brokered, which is what lets
  `networkClient` be the only capability that changes the runner variant;
- revocation is a `close()`, which the child observes immediately as EOF rather than as a 401 on
  its next call.

The loopback listener remains for the experimental policy and for the MCP surface, which is a
separate consumer.

Three things about socket I/O were found by implementing this and are easy to walk back into:

- **`FileHandle.read(upToCount:)` blocks on a socket until it has the whole count**, so a
  chunk-sized read waits for bytes the peer was never going to send. The client reads with
  `read(2)`.
- **`FileHandle` raises an Objective-C exception on an I/O error**, which turns a revoked
  connection into a crash rather than a thrown error. Same fix.
- **`SO_NOSIGPIPE` is set on both ends.** Writing to a revoked broker has to be an error, not a
  signal.

### 7. Capability-to-sandbox mapping

| Capability | Enforced by |
|---|---|
| `network.client` | runner variant (`com.apple.security.network.client`) |
| `storage.kv`, `storage.cache` | broker, over fd 3; no filesystem grant |
| `storage.secrets` | broker, over fd 3; the runner holds no Keychain entitlement |
| `services.consume`, `services.provide` | broker, over fd 3 |
| `host.*` reads, `host.events` | broker, over fd 3 |
| `ui.components`, `ui.panels`, `commands`, `settings`, `mcp.tools` | protocol on fd 0/1; no OS authority needed |
| package contents | runner's read-only home-relative exception |
| everything else | denied by App Sandbox default |

Every row that reads "broker" is already token-authenticated by `ExtensionHostService`, so this
table describes a *second* enforcement layer rather than a replacement for the first.

### 8. Signing across local development, tests, archive, and distribution

- **Local development**: the helpers are Xcode command-line-tool targets copied into the app's
  `Contents/Helpers`, each with an embedded `Info.plist` (`-sectcreate __TEXT __info_plist`).
  App Sandbox requires a signature to carry entitlements; **ad-hoc signing (`-`) with an
  entitlements file is sufficient** — the whole measurement above was made that way, outside
  Xcode.
- **Tests**: the helper is located through `Bundle.main`, so the hosted test bundle finds the
  same copy the app uses. When it is absent — a plain `swift build`, a CI image without a
  signing identity — the launch abstraction reports `runnerUnavailable` and the suite runs the
  experimental policy instead, saying so in the failure message rather than silently changing
  what it tested.
- **Archive and distribution**: Developer ID signing is inside-out — each helper first, then
  the app — and notarization covers the nested executables. The helper is versioned with the
  app; there is no independent update path, which is deliberate: a helper and a host that
  disagree about the spawn contract is a failure nobody can diagnose from the outside.

### 9. How registration probes and persistent launches share the runner

They are the same spawn request with different arguments and different descriptors:

| | registration probe | persistent session |
|---|---|---|
| arguments | `--threading-register` | `--threading-serve` |
| stdin | `/dev/null` | pipe |
| host fd | none | socketpair |
| lifetime | bounded by the caller's timeout | until revoked |

`ExtensionRegistrationLoader` and `ExtensionProcessSession` therefore call one abstraction with
one shape of request, and the runner has exactly one entry point to audit.

### 10. Testing denial

Containment is only proven by trying to break it. Every other sandbox test in this project
reads the *generated profile*, which proves what we wrote and not what the kernel enforced, so
a probe now runs inside the sandbox and reports back what it managed to do
(`ExtensionBundleLoaderTests.testTheSandboxDeniesEverythingAnExtensionDidNotDeclare`).

It is built from shell builtins on purpose: a probe that shelled out to `curl` would be
measuring `process-exec` denial in every case and calling it a network result. Measured under
the current `sandbox-exec` policy:

| Attempt | Outcome |
|---|---|
| Read its own package | **allowed** — the positive control |
| Read a path outside its package | denied |
| Write outside its package | denied |
| Write to its own package | denied |
| Outbound TCP, no `network.client` | denied |
| Outbound TCP, with `network.client` | **allowed** |
| Execute another program | process ends |

Two of those rows are load-bearing beyond their result. **The positive control is what makes
the denials mean anything** — a suite that only asserts denial cannot tell containment from a
probe that silently did nothing, which is precisely what happened twice while this was being
written. And the **network pair points at a real listener** on an ephemeral loopback port,
because a probe aimed at a closed port reports "denied" on a machine with no sandbox at all.

Three findings came out of writing it, each of which cost a run:

- **Executing another program ends the process** rather than returning an error the extension
  can see. It is measured by its own spawn for that reason; run alongside the others it
  truncated every later case into silence. A launcher expecting a graceful error here would be
  wrong.
- **A `#!/bin/sh` package runs as `bash --posix`, and posix mode exits the shell on *any*
  redirection error.** A probe written that way dies at its first denial. `#!/bin/bash` is an
  equally allowed interpreter and does not.
- **A shebang with leading whitespace is not detected**, so the launcher execs the script
  directly and the kernel refuses it — fail-closed, and worth knowing before someone reads that
  `Operation not permitted` as a sandbox bug.

### The compiled probe, under the helper

`Packages/ThreadingExtensionKit/Examples/DenialProbeExtension` reaches what a shell cannot: the Keychain,
inbound listeners, and whether a spawned child inherits the containment. It reports on **stderr**
and emits an ordinary registration on stdout, so it is a real extension the launcher starts
rather than a special mode the launcher would have to allow — widening the entry-mode list to
accommodate a test would weaken the thing the test exists to check.

Measured under the signed helper, and **verified identically in Debug and Release** — the latter
signed with a real identity and hardened runtime (`flags=0x10000(runtime)`), carrying exactly
two entitlements and no filesystem exception beyond the packages directory. Checking both is not
ceremony: the first of the two findings below is a difference between configurations that made
Debug look contained when it was not.

| Attempt | Outcome |
|---|---|
| Read its own package | **allowed** — the positive control |
| Read the user's home | denied |
| Read `Threading/threading.db` | denied |
| Read `Threading/Extensions/` (every other extension's storage) | denied |
| Write its own package, or `/tmp` | denied |
| Listen on a TCP port | denied |
| Read Threading's extension secrets without interaction | denied |
| Raise a legacy login-Keychain ACL prompt | **allowed — blocks helper promotion** |
| Spawn another program | denied by the inherited hard process limit |
| A spawned child escaping the sandbox | denied (the spawn itself is refused) |
| Enumerate Keychain item *attributes* | **allowed** |

**Two of those rows are not what the design assumed**, and both were found by running the probe
rather than by reading a profile:

- **`xcodebuild test` re-signs the helper with injected entitlements no build setting
  suppresses.** The test action adds the `/` exception and `com.apple.testmanagerd` lookups to
  every target it builds, *overriding* `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`. The copy in
  `Contents/Helpers` after a test run is therefore not the copy that ships, and a test that
  probed it would be measuring Xcode's debugging affordances rather than the containment —
  which is exactly what happened on the first automated run. `testTheCompiledProbeIsContained…`
  re-signs the built binary with the product's own entitlements file and probes that, and
  asserts the re-sign actually replaced them so it cannot pass for the wrong reason. Ad-hoc
  signing carries entitlements perfectly well, which is what makes this measurable with no
  identity at all.
- **`CODE_SIGN_INJECT_BASE_ENTITLEMENTS` silently disabled the containment in Debug builds.**
  Xcode injects debug entitlements into the signature, and among them is
  `com.apple.security.temporary-exception.files.absolute-path.read-only` for **`/`** — read
  access to the entire filesystem, inherited by every extension the helper execs. The first
  probe run under the built helper reported the home directory, the projects database and other
  extensions' storage all readable. The setting is now `NO` on both helper targets. Containment
  that only holds in Release is containment nobody can test, and this is the single easiest way
  to reintroduce a hole that looks like a working helper.
- **Keychain *metadata* is enumerable.** A contained extension can list generic-password items —
  327 of them on this machine, the same count as an unsandboxed process — reading service and
  account names. Reading a secret's *data* is a different matter. The test seeds real bytes in
  the exact production service/account, disables every interactive Keychain path **before its
  first Keychain query**, requests `kSecReturnData`, and asserts the bytes are denied. The probe
  exits without querying if legacy interaction cannot be disabled; a containment test must
  never train the user to approve a Keychain prompt. Metadata exposure remains a **known
  limitation**: an extension can learn *which* services the user holds credentials for.
  Verified identically under ad-hoc and Developer ID + hardened runtime signing.
- **App Sandbox does not suppress legacy-Keychain authorization UI.** The first exact-data
  probe displayed a real dialog asking whether the extension should receive Threading's seeded
  secret. Moving the cooperative no-UI switch before every probe query prevents test UI but
  cannot constrain malicious code. The product's generated Seatbelt profile now explicitly
  denies `com.apple.securityd.xpc`, `com.apple.securityd.general`, and
  `com.apple.security.XPCKeychainSandboxCheck`. An adversarial probe omits every no-UI flag and
  requests the same seeded bytes; it returns denied in 0.08 seconds without a dialog. For that
  reason `ExtensionManager` always selects `SandboxExecLaunchPolicy` and ignores the old
  `usesContainedExtensionLauncher` developer default. The helper remains a test harness until
  a non-deprecated boundary can pass that same adversarial probe.

App Sandbox by itself permits spawning and merely passes containment to the child. That is not
enough for lifecycle ownership: a sandboxed network-capable child could still outlive disable.
The helper therefore lowers both the soft and hard `RLIMIT_NPROC` to one before `execve`. The
extension cannot raise it again, its subprocess probe receives `EAGAIN`, and the launch's
separate process group remains a second termination boundary for future capability work.

## Implementation sequence

1. ~~**Launch abstraction, no behaviour change.** Introduce `ExtensionLaunchPolicy` with the
   current `sandbox-exec` implementation behind it, and route both
   `ExtensionRegistrationLoader` and `ExtensionProcessSession` through it.~~ Done. The
   abstraction describes a *spawned child* rather than a `Process`, and latches the exit status
   so an observer installed after the child died still receives it — under the runner the app
   cannot `waitpid` a child it did not fork, so the exit arrives as a message.
2. ~~**Descriptor-mode host connection.** Add `THREADING_EXTENSION_HOST_FD` to
   `ExtensionHostConnection` and serve the same protocol over a socketpair in
   `ExtensionHostService`. Keep the loopback path.~~ Done. Revocation shuts the socket down
   synchronously; `ExtensionLaunchRequest.extraDescriptors` carries the child's end, and
   `SandboxExecLaunchPolicy` refuses it rather than pretending to pass it.
3. ~~**Broker storage.** Move key-value and cache onto the broker and stop exporting storage
   directories in descriptor mode.~~ Done. `ExtensionLaunchPolicy` declares its `hostTransport`,
   so the day the runner lands the descriptor path goes live with no other change.
4. ~~**The helper targets.**~~ Done. `ThreadingExtensionHelper` and
   `ThreadingExtensionHelperNetwork` are command-line-tool targets embedded into
   `Contents/Helpers` with `CodeSignOnCopy`, each carrying its entitlements and an embedded
   `Info.plist`. `HelperLaunchPolicy` selects the variant from
   `ExtensionCapability.networkClient` and declares `hostTransport = .descriptor`. None of the
   XPC machinery — exit reporting, connection-invalidation cleanup, the crash-recovery kill
   list — was needed.
5. ~~**The denial probe and its tests.**~~ Done for what a shell probe can reach — files,
   outbound network with its positive control, and subprocess execution — against the current
   policy. A compiled probe for Keychain and inbound listeners lands with the runner.
6. ~~**Prevent direct Keychain prompts on the product path.**~~ Done with an explicit
   securityd Mach-service denial and an adversarial compiled probe.
7. ~~**Replace deprecated `sandbox-exec` without weakening the measured boundary.**~~ Done with
   the WebAssembly interpreter described below. The App Sandbox native helper remains only a
   test harness while legacy-Keychain ACL prompts are possible.

## 11. Resolution: interpret Swift WebAssembly, do not execute native package code

The long-term product boundary is now `WasmLaunchPolicy` plus the signed
`threading-wasm-extension-runner`. New safe manifests declare `runtime: webAssembly`; omission
means the legacy native compatibility path.

This changes the trusted question. We no longer ask macOS to confine an arbitrary native
executable closely enough. Threading interprets a module and links only the capabilities it may
have:

- WASI stdin, stdout, and stderr;
- no filesystem preopens;
- no socket-opening API;
- no subprocess host function;
- no Security.framework or Objective-C runtime;
- one custom import, `threading.host_exchange`.

The app opens the validated `.wasm` module read-only and installs it as descriptor 4. The
runner therefore needs no package-directory entitlement. In serve mode descriptor 3 is the
existing authenticated host broker; registration deliberately receives no broker. WasmKit
limits module size, linear-memory growth, table growth, and host request/response sizes.

The runner itself carries exactly `com.apple.security.app-sandbox`. A guest cannot manufacture
a Keychain authorization prompt because Security.framework is not linked or exposed as an
import; this removes the native helper's unresolved prompt surface instead of trying to hide it
with a voluntary flag.

`RuntimeSelectingLaunchPolicy` retains `SandboxExecLaunchPolicy` only so already-created
native format-1 packages still decode and run. It is a compatibility policy, not the template
for newly authored extensions. Direct guest networking is intentionally unavailable even when
an old capability vocabulary contains `network.client`; if safe extensions need HTTP, it must
arrive as a narrow authenticated host-broker service rather than a socket entitlement.

Verification covers three layers:

1. `ThreadingExtensionKit` contract tests and WebAssembly compilation of both reference
   extensions;
2. `ThreadingWasmRuntime` fixtures proving no-authority execution, fail-closed registration, and
   the sole broker import;
3. an app-hosted test which executes a real WASI registration module through the exact signed,
   App Sandboxed helper embedded in `Threading.app`.

Steps 1–3 change no containment and can land independently. Step 4 is the only one that needs a
signing identity to test end to end.

## What this note does not decide

- Package signing and provenance, which `HANDOFF.md` §2 owns. The runner has a hook for it
  (§3) and nothing more.
- Whether a trusted native tier ever exists. It would not use this runner; a native extension
  loads into the app and has no sandbox at all, which is exactly why it is a separate tier.
