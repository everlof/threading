# Extension system handoff

Updated: 2026-07-26. Safe extension API v1 is now checked through its release checklist:
WebAssembly containment, source-bundled packaging, provenance and migrations, the complete live
Hello Status/Consumer pass, MCP-assisted scaffold and reviewed installation, a real
scaffold-to-runner dogfood build, and the documented v1 compatibility freeze.

## Objective

Continue Threading's extension work toward a broad but controlled extension platform that is easy
for an AI to author against. Safe extensions run out of process, use the Foundation-only
`ThreadingExtensionKit`, exchange value types with the host, and ask Threading to render semantic UI.
Do not make AppKit or SwiftUI part of the safe extension ABI.

The user wants extensions to be able to customize most useful product surfaces over time, but
through documented, versioned host contracts rather than arbitrary runtime overrides.

## Current state

The experimental extension platform is usable end to end:

- `.threadingextension` directories and unpacked development directories can be inspected and
  imported into app-owned storage.
- Extensions can be enabled, disabled, reloaded, revealed, and recoverably removed from the
  Extensions settings page.
- Enabled extensions run as supervised JSONL processes. Crashes, protocol failures, reloads,
  disable, removal, and shutdown revoke the process generation and its host publications.
- Manifest capabilities and runtime are inspected before execution. New safe extensions are
  Swift WebAssembly modules launched through Threading's signed App Sandboxed interpreter, with
  no filesystem preopens, socket or subprocess surface, and only the authenticated host-broker
  import. `RuntimeSelectingLaunchPolicy` keeps the generated Seatbelt launcher only for legacy
  native format-1 packages.
- The native App Sandbox helpers and their compiled denial probes remain test harnesses. They
  proved the native approach's unresolved limit: arbitrary native code can ask macOS to show a
  legacy login-Keychain ACL prompt. The WebAssembly runner removes Security.framework and that
  prompt surface from the guest's imports instead of attempting to suppress it voluntarily.
- Packages can be **assembled** (`ExtensionPackager`) and **updated in place**
  (`ExtensionManager.update`), with the capability delta shown for approval before anything is
  replaced. The source is copied first; that staging tree is then inspected, digested, approved
  and atomically installed, so the approved artefact and installed artefact are the same tree.
- The public SDK is Foundation-only and has a build-policy plugin which rejects AppKit and
  SwiftUI imports.
- Extensions can contribute:
  - commands;
  - shortcuts in the same conflict namespace as built-in commands;
  - commands under stable `Extensions`, `Project`, and `View` menu anchors;
  - complete Settings pages or sections appended to stable built-in Settings pages;
  - semantic display-pane panels;
  - MCP tools, visible in the existing Tools settings;
  - versioned JSON services consumed by explicitly declared extensions;
  - constrained component patches and component actions;
  - provider/account image resolvers and session identity composition.
- Host snapshots and cursor events expose sanitized projects, sessions, repositories, providers,
  and account presentation behind independent read capabilities.
- Private extension persistence exists in four separate forms, all reachable with no writable
  path when the host brokers them:
  - host-owned extension settings;
  - bounded atomic KV storage;
  - reclaimable, name-keyed cache storage;
  - Keychain-backed opaque secrets through the generation-bound host broker.
- The production project and session sidebar rows expose versioned component contracts with
  safe properties, `after-title` status slots, and compact content replacement.
- The Hello Status reference extension exercises real project/session CI status, identity
  composition, settings, commands, panels, services, and host snapshots.
- Extension authoring MCP tools can scaffold a separate source project with the app-shipped SDK,
  list/describe/validate/preview public component contracts, and propose a package install. The
  proposal shows runtime and capabilities, requires the user's decision, and always installs
  disabled.

Start with:

- `docs/extensions/README.md`
- `docs/extensions/API_V1.md`
- `docs/extensions/AGENT_AUTHORING.md`
- `docs/extensions/HOST_SURFACES.md`
- `docs/extensions/COMPONENT_CUSTOMIZATION.md`
- `docs/extensions/CUSTOMIZATION_SURFACE_AUDIT.md`
- `docs/extensions/SANDBOX_RUNNER.md`
- `docs/extensions/AUTHORING_FLOW.md`
- `Packages/ThreadingExtensionKit/README.md`

## Important architecture boundaries

Preserve these boundaries unless there is strong evidence to change them:

1. **Safe extensions never provide native views.** They send semantic values and `ExtensionNode`
   trees. Threading owns rendering, theme, accessibility, focus, layout, and fallback.
2. **The host authenticates extension identity.** Host APIs derive the extension ID and process
   generation from the bearer token. Never accept an extension ID supplied in a request body as
   authority.
3. **Capabilities are independent.** UI does not imply host data, networking, storage, secrets,
   or another extension's service.
4. **Publications are complete and atomic.** Reject an invalid patch set without disturbing the
   last accepted set.
5. **Host-owned behavior stays outside replaceable content.** Selection, drag/drop, row actions,
   activity state, permissions, and security controls must survive extension replacement.
6. **Extensions do not read each other's storage.** Cross-extension communication goes through
   declared, versioned brokered services.
7. **Core MCP remains extension-agnostic.** The extension MCP provider is an adapter; do not
   import `ThreadingExtensionKit` or `ExtensionManager` into the MCP core.
8. **Installed packages are immutable.** Mutable state belongs in settings, KV, cache, or the
   secrets broker.
9. **Rendering never waits for an extension process.** Disable, crash, or invalid output must
   restore host defaults immediately.

## Recently completed work

### The launch abstraction, and the runner design it exists for

`docs/extensions/SANDBOX_RUNNER.md` is the design note remaining-work item 1 asked for. It
decides the ten questions that item listed, and three of its answers are worth knowing before
reading any launch code:

- **The runner is a spawn broker, not a data relay.** The app creates the pipes it already
  creates and passes the descriptors through XPC, so the JSONL bytes still flow directly
  between the app and the extension. There is no second buffer, and therefore no backpressure
  design.
- **The host broker moves from a loopback port to an inherited socket** (`fd 3`,
  `THREADING_EXTENSION_HOST_FD`). That is what lets the non-network runner variant hold no
  network entitlement at all, and it removes the guessable port.
- **Storage stops being a filesystem grant.** App Sandbox cannot express a per-extension
  writable directory, so key-value and cache access become broker traffic and a
  runner-launched extension has no writable path anywhere. This is the one place App Sandbox
  is weaker than the generated Seatbelt profile, and it is answered rather than accepted.

`ExtensionLaunchPolicy` is now in place and changes no behaviour. Both launch paths —
`ExtensionRegistrationLoader.load` and `ExtensionProcessSession.start` — build an
`ExtensionLaunchRequest` and receive an `ExtensionChildProcess`. The abstraction deliberately
does not expose `Process`: under the runner the app cannot `waitpid` a child it did not fork,
so exit arrives as a message. `LocalChildProcess` therefore **latches** the exit status, and
`observeExit` delivers it even when installed after the child has already died — pinned by a
test, because that race is invisible in the local policy and certain under the runner.

`RuntimeSelectingLaunchPolicy` is the product implementation. `SandboxExecLaunchPolicy` keeps
`ExtensionSandboxPolicy` as the native compatibility profile generator, so the existing native
containment tests still test that path.

Relevant files:

- `Sources/Threading/Core/Extensions/ExtensionLaunchPolicy.swift`
- `Sources/Threading/Core/Extensions/ExtensionBundleLoader.swift`
- `Sources/Threading/Core/Extensions/ExtensionProcessSession.swift`
- `Tests/ThreadingTests/ExtensionBundleLoaderTests.swift`

