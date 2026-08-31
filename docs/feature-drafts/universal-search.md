# Universal Search

**Status:** Implemented baseline — researched 2026-08-29 and shipped in-tree 2026-08-31.

This document preserves the SEARCH investigation, the competitor/user-feedback synthesis, and the
resulting product contract. It also records the implementation now present on macOS, the remote
host, and iPhone. Sections explicitly labelled future work remain design constraints rather than
claims about the shipping baseline.

## Decision

Threading will have one host-owned **Search** capability with three explicit scopes:

- **View** — the active conversation, terminal, browser page, Git review or other surface that
  can reveal a local match.
- **Project** — the exact Threading project/checkout that owns the current context.
- **Everywhere** — every project, active and archived session, and other globally searchable
  host-owned destination the current client is authorized and able to open.

`Command-F` opens Search everywhere. It starts in **View** when the active surface has an honest
local provider and in **Everywhere** otherwise. `Command-Shift-F` opens directly in
**Everywhere**. Scope is always visible; “global” means the capability is available everywhere,
not that every query silently mixes every corpus.

The same semantic coordinator serves macOS and the remote iOS companion. The Mac owns global
indexes, provider execution, ranking, permissions and locator validation. The iPhone owns a native
presentation and local View providers, and asks its paired Mac for Project and Everywhere results.
It never downloads or maintains a second transcript or repository index.

Literal and structured retrieval ship first. Semantic retrieval does not silently participate in
ordinary ranking; a later **Ask History** mode may be evaluated separately.

## Shipping baseline (2026-08-31)

- macOS has contextual `Command-F` for Browser, Git Review and terminal buffers, a themed
  window-local universal overlay elsewhere, `Command-Shift-F` for Everywhere, and `Command-G` /
  `Command-Shift-G` match navigation.
- View, Project and Everywhere scopes share typed query, hit, locator, coverage, cap and ranking
  contracts. Structured navigation, conversations, file paths, attachment/browser metadata,
  registries and cancellable on-demand project text are bounded providers.
- Conversation text uses a rebuildable FTS5 index and resolves to a bounded, exact historical
  window. File and project-text hits resolve through contained, bounded readers.
- The remote host exposes owner-only `POST /api/search` and `POST /api/search/resolve`. Opaque
  locators are process-, device-, generation- and time-bound, single-use, and reauthorized on
  resolve.
- iPhone has a native, themed, lazy Search destination from the dashboard and session menu, visible
  scopes, external-keyboard shortcuts, exact project/session/terminal/archive routes, and bounded
  read-only conversation/file landings. The local terminal has its own SwiftTerm-backed find bar.
- Empty universal queries show recent destinations. Result caps and partial/indexing coverage are
  visible. Query text is not retained as search history.

Not in this baseline: pagination beyond the visible bounded result set, filter chips/completion UI,
offline catalogue search, Git Review remote landing, two-direction paging beyond the centered
conversation/file window, semantic retrieval, and the stress/latency measurements listed below.

## Why this is one feature rather than a larger command palette

Threading already contains several individually useful search paths, but the entry and result
contracts are fragmented:

- The editable Find command currently reaches Browser or Git Review and is unavailable on other
  macOS surfaces. The placement boundary and the reason the old terminal placeholder was removed
  are recorded in [`window-chrome.md`](../architecture/window-chrome.md).
- The vendored SwiftTerm already has real scrollback search, navigation, case sensitivity, regular
  expressions and whole-word matching, including public APIs on iOS and macOS:
  [`TerminalViewSearch.swift`](../../Packages/Vendor/SwiftTerm/Sources/SwiftTerm/TerminalViewSearch.swift).
- The command palette has stable identities, cancellable filtering, bounded results and virtualized
  rows, but it searches commands rather than user content.
- The workspace file contract already maintains a checkout-aware, bounded path catalogue.
- Settings, session dashboards, Git Review and the iOS dashboard each have their own narrower
  filtering UI.
- Native conversation rendering is virtualized, but recent replay and full provider history are
  different data sources. A hit is not useful until Threading can mount a bounded window around
  its historical locator.

The product opportunity is not “put more entries in the command palette.” Search owns a query,
scope, provenance, result limits and exact landing. The command palette owns actions. The file
picker owns fast path navigation. Their structured destinations may participate in Everywhere,
but their direct shortcuts remain:

- `Command-P`: file picker.
- `Command-Shift-P`: command palette.
- `Command-F`: Search, contextual by default.
- `Command-Shift-F`: Search Everywhere.

## Product invariants

These are release blockers, not aspirations:

1. **Scope is visible.** A user never has to infer whether a query means this view, this checkout
   or all of Threading.
2. **Every shown result has an exact landing available on that client.** A result may not be
   emitted merely because text matched. The provider must also supply a revalidatable locator and
   the presentation must know how to open it.
