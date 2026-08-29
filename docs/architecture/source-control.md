# Source-Control Providers and Change Requests

The provider boundary for Git Review and managed-workspace publication: remote detection,
GitHub pull requests, GitLab merge requests, authenticated forge operations, and safe remote-ref
lifecycle.

Part of the [CLAUDE.md](../../CLAUDE.md) index. Also read [git.md](git.md),
[github.md](github.md), and [managed-workspaces.md](managed-workspaces.md).

## The boundary follows the product workflow

`ChangeRequestProviderClient` is not a speculative common forge API. It contains the four
operations the two shipping adapters genuinely share:

1. report whether unattended creation is ready and name the credential source;
2. discover repository metadata and an open change request for an exact source branch;
3. read one change request's lifecycle by durable provider number;
4. create one draft or ready change request from a validated proposal.

The shared models carry repository identity, default branch, clone URLs, head/base branches,
head revision, draft/merged state, checks and review counts. Provider differences remain explicit
in `SourceControlProviderCapabilities`: GitLab approvals do not claim GitHub's
changes-requested review state, and GitLab has no browser creation fallback. UI copy asks the
provider for “pull request” or “merge request”; wire types never escape an adapter.

Local Git is a separate boundary. `ChangeRequestGit`, `GitProcess`, and
`ManagedWorkspacePublisher` inspect, compare and push commits. Provider clients perform forge
API reads and writes only. A successful API call can therefore never stand in for proof that an
exact commit was pushed, and a local Git credential is not treated as forge API readiness.

## Remote detection and supported hosts

Remote parsing accepts HTTPS, `ssh://`, and SCP-like syntax without retaining URL user info or
credentials. GitHub repositories must be `github.com/<owner>/<repository>`; GitLab.com accepts
nested namespaces such as `gitlab.com/group/subgroup/repository`. Repository and namespace are
derived from path components after stripping the terminal `.git`, never from provider-specific
URL string slicing.

Shipping support is deliberately host-specific:

| Provider | Host | Status |
|---|---|---|
| GitHub | `github.com` | supported |
| GitLab | `gitlab.com` | supported |
| GitLab | conventional self-hosted GitLab hostname | explicitly unsupported |
| Unknown forge | any other hostname | unrecognised |

A conventional `gitlab.*` hostname gets an actionable unsupported result. An arbitrary custom
hostname cannot be identified as GitLab from Git transport syntax, so Threading does not guess.
Supporting self-hosted GitLab later requires an explicit host trust/configuration decision and
tests for its API/authentication policy; the adapter never silently sends a GitLab.com-shaped
request to every remote host.

## GitHub adapter

`GitHubPullRequestClient` keeps the existing GitHub behaviour behind the provider protocol.
Idempotent reads walk the app connection, `gh`, git credential helper, then anonymous access.
Automatic writes require a native credential; interactive creation may fall back to GitHub's
prefilled compare form. A write may move to another credential only after an explicit
401/403/404 refusal. A transport failure or unreadable successful response is ambiguous and is
never retried, because GitHub may already have accepted the POST.

The GitHub-specific credential chain, device flow, issue filing, and brokered extension reads
remain documented in [github.md](github.md). Those are not universal provider behaviours.

Discovery reads both modern check runs and classic combined commit statuses for the request's
remote head revision. Each source requests 100 entries at a time and stops after five pages, so a
refresh performs at most ten check requests and retains at most 1,000 provider results. GitHub's
`total_count` makes a capped source report the exact number not loaded. A later-page failure keeps
the already-read outcomes and marks the summary incomplete; a first-page failure makes only that
source unavailable, so a working source is still shown with the same incomplete marker.

The adapter preserves every documented check-run status and conclusion rather than projecting
them immediately into pass/pending/fail. `success` is successful; `neutral` and `skipped` are
separate non-blocking outcomes; `requested`, `queued`, `waiting`, `pending`, and `in_progress` are
separate active outcomes; and `failure`, `cancelled`, `timed_out`, `action_required`,
`startup_failure`, and `stale` are separate attention outcomes. Classic `success`, `pending`,
`failure`, and `error` join those same buckets. An unfamiliar incomplete run stays a bounded
unknown-active outcome; an unfamiliar completed conclusion or classic state stays a bounded
unknown-terminal outcome. That forward-compatible visibility is deliberate: new provider data
must not silently become success. Provider strings are limited to 24 characters; each unknown
disposition keeps three named values plus one “other values” aggregate, retaining totals while
bounding the status-card model even if every result invents a different value.

## GitLab adapter

