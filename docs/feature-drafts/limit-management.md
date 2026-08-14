# Limit management: your own limits, ahead of the provider's

**Status: partly shipped.** Sequencing step 1 — *alerts on provider windows* — shipped
2026-08-14: the rule record, the two storage scopes, `CustomLimitEvaluator`, window-instance
identity, the fired-state ledger, `UsageAlertCenter` and the Accounts page's Limits section. Step
2's *bar* half shipped 2026-08-15 — `CustomLimitBounds`, the capped track on `UsageBarView`,
effective-bound tinting on `UsageWindowRow`, the identity menu's metric columns and the
always-visible pill. Its
durable decisions now live in
[`accounts.md § Your own limits, ahead of the provider's`](../architecture/accounts.md#your-own-limits-ahead-of-the-providers);
**that file is authoritative for what exists**, and this one remains the plan for steps 2–6.
Re-check the rest against the code before starting, and move the decisions that survive into
`docs/architecture/` — most likely [`accounts.md`](../architecture/accounts.md),
[`limit-recovery.md`](../architecture/limit-recovery.md) and
[`usage-dashboard.md`](../architecture/usage-dashboard.md) — rather than leaving them here.

What the shipped slice settled, so the sections below are read against it: thresholds are
fractions of the bound and a sentence always names the percentage the *window* reads; the
consequence ladder is one ordered enum clamped to what the build implements, so a rule stored at
a later tier evaluates rather than being dropped; and the metric enum declares `paceShare` and
`syntheticWindow` already, so steps 4's arrival changes no stored shape.

Sibling of [usage-aware-accounts.md](usage-aware-accounts.md): that draft tells the *agent* its
budget and moves work when an account is spent; this one lets the *user* draw the line the
budget is measured against. Its section C (budget ceilings as control-plane grants) keeps the
actor-scoped half; the account-level bound model and evaluator it needs are designed here.

## The problem

The provider's limit is the only limit Threading knows. Every consumer of pressure — the pill's
severity tints, `LimitEscapeRanking`'s eligibility, the scheduled-send headroom check
(`SessionCoordinator+ScheduledMessages`), the usage-window poke's guards — reads a provider
window against 100% of itself. Three instructions a user should be able to give and cannot:

1. *"Give Codex back its five-hour window."* A provider that stops metering a window takes the
   pacing discipline with it: with only a weekly cap left, nothing says one enthusiastic morning
   is spending the week. The same gap exists for any window a provider never metered at all.
2. *"This is a friend's login — never use more than half of what the clock has released."* A
   shared account wants a bound tighter than the provider's and **relative to elapsed time**, so
   whenever the owner turns up, at least their share of the window is still there.
3. *"Tell me at 50% of the weekly"* — or at every tenth. Today the first signals are the fixed
   75%/92% tints and then the refusal itself.

All three are the same missing object: a **user-authored bound**, evaluated locally, feeding the
same consumers provider limits already feed.

## Product contract

A **custom limit** is a per-account rule with three parts: a *metric* (what is measured), a
*bound* (where the line is), and *consequences* (what happens on approach and at the line).

### Three metric shapes

| Shape | Measures | Bound | Example |
|---|---|---|---|
| **Fixed cap** | a provider window's `fraction` | a constant | "treat 80% of weekly as spent" |
| **Pace share** | a provider window's `fraction` against `elapsedFraction` | `share × elapsedFraction(now)` | "stay under 50% of linear time passed since reset" |
| **Synthetic window** | consumption inside a trailing window of length L the provider does not meter | a budget per L | "no more than 15% of the weekly in any 5 hours" |

- **Fixed cap** is the old draft's "stop at 80%", now one shape among three rather than a
  control-plane special. It reads the live `AccountUsage.Window.fraction` and nothing else.
- **Pace share** is the shared-login shape. `Window.elapsedFraction(at:)` already exists — it is
  the pace mark the usage bars draw and the deficit `LimitEscapeRanking` sorts by — so the cap
  is one multiplication over data every reading carries. The guarantee reads well the other way
  round: at any instant, at least `(1 − share)` of what linear time has released is unspent and
  waiting for the account's owner. A literal pace share opens each window with a budget of zero;
  whether a small grace floor is wanted is an open question below, and the literal reading is
  the default because it is the one the instruction actually states.
- **Synthetic window** has two funding sources, chosen by what the account can answer:
  - **Fraction delta**, preferred wherever a longer provider window is still reported: the
    consumption in the last L hours is `fraction(now) − fraction(now − L)` of that window, read
    from `UsageHistoryStore`'s samples (0.5-percentage-point / 15-minute resolution, 180-day
    retention — comfortably enough for a 5-hour trailing sum). The unit stays the provider's own
    normalized metric, so nothing is estimated. A recorded reset inside the trailing span ends
    the subtraction at the reset evidence rather than reading a clear as negative consumption.
  - **Ledger budget**, for accounts with no live reading at all: tokens or estimated cost from
    the transcript ledger's quarter-hour buckets (nine days retained, celled per account). This
    is an estimate and is labelled as one everywhere it appears — the dashboard's rule that an
    estimated transcript cost must never become a provider limit binds this feature too.

  Trailing rather than anchored, initially: an anchored recreation (first message opens the
  window, the old Claude shape) is the nostalgic fit for "give Codex its 5h back", but trailing
  is simpler, strictly stronger, and needs no phase state. Anchoring can be added later behind
  the same rule record; `UsageWindowPlan` already owns the anchoring arithmetic.