### The descriptor-mode host broker

The host now answers on an inherited socket as well as on the loopback port, and both carriers
reach `ExtensionHostService.route` — the bytes are the same HTTP/1.1 exchange, so there is one
router, one authenticator and one set of capability checks rather than two.

- `THREADING_EXTENSION_HOST_FD` selects it, and `ExtensionHostConnection(environment:)` **prefers
  it over `THREADING_EXTENSION_HOST_URL`**, since a runner-launched extension may hold no network
  authority at all. A descriptor-mode authorization exports no URL.
- `ExtensionHostService.authorize(…, transport: .descriptor)` mints the socket pair and returns
  the child's end as `ExtensionHostAuthorization.childDescriptor`, to be installed as
  `ExtensionHostDescriptorConnection.childDescriptorNumber` (3) and closed in this process
  afterwards.
- **Revocation is a `shutdown`, taken synchronously in `cancel()`**, so the moment `revoke`
  returns the extension's next call fails rather than racing a queue for the answer.
- `ExtensionLaunchRequest.extraDescriptors` carries it, and `SandboxExecLaunchPolicy` **refuses
  a request that uses it**: `Process` spawns with `POSIX_SPAWN_CLOEXEC_DEFAULT` and offers no
  API for descriptors past the three standard streams. That refusal is the honest statement of
  what the signed runner adds, and it is pinned by a test.

Three findings are worth keeping, because each cost real time and each is invisible in the
code that suffers from it:

- **`FileHandle.read(upToCount:)` blocks on a socket until it has the whole count.** A
  chunk-sized read therefore waits for bytes the host was never going to send. The transport
  uses `read(2)` directly.
- **`FileHandle` reports an I/O error by raising an Objective-C exception**, so a revoked
  connection crashed the process where it should have thrown `hostClosed`. Same fix.
- **`SO_NOSIGPIPE` is set on both socket ends.** Writing to a revoked broker must be an error,
  not a signal, or an extension whose generation was revoked mid-call dies of SIGPIPE instead
  of reading the end-of-file that explains it.

Relevant files:

- `Packages/ThreadingExtensionKit/Sources/ThreadingExtensionKit/ExtensionHostDescriptorTransport.swift`
- `Packages/ThreadingExtensionKit/Sources/ThreadingExtensionKit/ExtensionHostClient.swift`
- `Sources/Threading/Core/Extensions/ExtensionHostDescriptorConnection.swift`
- `Sources/Threading/Core/Extensions/ExtensionHostService.swift`

### Brokered storage

`ExtensionKeyValueStore` has two backings and one public API. Under the experimental launcher it
writes the granted directory as it always did; under the supported runner it speaks
`/v1/storage/kv` and the host writes on its behalf. `init(environment:)` chooses, preferring the
broker for the same reason `ExtensionHostConnection` does — a process holding a broker was
launched by the runner, and the runner grants no writable path.

- **The API stayed synchronous.** Storage has always been blocking because it was file I/O and
  an extension's serve loop is an ordinary `readLine` loop; making a stored counter `async`
  would be a large break for no gain. `ExtensionHostDescriptorTransport` therefore offers
  `sendSynchronously` alongside `send`, over the one serialized queue.
- **The host writes through the SDK's own directory-backed store.** One implementation of the
  on-disk format, so a brokered write lands exactly where a granted-directory write would have
  and changing launcher strands nothing.
- **Limits are enforced by the host**, which is where the authority is. The SDK keeps its local
  pre-checks so an obvious mistake answers without a round trip, never as the boundary, and
  `ExtensionHostService` maps its refusals back onto the same `ExtensionStorageError` cases the
  directory backing raises — one vocabulary regardless of which side refused.
- **`ExtensionLaunchPolicy.hostTransport` is the seam.** The launcher answers how its children
  reach the broker, because containment is what decides it; `ExtensionManager` asks. The day the
  signed runner lands, the descriptor path goes live with no other change.
- **`storage.kv` and `storage.cache` earn a host connection only in descriptor mode.** Over
  loopback they are granted directories, so issuing a broker token there would widen what an
  extension can reach for nothing.

`ExtensionCacheStore` is the same pattern for the cache, and replaces handing out a directory.
Three things about it are decisions rather than details:

- **A name is one path component**, validated by the SDK *and* independently by the host. The
  broker takes the name from a request body, so a broker that trusted its caller's path would
  be an arbitrary-write primitive rather than a cache.
- **A miss is a 200 carrying a null value, not a 404.** Threading may reclaim any entry at any
  moment, so absence is an ordinary answer; an extension forced to tell "absent" from "refused"
  by status code would get it wrong.
- **The 100 MiB ceiling is checked per write**, not only at launch as it was. A brokered
  extension never restarts to have its cache reclaimed, so a launch-time sweep alone would let
  it grow unbounded for as long as the app stays open.

`ExtensionCache.directoryURL()` survives as the experimental launcher's raw grant and reports
`unavailable` under the runner. `HelloStatusExtension` uses `ExtensionCacheStore` instead, since
the example is the authoring template.

### Containment is now measured, not just asserted

Every other sandbox test here reads the generated profile text, which proves what we *wrote*
rather than what the kernel *enforced*. A probe now runs inside the sandbox and reports what it
managed to do; the results table and the three findings that came out of writing it are in
`SANDBOX_RUNNER.md` §10. Two things about its shape matter more than the results:

- **The positive controls are load-bearing.** `readsOwnPackage=allowed` and the
  `network.client` half of the network pair are what make the denials mean anything — twice
  while writing this the probe reported total denial because it had silently failed to run at
  all, and only the control caught it.
- **The network probe points at a real listener** on an ephemeral loopback port. Aimed at a
  closed port it would report "denied" on a machine with no sandbox whatsoever.

Relevant files:

- `Tests/ThreadingTests/ExtensionBundleLoaderTests.swift`

### The runner foundation and completed product path

The original native runner foundation was built and tested first; that evidence then led to the
completed WebAssembly product path described below.

`ExtensionChildSpawner` spawns a child with an **exact descriptor map**. `Process` cannot: it
exposes only the three standard streams and spawns with `POSIX_SPAWN_CLOEXEC_DEFAULT`, which is
why `SandboxExecLaunchPolicy` refuses a request carrying `extraDescriptors`. A test drives a
real broker pipe in on fd 3 *and* asserts that a descriptor left out of the map is closed in the
child — an extension inheriting a stray descriptor would be a hole no profile can close.

It is deliberately **not** an `ExtensionLaunchPolicy`. Everything reachable through that
protocol contains the child; spawning without containment is a step in building one, never a
way to run an extension.

`ExtensionRunnerValidator` is the runner's own check on what it has been asked to run, repeating
from scratch work the app already did — a broker that trusts its caller's paths is a
convenience, not a boundary. It refuses an unknown entry mode (otherwise the runner is a
general-purpose exec service), a package outside the install root or nested inside another
package, an executable that leaves its package including **via a symlink that points out**, and
any `DYLD_*` environment name, since an injected library runs with the child's authority and
would make the sandbox profile irrelevant to what actually executes.

**The runner's shape changed, and it changed because it was measured.** The note originally
specified an XPC service; it now specifies a signed helper that the extension `execve`s out of.
An ad-hoc-signed probe, run outside Xcode, established:

- **App Sandbox survives `execve` into a different binary.** The helper was denied `~/.bashrc`;
  so was the `/bin/bash` it exec'd into.