3. **Provenance is part of the row.** Project, session, provider/author, relevant branch or path,
   and date appear where they disambiguate a hit.
4. **Literal search stays literal.** Exact identifiers, filenames, phrases and tokens are never
   displaced by an opaque semantic score.
5. **Slow providers do not hold fast providers hostage.** Results arrive in stable groups under
   fixed budgets. A late group never moves the selected row.
6. **Caps are visible.** The UI says `100+`, `More results`, `Still indexing`, or `Refine your
   search`; it never silently truncates.
7. **Queries are ephemeral.** Threading does not persist search queries by default. Queries often
   contain secrets, tokens, filenames and incident details.
8. **A partial index admits partial coverage.** Provider gaps and backfill progress are visible;
   the product never implies a corpus is complete when it is not.
9. **Search is read-only.** Opening or revealing a hit uses existing navigation and authorization.
   It does not grant command execution, file mutation, session management or browser control.
10. **Presentation is native to each platform.** The semantic query and hit model is shared; an
    AppKit overlay is not serialized to the phone and a SwiftUI tree is not sent from the Mac.

## Scope contract

### View

View is the surface the person is currently looking at, not the whole session by implication.

| Active surface | View corpus | Landing |
|---|---|---|
| Native conversation | The complete conversation when its history source is searchable; loaded rows only during an admitted partial-coverage state | Mount a bounded conversation window around the row and reveal its matched run |
| Terminal | The current SwiftTerm buffer/scrollback on that device | Select and center the match through SwiftTerm |
| Browser | The current page through the existing browser find engine | Existing browser match navigation |
| Git Review | Paths, hunk headings and revealable diff lines in the current review | Existing review file/hunk/line reveal |
| File preview | The open text document when the preview exposes stable line locations | Reveal line/range |
| A surface without an honest provider | No View scope | Search opens in Everywhere; the disabled scope explains why |

Terminal scrollback is deliberately local and ephemeral. It is not copied into the global index,
and a terminal match on the Mac is not promised to an iPhone whose mirror retained a different
bounded replay.

### Project

Project means one persisted Threading project/checkout identity, not every sibling worktree for
the same repository and not a string comparison on project name. It includes:

- sessions and project terminals owned by that project;
- indexed conversation records for those sessions;
- Git-visible file paths from that checkout;
- project text only when the explicit on-demand provider is enabled for the query;
- relevant settings/actions only when they are both project-scoped and navigable on the current
  client.

An unscoped window, a disconnected phone with no resolved project identity, or a result launched
from a deleted project cannot claim Project scope.

### Everywhere

Everywhere searches authorized host-level destinations in grouped order:

1. Exact destinations: project, session, terminal, identifier, file or command.
2. Current-view matches, when Search was opened from a view.
3. Conversations.
4. File paths and explicit project-text results.
5. Settings and actions on clients that can open them.
6. Archived sessions and archived conversation history.

Everywhere does not mean raw filesystem contents, every terminal byte, reasoning, browser bodies,
draft text or unlimited tool output.

## Searchable content

### Default corpus

| Content | Index/treatment | Default rank group |
|---|---|---|
| Project/session/terminal titles, branches, providers, stable IDs and archive state | Structured, synchronously queryable metadata | Destinations |
| User and assistant messages and final responses | Incremental literal full-text index | Conversations |
| Tool calls and errors | Tool name, path/query metadata, status and a bounded summary; never the unbounded raw result | Conversations / Work details |
| File paths | Existing Git-visible workspace path index | Destinations / Files |
| Current terminal scrollback | View provider only; never durable global data | Current View |
| Current Browser and Git Review | Existing surface engines behind the View provider | Current View |
| Commands, scripts and settings | Existing registries; only entries the current client can invoke or open | Destinations / Settings |
| Archived sessions | Structured metadata and indexed conversation records, labelled Archived | Archived |

### Explicit or later corpus

- **Project text** is an explicit cancellable provider over a selected checkout. Threading does
  not permanently index every working tree. It participates only when Project scope is active or
  the person deliberately enables project text in Everywhere.
- **Work details** may search bounded tool-output summaries. Raw tool output remains excluded.
- **Git history, execution audit and subagents** may become typed providers after each can produce
  an exact locator and a measured bound.
- **Ask History** may offer semantic retrieval later. It is a separate mode with separate
  labelling and ranking.
- **Extension results** require a future bounded provider contract. Extensions do not receive the
  user's query until the person has enabled that provider and its disclosure describes the data
  crossing the process boundary.

### Excluded by default

- provider reasoning/thinking;
- raw or unbounded tool output;
- arbitrary browser body text outside a deliberate View search;
- terminal history not present in the active emulator buffer;
- unsent drafts and pasteboard contents;
- arbitrary files outside a resolved checkout;
- secrets inferred from environment, account files or provider configuration.

## Query and ranking design

The initial query language is literal, deterministic and progressively disclosed.

Default ordering inside each result group is:

