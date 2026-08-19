# Open Source & Monetisation

Analysis written 2026-07-25, alongside the t3code research (see
[the archived t3code findings](archive/research/T3CODE_FINDINGS.md)). The questions it answers, in order: can t3code
make money; what do they do right that preserves the ability to; and what Threading must
decide *before* opening any source, given the working assumption that source availability
is a trust requirement in this category — so revenue has to come from somewhere other than
the code.

**What landed since:** the repository went public under GPLv3 on 2026-08-08 rather than
the FSL-everywhere of §7, and on 2026-08-19 the control plane alone was carved out to
FSL-1.1-ALv2 on the §6.1 reasoning.
[`docs/architecture/releasing.md`](architecture/releasing.md) holds the current record; this
file stays as the dated analysis.

---

## 1. The market's price for the app layer is $0

Every player in "GUI/harness for coding agents" gives the app away, each subsidized
differently:

| Product | Source | App price | Subsidized by | Monetisation surface |
|---|---|---|---|---|
| t3code | MIT, contributions closed | Free (`npx t3code`) | Theo's media business (YouTube sponsorships, T3 Chat $8/mo funnel) | None live; T3 Connect relay + enterprise are the kept-warm seams |
| Conductor (Melty Labs) | Closed | Free | YC / venture capital | None visible; pre-monetisation |
| opencode (SST) | MIT | Free | Hosted inference, run near break-even | Zen (pay-as-you-go models, zero markup), Go ($10/mo bundled models), Black (enterprise, closed to signups) |
| Official CLIs (Claude Code, Codex) | — | Free | The labs; the CLI sells the subscription | The subscription itself |

Two consequences. **The harness itself cannot be the primary revenue** — its price is set
at zero by players who don't need it to make money. And **"bring your own subscription" is
the category's identity** — a harness that adds a bill contradicts its own pitch.

## 2. Can t3code make money?

**Directly, today: no — by their own statement.** Theo, publicly: "A lot of people seem to
think it's a product we sell with subscriptions... we CAN NOT MAKE MONEY ON T3 CODE RN. You
HAVE to bring inference from somewhere else." They reworked the landing page to say so.

Their real monetisation surfaces, all visible in the code:

- **T3 Connect** — the hosted relay (`infra/relay`: Cloudflare Worker + PlanetScale +
  Clerk): tunnel, identity, APNs push, iOS Live Activities. The Tailscale model — open
  clients, paid coordination. Crucially, **push notifications to their App Store mobile app
  structurally cannot be self-hosted**: APNs certificates belong to whoever signs the app.
  A paywall made of physics, not license terms.
- **Enterprise later** — their auth design doc lists SSO/RBAC as "non-goals *for v1*"; the
  classic open-core seam, kept warm.
- **The honest reading: t3code may never need direct revenue.** It is audience
  infrastructure for a media business; 14.8k stars in five months *is* the return. Their
  $0 is subsidized by an asset (audience) that Threading does not have — which changes what
  Threading can safely copy.

Shared exposure worth naming: **platform risk**. Anthropic's (paused) move to meter
third-party harnesses would, in Theo's words, have cut subscription-backed usage "by 25×".
Any harness built on `claude -p` economics carries this; don't build the *paid* tier on
ground a lab can reprice.

## 3. What t3code does right — monetisation optionality

1. **Contributions are closed.** Quietly the most important decision. One copyright holder
   can relicense, or move a component proprietary, without hunting contributors for
   consent. MIT with hundreds of drive-by contributors is a one-way door; MIT with one
   copyright holder is reversible.
2. **The paid seam sits where self-hosting is impossible, not where it is forbidden**
   (APNs, App Store distribution, the hosted tunnel). A fork gets the code but not the
   push pipeline, the update channels, or the `t3` npm name.
3. **Brand is not licensed.** MIT covers code; the "T3" trademark, t3.codes, and the
   distribution channels stay theirs. A fork cannot be called T3 Code.
4. **The identity layer is pre-installed** (Clerk across every client) — billing can be
   switched on without re-architecting.
5. **The free product is genuinely whole** — which is what makes "steal our code" read as
   confidence instead of risk. Trust and adoption first; monetise operational surfaces.

