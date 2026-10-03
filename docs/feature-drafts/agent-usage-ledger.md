# Agent usage ledger: what each agent spent, kept where it ran

> Status: **in progress** (2026-10-03). Slices 1–3 are implemented: `Packages/ThreadingUsage`
> holds the shared adapters and pricing ([`usage-dashboard.md`](../architecture/usage-dashboard.md)),
> and the controller writes receipts, daily cells and enforces worker and chain budgets
> ([`autonomous-controller.md`](../architecture/autonomous-controller.md#usage-receipts-and-budgets-schema-v9)).
> The dashboards (slice 4) are next. Extends
> [`usage-dashboard.md`](../architecture/usage-dashboard.md) (the Mac's transcript ledger) and
> [`autonomous-controller.md`](../architecture/autonomous-controller.md) (workers and
> executions). Read by admission in [`portable-trigger-sources.md`](portable-trigger-sources.md)
> and [`agent-mail.md`](agent-mail.md).

## The problem

The Mac's Usage page accounts carefully for **conversations it can see**: `UsageLedgerRecord`, one
per provider response, five token categories kept apart, provider adapters for Claude, Codex and
OpenCode that dedupe resumes and forks, an honest pricing catalogue, and coverage rows that say
what could not be read. Remote-host sessions are covered through transcript mirrors.

It cannot answer the questions autonomous agents raise:

- **Which agent spent it.** A controller worker on a VPS runs `claude --print` / `codex exec`
  executions whose transcripts never reach the Mac, and even if they did, a transcript knows a
  conversation, not a worker, task, chain or trigger.
- **Whether to start more work.** Spend checks at admission (a grant's `SpendCeiling`, a chain's
  budget) must run on the host while the Mac is away.

## Contract

1. **The ledger lives with the agent.** Each host's controller keeps the ledger for the
   executions it ran — the [mailbox location](agent-mail.md#mailbox-location) rule. The Mac keeps
   its own for its sessions, as today. Nothing is copied to become a second authority.
2. **One parser, not two.** The provider adapters and pricing move out of the app target into a
   portable, Foundation-only package (`Packages/ThreadingUsage`): `UsageTokenCounts`,
   `UsageLedgerRecord`, the Claude/Codex/OpenCode adapters, `JSONLReader`'s strict entry point
   and `UsagePricingCatalog`. Today they import only Foundation, so this is a move plus access
   control, not a rewrite. The Mac app and the controller then produce identical numbers for an
   identical transcript, and a fix to an adapter fixes both.
3. **A receipt per execution, attributed by the controller.** When an execution's process is
   confirmed stopped, the controller reads that execution's transcript (its provider session id is
   the execution UUID, already substituted into the recipe) through the shared adapter and commits
   one `usage_receipt` with: worker, execution, work item, chain ID, trigger/source and event,
   account, runtime/biller, per-model token categories, provider-reported cost, catalog-priced
   cost, unpriced tokens, and coverage (`complete` / `partial` / `failed` with a reason). The
   attribution comes from the controller's own records, never from the transcript or the model.
4. **Refuse, don't undercount.** The usage-dashboard rule carries over: a transcript the adapter
   cannot finish reading yields a `partial`/`failed` receipt, visibly, never a plausible short
   total. A receipt with no transcript at all says `unavailable`.
5. **Tokens are measured; percentages are read.** The ledger holds tokens and cost. A fraction of
   an account's window comes from that account's usage reading, which is a different fact with
   its own freshness ([`accounts.md`](../architecture/accounts.md)); the two are never converted
   into each other.

## Records (controller schema, next version)

- `usage_receipt` — keyed by execution; parent = work item; indexed by `(worker, endedAt)`,
  `(chain)`, `(account, endedAt)`. One row per execution, with per-model cells inside its bounded
  payload (at most 16 models; overflow folds into an "other models" cell that keeps totals exact).
- `usage_daily` — `(worker, account, model, day)` cells maintained in the same transaction as each
  receipt, so a dashboard range read is O(days × cells), never O(executions).
- Running executions are not receipts. Admission sees "N executions in flight in this chain" and
  each one's ceiling, not a guessed partial spend.

## Admission reads

- **Chain budget**: the sum of receipts in a chain (indexed), checked before a mail-triggered or
  source-triggered admission. Over budget refuses the next wake in that chain; it never stops a
  running execution.
- **Grant `SpendCeiling`**: the account's current window fraction from its reading; if the reading
  is older than its freshness bound, admission defers.
- **Per-worker budget** (optional, owner-set): tokens or cost per day from `usage_daily`.

## Dashboard

- **Mac Usage page** gains an *Agents* breakdown beside runtime/account/checkout: Mac sessions from
  the existing transcript ledger, and each connected host's workers from that host's ledger over
  `owner-rpc` (`usage-summary RANGE`, `usage-receipts WORKER [CURSOR]`). A host that cannot be
  reached shows its last summary with its age, never zero. Remote-host session mirrors and worker
  receipts never overlap (workers' transcripts are not mirrored), and response identity still
  dedupes if they ever do.
- **A worker's page** (Mac Automations ▸ Remote, and Rindabox's agent page): spend by day, by
  task, by trigger, and by chain — so "this agent woke 40 times on newsletters" is visible as a
  trigger's cost, which is what makes a source worth tuning.
- Both are presentations over the same owner projection; neither recomputes from transcripts.

## Scaling contract

Expected: 10 workers, 100 executions/day, 90 days → ~9,000 receipts. Stress: 100 workers,
100,000 receipts, transcripts up to 50 MiB.

- Receipt creation streams one transcript once, off the supervisor's critical path, bounded by
  the strict reader; a 50 MiB transcript is read once and never retained.
- Dashboard reads use `usage_daily`; receipt lists are cursor pages (100 rows / 1 MiB).
- Chain sums are indexed; a long history never enters an admission check.

## Rollout

1. **Extract `ThreadingUsage`.** Move the adapters and pricing with their tests; the Mac's numbers
   must be byte-identical before and after on the existing fixtures.
2. **Controller receipts** at confirmed stop, `usage_daily`, owner reads.
3. **Admission reads** for chain budget and `SpendCeiling`.
4. **Dashboards**: the Mac's Agents breakdown and the worker page; Rindabox's view.

## Tests

Shared-fixture parity (same transcript → same totals on Mac and controller); partial/failed
coverage on a corrupt line; receipt idempotent across a supervisor restart; attribution from
controller records even when the transcript names something else; chain sum correct across 100
executions; stale reading defers admission; stress fixture of 100,000 receipts timing range reads
and admission sums.

## Open questions

- Account usage readings on Linux: the Mac's `AccountUsageService` polls provider windows; the VPS
  needs its own reading for its own logins before a fraction ceiling can apply there. Until then,
  host-side budgets are token/cost budgets only.
- Live spend during a long execution: worth a mid-run reading from the transcript tail, or is
  "in flight, bounded by its curfew" enough for admission?