1. Exact stable ID, project, session, filename or command.
2. Metadata prefix.
3. Literal phrase/token match.
4. Metadata fuzzy match.
5. Recency as a tie-breaker only.

The parser ships these textual filters:

- `type:conversation`, `type:file`, `type:command`, `type:session`;
- `from:you`, `from:agent`;
- `project:`, `provider:`;
- `is:archived`, `has:error`;
- `before:`, `after:`;
- quoted phrases and negative terms.

Unknown filters produce a visible query error; they do not degrade into surprising literal tokens.
Visible chips and `from:` / `type:` completion are a follow-up presentation enhancement. When
added, they must write the same textual form into the query so search remains copyable and fully
keyboard-operable.

Providers return a **score tier and deterministic keys**, not arbitrary incomparable floating
scores. `SearchCoordinator` owns group order and tie-breaking. Once keyboard or VoiceOver
selection enters a group, later batches may append to or update that group but do not insert above
the selected hit.

## macOS presentation

### Shell and placement

Search is a window-local application surface, opened through the host command plane. Its visible
component belongs in `Sources/Threading/UI/Design/` and uses existing primitives such as
`ThemedSearchField`, `SearchMatchLabel`, `RevealHighlightView`, themed controls and virtualized
collection rows. Feature code owns coordination only; it does not instantiate a drawing AppKit
control. The full boundary is [`THEME_BOUNDARY.md`](../THEME_BOUNDARY.md).

The shell mounts through the window's safe overlay/content boundary. It never pins a full-width
bar to `window.contentView.topAnchor`, covers traffic lights, or independently guesses the themed
frame geometry. Implementing the shell requires updating the durable Find rule in
[`window-chrome.md`](../architecture/window-chrome.md): View providers remain surface-owned, while
the universal shell is a named window overlay that delegates matching and reveal to them.

The shipping presentation has two cooperating layouts under one semantic contract:

- **View mode:** the existing Browser, Git Review or terminal surface owns its compact field,
  count, Previous, Next and Close behavior. Browser is not forced to manufacture snippets merely
  to resemble transcript search.
- **Project/Everywhere mode:** a themed universal overlay presents visible scope above grouped,
  virtualized results, provider progress and visible caps.

Escape closes Search and restores focus to the surface that opened it. Return opens/reveals the
selected result; Command-G and Command-Shift-G navigate View matches. Changing scope preserves the
query but starts a new cancellable search generation.

### Current-surface boundary

Introduce a host-owned `SurfaceSearchProvider` seam rather than teaching the window controller
about Browser, Git Review, conversation and SwiftTerm cases. A provider states:

- whether View search is currently available;
- supported options and whether matches can be enumerated;
- query generation/cancellation;
- count/current position when available;
- next, previous, reveal and clear;
- a focus-return target.

The existing Browser and Git Review implementations adapt to it. SwiftTerm uses its public search
helpers, but Threading does not ship the vendored `MacFindBarView` as product chrome. Native
conversation results use the shared historical locator service; a separate compact loaded-row
View adapter remains future work.

## Remote iOS product design

The iPhone is not a remote bitmap of the Mac Search overlay. It is a native client of the same
semantic coordinator with a deliberately smaller result eligibility set.

### Entry points

- The dashboard exposes the universal Search destination. An empty query presents recent
  destinations immediately; typing searches the selected scope.
- A session's existing trailing actions menu gains **Search**. It does not add another permanent
  toolbar glyph to the already constrained session title row.
- Workspace destinations may expose Search through their existing action/menu chrome when View
  search is supported.
- `Command-F` and `Command-Shift-F` are registered at the mobile root command router so an iPad or
  iPhone with an external keyboard gets the same scope rules as macOS. The command does not live
  only on `RemoteTerminalView`, which would make it disappear from Native conversation and the
  dashboard.
- A result notification/deep link may open Search only with an opaque locator already authorized
  by the host. Query text is never put in a URL.

Search is a `MobileNavigationRoute`, presented as a full search destination rather than a compact
confirmation or a menu pretending to hold results. It uses the system search-field interaction,
the current remote theme, a visible View/Project/Everywhere scope picker, lazy grouped rows and
themed row plates. If it crosses a sheet/hosting boundary, the complete theme crosses through
`mobileTheme(_:)` as required by [`IOS_THEMED_DIALOGS.md`](../IOS_THEMED_DIALOGS.md).

### iOS scope behavior

- Opened from a searchable session surface, Search starts in **View**.
- Opened from a project dashboard or project workspace, it starts in **Project**.
- Opened from the root dashboard, it starts in **Everywhere**.
- Switching scope preserves the query. Leaving Search discards it.
- The scope control remains visible while results scroll.
- When the Mac is unreachable, Project and Everywhere show an explicit connection requirement.
  Only the currently mounted terminal's local View search continues without the Mac.

