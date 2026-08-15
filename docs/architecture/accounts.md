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

The copied tail is not new provider output at the destination. Transcript readers normally key
their changed-only cache by path, so a migration also records the installed copy's exact byte
boundary through
`ObservedUsageLimit.transcriptWasMigrated`. Its value is cleared rather than copied: a 429 at the
tail belongs to the account the session left, and rediscovering it at the new path would claim the
destination refused before it had attempted a turn.

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

  A **model-scoped** window lives in `utilization.limits[]`, as an entry whose `scope.model`
  names a model; entries with no model are the account's own windows under another name and are
  skipped rather than drawn twice. A plan can meter some models separately (a weekly window for
  Fable beside the weekly window for everything), and on a session running that model the scoped
  window is routinely the binding one — 89% against a 56% account weekly is the number that
  stops the work. The endpoint and the CLI's cache carry the same document, decoded by one type
  (`ClaudeUtilization`), so a live API read brings its scoped windows with it. It did not
  always: the fetch used to decode only the fixed `five_hour`/`seven_day` pair, which dropped
  the scoped limits the response already named and left them recoverable only from a
  `.claude.json` cache that plenty of accounts simply do not have — the symptom was a login
  showing fresh 5-hour and weekly bars with its Fable window nowhere.

  The third source is still **merged into** a winner that arrived without scoped windows,
  which is the status-line feed's case — that feed does not carry them. `parsedScopedLimits`
  in Claudex's bridge anticipates the same data arriving through the status line one day;
  until it does, `.claude.json` is what backfills it. A reading that brought its own scoped
  windows keeps them: it is fresher than the cache by construction.

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
actionable — a spent Fable window is escaped by picking something else. It states the shared
numbers **once, in a header**, and each row only what meters *it*:

- The header (`AccountUsageMenu.modelMenuHeader`) is a disabled row — the same informational
  idiom as "No apps found" — titled with the login's name, since the account was chosen on
  another surface and a menu of readings had better say whose they are. Its line is the plan
  and the account's own windows with the binding reset: `Max · 5h 41% · 7d 77% · 7d resets in
  22h 10m`. Deliberately not the scoped windows, which belong to the rows.
- A row's line (`AccountUsageMenu.modelSummary`) is the windows scoped to that model, plus a
  countdown only when a window of the row's own is what binds: `7d Fable 89% · resets in 15h`.
  The countdown stays bare beside a single reading — attributing it there repeats a name three
  inches from itself — and names its window only when the row states more than one. Rows the
  plan meters no differently carry no line at all.
- Every row keeps its **ring**, gauging the binding window per model, so the row whose scoped
  window is nearly spent sits visibly fuller than its neighbours. Both menus draw the same
  ring, gauging the same binding window, because two rings a click apart that meant different
  things would be worse than no ring.

**This is the third design, and the header is what makes the first one work.** Scoped-only rows
were tried, and three models listed with a number beside exactly one of them read as two failed
lookups. Repeating the account's windows on every row fixed that and was the second design —
but on the common account with no scoped window at all it printed one sentence five times,
which reads as a rendering bug, not as five models. The header resolves both: a bare row under
a stated header means "nothing beyond the line above", and nothing repeats. The row that leaves
the choice to the CLI is metered by the account's configured default, or by nothing at all when
the account names none — in which case the header already said everything there was to say.

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

  **The reading is a table, not a sentence — this is the fourth design and the first one that
  scales to the comparison the menu exists for.** The line it replaced was
  `Claude Code · Max · 5h 27% · 7d 81% · 7d resets in 19h 36m`, toned per run, with a 14pt
  meter under the brand mark. Read one row at a time it was fine. Read as a menu it had five
  faults, and every one of them comes from the same root — *in a sentence, a value's position is
  set by the length of the name in front of it*:

  1. **No columns.** Three logins put their three 5-hour numbers at three different x positions,
     so comparing them is a search rather than a glance.
  2. **One separator for seven kinds of thing.** `·` joined runtime, plan, window, value, scoped
     window and countdown alike, so it gave the eye nothing to skip by.
  3. **`7d` written three times in one line** (`7d 37% · 7d Fable 0% · 7d resets in 2d 6h`) —
     and that repetition is what pushed the line past `ThemedMenuLayout.maximumWidth`.
  4. **So it truncated, and the countdown is what lost its digits**: `7d resets in 5d 1…`, a
     sentence claiming to be complete.
  5. **The meter could only ever be a hue.** 14×2pt under the mark: 27% and 37% draw the same
     length, so it repeated the tint the value already carried and added no second reading.

  Each window is now a `ThemedMenuMetric` — a named column, a bar, and the number — and the menu
  measures one column plan across every row (`ThemedMenuMetrics.metricColumns`), so every row's
  `7d` is stacked under every other row's. A plan metering one window leaves the `5h` cell
  **empty rather than closed up**: closing it would slide the remaining readings under a
  different heading, which is the one thing a column must never do, and the gap itself says that
  plan has one window. The bar is 32pt, wide enough that ten points of difference is visible —
  which is what makes the ranking pre-attentive and retires the argument for the meter under the
  mark. The numbers stay beside it: the bar is the glance, the number is the precise answer.

  **What paid for the columns was the section head.** The rows are filed under one head per
  runtime, so `Claude Code · ` — the longest segment on the line — comes off every row and is
  said once. This costs no navigation: a header is not a submenu, so reaching another runtime's
  login is still the one press it became when this stopped being two sections. A runtime with no
  login to offer keeps its bare row and gets *no* head, because a heading over a single row
  repeating its own name is furniture.

  The rest of the line redistributes by what it is. The **plan** joins the title's line
  (`titleDetail`), quieter than the name — demoting it to a second line would give a
  subtitle-height row to every login whose provider happens to report one. The **countdown** gets
  a right-aligned column of its own (`7d · 19h 36m`), which is what makes fault 4 structurally
  impossible: the columns are fixed and the *name* is elastic, so a menu at its width cap
  truncates the name — the one thing still recognisable from its first half — and never a number.
  `resets in` is dropped, since a column of countdowns states what it is by being one, but the
  countdown still **names its window**: it is not always the last column, and a bare one at the
  end of a row is read as belonging to whichever is. The **scoped model windows** are the one
  thing a shared column cannot hold — a scoped window's name is its length *and* its model
  (`7d Fable`), so a column per model would be a column almost every row leaves empty — and they
  take the row's second line, present on the few logins that have one.

  **Which image the row carries still depends on whether it has to name its runtime.** A menu row
  has exactly one image slot. Where the runtime is a foregone conclusion it holds
  `UsageRingImage`, as it always did. In the composer's identity menu it holds `AccountMarkImage`
  — but the **plain** mark now, not the metered one. Its 2pt underline existed only because a
  14pt slot was the only room a reading had; the columns carry the length now, so the mark goes
  back to being identity alone. (Composing mark and ring — the mark drawn *inside* the ring — was
  tried in the metered era and rejected on the render: at 14pt the enclosed mark is a coloured
  smudge that identifies nothing, which was the one job it was added for.)

  Tones are unchanged and still semantic: window names, separators and the countdown at the muted
  tier, values in the row's own ink until their window passes the warning threshold and in its
  severity colour after — the pill's grammar, which the model rows also keep. The tint remains a
  second signal, never the only one; the numbers say the same thing in any ink, and a classic
  selection band flattens every tone — text *and* bar — to its own authored pair.
  `AccountUsage.readings` is the shared structured source, and it now carries `fraction` beside
  `value` so a bar and the number next to it cannot disagree about whether there is anything to
  report: an expired window prints `—` and draws an **empty** track, never the full one a
  fraction carried over from the previous window would have drawn.

  `AccountUsageMenu.apply` is the seam: the reading half of `decorate` with the account lookup
  taken out, so a test and the dropdown render sweep both build the row the composer assembles
  rather than re-deriving it. `ThemedMenuItem.spokenSummary` is that row joined into one line —
  what the tooltip and VoiceOver get, since neither of them can see a column or a bar, and a row
  announced by its name alone would be a login with no reading at all.
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

And one thing the renders could *not* catch, because the fixture was too clean. The text columns
were fixed widths sized to the longest strings imagined for them, and the fixture's round
three-hour burn produces exactly those strings — but a *measured* burn writes minutes into every
figure (`6h 36m working  +1h 23m`), which is wider, and macOS 14 stopped clipping drawing to a
view's bounds, so the overflow ran out of the diagram and across the settings card's own frame.
The columns are measured from the strings actually drawn now, the old constants kept only as
floors, and `testTheDiagramDrawsNothingOutsideItsOwnBounds` renders the grid inside a transparent
margin with a minutes-heavy burn and asserts the margin stayed empty.

The accessibility label states both lanes' window counts and totals outright, because the whole
argument is carried by fill and by one extra break, and neither survives being read aloud.

## Your own limits, ahead of the provider's

The provider's limit used to be the only limit Threading knew: every consumer of pressure — the
pill's tints, `LimitEscapeRanking`'s eligibility, the scheduled-send headroom check, the
usage-window poke's guards — read a provider window against 100% of itself. A **custom limit**
(`CustomLimit`) is a line the *user* draws on one account, evaluated locally, feeding the same
consumers. Today it can tell you when you reach it; the rest of the ladder is
[the draft](../feature-drafts/limit-management.md).

A rule has three parts: a **metric** (what is measured), a **bound** (where the line is), and
**consequences** (what happens on approach and at the line).

- `CustomLimitMetric` declares three shapes and implements one. `fixedCap` reads a provider
  window's own `fraction` against a constant. `paceShare` and `syntheticWindow` are named in the
  stored enum so the record does not have to change shape when they arrive, and
  `CustomLimit.isSupported` is what stops a rule written by a later build being evaluated as
  though it were a fixed cap — a pace share's bound is a share of *elapsed time*, and reading it
  as a fixed cap would fire alerts at a line the user never drew.
- `CustomLimitTier` is the consequence ladder — `show`, `notify`, `hold`, `park` — ordered, so a
  higher tier implies the ones above it rather than being a separate list of opt-ins.
  `effectiveTier` clamps to what the build implements: a rule stored at `park` still evaluates,
  at `notify`, because a limit that decodes and then does nothing is the silent forgetting the
  stored raw values exist to prevent.

**Thresholds are fractions of the bound, not of the window**, and the direction is stated once
because the two halves disagreeing is how a notification ends up naming a number nothing else on
screen shows. "Tell me at 50% of the weekly" is a bound at `0.5` with one threshold at `1.0`;
"keep this under 80%, warn me on the way" is a bound at `0.8` with thresholds `[0.75, 1.0]`. What
a *sentence* names is always the percentage the **window** reads (`threshold × bound`), since
that is the number printed everywhere else — a receipt quoting a fraction of a bound would be the
only place in the app where "60%" meant something other than 60% of the window.

### The evaluator

`CustomLimitEvaluator` is pure, in `UsageWindowPlan`'s shape and for its reason: a rule standing
between a person and their own quota has to be arguable from a table, because every failure it
can have is a quiet one. An alert that did not fire and a hold that engaged on nothing look
identical from outside the app.

It takes the rules, the account's last `AccountUsage`, the thresholds already announced, and
`now`. It returns, per rule: consumed-of-bound, the raw provider fraction, the state, a
structured reason, and the thresholds newly crossed. The sentence a receipt prints is
`CustomLimitReceipt`'s job — keeping `L10n` out of the judgement is what lets the tests assert on
the answer rather than on this month's wording.

Two rules the assertions exist for:

- **A sparse jump fires once.** A reading that steps from 48% to 61% past lines at 50% and 60%
  names 60% and marks both. Announcing every line in between is the alert fatigue this feature is
  supposed to be careful about; marking only the highest would make the skipped line arrive one
  reading late.
- **An unknown reading is a missing reading, never headroom and never spend.** `notify` goes
  silent on it — an alert derived from a guess is noise — while `hold` and `park`, when they
  arrive, engage, and the receipt names the missing reading as the reason. "Over your line" and
  "cannot see" have opposite remedies. An **expired** window is an unknown reading: its
  percentage describes the turn before this one, and reading it as consumption would fire this
  instance's alerts off the last instance's spend.

**Severity is computed against the effective bound**, reusing `warningFraction`/`criticalFraction`
rather than inventing a second vocabulary. An account at 47% raw under a 50% line tints critical
while printing 47%: the number is the fact, the tint is the pressure. Nothing about a rule changes
a bar's length or its printed percentage — a bar drawing full at 40% would lie about the figure
beside it.

### Drawing the line where the reading is

`CustomLimitBounds` answers the question every surface that *draws* a window has and none of them
should compute for itself — a pill, a bar and a menu column disagreeing about which of two rules
binds a window would be three readings of one fact. It reports the tightest **supported** rule on
a window, the effective bound, and the severity that follows.

Two rules draw nothing. A rule at the provider's own line has no line of its own — a tick at 100%
would mark the end of the bar as though the user had put it there, and an alert-only rule made to
fire one notification must not add furniture to a gauge. And a metric this build cannot evaluate
cannot be drawn either, for the reason it is not evaluated.

**The line is a change in the track, not a second mark.** `UsageBarView.capMark` quietens the
track past the line and leaves the stretch before it at full strength; the boundary *is* the line.
A pace mark and a cap mark are not the same kind of thing — one is where the clock stands, the
other is where the user said to stop — and two identical 2pt ticks on a 6pt bar would be a puzzle
rather than a reading. The remainder keeps `cappedTrackAlpha` of its colour rather than vanishing,
because the bar is still a gauge of the *provider's* window and a remainder drawn to nothing would
say the window ends where the user's line does. The historical progress styles draw their own
trough and are left alone.

**Three things the line does not touch**: the fill's length, the printed percentage, and
consumption past the line — which still draws at full strength, because that spend really
happened. What moves is the tint, computed against the effective bound. A row reading 47% under a
50% line prints `47%` in the critical tint: the number is the fact, the tint is the pressure.

A quieter stretch of a 6pt bar reaches nobody who is not looking at it, so the rule also names
itself in the row's tooltip and in what the row is read out as.

**The identity menu's metric columns take the same tone**, and nothing else about them changes.
That is where a fenced-off login has to read as pressured, because it is the moment an account is
being *chosen*: a shared login at 47% of a 50% share is nearly spent, and a menu drawing it in the
same quiet ink as a free login at 47% hands the user the wrong one. The label, the value and the
bar's length stay the provider's, since a column that shortened or renumbered itself under a rule
would be answering a different question from the one the other logins' columns answer — on the one
surface where two logins are read side by side.

**The always-visible pill is opt-in per rule** (`showsInToolbar`, switched on the rule's own row).
That is the one surface a user cannot dismiss, and it must not acquire a new red state because
somebody made a rule to fire one quiet 50% alert; every other surface reads every rule, because
they asked to be there. An opted-in rule does two things and adds no segment — its window is
already printed. The segment keeps its raw number and takes the effective tint, and
consumed-of-bound joins the comparison the **ring** gauges: `CustomLimitBounds.bindingWindow` is
the fullest share of its bound rather than the fullest window, which is the shipped rule exactly
when no line is drawn. The ring's *fill* stays the provider's figure — a ring filled to
consumed-of-bound would report a level the account never reached, on the one control whose whole
job is to say how much is left.

**The model menu carries the scoped half**, which is the one surface where a scoped limit is
*actionable* — a spent Fable window is escaped by picking something else. Its header takes the
account's own windows' tones and each row takes its model's, so a line drawn on one model's window
tints that row and no other.

**The Limit History chart draws the cap as a horizontal `ThemedChartValueRule`**, not as a marker.
`ThemedChartMarker` is anchored to a `Date` and drawn vertically, which is right for the three
things it already marks — a reset, an expiry, a projected exhaustion all happen *at a time*. A
limit is not an event: it is a level the series is read against. Making it a marker kind would
have given that enum one case whose geometry contradicted the other four. Only a fixed cap is
drawn; a pace share's line moves with the clock, and one horizontal rule across a week of history
would be a line that was never there.

### The other two metrics

**Pace share** (`share × elapsedFraction`) is the shared-login shape, and its line **rises with
the clock**. That is why nothing reads `rule.bound` directly: `CustomLimitBounds.resolvedBound`
is asked for the line *at a moment*, and returns nil where it cannot be placed — a pace share on
a window whose length the provider never stated has no elapsed fraction to take a share of, and
inventing one would draw a line nobody set. Nil reads as "cannot see", which holds and does not
alert.

`consumedOfBound` treats **zero spend as zero consumption whatever the line is**. A literal pace
share opens each window with a bound of exactly zero and the division is `0 / 0`; the answer is
not "infinitely over", because nothing has been released and nothing has been taken from the
account's owner. That single rule is what the draft's proposed "grace floor" would have bought,
which is why there is no floor.

**Synthetic windows** (`CustomLimitTrailingWindow`) measure consumption inside a trailing span the
provider does not meter — a five-hour discipline recreated on a plan that meters only a week.
Funded by **fraction delta** over `UsageHistoryStore`'s samples, so the unit stays the provider's
own normalized metric and nothing is estimated. Three rules the arithmetic turns on:

- a **reset inside the span** ends the subtraction at the reset evidence; subtracting across the
  boundary would read a clear as *negative* consumption, which then reads as headroom — on the one
  metric whose whole purpose is to notice a burst;
- history that does not reach back far enough **cannot answer**, and says so rather than calling
  the unobserved hours zero;
- the span starts at the last sample **at or before** the boundary rather than the first one
  inside it. History is sparse, so the true value at the boundary is unknown and the two
  candidates bracket it; starting earlier can only over-count, which holds sooner. A rule that
  exists to notice a burst errs toward noticing.

Its **instance is the span itself** rather than the provider window's turn, which is what makes a
trailing rule re-arm sensibly: a line crossed and then left behind can be crossed again once the
spend has aged out. Keying on the provider window's reset would have meant one announcement per
*week* for a rule about five hours.

Ledger funding — the draft's second source, for an account with no live reading at all — is
deliberately not built: it is the one place this feature would put an *estimate* where a limit is
enforced.

### Tier 4: park

A park is a hold plus one more consequence: `ConversationOutbox` stops draining at the turn
boundary, the row carries a mark, and the composer gets a strip. It **does not stop the keyboard**
— a turn typed and sent by hand goes, and the copy says so. Two deliberate differences from a
provider park:

- **It is not the triangle.** `ThemedWarningMark` means "the provider stopped this and you cannot
  answer it". A self-imposed cap is conduct, not weather, so the row wears the `RowConductSummary`
  mark — the family that already marks rows whose non-inherited settings act when nobody is
  watching — and the strip swaps its mark for the same glyph. There is no new `SessionActivity`
  case: the process really is idle and the provider really would accept a turn.
- **Continue Anyway is real and scoped.** The rule is the user's own, so overriding it is
  legitimate. `CustomLimitOverrideStore` keys the permission by account, rule and window instance
  and prunes it at the reset, so one late-night exception does not quietly disable the rule
  forever. It is stored at `preference` criticality rather than `rebuildableCache`, unlike the
  alert ledger: losing a fired alert costs one duplicate notification, while losing an override
  silently re-parks a session the user has already answered for.

The strip is the escape strip's surface with a `source` — same geometry, same two offers, a
different mark and different words. A provider refusal **outranks** a park where both stand: it is
the one the user cannot answer, and naming the smaller fact on top of the larger one would be the
wrong way round.

`UsageBarView.drawnFillWidth` and `drawnCapTrackWidth` exist because a test reached the fill
through `subviews.first`, and the capped track inserted below it quietly made that a different
view — the test then reported a fill of zero for a bar drawing correctly. A gauge a test has to
index into is a gauge whose tests break on layering.

### Holding Threading's own spend

`CustomLimitBounds.hold` is **one decision for four seams** — the scheduled-send delivery, the
usage-window poke's guard table, `LimitEscapeRanking`'s eligibility, and the control plane's
admission — because a hold that four call sites each decided for themselves would be four subtly
different lines, and the user drew one. Only rules armed at `hold` or above are asked: a rule that
exists to colour a bar or fire one notification has not been given permission to stop anything.

Its two refusing cases are kept apart rather than collapsed into a bool, because **"over your
line" and "cannot see" have opposite remedies**. Holds engage on unknowns, asymmetrically with
alerts, which go silent on them: an alert derived from a guess is noise, while a hold skipped for
a missing reading spends the user's quota for a reason they cannot see.

What each seam does with it:

- a **scheduled send** stands aside and re-arms at the window's reset — the user asked for the
  message to go, and a limit is a "not yet" rather than a "no". `ScheduledResetPolicy` bounds how
  many times that may happen, and a hold with no reset to wait for lets the send through rather
  than eating it. The reset-anchored `hasRoom` check takes the effective bound too: on an account
  fenced at half, 60% is not room;
- the **usage-window poke** gains a `customLimitReached` row, last in the guard table, because
  every guard above it describes the provider's arithmetic and this one describes a line over it;
- `LimitEscapeRanking` refuses a fenced login as a destination and reports it through
  `exclusions`, so a receipt can say **"excluded by your limit"** rather than leaving it looking
  spent — silent exclusion slanders an account with headroom and points the user at the provider
  for a line they drew themselves. Its pace deficit generalizes to
  `bound × elapsedFraction − usedFraction`, which is the shipped formula exactly when no rule
  draws a line, and is the "yours vs. theirs" answer when one does;
- the **control plane** refuses `send_to_session` with `targetHeldByOwnLimit`, carrying the rule's
  own sentence. The check runs *after* the scope checks, so a caller cannot learn whether a
  session outside its scope has a limit on it. The plane asks through a `Dependencies` closure
  like every other fact it needs, so the refusal matrix stays a table test.

### Window instances, and why a rule re-arms

A rule re-arms when its window does, and "when its window does" cannot be read from the
identifier: `7d` is the same window all year. `CustomLimitWindowInstance` is the window's id
**plus its reset moment**, and that pair is what tells this week's weekly from last week's.
`UsageAlertLedger` keys its fired thresholds by account, rule and instance — the account is part
of the key because a rule inherited from the app-wide defaults is the *same rule id* on every
login, and without it the first account to cross 50% would silence the other four.

Pruning is what re-arms: a record whose `resetsAt` has passed is dropped, and the dropped key is
returned so the notification it posted is withdrawn. **The ledger key is the notification's own
request identifier**, which is what lets a relaunch take down what the run before it delivered; an
in-memory set of delivered ids would have left last night's "weekly reached 50%" sitting over this
morning's fresh window. A window the provider reports without a reset never prunes on time, so the
map is bounded by count as well.

### Not an attention alert

`UsageAlertCenter` is deliberately **not** a fourth `AttentionAlert` case. That family is
session-scoped and every case in it is a change the user can act on *in that session* — which is
why a provider limit stop posts nothing at all. A usage alert is account-scoped, explicitly
subscribed to by the rule that fires it, and actionable at the account level: slow down, switch
login, change model. So it has its own switch, and the session-attention master switch does not
gate it — someone who silenced their sessions has not thereby said they no longer want to hear
about their quota.

Evaluation is **edge-driven, never polled**: a new reading (`AccountUsageDidChange`), and a rule
being edited. A fixed cap moves only when the reading does, so those are the complete set of
moments its answer can change; the armed wakeup the draft describes belongs to the pace-share
metric, whose bound rises with the clock, and arrives with it.

A later line on the same rule **replaces** the earlier banner rather than stacking beneath it,
because the request identifier is the rule's turn of the window. "Every 10%" on a busy account is
the user's explicit choice; five banners about one window is not what they chose. Switching alerts
off withdraws what they said and **keeps the ledger**: clearing it would make switching back on
inside the same window announce every line already crossed, in one burst.

Two locks keep this out of a test run, the convention the poke set: `CustomLimitSettings` and
`UsageAlertLedger` write through `PreferenceStore`, which redirects to a scratch suite under a
hosted test bundle, and `UsageAlertCenter.start()` refuses outright when `XCTestCase` exists.

### Where a rule is stored

Two scopes, not three. Per-account rules live in `AccountPreference.customLimits`, app-wide
defaults in `CustomLimitSettings`, and **absent means inherit while empty means none** — which is
why the account-level field is optional. An account whose owner cleared its rules must keep having
none rather than quietly picking the app default back up, and a plain array could not say so.
Project and session scopes are deliberately not offered: a limit is an account fact, and a
per-session budget is an *authority* that belongs to the control plane's grants.

Resolution is one seam (`CustomLimitSettings`), and the two editing verbs live there rather than
on the account store, because both are resolution questions:

- **Adding** a rule to an account still on the defaults **materializes what it had** and appends.
  The other reading — a first rule replacing the inherited ones — is surprising in the direction
  that silently stops telling somebody about their quota.
- **Removing** an inherited rule materializes the same list minus that rule. A Remove button that
  did nothing because the list it was drawn from belongs to another scope is the quietest kind of
  broken, so an inherited row is drawn like an owned one, marked `from All Accounts`, and works.

`AccountPreferencesStore` moved to `PreferenceStore` with this. Everything in that blob is a
choice — an icon, a name, a login switched off, and now a line drawn on a quota — and the tests
are hosted in the app, so `.standard` there was the developer's own account preferences.

### The page

`AccountLimitsSectionController` is the "Your Own Limits" half of the Accounts page: the switch,
an **All Accounts** fold, one fold per login, and a note that says what this slice does *not* do.
The app-wide fold comes first because it is the one that explains the others — a login's rule
reading `from All Accounts` is only legible beside the place those were set. It is its own controller
because it holds state the rest of that page does not — which folds are open — and the page
rebuilds itself wholesale on every edit; a fold that closed each time a rule was added would be
the page arguing with the person using it. Its stores are injectable, so its tests drive it over
their own suite rather than leaving rules in whatever the next test reads.

The templates are named in the user's terms — *Tell me when… Weekly… it reaches 75%* — and the
windows offered come from what the account's reading actually reports, so the menu never offers a
limit on a window this login does not have. With no reading yet, the two lengths both providers
normalize to are offered, and the resulting rule reads "No Weekly reading yet" until one
arrives — which is the honest state, and visibly so. Naming a window with no reading is what
`UsageDefaults.label(forWindowID:)` exists for: there is no `Window` to take a `label` from until
one lands, and the identifier is a key — a key on screen reads as a leak.

Two defects the render caught and no assertion would have, both now asserted directly:

- the cards sat at about a third of the pane while every assertion about the section's width
  passed, because a vertical `NSStackView` aligned `.leading` gives each arranged view its
  *fitting* width. `SettingsUI.page` states the same rule for its own sections and for the same
  failure; a view that *is* one section has to restate it internally.
- with the label column cut to that width, a one-line caption wrapped into five lines and
  `Claude Code` truncated to `Clau`.
