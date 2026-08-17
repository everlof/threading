# Usage-aware work: budgets, and the next best account

**Status: draft, except the delegated half of C.** A manager grant already carries an optional
`SpendCeiling`, admitted by `ControlSpendCeiling` when a manager spawns, resumes or sends
(2026-08-17, [`control-plane.md`](../architecture/control-plane.md)); that covers delegated work
only, and A, B and the ordinary session's own ceiling remain unbuilt. Re-check the rest against
the code before starting, and move the decisions that survive into `docs/architecture/` — most
likely [`accounts.md`](../architecture/accounts.md),
[`limit-recovery.md`](../architecture/limit-recovery.md) and
[`control-plane.md`](../architecture/control-plane.md) — rather than leaving them here.

## The problem

Two instructions a user should be able to give and cannot today:

1. *"Refactor until you have used 80% of the weekly limit, then stop."*
2. *"When this account is nearly spent, move to the next best account for this task."*

Both are blocked by the same gap: **an agent cannot see its own usage.** It has no view of the
five-hour or weekly window, no idea what the session has cost, and only an unreliable sense of
how full its own context is. It learns about a limit the way everyone else does — a request
fails.

This is not hypothetical. On 2026-08-08 the control-plane session fanned out a ten-agent
review twice; both runs died mid-flight on usage limits, and a cheaper strategy (narrower
range, lower effort) was only discovered *after* burning a window to find out. The failure was
missing instrumentation, not missing judgement.

**Threading knows everything the agent does not.** `AccountUsageService` holds per-account
windows with `fraction` and `resetsAt`; the usage dashboard keeps a transcript cost ledger and
a durable limit/reset history; the toolbar pill already draws the answer. The asymmetry is the
opportunity: the app can simply tell the agent, and can act when the agent cannot.

## Product contract

Three capabilities, deliberately separable and shippable in this order. Each is useful alone.

| | What it gives | Who enforces |
|---|---|---|
| **A. Pushed usage reading** | The agent can pace itself, and can choose a cheaper strategy before starting | the agent |
| **B. Account order + failover** | Work continues on another login instead of stopping for days | the app |
| **C. Budget ceilings** | "Stop at 80%" is a guarantee rather than a hope | the app |

---

## A. Pushed usage reading

**Push, never poll.** A tool the agent must call to learn its budget spends budget to learn
about budget — the anti-pattern `watch_session` exists to kill. The reading rides a channel
that already reaches every session: the `initialize` instructions for the opening state, and
the turn boundary for updates. `SessionActivityDidChange`'s settle edge is the existing carrier.

**Decision-shaped, not gauge-shaped.** "34% of a five-hour window, resets 18:40" does not
answer *should I fan out ten agents*. What answers it is history: "a ten-agent review has cost
about 40% of a window." The usage dashboard's ledger and limit history already hold that, and
it is the part an agent cannot estimate for itself — models are poor at pricing their own work.

**An unknown reading says "unknown."** Providers report unevenly and readings lag. A missing
fraction must never render as headroom; the same fail-closed rule the delivery seam learned
when `.typedUnconfirmed` replaced a confident lie about a message that never arrived.

---

## B. The next best account

### B1. A per-provider order the user sets

The new user-facing model, and the thing that makes automatic movement *consented to* rather
than merely convenient.

- One optional field on `AccountPreference`: `overflowRank: Int?`, keyed by `AccountID`
  (`provider:handle`), stored in `AccountPreferencesStore` beside the emoji and display-name
  overrides.
- **The rank is the eligibility.** `nil` means "never move work here on your own"; a rank means
  "eligible, in this order". One field, two jobs, no ambiguity — and it follows the store's
  established convention that an untouched account and a reset one are the same stored value.
- **Deliberately not `isEnabled`.** That flag answers "may I offer this account to the user";
  this answers "may the app spend it without asking". An account can reasonably be the first
  and not the second — a personal login you are happy to pick by hand but not to have drained
  overnight.
- Ordered **within a provider**, because a same-provider move is the lossless one (B4). A
  cross-provider order is a second, opt-in list.
- Surface: Settings ▸ Accounts, drag to order, with the unranked accounts in a separate group
  under a line saying plainly that they are never used automatically.

### B2. The ranker

Filters first, then one sort. Explainability is a requirement, not a nicety: the receipt has to
be able to say *why* in one sentence, so weighted scoring is rejected outright — a weighted
choice cannot be explained to the person whose money it spent.

1. **Filter — capability fit.** The account must support what the task needs: the model, the
   reasoning levels, the native surface, whatever the session is configured with. An account
   with plenty of headroom and the wrong capabilities is a silent downgrade, not a fallback.
2. **Filter — eligible.** Ranked (B1), enabled, discovered, authenticated, and not the account
   the session is already on.
3. **Filter — worth moving to.** Headroom above a floor. Moving into an account that is itself
   nearly spent buys one turn and costs a migration.
4. **Sort — the user's order** (B1), ascending.
5. **Tie-break — headroom**, descending.

Rejected alternative: rank purely by headroom. It reliably picks the account the user was
saving, which is the one behaviour guaranteed to make the feature untrusted.

