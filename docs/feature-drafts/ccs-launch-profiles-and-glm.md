# CCS launch profiles and GLM

> Status: feature draft — researched and implementation-ready for the CCS account-profile
> slice after the persistence downgrade guard below is in place. CCS API profiles, including
> GLM, require upstream redacted metadata for any support; Native Chat additionally requires the
> settings-overlay gate below. Terminal-only and Native support must be labelled separately.

## Decision

Threading should integrate CCS, but **CCS is a launch-profile router, not an account store**, and
**GLM is an inference provider/model behind the Claude Code-compatible runtime, not a new
`AgentKind`**.

The product should therefore:

1. detect the `ccs` executable during onboarding without running it, then ask before invoking CCS
   to discover profiles;
2. keep direct Claude accounts available alongside CCS profiles;
3. pin the exact CCS profile and its observed transcript/history lane to every session;
4. launch that session through `ccs <profile> ...` on every start and resume;
5. derive effective features, model presentation, usage, and billing from both the Claude runtime
   and the chosen route;
6. fail closed if the profile disappears or its history lane changes; and
7. ship CCS account profiles first, then terminal-only GLM/API profiles after redacted discovery
   exists, and Native Chat only after settings composition is proven.

This answers the first-launch question with slightly different copy from “use the account
configured in CCS?” CCS can hold several account, API, composite, and CLIProxy profiles. Asking
about one implicit account would hide the choice that determines credentials, billing, models,
and conversation continuity.

## User problem

A person who already uses CCS expects Threading to launch the same identities and providers they
use at the command line. Today Threading discovers Claude config directories directly and always
executes `claude`. It cannot select a CCS-only profile such as GLM, and a session created through
an ambient Z.ai configuration may work while being mislabeled and attributed as Anthropic.

The desired experience is:

- first run notices CCS, asks before allowing its normal maintenance/discovery path to run, and
  then offers the profiles it can identify safely;
- choosing `Work` or `GLM` is one identity-menu action, not environment-variable setup;
- CCS and the wrapped CLI continue to own credentials and provider configuration; Threading never
  reads or copies them;
- the choice sticks to the conversation across restarts and surface changes;
- Threading's own remote access still works with a GLM-backed local session; and
- unsupported Claude-specific behavior is absent or explained, never attempted optimistically.

## Terms and invariants

The existing architecture already separates runtimes from model providers. This feature needs two
more explicit concepts, without collapsing any of them:

| Concept | Example | Owns |
| --- | --- | --- |
| Runtime | `AgentKind.claude` | CLI grammar, session protocol, transcript format |
| Account identity | direct Claude login, CCS `work` | whose quota/credentials are used |
| History lane | `~/.claude/projects`, a CCS shared context group | where transcripts live |
| Launch route | direct, CCS profile `glm` | executable/wrapper and the exact profile selected |
| Inference/billing origin | Anthropic, Z.ai | model family, quota, price attribution |

Load-bearing invariants:

- Do not add `.glm` or `.ccs` to `AgentKind`.
- Do not treat an API profile as an `AgentAccount`; it may reuse the default Claude history lane
  while changing only endpoint, credential, model, and biller.
- Do not infer the biller from `AgentKind.claude`.
- Do not copy a CCS token, API key, or settings payload into Threading state.
- A session stores an exact route, never a mutable “current/default CCS profile.”
- Resume uses the same route **and** the same history lane as the first launch.
- A missing or changed route is an actionable launch error, never a fallback to direct Claude or
  another CCS profile.
- A changed biller/target is a changed data destination and blocks until the user explicitly
  rebinds the session, even if the profile name and history lane stayed the same.
- Direct sessions from older Threading builds continue to decode as direct **only when the route
  key is absent**. A present unknown/corrupt route refuses the authoritative row; it never decodes
  as direct.

## Research snapshot

Research was checked on 2026-08-09 against CCS 8.9.0 source and current documentation:

- [CCS repository](https://github.com/kaitranntt/ccs)
- [CCS configuration](https://docs.ccs.kaitran.ca/getting-started/configuration)
- [CCS file locations](https://docs.ccs.kaitran.ca/reference/file-locations)
- [Z.ai Claude Code integration](https://docs.z.ai/devpack/tool/claude)
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-usage)
- [Claude Code settings](https://code.claude.com/docs/en/settings)

### What CCS actually does

- `ccs <profile> [claude arguments...]` selects a profile and forwards the remaining arguments to
  Claude Code.
- Account profiles isolate the CLI with `CLAUDE_CONFIG_DIR` and have an instance path. CCS may
  also initialize or synchronize that instance before launch.
- Settings/API profiles load a profile settings file and commonly inject it as an initial
  `--settings <path>` argument. Those files can contain `ANTHROPIC_AUTH_TOKEN` and must be treated
  as secrets.
- A settings/API profile may inherit conversation continuity from a CCS account through
  `continuity.inherit_from_account`; otherwise it commonly uses the ordinary Claude lane.
- CCS strips inherited Anthropic routing variables according to profile type before spawning
  Claude. Threading should preserve that wrapper behavior instead of reconstructing it.
- `ccs auth list --json` provides structured, non-secret metadata for account profiles, including
  names, default status, account creation time, context-sharing policy, and instance paths. Its
  top-level `version` is the CCS application version, not a metadata schema version.
- Invoking `ccs auth list --json` is **not read-only in CCS 8.9.0**. Every ordinary CCS command
  enters pre-dispatch auto-migration and recovery before root-command handling; it can normalize or
  recreate CCS-owned configuration. `CCS_NO_PRE_DISPATCH=1` is not an integration escape hatch:
  it also bypasses root-command routing, so `auth list` no longer has its documented meaning.
- `ccs api list` is human-readable today. `ccs env <profile>` exposes shell exports including
  credentials and is not a discovery API. The hidden `__complete` command is not a stable metadata
  contract and mixes profile names with commands.

### What Z.ai provides

Z.ai exposes GLM models through an Anthropic-compatible endpoint configured for Claude Code. That
means Claude remains the runtime: Claude owns the command grammar, stream JSON, session identifier,
and transcript. Z.ai owns inference and billing. Compatibility at the HTTP shape does **not** prove
that every Claude product feature exists behind that endpoint.

### Current Threading seam

- `AgentKind` correctly describes runtimes, not model providers.
- `AgentAccount` and `AgentAccountDiscovery` model config-directory logins.
- `AgentLauncher` builds direct `claude` commands and `AgentAccountRouting` prefixes the runtime's
  `accountEnvironmentKey` (`CLAUDE_CONFIG_DIR` for Claude) — and deliberately `env -u`s that key for
  the default account, because Threading itself may inherit an exported alternate home.
- `AgentSession.accountHandle` approximates account and history lane for direct profiles, but CCS
  shared context groups prove those are different axes; no session field pins a launch wrapper.
- `AgentAccountDiscovery.account(for:handle:)` currently falls back to a preferred/default account
  when an exact handle is missing. A routed launch must not pass through that behavior, and this
  feature should replace launch-time account lookup with a typed exact/missing result for direct
  non-default accounts too. The exact lookup must still search disabled logins, as the current code
  deliberately does: a resume has to route back to the account that owns its conversation.
- Both Claude launch paths append a per-session `--settings` hooks file written by
  `MCPSessionRegistry.writeHookSettings` — terminal sessions carry lifecycle/status hooks only,
  and Native Chat additionally brokers permissions through it.
- the composer chooses runtime plus account as one `ComposerIdentity` (currently `private` to
  `SessionComposerViewController`; carrying a route means promoting or replacing it).
- runtime capabilities currently assume direct provider behavior in several places: Claude Remote
  Control, Fast, model aliases, live account usage, the usage-window poke launch, and usage
  attribution.
- `UsageOrigin` already has the correct shape: runtime and billing provider are separate.

## Product contract

### Onboarding

The existing **Accounts** onboarding page (`OnboardingDiscoveryPageViewController`) first performs
**only** a login-shell `command -v ccs` probe beside the `AgentCLIProbe` checks it already runs for
the agent CLIs, with a short timeout and generation guard. It must not run `ccs`, inspect
`~/.ccs`, delay opening the page, or block completion of onboarding.

When `ccs` is executable and consent is still undecided, show one fixed-size card:

> **CCS detected**
> Let Threading ask CCS for your profile list? Starting CCS may run its normal configuration
> migration or recovery. Threading does not read profile files or credentials.

Actions:

- **Continue with CCS** — records consent, then runs the structured profile command off-main;
- **Not Now** — runs no CCS command and records a dismissible choice, not a permanent denial.

After a successful consented discovery, replace the card with a bounded summary naming at most the
first three profiles plus “and N more,” with **Use These Profiles** and **Review Profiles…**. The
full selector uses a value-backed, virtualized table. No result silently enables profiles before
this second action.

If the consented command finds account profiles but cannot safely enumerate API profiles,
onboarding offers only the account profiles and says API/GLM profiles need a newer CCS integration
contract. It does not guess profile names. If discovery fails, the UI distinguishes unsupported
CCS version, malformed/incomplete output, timeout, and no configured account profiles; none is
presented as “no profiles.”

This prompt does not replace direct accounts. It adds CCS-backed choices and can be changed later
under Settings -> Accounts. Persist the consent/decline through `PreferenceStore`, not
`UserDefaults.standard`; Settings exposes **Use CCS profiles** and **Forget CCS access**. Forgetting
stops discovery and clears cached profile metadata, but retains the minimal binding on existing
sessions and asks for consent again before they can launch.

### Composer and Settings

The identity control remains one decision, but the existing `ThemedMenu` is an eager retained-row
surface and cannot own an unbounded CCS collection. Keep direct identities and a bounded recent
CCS set in the chip menu, followed by **Choose CCS Profile…**; that action opens a searchable,
value-backed virtualized chooser built from the `UI/Design` primitives (`ThemedSearchField`,
`ThemedTableView`, `ThemedVirtualTableCell`), modeled on `ScheduledFinishPickerViewController`'s
off-main search over a value model — no ready-made chooser component exists in `UI/Design` today.
A choice still resolves to one combined execution identity. Example rows:

- `Claude Code · Default` — direct;
- `Claude Code · Work via CCS` — CCS account profile;
- `Claude Code · GLM via CCS` — CCS API profile, biller Z.ai.

The represented value becomes runtime + account/history lane + launch route. Selecting a different
row resets model, effort, Fast, and Claude Remote Control to values allowed by the new effective
capability set. It must not carry a Claude alias such as `opus` into a GLM profile.

Settings lists profiles with route type, provider when known, and precise discovery state. The
current account JSON proves configuration, not authentication/provider health, so it must say
**Configured** rather than **Ready** until a launch proves more. Its controls only enable/disable
profiles for new Threading work. Creating, editing, authenticating, renaming, and deleting profiles
remain CCS operations. Initially **Manage in CCS…** shows copyable, documented CCS instructions;
Threading never edits `~/.ccs` directly or starts a management command without a separate user
action.

### Starting and resuming

For a direct route, behavior is byte-for-byte the existing launch path.

For a CCS route, Threading launches the wrapper with the exact persisted profile:

```text
ccs <persisted-profile-name> <the Claude arguments Threading already builds>
```

The wrapper is resolved through the login shell. Each argument still passes through
`ShellCommand`'s quoting — the profile name as an appended word, the prompt as the single trailing
operand — never as interpolated shell fragments.

Before a resumable session starts, Threading refreshes redacted metadata for that exact profile:

- missing/renamed profile: block with “CCS profile ‘X’ is no longer available”;
- removed and recreated profile with the same name but a different creation/binding epoch: block;
- different target/runtime: block;
- different billing provider/data destination: block and require explicit rebinding;
- different effective history lane: block and explain that resuming from the new lane would not
  find the same conversation;
- credential/provider health failure reported by CCS at launch: show the wrapper's sanitized
  failure and preserve the dormant session;
- no condition silently selects CCS's current default or direct Claude.

Changing a session's route is a migration, not an edit. It is only enabled when Threading can prove
the destination history lane already contains the transcript or can perform the existing
non-destructive transcript copy. Moving between billers must name that consequence explicitly.

An account profile's first launch may lazily create its instance and shared-context symlinks. A
fresh session stores a provisional lane from consented metadata; after the wrapper has initialized,
Threading resolves the actual `projects` transcript root, persists its canonical lane binding, and
only then treats the session as resumable. A resumable session with an unavailable/unconfirmed lane
blocks instead of letting CCS create a new empty lane under the same name.

### GLM behavior

The first supported GLM experience should be conservative:

- runtime label remains Claude Code;
- route/provider subtitle says `GLM via CCS` / `Z.ai`;
- model selection initially offers **Profile Default** only;
- the actual model reported by Claude's init/transcript stream may be displayed as observed state,
  but must not be written back as a launch override unless CCS publishes a compatible catalog;
- Z.ai usage is not represented as Anthropic plan usage;
- cost remains unpriced unless Z.ai reports a cost or an exact model/version has an authoritative,
  versioned price source;
- Claude vendor Remote Control and Claude Fast are unavailable unless the route explicitly proves
  them; and
- Threading Remote Access remains available because it controls the local Threading session and
  is independent of Claude's vendor bridge.

### Failure and recovery UX

Failures should preserve the distinction between installation, profile, and provider:

- `ccs` missing: “CCS is no longer on your login-shell PATH.”
- profile missing: “The CCS profile ‘GLM’ was renamed or removed.”
- history lane changed: “This profile now uses a different Claude history location.”
- provider rejected credentials: preserve CCS's concise error after redaction.
- unsupported Native Chat: offer **Open in Claude Code UI** for the same session/route, not a
  direct-provider fallback.

The row remains visible and resolvable even when its route is disabled for new work, matching the
existing rule for disabled accounts.

## Architecture

### Persisted route model

Add a provider-neutral launch route to `AgentSession`:

```swift
enum AgentLaunchRoute: Codable, Equatable, Hashable, Sendable {
    case direct
    case ccs(CCSProfileBinding)
}

struct CCSProfileBinding: Codable, Equatable, Hashable, Sendable {
    let profileID: ExternalLaunchProfileID?
    let invocationName: String
    let lastKnownDisplayName: String
    let profileType: CCSProfileType
    let target: AgentKind
    let billingProvider: BillingProviderIdentity?
    let bindingEpoch: String?
    let continuityLane: HistoryLaneBinding
}
```

`HistoryLaneBinding` is not an account. It carries a stable redacted lane identifier, its
provisional/confirmed state, and enough private local path metadata for `SessionTranscript` to
resolve the transcript. Identity is the canonical **transcript root** (`projects` after resolving
CCS context-group symlinks), not merely the instance/config directory. The identifier should come
from CCS's structured inspection contract. For the account slice, derive a provisional identity
from the allowlisted context policy, then confirm the canonical root after CCS initializes it. Store
the path locally for offline replay, but never place it in wire DTOs or diagnostics.

`profileID` is nil for the current account-only contract, where the invocation name and account
record's `created` value form the best available binding. The future CCS schema should provide a
stable profile ID plus a non-secret semantic routing revision. Credential rotation must not look
like a new route, while delete/recreate, target change, biller change, or data-destination change
must. If `created` is absent, a name that disappears and later reappears is ambiguous and requires
explicit rebinding. A profile rename does not rewrite existing sessions automatically.

`AgentSession.accountHandle` remains the direct-account key for compatibility, not the new source
of truth for transcript location:

- a CCS account profile resolves to a namespaced account handle backed by its instance path;
- an API profile using ordinary continuity resolves to `.standard`;
- an API profile inheriting from a CCS account resolves to that CCS account handle.

The launch route stays separate even when two identities resolve to the same lane. CCS account
profiles in one shared context group can share a canonical transcript root while using different
credentials; direct Claude and GLM can likewise share `~/.claude/projects`. Resume pins both axes.

Store the route alongside the provider-neutral fields on `AgentSession`, and thread it beside
`AgentSessionConfiguration` through every construction path: composer, scheduled start, side chat,
import when known, continuation, and the remote start used by paired devices (one path, not two),
plus the wire DTOs that carry it. Forks inherit the parent's route. A new continuation chooses its
destination route explicitly.

Adding an optional/defaulted field to `AgentSession` costs no `ProjectsStateVersion` migration in
the current SQLite thin-row/JSON-payload architecture; the legacy document version remains 2 and an
absent route decodes as `.direct` — through `AgentSession`'s hand-written `CodingKeys`,
`init(from:)`, and `encode(to:)`, all three of which change together, and past its decoder's
cross-field invariants, which throw into the all-or-nothing load, so the strictness of route
validation there is a deliberate choice, not a free default. Merely bumping that legacy number
would not protect the live database, and merely increasing SQLite `user_version` (currently 3) is
also insufficient because `SQLiteDatabase.migrate(to:step:)` returns without error when the on-disk
version is newer.

Downgrade safety therefore needs an explicit database design before any routed session can ship:

- add schema v4 with a `routed_session` table mirroring the indexed session columns and JSON
  payload; routed sessions live only there, while direct sessions remain in `session`. Do not give
  the new table the current `session` table's project cascade (`ON DELETE CASCADE`): a downgraded
  build deleting what looks like an empty project must not silently delete the routed rows it
  cannot display. Without a cascade the table also has no reaper, so pair it with an explicit
  retain/prune pass the way the auxiliary tables do;
- load/save the two tables as one model graph, reject duplicate IDs across them, and move a row
  transactionally if an explicit migration changes route class;
- a pre-route build sees no routed row and therefore cannot launch it as direct, while leaving the
  unknown table untouched during ordinary saves;
- also change `SQLiteDatabase.migrate(to:step:)` to refuse future `user_version` values for
  protection from the next schema change, without pretending that change retroactively protects old
  builds;
- have the new reader surface an orphaned routed row for recovery rather than pruning it. That is a
  new disposition for copy-of-record data — today an orphaned session row fails the load and
  quarantines the whole store, and per-row tolerance exists only for auxiliary tables — so it must
  be designed and tested as such. Test delete, reorder/save, quarantine, orphan recovery, and
  downgrade-reader behavior against a v4 fixture.

Remote compatibility is separate. Add optional route/profile IDs and display metadata to wire DTOs
without local paths or secrets. Old clients omit the selection and can create only `.direct`. The
host already authorizes every session-management request server-side, per message; route and
surface admission must be enforced at that same boundary — today's `RemoteCapability` is only
`view`/`interact` and no reroute request exists, so both checks are new host work, not existing
behavior. Per the releasing checklist (`docs/architecture/releasing.md`, pinned by
`RemoteProtocolTests`), an additive DTO change does not itself bump `RemoteProtocol.current`; bump
it only if implementation proves the wire change breaking.

### Discovery boundary

Add `CCSProfileDiscovery`, separate from `AgentAccountDiscovery`:

```swift
struct ExternalLaunchProfile: Sendable, Identifiable {
    let id: ExternalLaunchProfileID
    let displayName: String
    let route: AgentLaunchRoute
    let historyLane: HistoryLaneBinding
    let associatedAccount: AgentAccount?
    let state: ExternalProfileState
}
```

An API profile can work without a directly discovered `AgentAccount`, so the association is
optional. Consumers ask a route-aware history-lane resolver and quota-subject resolver rather than
manufacturing an account solely to carry a path.

The service:

- resolves `ccs` with the login shell;
- invokes CCS only after recorded consent, using documented, structured, redacted commands;
- enforces a timeout, output-byte cap, profile-count stress fixture, and cancellation;
- parses off the main actor and publishes immutable values on the main actor;
- represents `notAuthorized`, `loading`, `valid`, `unsupportedVersion`, `incomplete`, and `failed`
  separately, preserving a last-known-good snapshot as stale on refresh failure;
- caches briefly and invalidates after Settings asks CCS to manage profiles, but never converts an
  error or oversized result into an empty inventory;
- treats malformed records independently so one bad profile does not erase valid siblings; and
- logs only command/version, counts, duration, exit category, profile type, and redacted IDs.

For the first slice, `ccs auth list --json` is the admissible source for account profiles **after
consent**. It has no schema-version field, so gate it by an explicitly tested CCS semantic-version
range, require a pure JSON document, decode only allowlisted fields, and treat pre-dispatch banners
or mixed output as incomplete rather than scraping a JSON substring. Its normal migration/recovery
side effects are covered by the consent copy; do not auto-retry a command that may just have changed
configuration. A user-driven refresh can run it again. Do not:

- invoke `ccs env`;
- read `*.settings.json`;
- parse credentials and then promise to discard them;
- parse ANSI/human tables from `ccs api list`;
- rely on `__complete` as a production schema;
- set `CCS_NO_PRE_DISPATCH=1` and assume root commands still route normally; or
- call `auth show --json` per row during discovery (it walks history/settings diagnostics and would
  turn one refresh into N filesystem scans).

Add a small upstream CCS request for a command such as:

```text
ccs profile list --json --redacted
ccs profile inspect <name> --json --redacted
```

The minimum schema is: schema version, stable profile ID, invocable profile operand, name, profile
type, target runtime, enabled/default status, billing-provider ID/display name, model-family hints,
effective transcript-lane ID/path, a non-secret semantic routing revision, settings-layer behavior,
supported wrapper surfaces, and whether invocation may perform maintenance. It must never return a
token, key, authorization header, or arbitrary environment value. Prefer an integration flag whose
metadata operation is guaranteed read-only and machine-clean; until CCS provides one, Threading's
consent wording and strict failure state remain mandatory.

Threading accepts only known schema versions and profile types. Unknowns remain visible as
unsupported, not coerced into settings/API profiles. Validate profile operands against the grammar
the reported CCS version guarantees; shell quoting prevents injection but cannot make a
dash-leading name stop being a CLI flag. Strip/control-render bidirectional, ANSI, newline, and
other control characters from all external display/error strings and cap their lengths.

### Launch composition

Introduce one `AgentLaunchRouting` seam after the runtime-specific invocation is built. Account
routing and wrapper routing are mutually exclusive outcomes, not serial prefixes:

```text
runtime invocation -> direct exact-account routing OR exact CCS wrapper -> host hook env -> login shell/process plan
```

- `.direct` continues through `AgentAccountRouting`, except that a persisted non-default account
  now requires an exact lookup; missing no longer falls back to the preferred/default login.
- `.ccs` does **not** also prefix `CLAUDE_CONFIG_DIR`; CCS is authoritative for profile setup. The
  observed lane is for transcript resolution and drift detection, not a second source of launch
  environment. Whether the wrapper must still be shielded from an ambient `CLAUDE_CONFIG_DIR` the
  way the direct default path `env -u`s it — or CCS's own inherited-environment scrubbing covers
  it — is a fixture-pinned question, not an assumption.
- the wrapper receives the inner Claude argument vector without a duplicated `claude` executable
  word.
- Threading's hook environment and MCP arguments remain launch-scoped and may be passed through
  only after fixture and real-process verification.
- launch preflight and launch use the same supported CCS-version/operand validation. A stale
  settings-page cache is never sufficient authority for a new process; concurrent/startup launches
  coalesce onto one fresh bounded discovery generation rather than spawning one full profile-list
  process per session.

Do not reconstruct the CCS environment inside Threading. Besides exposing credentials, that would
skip CCS's inherited-environment scrubbing, lazy instance creation, continuity selection, proxy
lifecycle, model mapping, and future compatibility work.

### The settings-layer gate

CCS settings/API profiles currently prepend their own `--settings <profile>` while Threading adds
a per-session `--settings <hooks>` for lifecycle/brokered permissions, Remote Control, Fast, and
status-line overrides. Claude's public CLI documentation presents `--settings` as one option; a
stable merge and precedence contract for two occurrences has not been established. Last-one-wins
behavior would be especially dangerous because it could discard the CCS provider settings and send
the turn to a different endpoint.

Therefore:

- CCS account profiles may proceed to compatibility testing because their account flow does not
  add the API-profile settings layer.
- a CCS API/GLM terminal can be offered experimentally only after the route prevents
  `MCPSessionRegistry` from writing/passing Threading's settings file and disables every feature
  that depends on it; ordinary permission-mode flags may still be tested independently;
- GLM Native Chat is blocked because permission brokering requires Threading's settings/hooks;
- no implementation may concatenate JSON, read and rewrite the CCS settings file, or choose an
  order based on observation alone and call it contractual.

Unblock API/GLM parity through one of:

1. CCS accepts a caller-supplied overlay (`--caller-settings`) and performs a documented safe merge;
2. CCS publishes a launch protocol that accepts structured hook/permission additions without
   disclosing profile secrets; or
3. Claude documents and tests repeatable `--settings` merge/precedence semantics, and CCS commits
   to preserving Threading's trailing argument.

Pin the chosen contract with fake-wrapper argv tests and a real end-to-end test. Until then the UI
must say **Claude Code UI** for GLM rather than offering a Native Chat mode that can silently lose
permission prompts.

### Effective capabilities

`AgentKind.capabilities` remains the static runtime truth. Add route-level facts and intersect them
at the session/identity boundary:

```swift
effective = runtime capabilities constrainedBy route capabilities
```

Audit presentation and launch call sites that currently ask only `kind.supports(...)`. The route
can remove, but not invent, runtime capabilities unless a separate delivery implementation exists.

Initial route rules:

| Feature | Direct Claude | CCS account | CCS API/GLM before overlay contract |
| --- | --- | --- | --- |
| Terminal Claude UI | yes | yes after E2E | experimental yes |
| Native Chat | yes | after stream/hook E2E | no |
| Resume | yes | yes with pinned lane | yes with pinned lane |
| Permissions in terminal | Claude UI | Claude UI | Claude UI |
| Brokered native permissions | yes | after E2E | no |
| Terminal Threading MCP bridge (`--mcp-config`) | yes | after pass-through E2E | after pass-through E2E, without hook claims |
| Side chat/fork | yes | after E2E | no initially |
| Claude Remote Control | yes | only if CCS says native Anthropic | no |
| Threading Remote Access | yes | yes | yes |
| Fast | catalog/transport rules | route/catalog rules | hidden initially |
| Claude subscription usage | yes | native Anthropic account only | never |

Do not persist an externally reported capability bitset as launch authority. Persist only semantic
route facts needed for history/provenance. Current effective capabilities come from Threading's
versioned compatibility registry (CCS version + Claude version + profile type), intersected with
fresh metadata at each launch. Unknown or newly upgraded versions lose optional capabilities until
tested. A refresh never silently adds a persisted override such as Fast or Remote Control.

### Model catalog and observed model

Resolve model options by execution identity, not only `AgentKind`/account:

- direct and native CCS account routes may use the existing Claude catalog after verification;
- a GLM/API route exposes only **Profile Default** until structured metadata publishes valid model
  IDs and compatible effort levels;
- selecting the route clears an incompatible stored model and effort before session creation;
- the init event/transcript's actual model is observational metadata for display and usage;
- observed metadata never becomes a future `--model` argument by accident.

Provider/model hints from CCS are untrusted display/catalog inputs with length and count limits.
They do not grant capabilities.

### Transcript, import, and migration ownership

`SessionTranscript`, `ClaudeTranscript`, `TranscriptReplay`, title/model readers, importer, and
`SessionMigration` must resolve the session's effective account/history lane rather than asking
only the direct account scanner.

- Threading-created sessions are stamped with route and lane at creation.
- Imports from a CCS lane need an explicit route selection when the same transcript directory can
  be used by several billers. Do not infer the route from the transcript's Claude shape.
- A global scan may group candidates by lane once, but must not duplicate a transcript once per
  profile that shares that lane.
- An unknown historical transcript can be imported with route **unassigned** only if the user is
  required to choose a route before first resume.
- route changes use the existing stop/confirm/reopen coordination and preserve the source
  transcript non-destructively.

Profile/lane discovery is background work. Transcript scans remain bounded/cached according to
the existing import and usage-index architecture; adding N profiles must not rescan the same lane N
times.

Introduce a `HistoryLaneResolver` that returns a transcript-root URL and typed availability without
requiring an `AgentAccount`. Resolve/deduplicate the canonical `projects` root before scanning;
CCS shared context groups can make several instance paths point at the same root. Filesystem errors
preserve the last known lane and surface failure rather than becoming an empty transcript list.

### Usage, billing, and quotas

Construct `UsageOrigin` from session route:

- direct Claude and CCS native Anthropic account: runtime `claude`, biller `anthropic`;
- CCS GLM: runtime `claude`, biller `zai`;
- unknown CCS API provider: runtime `claude`, a stable external/unknown biller, never Anthropic by
  default.

The current usage scanner enumerates transcript files per account directory and the Claude adapter
currently stamps them as direct Anthropic before it knows a Threading session. That must change:

- build a bounded map from `(canonical lane ID, transcript ID)` to the persisted route/biller and a
  biller-scoped account identity;
- scan each canonical lane once, then enrich route-neutral parsed records from that map;
- an imported/externally-created transcript in a lane shared by several routes is **unknown biller**
  until the user assigns it; transcript shape or model name is not evidence of destination;
- include the route-classification revision in cache validity (the scan cache already keys on
  `parserID` and a schema version — a natural seam), or cache route-neutral token records, so a
  route assignment/provider correction reclassifies an unchanged file; and
- key account breakdowns by biller-scoped execution identity, not the runtime-scoped `AccountID`
  (runtime + account handle) alone, so direct Anthropic and GLM sharing the standard Claude handle
  do not collapse into a misleading “Default” account row.

The usage ledger may count tokens from the Claude-format transcript for every classified route.
Monetary cost uses `UsageCostSource.providerReported`, `.catalogPriced` only from an exact
versioned provider rate, or `.unpriced` — never Anthropic prices for GLM-shaped token records.

`AccountUsageService` must become route-aware at its caller boundary. It must not read the default
Claude OAuth/Keychain usage and display it beside a GLM session merely because both share
`.standard`. For routes without a quota API, show no pressure ring and an explanatory “Usage not
available from this CCS profile” row. Never ask CCS for secret environment output to implement a
quota fetcher. The usage-window poke is itself a direct `claude` launch
(`AgentLauncher.usageWindowPokeCommand`) with hard-coded account routing; it must be gated by route
the same way and never run for a route whose subscription usage is unavailable.

### Process lifecycle

CCS is expected to remain alive while its spawned Claude child uses inherited stdio, but this is a
measured compatibility requirement rather than an assumption. Both PTY and native process
ownership must be tested with the wrapper in place:

- stdin reaches Claude for stream JSON;
- stdout/stderr framing and startup diagnostics remain parseable;
- wrapper exit status is the Claude/provider exit status;
- interrupt, stop, app quit, crash cleanup, and process-group termination reach wrapper,
  Claude, and descendants;
- no wrapper-owned child/subagent in Threading's process group survives teardown;
- separately managed CCS proxy daemons are neither killed nor adopted by Threading; CCS must
  document their ownership/cleanup, and the integration must distinguish them from leaked children;
- terminal resize/signals remain correct; and
- prompts beginning with `-`, supported profile-name punctuation, large prompts, and attachments
  preserve argument boundaries; non-invocable profile names fail discovery rather than being
  rewritten.

A test fake should emulate a wrapper process and child rather than asserting only the rendered
shell string.

### Security and privacy

The security boundary is simple: Threading can know a profile exists and how to address its
non-secret continuity lane; CCS alone knows how to authenticate it.

- Never store API keys, tokens, settings JSON, or `ccs env` output in projects, SQLite, defaults,
  logs, crash diagnostics, support reports, remote DTOs, clipboard, or test snapshots.
- Allowlist structured metadata fields; do not serialize unknown JSON wholesale.
- Redact profile names from privacy-sensitive logs where current account names are redacted; a
  stable local hash is enough for correlation.
- Cap stdout/stderr captured from discovery and launch failures, and run the existing secret
  redactor before display or logging. Treat CCS output as untrusted even when the exit status is
  zero; sanitize control sequences before it reaches an attributed string or accessibility label.
- Treat paths as private in logs. Resolve symlinks only for lane identity; do not traverse profile
  settings paths. Reject non-absolute or broad roots, derive only the fixed `projects` child from an
  account `instance_path`, and apply the transcript scanner's regular-file/size/count limits after
  canonicalization.
- Threading itself does not read or mutate `~/.ccs`, run CCS repair/update, or authenticate during
  discovery. The consented CCS process may perform its documented pre-dispatch migration/recovery;
  that fact must remain explicit rather than being described as read-only.
- A remote client receives display metadata and route availability, never local executable/config
  paths.

## Scaling gate

CCS profile count is provider data and therefore unbounded. Use these planning values:

| Measure | Expected | Stress |
| --- | ---: | ---: |
| CCS profiles | 1-12 | 1,000 |
| Distinct continuity lanes | 1-6 | 500 |
| Profile metadata output | under 64 KiB | hard cap 2 MiB |
| Discovery frequency | onboarding/settings/manual refresh | burst of 20 invalidations |

Requirements:

- discovery and parsing occur off-main with timeout/cancellation/output caps;
- deduplicate work by continuity-lane ID;
- onboarding materializes at most three summary rows;
- the full Settings/profile chooser virtualizes at the profile row;
- composer keeps only a small bounded recent-profile menu and routes the full collection to the
  virtualized chooser; it never gives 1,000 entries to the eager `ThemedMenu`;
- define a hard parsed-profile count in addition to the 2 MiB byte cap; exceeding either produces
  an incomplete result rather than truncating silently;
- consented/manual/launch refreshes coalesce by generation and update changed values rather than
  rebuilding every retained view; do not add a watcher for secret-bearing CCS files; and
- add stress fixtures that measure discovery parsing and UI first paint at 1,000 profiles.

## Implementation sequence

### 0. Capture and request the external contracts

1. Record CCS 8.9.0 fixtures for `auth list --json`, including first-run auto-migration/recovery,
   mixed-output failure, account launch argv/environment, profile delete/recreate, corrupt config,
   shared context groups, and changed instance path.
2. Open the structured redacted, read-only/machine-clean profile-list/inspect request with CCS.
3. Resolve the settings-overlay contract with CCS/Claude before claiming API Native Chat.
4. Add opt-in manual E2E instructions that use disposable CCS profiles; never commit credentials.

Exit: the account schema is fixture-pinned; API/GLM gates have named owners and tests, not an
assumption embedded in Threading.

### 1. Persist route and continuity identity

Files centered on:

- `Sources/Threading/Models/Project.swift`
- `Sources/Threading/Models/Identifiers.swift`
- `Sources/Threading/Core/Storage/ProjectDatabase.swift`
- `Sources/Threading/Core/Storage/SQLiteDatabase.swift`
- `Sources/Threading/Core/Session/StateManager.swift` (quarantine, the migration chain, and the
  unreadable-row policy live here)
- `Packages/ThreadingRemoteKit/Sources/ThreadingRemoteKit/RemoteWireDTO.swift`
- `Sources/Threading/Core/Session/ProjectStore.swift`

Add route/binding/history-lane/billing-provider types, default-direct decoding, the v4 routed-row
downgrade guard, session-construction propagation, additive remote compatibility, and exact
missing-route errors. Existing payload fixtures must prove absent routes become direct; a simulated
pre-route database reader must not see routed rows.

### 2. Discover CCS account profiles safely

Add executable-only `CCSCLIProbe`, consent-aware `CCSProfileDiscovery`, typed snapshot/cache,
`PreferenceStore` choices, and fixtures beside existing account discovery. Add
`HistoryLaneResolver` rather than forcing every external route into `AgentAccount`; replace
launch-time missing-account fallback with exact resolution.

Tests cover “no CCS process before consent,” supported-version parsing, malformed siblings,
mixed stdout, pre-dispatch mutation disclosure, timeout/cancellation with process-group cleanup,
byte/count caps, last-known-good preservation, duplicate lanes, shared context groups,
delete/recreate, disabled-but-resumable profiles, hostile display text, valid operand punctuation,
and 1,000-profile performance.

### 3. Route terminal launches

Refactor `AgentLauncher` through `AgentLaunchRouting`. First prove direct command snapshots are
unchanged. Then add exact CCS account wrapper plans, safe quoting, login-shell lookup, and fake
wrapper/child lifecycle tests.

Run real opt-in E2E for fresh launch, prompt, exit, resume, interruption, side chat, MCP, model
report, first-launch lane confirmation, account rename/removal/recreation, shared-lane behavior, and
lane/biller drift. Exercise startup relaunch and crash-recovery launches: they keep the exact route,
skip unavailable routes with a typed visible failure, and never bypass CCS as a recovery measure.
Grant only each capability that passes.

### 4. Add onboarding, Settings, and composer selection

Use existing `UI/Design` components, `ThemedAlert` and the registered
`ConfirmationAlert`/`ConfirmationPrompt` flows, localization, keyboard/accessibility contracts, and
the scaling bounds above. Update:

- onboarding discovery page and render/flow tests;
- Accounts settings and profile enablement;
- bounded composer identity menu, virtualized profile chooser, and model-reset behavior;
- session/sidebar tooltips and unavailable-route presentation.

Render under System plus two contrasting themes, with Increase Contrast, Reduce Motion, keyboard
navigation, VoiceOver labels, long localized names, missing CCS, and the three-row onboarding cap.
Put every new unit-test source below `Tests/ThreadingTests`; the filesystem-synchronized target
compiles it automatically.

### 5. Make models, capabilities, usage, and import route-aware

Add effective capability resolution and audit runtime-only checks for route-sensitive features.
Route model catalogs, observed model display, usage origin/pricing/quota UI, route-neutral usage
cache enrichment, transcript resolution, imports, migration, continuation, scheduling, remote
starts, and forks through the persisted route.

Add an architecture lint/test that a routed Claude session cannot reach direct-only usage, Remote
Control, Fast, or model-default code without an effective-route decision.

### 6. Enable GLM/API profiles behind the proven contract

Consume only the versioned redacted CCS metadata schema. The first GLM release is deliberately
terminal-only with Profile Default and no Threading `--settings` layer. Terminal MCP may graduate
separately after `--mcp-config` pass-through E2E because it does not require a second settings file.
Enable Native Chat, brokered permissions, lifecycle hooks, forks, model options, images,
attachments, and live configuration one by one only after the settings-overlay contract and
compatibility matrix pass for the supported CCS and Claude versions.

If the overlay contract remains unavailable, terminal-only GLM is still a useful honest product:
Threading can host the Claude UI and expose its provider-neutral remote access without pretending
to broker Native Chat permissions.

### 7. Documentation and rollout

Move implemented decisions into `docs/architecture/accounts.md`, `sessions.md`,
`native-conversations.md`, `onboarding.md`, `usage-dashboard.md`, and `performance.md`. Update the
product guide with:

- what Threading reads from CCS;
- how to enable/disable profiles;
- why GLM initially uses Profile Default/terminal UI;
- the difference between Threading Remote Access and Claude Remote Control;
- missing-profile/lane-drift recovery; and
- how to revoke Threading's discovery/launch consent, and why existing sessions retain a dormant
  non-secret binding until deleted.

Roll out behind a preference/feature flag. Account profiles graduate first. Terminal-only API/GLM
can graduate after redacted metadata and the terminal supported-version matrix are green; Native
Chat remains unavailable until the overlay contract and Native matrix are green. No background
telemetry should contain profile names; local diagnostics can report counts, types, route version,
and failure category.

## Verification matrix

At minimum, cross these dimensions:

| Dimension | Cases |
| --- | --- |
| Route | direct, CCS account, CCS GLM/API, missing, renamed, delete/recreated, biller changed, lane changed |
| Surface | terminal, Native Chat where admitted, switch terminal <-> native |
| Lifecycle | fresh, exit/resume, app restart, crash cleanup, fork, schedule, import, continuation |
| Configuration | model nil/explicit, effort nil/explicit, permission mode, Fast, Remote Control, MCP/hooks |
| Provider outcome | success, auth refusal, quota refusal, network error, malformed stream, wrapper crash |
| Data lane | standard, isolated CCS instance, shared context group, inherited account, two billers sharing one lane |
| Scale | 0, 1, 12, and 1,000 profiles; 500 distinct lanes |

Required automated layers:

- pure encode/decode default-direct tests, SQLite v4 routed-row tests, and a downgrade-reader fixture;
- discovery parser/process tests with a fake `ccs` executable and zero secrets;
- launch quoting and argv tests;
- wrapper-child stdin/stdout/signal/process-group integration tests;
- capability matrix pairings between claims and delivery;
- transcript/import deduplication by canonical transcript root;
- usage origin, unchanged-file reclassification, ambiguous shared-lane handling, biller-scoped
  account grouping, and “never Anthropic by inference” tests;
- onboarding/composer/settings behavior, render, accessibility, and scaling tests;
- direct-route regression snapshots proving no changed launch lines.

Required manual/opt-in E2E:

- current supported CCS + Claude versions with a disposable CCS account profile;
- a real Z.ai GLM profile without recording credentials;
- fresh turn and resume on both surfaces admitted by the matrix;
- tool permission allow/deny, MCP call, subagent, interrupt, large/multiline/dash-leading prompt,
  image/attachment, and provider refusal;
- change the CCS continuity mapping and prove Threading blocks rather than losing or rerouting the
  conversation;
- remove CCS from PATH and rename/remove the profile;
- use Threading Remote Access from a paired device against terminal-only GLM.

## Rejected alternatives

- **Add `AgentKind.glm`.** Wrong abstraction: the process and transcript remain Claude Code. It
  would duplicate a runtime merely to name its backend.
- **Treat every CCS profile as an account.** API profiles can share one transcript lane while
  changing provider/billing; account identity cannot represent that.
- **Import CCS environment variables.** It copies secrets, freezes mutable config, and bypasses
  the wrapper behavior the user chose CCS for.
- **Read `*.settings.json` but discard secret fields.** Reading a secret-bearing file is
  unnecessary when the owning tool can expose an allowlisted redacted schema.
- **Parse `ccs api list` or `__complete`.** Human/hidden output is not a versioned integration
  contract and cannot safely answer provider, lane, or capabilities.
- **Follow the CCS default on each launch.** A changed default would resume one conversation
  through a different account or biller.
- **Fall back to direct Claude.** That can spend the wrong account, expose data to the wrong
  provider, and fail to find the transcript.
- **Show Claude model aliases for GLM.** A runtime-shaped alias is not a provider catalog.
- **Enable Native Chat because stream JSON appears to work.** Permission brokering and settings
  composition are load-bearing; a successful text turn proves neither.
- **Hide missing profiles.** Existing sessions must remain recoverable and explain why they cannot
  launch, like disabled accounts.
- **Run `ccs auth list` merely because `command -v ccs` succeeded.** In 8.9.0 that can migrate or
  recover CCS configuration; only an explicit consent action authorizes the process invocation.
- **Protect downgrade launches with `ProjectsStateVersion` alone.** The live store is SQLite and
  session fields are JSON payload additions. Routed rows need to be invisible to the immediately
  preceding reader, not merely defaulted by the new decoder.

## Acceptance criteria

The CCS account-profile slice is complete when:

- first-run executable detection is non-blocking and runs no CCS process before consent; the choice
  is dismissible and available later in Settings;
- Threading never reads, copies, persists, logs, or sends profile credentials; CCS and the wrapped
  CLI retain their existing ownership;
- a user can select a CCS account profile in one composer action;
- every session persists its exact route and continuity lane;
- fresh launch and resume go through that exact profile;
- route removal and lane drift fail closed with recovery guidance;
- direct Claude behavior and launch snapshots are unchanged;
- route-aware capabilities prevent unsupported controls/actions;
- the full profile UI satisfies the 1,000-profile scaling fixture; and
- SQLite routed-row isolation prevents the preceding Mac build from launching a routed session as
  direct, and stale remote clients cannot request a route/surface the current host has not admitted.

GLM support graduates from Experimental when, in addition:

- CCS provides versioned redacted provider/lane metadata;
- the per-session settings-overlay contract is documented and pinned, or the product remains
  explicitly terminal-only;
- model UI never offers unverified Claude aliases;
- usage is attributed to Z.ai and never priced/read as Anthropic by inference;
- the admitted surface/capability matrix passes real GLM E2E; and
- Threading Remote Access works without claiming Claude Remote Control support.

## Deferred follow-ons

- A “Change provider” action between profiles sharing one history lane is deferred. It changes the
  billing/data destination and must not be mistaken for an account rename; the foundation exposes
  an explicit migration seam but no one-click action.
- **Manage in CCS…** initially shows copyable instructions. Opening an embedded terminal command is
  a later convenience with a larger side-effect and process-lifecycle surface.