The phone does not remember query history. It may remember the last chosen scope only within the
current Search presentation; a later invocation derives its scope from context again.

### Results reasonable to show on iOS

A host result is eligible only when the paired iPhone has a native landing route:

| Content | iOS treatment | Initial release |
|---|---|---|
| Projects, active sessions and project terminals | Open the existing project/session/terminal route | Yes |
| Archived session metadata | Open the Archived destination and reveal the row | Yes |
| Active or archived conversation messages | Open a bounded read-only native conversation window centered on the matched row | Yes |
| Tool calls and errors represented as conversation rows | Same centered conversation landing | Yes |
| Current mobile terminal scrollback | Search the local SwiftTerm mirror and reveal locally; never ask the Mac to pretend buffers match | Yes, View only |
| Git Review paths, hunks and diff lines | Omitted until a typed mobile review locator ships | Deferred |
| Repository file paths | Open a bounded read-only file window at the exact relative path | Yes |
| Repository text | Open the same bounded file window centered on the exact line/range | Yes, explicit provider |
| Attachment names and bounded metadata | Open the existing attachment preview by session and attachment ID | Yes |
| Browser tab title and URL metadata | Open Browser Follow at the exact tab | Yes |
| Browser page body | View search only when Browser Follow gains an honest host-backed match/reveal contract | Deferred |
| Commands, scripts and Mac settings | Omit; the iPhone cannot safely execute/open their Mac destination | No |
| iOS settings | Local-only structured destinations may join later; they are not supplied by the Mac index | Later |
| Extension panel content | Omit until a panel declares a bounded searchable projection and native locator | Deferred |

An omitted result category is not a lower-ranked result category. The Mac filters by client
capabilities before returning hits so the phone never shows a dead row.

### Mobile result anatomy

Each row contains only what helps identify and open the hit:

- primary title or matched text;
- one bounded snippet with matched runs emphasized;
- project/session/provider and relative path where relevant;
- date and Archived state where relevant;
- a type glyph with an accessibility label;
- provider coverage/cap notice at the group level, not repeated in every row.

Rows are stable and lazy. Dynamic Type may increase row height; snippets cap by semantic content,
not by prebuilding hidden lines. VoiceOver reads type, title, provenance, snippet, position within
the group and whether more results exist. Opening a match posts an announcement after the target
is mounted and highlighted. Reduce Motion replaces the reveal pulse with a static search-match
state.

### Offline and degraded behavior

The global index stays on the Mac. In the shipping baseline a disconnected phone may search its
currently mounted terminal scrollback. Project and Everywhere require the host and say so; cached
snippets are never presented as complete results. An explicitly labelled **On This iPhone**
catalogue fallback and loaded-conversation View search remain future work.

An older Mac that does not advertise universal search keeps the existing dashboard filter and
local surface search. The phone explains that broader search requires an updated Mac rather than
issuing a route that will 404.

## Core architecture

### Semantic types

Create a Foundation-level search module with no AppKit, UIKit, SwiftUI or remote transport types:

```swift
struct SearchQuery: Sendable, Equatable {
    let text: String
    let scope: SearchScope
    let filters: [SearchFilter]
    let generation: UInt64
}

enum SearchScope: Sendable, Equatable {
    case view(SearchViewContext)
    case project(ProjectID)
    case everywhere
}

struct SearchHit: Sendable, Equatable, Identifiable {
    let id: SearchHitID
    let kind: SearchHitKind
    let title: String
    let snippet: SearchSnippet?
    let provenance: SearchProvenance
    let scoreTier: SearchScoreTier
    let stableOrder: SearchStableOrder
    let locator: SearchLocator
}

struct SearchBatch: Sendable {
    let provider: SearchProviderID
    let hits: [SearchHit]
    let coverage: SearchCoverage
    let continuation: SearchContinuation?
}
```

`SearchLocator` is internal routing authority, not display text. It names a canonical project,
session, source record, row, file, line, browser tab or attachment through typed values. A title,
snippet, relative path or provider path is never reparsed to decide navigation.

### Coordinator and providers

`SearchCoordinator` owns query generations, provider selection, cancellation, stable grouping,
quotas and client eligibility. Providers are typed and independently budgeted:

- `CurrentSurfaceSearchProvider` — adapter to the active `SurfaceSearchProvider`;
- `NavigationSearchProvider` — projects, sessions, terminals, branches and IDs;
- `TranscriptSearchProvider` — indexed user/assistant/tool-summary records;
- `WorkspaceFileSearchProvider` — existing checkout path index;
- `WorkspaceMetadataSearchProvider` — already-retained browser-tab and attachment descriptors,
  never a new terminal-buffer or filesystem scan on a keystroke;
- `RegistrySearchProvider` — commands, scripts and settings for a capable local client;
- later `ProjectTextSearchProvider`, Git history, execution audit and extension providers.