Every headroom and pace reading here is against the **effective** line, not the provider's
100%: [limit-management.md](limit-management.md) lets the user draw a tighter one (a fixed cap,
a pace share, a synthetic window). Filter 3 consults it, and the pace comparison generalizes to
`bound × elapsedFraction − usedFraction` — the shipped deficit exactly when no rule applies. An
account at its own rule's line is not "worth moving to" whatever the provider would still
accept, and the receipt says "excluded by your limit", never "spent". This ranking is also the
combined "yours vs. theirs" reading across several shared logins — the answer surfaces where an
account is chosen rather than on a standing dashboard.

### B3. When it fires

**Trigger pre-emptively at `UsageDefaults.criticalFraction` (0.92), not at 97%.** A migration
costs turns — the handoff replays context — so the move must be affordable at the moment it is
decided. At 97% there may not be enough window left to complete the move just chosen. 97%
remains the *hard stop*, not the switch point.

**Which window is blocking changes the right answer.** This is the decision the policy turns on:

- A **five-hour** window at 92% resets within hours. Parking is usually right, and
  [`limit-recovery.md`](../architecture/limit-recovery.md) already schedules a continuation at
  reset. Moving accounts to save a few hours' wait is a bad trade.
- A **weekly** window at 92% is days away. This is where failover earns its keep.

So the rule is not one threshold: *if the blocking window resets within N hours, park; otherwise
move.* N is a named default, initially a few hours.

**Threshold moves pre-emptively; the refusal is the backstop.** The provider is the authority on
whether a turn is allowed, and Threading already reads the real refusal out of the transcript.
Thresholds are a forecast and can be wrong in both directions, so both paths exist and converge
on the same move.

**It lands as a new case in the existing recovery policy**, alongside "wait for reset" and "flag
me and wait" — not as a parallel subsystem. That chooser is in flight in its own session; this
draft must be re-checked against it before implementation.

### B4. How the move happens

- **Same provider: `SessionMigration`.** The transcript is preserved and the conversation
  resumes by its own id. Lossless, already built, already reachable from the row menu as
  *Move to Account*. Strongly preferred, and the reason B1 orders accounts within a provider.