And one thing they did wrong that converts directly into a competitor's asset: default-on
telemetry with a hidden opt-out (issue #1397) turned goodwill into GDPR threads. Trust is
the currency of this category, and they spent some of theirs.

## 4. What trust actually requires (interrogating the premise)

The premise "open source is required for trust" is *mostly* right and worth sharpening.
What buys trust for a tool that hosts an agent with shell access is **auditable local
behavior**: no account, no telemetry, and no bytes leaving the machine without an explicit
user-started network feature, with verifiable network silence otherwise. Evidence both ways:

- Conductor is closed and praised; Obsidian and 1Password are closed and trusted — via
  local-first architecture and reputation.
- t3code is open and still took a trust wound, because behavior (telemetry) contradicted
  posture.

Source availability is the strongest *proof* of local behavior, and in this category the
audience skews developer, so the assumption holds in practice. But the operative word is
**source-available, not necessarily OSI-open**: users can read, audit, and build the code
under a source-available license too. That distinction is where the money survives.

## 5. Licensing — the decision tree

- **MIT/Apache (OSI-open).** Maximum trust and contribution potential; zero defense
  against a funded fork or a cloud provider reselling the work. t3code affords MIT because
  its moats are audience and velocity. A solo developer without those moats should treat
  plain MIT as the *riskiest* option, not the default.
- **FSL — Fair Source License (Sentry's).** Read, audit, compile, self-use freely;
  competitors cannot resell it as a competing product/service; **auto-converts to
  Apache/MIT after two years**, so the community is guaranteed the code eventually. Built
  for exactly this situation. ~95% of the trust value, commercial rights kept.
- **BUSL (MariaDB/HashiCorp-style).** Same shape, heavier reputation baggage post-2023.
- **GPL/AGPL.** Open and fork-resistant against proprietary reuse, but doesn't stop a
  compliant free fork, and AGPL scares enterprise adoption.
- **Split model** (open core + closed components) — composes with any of the above: the
  app under FSL, the future paid components (relay, enterprise policy) never in the public
  repo at all.

**Sequencing is the real constraint: you can always open more later; you can never
un-open.** Default to FSL first, loosen if strategy demands.

## 6. What Threading must decide before opening — the checklist

1. **Pick the money seam first.** Whatever will be charged for must either stay out of the
   public repo or be covered by a license that prevents freeloading. Relicensing after the
   fact is where projects get burned.
2. **Keep sole copyright** — contributions closed (t3code's move), or CLA/DCO from day
   one. This keeps decision #1 reversible.
3. **Register and withhold the trademark** — name, icon, domain. License code, never
   brand. A fork may exist; it may not be called Threading, sit in the App Store under that
   name, or receive the signed update stream.
4. **Choose the revenue models** (ranked for Threading's shape):
   - **Paid signed binaries, source available — the Aseprite model.** Free if you compile
     it yourself; pay for the notarized, auto-updating build and/or App Store listing.
     Works *unusually well* for a native Mac app: "build it yourself" means Xcode and
     signing certificates, not `npx t3code`. The friction asymmetry is the price fence.
     Probably the primary model.
   - **A paid companion: iPhone app + push when a session needs attention.** The exact
     42-vote unmet demand in t3code's tracker, sitting on the same APNs seam that cannot
     be self-hosted. `needsAttention` already exists in `AgentRuntime`; a small relay
     subscription funds the service side. (Their bug tracker also warns: the connection
     layer is where their reliability went to die — scope it narrowly, notifications
     first, not full remote control.)
   - **Team/enterprise tier, later**: fleet policy for `ShellCommandPolicy`, audit via
     `EventLog`, session sharing, SSO — sold as a commercial license or closed module to
     companies running agent fleets.
   - **Support/priority licensing** — supplementary only.
   - **Anti-models**: reselling inference (contradicts the BYO identity; opencode runs
     Zen at zero markup as strategic break-even — not an indie business), and any paid
     tier whose economics a lab can meter away (see §2 platform risk).
5. **Make "nothing leaves without your action" the loudly stated brand promise.** Threading's
   current truth: no account and no telemetry; network egress belongs to explicit features such
   as remote access, GitHub, issue reporting, avatar probes, and icon discovery the project itself
   points at. Each surface states what it sends before enabling it. That is the differentiator
   t3code fumbled — state it on the landing page, in the README, and keep it testable.
6. **Pre-publication hygiene**:
   - Scrub **git history**, not just HEAD: secrets, tokens, machine paths, and pre-scrub
     versions of the fixture transcripts (the scrubber is good; history may predate it).
   - Keep signing identities, notarization credentials, and any future server component
     out of the repo entirely.
   - Verify third-party license notices travel: the SwiftTerm / LabelMorph / ThinkingOrbs
     forks are MIT-lineage — fine, but notices must be retained.
   - Decide the public issue-tracker posture (t3code: issues open, contributions closed —
     a reasonable default that harvests feedback without copyright entanglement).

## 7. Recommendation

Open the code under **FSL with contributions closed**; sell the **signed, notarized,
auto-updating build** (compile-yourself remains free); build the **phone-notification
companion** on the APNs seam as the second product; keep enterprise policy/audit as the
kept-warm third; and make **"nothing leaves without your action"** the stated identity. That
captures the trust that requires source availability, prices the things a fork cannot
take (signature, distribution, push, brand), and avoids both of t3code's self-inflicted
wounds — the telemetry breach and the load-bearing free tier with no path to revenue.

## Sources

- Theo on monetisation: https://x.com/theo/status/2054737293186126056 · Conductor
  comparison: https://x.com/theo/status/2036875737266000048
- Conductor pricing: https://www.fixedlabs.ai/tools/conductor ·
  https://docs.conductor.build/ · https://www.ycombinator.com/companies/conductor
- opencode monetisation: https://opencode.ai/docs/zen/ ·
  https://note.com/famous_prawn2009/n/n4decca184d6e?hl=en
- t3code telemetry issue: https://github.com/pingdotgg/t3code/issues/1397
- Platform risk: https://venturebeat.com/technology/anthropic-reinstates-openclaw-and-third-party-agent-usage-on-claude-subscriptions-with-a-catch
- Fair Source License: https://fsl.software/ · T3 Code overview:
  https://betterstack.com/community/guides/ai/t3-code/ · https://t3.codes/