- **A home-relative read-only exception is what permits the exec**, proven by the negative case:
  the same binary signed without it failed `execve` with `EPERM`.
- **The exec'd extension runs and stays contained** — it reads its own package, and is denied
  its home, denied writing its package, and denied writing `/tmp`. That is the whole design in
  one line, with no profile written by us at runtime.
- **A bare signed executable cannot be App Sandboxed.** It traps at launch unless it carries an
  embedded `Info.plist` with a `CFBundleIdentifier` (`-sectcreate __TEXT __info_plist`). This
  is the most likely way to build the helper and have it look simply broken.

Because the helper `execve`s **in place**, the pid the app spawned is the pid the extension runs
as. Before the exec it sets a hard inherited `RLIMIT_NPROC = 1`, denying subprocesses which
could otherwise outlive that pid, and the app signals the launch's entire process group as
defence in depth. That deletes the XPC design's ownership problem, descriptor transfer,
exit-reporting message, and orphan/crash-recovery machinery. The superseded design is kept,
collapsed, in the note.

### The helper exists, and it works

`Targets/ExtensionHelper/` is a small target of its own: `main.swift` validates and `execve`s, and it shares
`ExtensionRunnerRequest.swift` with the app. Two Xcode command-line-tool targets build it —
`ThreadingExtensionHelper` and `ThreadingExtensionHelperNetwork`, differing only in
`com.apple.security.network.client` — and the app embeds both into `Contents/Helpers` with
`CodeSignOnCopy`. `HelperLaunchPolicy` picks the variant from the manifest's capabilities and
declares `hostTransport = .descriptor`.

An end-to-end test runs a real package through **the helper that actually ships**, and it is not
a skip: it asserts the extension ran with the right entry mode, read its own package, received
the broker on fd 3 *through the `execve`*, and was denied writing its package or anywhere
outside it. A second test confirms the helper refuses a package outside the install root even
though the app would never ask for that.

Four things worth knowing before touching this:

- **`CODE_SIGN_INJECT_BASE_ENTITLEMENTS` must stay `NO` on both helper targets.** Xcode
  otherwise injects debug entitlements including a read-only exception for **`/`**, which hands
  the helper — and every extension it execs — read access to the entire filesystem. The helper
  still runs, still validates, and still refuses what it should, so nothing about it looks
  wrong; only the compiled probe caught it.

- **The helper needs an embedded `Info.plist`** (`OTHER_LDFLAGS = -sectcreate __TEXT
  __info_plist …`). Without a `CFBundleIdentifier` the sandbox cannot resolve a container and
  the process traps before `main` — which reads as the helper being broken rather than
  misconfigured.
- **The two variants use different bundle identifiers** on purpose. The sandbox derives a
  container from the identifier, and although neither helper uses its container, a shared one
  is a coupling nobody would think to look for.
- **`project.pbxproj` was edited with the `xcodeproj` Ruby gem**, not by hand, via
  `scripts/add_helper_targets.rb` — which is idempotent, so re-running it after a merge
  conflict rebuilds the targets rather than duplicating them. The diff is large mostly because
  the gem re-sorts `PBXBuildFile`; the set of registered sources was diffed before and after to
  confirm nothing was lost.

**The app no longer launches real extensions through it.** The old
`AppSettings.usesContainedExtensionLauncher` developer default is ignored deliberately.
App Sandbox blocks silent secret reads but allows legacy login-Keychain ACL authorization UI,
and a malicious extension can choose not to set the cooperative no-UI Security.framework
flags. `ExtensionManager.defaultLaunchPolicy` therefore always returns the generated Seatbelt
policy, whose explicit deny of the securityd Mach services is enforced before any ACL prompt.
The helper remains directly reachable by focused containment tests, not by product startup.

Wiring it up surfaced a real gap and a real hazard, both now closed:

- `ExtensionProcessSession.start` had **no way to pass the broker descriptor**. It takes a
  `hostDescriptor` and turns it into the request's `extraDescriptors`, so the socket the host
  minted actually reaches the extension.
- **Descriptor ownership had to be stated, not implied.** Attempting a spawn now *consumes* the
  request's descriptors whether or not it succeeds, and `ExtensionManager` closes the broker
  socket itself on the one path that fails before reaching a policy. The two failure modes here
  are opposite and both bad: leak it and the host end never sees end-of-file, so a dead
  extension merely looks quiet; close it twice and the second close lands on whatever unrelated
  descriptor inherited the number.

The App Sandbox helper cannot become the default on current evidence. The adversarial probe
proved that the generated Seatbelt product policy prevents both secret data and the legacy
authorization prompt; the same probe demonstrated that App Sandbox alone does not. The
Hello Status product pass through that hardened path is now complete. The remaining runtime
work is replacing deprecated `sandbox-exec` without promoting the helper's weaker boundary.

Relevant files:

- `Targets/ExtensionHelper/main.swift`, `Targets/ExtensionHelper/ExtensionRunnerRequest.swift`
- `Targets/ExtensionHelper/threading-extension-helper*.entitlements`, `Targets/ExtensionHelper/Info*.plist`
- `Sources/Threading/Core/Extensions/HelperLaunchPolicy.swift`
- `Sources/Threading/Core/Extensions/ExtensionChildSpawner.swift`

One trap worth knowing before writing a test against this: broker authentication and AppKit
registries live on the main actor, while **KV/cache parsing and disk I/O run on
`ExtensionHostStorageRouter`'s serial queue**. Brokered SDK calls remain synchronous from the
extension's perspective. In a test both ends still share one process, so
`ExtensionRendererTests.asAnExtensionProcess` runs the extension side off-main; a separate
blocking-store test proves a slow extension-controlled cache operation cannot pin the UI.

Relevant files:

- `Packages/ThreadingExtensionKit/Sources/ThreadingExtensionKit/ExtensionKeyValueBroker.swift`
- `Packages/ThreadingExtensionKit/Sources/ThreadingExtensionKit/ExtensionCacheBroker.swift`
- `Packages/ThreadingExtensionKit/Sources/ThreadingExtensionKit/ExtensionStorage.swift`
- `Sources/Threading/Core/Extensions/ExtensionStorageStore.swift`
- `Sources/Threading/Core/Extensions/ExtensionHostService.swift`

### Menu placement and shortcuts

`ExtensionMenuPlacement` supports `extensions`, `project`, and `view`.
`AppDelegate.rebuildExtensionMenus()` renders extension groups at those stable anchors.
`ExtensionCommandMenuLayout` chooses one canonical placement as the shortcut owner so a command
shown in several menus does not register its key equivalent several times. A command with no
visible placement can still be dispatched by its assigned shortcut.

Relevant files:

- `Packages/ThreadingExtensionKit/Sources/ThreadingExtensionKit/ExtensionContributions.swift`
- `Sources/Threading/App/AppDelegate.swift`
- `Sources/Threading/Core/Settings/ExtensionCommandMenuLayout.swift`
- `Sources/Threading/Core/Settings/CommandRegistry.swift`
- `Sources/Threading/Core/Settings/ShortcutOverrideStore.swift`

### Keychain-backed secrets

The `storage.secrets` capability and `ExtensionHostClient` secret APIs are implemented.
The host stores generic-password Keychain items in an extension-scoped namespace, validates
key/value/count limits, and exposes list/get/put/delete through `/v1/secrets`.

Important properties:

- at most 256 keys per extension;
- key length is 1–512 UTF-8 bytes with no control characters;
- value size is at most 64 KiB;
- listing returns sorted names, not values;
- namespaces come from authenticated extension identity;
- missing capability returns `403`;
- corrupt or oversized stored responses fail validation;
- secrets never enter settings, package files, KV JSON, cache directories, or sandbox grants.

Relevant files:

- `Packages/ThreadingExtensionKit/Sources/ThreadingExtensionKit/ExtensionSecrets.swift`
- `Packages/ThreadingExtensionKit/Sources/ThreadingExtensionKit/ExtensionHostClient.swift`
- `Sources/Threading/Core/Extensions/ExtensionSecretStore.swift`
- `Sources/Threading/Core/Extensions/ExtensionHostService.swift`
- `docs/extensions/schema/extension-secrets.schema.json`

This work also fixed a sandbox bug: `services.consume` was accepted by host authorization but did
not receive access to the generation's exact loopback port. Both `services.consume` and
`storage.secrets` now receive that one broker port without receiving broad network access.

## Verification baseline

The following was green after the latest changes:

```bash
swift test --package-path Packages/ThreadingExtensionKit
# 46 tests, 0 failures

xcodebuild -project Threading.xcodeproj -scheme Threading \
  -destination 'platform=macOS' test
# 1038 tests, 2 intentionally skipped, 0 failures

swift run --package-path Packages/ThreadingExtensionKit \
  ThreadingComponentCatalogGenerator --check docs/extensions/generated
# Component catalogue is up to date.

git diff --check
# clean
```

Ten JSON files under `docs/extensions/schema` were also decoded successfully.

`Tests/ThreadingTests` is not a synchronized Xcode group. If a new test file is created, register it
in `Threading.xcodeproj/project.pbxproj` or use the existing `scripts/add_test_file.py` helper.
Prefer adding tests to an existing registered test file when that produces a coherent suite.

## Worktree warning

The worktree contains the complete, uncommitted extension/theme implementation and unrelated
user work may also be present. Do not reset, restore, delete, or broadly reformat files. Inspect
`git status` and the overlapping diff before every edit. Preserve all existing changes.

## Remaining work

### Safe extension v1 release checklist

This is the authoritative, checkable path from the current experimental platform to a
supported safe extension v1. More detailed sections below explain the evidence and constraints
behind each item. Do not call the extension system production-ready until every unchecked
v1-blocking item here is complete.

#### Runtime and containment

- [x] Run extensions out of process behind `ExtensionLaunchPolicy`.
- [x] Build and embed signed App Sandbox helper variants.
- [x] Move host authority onto a generation-bound inherited descriptor.
- [x] Broker KV, cache, secrets, services, and host data without granting writable paths.
- [x] Deny undeclared filesystem, inbound-network, and subprocess authority with executable
  probes rather than profile inspection alone.
- [x] Prevent the automated Keychain denial probe from displaying authorization UI: interaction
  is disabled before its first Keychain query and the probe exits without querying if that
  cannot be guaranteed.
- [x] **Block direct legacy-Keychain authorization prompts from arbitrary extensions.** The
  product's generated Seatbelt profile denies the securityd Mach services themselves. An
  adversarial compiled probe intentionally uses Security.framework's default interactive
  behavior against real seeded bytes and returns denied in 0.08 seconds, without a dialog. The
  prompt-capable App Sandbox helper is no longer selectable by the app, even through the stale
  developer default; it remains a test harness only.
- [x] Complete the real Hello Status pass through the hardened Seatbelt product policy in the
  running app:
  - [x] Install, enable, and launch the packaged extension under the product policy.
  - [x] Render its live project/session component publications and host-data snapshots.
  - [x] Show its contributed settings page and its section on an existing settings page.
  - [x] Exercise brokered KV and cache storage from the extension process.
  - [x] Invoke its contributed command through the registered `⌥⌘R` shortcut.
  - [x] Publish its dynamic MCP tool into the live server and invoke it end to end.
  - [x] Exercise brokered secrets from the live extension without allowing direct Keychain
    access. Hello Status 0.2.0's MCP probe completed a temporary write/read/list/delete round
    trip through the host broker, and a separate Keychain lookup confirmed that it removed the
    temporary item.
  - [x] Run the packaged Hello Status Consumer extension under the product policy and invoke its
    registered command. Its brokered dependency call reached Hello Status's registered
    `status` v1 service and returned `{"refreshCount":1}` with no response error.
  - [x] Approve and install a package update from Hello Status 0.1.0 to 0.2.0. The confirmation
    showed only the added `storage.secrets` capability, retained extension state, and the
    installed manifest plus relaunched process both reported 0.2.0.
  - [x] Verify explicit reload, a full disable/enable cycle, and crash recovery. Reload replaced
    the process generation and restored the provider service. Disable removed the provider while
    the still-running consumer received a brokered 503; enable restored the call. A deliberate
    `SIGKILL` produced an enabled-but-failed status with no registered service, and Reload
    started a new process which the unchanged consumer called successfully.
  - [x] Repeat the visual pass with the replacement-layout fix in a clean app build and confirm
    that it produces no Auto Layout warnings. The clean build passed the theme boundary, the
    main extension-customized sidebar and both host/extension Settings surfaces rendered
    correctly, and the post-fix unified-log query was empty for AppKit constraint failures,
    Auto Layout diagnostics, theme-audit failures, and fatal errors. The pass first caught a
    separate transient launch conflict in the pane header while AppKit still reported a
    zero-height toolbar safe area; its safe-area equality is now priority 999 so the 40-point
    floor wins only during that initial layout and settled geometry remains unchanged.
- [x] Decide and implement the supported long-term replacement for deprecated `sandbox-exec`.
  New safe extensions compile to WebAssembly and run in a signed App Sandboxed WasmKit
  interpreter with no filesystem preopens, sockets, subprocesses, or direct Security.framework
  surface. The inspected module arrives on descriptor 4 and its sole custom import reaches the
  authenticated host broker on descriptor 3. Native format-1 packages remain a deprecated
  compatibility path; the prompt-capable native helper is still only a test harness.

#### Packaging and distribution

- [x] Import, inspect, enable, reload, update, and recoverably remove packages.
- [x] Stage, digest, approve, and atomically install the exact update candidate.
- [x] Show added capabilities and version direction before an update.
- [x] Assemble and validate an installable `.threadingextension`.
- [x] Choose how an extension project outside this repository consumes a versioned
  `ThreadingExtensionKit`: scaffolded projects vendor the exact app-shipped SDK snapshot and use
  a relative SwiftPM path dependency. `SDK_VERSION` versions that snapshot; no checkout path,
  floating branch, or rebuild-time network access is required.
- [x] Require editable source in distributable WebAssembly packages while retaining a prebuilt
  module for deterministic installation. The inspector requires `Package.swift` and a Swift
  source under `Sources/` without compiling; the packager copies it to `Source/` while omitting
  local build and VCS state.
- [x] Define provenance/signing and its trust presentation. V1 records host-authored local
  import provenance (source name, package SHA-256, SDK version, timestamps) and presents it as
  local/unsigned. There is no author-signing hierarchy and no “trust anyway”; provenance never
  weakens containment or grants authority.
- [x] Define versioned migrations for extension-owned settings/KV/cache data. `dataVersion` is
  monotonic; from/to values reach the process, the host commits only after successful
  registration, and interrupted idempotent migrations retry.
- [x] Define and document uninstall/reinstall retention for settings, KV, cache, and Keychain
  secrets. Filesystem state, committed data version, and provenance move beside the package in
  `Removed/`; secrets remain namespaced in Keychain for intentional reinstall and must be
  removed explicitly before uninstall when retention is unwanted.

