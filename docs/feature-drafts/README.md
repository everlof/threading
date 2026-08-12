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

## Drafts

- [Project Insights extension](project-insights-extension.md) — keep project hover glanceable
  while exposing bounded composition, churn, coupling, and anonymized ownership through a reusable
  safe-extension data and project-panel contract.
- [Browser Focus](browser-focus.md) — let the live browser fill the main window while retaining a
  compact, live conversation dock.
- [Skin and Chrome Imports](skin-and-chrome-imports.md) — translate established declarative theme
  formats into Threading's existing theme and window-chrome model.
- [Usage-aware accounts](usage-aware-accounts.md) — tell an agent what its budget is, let the user
  rank which logins may be spent automatically, and move work to the next best one before a
  weekly window strands it.
- [Cross-platform Usage dashboard](cross-platform-usage-dashboard.md) — bring the Mac's measured
  usage and limit history to the iOS companion through bounded owner-only snapshots, with banked
  reset inventory and evidence presented consistently on both platforms.
- [Hosted remote service](hosted-remote-service.md) — operate accounts, push, widgets and an
  optional managed public relay while preserving local use and Tailscale, with explicit service
  boundaries and cost ceilings.
- [CCS launch profiles and GLM](ccs-launch-profiles-and-glm.md) — adopt CCS-managed launch
  profiles without importing credentials, with route-safe account support and a gated GLM path.
- [Scoped sound overrides](scoped-sound-overrides.md) — let a sound say which chat is calling and
  why, by scoping the notification and bell sounds to the chat, the project or the app and
  splitting each into the events the activity tracker already tells apart.
- [Pasteboard-aware prompt suggestions](pasteboard-prompt-suggestions.md) — offer a short-lived,
  privacy-safe Paste action when Threading observed a recent pasteboard ownership change, while
  leaving content reads to the user's ordinary Paste action.
