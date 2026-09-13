# iPhone subscription for hosted access

**Status: deferred (2026-09-13).** Threading Remote ships free. Local use over Wi-Fi, a VPN or
Tailscale stays free, because [`REMOTE_ACCESS.md`](../REMOTE_ACCESS.md) records that payment buys
operated infrastructure and not a lock on local pairing. Reopen this draft when hosted Threading
Direct and hosted push ship in public Mac builds; today they are development-channel only
(`BuildChannel.offersHostedDirect`), because a Developer ID build cannot carry Sign in with Apple.

A subscription-only App Store build was considered the same day and dropped for that reason. The
research and design below still apply to a subscription that unlocks the hosted features.

## Pricing research (2026-09-13)

Collected from the iTunes Search and Lookup APIs, App Store product pages and developer sites.

- Paid coding-agent companions mostly charge $6.99–12.99 a month (Moshi $7.99–9.99, littleclaw and
  Claude Code Notifier Companion $6.99, Forge Remote and Btelo $9.99, Vicoa $12.99). The low end is
  TermOnMac at $0.99, ServerCC at $1.99 and CC Pocket at $2.99.
- Several capable companions are free with no purchases: Paseo, T3 Code, Codex Relay, Omnara. The
  Claude and ChatGPT apps include remote control for their own agents.
- SSH clients that the old name "Threading: Remote Terminal" collided with: Termius $15/month,
  Blink $19.99/year with a 14-day trial, Secure ShellFish $2.99/month or $14.99/year, Prompt 3
  $9.99/year.
- The owner's price points at the time: $1.99 a month or $19.99 a year, each with a two-week free
  trial, and no free tier until usage shows one is needed.
- Apple's lowest subscription price point is $0.29 (3 kr), per Apple's December 2022 pricing
  update. Confirm current points in the App Store Connect picker.

## Rules that apply

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) 3.1.2(a): a
  subscription must provide ongoing value and last at least seven days. Hosted relay and push are
  ongoing service, which is the honest basis for charging.
- 3.1.2(c) and [Apple's subscriptions page](https://developer.apple.com/app-store/subscriptions/):
  before purchase, show what the subscription gives, the full renewal price and the trial length,
  with the billed amount at least as prominent as "free"; offer Restore Purchases; link Terms of
  Use and the privacy policy in the app and in the metadata.
- 5.1.1(i): the privacy policy link must be reachable inside the app.
- Anthropic's and OpenAI's brand rules forbid their product names in app names; keep them out of
  subscription display names too.

## Design that carries over

- **StoreKit 2 on the device, no receipt server.** Verify `Transaction.currentEntitlements`, read
  renewal state from `subscriptionStatus`, and finish transactions from a `Transaction.updates`
  listener started at launch. A later control plane can verify the signed transaction the phone
  forwards (`jwsRepresentation`) when hosted access has to be enforced server-side, which is where
  this subscription would need it.
- **An expiry emits no transaction update.** Re-evaluate on a timer to the earliest expiry or
  grace-period end, and on every foreground.
- **A pure resolver** maps verified evidence to trial, active, grace period, billing retry,
  expired, revoked, not subscribed or unverified. Grace period unlocks; billing retry does not;
  upgraded transactions are ignored in favour of their replacement; sandbox counts, because
  TestFlight uses it. Family Sharing stays off: turning it on in App Store Connect is irreversible.
- **The gate covers hosted features only.** Pairing, local connections and the demo never pass
  through it.
- **UI inside the iOS theme boundary.** Build the paywall from `ThemedRowGroup` rows and
  `MobileThemedActionButtonStyle`, present sheets with `.mobileTheme(_:)`, and leave the purchase
  and manage sheets native. `SubscriptionStoreView` draws its own chrome. Period phrases need fixed
  localization keys, because the localization lint requires a Swedish `stringUnit` and rejects
  plural variations.
- **Testing.** Keep the `.storekit` file outside every synchronized root (for example
  `Fixtures/StoreKit/`) so it never ships. `Tests/ThreadingMobileTests` needs explicit project
  entries for each new file, and every new `Sources/ThreadingMobile` file needs a Mac-target
  membership exception. A DEBUG fixture source selected by an environment variable keeps UI
  evidence and connectivity lanes deterministic.

## App Store Connect checklist

1. The Paid Applications Agreement, banking and tax must be active, or products load empty
   everywhere, TestFlight included.
2. One subscription group with monthly and yearly products at the same level. Product IDs cannot be
   reused once created; the proposal was `codes.threading.mobile.subscription.monthly` and
   `.yearly`.
3. Localized display names, prices with equalization, and a free-trial introductory offer, which
   the API creates one territory at a time.
4. A review screenshot of the paywall and a review note per subscription.
5. The first subscription must be submitted together with an app version.