- **Cross provider: `ConversationHandoff`.** Bounded and, for some runtimes, deliberately lossy
  (Grok's inline transport). Opt-in only, and never the automatic first choice.
- **The move is visible and recorded.** A receipt naming the account moved to and why —
  the pattern `agentArchiveToast` established for an action nobody clicked — plus an `EventLog`
  record. A session that quietly changed accounts is a session whose usage nobody can reason
  about afterwards, and the sidebar's account chip alone does not say *why* it changed.
- **If nothing qualifies, park and say so.** Silence, or continuing on a spent account, are both
  worse than the existing park.

### B5. Poke on reset: keep a draining fleet's windows cycling

An anchored window's meter only starts on the first message after its reset — the premise of
the Usage Windows page ([`accounts.md`](../architecture/accounts.md)). For the accounts this
draft ranks as overflow and drains to their caps, that anchor is a leak: every hour between a
reset and the account's next first message is a window opening late, and over a month that is
whole windows lost. Community practice already names the workaround — r/codex's PSA "send at
least one message per account after fresh reset", and 9router automating "using tokens shortly
after resetting".

Threading holds both halves of that automation today, unjoined: the **poke run** (cheapest
model, scratch directory, no MCP or tools, reply discarded, routed by the account's own
environment key — `usageWindowPokeCommand`) and the **reset clock** (scheduled messages already
fire at a window's `resetsAt` plus a margin, and re-arm boundedly when the window turns out
still spent). The new piece is per-account consent and the guards:

- **Opt-in per account, and deliberately not inherited from `overflowRank`.** The rank consents
  to moving work *in*; this spends a message and **starts the owner's clock**, which on a
  shared login is a fact about the owner's week, not ours. A custom limit's hold applies on top
  ([limit-management.md](limit-management.md)) — the keep-alive is Threading-initiated spend
  like any other.
- **It fires a margin after the anchored window's reset and verifies with a refreshed
  reading.** An account already used since the reset skips — the owner's own message beat it —
  and `usageUnknown` skips outright, the day poke's first refusal for the same reason.
- **`neverExhausts` inverts into the eligibility rather than out of it.** An account whose
  history never reaches its weekly cap gains nothing from cycling and keeps the *later* anchor,
  which is worth more to a light user — the window then covers time they are actually present.
  The keep-alive is for accounts the ledger shows being drained; a naive "always poke at reset"
  actively harms the light ones.
- **The daily cap sits below the rules**, the day poke's own backstop, so a defect above cannot
  turn this into a poller.
- The same run is reachable **by hand** from the account's row — "start the window now" — for
  whoever wants the workaround with themselves in the loop; the alert-only version ("tell me it
  reset") is a reset-edge alert in [limit-management.md](limit-management.md)'s alert family.

The weekly window is the one worth cycling; the short window's phase already belongs to the day
poke, whose lead arithmetic would be fought rather than helped by pinning it to reset.

The PSA is also **evidence about Codex**: "your weekly timer gets pushed back to exactly 7 days
after your first message" is the anchored shape `anchoredUsageWindow` refuses to assume for
Codex until it is measured from an account's own history. The honest order stands — but the
180-day journal now holds exactly the history that can answer it (a quiet account across a
boundary), and the poke's Codex branch is already written behind the gate. This PSA is a reason
to run that measurement.

---

## C. Budget ceilings, as grants

"Work until 80% of weekly" needs the app to enforce it, because the agent cannot: it reads 78%,
starts a large refactor, and lands at 91%. It cannot price the next chunk of work, so its
stopping is a hope.

The account-level bound model and evaluator a ceiling reads — fixed caps, pace shares,
synthetic windows, and their alert/hold/park consequences — are designed in
[limit-management.md](limit-management.md); this section keeps the actor-scoped grant half.

A ceiling is an **authority**, which is exactly the third axis
[`control-plane.md`](../architecture/control-plane.md) reserves for slice two —
`ControlActor` × `ControlScope` × authority. "This actor may spend down to 80% of weekly" has
the same shape as "this actor may reach these sessions", and belongs in the same grant record.

Enforcement goes where new work is admitted — spawning subagents, starting turns through
`send_to_session`, firing scheduled sends — and refuses with a reason in the plane's existing
voice. Pushed reading (A) is what lets the agent stop *gracefully* before the ceiling refuses it
*abruptly*; they are complements, not alternatives.

**The delegated half shipped on 2026-08-17** with the manager role: a grant may carry an optional
`SpendCeiling`, and `ControlSpendCeiling` admits the manager's spawn, resume and send against it,
refusing when the reading is unknown. What remains is the ceiling a user places on a session's
*own* work — the same bound reaching the paths a manager does not sit in front of — and A, so a
session can see the line before it meets it.

---

## What exists, and what is new

| Piece | State |
|---|---|
| Per-account usage windows, `fraction`, `resetsAt`, `criticalFraction` | exists |
| Cost/limit history to price work | exists (usage dashboard ledger) |
| Move a conversation between accounts | exists (`SessionMigration`, `moveSession(_:to:)`) — user-triggered |
| Limit detection and the recovery-policy chooser | exists (`LimitEscapeRanking`, the park policy) |
| The user's own line the ceiling is measured against | exists (`CustomLimitEvaluator`, shipped 2026-08-15) |
| Per-account preferences keyed by `AccountID` | exists (`AccountPreferencesStore`) |
| **`overflowRank` + its Settings surface** | new, small |
| **The ranker** | new — policy over data that already exists |
| **Window-type-aware trigger + failover policy case** | new |
| **Reset keep-alive poke (B5)** | new — joins the existing poke run and the reset clock |
| **Pushed usage reading** | new — a channel, not a tool |
| **Budget ceilings** | the delegated half exists (`SpendCeiling` on a manager grant); a session's own ceiling is new |

## Risks and boundaries

- **Spending money the user did not intend.** The whole reason rank is opt-in and unranked
  means never. Ship the ordering UI before the automatic move, not after.
- **A stale or absent reading.** Fail closed: unknown never reads as headroom.
- **Migration affordability**, addressed by the 0.92 trigger — but worth measuring, because the
  handoff's cost varies with transcript size.
- **Silent capability downgrade**, addressed by making capability a hard filter.
- **Unreasonable-about-usage sessions**, addressed by receipts and the event record.
- **Out of scope:** load-balancing work across accounts, cost optimisation as an objective,
  and anything that moves a session while a turn is in flight.

## Tests

- **Ranker** — a pure function over injected accounts, preferences and usage; table-driven over
  capability mismatch, unranked, disabled, current-account, low-headroom, ties.
- **Trigger** — the window-type matrix: five-hour vs weekly × near vs far reset × ranked
  alternative present or absent.
- **Store** — absent-means-default for `overflowRank`, and preferences surviving a reordering.
- **Honesty** — an unknown usage reading never selects a move and never reads as headroom.
- **Integration** — refusal → chosen account → `SessionMigration` → resumes by the same id, with
  the receipt naming both accounts.

## Sequencing

1. **A. Pushed reading.** Cheapest, immediately useful, and it makes "stop at 80%" *mostly* work
   through the agent's own judgement.
2. **B1. The per-provider order and its Settings surface.** User-visible, safe, and the consent
   the rest depends on.
3. **B2–B4. Ranker, trigger, failover**, re-checked against the recovery-policy chooser once it
   lands.
4. **C. Ceilings**, with slice two's grants.

B5 rides beside the sequence: it depends on nothing above beyond its own per-account opt-in,
and its Claude half could ship first — the Codex half waits on the anchoring measurement.

## Open questions

- Does the reset-soon threshold (N hours) want to be user-visible, or is a good default enough?
- Should a moved session move *back* when its original window resets, or stay where it landed?
  Staying is simpler and probably right; moving back is what a user expecting their "main"
  account might assume.
- Cross-provider failover: worth offering at all, given the handoff's losses, or is parking
  always better than a lossy continuation?
- Should the ceiling be per-session, per-project, or per-account? "80% of the weekly" is an
  account fact, but the instruction was given to one session.