Providers return `AsyncSequence<SearchBatch>` or an equivalent cancellable stream. They never
touch presentation state. The coordinator drops batches from superseded generations and applies a
per-provider quota before a provider can starve another group.

Structured in-memory providers answer first. Transcript and project-text work runs off the main
actor. No provider performs filesystem, SQLite, process or IPC work from row configuration,
layout, draw or accessibility callbacks.

### Rebuildable conversation index

Conversation full text lives in a separate rebuildable SQLite database under Threading's
Application Support, not as raw transcript copies in `threading.db`. The durable store remains the
source of product state; provider transcripts and normalized live events remain the source of
conversation truth. This follows the persistence boundary in
[`persistence.md`](../architecture/persistence.md).

The search database contains:

- a source ledger keyed by provider, stable source fingerprint, size, modification time and parser
  version;
- normalized searchable records with project/session/type/author/date metadata;
- a provider-specific opaque source locator sufficient to reload the record;
- FTS5 columns for bounded title, body and selected metadata;
- schema/index generations and coverage state;
- no raw provider JSON blobs and no copied attachment/browser/terminal bodies.

Indexing rules:

1. Detect append, rewrite, truncation, deletion and parser-version changes explicitly.
2. Process only changed/appended bytes when the provider format permits it.
3. Use a per-source autorelease pool and fixed parse/transaction batches.
4. Commit normalized records and the source-ledger checkpoint atomically.
5. Index live normalized conversation events going forward so recent messages do not wait for a
   filesystem rescan.
6. Prune records for deleted sessions/sources and revalidate every selected locator.
7. Rebuild after schema corruption or incompatible index format without quarantining or disabling
   the durable project store.
8. Index Claude and Codex historical formats first. Add other providers only after their parser
   can prove coverage; report gaps rather than mapping unknown records optimistically.

The initial investigation measured 2,824 transcript sources in the real corpus and previously
observed a 10.3 GB process footprint when a scanner retained source data. It also ran a synthetic
SQLite 3.51/FTS5 feasibility probe: 250,000 documents built/optimized in about 3.6 seconds, with an
approximately 144 MB index; rare literal queries were effectively immediate while naive ranked
common-term queries took about 0.55–0.66 seconds. Those are feasibility numbers, not shipping
benchmarks. They justify FTS5 and reject unbounded `ORDER BY rank` over every common match.

### Historical exact landing

Historical landing is a prerequisite of conversation search, not polish after indexing.

Create a `ConversationWindowLoader` that accepts a validated `SearchLocator` and returns a bounded
window centered on the matching normalized record:

- stable presentation row IDs;
- rows before and after the anchor;
- `hasEarlier` and `hasLater`;
- the anchor row/range;
- source/index generation used;
- live/archived/read-only state.

The loader seeks by provider locator rather than replaying a transcript from byte zero. If a
provider cannot seek safely, it may use a bounded ledger/checkpoint strategy, but it may not load
the entire conversation on the main actor.

macOS and iOS use the same loader. The native conversation controller mounts the returned window,
reveals the anchor and can page in either direction. A live session keeps a separate route back to
the current edge; a historical window is not overwritten by the ordinary recent WebSocket
snapshot before the person sees the match.

If the source changed, the loader revalidates the record. It may repair to the same stable row or
return **Result no longer available**. It never opens the nearest unrelated text.

## Remote contract

### Discovery and authorization

Add `RemoteRESTFeature.universalSearch`. The host advertises it only to an authenticated
`ownerDevice` with `allSessions` scope. Search is read-only, so both `.view` and `.interact`
owner capabilities may use it; session-scoped guests and project-terminal shares never receive
the feature or the endpoint.

All remote providers reapply current visibility and owner-read rules at query and resolve time.
Archive changes, project deletion, session visibility and route capability are not trusted from
the index. Repository/browser/attachment hits keep the same owner-only restrictions as their
existing remote destinations.

### Routes

The baseline uses additive REST routes rather than the per-session live WebSocket:

- `POST /api/search` — start one bounded Project or Everywhere query and return the first grouped
  snapshot.
- `POST /api/search/resolve` — revalidate one opaque hit locator and return a typed mobile landing
  payload.

The first response is intentionally capped and asks the person to refine the query. Opaque group
pagination and before/after conversation-window routes remain future additions.

View search normally stays on the active client surface. Native-conversation View search may use
the host transcript provider to cover history not loaded on the phone, but it still sends a
session-constrained query and receives only conversation hits for that authorized session.

### Wire values

The additive DTOs in `ThreadingRemoteKit` are:

- `RemoteSearchScopeKindDTO`;
- `RemoteSearchRequestDTO`;
- `RemoteSearchGroupDTO` and `RemoteSearchHitDTO`;
- `RemoteSearchCoverageDTO`;
- `RemoteSearchResolveRequestDTO` and `RemoteSearchResolutionDTO`;
- `RemoteSearchConversationWindowDTO` and `RemoteSearchFileWindowDTO` for bounded read-only
  historical navigation.

