# Feature drafts

This directory holds researched product and architecture proposals that are worth preserving but
are not committed implementation work yet.

A draft is a parking place, not a promise or a second architecture source of truth. It should:

- describe the user problem and the intended product contract;
- record relevant research and rejected alternatives;
- identify the existing architecture it would extend;
- state important scope boundaries, risks, tests, and rollout steps;
- remain clearly marked as a draft until implementation begins.

When work starts, re-check the draft against the current code and the relevant files in
`docs/architecture/`. Move any durable decisions into those architecture documents as part of the
implementation. When the feature ships or is abandoned, remove the draft or replace it with a
short pointer to the durable record so this directory does not become a competing specification.

**A draft is not a decision record.** Everything here is something somebody intends to build.
An idea investigated to the point of *no*, *not yet*, or *only this much* belongs in
[`docs/decisions/`](../decisions/README.md) instead, with its recommendation and the evidence that
should reopen it. A draft that turns out to be a bad idea moves there rather than being deleted —
the investigation is the value, and an idea deleted without a record comes back.

## Drafts, by priority

The grouping below is the priority statement, kept here and nowhere else — each draft's own
status line stays authoritative for what gates it, and a priority is intent, not a promise.
The tier boundaries are the durable part; the order inside a tier is a proposal, and
reshuffling it is a line move.

### Now — in active design

- [Usage-aware accounts](usage-aware-accounts.md) — tell an agent what its budget is, let the user
  rank which logins may be spent automatically, move work to the next best one before a
  weekly window strands it, and keep a drained fleet's anchored windows cycling at reset. It is
  first because the drafts either side of it finished: the user's own line exists
  ([limit management](limit-management.md)), and a manager grant can now carry a `SpendCeiling`
  that refuses delegated spend at it — so a session can be stopped at a ceiling it still cannot
  see. **The pushed reading (A) is the cheap first slice** and the missing half of that: it is
  what lets an agent stop gracefully before a ceiling refuses it abruptly, and it rides channels
  that already reach every session — `MCPToolCatalog.instructions(for:)` for the opening state,
  and the settle edge `AccountUsageService` already observes for updates. Its account order (B1)
  is the consent the automatic move depends on and must ship before it; the reset keep-alive's
  Claude half (B5) can ship ahead of the rest.
### Next — researched and ready, waiting for a slot

- [Remote execution hosts](remote-execution-hosts.md) — run a session's agent on a Linux machine
  the person owns (a Pi, a VPS, a workstation) by running `threading-ptyd` there and reaching it
  over SSH, with the Mac still the authority for every surface. Slice 1 — the daemon building as a
  static Linux binary and passing its own suite there through `scripts/test-ptyd-linux.sh` — is
  done on arm64 and x86_64; host profiles, the `ExecutionHost` model and hooks over a reverse forward follow.
- [Universal Search](universal-search.md) — make `Command-F` a host-owned Search capability with
  visible View, Project and Everywhere scopes; reuse the real Browser, Git Review and SwiftTerm
  engines; add incremental FTS5 conversation history with exact bounded-window landing; and expose
  only natively navigable results to the paired iPhone through a bounded owner-only remote
  contract. The semantic plan, remote iOS result matrix, scaling gate and delivery slices are
  concrete; implementation has not started.
- [Observed work for terminal sessions](observed-work-for-terminal-sessions.md) — feed the Activity
  tab from the transcript, export and git checkpoint a session already leaves behind, so a chat
  Threading does not render itself stops reporting zeros over a full repository atlas. **The
  transcript feed shipped 2026-08-14; the git-observed floor, the exact/observed provenance split
  and the honest empty state shipped 2026-08-17**, with the durable decisions in
  [`mcp-and-display.md`](../architecture/mcp-and-display.md). Only the OpenCode/Grok export feed
  remains, and it is blocked on a measurement rather than on work: neither CLI is installed here.
  It moves down this list because the floor already gives those two runtimes a reading.
- [Conversation forks and quick asides](conversation-forks-and-quick-asides.md) — separate the
  current durable Claude fork from a true temporary side question, add persistent forks for
  Codex, Grok and OpenCode, and add native read-only asides for Codex and Grok first. High-frequency
  session workflow with direct upstream operations; Claude native aside remains a measured later
  slice rather than blocking the ready paths.
- [Browser Focus](browser-focus.md) — let the live browser fill the main window while retaining a
  compact, live conversation dock. Implementation-ready and self-contained.
- [Glanceable iOS surfaces](ios-glanceable-surfaces.md) — put Usage and a running session on the
  Lock Screen, the Home Screen and the Dynamic Island. The 2026-09-08 review prioritizes Usage
  widgets, then one followed agent's Live Activity with status and an optional completion preview.
  One extension shares a bounded app-group usage snapshot; ActivityKit uses a separate push path.
  The capacity feed preserves observation time and settled-reading updates outside the Usage
  sheet. The plan covers independent widget
  configuration, Live Activity freshness and ordering, and the data-acquisition requirement behind
  iOS 26 push reloads. The first usage extension, capacity endpoint and shared cache are implemented;
  visual acceptance and ActivityKit remain pending. Design spikes use the installed extension. Sessions
  widgets and inline permission decisions remain independent follow-ups.
