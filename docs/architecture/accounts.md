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

The composer starts on the standard handle, so a disabled *default* is the case that bites —
without `preferredAccount`, the login the user just switched off is still what a fresh session
launches on, while the chip names it as though it had been chosen. `preferredAccount` is the
standard login while it is on, else the first that is; `preferred(among:)` is the same rule as a
pure function, so it can be tested without a home directory to scan.

Two invariants matter:

- **The account sticks to the session.** Conversations are stored per account, so a resume
  must route to the same account or the id will not be found.
- **The default account launches with `env -u`**, not a bare command. A login shell may export
  an override, which would otherwise silently route to the wrong account.

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

The toolbar's trailing pill (`AccountUsageItemView`) shows the selected session's account
rate-limit pressure: a ring gauging the peak window beside every window's own value
(`5h 43% · 7d 73%` — Claude's own status-line vocabulary), monochrome until 75%, orange then
red past 92%, each value tinted by its own window's severity; clicking opens per-window bars
with reset countdowns. `AccountUsageService` caches
per account and keeps the last good reading through failed refreshes. The credential posture
mirrors `~/repo/claudex`: read the short-lived tokens the official CLIs already keep, use
them read-only, never refresh them.

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

Sources, per provider:

- **Codex** — `auth.json` (`tokens.access_token` + `tokens.account_id`) against
  `chatgpt.com/backend-api/wham/usage`, with the `ChatGPT-Account-ID` and `originator`
  headers the backend gates on. Primary/secondary windows are *positions*, not timeframes —
  each is named from its own `limit_window_seconds`.
- **Claude** — four sources, ordered by freshness, in `ClaudeUsageFetcher`:
  1. `<config>/.credentials.json` against `api.anthropic.com/api/oauth/usage` when the file
     exists. On this machine it does not (macOS keeps the token in the Keychain).
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
gauges the binding window and names it in its text (`5h 7% · 7d 56% · Fable 89%`).

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

The account menu is read against the model that *would* run if that login were picked, resolved
per account (the configured default is an account's own setting). Its line is
`Max · 5h 7% · 7d 56% · Fable 89% · Fable resets in 15h` — plan, every window, and when the tight
one comes back. The reset names its window rather than trailing the list bare: the binding window
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
actionable — a spent Fable window is escaped by picking something else. Each row states its own
scoped window and nothing more (`AccountUsageMenu.modelSummary`): `7d 89% · resets in 1h 1m`,
named by the window's *length* rather than by the model, which the row's title already says —
`UsageDefaults.windowID(forDuration:)` recovers `7d` from it, since a scoped window is named
after its model and its length is the only thing left that identifies the window. Rows the plan
meters no differently stay bare: their pressure is the account's, which every row would repeat
and none would distinguish. It reads the cache without asking for a refresh — the composer has
already prefetched, and a model list is not a new reason to spend a round trip per row.

A window whose `resets_at` has passed keeps its identity but not its percentage — the stale
value describes the *previous* window, so it renders as `—`, never as pressure. The pill
hides entirely for accounts with no usage source (Claude without either
source): a control with nothing to say is noise in the always-visible corner.

The same reading is put where an account is **chosen**, because that is the moment the number
changes a decision; the pill speaks only after the session exists. Twice over, at two
resolutions:

- `AccountUsageMenu` writes each login's reading onto its item in the account chip's
  menu, so the accounts are compared *before* one is picked. It shows the *cached* value and
  starts a refresh — a menu is built synchronously and a fetch is a network round trip, so
  the alternative to what is known is nothing at all. `prefetch()` is therefore called where
  the surface *appears* (launch, and each time the composer is shown) rather than where the
  menu opens, which is already too late for that open.

  It also carries a **ring** (`UsageRingImage`), because the text alone did not scale to the
  decision it exists for: `5h 0% · 7d 90%` is four numbers and two window names per account,
  so comparing three logins means reading twelve of them and holding the comparison in your
  head. A ring compares without arithmetic — the fullest one is the busiest account — and its
  tint says whether that matters. It shows the **peak** window rather than the first, since an
  account at `5h 0% · 7d 90%` is nearly out and a ring drawn from the 5-hour window would say
  the opposite. Drawn rather than composed from views, because `NSMenuItem` takes an image and
  no view at all — the same constraint that produced `ThemeSwatchImage`. The numbers stay: the
  ring is the glance, the text is the precise answer.
- `AccountUsagePanelView` draws the chosen account in full under the chips: a `UsageWindowRow`
  per window, each with the **time mark** that makes the number legible — fill short of the
  mark is under pace, past it is spending faster than the window refills.

`UsageWindowRow` and `UsageBarView` are shared with the toolbar's popover rather than
reimplemented: the composer and the popover ask the same question, so they draw the same
answer. The panel takes a *reading*, not an account — the composer owns the fetch and the
notification, the view owns the drawing, which is also what lets it be rendered from
synthetic data in a harness.

`AccountUsage.compactSummary` is plain text for menus and tooltips; the pill keeps its own
attributed build, which the model cannot produce because each value carries its own window's
severity colour.