#### Product proof and API freeze

- [x] Connect settings pages/sections, commands, shortcuts, menu anchors, panels, MCP tools,
  services, component patches/actions, and identity composition to real product surfaces.
- [x] Publish machine-readable schemas, a generated component catalogue, public authoring
  documentation, reference extensions, and authoring MCP tools.
- [ ] Apply the customizable-presentation pattern across stable product surfaces. Each adoption
  must keep trigger, lifecycle, placement, focus, accessibility and destructive behavior in a
  host-owned shell; extensions receive only semantic add/wrap/replace contracts:
  - [x] `sidebar.project-hover-card@1`: compose around native project-metrics content, replace it, or create
    an extension-only card. Multiple hooks retain provenance and the Hello Status reference
    extension contributes real project detail through the public contract.
  - [x] `sidebar.session-hover-card@1`: compose around the existing session identity/status
    card using session-presentation context. It reuses the same host and constraints, supports
    extension-only presentation in the generic shell, and preserves action provenance.
  - [x] `toolbar.account-usage-popover@1`: compose account-specific details while Threading owns
    usage refresh, hover survival and account switching. The pointer bridge surrounds the
    composition host, so even a complete replacement cannot make the hover popover collapse.
  - [x] Define safe composer seams. `composer.session-start@1` and
    `composer.conversation-reply@1` accept protected horizontal hooks with compact controls
    before or after exactly one `.proceed`. The real native prompt remains the same instance;
    replacement and overlay are rejected, and input, submission, keyboard, drafts, streaming,
    permission state and accessibility remain host-owned. Full replacement is intentionally
    deferred unless those behaviors gain a separate permanent shell.
  - [x] Define conversation-row contracts separately:
    `conversation.user-message@1`, `conversation.assistant-message@1`,
    `conversation.tool-call@1`, and `conversation.permission-card@1`. Each is a protected
    vertical annotation hook around one `.proceed`, scoped family-wide or by session without
    exposing transcript content. Native message/tool/permission objects remain intact;
    permission annotations are display-only and cannot imitate approval controls.
  - [x] Audit display-pane chrome and tab headers without exposing replacement.
    `display.pane-header@1` provides a protected compact command/status region before the
    host-owned `+` button, while `display.tab-header@1` provides one display-only
    `after-title` status slot inside each native tab. Targets are session-scoped rather than
    internal-tab-UUID-scoped. Selection, close, ordering, active state, overflow, persistence,
    pane visibility and the new-tab menu remain host-owned; Hello Status and the real
    display-pane controller exercise action provenance and fallback.
  - [x] Keep system menus, permission decisions, Keychain prompts and destructive confirmation
    wording host-owned. Extend their semantic command/action inputs rather than their AppKit
    hierarchy. Extension commands already enter host-rendered stable menu anchors and the global
    shortcut registry without receiving `NSMenuItem` or event-monitor access. Commands now add
    only `ExtensionCommandRisk`; `.destructive` gates menu and shortcut invocation through a
    Threading-authored warning whose copy, button roles, keyboard default and decision cannot be
    supplied by the extension. Permission-card hooks remain display-only, while safe WebAssembly
    extensions have neither AppKit nor Security.framework and reach secrets only through the
    isolated host broker.
- [ ] Complete the Session Info public-API dogfood pass. This is intentionally measured against
  the existing built-in feature, not against a reduced panel that happens to compile:
  - [x] Build `SessionInfoExtensionExample` using only public SDK values and the policy plugin.
  - [x] Add the generic optional panel `loadActionID`, with project/session context, a
    generation-scoped exactly-once host lifecycle, backwards-compatible decoding, schema/docs,
    and focused SDK/host tests.
  - [x] Render the data already available through safe project, session, and repository
    snapshots: title, activity, project, provider/account identity, branch, surface, repository,
    revision, side-chat state, and archive state.
  - [x] Exercise `--threading-serve` against a capability-shaped test broker: the automatic load
    request fetched its session and project, preserved the request ID, and returned a validated
    12-row replacement panel.
  - [x] Define a narrow brokered session-runtime snapshot for agent/shell process groups, CPU,
    memory, and listening-port metadata. SDK snapshot 1 includes
    `host.sessions.runtime.read` and `sessionRuntime(id:)`; the host resolves only its own
    agent/shell roots for a known session and returns bounded semantic rows. There is no process
    enumeration, arbitrary PID query, parent traversal, arguments, environment, open files, or
    socket authority. Session Info renders the result using ordinary public nodes.
  - [ ] Define panel visibility and pushed-update semantics so a live panel polls only while
    visible and can replace its content without a user action.
  - [ ] Define brokered semantic actions for reveal-in-Finder, copy-to-pasteboard, and opening a
    validated local URL. Do not expose `NSWorkspace`, `NSPasteboard`, or arbitrary host calls.
  - [ ] Decide whether the exact working-directory path is justified by a separate visible
    capability, or replace it with a host-rendered opaque directory presentation/action.
  - [ ] Decide whether repeated process/port rows need a reusable semantic row node after
    rendering the first telemetry-backed version; do not add a Session-Info-specific view type.
  - [ ] Package, install, enable, visually verify, reload, and disable the completed Wasm
    extension in the running app.
- [x] Dogfood the authoring flow from a user's request into a separate extension project,
  proposal, capability approval, package assembly, installation, and later update. The MCP
  scaffold/proposal tools are wired into the live catalogue; both MCP and manual import share
  the same pre-copy capability decision. An official Swift 6.3.2/Wasm opt-in test executes the
  generated scaffold and `Scripts/package.sh`, installs the resulting source-bundled package
  disabled with provenance, and registers it through the signed runner. Hello Status's live
  0.1.0 → 0.2.0 update supplies the later-update and added-capability approval evidence.
- [x] Build enough real extensions to exercise CI status, identity composition, and a richer
  stateful panel. Hello Status is the CI, identity and stateful hybrid (settings, KV/cache/secrets,
  MCP, panels, commands and a service); Hello Status Consumer independently proves declared
  cross-extension consumption and lifecycle loss/recovery.
- [x] Freeze and document the safe extension API as v1 after dogfooding.
  `ThreadingExtensionAPI`, SDK snapshot 1, and `API_V1.md` pin the supported Wasm runtime,
  manifest/process/host/component version domains, safe capabilities, source/wire compatibility
  promise, and explicit exclusions. Tests bind `SDK_VERSION` and all current component contract
  versions to that declaration. This is still pre-release: dogfood additions remain part of
  snapshot 1, and the published compatibility/migration promise begins with the first public
  extension release rather than private local experiments.

The optional trusted native-UI tier in §4 is **not** a safe-v1 blocker.

### 1. Long-term sandbox runner — WebAssembly boundary complete

This was the largest known technical gap and no longer is. `docs/extensions/SANDBOX_RUNNER.md`
holds the design, the measurements behind it, and the results of both denial probes. The shape
changed on evidence: an **exec-in-place helper** replaced the XPC service once App Sandbox was
measured to survive `execve`, which deleted the ownership, descriptor-transfer and
exit-reporting machinery the XPC design needed.

The production answer is now a capability-oriented WebAssembly boundary rather than a more
elaborate native-process sandbox. Swift source still uses the public value-only SDK, but the
shipped artifact is a WASI command module interpreted by WasmKit.

- ~~Write the design note.~~ Done.
- ~~Introduce a launch abstraction used by both `ExtensionRegistrationLoader` and
  `ExtensionProcessSession`, changing no behaviour.~~ Done: `ExtensionLaunchPolicy`.