- [CCS launch profiles and GLM](ccs-launch-profiles-and-glm.md) — adopt CCS-managed launch
  profiles without importing credentials, with route-safe account support and a gated GLM path.
  The account-profile slice is ready once its persistence downgrade guard lands; the API/GLM
  slices wait on upstream redacted metadata.
- [Analytics and crash reporting](analytics.md) — answer counterfactual engineering questions
  (the activation-prewarm pool question) and feature-usage/failure reality with Go-shaped
  local-first counters: on-device aggregation, upload strictly by consent, no stable
  identifiers, a published and build-gated schema, browsable reports, first-party ingest on the
  existing control plane, and ask-at-the-moment crash reporting. The local counter slice is
  implementable now with no consent surface; the upload backend shares the
  [hosted remote service](hosted-remote-service.md)'s deployment gate, and the whole feature is
  gated on the brand decision it is designed to keep true: nothing leaves without your action.
- [Triggers](external-event-automations.md) — **the first local slice is implemented**: listen to
  a source in a separate launch agent, match typed conditions, and start an ordinary read-only
  assessment with an optional separately authorized local fix. The Trigger Center, immutable
  approvals, durable runs, MCP draft tools and first Sonda adapter are present. Hosted ingress,
  public webhooks, source resources and push quick replies remain later slices.

### Gated — blocked on something named

- [SSH remote hosts and SFTP attachment sources](ssh-remote-hosts-and-sftp-attachments.md) — let
  the Mac own trusted SSH/SFTP profiles while both Mac and iPhone can choose remote files as
  ordinary session-owned chat attachments, then reuse the profile for a later remote-execution
  helper. The attachment slice is gated on adopting and auditing a client that preserves macOS 13
  and on proving its authentication, paging, cancellation and teardown matrix; it deliberately
  does not replace Threading's remote-companion protocol.
- [Hosted remote service](hosted-remote-service.md) — operate accounts, push, widgets and an
  optional managed public relay while preserving local use and Tailscale, with explicit service
  boundaries and cost ceilings. The transport shipped 2026-08-12; production waits on re-checking
  vendor limits and prices before procurement.
- [Pasteboard-aware prompt suggestions](pasteboard-prompt-suggestions.md) — offer a short-lived,
  privacy-safe Paste action when Threading observed a recent pasteboard ownership change, while
  leaving content reads to the user's ordinary Paste action. Gated on verifying passive
  `changeCount` access in a signed app on every supported pasteboard-privacy regime.
- [Project Insights extension](project-insights-extension.md) — keep project hover glanceable
  while exposing bounded composition, churn, coupling, and anonymized ownership through a reusable
  safe-extension data and project-panel contract. Needs its two host seams first: the bounded
  repository-analysis capability, and a project action that opens an extension panel.
- [Traffic inspector extension and workbench surfaces](network-inspector-extension.md) — put a
  lightweight, agent-readable HTTP(S) inspector in the existing bottom drawer while adding the
  isolated rich surface, live companion data plane and crash-safe system leases other ambitious
  extensions need. The largest platform investment here; nothing scheduled and no proxy engine
  adopted. **Its rendering gate is half answered**: a *first-party* inspector could be built on the
  shipped [native plugin tier](../architecture/plugins.md) today, the way Device Logs was. Host gap
  2 — the sandboxed web surface for untrusted code, and the only option that also renders on the
  iPhone — is untouched, as are gaps 1, 3, 4 and 5, so the draft as written is still gated.
- [Skin and Chrome Imports](skin-and-chrome-imports.md) — translate established declarative theme
  formats into Threading's existing theme and window-chrome model. Recorded for future
  evaluation; no format support committed.
- [Native Linux host and UI](linux-host-runtime.md) — finish the structural UI boundary rather
  than porting AppKit controllers one by one: keep product behavior and extension contracts
  semantic, retain AppKit as the macOS leaf, and admit a Linux backend only after dual-render,
  text/IME, accessibility and virtual-list spikes pass. Gated on the application-layer extraction
  and on Linux becoming a funded product priority rather than a toolkit experiment.
- [Durable sessions](durable-sessions.md) — stop a restart from killing every running turn, by
  first making a session's bridge outlive one app launch (durable tokens, a unix socket, an MCP
  stdio shim) and then moving PTY ownership into a small always-on host. **Part one shipped
  2026-08-22** — the lease grace period, durable tokens, the unix rendezvous and the stdio bridge
  behind the hidden `mcpStdioBridgeEnabled` setting, default off, with the hop measured in
  `performance.md`; the durable decisions are in `mcp-and-display.md`, `session-activity.md`,
  `persistence.md` and `REMOTE_ACCESS.md`. Making the bridge the default and retiring the TCP
  endpoint is next. **Part two, the PTY host, is built** (2026-08-23, `pty-host.md`): sessions
  survive a quit under the opt-in `ptyHostEnabled`, which stays off-by-default until TCC
  attribution is verified on a SIP-enabled Mac. The one slice that depended on neither — a grace period on the remote viewport
  lease, so a phone re-entering a chat stops reflowing the agent — shipped with part one.
