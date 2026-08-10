# Accounts and Usage

Multiple logins per CLI, how they are discovered and named, and the rate-limit readings shown beside them.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

Both CLIs support multiple logins via `CLAUDE_CONFIG_DIR` / `CODEX_HOME`. Accounts are
discovered from the filesystem, not from aliases, so they are found regardless of shell setup;
aliases are read only to supply a friendly label.

Admission requires proof of a real login (`.claude.json`/`settings.json` for Claude,
`auth.json` for Codex). Two things are deliberately excluded: Claude Science data roots
(`~/.claude-science`, or any root carrying `install-id` + `runtime/` + `orgs/`), which hold
Claude-shaped state but are not login slots; and aliases that set no config directory.

**Where a login is *chosen*, it is named after the person** (`AccountName`), not after the
alias. An alias is named after the agent — `claude-dblock`, `claude-vlundborg` — so a menu of
them asks the user to tell two logins apart by four characters in the middle of a word, and
`AccountBadge`'s initial has the same collision (both are `c`). The name is derived from the
login address instead: `daniel.block3@example.com` → `Daniel Block`, dropping trailing digits
because they are almost always "that address was taken". Names are resolved for the whole
*list* at once, since the failure being avoided is only visible across it — two logins
belonging to one person derive the same name, and a menu offering it twice is worse than one
offering two aliases, so a collision falls back to the address. The alias still names sessions
and still appears in the accounts settings page, which is where it is edited.

`AccountEmailProbe` exists because the **default** Claude login is the one account that cannot
be named from disk: alternates record `oauthAccount.emailAddress` in their own `.claude.json`,
while `~/.claude/.claude.json` carries a hashed `userID` and nothing else — its identity is in
the Keychain, which this app never reads. `claude auth status --json` reports `email`, honours
`CLAUDE_CONFIG_DIR`, and needs no token of ours, so the one unanswerable account is asked
directly. It costs a subprocess, so the answer is cached in `UserDefaults` and the probe runs
at most once per account per install — an address does not change while a login does not. Only
Claude: Codex's `id_token` already carries its `email` claim.

**An account can be switched off** (`AccountPreference.isDisabled`), which is the only kind of
"remove" this app can honestly offer: the account *is* a config directory, and deleting one is
the CLI's business, not a settings pane's. So the switch changes what is **offered**, nothing
else — `AgentAccountDiscovery.accounts(for:)` returns the enabled logins and `allAccounts(for:)`
returns everything found. The filter lives at that seam rather than at the thirty call sites
that list accounts, because the other arrangement fails silently: one menu keeps offering the
login the user turned off and nothing says which menu was missed.

Two places deliberately see a disabled account anyway. `account(for:handle:)` searches
everything, because a session records the account it started on and a resume must route back to
it — the account sticks to the session, switch or no switch. And the accounts pane lists
everything, since it is where a login is switched back on. `AccountName` also resolves against
every sibling: a disabled login still owns the address that would make another one ambiguous.

The presentation action on that row is deliberately **Restore Name & Icon**, not Reset. It
clears only the display-name and emoji overrides and leaves enablement, credentials, sessions,
and every usage reading untouched. “Reset” beside the Usage destinations made the last of those
easy to misread; the button now names the complete scope of its action on its face.

The composer starts on the standard handle, so a disabled *default* is the case that bites —
without `preferredAccount`, the login the user just switched off is still what a fresh session
launches on, while the chip names it as though it had been chosen. `preferredAccount` is the
standard login while it is on, else the first that is; `preferred(among:)` is the same rule as a
pure function, so it can be tested without a home directory to scan.

**Who a session runs as is one decision, so the composer's identity menu is one list.** It used
to be two sections — the selected runtime's logins, a separator, then the other runtimes — which
made every login of every *other* runtime two trips away: one to change runtime, another to pick
the login inside it, with a moment in between where the composer was pointed at that runtime's
preferred account rather than the one being aimed for. `identityItems()` now emits every login of
every runtime one row deep, and a runtime appears as a row of its own only where it offers no
login to name (it routes no accounts, or none were discovered). A row's represented value is a
`ComposerIdentity` — runtime *and* handle together — rather than one or the other: a menu that
returned a bare handle would let a Codex login set a Claude session's account, which is the shape
of bug the two-section menu could not have and this one could. Choosing any row resets the model
and the reasoning effort, whether or not the runtime changed, because both are properties of a
catalog the new login may not publish.

Two invariants matter:

- **The account sticks to the session.** Conversations are stored per account, so a resume
  must route to the same account or the id will not be found.