`GitLabChangeRequestClient` uses the official `glab` CLI as its authenticated transport. It asks
`glab auth status --hostname gitlab.com` for readiness, then uses `glab api` for project metadata,
merge-request discovery/creation, commit statuses, approvals, and lifecycle by merge-request IID.
Threading does not read `glab`'s config, request a token, copy one into its environment, or persist
one. `GLAB_NO_PROMPT=1` makes background discovery and managed publication fail visibly instead
of opening an authentication prompt.

The process has a 45-second deadline, a 2 MiB response limit and a 4 KiB sanitized diagnostic
limit. Creation sends bounded JSON on standard input and attempts exactly one POST. A failed or
unreadable POST response tells the caller to discover before any deliberate retry. Draft creation
uses GitLab's supported `Draft:` title convention, while reads also recognise the legacy draft
prefixes when an older GitLab response omits its `draft` field.

GitLab discovery returns the repository's default branch and HTTPS/SSH clone locations alongside
the current branch's open merge request. Commit-status reads include `ref=<source branch>` so a
named external status does not leak across ref-specific histories, request 100 statuses per page,
and stop after five pages. GitLab's endpoint does not provide a total count in the response body,
so a full fifth page carries “more results not loaded” without inventing a remainder. GitLab's
complete `CommitStatus` state machine remains exact: `created`, `preparing`, `scheduled`,
`waiting_for_callback`, `waiting_for_resource`, `pending`, `running`, and `canceling` are active;
`success` passes; `skipped` is non-blocking; and `manual`, `failed`, and `canceled` need attention.
A manual, failed, or canceled status with `allow_failure` remains a separate non-blocking
allowed-failure outcome instead of being counted as either passed or adverse. Unfamiliar values
are visible as bounded unknown terminal outcomes. The approvals endpoint supplies approvals and
requested reviewers. Because
GitLab does not expose GitHub's per-review changes-requested meaning through this workflow, that
capability is false and the adapter reports no invented count.

## Read-only status-card projection

Git Review owns the complete provider state and every write. While the user has the session status
card enabled, `TerminalContainerViewController` makes one provider-neutral discovery for the
selected checkout and projects only a connected request's number, title and checks. Both rows
navigate to Git Review; publication, pushing, review details and browser opening stay there.

The filesystem watcher can report a checkout burst for every file an agent writes, so this read
path is bounded independently: events debounce for 500 ms, an unchanged branch + HEAD signature
reuses its answer for 15 seconds, and a 30-second poll exists while any visible check outcome is
active or the provider summary is incomplete. Polling reads the underlying buckets rather than
the headline severity: one failed check beside one running check still refreshes. Switching
sessions or disabling the card cancels the task, debounce and poll and rejects late generations.
Unsupported remotes stop before a provider request. These are idempotent reads; the
explicit-publication rule below is unchanged.

## Explicit publication and durable safety

The repository-scoped policy is shared across linked worktrees. Every Git Review primary click
advances exactly one external transition: push a branch, open an editable composer or create the
chosen provider's request, push a newer head, or open the existing request. Codex can draft title
and body but has no publication method. No provider write occurs merely because a repository was
opened, detected, refreshed, or placed in a managed worktree.

Managed publication is the separate explicit authorization captured in the session draft. It
preflights provider readiness before the first repository-visible mutation, pushes detached HEAD
without force to the deterministic `refs/heads/threading/<session UUID>`, discovers before
creating, and persists a provider-neutral receipt before removing the local worktree. The receipt
names provider, repository, durable request number, URL, branch, published revision, draft state,
and credential source; the decoder accepts the old `credentialTier` spelling so existing GitHub
receipts survive the provider migration.

Remote cleanup also routes through the provider registry. A closed or merged request is necessary
but not sufficient: `ls-remote` must still show the recorded revision, and deletion uses
`--force-with-lease=<ref>:<published revision>` followed by an absence check. A moved ref is left
alone. GitHub and GitLab therefore share lifecycle orchestration without disguising any
provider-specific API as local Git.

## Verification

`ChangeRequestTests` is registered in the Xcode project and covers provider detection (including
nested GitLab namespaces and self-host refusal), authentication failure before writes, GitHub
credential behaviour, GitLab discovery/create/no-retry/lifecycle, provider-specific proposal
language, durable receipt compatibility, and cleanup routing. `ManagedWorkspaceLifecycleE2ETests`
uses real local Git and a bare remote to prove deterministic non-forced GitLab publication and
one merge-request POST. The live GitHub fixture remains an opt-in proof of the existing GitHub
transport; local adapter fixtures intentionally do not consume a developer's GitLab account.