- ~~**Descriptor-mode host connection.** Add `THREADING_EXTENSION_HOST_FD` to
  `ExtensionHostConnection` and serve the existing request/response protocol over a socketpair
  in `ExtensionHostService`, keeping the loopback path.~~ Done.
- ~~**Broker storage.** Key-value and cache, so no extension needs a writable path.~~ Done.
  Cache is a bounded byte API keyed by name rather than descriptor passing: `SCM_RIGHTS` is
  ancillary data the HTTP framing cannot carry, so passing descriptors would mean a second
  framing on the same socket.
- ~~**Build the helper.**~~ Done, and proven end to end through the helper that actually ships.
- ~~**Deny legacy-Keychain authorization UI at the runner boundary.**~~ Done for the product
  path. The Seatbelt profile denies securityd's Mach services, and a compiled adversarial probe
  intentionally permits UI while requesting real seeded bytes; it returns denied in 0.08
  seconds without displaying anything. The App Sandbox helper remains prompt-capable and is
  therefore unreachable from `ExtensionManager`, including through the old developer default.
- **Finish the real-extension pass through the hardened Seatbelt product policy.** The packaged
  Hello Status extension now launches in the running app under the product policy. Its
  project/session publications, full and embedded settings contributions, brokered KV/cache,
  secrets, `⌥⌘R` command, dynamic MCP registration plus invocation, and approved 0.1.0 → 0.2.0
  update have all been exercised live. The run also exposed an Auto Layout bug: replacement
  content inherited the hidden native identity view's fixed constraints.
  `ComponentContentContainer` now deactivates the native constraints while a replacement is
  installed, and a focused layout test pins the resulting 36-point `HStack` width. The first
  secret probe also exposed a debug-verification trap: rebuilding the `.app` while its old
  process remained alive made securityd reject the running process because its cdhash no longer
  matched the bundle on disk. Relaunching the exact built bundle made the brokered
  write/read/list/delete pass. The separately packaged Hello Status Consumer was then installed,
  enabled, and exercised through its registered command; the host verified its declared
  dependency and brokered the call to Hello Status's `status` v1 service. Explicit reload,
  disable/enable, and deliberate-crash recovery were then exercised with process replacement
  and service availability checked at each boundary. Finally, a clean build and live visual
  rerun covered the customized sidebar, built-in Extensions page, and extension-owned Settings
  page. That audit also found and fixed the pane header's transient zero-safe-area launch
  constraint; the rebuilt app produced no matching Auto Layout, theme-audit, or fatal log
  entries.
- ~~**Replace deprecated `sandbox-exec` without weakening the boundary.**~~ Done for new safe
  extensions. `RuntimeSelectingLaunchPolicy` routes `runtime: webAssembly` to the signed
  `threading-wasm-extension-runner` and old native manifests to the compatibility policy. The
  app opens the already inspected module and passes it on fd 4, so the runner needs no package
  read entitlement. It provides no filesystem preopens or socket API and links only
  `threading.host_exchange`; registration has no broker and serve mode gets the generation-bound
  fd 3 broker. Limits cover module bytes, guest memory, table growth, and broker frames.
  SDK tests compile both reference extensions for `wasm32-unknown-wasip1`; runtime tests execute
  no-authority and brokered fixtures; app tests execute a real WASI registration module through
  the exact signed helper embedded in the built app.
- ~~**The compiled denial probe.**~~ Done — and it found two things, one of which was a hole.
  See `SANDBOX_RUNNER.md` §10. In short: **Xcode's injected debug entitlements granted read
  access to all of `/`**, so the containment was off in Debug builds and looked fine
  (`CODE_SIGN_INJECT_BASE_ENTITLEMENTS` is now `NO`); and **Keychain item metadata is
  enumerable** from inside the sandbox, which is platform behaviour and a documented limitation
  rather than something an entitlement fixes. The probe now also requests real seeded secret
  bytes from the exact production namespace with interaction disabled, and asserts denial.
- ~~**Automate the compiled probe.**~~ Done, and it immediately found the *second* half of the
  entitlement-injection problem: **`xcodebuild test` re-signs the helper with the `/` exception
  regardless of `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`**, so the artifact a test run produces
  is not the artifact that ships. The test therefore re-signs the built binary with the
  product's own entitlements file before probing, and asserts the re-sign replaced them so it
  cannot pass for the wrong reason. It skips with the exact `swift build` command when the probe
  is not built.
- ~~**The denial probe.**~~ Done twice over: a shell probe against the experimental
  `sandbox-exec` policy, and the compiled `DenialProbeExtension` against the signed helper,
  covering Keychain, inbound listeners and subprocess denial. Both result tables are in
  `SANDBOX_RUNNER.md` §10.

Keep `sandbox-exec` reachable only for existing native format-1 packages while migration
remains useful. New authoring, package examples, and API-freeze evidence must use WebAssembly.

### 2. Package publication and updates

Import and recoverable removal work, but the publication lifecycle is incomplete:

**The update path is done**, which is the security-relevant half. `ExtensionPackageStore`
gained `updatePlan(from:)` and `update(from:approving:)`, and `ExtensionUpdatePlan` says what
replacing an installed copy would change: version direction, capabilities added, capabilities
removed. Four decisions in it are worth keeping:

- **Only *added* authority requires re-approval.** Nobody has to consent to an extension asking
  for less, and a version number alone changes nothing the user agreed to. `requiresApproval` is
  therefore `!addedCapabilities.isEmpty` and not "anything differs".
- **The plan carries a content digest of the candidate**, not just its manifest fields. This was
  fixed after the fact: the first version compared identifier, version and capabilities, so a
  source that swapped its *executable* while leaving its manifest untouched passed the
  re-check and installed code the user never reviewed. Verified by disabling the digest and
  watching the substituted build go in. The capability model still bounded what that code
  could do — this was never privilege escalation — but the re-check claims "the same thing I
  showed you" and now means it. `ExtensionPackageDigest` hashes every file's **path alongside
  its contents, in sorted order**, so a rename with identical bytes is not invisible and the
  result does not depend on enumeration order. Any read error refuses the update; a hash of a
  readable prefix is never accepted as evidence.
- **Copy first, then inspect the immutable staging candidate.** Between showing a capability
  delta and acting on it a source directory can change. Replacement therefore copies into an
  app-owned staging sibling, validates and hashes that exact tree while the package store is
  locked, compares it with the approved plan and only then atomically moves that same tree into
  place. A test performs substitution and asserts the installed copy is left untouched.
- **Private storage survives an update.** Settings, key-value state, cache and secrets live in a
  tree keyed by identifier, so replacing the package does not touch them. That is worth stating
  because the obvious alternative — uninstall then install — silently discards all four, which
  is why update is its own operation rather than a convenience wrapper.
- **A rollback is surfaced, not refused.** `isReinstallOrRollback` reports it; a deliberate
  downgrade is legitimate and a silent one is how an old vulnerable build comes back.

`ExtensionVersion` compares dotted integers numerically (`0.10.0` is newer than `0.9.0`) and
treats a trailing zero as no change, and reports `.incomparable` rather than guessing an order
for something like `1.0-beta` — ordering that wrongly is worse than declining to.

