# Project Insights Extension

> Status: feature draft — product scope and reusable host seams are decided; implementation is
> intentionally separate from the native glanceable project card.

## Decision

Keep the native project-row hover small and automatic:

- code lines, files, and language composition;
- commits during the past twelve weeks;
- latest commit time.

Build deeper repository analysis as a safe Project Insights extension. Its full panel can show
hotspots, churn, coupling, and ownership without turning every pointer dwell into a repository
survey or making those opinions part of Threading's core UI.

Two generic host additions are required before that extension is useful:

1. a separately approved, bounded repository-analysis read capability; and
2. a host-owned way for a project action to open an extension panel with project context.

No chart- or graph-specific renderer is required for v1. Existing semantic nodes and
`ExtensionScene` cover bars, treemaps, and a coupling matrix. Add a more expressive graph
primitive only after several extensions demonstrate a meaning that scenes, lists, and matrices
cannot express accessibly.

## Why these metrics

The hover answers questions that remain meaningful across languages and project types: what the
project is made of, whether it has been active recently, and when it last changed. Threading can
compute all three cheaply, cache them independently, and state their time window precisely.

The following candidates do not belong in the native card:

| Candidate | Decision | Reason |
|---|---|---|
| Global complexity score | Extension only | scc's language analyzers do not produce one comparable unit across a polyglot repository. |
| Comment or blank-line percentage | Omit by default | Easy to calculate, weak as a quality signal, and visually competes with composition. |
| Estimated effort or cost | Omit | COCOMO output looks authoritative while depending mostly on line count and broad assumptions. |
| Repository disk size | Storage surface | Generated output and dependencies make it ambiguous; reclaimable storage already has stronger gates. |
| File hotspots and churn | Insights panel | Useful, but proportional to history and path-sensitive. |
| Co-change coupling | Insights panel | Requires bounded history analysis and a larger explanatory surface. |
| Ownership and bus factor | Insights panel | Useful only with careful identity privacy and explicit methodology. |
| Test coverage, CI, vulnerabilities | Later extension facets | No universal local source; provider/build integrations must state provenance and freshness. |

## Product shape

The extension contributes three entry points that all open the same project-scoped panel:

- **Project Insights…** in the project row menu;
- an optional **Open insights** button after `.proceed` in
  `sidebar.project-hover-card@1`; and
- a rebindable project-scoped command.

The hover contribution contains only the action. It does not load deep analytics. Threading owns
the popover lifecycle and the transition into the display panel.

The first panel version has these sections:

1. **Overview** — the host composition and twelve-week activity aggregates, with measurement
   time and HEAD revision.
2. **Hotspots** — a treemap sized by code lines and coloured by bounded recent churn, plus a
   virtualized top-file table.
3. **Change** — commit buckets over a selectable bounded window and top additions/deletions.
4. **Coupling** — a top-N co-change matrix and ranked edge list. A force-directed graph is not
   necessary to explain the data.
5. **Ownership** — anonymized contributor concentration and estimated bus factor, with the
   method and completeness visible beside the result.

Dependency manifests, forge state, CI, coverage, and vulnerability sources can become later
facets. They should use their own capabilities or `network.brokered` grants rather than being
smuggled into the local-repository contract.

## Existing extension pieces to reuse

Safe extensions already have nearly all of the presentation machinery:

- `sidebar.project-hover-card@1` supplies sanitized project context and a host-owned action seam;
- `ExtensionPanel.loadActionID` supports explicit, context-dependent loading;
- text, status, picker, disclosure, and virtualized vertical-stack nodes cover the explanatory
  UI and tables;
- an `ExtensionScene` supplies up to 500 normalized, semantic marks for the hotspot treemap,
  activity bars, and coupling matrix;
- scene marks already carry visible labels, accessibility labels/values, selection, and actions;
- `host.events` plus revision-bearing responses are sufficient for invalidation;
- extension-private cache storage can retain derived presentation state.

Scenes intentionally have no built-in axes, legends, tooltips, or repository semantics. The
extension composes those from ordinary semantic nodes. That is preferable to adding a
`dependencyGraph` node whose data model, layout, interaction, and accessibility would be useful
to only one feature.

