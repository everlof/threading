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
- [CCS launch profiles and GLM](ccs-launch-profiles-and-glm.md) — adopt CCS-managed launch
  profiles without importing credentials, with route-safe account support and a gated GLM path.
  The account-profile slice is ready once its persistence downgrade guard lands; the API/GLM
  slices wait on upstream redacted metadata.

### Gated — blocked on something named

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
- [The navigator pipeline](navigator-pipeline.md) — make the sidebar a transform over typed facts
  rather than a document an extension renders, so a t3-style list, a ChatGPT-style activity inbox,
  and a GitLab provider with no UI at all are each buildable from the published SDK. A platform
  investment with nothing scheduled.
- [Traffic inspector extension and workbench surfaces](network-inspector-extension.md) — put a
  lightweight, agent-readable HTTP(S) inspector in the existing bottom drawer while adding the
  isolated rich surface, live companion data plane and crash-safe system leases other ambitious
  extensions need. The largest platform investment here; nothing scheduled and no proxy engine
  adopted.
- [Skin and Chrome Imports](skin-and-chrome-imports.md) — translate established declarative theme
  formats into Threading's existing theme and window-chrome model. Recorded for future
  evaluation; no format support committed.
- [Durable sessions](durable-sessions.md) — stop a restart from killing every running turn, by
  first making a session's bridge outlive one app launch (durable tokens, a unix socket, an MCP
  stdio shim) and then moving PTY ownership into a small always-on host. **Low priority and
  nothing scheduled.** Part one is small, ships alone and fixes degradation today; part two is
  gated on it having shipped and settled, because until the bridge is reconnectable durability
  only buys a live process nothing can address. Carries one slice that depends on neither: a
  grace period on the remote viewport lease, so a phone re-entering a chat stops reflowing the
  agent.

### Shipped — pointers remain

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