`ExtensionPackager.assemble(manifestURL:executableURL:into:)` is the step `README.md` used to
spell out as `mkdir`, two `cp`s and a `chmod` — fine to read once, wrong to make every author
repeat, and the middle step of the edit → build → install loop in `AUTHORING_FLOW.md`. It puts
the binary where the *manifest* says rather than where the caller built it, refuses a manifest
whose executable path escapes the package **before writing anything**, refuses to overwrite an
existing destination, and **validates the result through `ExtensionBundleInspector`** — as the
host will read it, not as we believe we wrote it. It assembles in a staging sibling and moves
into place only once that passes, so a failed assembly leaves nothing for someone to later
mistake for a real package. Its test proves the output installs.

It is deliberately not a build system: the caller has already produced an executable by
whatever means.

**The delta is now shown, which is what the delta was for.** Each extension has an *Update…*
button; choosing a source computes the plan and puts it to the user before anything is
replaced. `ExtensionUpdatePlan.confirmation(name:)` builds that text and lives beside the plan
rather than inside the view controller — it is the sentence the whole feature exists for, and a
sentence assembled inside an `NSAlert` call is one no test ever reads. Two things it does
deliberately: the **title carries the risk** ("Update “X” and grant new permissions?" with a
*Grant and Update* button), because a title people skim is the last thing read before a button
is pressed; and an ordinary update does **not** borrow that wording, or the alarming wording
stops meaning anything. It also states that settings, stored data and secrets are kept, because
the thing people assume is the opposite.

`ExtensionManager.update(from:approving:)` orchestrates it, and the ordering is the reason it
is not just a call to the store. **The running generation is stopped before the package
moves.** An extension's executable is the file its process is running from; replacing it under
a live child leaves a process whose image no longer matches its package, and the next thing to
read that package — a reload, a capability check, the sandbox profile — would describe
something the running process is not. While this is happening the manager exposes `.updating`
and refuses enable, disable, reload, uninstall and overlapping update actions. Completion reads
the **current desired state** before restarting, rather than a stale captured Boolean. A failed
update still restores an enabled working extension. Success, failure, and the exclusion window
are tested against a genuinely running extension.

**An incompatible manifest now says which side is out of date.** A package declaring
`formatVersion: 2` used to report "The extension manifest could not be read", which sends
someone looking for a typo in a file that is fine. `ExtensionBundleInspector` reads the format
version *on its own, before the manifest it describes* — a future format may carry fields
today's decoder cannot read at all — and reports "needs a newer version of Threading" or "this
build no longer supports it" accordingly. A manifest with no `formatVersion` at all is still
malformed rather than incompatible, and still reports the missing field.

**The example manifests are now validated by enumeration, not by name.** The test that checked
them listed two explicitly, so a third example added with `schemaVersion` where the format
requires `formatVersion` sat in the directory authors are told to copy from — invalid, refused
on import, and passing tests. It now walks `Examples/` and fails naming the directory and the
missing key. A named list only ever checks the examples someone remembered to add to it, which
is the same silent-failure shape as an unregistered test file.

What remains of this item:

- ~~build a packager which assembles and validates `.threadingextension`;~~
- ~~require editable source for published extensions while retaining a prebuilt executable for
  reliable installation;~~
- ~~choose how projects outside the repository consume the SDK;~~ Vendored exact snapshot with
  `SDK_VERSION`. The app now embeds that filtered source package under
  `Contents/Resources/ExtensionSDK`; the scaffold copies it into `Vendor/ThreadingExtensionKit`
  and its generated script packages the compiled Wasm plus rebuildable source.
- ~~define signing/provenance and trust presentation;~~ v1 deliberately records local/unsigned
  provenance and package integrity without inventing an author PKI. If author signing is added,
  it identifies who wrote the same sandboxed package and never grants more authority;
- ~~implement version-aware update/replace without overwriting by identifier;~~
- ~~define manifest/SDK storage migrations;~~ monotonic `dataVersion`, retry-safe startup
  context, and commit-after-registration are implemented;
- ~~decide and document secret retention/removal behavior;~~ update keeps all state; uninstall
  recovers filesystem state/provenance and retains identifier-scoped Keychain items explicitly;
- ~~make capability changes visible before an update is enabled~~ — done end to end: an
  **Update…** button on each extension, a picker, and a confirmation naming the version
  direction and the permissions being added, wired to `update(from:approving:)`.

Source-only execution should remain a developer workflow. Do not make normal installation depend
on a compatible Swift toolchain existing on the user's machine.

### 3. Dogfood real extensions before broadening UI

Build three real extensions against public documentation only:

1. a CI extension with project/session indicators and commands;
2. an identity extension which changes provider/account/session identity composition;
3. a richer panel extension with settings, persistent state, an MCP tool, and at least one
   brokered service.

Treat missing APIs encountered by these extensions as evidence. Add the narrowest semantic host
surface that resolves a real gap.

### 3a. The authoring flow — how a user ever gets here

`docs/extensions/AUTHORING_FLOW.md` is the design for the moment a user says "Threading should
show me X". That sentence now connects to an explicit MCP authoring flow: the agent can discover
the extension tools, scaffold a standalone project with the shipped SDK, build and package it,
and propose a reviewed disabled installation. The agent cannot approve or enable its own
package.

The shape is that **the ask becomes a new extension in its own project in the sidebar** — an
extension under development is a software project, and holding those is what the app already
does, so the flow routes into an existing surface rather than inventing one. Three decisions in
that flow remain important:

- **It carries the ask, not the chat.** A fork cannot cross projects as things stand — Claude
  resolves `--resume` inside a directory slugged from the cwd — and most of the conversation is
  about the user's own repository anyway. `SessionMigration` shows a transcript is a portable
  file, so a cross-project fork is plausible and unproven; measure it before assuming it.
- **Installing is proposed, never performed**, on `propose_storage_cleanup`'s precedent. The
  thing being approved is the *capability set*. An agent that could grant itself
  `network.client` and `storage.secrets` by writing a manifest would make every other boundary
  here decorative.
- **Source and installed package are different things**, because boundary 8 makes the package
  immutable. Editing source does not change the running extension, and a flow that hid that
  would make "I changed it and nothing happened" the standard experience.

The dependency and scaffold questions are resolved: **an extension scaffolded outside this
repository vendors the exact SDK snapshot shipped by the app**, points SwiftPM at it with a
relative path, and includes its own build/package script. MCP creates the project and proposes
the reviewed install; it never enables the result. The app also ships the matching authoring
contract, schemas, and generated catalogue beside that SDK. Scaffolding preserves both under
`Vendor/`, and packaging preserves the complete project under `Source/`, so a later agent can
discover, audit, fork, and rebuild the extension offline. App embedding excludes local `.build`
and `Build` artifacts; the SDK snapshot is source and contract, not a recursively bundled
development output.

This flow is also where the dogfooding evidence above will actually come from: real users
hitting real gaps, rather than us guessing which three extensions to write.

### 3b. Composable UI hooks

The first general wrapper seam now follows the same model as an around hook in a swizzle
library, but keeps the value-only safe boundary:

- [x] Add a separate `hook` contribution alongside existing exclusive replacements.
- [x] Represent the next implementation as `.proceed`, with contract-controlled cardinality.
- [x] Compose all enabled hooks in deterministic extension order.
- [x] Keep process generation/provenance on every hook and reconnect the chain on revocation.
- [x] Add generic stack and overlay composition around `.proceed`.
- [x] Publish `application.main-window@1` without exposing its AppKit hierarchy.
- [x] Add capability-gated custom Metal fragment surfaces hosted entirely by Threading.
- [x] Add bounded semantic host signals, initially active-account usage remaining.
- [x] Copy project `Resources/` into source-bundled packages.
- [x] Add install-time GPU-source disclosure and public authoring documentation.
- [x] Implement Usage Rain as an example extension rather than an app-specific feature.
- [x] Cover hook validation, ordering, generation revocation and Metal capability enforcement in
  tests.