## Reusable host API gap 1: repository analysis

Add this independent safe-extension authority:

```text
host.repositories.analysis.read
```

It is not implied by `host.projects.read` or `host.repositories.read`. The existing repository
snapshot exposes only sanitized remote identity, branch, and HEAD; analysis adds derived local
facts and, for file facets, relative paths. Installation and enablement must therefore describe
the additional access explicitly.

### Request

Add a host-broker method with a typed request resembling:

```swift
public struct ExtensionRepositoryAnalysisRequest: Codable, Sendable {
    public let projectID: String
    public let facets: Set<ExtensionRepositoryAnalysisFacet>
    public let lookbackDays: Int       // default 84, maximum 365
    public let topFileLimit: Int       // default 30, maximum 100
    public let couplingEdgeLimit: Int  // default 75, maximum 250
}

public enum ExtensionRepositoryAnalysisFacet: String, Codable, Sendable {
    case composition
    case activity
    case fileChurn
    case coupling
    case ownership
}
```

Validation happens before any work begins. The extension cannot supply a path, Git directory,
command, glob, revision range, raw Git arguments, or output-size limit. The host resolves an
authorized project ID and chooses the implementation and hard ceilings.

### Response

The response is a versioned aggregate envelope:

```swift
public struct ExtensionRepositoryAnalysis: Codable, Sendable {
    public let schemaVersion: Int
    public let projectID: String
    public let measuredAt: Date
    public let headRevision: String?
    public let state: ExtensionRepositoryAnalysisState
    public let composition: ExtensionCompositionAnalysis?
    public let activity: ExtensionActivityAnalysis?
    public let files: [ExtensionFileAnalysis]?
    public let coupling: [ExtensionCouplingEdge]?
    public let ownership: ExtensionOwnershipAnalysis?
    public let completeness: ExtensionAnalysisCompleteness
}
```

Every facet states its actual time window and sampled counts. `completeness` distinguishes
complete, truncated, unsupported, not-a-repository, no-commits, and temporarily unavailable
states and includes which host ceiling was reached. An extension must never infer completeness
from a short array.

The v1 data vocabulary is deliberately aggregate:

- composition: language, code lines, and file count;
- activity: fixed bucket boundaries and commit counts;
- files: repository-relative path, language, code lines, commits touching it, additions, and
  deletions during the requested window;
- coupling: two repository-relative paths, co-change count, and a documented normalized score;
- ownership: opaque repository-scoped contributor keys, concentration shares, and estimated bus
  factor.

Do not return absolute paths, Git directories, remote credentials, author names or emails,
commit messages, diffs, file contents, untracked-file contents, environment, or process output.
Opaque contributor keys should be derived in a host secret namespace so identities cannot be
joined across repositories or extensions.

### Host implementation

The wire contract describes facts, not the tool that produced them. Initially the host can:

- reuse `ProjectStatsService` for composition and twelve-week activity;
- use the bundled scc helper for bounded file composition;
- use `/usr/bin/git` with host-authored arguments for timestamps and numstat history;
- stream parse into top-N accumulators and sparse co-change counts instead of retaining raw log
  output;
- cache by project ID, HEAD revision, facet, and normalized request window;
- persist only the bounded aggregate response.

If a future scc release or another audited helper produces better analysis, Threading can switch
providers without changing the extension API.

Fast composition/activity facets may use the passive cache. File, coupling, and ownership facets
run only from an explicit panel load or refresh. They skip a project with a working session and
return `temporarilyUnavailable` rather than competing with a build. Proposed hard ceilings are:

- 365 days;
- 50,000 commits inspected;
- 100,000 changed-file records streamed;
- 100 returned files;
- 250 returned coupling edges;
- 30 seconds per deep facet and 16 MiB combined process output.

These are implementation maxima, not promises that every request reaches them. Instrument elapsed
time, records inspected, truncation reason, cache hit, and output size without logging paths or
identities.

## Reusable host API gap 2: project-scoped panel presentation

Panels currently load in the selected session's display context. A project-row action needs to
open a full panel even when the project has no session. Add:

```swift
public enum ExtensionPanelContextScope: String, Codable, Sendable {
    case session   // default for existing manifests
    case project
}
```