The remote hit carries presentation values plus an opaque locator token. It never carries an
absolute provider transcript path, account configuration path, raw SQLite row ID or authorization
claim. The token is bound to the authenticated device, search generation and current host process,
expires after a short fixed interval, and is reauthorized when resolved.

`RemoteSearchResolutionDTO` is a closed, typed set:

- project/session/project-terminal;
- archived-session-row;
- conversation-window;
- repository file/line;
- attachment;
- browser tab.

An older client decodes an unknown hit kind through lossless-token fallback and omits that row.
An older host advertises no feature, so a current client never probes these routes.

### Transport bounds and cancellation

Shipping wire bounds are pinned in shared constants and may be adjusted only from measurement:

| Quantity | Bound |
|---|---:|
| UTF-8 query | 512 bytes |
| Parsed filters | 16 |
| Groups per response | 8 |
| Hits per group | 64 |
| Total hits in first response | 128 |
| Title | 512 UTF-8 bytes |
| Snippet | 1,024 UTF-8 bytes |
| Provenance fields | 8 |
| Encoded search/resolve response | 1 MiB |
| Active query per authenticated device | 1 |
| Opaque result-token lifetime | 60 seconds |

The phone debounces network search by 140 ms after the last edit while opening the UI immediately.
Each request carries a client generation. Starting a later generation cancels the URL task and
invalidates host work for the previous generation; a response from an old generation is dropped
before it touches UI state.

Future continuation tokens must capture query fingerprint, provider/group, stable cursor and index
generation. They must not expose SQL offsets. Until then, visible caps instruct the person to
refine the query.

## Privacy and security

- Queries and result snippets stay on the authenticated direct/hosted remote transport and are
  never written to diagnostics, analytics or query history.
- The search database is local to the Mac, rebuildable and excluded from cloud synchronization and
  support bundles by default.
- Remote responses contain bounded normalized snippets, never raw transcript records or absolute
  provider paths.
- The host filters result categories by authorization and client navigation capability before
  encoding them.
- Resolve rechecks authorization, current visibility, path containment and locator generation.
- Search does not cause browser navigation, command execution, filesystem mutation, session
  restoration or archive changes. Those remain explicit actions through existing gates.
- Exact-session guests may search rows already loaded in their one shared conversation locally,
  but receive neither global feature discovery nor an index endpoint.
- Project-text search opens files through the same descriptor-relative containment checks as the
  existing remote file browser.

## Customization-surface gate