- [ ] Build Usage Rain with a compatible Swift.org WebAssembly toolchain, import it disabled,
  approve/enable it, and inspect the live full-window composition.
- [ ] Repeat the live pass with two wrappers enabled, then disable each in both orders and verify
  that the original window remains mounted and interactive.

Do not turn this into arbitrary method swizzling. New hook points are versioned component
contracts with explicit node vocabularies, host-owned behavior and proceed rules. A future
contract may allow true replacement, but `application.main-window@1` deliberately requires
exactly one `.proceed`.

Likely additions, only when demanded:

- more documented component anchors;
- richer panel nodes such as progress, lists, tables, or form-like presentation;
- interactive component slots with preserved contribution provenance;
- narrower transcript, workspace, file, build, or host-asset APIs;
- durable large-file storage distinct from reclaimable cache.

Avoid exposing raw model objects, paths, arbitrary filesystem reads, view handles, or a universal
runtime-injection API.

### 4. Advanced companion superset

The power tier is now an **out-of-process companion superset**, not an in-process native plug-in.
Every advanced package keeps a WebAssembly core and uses the same settings, commands, menus,
hooks, panels, MCP tools, storage, services, and host-data capabilities as a lightweight
extension. It adds a separately identified macOS `.app` only for work which genuinely needs
OS authority. Custom UI still enters Threading as semantic nodes, a future bounded web surface, or
a bounded remote surface; the companion never hands the host an `NSView`.

The manifest and approval foundation is implemented:

- [x] Add an optional `companions` array without changing ordinary Wasm manifests.
- [x] Derive each companion's stable bundle identifier from extension identity and local ID.
- [x] Keep companion OS authority separate from the Wasm core's Threading host capabilities.
- [x] Define granular initial authorities for background lifecycle, process launch, client and
  listener networking, user-selected files, screen capture, input control, Apple Events,
  notifications, clipboard access, and remote surfaces.
- [x] Inspect the nested `.app`, bounded `Info.plist`, derived bundle identifier, and executable
  path without executing code.
- [x] Require a valid code signature, hardened runtime, App Sandbox, and exact agreement between
  the reviewed capability list and signed network/file/Apple-Events entitlements. Unknown
  `com.apple.security.*` entitlements fail closed.
- [x] Surface companions and their authorities in install review and Extensions settings.
- [x] Treat a new companion, new OS authority, or on-demand → while-enabled transition as an
  update permission widening.
- [x] Fail closed before the companion supervisor exists; declaration support must never look
  like execution support.
- [x] Pin the inspected designated code requirement for the installed generation and re-check
  that requirement, the signature, hardened runtime, sandbox, and entitlements immediately
  before every launch.
- [ ] Define distribution author trust/PKI above the exact installed-signature pin. Ad-hoc local
  development remains intentionally possible but is not marketplace author identity.
- [x] Implement the supervised companion lifecycle: bounded generation handshake,
  `whileExtensionEnabled`, host-owned `onDemand` activation, crash reporting, graceful shutdown
  with escalation, and generation revocation across disable/reload/update/core failure.
- [x] Add a duplex control channel between the Wasm control plane and its worker without giving
  the companion the core's bearer token or implicit host-data authority. Operations are
  manifest-declared, require `companions.invoke`, are addressed only within the authenticated
  extension, use bounded generation-bound request/response envelopes, and activate on-demand
  workers through the lifecycle manager.
- [x] Add a high-throughput remote-surface data plane: bounded frames into a host-owned view,
  normalized pointer/keyboard events out, backpressure, visibility, accessibility fallback, and
  immediate teardown on revocation.
- [x] Broker interactive Screen Recording and Accessibility grants from the host before spawn.
  Measurement showed that macOS attributes these TCC services to Threading for a directly
  supervised child even though App Sandbox entitlements remain scoped to the companion. Missing
  grants now fail closed with the correct System Settings target.
- [x] Preserve the companion's final stderr diagnostic across the stdout-EOF/process-exit race
  and make writes to a worker that exited between validation and send immune to SIGPIPE.
- [ ] Add a sandboxed web/canvas panel body as the middle tier between semantic nodes and pixels.
- [x] Complete the live proof with the integrated Simulator extension composed from process,
  capture, input, and remote-surface capabilities—no Simulator-specific extension API. The
  standalone source project builds a real Wasm core plus a hardened, sandboxed, signed companion
  and retains its vendored SDK. The production-boundary test now launches the real package and
  reports the correct Screen Recording grant target. Verified on 2026-07-26 with a
  development-signed Threading granted Screen Recording and Accessibility: the test received and
  acknowledged a non-solid 305×700 live Simulator frame, wrote its PNG, relayed normalized
  input, and observed the worker remaining healthy.
- [ ] Then exercise the same primitives with an HTTP proxy and a Claudex-shaped background
  extension.

Do not add an `advanced.full-access` capability. Authority remains opt-in per worker and does not
flow across the companion/Wasm boundary. Do not revive direct in-process AppKit loading: a
separately supervised process is the crash and permission boundary this tier exists to provide.

## Recommended next sequence

1. ~~Audit the current worktree and rerun the verification baseline.~~
2. ~~Write the XPC runner design note.~~
3. ~~Add a launch abstraction without changing runtime behavior.~~
4. ~~Move the host broker onto an inherited descriptor, then storage onto the broker.~~
5. ~~Implement and test the signed runner, with the denial probe.~~ Both done, and the design
   changed on evidence along the way: an exec-in-place helper replaced the XPC service.
6. ~~Build package/update tooling.~~ Packager, update plan, update orchestration,
   capability-delta approval, and host-authored local/unsigned provenance are done — see §2.
7. ~~**Block direct legacy-Keychain authorization prompts** at the runner boundary and prove it
   with an adversarial probe that does not voluntarily disable UI.~~ Done for the product
   Seatbelt policy; the prompt-capable App Sandbox helper is no longer selectable.
8. ~~**Finish the Hello Status product pass** through the hardened product policy.~~ Done:
   installation, publications, settings, KV/cache/secrets, shortcut/command, MCP tools,
   cross-extension services, update, lifecycle recovery, and a clean visual/log pass are proven
   live.
9. ~~**Choose a non-deprecated long-term runner.**~~ Done: WebAssembly/WasmKit, with the native
   runner retained only for format-1 compatibility.
10. ~~Dogfood real extensions and the authoring flow.~~ Done through Hello Status/Consumer and
    the official-toolchain scaffold → package → install → signed-runner test.
11. Add only the component anchors and semantic nodes proven necessary.
12. ~~Freeze and document the safe extension API as v1.~~ Done in `API_V1.md` and
    `ThreadingExtensionAPI`.
13. ~~Finish the live Simulator permission/frame/input pass in §4.~~ Verified with the real
    package and a development-signed Threading: permission brokering, frame acknowledgement,
    normalized input, and worker health all passed. Next use the same primitives for the proxy
    and Claudex-shaped cases.

The **safe extension v1 checklist is complete**. Broader marketplace distribution remains a
separate product phase: author identity/signing, discovery, delivery, and update feeds are not
part of local source-bundled v1 and do not weaken its containment.

Two things are deliberately *not* claimed. The old prompt-capable App Sandbox helper is not a
product policy, and `network.client` is not a safe WebAssembly v1 capability. A bounded future
network broker and an optional watched development install require separate designs.
