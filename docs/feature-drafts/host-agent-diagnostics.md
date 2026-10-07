# Host and agent diagnostics

Status: agreed implementation plan, not yet implemented.
Planned: 2026-10-05. Recorded: 2026-10-07.

## Outcome and cost

Make failures understandable in Rindabox and Threading, and send operator emails when the VPS
or Mac becomes unavailable, even while that host is offline.

Use Threading's existing Cloudflare control plane. Expected incremental cost: $0/month if its
Workers Paid account has spare included capacity; otherwise budget $5/month for the account's
base plan, before tax. Two hosts reporting every minute plus the monitoring cron produce roughly
130,000 invocations/month, comfortably within its included allowance. Verify current billing
before activation. Pricing was checked on 2026-10-05 against
[Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/).

Cloudflare's included D1 capacity is ample for this workload, and sending to verified operator
addresses is free. Configure a dedicated alert sender without changing Rindabox's existing mail
setup. See [D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/) and
[Email pricing](https://developers.cloudflare.com/email-service/platform/pricing/).

## Portable Threading diagnostics

- Bring the relevant `fix/platform-review` changes forward before implementation. Use clean
  task worktrees and preserve other ongoing edits.
- Add a versioned `HealthSnapshot` and bounded issue projections to the controller's owner
  CLI/RPC. Include host authority, observation time, service instance, last attempted/completed/
  successful cycle, component state, and stable issue codes.
- Record supervisor progress even during quiet idle cycles. Distinguish a responsive loop that
  reports failures from successful supervision.
- Expose existing launch failure classifications, start/stop times, exit status, and recovery
  evidence. Retain owner-only output-tail access under its existing boundary; exclude tails
  from the new shared snapshots and alerts.
- Add ptyd journal health through additive handshake fields. Older components report
  diagnostics as unsupported or unknown.
- Rotate journals at 4 MiB per segment; retain at most seven days and 64 MiB per daemon. Prune
  during operation and expose write failures, dropped records, and incomplete cleanup. Keep
  filesystem work bounded and off the daemon's control path.
- Keep Cloudflare publishing in adapters. The controller and ptyd remain usable without any
  hosted monitoring service.

The existing architecture records are
[autonomous controller](../architecture/autonomous-controller.md),
[PTY host](../architecture/pty-host.md), and
[status integrity](../architecture/status-integrity.md). Move implemented decisions into these
records rather than maintaining this draft as another architecture source of truth.

## Rindabox monitoring and incidents

- Add an independent monitoring loop that consumes portable health through existing pinned SSH
  owner transport and reads both execution-user and controller-user preflight results.
  Instrument the autonomous and delivery pumps separately.
- Extend the shared contracts so task details preserve structured launch failures and timing.
  Show blocked admission, computation failure, and delivery uncertainty separately.
- Persist incidents and acknowledgements in PostgreSQL. Each incident records its source,
  affected host/agent/work, reason, severity, first/last observation, and recovery evidence.
  Acknowledgement does not mark a problem fixed.
- Add a health summary and paginated incident list to Operations, with relevant explanations in
  task details. Use the existing workspace components and authenticated deep links.
- Expose separately grantable MCP health/incident reads and acknowledgement writes. Host-wide
  reads and acknowledgements require management authority; hosted executions cannot administer
  monitoring.
- Preserve the application's existing readiness contract. Add a restricted, uncached
  monitoring endpoint for agent-platform readiness.
- Classify new state in the recovery inventory: incident history is backed up; current
  observations are rebuildable; credentials stay in secret storage. Restores disarm notification
  delivery until reconciled.

Rindabox owns business context, task visibility, recipient policy, and its incident workflow.
Threading owns portable process and controller evidence. Follow Rindabox's own repository
guidance, MCP policy, and recovery inventory when implementing its consumer changes.

## Cloudflare alerts and Threading's Mac view

- Extend the existing control plane with authenticated monitor registration, per-target
  publishing credentials, durable observations, incident transitions, and an every-minute cron.
- Enrol the Rindabox execution host and the Mac independently. Credentials permit a reporter to
  update only its own target; reuse existing account ownership for configuration and revocation.
- Publish one small heartbeat per minute. Cloudflare also probes Rindabox's restricted
  monitoring endpoint. Emails come directly from Cloudflare, independently of Rindabox's pumps,
  database, and mail service.
- Send structured summaries only: affected host, reason, timestamps, and an authenticated
  inspection link. Exclude task prose, transcripts, credentials, and filesystem paths.
- Add Diagnostics to Threading's existing remote-host settings: component health, evidence
  freshness, active issues, and bounded report export. Link to existing authorized management
  controls and respect externally managed installations.
- Add an opt-in "Expected online 24/7" setting for the Mac, with an explicit maintenance pause.
  Sleep, app exit, and network loss remain unavailable conditions unless monitoring was paused.
  Missing heartbeats say "Threading host unavailable" without inventing a cause.
- Ship Mac support first. Use themed components, command-registry actions, and inspected evidence
  from the real product shell.

These are deliberately host-owned operational surfaces. Health truth, identity, monitoring
consent, authorization, acknowledgements, and management authority remain host-owned. Apply
the [customization-surface gate](../extensions/CUSTOMIZATION_SURFACE_AUDIT.md) before implementation.

## Detection and notification defaults

| Condition | Initial behavior |
| --- | --- |
| Missing host heartbeat | Open an outage after five minutes |
| Supervisor or configured pump stops completing cycles | Mark degraded after five minutes |
| Eligible queued work does not start | Warn after 15 minutes; show admission holds separately |
| Execution exceeds its deadline | Warn after the configured deadline plus 60 seconds; retain current timeout behavior |
| No model account available while work needs one | Alert after five minutes; show known reset times |
| Uncertain delivery | Alert after five minutes; require existing reconciliation |
| Same worker fails three consecutive executions within 15 minutes | Open a repeated-failure incident |
| Individual execution failure | Show immediately in the portal |
| Recovery | Resolve after two consecutive healthy observations |

Waiting for a person, draft approval, paused workers, budget holds, and absent checkpoints do
not establish stalled execution.

Send one email when an actionable incident opens, another if severity increases, and one on
recovery. Correlate host outages with dependent failures to avoid an alert per affected task.
Retain closed incident history for 90 days. Add no new automatic restart or retry policies.

## Verification and rollout

- Test idle health, stalled loops, storage failures, unavailable ptyd, lost receipts, account
  exhaustion, deadline overruns, blocked work, and delivery uncertainty with deterministic clocks.
- Test journal rotation, runtime pruning, restart, partial writes, disk-full failures, and
  bounded tails.
- Test heartbeat authentication/revocation, stale and reordered reports, concurrent cron runs,
  maintenance pauses, incident deduplication, email failure, and recovery notifications.
- Verify HTTP/MCP permission parity, read-only write rejection, grant revocation, migrations,
  and recovery with synthetic data.
- Inspect Rindabox in light, dark, System, and narrow layouts; inspect the Mac diagnostics inside
  Threading's real shell. Stress 100 workers and 100,000 retained records with bounded queries
  and rendering.
- Run controller/ptyd shipping checks on macOS and Ubuntu, Cloudflare service tests, relevant
  native checks, and Rindabox's full gate plus infrastructure and recovery checks.
- Roll out in stages: portable evidence, consumer views, Cloudflare detection, then verified
  email delivery. Complete controlled VPS/service and Mac-disconnection drills proving that an
  alert arrives while the target is unavailable and that recovery clears it.

Activation requires verified operator recipients and confirmed Cloudflare billing/email
configuration. Acceptance is demonstrated outage detection and useful explanations in both
clients, with no duplicate work or automatic replay of uncertain effects.