- [iPhone subscription for hosted access](ios-hosted-subscription.md) — charge for hosted
  Threading Direct and push, never for local pairing. Gated on hosted Direct and hosted push
  shipping in public Mac builds, which a Developer ID build cannot do while it needs Sign in
  with Apple. Keeps the 2026-09-13 pricing research, the StoreKit 2 design and the App Store
  Connect checklist from when a subscription-only app was considered and dropped.

### Shipped — pointers remain

- [Three-chat project previews on iPhone](mobile-project-chat-preview.md) — **implemented**
  2026-09-15: compact previews, inline disclosure, hidden activity summaries and light haptics.
  The durable contract lives in [Remote Access](../REMOTE_ACCESS.md).
- [The navigator pipeline](navigator-pipeline.md) — **shipped** 2026-09-07. Extensions can define
  a focused sidebar as a host-evaluated transform over typed host and provider facts, with
  persisted static and registered-fact options, host-owned search and row intents, virtualized
  complete ordering, and permanent Native failback. Activity Inbox and T3 Sidebar are the visible
  reference navigators; the UI-free GitLab provider proves cross-extension facts. The durable
  authoring contract is in
  [`WORKSPACE_NAVIGATORS.md`](../extensions/WORKSPACE_NAVIGATORS.md), and the draft remains as the
  delivery and research record. Later pipeline shapes and subject-scoped provider subscriptions
  remain additive future work rather than rollout blockers.
- [Native extension tier](native-extension-tier.md) — **Plan A shipped** 2026-09-02. Threading
  `dlopen`s a signed code bundle, hosts its `NSView` in a pane, and hands it the host's whole theme
  so it draws with the real components; `ThreadingPluginKit` is the contract both sides link and
  `ThreadingDesignKit` compiles the design system a second time behind a symlinked source set. The
  durable decisions — the trust policy the operating system does not enforce, the loader's
  refusals, the encoded theme handoff, and the two build approaches that do not work — are in
  [`plugins.md`](../architecture/plugins.md). The draft remains as the delivery plan and the
  decision record, and keeps what is still open: no third-party install flow, no crash quarantine,
  and **Plan B, the crash-isolated ExtensionKit appex, is proposed and not started**.
- [Device and simulator logs](device-and-simulator-logs.md) — **shipped** 2026-09-02 as the plugin
  tier's first tenant. Four sources (simulator NDJSON, the paired-device syslog relay, `devicectl`
  console, and an app's own log file pulled off the device), a level and time reading for formats
  we have never seen, and `DeviceRelayReclaim` for the single-client `os_trace_relay`. The pane
  lives in `Plugins/DeviceLogsPlugin` and the user's route did not change. The draft stays as the
  measurement record and the source matrix; **the opt-in tap is the remaining slice**, and its
  consent and `DeviceLogTap` deliberately stay in the application.
- [Orchestrator role and grants](orchestrator-role-and-grants.md) — **shipped** 2026-08-17;
  explicit grants, the project Manager role, bounded supervision operations and durable fleet
  state are recorded in [`control-plane.md`](../architecture/control-plane.md), with account,
  session and persistence boundaries in their respective architecture records.
- [Limit management](limit-management.md) — **shipped** 2026-08-15; user-authored limits ahead of
  the provider's. The alerts, the line drawn where the reading is, the four hold seams, both new
  metrics and the tier-4 park live in
  [`accounts.md`](../architecture/accounts.md#your-own-limits-ahead-of-the-providers), and the
  draft remains beside it as the delivery plan and decision record. Its step 6, grants
  integration, belongs to [usage-aware accounts](usage-aware-accounts.md) §C and shipped with the
  manager grant's `SpendCeiling` on 2026-08-17.
- [Cross-platform Usage dashboard](cross-platform-usage-dashboard.md) — **shipped** 2026-08-11;
  the file deliberately remains as the delivery plan and decision record beside
  [`usage-dashboard.md`](../architecture/usage-dashboard.md).
- [Curfew](curfew.md) — **shipped** 2026-08-22; a pointer remains. A scheduled end for a
  session — the deadline's three moments, the hold at every seam, the bounded-interrupt ladder
  with the opt-in stop-agent escalation, quiet hours and the receipts — is recorded in
  [`curfew.md`](../architecture/curfew.md), with its owed Escape measurement and follow-ups.
- [Scoped sound overrides](scoped-sound-overrides.md) — **shipped**; a pointer remains. The
  durable decisions moved to
  [`session-activity.md`](../architecture/session-activity.md).
- [Reclaimable storage outside projects](reclaimable-storage-outside-projects.md) — **shipped**
  2026-08-14; a pointer remains, keeping the two open research questions. The durable decisions
  moved to [`storage-and-stats.md`](../architecture/storage-and-stats.md).
- Media documents and the Lottie viewer — **shipped**; the draft is gone and its durable
  decisions live in [`media-documents.md`](../architecture/media-documents.md), including the one
  thing that changed on the way: the Lottie engine is carried in-tree rather than vendored, and
  the note there says what should reopen that.