An **alert-only rule** is a rule whose consequence list stops at notify — "tell me at 50%" is a
fixed cap at 50% with nothing armed but the notification.

### The consequence ladder

Each tier is opted into per rule; a higher tier implies the ones above it. Nothing here ever
answers a chooser, types into a session, interrupts a turn in flight, or spends money — the
limit-recovery inheritances.

1. **Show.** The bound is drawn where the reading is: a cap tick on `UsageBarView` (sibling of
   the pace `timeMark` it already draws), the rule named in the pill's tooltip, and a cap-line
   marker kind on the Limit History charts beside the existing reset/expiry/projection markers.
   The bar's *length* and the printed number stay the raw provider fraction — a bar drawing full
   at 40% would lie about the figure beside it. What the rule moves is the **tint**: severity is
   computed against the *effective* bound (the tighter of the provider's 100% and the rule),
   reusing `warningFraction`/`criticalFraction` applied to consumed-of-bound rather than
   inventing a second severity vocabulary. A friend's account at 40% raw under a 50% pace-share
   cap tints critical while printing 40% — the number is the fact, the tint is the pressure.
2. **Notify.** Thresholds are fractions of the bound (`[0.5, 0.75, 0.9]`, or "every 10%" as a
   generator). One notification per crossing per **window instance** — identified by
   `(window.id, resetsAt)`, so a reset re-arms everything and also withdraws the delivered
   notifications, the hygiene rule `AttentionAlertPolicy` already enforces for its own. A sparse
   reading that jumps 48% → 61% fires once, naming the highest line crossed, not a backlog of
   every line in between. These are deliberately **not** `AttentionAlert`s: that family is
   session-scoped and every case is a change the user can act on *in that session*, which is why
   `limitReached` posts nothing. A usage alert is account-scoped, explicitly subscribed to by
   the rule that fires it, and actionable at the account level (slow down, switch login, change
   model) — a new small `UsageAlertCenter` with its own settings toggle, not a fourth case
   shoehorned into the session family.
3. **Hold automation.** Threading-initiated spend stands down at the bound, at the seams that
   already exist:
   - scheduled sends park visibly instead of delivering — the delivery seam already asks
     `hasRoom` against `criticalFraction`; the effective bound joins that comparison, and the
     strip says which rule is holding the send;
   - the usage-window poke gains a hold row in its guard table (`customCapReached`), beside
     `weeklyAheadOfPace` and for the same kind of reason;
   - `LimitEscapeRanking` eligibility treats a capped account as ineligible — the escape strip
     and the future automatic policy must never move a conversation *into* an account the user
     fenced off, and the receipt says "excluded by your limit", never "spent";
   - control-plane admission (`send_to_session`, future grants) refuses with a sentence in the
     plane's existing voice.
4. **Park.** At the bound, sessions on the account are held at their next turn boundary: queued
   and scheduled work stays parked, the row carries a mark, and the composer area gets a strip —
   the `LimitEscapeStripView` surface with different words — offering **Continue Anyway** and,
   where another login qualifies, the same escape the real refusal offers. Two deliberate
   differences from a provider park:
   - **It is not the triangle.** `ThemedWarningMark` means "the provider stopped this and you
     cannot answer it". A self-imposed cap is conduct, not weather — it reads as a
     `RowConductSummary`-style mark on an otherwise idle row, the family that already marks
     rows whose non-inherited settings act when nobody is watching. No new `SessionActivity`
     case: the process really is idle and the provider really would accept a turn.
   - **Continue Anyway is real and scoped.** The rule is the user's own, so overriding it is
     legitimate; the override applies to the current window instance and expires with it (for a
     trailing rule, until consumption next falls below the bound), so one late-night exception
     does not quietly disable the rule forever.

### The honesty boundary

Threading can guarantee its own conduct: at tier 3, nothing it initiates spends past the line.
It cannot stop the keyboard — a user typing into the TUI spends whatever they type, and a rule
at tier 4 makes that deliberate and visible rather than impossible. The settings copy says this
plainly; a rule sold as a hard limit that a keystroke walks through would be the feature's
version of the confident lie the delivery seam refuses elsewhere.

Unknown readings fail closed, asymmetrically:

- **Notify** goes silent — an alert derived from a guess is noise, and a missing fraction never
  reads as consumption.
- **Hold and park** engage while the reading a rule requires is unknown, and the receipt names
  the missing reading, not consumption, as the reason. A missing fraction never reads as
  headroom either — the rule exists because the user asked for protection, and "I could not see,
  so I spent anyway" is the wrong side of that ask.

## The evaluator

`CustomLimitEvaluator` is pure — `UsageWindowPlan` and `LimitEscapeRanking`'s shape, for their
reason: a rule that stands between the user and their own quota must be table-testable with no
network, no home directory and no clock of its own. Input: the rules, the current
`AccountUsage`, the recent history samples and ledger buckets a synthetic rule names, and `now`.
Output per rule: consumed-of-bound, thresholds crossed since the last evaluation, the state
(clear / near / holding / parked), and the one sentence a receipt or strip prints. Weighted
scoring stays rejected; every answer must be explainable to the person whose quota it manages.

Evaluation is edge-driven, never polled:

- `AccountUsageDidChange` — a new reading;
- the turn-settle refresh that already exists (the one moment the server's number just moved);
- **one armed wakeup for time-driven crossings.** A pace-share cap rises linearly while the
  spent fraction holds still between readings, so the next crossing instant has a closed form;
  a trailing window's sum next changes at a known bucket boundary as old spend ages out. The
  evaluator reports the earliest interesting instant across all rules and one timer is armed to
  it — bounded work, no cadence, and an idle app schedules nothing.

Rule count is user-fixed and small; history reads are bounded by the rule's own window length.
Nothing here scans transcripts — the ledger buckets are already built and celled per account.

## Storage

- **Rules** live in `AccountPreferencesStore`, beside the emoji and display-name overrides and
  the old draft's `overflowRank`, keyed by `AccountID`. Codable records with persisted raw
  values — named at birth, never renamed.
- **App-wide alert defaults** ("alert every 10% on every account") live in `PreferenceStore`,
  with the per-account record overriding and **absent meaning inherit** — the three-scope
  convention themes, sounds and recovery already follow, minus the middle scope: a limit is an
  account fact, so project and session scopes are deliberately not offered here (a per-session
  budget is an *authority* and belongs to the control-plane grants in the sibling draft).
- **Fired thresholds and overrides** persist as a small map keyed by rule and window instance,
  pruned as `resetsAt` passes — so a relaunch neither re-fires the 50% alert nor forgets an
  override mid-window.
- Both stores redirect under a hosted test bundle, and anything that could act (the alert
  center, the hold seams) refuses under `XCTestCase` — the two-lock convention
  `UsageWindowPoker` set, and for the same consequence if neither lock held.

## Surfaces

- **Settings ▸ Accounts**: a Limits section per account — the rule list, added from templates
  named in the user's terms ("Alert me at…", "Keep this account under…", "Reserve a share for
  its owner…", "Recreate a shorter window…"), each stating its tier in plain words.
- **The pill and its popover**: the popover always draws the cap ticks on its bars and names
  the rule in the tooltip beside the reading's age. The always-visible pill is **opt-in per
  rule** (`showsInToolbar`): the one surface that cannot be dismissed must not acquire a new
  red state because a rule was created to fire one quiet 50% alert. Opting in does two things,
  by shape:
  - a rule capping a **provider window** (fixed cap, pace share) adds no segment — its window
    is already printed. The segment keeps its raw number and takes the effective tint, and
    consumed-of-bound joins the binding comparison the ring gauges, so the user's own line can
    be what turns the corner red;
  - a **synthetic window** gets a segment of its own — it has no provider segment to tint, and
    a recreated 5-hour window exists precisely to be glanced at. It prints consumed-of-bound
    and is never named bare: a segment reading `5h 62%` in the provider's vocabulary would be
    exactly the masquerade the risks section forbids, so its compact name carries a mark that
    says the line is the user's own (the exact register is an open question below).

  A ledger-funded rule that opts in also gives the pill something to say for an account it
  hides for today — no provider source, but a line the user drew and asked to watch.
- **The identity and model menus**: the metric columns keep their raw lengths and numbers and
  take the effective tint, so a fenced-off login visibly reads as pressured at the moment an
  account is being *chosen* — the same moment the readings were put there for.
- **Usage ▸ Limit History**: the cap drawn as its own marker kind, so "how close have I been
  running to my own line" is a chart, not a memory.
- **The row and the strip** for tier 4, as above.
- **The pushed usage reading** (sibling draft, section A) carries the effective bound and
  consumed-of-bound, so an agent paces itself against the user's line rather than the
  provider's — which is most of what makes "stop at 80%" work gracefully before any grant
  refuses it abruptly.

## More than the three asks

Two extensions fall out nearly free, and one is deliberately deferred:

- **Projected-exhaustion alert.** The dashboard already projects weekly utilization at reset;
  an alert-only rule can subscribe to the projection — "at this pace the weekly runs out
  Thursday 14:00, two days before reset" — fired once per instance when projected exhaustion
  first lands before `resetsAt`, withdrawn if pace recovers. The projection's own narrowness
  (measured six-to-eight-day windows, thirty minutes of history) bounds it.
- **A reset alert.** "Tell me when this account's window resets" — a reset-edge alert kind in
  the same family, once per instance by construction. It is the by-hand half of the fleet
  keep-alive ([usage-aware-accounts.md](usage-aware-accounts.md), B5): with anchored windows,
  the meter is not running again until the account is spoken to, and this is the notification
  for whoever wants that first message to be their own.
- **A reserve for by-hand work.** "Keep the last 15% for me" is exactly a tier-3 rule at 85% —
  automation stands down, the keyboard keeps working. Worth naming as a template, because it is
  the inverse framing users reach for first.
- **"Where is my slack?" is the next-best-account ranking, made rule-aware.** The appetite for
  a combined reading across several fenced logins is real, but it is not a new dashboard: "of
  the accounts I may spend, which has the most of *my* slack" is exactly the question
  `LimitEscapeRanking` and the sibling draft's next-best-account policy already answer, and
  rules change only the line the ranking measures against. The pace deficit generalizes from
  `elapsedFraction − usedFraction` to `bound × elapsedFraction − usedFraction` — the linear
  burn toward the *user's* end-of-window line, which is the shipped formula exactly when no
  rule draws one (`bound = 1`), and `share × elapsedFraction − usedFraction` on a pace share
  by construction. A shared login far under your share therefore ranks ahead of a free login
  near its cap, which is the "yours vs. theirs" answer delivered where it is actionable: the
  identity menu's comparison table, the escape strip, and the future automatic policy. A
  standing aggregate surface stays unbuilt unless the menu's at-the-moment answer proves
  insufficient.
- **Provider-wide rules** ("all Codex logins share one synthetic window") are deferred: every
  consumer here is per-account, and an aggregate bound needs an aggregation story the ledger
  has but the live readings do not. The rule record should not preclude it.

## What exists, and what is new

| Piece | State |
|---|---|
| `fraction`, `resetsAt`, `windowDuration`, `elapsedFraction` per window | exists (`AccountUsage.Window`) |
| Pace comparison (`elapsedFraction − fraction`) | exists (`LimitEscapeRanking`, `weeklyAheadOfPace`) |
| Sparse durable fraction history with reset evidence | exists (`UsageHistoryStore`, 180 days) |
| Per-account quarter-hour ledger buckets | exists (usage dashboard, 9 days) |
| Headroom check before a scheduled delivery | exists (`hasRoom` against `criticalFraction`) |
| Guard-table hold shape for automated spend | exists (`UsageWindowPlan`) |
| Escape strip, ranking, eligibility filters | exists (`LimitEscapeSuggestion`) |
| Pace `timeMark` on usage bars; chart marker kinds | exists |
| **Rule record + `AccountPreferencesStore` surface** | **shipped** (`CustomLimit`, `AccountPreference.customLimits`, `CustomLimitSettings`) |
| **`CustomLimitEvaluator`** | **shipped** for `fixedCap`; the two other metrics are declared and refused |
| **`UsageAlertCenter` + fired-state store** | **shipped** (`UsageAlertLedger`, keyed by account + rule + window instance) |
| **Effective-bound tinting + cap ticks** | **shipped on the bar** (`CustomLimitBounds`, `UsageBarView.capMark`); the pill, the menus and the charts still read the provider's 100% |
| **Hold seam extensions (sends, poke, ranking, plane)** | new — one comparison at each existing seam |
| **Tier-4 park + conduct mark + strip variant** | new |

## Risks and boundaries

- **A rule must never masquerade as the provider.** Different mark, different words, different
  clear: a rule park clears when consumption falls under the bound or the user overrides; a
  provider park clears on transcript evidence per limit-recovery. Conflating them would teach
  the user that the triangle is sometimes negotiable.
- **Estimates stay estimates.** A ledger-funded synthetic window is labelled an estimate
  end-to-end; fraction-delta rules inherit the provider's own normalization and need no label.
- **The escape machinery must not start lying.** An account excluded by rule says so in the
  receipt. Silent exclusion reads as "spent", which slanders an account with headroom.
- **Alert fatigue is a design failure.** Once per threshold per instance, highest-crossed only,
  withdrawn at reset. "Every 10%" on a busy account is the user's explicit choice, not a
  default; the shipped default is no rules at all.
- **A stale reading moving real behaviour.** Holds engage on unknowns (fail closed), but the
  receipt must distinguish "over your line" from "cannot see" — the two have opposite remedies.
- **Out of scope:** per-session/project ceilings (control-plane grants — sibling draft, which
  this evaluator should serve), money-denominated caps on metered API billing, cross-provider
  aggregate budgets, and anything that interrupts a turn in flight.

## Tests

- **Evaluator** — table-driven and pure: pace share at window open, mid-window, expired window
  and unknown fraction; fraction-delta across a recorded reset; ledger budget cold and warm;
  a 48% → 61% jump firing one notification naming 60%; re-arm on reset; override scoped to one
  instance and expiring with it.
- **Holds** — the poke's guard row; a scheduled send parking with the rule named; ranking
  excluding a capped account with the stated reason; none of them firing under `XCTestCase`.
- **Honesty** — unknown never fires an alert, always engages a hold with "cannot see" as the
  stated reason; a ledger estimate never prints as a provider figure.
- **Render** — cap ticks and effective tinting across themes, light and dark; the tier-4 strip
  and conduct mark visibly distinct from the provider triangle and refusal strip.
- **Instance identity** — fired-state and overrides pruned as `resetsAt` passes; a relaunch
  neither re-fires nor forgets.

## Sequencing

1. ~~**Alerts on provider windows.**~~ **Shipped 2026-08-14.** Smallest slice, immediately
   useful, and it built the evaluator, instance identity, fired-state store and
   `UsageAlertCenter` everything else rides.
2. **Show:** ~~cap ticks and effective-bound tinting~~ — **the bar shipped 2026-08-15**
   (`CustomLimitBounds`, `UsageBarView.capMark`, `UsageWindowRow`). The line turned out not to be
   a tick: it is a change in the *track*, because a pace mark and a cap mark on a 6pt bar are two
   different kinds of thing and cannot share one vocabulary. What remains of this step is the
   *model* menu's scoped columns and the cap-line marker on the Limit History charts. The bar,
   the identity menu's columns and the always-visible pill — segments, ring and the per-rule
   `showsInToolbar` switch — all shipped.
3. **Holds:** the three existing seams plus the plane's refusal sentence.
4. **The two new metrics:** pace share, then synthetic windows (fraction-delta first, ledger
   funding second).
5. **Tier 4:** park, conduct mark, strip variant, Continue Anyway.
6. **Grants integration:** the sibling draft's section C consumes the evaluator.

## Open questions

- Does a pace share want a grace floor at window open (literal `share × elapsed` starts at
  zero), or is the literal reading — which is what the instruction says — the right default with
  the floor as a per-rule option?
- The compact register for a user-authored segment in the pill: `5h` must not appear bare, so
  what marks it as the user's line without costing the width the columns fought for — a glyph,
  a distinct tone, or a short word?
- Anchored synthetic windows: worth the phase state once trailing ships, or is trailing's
  strictly-stronger guarantee simply better than nostalgia for the provider's old shape?
- Threshold re-arm for trailing windows that oscillate around a line: re-arm below the previous
  step, below `threshold − ε`, or only after a quiet interval?