- **The default account launches with `env -u`**, not a bare command. A login shell may export
  an override, which would otherwise silently route to the wrong account.

`AgentAccountRouting` is the single implementation of those invariants for both launches and
provider lifecycle commands. In particular, Codex archive/unarchive must address the recorded
session account: using a bare `codex archive` would file a matching id under whichever
`CODEX_HOME` happened to leak from the login shell, while Threading changed a different account's
record. See [the provider archive boundary](sessions.md#the-provider-archive-boundary).

These are Claude/Codex capabilities, not assumptions about every runtime. Grok supports a
redirectable `GROK_HOME`, but multiple-login discovery and session movement have not been
measured, so its login remains inside the TUI. OpenCode provider
credentials and session data are shared while `OPENCODE_CONFIG_DIR` redirects configuration
only, so it is not presented as a Threading multi-account agent. OpenRouter authentication and
provider selection stay inside OpenCode (`/connect` and `/models`).

In the sidebar an alternate account is identified entirely by the session's icon slot — its
chosen emoji, else a letter badge (`c.circle.fill`) from its name — with the full name in the
tooltip. Rows carry no account text line, which keeps every session a single-line row.

This mirrors the logic in `~/repo/claudex` (`CredentialStore`, `HandoffLauncher`).

**Moving a conversation between accounts** (`SessionMigration`) exploits that a transcript is a
client-side file the CLI replays each turn, not server state bound to the originating account.
*Verified empirically*: a Claude transcript copied into another account's config dir resumed
with full context under that account. So a move is: copy the transcript into the target
account's directory and re-point `accountHandle`. The destination is the source path with its
**account-directory prefix swapped** — the layout under a config dir (`projects/<slug>/` for
Claude, dated `sessions/` for Codex) is identical between accounts, so one prefix swap serves
both agents. It is **non-destructive** (the original stays, so a move reverses), stops any live
process first (it belongs to the old account and is still writing the file), and Threading never
touches a token — the official CLI authenticates under whichever account, so this is
portability, not credential reuse.

Same agent only. Cross-agent (Claude ↔ Codex) is *not* a resume — the transcript formats,
provider state and resume paths differ. That distinction is visible in the second verb,
**Continue with Claude/Codex** (`ConversationContinuation`): it stops a live source after
confirmation, freezes its raw transcript under Application Support, and creates a new
provider-native sibling session. The source session and its transcript stay intact and
resumable; the destination records `continuedFrom` and `continuationSourceKind`, but has a new
provider conversation identifier.

The destination's deterministic first turn asks Threading's scoped `conversation_history` MCP
tool for every page of the frozen snapshot. Threading parses that snapshot through
`TranscriptReplay` into `[StreamEvent]` and exposes visible user/assistant messages plus bounded
tool calls and results. Private thinking, provider-only state, model selection and tool-call
identity do not cross the boundary. That makes the operation deliberately lossy, but symmetric
and honest in both directions: no Claude transcript is forged for Codex and no Codex transcript
is forged for Claude.

**A move is a relaunch, so it goes through `SessionCoordinator.moveSession`**, the same route as
the surface switch and for the same reason: the migration stops the live process, and a sidebar
reload alone left the pane holding a discarded controller — blank until the session was selected
again, which read as the move having done nothing. The coordinator reopens it
(`reopenIfShowing`), which resumes the transcript under the new account, and asks first when the
agent is running, under the `.moveRunningSessionToAccount` confirmation prompt — its own switch,
alongside the three other interruptions it is a sibling of.

Nothing is injected into the conversation to announce the move. The transcript *is* the context,
and it arrives whole; the account is who pays for the next turn, not something the agent needs
told. What does not travel is a live process and anything the CLI keeps per config directory —
project trust and per-project permissions live in `<config>/.claude.json`, so a project the
target account has never opened prompts once, exactly as it would have anyway.

## Account Usage

This section owns live account discovery, credentials, endpoint pacing and the compact toolbar
reading. The combined 90-day transcript ledger and durable 180-day limit/reset dashboard are
documented in [`usage-dashboard.md`](usage-dashboard.md); they consume these normalized readings
without taking over provider authentication.

The toolbar's trailing pill (`AccountUsageItemView`) shows the selected session's account
rate-limit pressure: a ring gauging the peak window beside every window's own value
(`5h 43% · 7d 73%` — Claude's own status-line vocabulary), monochrome until 75%, orange then
red past 92%, each value tinted by its own window's severity; clicking opens per-window bars
with reset countdowns. `AccountUsageService` caches
per account and keeps the last good reading through failed refreshes. The credential posture
mirrors `~/repo/claudex`: read the short-lived tokens the official CLIs already keep, use
them read-only, never refresh them.

The cache state is one `AccountUsageReading`, not a usage optional beside an error optional:
`.notFetched`, `.current`, `.stale(lastGood, error:)`, or `.failed`. A consumer that needs both
halves takes one snapshot, so it cannot observe the usage before a refresh and the error after
it, and a stale reading cannot be confused with either a fresh one or a first-fetch failure.

**The Keychain is read only with a standing opt-in** (`readsClaudeLoginFromKeychain`, the
Privacy page's "Live usage from your Claude login"). The old rule here was "never", for two
stated reasons, and both were retired by measurement rather than argument
(`ClaudeKeychainCredentials` records the probe):

- *"Items do not say which config directory they belong to."* They do. The CLI names its item
  per config directory: the default login owns the bare service `Claude Code-credentials`, an
  alternate owns `Claude Code-credentials-<first 8 hex of SHA-256 of the canonical config
  path>` — verified byte-for-byte against the three real logins on this machine, with the
  never-logged-in data root correctly owning none. A token is therefore attributable to
  exactly one account.
- *"An unbundled binary re-prompts every rebuild."* It would, so no background read is ever
  allowed to prompt: refresh-path reads run with keychain interaction disabled and *fail
  closed* (verified: `errSecAuthFailed`, no dialog), falling back to the cache chain below.
  The one interactive read lives behind the Privacy page's own toggle, where the macOS
  prompt is the direct consequence of the flip the user just made. A Debug build (ad-hoc
  signed, so its grant dies with each rebuild) quietly degrades to the caches; a release
  build's "Always Allow" persists.

The token stays in memory only, is never logged, and goes nowhere but the usage endpoint's
`Authorization` header. A 401 drops it and the next cycle re-reads — the CLI rotates the item
in place.

**Refreshes are paced from three directions** so the usage endpoints cannot be hammered: the
per-account floor (`minimumRefreshSpacing`) however eagerly the UI asks; a `notBefore` the
endpoint sets by answering 429 — honoured from `Retry-After` when sent, exponential with
upward-only jitter when not (`UsageRetrySchedule`), and respected even by `force`, because a
user clicking refresh must not be a way to spend a rate limit faster; and an event-driven
path that refreshes when a session *leaves* `working` — the one moment the server's number
has just moved. That last is CodexBar's "agent-aware refresh" done with certainty instead of
guesswork (Threading is told the turn boundary), and it is also the back-off: an idle app
generates no turn boundaries and therefore no extra requests.

The 429 counter means *consecutive 429 responses*: a success or any non-429 failure resets it.
Previously a network/decoding failure between two refusals left the counter intact, so the later
refusal inherited exponential backoff from a sequence that had actually ended.

Sources, per provider:

- **Codex** — `auth.json` (`tokens.access_token` + `tokens.account_id`) against
  `chatgpt.com/backend-api/wham/usage`, with the `ChatGPT-Account-ID` and `originator`
  headers the backend gates on. Primary/secondary windows are *positions*, not timeframes —
  each is named from its own `limit_window_seconds`.
- **Claude** — four sources, ordered by freshness, in `ClaudeUsageFetcher`:
  1. `<config>/.credentials.json` against `api.anthropic.com/api/oauth/usage` when the file
     exists. On macOS the live token lives in the Keychain instead, so where this file exists
     at all it is usually a leftover of an older layout — present, unrefreshed, and stale
     within the day.
  1b. The **Keychain token** (`ClaudeKeychainCredentials`, opt-in as above) against the same
     endpoint — the live source a macOS login actually has.
  2. **Claudex's status-line cache**:
     `~/Library/Application Support/Claudex/ClaudeStatus/<profileID>.json`, where `profileID`
     is the lowercase-hex SHA-256 of the standardized, symlink-resolved config-dir path
     (Claudex's own recipe, verified against the real cache files). Claude Code pushes
     `rate_limits` into that feed on every turn, so it is fresher than any polling — and reads
     as `source: .localCache`, which shortens the re-read interval from 300s to 30s.
  3. `<config>/.claude.json` → `cachedUsageUtilization` (`ClaudeUsageProfileCache`), the CLI's
     own copy of its last API reading. Staler — the CLI refreshes it on its own schedule, not
     per turn — but it needs neither a credential nor Claudex, so it is what an account with
     neither of the first two still reports.

  **A source that cannot serve hands the question down; it never answers for the chain.** The
  order above only means anything if every step falls through, and one did not: the credentials
  file's expiry check threw from *outside* the fall-through, so a stale token on disk skipped
  the Keychain, the status-line cache and the profile snapshot in one go and reported "The
  account's login has expired" — under an account whose CLI was mid-turn, with a status-line
  reading minutes old sitting unread beside it. A token source now returns `.usable`,
  `.unusable(reason:)` or `.absent`; only the last source left may name the failure, and
  "expired" is said only when a token really was refused *and* nothing below could serve. An
  account with no token anywhere reports `.noCredential`, not an expired login.

  The third source is also **merged into** whichever won, because it is the only one that names
  a **model-scoped** window. A plan can meter some models separately (a weekly window for Fable
  beside the weekly window for everything), and on a session running that model the scoped
  window is routinely the binding one — 89% against a 56% account weekly is the number that
  stops the work, and neither the status-line feed nor the fixed `five_hour`/`seven_day` pair
  carries it. It is findable only in `utilization.limits[]`, as an entry whose `scope.model`
  names a model; entries with no model are the account's own windows under another name and are
  skipped rather than drawn twice. `parsedScopedLimits` in Claudex's bridge anticipates the same
  data arriving through the status line one day; until it does, `.claude.json` is where it is.

  Scoped windows land in `modelWindows`, kept out of `windows` so the *account's* peak stays the
  account's — the rule Codex's per-model limits already follow.

### The binding window

`peakWindow` and `bindingWindow` answer different questions, and both are needed. The peak is the
account's pressure, which is what compares two logins. The **binding** window is what stops the
work in front of you: the fullest of the account's own windows *and* the scoped windows metering
the model that session runs. A weekly window at 56% beside a Fable window at 89% is comfortable
as an account and nearly spent as a session, and the toolbar belongs to the session — so the pill
gauges the binding window and names it in its text (`5h 7% · 7d 56% · 7d Fable 89%`).

### One name per window

A window is named by its **length**, and a scoped one adds the **model** it meters: compact
`5h`, `7d`, `7d Fable` (`Window.compactName`); spacious `5-hour`, `Weekly`, `Weekly · Fable`
(`Window.label`). Same structure, two registers — short in a menu line or the pill, long in a bar.

The scoped window used to print as its model alone, so one window answered to three names on one
screen: the composer's bar said `Weekly · Fable`, the account menu said `Fable`, and the model
row said `7d`. Worse than inconsistent — `5h 7% · 7d 56% · Fable 89%` sits a model's name in a
list of durations, and nothing in the line says what period that last number covers.

`id` was not available to fix it: it identifies the limit, it is what `ModelName.scope(_:meters:)`
matches a session against, and it is the key `UsageHistoryStore` files samples under. So the scope
is carried separately (`Window.scopeName`) and the length recovered from `windowDuration` — a
provider that reports a scoped limit without a window length keeps the bare model name, which is
then genuinely all that is known.

Which scoped windows apply is decided by name (`ModelName.scope(_:meters:)`), because the two
vocabularies never line up: a limit is named after the family it meters (`Fable`), a session
carries the id its CLI launched with (`claude-fable-5[1m]`). Containment reads the id and the
friendly name, so a limit matches the whole family rather than one dated version — and an
unrecognised pairing is deliberately *not* a match, since a scoped limit wrongly applied would
put a session in the red over a model it is not running. Naming no model at all reads the same
way: the account's own windows, never a guess.

The model the pill uses is the **effective** one — the session's own choice, else what the
account is configured to run — since that is what the next turn will spend. It is passed in
rather than looked up, because the pill follows a session and the session is what knows.

### Which model an unpinned session runs

Four sources answer "what will this run on", and `AgentModels.resolvedDefault` ranks them.
`ResolvedDefaultModel.Source` comes back with the answer because each is qualified differently on
screen — one is a setting to go and change, one is a fact about this session, one is a memory:

| Rank | Source | Row reads |
|---|---|---|
| 1 | the id this session's runtime announced when it started | `Opus · 1M  (in use)` |
| 2 | `model` in the account's `settings.json` / `config.toml` | `Opus · 1M  (account default)` |
| 3 | `orgModelDefaultCache` in the account's `.claude.json` | `Opus · 1M  (account default)` |
| 4 | what this login last resolved an unpinned session to | `Opus · 1M  (last used)` |
| 5 | the model the login's newest transcript recorded | `Opus 5  (last used)` |
| — | nothing | `Agent's choice` |

**The runtime outranks the config file, but only while the session pinned nothing.** The file is
our reading of what the CLI *would* pick; the announced id is what it did pick. After an explicit
switch, though, that id names the user's own choice — printing it on the row that means "leave it
to the CLI" would be actively wrong, where the generic string was merely unhelpful. OpenCode draws
the same line: *"switching models changes that session and does not rewrite your config."*

This started as a chip and a menu row disagreeing one click apart. The chip fell through
`session.model → reported → configured` while the row consulted only the config file, so a login
whose `settings.json` names no model — the common case, since leaving the choice to the CLI is the
default — showed `Opus · 1M` above a row still reading "Default model".

**Ranks 4 and 5 are evidence, not configuration**, which is why they lose to a config file that
has since changed and why they share one label. Rank 4 is what Threading watched a session
resolve to (`AccountPreference.lastReportedModel`, recorded only from sessions that pinned
nothing). Rank 5 is `ClaudeAccountLastRunModel`, which reads the same fact out of the transcripts
the login has already written — including every session it ran in a plain terminal, before
Threading existed on that machine.

Rank 5 is why the last resort is nearly unreachable. Measured on a real login: no `model` key
anywhere, no organisation, never once run inside Threading — and 167 transcripts whose newest
records `claude-opus-5`. The answer was on disk the whole time. It is deliberately labelled
*last used* rather than *account default*, because nothing in a transcript says whether that
model was inherited or passed as `--model`; "last used" is true either way.

**No rank invents a name.** Nothing here guesses the CLI's own fallback: that is negotiated per
subscription and is not recorded on disk. Three ways of asking for it were tried and none works
offline — there is no `claude models list`, `claude doctor` does not report it, and the
stream-json `init` event carrying the model is only emitted once a turn begins, so it cannot be
probed without spending an API call.

The comparable apps all guess instead — OpenCode falls back to "the newest available supported
model", Zed's hosted service pins one, VS Code carries the last used model globally and now cannot
migrate users off deprecated ones.

**The last resort says who decides, not what.** It reads `Agent's choice`, not "Default model".
The old words were the actual complaint that started this: a row reading "Default model" looks
like a setting whose value is being withheld, when the truth is that nothing has chosen yet. Only
a login that has never run this agent *anywhere* reaches it.

### Reading the CLI's own state file

`settings.json` is what the *user* wrote. `.claude.json`, beside it in the same config directory,
is what the CLI cached from the service, and it answers two things the settings file cannot:

- `additionalModelOptionsCache` — models beyond the documented aliases this login may select,
  each `{value, label, description}`. It carried `claude-fable-5[1m]` on both active logins
  measured, which no alias names, so before this was read that model could not be picked from the
  menu at all. Appended after the aliases, deduplicated by identifier.
- `orgModelDefaultCache` — a managed organisation's default model, at rank 3 above.

Both keys are **undocumented and frequently absent** — null on two of four real logins when this
was measured — and `orgModelDefaultCache` was null on all four, so its *shape* is unverified: a
bare string and two object forms are accepted and anything else reads as absent. Every read is
strictly additive; a miss leaves the previous behaviour exactly as it was. This is the same move
already made for Codex, which parses `models_cache.json` for slug, display name and service tiers.

**The aliases are not a hardcoded stand-in for a catalog.** `claude --help` documents `opus`,
`sonnet` and `fable` as *"an alias for the latest model"*, so they already track the newest of each
family and stay right as versions ship. There is no `claude models list` to query and no
cross-family notion of "newest" to compute — those three are tiers, not a timeline.

The account menu is read against the model that *would* run if that login were picked, resolved
per account (the configured default is an account's own setting). Its line is
`Max · 5h 7% · 7d 56% · 7d Fable 89% · 7d Fable resets in 15h` — plan, every window, and when the
tight one comes back. The reset names its window rather than trailing the list bare: the binding window
is not always the last one written, and an unattributed countdown is read as belonging to
whichever is.

**In that one menu the text is wider than the model** (`compactSummary(… scoped: .all)`), and the
ring is not. The account is picked *before* the model, so narrowing the text to the account's
configured default withheld exactly the number the choice needed: a login whose Fable window sat
at 89% read identically to one at 12% for as long as its `settings.json` said `opus[1m]`, and the
89% only appeared after the account was already chosen and the model switched. So the line names
every scoped window the login has. The **ring** stays metered by the resolved model, because it
answers the narrower question — what stops the session that would start now — and a model this
session is not running must not tint it. The two disagreeing is the point, not a slip.

Everywhere else the reading stays narrow (`.metering`, the default): a session already running a
model, and the mobile mirror of one, are subject to that model's windows and to no others.

The **model** menu carries the other half, since it is the only surface where a scoped limit is
actionable — a spent Fable window is escaped by picking something else. Each row states every
window a session on it would be measured against (`AccountUsageMenu.modelSummary`, `.metering`):
`5h 10% · 7d 22% · 7d Fable 89% · 7d Fable resets in 15h`. Both menus draw the same ring, gauging
the same binding window, because two rings a click apart that meant different things would be
worse than no ring.

**Rows the plan meters no differently repeat the account's windows rather than staying bare.**
Printing only the scoped ones was the first design and it was defensible — the account windows
are identical on every such row and distinguish nothing — but three models listed with a number
beside exactly one of them does not read as "two models with nothing of their own to say", it
reads as two failed lookups. Repetition is the cheaper mistake. The row that leaves the choice
to the CLI decorates too, metered by the account's configured default, or by nothing at all when
the account names none — in which case the account's own windows are the whole honest answer.

The model menu reads the cache without asking for a refresh per row; the conversation header's
copy of it asks once for the whole menu, since unlike the composer it has no prefetch on appear.

**Both model menus decorate — the composer's and the running session's.** The conversation
header's chip listed models with no readings at all for as long as it existed, which is the one
place the numbers are most actionable: switching model mid-conversation is exactly the move a
spent window calls for, and the pill only ever spoke for the model already running.

A window whose `resets_at` has passed keeps its identity but not its percentage — the stale
value describes the *previous* window, so it renders as `—`, never as pressure. The pill
hides entirely for accounts with no usage source (Claude without either
source): a control with nothing to say is noise in the always-visible corner.

The same reading is put where an account is **chosen**, because that is the moment the number
changes a decision; the pill speaks only after the session exists. Twice over, at two
resolutions:

- `AccountUsageMenu` writes each login's reading onto its item in the composer's **identity**
  chip menu — every runtime's logins, in one flat list — so the accounts are compared *before*
  one is picked. It shows the *cached* value and
  starts a refresh — a menu is built synchronously and a fetch is a network round trip, so
  the alternative to what is known is nothing at all. `prefetch()` is therefore called where
  the surface *appears* (launch, and each time the composer is shown) rather than where the
  menu opens, which is already too late for that open. Warming **every** runtime's logins, not
  the selected one's, is what a list spanning all four needs.

  It also carries a **gauge**, because the text alone did not scale to the decision it exists
  for: `5h 0% · 7d 90%` is four numbers and two window names per account, so comparing three
  logins means reading twelve of them and holding the comparison in your head. It compares
  without arithmetic — the fuller one is the busier account — and its tint says whether that
  matters. It shows the **peak** window rather than the first, since an account at
  `5h 0% · 7d 90%` is nearly out and a gauge drawn from the 5-hour window would say the
  opposite. Drawn rather than composed from views, because a menu row takes an image and no
  view at all — the same constraint that produced `ThemeSwatchImage`. The numbers stay: the
  gauge is the glance, the text is the precise answer.

  **Which gauge depends on whether the row has to name its runtime.** A menu row has exactly
  one image slot. Where the runtime is a foregone conclusion the slot holds `UsageRingImage`,
  as it always did. In the composer's identity menu it holds `AccountMarkImage` instead — the
  runtime's brand mark with the same reading as a meter underneath it — because a flat list of
  Claude, Codex, Grok and OpenCode logins is unreadable if a row cannot say which of them it
  belongs to. Composing the two (the mark drawn *inside* the ring) was tried first and rejected
  on the render: at 14pt the enclosed mark is a coloured smudge that identifies nothing, which
  is the one job it was added for. Underlining keeps both legible.

  The runtime is also **written**, leading that row's subtitle — `Claude Code · Max · 5h 7% · …`.
  The mark answers the glance, but one person's logins are frequently named the same thing on
  two runtimes, and two rows reading `Everlof` separated only by a silhouette is a coin toss. It
  leads rather than trails because the eye finds the start of a line, and because it is the one
  segment that survives a login with no reading at all.

  The line itself is **toned rather than printed in one grey**. The row draws it as
  `ThemedMenuSubtitleSegment` runs — window names, separators and the reset clause at the muted
  tier, values in the subtitle's own ink until their window passes the warning threshold and in
  its severity colour after — which is the pill's grammar transplanted to the menus (both of
  them: the model rows tint the same way). It exists for the same reason the gauge does:
  comparing three logins is twelve numbers, and printed in one ink the twelve hide the one the
  decision turns on. The tint is a second signal, never the only one — the numbers say the same
  thing in any ink. `AccountUsage.readings` is the shared structured source (name, value,
  severity per window, the stale-value rule decided once for the pill, the menus and the plain
  joins), and `AccountUsageMenu.summarySegments`/`identitySegments` are asserted directly, plus
  drawn by the dropdown render sweep with data chosen to hit every tone.
- The composer's own reading is **one line inside the prompt box**, on the row that carries
  what the session will run with. It is `AccountUsage.compactSummary` metered by the model the
  session would launch on, which is the same string the toolbar pill draws once the session
  exists, so the number a login is chosen on is the number that goes on being watched. Its
  tooltip carries what the reading cannot: whose account it is, where each window stands and
  when it comes back, and how old the reading is.

  It replaced `AccountUsagePanelView`, which drew every window in full under the chips, one
  `UsageWindowRow` per window with its bar and time mark. That panel had to be **told how much
  room it could have**, because one bar per window plus one per metered model is a list the
  provider lengthens and a panel taller than the pane makes the *window* taller — see
  [`window-chrome.md`](window-chrome.md#a-pane-cannot-be-taller-than-its-window). A line cannot
  do that, whatever the provider reports, which is the stronger version of the same rule and
  why the fitting pass went with the panel. The full drawing is still a click away in the pill's
  popover, where the pane's height is not at stake.

`UsageWindowRow` and `UsageBarView` belong to the toolbar's popover and the usage settings page
now. `AccountUsage.readings` is the structured reading every tinting surface consumes — the
pill's attributed build and both menus' toned segments — and `AccountUsage.compactSummary` is
the same list joined plain, for the surfaces that cannot tint: the tooltips and the composer's
line inside the prompt box.

**A bar travels to a new reading rather than appearing at it** (`UsageBarView.apply`): the fill
eases over `Design.Motion.standard` and the severity tint crossfades, while the words state the
new reading outright, because a number counting up is unreadable mid-count. The travel eases out
with **no overshoot**, unlike `ThemedToggle`, whose settle past the end is what gives its knob
weight: a gauge may not draw a value it does not have, and a bar sailing past 90% and easing
back would report a level the account never reached, on the one surface whose whole job is to
say how much is left.

`Design.Motion.standard` is zero under Reduce Motion, so the same guard that skips a pointless
travel is also the accessibility branch — and it lands the value synchronously rather than
costing a frame to arrive at what the caller is entitled to have now. A bar outside a window,
or one leaving it mid-travel, lands for the same reason: the display link retains the view.


## Usage Windows

The short window is **anchored**: it opens on the account's first message and resets a fixed
span later, rather than sliding continuously. That single fact is the whole premise of the
Usage Windows page, because it means the *phase* of the window grid belongs to whoever sends
that first message.

`AgentCapabilities.anchoredUsageWindow` states it, and Claude is the only claimant. The evidence
is `ClaudeUsageFetcher`'s own readings: `resetsAt` stands still through a session and jumps by
exactly five hours when a new window opens, which is an anchor. Codex reports a five-hour window
too, shared between local messages and cloud chats, but whether its reset is anchored or sliding
is unpublished, and the two are indistinguishable until an account goes quiet across a boundary.
So the flag stays off there until it can be measured from an account's own history — the honest
order, and the reason `AgentLauncher.usageWindowPokeCommand` already has the Codex branch written
behind the gate. Grok and OpenCode report no windows here at all, and xAI's acceptable-use policy
forbids scripted access outright, so neither is a candidate whatever it starts reporting.

Nothing in the feature is provider-named below that flag. The window it moves is
`AccountUsage.anchoredWindow`, chosen as the **shortest window the provider reports** rather than
by matching `5h`, and its length comes from the provider's own `windowDuration`. A runtime that
meters on four hours needs no change here.

### The arithmetic

`UsageWindowPlan` is pure, which is what makes a feature that spends someone's rate limit
reviewable at all. Two numbers drive it:

- **Burn** (`UsageWindowBurn`): how long this account takes to spend one window *while actually
  working*. Deliberately not "time from window start to exhaustion" — a window anchored at 07:00
  and exhausted at 15:00 did not take eight hours of work if two of them were lunch. Idle
  stretches are dropped and what is measured is the rate during movement, inverted. Nobody is
  asked for this number; `UsageHistoryStore` has been collecting the readings it comes from since
  long before this page existed.
- **Lead** = `windowLength - burn`. When the window opens exactly `burn` before the working day
  starts, it is drained at the moment it resets: nothing wasted in front of it, and no wait
  behind it. Lead too short and the morning ends capped; lead too long and the window expires
  before the first message, which is identical to not poking. That is why it is derived rather
  than typed into a box.

Measured against a nine-hour day at a three-hour burn: two windows and six productive hours
without a poke, three windows and seven with one. `UsageWindowPlanTests` asserts exactly that,
and the settings diagram draws it.

**It raises no limit.** The same window holds the same allowance and the weekly cap does not move
at all, so the extra window is a week spent faster. `weeklyAheadOfPace` is the consequence: when
the weekly window is running ahead of the clock (`fraction` past `elapsedFraction`, the same pace
comparison the bars draw), the poke stands down.

### Why it is not a cron line

Claude Code ships schedulers of its own, and a 07:00 job that sends `.` is three minutes of work.
What a cron line cannot do is **look first**. It fires whether or not a window is already open, so
on every day the user started early it spends a message to achieve nothing, and it can never
notice that yesterday's window is still open. Every rule worth having reads state only the app
holds: the reading, the burn history, whether a session is busy right now. `UsageWindowPoker`
gathers those and `UsageWindowPlan` decides; the runner itself is deliberately thin.

The rule that reopens a window expiring at lunchtime is not a rule. It falls out of "no window
open, inside the working day, past the poke time" — and the reason it does not then fire at every
boundary of a working afternoon is the `working` hold: a busy account opens its own window with
whatever it sends next, so poking it would pay for something that was about to be free.

### The guards, and why each exists

| Hold | What it prevents |
|---|---|
| `usageUnknown` | Poking blind. Without a reading, whether a window is open is a guess |
| `windowOpen` | Spending a message on a window that is already open |
| `working` | Paying for what the user's own next keystroke does for nothing |
| `settling` | The next tick reading the same stale reading and poking again |
| `neverExhausts` | Firing daily for someone who never reaches the short limit |
| `tailTooShort` | A window opened with an hour of day left, four hours of which expire overnight |
| `weeklyAheadOfPace` | Winning a morning by spending the week |
| `dailyLimitReached` | A defect in any rule above turning this into a poller |

The daily limit is not a tuning knob. It is enforced below the rules, and three is one more than
a nine-hour day needs.

### The run itself

One message, on the named account, through the official CLI. `usageWindowPokeCommand` routes with
the account's own environment key (a window belongs to a login, so poking the default one buys
the named one nothing), asks for the cheapest model, and carries no context at all: no MCP
servers, no tools, and a scratch working directory, so nothing loads a `CLAUDE.md` or a tool
catalogue whose input tokens would be charged to the weekly limit the feature exists to protect.
The reply is discarded unread; only the timestamp was ever wanted.

Two locks keep it out of a test run. `UsageWindowSettings` writes through `PreferenceStore`, which
redirects to a scratch suite under a hosted test bundle, and `UsageWindowPoker.start()` refuses
outright when `XCTestCase` exists. One would do; the consequence of neither — a background process
spending the developer's own weekly limit every morning — is worth two.

### The page

`UsageWindowPreferencesViewController` puts the explanation and the picture above the controls,
which is the opposite of every other settings page here and deliberate: this one configures a
consequence of how a subscription meters time, and it sounds like a trick until it is drawn.
`UsageWindowGridView` draws the same day twice, anchored where the first message would land and
anchored where the poke puts it: a block per window, the gaps between them the resets, the
productive stretch filled, and the hour gained in the accent colour beside the second lane.

**Every surface in it is drawn by `ThemedSurface`.** A window block is a trough in whatever the
current material says a trough is — flat with a hairline edge on the modern themes, a sunken
bevel under Platinum, and filled with chunks rather than a smooth bar under Win98, whose
`progressStyle` is `.segmented`. That last case is why `ThemedProgressDrawing.drawSegments` was
split out of `drawSegmented`: a surface drawing its own trough still has to fill it the way the
theme fills a progress bar. The first version drew its own 1pt border at its own corner radius,
which is how a diagram ends up looking like it came from a different app.

Three things the renders caught that no assertion would have.

- The day-start rule ran the full height of the view and struck through the lane titles. Moving
  the titles into a **left column** fixed the cause rather than the symptom: with the plot a clean
  rectangle, one rule serves both lanes and crosses nothing.
- Blocks carried three states (before you sat down, working, waiting), and the faint one was
  fighting the empty one. There are two now. Which state an empty stretch *is* comes from which
  side of the rule it sits on, which is what the rule is for.
- Platinum's caption is a taller face than the system one, and the axis label drawn on the floor
  of its band lost its descenders off the bottom of the view. It is centred in the band now.

The accessibility label states both lanes' window counts and totals outright, because the whole
argument is carried by fill and by one extra break, and neither survives being read aloud.
