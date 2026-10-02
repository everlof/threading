# Project default accounts

**Status: implemented (2026-10-02), all four slices.** The durable decisions now live in
[`accounts.md`](../architecture/accounts.md#project-default-accounts),
[`limit-recovery.md`](../architecture/limit-recovery.md#project-default-accounts) and
[`REMOTE_ACCESS.md`](../REMOTE_ACCESS.md); this file stays as the plan and decision record.

What landed differently from the plan below:

- **The Mac editor reorders with buttons, not drag.** Each listed row has Move up, Move down and
  Remove; each other login has Add. Every move is a press that VoiceOver and the keyboard reach
  the same way a pointer does. It is `ProjectDefaultAccountsViewController`, built from
  `SettingsUI` rows and `ThemedIconButton`. A shared `AccountOrderEditor` in `UI/Design` is
  extracted when [usage-aware accounts](usage-aware-accounts.md) §B1 needs the same list.
- **The composer's provenance is in the usage line's tooltip**, not inline text.
  `UsageReadingLabel` draws readings only, and the receipt at the send is the visible statement.
- **The strip's one-tap offer leads with the list but may leave it.** It falls back to the pace
  ranking when no listed login has room, because a press is the user's decision. The automatic
  policy stays inside the list.
- The open questions were answered with the recommendations: one mixed list, 0.92, and a moved
  conversation stays where it landed.

## The problem

*"Chats in this project run on my work login. When that one is out, use my second work login.
Never use my personal login here unless I pick it."*

Nobody can say that today. A new chat's login is chosen by one app-wide rule:

- **On the Mac,** the composer picks the enabled login that this runtime used most recently,
  searching every project. If there is none, it takes the standard login, then the first one
  (`AgentAccountDiscovery.preferred(among:for:recentlyUsedIn:)`).
- **On the iPhone,** the draft takes `"default"`, or else the first account in the catalogue
  (`SessionDraftView.applyAgentDefaults()`).

So the two platforms already disagree. Neither looks at usage, and neither knows which project
the chat is for. The only code that picks a login by usage is
`LimitEscapeRanking`. It runs *after* a conversation has been refused, which is too late for the
choice a new chat makes.

## Product contract

A project can have an **ordered list of logins**. On Mac and iPhone alike, a new chat in that
project starts on the first login in the list that is not out of usage, and the user sees which
login was picked and why. The list is set from the project's context menu on the Mac and the
project heading's menu on the iPhone. It is stored once, on the Mac, and the Mac decides.

| Moment | What happens |
|---|---|
| **Draft opens** (or its project changes) | The draft's runtime and login are taken from the first usable entry. Fresh readings for the listed logins are requested in the background. |
| **Send** | If the draft's login came from the list and is now *known* to be spent, the chat starts on the next usable entry **of the same runtime**. A one-line receipt names both logins. |
| **The conversation hits a limit later** (slice 4) | If the project's recovery policy is *resume on best account*, the move follows the list's order instead of pace deficit. |

An explicit pick in the draft always wins. A project with no list behaves exactly as today.

## Decisions

### D1. One list of provider-qualified logins, mixed across runtimes

The field is `Project.defaultAccounts: [AccountID]?`. `nil` or empty means no list.

`AccountID` is already provider-qualified (`claude:work`, `codex:default`), so one list can say
*"Claude work, then Claude spare, then Codex"*. This means the list chooses the **runtime** as
well as the login, which is what *"when all my Claude is out, use Codex"* needs.

A per-runtime list was considered. It is the same data filtered per runtime, so the model allows
either; the UI would differ. The decision is open (see [Open questions](#open-questions)).

When the user changes the draft's runtime by hand, the login becomes the first usable entry of
that runtime. If the list has no entry for that runtime, today's rule applies.

### D2. Precedence

1. **An explicit choice made in this draft.** The draft records where its identity came from
   (`explicit`, `projectDefault`, `appRule`). Only `projectDefault` is ever substituted later.
2. **The project's list**, resolved by D3.
3. **Today's rule** (most recent login, then standard, then first). It also covers a list whose
   entries are all unavailable.

A start that came from the project list does **not** write `AppSettings.defaultAgentKind`. If
it did, a project whose list leads with Codex would turn every other project's composer to Codex.
`rememberSuccessfulNewSessionChoice` keeps writing the per-account `newSessionRunChoice`, because
that is a fact about the login, not about the project.

### D3. What "out of usage" means: one pure resolver

`ProjectAccountOrder.resolve(entries:accounts:readings:limits:model:now:)` is a pure function
over in-memory values. It classifies each entry, then picks one.

| State | When |
|---|---|
| `unavailable` | The login is disabled, missing (directory gone or renamed), or its runtime cannot route logins. |
| `spent(until:)` | Some **unexpired** window that meters the draft's model, in a `.current` or `.stale` reading, is at or over **`ProjectAccountDefaults.spentFraction` (0.92 = `UsageDefaults.criticalFraction`) of the effective bound**, which is `CustomLimitBounds.consumedOfBound` against `effectiveBound`, so the user's own lines count. Also, a custom-limit hold of `.overLine`. `until` is that window's `resetsAt`. |
| `usable` | The reading is `.current`, every metering window is unexpired, and every window is below the line. |
| `unverified` | Everything else that is enabled and present: no reading, a failed reading, an expired window, a `.stale` reading below the line, or a `.cannotSee` hold. |

**Pick the first entry that is `usable` or `unverified`.** The user's order outranks how much is
known about each login. This is a deliberate asymmetry with `LimitEscapeRanking`, which fails
closed:

- **A stale reading can prove exhaustion, but it cannot prove headroom.** Usage only grows within
  a window, so an old 95% is still at least 95%, but an old 40% may be 90% now. A new chat moves
  no transcript and is visible before Send. If the pick is wrong, the provider refuses the first
  turn and the project's recovery policy takes over. Skipping the first-choice login because
  nothing has fetched its reading yet would be the more common failure. Background accounts are
  often `.notFetched`, because nothing polls them.
- **The honesty rule still holds for display.** An `unverified` entry is shown as "usage
  unknown", never as headroom.

0.92 rather than 1.0, because starting a chat on a login at 97% buys one turn. The same number
is the pre-emptive switch point in [usage-aware accounts](usage-aware-accounts.md) §B3.

**If every entry is spent,** pick the one whose blocking window resets soonest, with ties going
to list order. Say so plainly, for example "All of this project's logins are out · Work resets
18:40". Never leave the list on the user's behalf. The list is the consent, so an unlisted login
is never chosen automatically for this project. The user can still pick any login by hand.

**Provider refusals are not a v1 input.** `UsageLimitStop.resetHint` is text only, so a refusal
cannot say when it ends. The reading is the evidence.

### D4. Readings are refreshed, never waited on

When a draft opens in a project that has a list, every listed login gets
`AccountUsageService.refresh(_:force: true)`. That service already paces refreshes: a 60 s floor,
at most four at once, and it honours a 429's `notBefore`. At Send, the resolver runs again on
whatever has arrived. Send never blocks on the network.

The draft does **not** switch its login while it is open. A chip that changes under someone who
is typing breaks the rule in [`accounts.md`](../architecture/accounts.md) that usage readings "do
not silently switch an unfinished draft". The decision is made again only at Send, which is the
moment it matters, and the receipt makes that visible.

### D5. Send-time substitution stays within the runtime

Moving to a different runtime at Send would invalidate the draft's model, reasoning effort,
permission mode and surface. That is acceptable when a draft opens, because the user sees it.
It is not acceptable at Send, after the user has committed.

So at Send, substitution only moves to the next usable entry of the same runtime. The model is
kept if the new login offers it; otherwise that login's `newSessionRunChoice` or default model
is used, and the receipt says so. If no entry of that runtime is usable, the chat starts on the
draft's login as it is.

## Mac surfaces

- **Editing.** The sidebar project row's menu gets **Default Accounts…**, placed next to the
  usage-limit recovery submenu. It is also a registered command, so the palette and shortcuts can
  reach it (see [command-first actions](../../CLAUDE.md#command-first-actions)). It opens a themed
  popover anchored to the row.
  - The popover has two groups: **In order** (numbered, drag to reorder, remove) and **Not used
    automatically** (add). This is the same shape that [usage-aware accounts](usage-aware-accounts.md)
    §B1 plans for its app-wide order.
  - Each row shows the runtime mark, the login's chip and its current state ("Out until 18:40",
    "Held by your limit", "Usage unknown", "Missing login").
  - The row subtitle is one line; mechanics go behind the "?" `HelpTopic`.
- **A new design component.** `UI/Design` has no reorderable list today. Build
  `AccountOrderEditor` there, from themed parts, not inside the feature:
  - drag reordering, plus VoiceOver *Move up* / *Move down* custom actions;
  - behaviour, accessibility, live-theme-switch and rendered-state tests, as the theme boundary
    requires;
  - B1's Settings ▸ Accounts order reuses it later instead of building a second list.
- **Composer.** When the identity came from the list, the existing usage line under the identity
  chip starts with "Project default". If entries were skipped, it says so, for example "Project
  default · Work is out until 18:40". The identity menu shows each listed login's number in the
  order. Nothing new appears for projects without a list.
- **Receipt.** A Send-time substitution posts a short toast in the existing receipt style ("Started
  on Spare — Work was out") and an `EventLog` record.

## iPhone surfaces

- **Editing.** The project heading's ellipsis menu gets **Default Accounts** next to Hide/Show
  Project. It appears only for the owner (`canManageHost`) and only when the host advertises
  `project-default-accounts`. It opens a `List` page built from `ThemedSettingsSection` with
  `.themedSettingsPage(theme)`:
  - the ordered section uses `EditButton` with `onMove` and `onDelete`;
  - a second section adds the remaining logins;
  - presentation follows `MobileSessionSettingsView`, using no bare `Section` and no system alerts
    ([`IOS_THEMED_DIALOGS.md`](../IOS_THEMED_DIALOGS.md)).
- **Draft.**
  - `applyAgentDefaults()` gains the project step. It predicts the pick from the catalogue's list
    plus the live capacity feed (`accountUsageByID`), using the same threshold, and sets
    `identitySource = .projectDefault`.
  - Add the missing `.onChange(of: projectID)`, so a draft moved to another project re-resolves.
    It re-resolves only while the identity has not been touched.
  - The phone does not see custom limits, so its pick is a **prediction**. The Mac's answer is
    authoritative (below).
- **Receipt.** If the create response names a different login than the one sent, the opened
  chat shows the same one-line receipt as the Mac.

## Wire contract (ThreadingRemoteKit)

All additions are additive and optional, following the rule in
[`releasing.md`](../architecture/releasing.md). No protocol version bump.

| Addition | Shape |
|---|---|
| Feature flag | `RemoteRESTFeature.projectDefaultAccounts = "project-default-accounts"`, owner-only, published beside `project-visibility`. |
| Catalogue | `RemoteProjectChoiceDTO.defaultAccounts: [RemoteAccountReferenceDTO]?`, where each entry is `{agentID, accountID}`. A reference not in the catalogue renders as "Unavailable login". Absent means no list, or an older host; the feature flag tells the two apart. |
| Mutation | `POST api/project/default-accounts` with `RemoteSetProjectDefaultAccountsRequestDTO {projectID, accounts}`. It requires `canManageHost`, refuses unknown logins with 422, de-duplicates, caps the list, and replies with the full `RemoteMeDTO` through `respondWithCatalogue`. This is the same pattern as `api/project/visibility`. |
| Create | `RemoteCreateSessionRequestDTO.accountSelection: RemoteAccountSelectionDTO?`, a lossless enum `explicit \| projectDefault \| unknown(String)`. Absent means `explicit`, which is today's meaning. With `projectDefault`, the phone still sends its predicted `accountHandle`. The Mac keeps it unless it is now `spent`, and otherwise applies D5. |
| Create response | `RemoteCreateSessionResponseDTO.accountSubstitution: {requestedAccountID, reason, resetsAt?}?` so the phone can word the receipt itself. |

The phone sends `projectDefault` only when the catalogue advertises the feature, so an older Mac
is never sent a word it would ignore.

## Slice 4: limit recovery follows the list

When a session's project has a list and its resolved policy is `.resumeOnBestAccount`:

- the candidates become the list's entries of the session's runtime, minus the current login, in
  list order;
- the first one that passes `LimitEscapeRanking.hasHeadroom` wins. This path stays **fail-closed**,
  because it moves a conversation.

`LimitEscapeSuggestion`'s one-tap offer uses the same order. Without a list, nothing changes.

This also answers the project-scope limitation recorded in the recovery menu: a project-scope
answer "names no login, and cannot". With a list it does, per runtime.

## What exists, and what is new

| Piece | State |
|---|---|
| Per-project optional overrides in the `Project` JSON payload (no SQL migration) | exists: `limitRecoveryPolicy`, `curfewRule`, `executionHost` |
| `ProjectStore.setX(_:forProjectID:)` → save → `notifyChanged` | exists |
| Readings, effective bounds, holds, pacing | exists: `AccountUsageService`, `CustomLimitBounds` |
| Fail-closed headroom check for moves | exists: `LimitEscapeRanking.hasHeadroom` |
| Owner-only project mutation over the wire, catalogue reply | exists: `api/project/visibility` |
| Live per-account capacity on the phone | exists: `api/usage/capacity`, `accountUsageByID` |
| **`Project.defaultAccounts` + setter + command** | new, small |
| **`ProjectAccountOrder` resolver** | new, pure |
| **`AccountOrderEditor` (UI/Design) + Mac popover** | new; the largest UI piece |
| **Composer/draft identity source + Send-time substitution + receipt** | new |
| **Wire additions + iOS editor page + draft step** | new |
| **Recovery ordering by list** | new, small; slice 4 |

## Scaling gate

- **Cardinality.** Expected 1–3 entries per project, stress 32. Discovery stops admitting logins
  above 32, so the list is capped at 32 too (`ProjectAccountDefaults.maximumEntries`). Projects:
  expected tens, stress hundreds. The catalogue grows by at most 32 short strings per project and
  omits the field when there is no list.
- **Frequency.** Resolution runs on draft open, on a project or runtime change in the draft, and
  at Send. It never runs on layout, scroll or usage ticks. Each run is O(entries) over in-memory
  values on the main actor, with no file, process or network work.
- **Refresh.** The only external work is the existing paced `refresh`, at most one forced request
  per listed login per draft open, bounded by the service's 60 s spacing and four concurrent
  requests.
- **Views.** The editor builds at most 32 rows on both platforms, which is a small fixed form.

## Risks and boundaries

- **Spending a login the user did not intend.** This is why an unlisted login is never chosen
  automatically and a project without a list is unchanged.
- **An unknown reading.** It is pickable by order but never displayed as headroom (D3). The
  conversation-moving path stays fail-closed (slice 4).
- **A surprise at Send.** Substitution stays within the runtime, is announced, and only happens on
  positive evidence of exhaustion.
- **Phone and Mac disagree.** The Mac decides and the phone shows the outcome. Custom limits are
  the expected cause of a disagreement.
- **An older build rewriting a project row drops the list.** This is the same accepted exposure
  as `curfewRule` and `limitRecoveryPolicy`, which are optional keys in the same payload.
- **Out of scope for v1:**
  - scheduled starts, triggers and manager spawns, which keep their frozen or explicit login;
    a later slice could offer "Project default" resolved when they fire;
  - projects with an `executionHost`, until it is confirmed how logins route there;
  - runtimes without logins (Grok, OpenCode, Cursor) as list entries.

## Tests

- **Resolver**, table-driven:
  - each state: disabled, missing, `.notFetched`, `.failed`, expired window, `.stale` below and
    above the line, `.current` below and above;
  - model-scoped windows;
  - custom-limit `.overLine` and `.cannotSee`;
  - all spent, choosing the soonest reset with ties in list order;
  - runtime filtering.
- **Store:**
  - absent means no list;
  - round trip;
  - an older payload decodes;
  - de-duplication and the cap.
- **Composer:**
  - the precedence matrix;
  - no live switch while the draft is open;
  - Send-time substitution keeps the model when the new login offers it;
  - a project-list start leaves `defaultAgentKind` untouched.
- **Wire** (`RemoteProtocolTests`):
  - the new fields round-trip;
  - an older payload decodes with them absent;
  - an unknown `accountSelection` stays lossless.
- **Server** (`RemoteServerIntegrationTests`):
  - the mutation is owner-only and refuses unknown logins;
  - a `projectDefault` create substitutes and reports it;
  - an `explicit` create never substitutes.
- **Mobile:**
  - the draft prediction;
  - re-resolution on a project change;
  - an older host shows no menu item and sends no new field;
  - editor reordering.
- **Rendered state:** the editor popover and the iPhone page, light and dark, with every state
  label.

## Sequencing

1. **Model and resolver.** `Project.defaultAccounts`, the setter, `ProjectAccountOrder`, and
   their tests. Nothing is visible yet.
2. **Mac.** `AccountOrderEditor`, the popover and command, the composer step, Send-time
   substitution and the receipt. This is usable end to end on the Mac.
3. **iPhone.** The wire additions (Mac first), the editor page and the draft step.
4. **Recovery.** `resumeOnBestAccount` follows the list.

## Open questions

- **Mixed list or one list per runtime?** This draft recommends mixed, so the list can also say
  "fall back to Codex". The data model supports either; only the editor's grouping changes.
- **Is 0.92 the right "out" line?** Or should a login count as out only at the provider's 100%
  or the user's own line? A named constant either way; it could become a per-project setting if
  people disagree.
- **Should slice 4 move a conversation back** to the first entry when its window resets? The
  [usage-aware accounts](usage-aware-accounts.md) draft leans towards staying put.
- **Should the app-wide order of usage-aware accounts §B1 become the fallback** for projects
  without a list, or does a per-project list make it unnecessary?
