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
| Concrete UI-controller references in Core | 18 across 4 files | Move the next complete runtime/controller ownership edge behind a typed application capability; ratchet the gate in the same commit. |
| UI-framework imports in Core/Models | 63 across 61 files | Extract stable Foundation-only contracts into the existing domain boundary before adding another module. |
| `ProjectStore.shared` | 247 across 63 files | Migrate the next complete application coordinator or background service through an existing composition root. |
| `AgentRuntime.shared` | 102 across 31 files | Inject the runtime at the next ownership boundary that already has a composition root. |
| `AppSettings.shared` | 216 across 39 files | Pass a narrow settings projection or store only where a use case needs it. |
| `EventLog.shared` | 82 across 25 files | Inject logging into application services; system log APIs may remain process-global. |
| `MainWindowController` authority | 5,107 lines across 4 files | Continue moving use cases out; the controller should converge on composition, navigation, and window lifecycle. |
| `AgentToolCoordinator` authority | 9,005 lines across 15 files | Move the next command family's policy and sequencing behind a typed, independently tested boundary. |

## Rules for closing an item

- Preserve typed IDs, bounded I/O, commit-before-publish persistence, strict concurrency, and
  refusal/recovery tests.
- Record before/after ownership counts in `docs/architecture/application-structure.md`.
- Add a focused test and an architecture ratchet for each removed dependency.
- Run the focused suite, architecture gate, theme gate when UI is touched, and `scripts/test.sh`
  before declaring a milestone complete.
- Archive a completed investigation instead of growing this ledger into another historical review.
