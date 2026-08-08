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

## Drafts

- [Browser Focus](browser-focus.md) — let the live browser fill the main window while retaining a
  compact, live conversation dock.
- [Skin and Chrome Imports](skin-and-chrome-imports.md) — translate established declarative theme
  formats into Threading's existing theme and window-chrome model.