and an optional `contextScope` on `ExtensionPanel`. Existing packages decode a missing value as
`.session`, preserving API v1 behavior.

Add a host-owned presentation intent to both correlated response types:

```swift
public struct ExtensionPresentationIntent: Codable, Sendable {
    public let kind: ExtensionPresentationKind // .openPanel
    public let panelID: String
    public let context: ExtensionCommandContext
}

public struct ExtensionActionResponse {
    // existing fields...
    public let presentation: ExtensionPresentationIntent?
}

public struct ExtensionCommandResponse {
    // existing fields...
    public let presentation: ExtensionPresentationIntent?
}
```

The responding extension is implicit; it cannot open another package's panel. The host verifies
that the panel exists, its scope matches the context, the project/session remains visible to the
extension, and the intent came from the correlated action. Load actions cannot recursively return
another open intent. Invalid or stale intents become an ordinary localized error, not a partial
navigation.

On macOS, an `ExtensionPanelPresentationCoordinator` asks the main window to reveal the display
pane, installs/selects the extension panel tab, and passes the sanitized project context to its
load action. Threading owns selection, focus, restoration, tab chrome, and dismissal. The same
intent should be projected through `ThreadingRemoteKit` so another native host can choose an
equivalent presentation without receiving AppKit concepts.

This is a reusable navigation seam for any project dashboard, release report, artifact explorer,
or CI panel. It should not be named after insights.

## Why not filesystem, subprocess, companion, or Metal access

- Direct filesystem access would expose more than the aggregate feature needs and make ignore,
  symlink, size, and active-work safety every extension author's problem.
- A subprocess capability would turn a data request into arbitrary local execution and tie the
  extension to installed tools and shell state.
- A native companion's operating-system permissions are independent; invoking one does not grant
  it Threading's project model or justify passing a private absolute path.
- `ui.rendering.metal` is for constrained host-owned custom surfaces, not ordinary charts. The
  existing semantic renderer retains theme, accessibility, validation, and remote portability.

## Implementation order and effort

1. Add `host.repositories.analysis.read`, request/response models, manifest/schema support,
   broker routing, consent copy, bounds, caches, docs, and contract/security/performance tests.
   Estimate: **4–7 focused development days**.
2. Add project panel scope and `openPanel` presentation intents through ExtensionKit, the Wasm
   protocol, localization, macOS presentation, RemoteKit projection, schemas, examples, and
   tests. Estimate: **2–4 days**.
3. Build Project Insights as an ordinary safe reference extension using only those public seams.
   Start with overview, hotspot treemap/table, activity, and coupling matrix; add ownership after
   its methodology is validated on real repositories. Estimate: **4–7 days** for the first useful
   extension.
4. Reconsider a semantic edge/graph primitive only after the extension ships and at least one
   other extension has the same accessible interaction need.

The estimates exclude polishing a new analysis algorithm against very large monorepos. Each step
can ship independently: the native hover has no dependency on the extension, the analysis broker
is useful without special graph UI, and panel presentation is useful to extensions outside this
domain.

## Verification gate

- Codable/schema round trips and backward decoding for both new protocol additions.
- Capability denial, stale-context, cross-extension panel, path injection, and recursive-intent
  tests.
- Fixture repositories for non-Git, unborn, shallow, subdirectory-scoped, renamed-file,
  merge-heavy, non-UTF-8-path, and capped histories.
- Proof that output never contains absolute paths, author identity, commit text, or file content.
- Cache invalidation by HEAD and requested window, plus cancellation on extension generation
  replacement.
- Stress fixtures at every stated cap with no main-actor process wait or O(total) view creation.
- Semantic-scene accessibility and light/dark render stories; virtualized top-file rows at the
  maximum returned count.
- Finished-product capability/schema generation and extension example validation in CI.

## Rollout rule

Treat the bundled provider and limits as host implementation details. Treat the capability name,
aggregate field meanings, completeness states, privacy omissions, and project-panel navigation as
the public contract. If real use cannot state an important meaning within those boundaries,
version the data or semantic UI contract deliberately; do not leak raw host models as a shortcut.
