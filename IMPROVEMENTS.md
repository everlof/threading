# Active architecture health ledger

This file contains only current structural debt. Completed reliability reviews and their full
evidence are preserved in [`docs/archive/reviews`](docs/archive/reviews/README.md). Current
load-bearing rules live in [`docs/architecture`](docs/architecture/application-structure.md).

Refresh counts with `scripts/report_architecture_health.py`. A count is evidence, not a target by
itself: work is complete only when authority and dependency direction become smaller and a test or
gate prevents the old coupling from returning.

## Current boundaries — 23 August 2026

| Boundary | Current measurement | Next coherent reduction |
|---|---:|---|
| UI-framework imports in Core/Models | 69 across 66 files | Extract stable Foundation-only contracts into the existing domain boundary before adding another module. |
| `ProjectStore.shared` | 295 across 74 files | Migrate the next complete application coordinator or background service through an existing composition root. |
| `AgentRuntime.shared` | 108 across 37 files | Inject the runtime at the next ownership boundary that already has a composition root. |
| `AppSettings.shared` | 207 across 42 files | Pass a narrow settings projection or store only where a use case needs it. |
| `EventLog.shared` | 110 across 28 files | Inject logging into application services; system log APIs may remain process-global. |
| `MainWindowController` authority | 5,911 lines across 5 files | Continue moving use cases out; the controller should converge on composition, navigation, and window lifecycle. |
| `AgentToolCoordinator` authority | 8,967 lines across 18 files | Move the next command family's policy and sequencing behind a typed, independently tested boundary. |

## Rules for closing an item

- Preserve typed IDs, bounded I/O, commit-before-publish persistence, strict concurrency, and
  refusal/recovery tests.
- Record before/after ownership counts in `docs/architecture/application-structure.md`.
- Add a focused test and an architecture ratchet for each removed dependency.
- Run the focused suite, architecture gate, theme gate when UI is touched, and `scripts/test.sh`
  before declaring a milestone complete.
- Archive a completed investigation instead of growing this ledger into another historical review.
