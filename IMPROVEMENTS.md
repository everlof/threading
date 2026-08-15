# Active architecture health ledger

This file contains only current structural debt. Completed reliability reviews and their full
evidence are preserved in [`docs/archive/reviews`](docs/archive/reviews/README.md). Current
load-bearing rules live in [`docs/architecture`](docs/architecture/application-structure.md).

Refresh counts with `scripts/report_architecture_health.py`. A count is evidence, not a target by
itself: work is complete only when authority and dependency direction become smaller and a test or
gate prevents the old coupling from returning.

## Current boundaries — 15 August 2026

| Boundary | Current measurement | Next coherent reduction |
|---|---:|---|
| Concrete UI-controller references in Core | 19 across 5 files | Replace one runtime-to-controller lookup with a typed application capability; ratchet the gate in the same commit. |
| UI-framework imports in Core/Models | 63 across 61 files | Extract stable Foundation-only contracts into the existing domain boundary before adding another module. |
| `ProjectStore.shared` | 295 across 64 files | Migrate one application coordinator or background service through `AppEnvironment`; do not rewrite leaf call sites mechanically. |
| `AgentRuntime.shared` | 116 across 32 files | Inject the runtime at the next ownership boundary that already has a composition root. |
| `AppSettings.shared` | 223 across 40 files | Pass a narrow settings projection or store only where a use case needs it. |
| `EventLog.shared` | 94 across 27 files | Inject logging into application services; system log APIs may remain process-global. |
| `MainWindowController` authority | 5,075 lines across 4 files | Continue moving use cases out; the controller should converge on composition, navigation, and window lifecycle. |
| `AgentToolCoordinator` authority | 9,349 lines across 15 files | Continue moving one command family at a time into independently tested application services. |

## Rules for closing an item

- Preserve typed IDs, bounded I/O, commit-before-publish persistence, strict concurrency, and
  refusal/recovery tests.
- Record before/after ownership counts in `docs/architecture/application-structure.md`.
- Add a focused test and an architecture ratchet for each removed dependency.
- Run the focused suite, architecture gate, theme gate when UI is touched, and `scripts/test.sh`
  before declaring a milestone complete.
- Archive a completed investigation instead of growing this ledger into another historical review.