Universal Search is deliberately **host-only in its first version**, under the gate in
[`CUSTOMIZATION_SURFACE_AUDIT.md`](../extensions/CUSTOMIZATION_SURFACE_AUDIT.md#gate-for-every-new-surface).

It is not initially a public extension component because it combines privileged cross-product
state, historical transcript access, repository paths, ranking, remote authorization and exact
navigation. Threading keeps these behaviors host-owned:

- scope and query parsing;
- provider eligibility and disclosure;
- ranking, grouping, quotas and caps;
- index lifecycle and coverage claims;
- permissions and remote projection;
- locator validation and navigation;
- selection stability, accessibility and result virtualization.

Themes own presentation roles through the existing macOS and mobile theme boundaries. A future
extension API may contribute typed, bounded `SearchHit` values from data the extension already has
permission to read. It may not replace the Search shell, see other providers' hits, choose global
rank, receive queries without disclosure, or supply an unchecked navigation closure.

## Scaling and performance contract

This feature crosses every risk pattern in the implementation-time
[scaling gate](../architecture/performance.md#implementation-time-scaling-gate): transcripts,
files, sessions, providers, remote clients and per-keystroke callbacks. The contract is fixed
before implementation.

### Cardinalities

| Quantity | Expected | Stress |
|---|---:|---:|
| Projects | 20 | 200 |
| Sessions | 200 | 5,000 |
| Searchable normalized conversation records | 100,000 | 2,000,000 |
| Transcript sources | 3,000 | 20,000 |
| Git-visible paths in one checkout | 10,000 | 100,000 |
| Concurrent authenticated remote clients | 2 | 32 |
| Visible result rows | 20 | 60 |
| Providers active for one query | 5 | 12 |

### Latency and work

- Search chrome appears and accepts typing in the first presentation frame. Opening Search starts
  no synchronous index build.
- Warm structured results reach the macOS coordinator within 50 ms.
- First useful warm transcript results reach it within 100 ms.
- On iOS, the target is first structured results within 250 ms on the deterministic LAN test path
  and within one network round trip plus 150 ms of host work on higher-latency routes. Transport
  and host time are recorded separately; these targets become claims only after measurement.
- Every edit cancels superseded provider, SQLite, process and remote work.
- Query cost is bounded by candidate/result budgets, not corpus size. Common terms do not sort all
  postings.
- Indexing cost is proportional to changed bytes/records and uses bounded transactions.
- Row realization, layout and accessibility are O(visible), with no hidden result views built.
- Provider and remote fan-out is capped. Thirty-two clients do not run thirty-two identical index
  backfills or duplicate immutable structured catalogues.
- Memory is bounded by the index connection/cache policy plus visible/current result pages; no
  query retains transcript source blobs.
- Live appends update the index in bounded batches without broadcasting one full query rerun per
  token.

### Required measurement

Add deterministic fixtures for:

- 5,000 sessions and 2 million normalized records;
- exact IDs, rare terms and deliberately common terms;
- live append, source rewrite/truncation/deletion and parser-version rebuild;
- navigation to a match older than 400 replay events;
- 100,000 file paths and explicit project-text cancellation;
- 32 remote clients issuing superseding queries;
- iPhone cold Search open, first result, scrolling, pagination, exact landing and reconnect;
- index unavailable/rebuilding while structured providers remain useful.

Record before/after measurements in `docs/architecture/performance.md` before turning these targets
into release claims. The bounded implementation is present; this stress matrix is still pending.

## Implementation record

The baseline was delivered in vertical slices, while keeping every emitted result navigable:

1. **Core contracts:** typed scopes, parser, filters, deterministic score tiers, stable ordering,
   groups, caps, coverage, generations, client capabilities and opaque typed locators.
2. **Bounded providers:** warm navigation projection, rebuildable transcript FTS5, workspace path
   catalogue, live attachment/browser metadata, command/settings registries and cancellable
   checkout-contained project text. Conversation and file loaders return bounded exact windows.
3. **macOS:** the themed Design-system overlay is mounted through the window overlay boundary;
   Browser, Git Review and SwiftTerm retain honest surface-local find; unsupported views fall back
   to universal Everywhere search. Existing Command-P and Command-Shift-P routes remain intact.
4. **Remote authority:** additive DTOs and owner-only routes enforce request bounds, stable project
   identity, iOS capability filtering, generation replacement and short-lived one-use resolution
   tokens. Resolve rechecks current projects, sessions, metadata and file containment.
5. **iPhone:** native grouped search with a 140 ms debounce, recent destinations, visible scope,
   caps and coverage; stable project/session/terminal/archive navigation; bounded conversation/file
   landings; attachment/browser routes; and local terminal find.

The remaining roadmap is deliberately separate from the shipping claim: group/window pagination,
filter chips and completion, native-conversation compact View search, offline catalogue fallback,
typed mobile Git Review landing, broader history providers, extension disclosure, Ask History, and
the stress/latency evidence below.

## Test ownership

The baseline owns the core/provider/remote contract tests and the macOS/iOS render fixtures now in
the tree. Items involving pagination, offline fallback, Git Review remote landing, large stress
fixtures, VoiceOver announcements and performance targets describe follow-up coverage.

### Core/unit

- query tokenizer/parser, quoted phrases, negative terms, textual filters and invalid filters;
- deterministic ranking/ties and group order;
- provider quotas, cancellation, generation drop and stable selection;
- locator coding/revalidation and deleted/moved targets;
- FTS normalization, Unicode tokenization, prefix/phrase behavior and snippets;
- source append/rewrite/truncate/delete/parser-version transitions;
- coverage and visible-cap semantics.

### macOS integration/UI

- command enablement and routing from every main surface;
- Browser, Git Review, SwiftTerm and conversation provider adapters;
- View/Project/Everywhere scope transitions;
- keyboard navigation, focus return, VoiceOver and Reduce Motion;
- virtualized row count and no hidden view construction;
- rendered evidence under System, light/dark authored themes and authored window chrome.

### Remote contract

- additive feature discovery and older-host/client compatibility;
- owner all-session authorization, read-only owner access and exact-session guest refusal;
- query/request/response/cursor bounds and malformed input;
- cancellation under superseding generations and disconnect;
- opaque locator expiry, device binding, generation change and resolve-time reauthorization;
- client-capability filtering: no dead iOS result kinds;
- no absolute paths, raw transcript records or queries in diagnostics.

### iOS integration/UI

- entry from root, project, session menu, workspace and external keyboard;
- context-derived scope and preserved query while changing scope;
- offline local View search and labelled metadata fallback;
- terminal local-buffer parity and no claim about Mac scrollback;
- active/archived conversation centered landing and two-direction paging;
- attachment/browser/review/file typed landing;
- lazy results, Dynamic Type, VoiceOver, Reduce Motion and keyboard overlap;
- visual evidence on compact/large iPhone, iPad/external keyboard, light/dark and an authored remote
  theme.

### Performance

- all stress fixtures and latency/memory contracts above;
- first-frame Search presentation while index backfill is active;
- common-term query cancellation;
- 32-client remote fan-out and reconnect;
- repeated open/close with no retained provider tasks, SQLite statements or mobile result views.

## Baseline acceptance criteria

The implemented baseline is accepted when all of these are true:

- Command-F is a useful entry from every macOS main-window state and every relevant iOS context.
- View/Project/Everywhere is visible and means the same semantic scope on both platforms.
- SwiftTerm search is exposed on macOS and in the local iOS terminal mirror.
- Project/session/file navigation results arrive without transcript indexing.
- Supported historical conversations are incrementally indexed with honest coverage.
- Conversation hits resolve to a bounded window centered on the exact indexed row on macOS and
  iOS without loading the whole transcript.
- Every iOS result kind has a native landing; unsupported Mac-only actions are filtered by the
  host.
- Archived results are labelled and navigable.
- Query, provider and wire caps are visible and tested.
- Search never persists query text or emits it to diagnostics.
- Guest/session-scoped remote credentials cannot query the global index.
- UI appearance has inspected rendered evidence from the real macOS and iOS product shells.

Release follow-ups are tracked explicitly rather than silently claimed: finish the stress/latency
matrix, broaden rendered accessibility/device coverage, and add pagination only if measured result
caps show that refinement is insufficient.

## Competitor research distilled

The original investigation compared product documentation with user-reported failure modes:

- [VS Code](https://code.visualstudio.com/docs/editing/codebasics) keeps local Find and workspace
  Search distinct, groups results by file and provides exact navigation. The lesson is to preserve
  context and a direct local path; [user feedback](https://www.reddit.com/r/vscode/comments/1rtccmi/i_hate_vscodes_default_global_search_feature_so_i/)
  reinforces how quickly filenames and surrounding context become lost in a long result list.
- [JetBrains Search Everywhere](https://www.jetbrains.com/help/rider/Searching_Everywhere.html)
  combines structured destinations and text while keeping categories visible. The failure mode is
  scope pollution and noisy/generated results displacing useful hits, including a
  [documented capped-result scope bug](https://youtrack.jetbrains.com/projects/RIDER/issues/RIDER-123944/Go-to-Files-search-has-non-indexed-items-in-the-search-results-when-searching-within-Solution-scope).
- [Slack search](https://slack.com/help/articles/202528808-Search-in-Slack) has strong `in:`,
  `from:` and date filters. The lesson is to expose those through chips rather than requiring
  syntax memorization; [partial-search feedback](https://www.reddit.com/r/Slack/comments/1sn863x/need_help_getting_better_at_slack_search/)
  also calls out loose matching and missing provenance.
- [Cursor conversation search](https://prod.cursor.com/help/ai-features/conversation-search)
  separates current-conversation and global-history intent. Historical discovery must ship with
  durable exact landing, not only snippets.
- [Linear search](https://linear.app/changelog/2025-04-10-new-search) demonstrates the usefulness of
  semantic retrieval, but exact identifiers and literal text must remain deterministic.
- [t3code](https://github.com/pingdotgg/t3code/blob/main/docs/user/keybindings.md) searches thread
  titles, projects, branches and selected conversation content from a palette. Its
  [reported large-tool-activity failure](https://github.com/pingdotgg/t3code/issues/5351)
  reinforces bounded providers and visible caps.

The common result is this draft's central rule: local and global intent may share one interface,
but scope, provenance, stable ordering, exact navigation and honest limits must remain explicit.

## Rejected alternatives

- **One blended omnibox with invisible scope.** Fast to demo, impossible to predict, and noisy
  providers crowd exact destinations.
- **Put everything in the command palette.** Actions and content search have different result,
  provenance, paging and navigation contracts.
- **Persist every checkout and terminal in one giant index.** Stale, expensive, privacy-hostile and
  dishonest about ephemeral terminal state.
- **Copy the Mac index to iOS.** Duplicates sensitive data, complicates invalidation and produces
  results the phone may not be authorized or able to open.
- **Send Mac UI to the phone.** Violates the semantic remote boundary and produces inaccessible,
  non-native interaction.
- **Show hits before exact landing exists.** A snippet that cannot be opened is not a search result.
- **Blend semantic similarity into literal rank.** Makes exact search non-exact and obscures why a
  result appeared.
- **Persist query history by default.** Search fields routinely receive secrets and incident data.
- **Expose global search to one-session guests.** The index itself reveals that other projects and
  sessions exist.

## Questions to answer from measurement, not taste

The core product decisions above are closed. These values remain deliberately measurable:

- whether the shipping 140 ms iOS debounce is the best typing/network tradeoff;
- the final page/response/continuation bounds after real corpus and tailnet measurements;
- whether Browser Follow can provide remote page-body View search without mutating or leaking the
  Mac browser state;
- which non-Claude/Codex providers can support incremental historical locators honestly;
- whether users need Work details or Ask History after literal search ships.

The empty-query question is closed: universal Search shows a bounded recent-destination list.
None of the remaining questions blocks the shipped baseline above.
