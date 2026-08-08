# Managed Session Workspaces

The opt-in session checkout: progressive disclosure in the composer, detached Git worktrees,
execution-directory routing, and safe local delivery.

Part of the [CLAUDE.md](../../CLAUDE.md) index. Also read
[git.md](git.md), [source-control.md](source-control.md), [sessions.md](sessions.md), and
[mcp-and-display.md](mcp-and-display.md).

## Product contract

Managed workspaces are **off unless the draft explicitly enables one**. While off, the
composer contains only the opt-in checkbox: its delivery controls do not merely hide, they are
absent from the view hierarchy. A nil `ManagedWorkspacePlan` is therefore the UI state, stored
state, and launch behaviour for every ordinary session and for records written before this
feature existed.

There is no name field. A local managed session has no feature branch to name: Threading creates
a locked detached worktree under its Application Support directory, named by the session UUID.
The logical `Project` remains the sidebar, theme, grouping, and persistence owner. Only APIs that
execute or inspect session files receive an `executionProject` copy whose folder points at the
managed checkout.

Publishing is a separate, nested decision. The local delivery modes are:

- **Merge and clean up** — validate, fast-forward the checkout the session started from, then
  remove the worktree. This is the default.
- **Keep workspace for review** — archive the session but deliberately retain the checkout.

When the selected repository has a supported review provider, enabling the workspace reveals a
second **Open a change request when finished** checkbox. That checkbox is off by default;
while it is off, its draft/ready setting is absent from the view hierarchy just like the local
delivery controls are while isolation is off. Enabling publication replaces the local delivery
choice with a Draft/Ready choice because the remote review, rather than the source checkout, is
the delivery target. GitHub pull requests and GitLab.com merge requests both travel through the
same provider boundary. The stored receipt and lifecycle types remain provider-neutral; a
recognisable self-hosted GitLab remote is refused explicitly rather than treated as GitLab.com.

## Lifecycle

Turn checkpoints belong to the repository, not to the lifetime of the managed worktree. Capture
records both identities: `worktreeIdentity` proves which execution checkout supplied the bytes,
while `repositoryIdentity` scopes and serializes the private ref update in the shared Git directory.
The refs therefore survive normal managed-worktree disposal. Historical tree-to-tree reads may use
the logical checkout after proving it has the same repository identity; they never recreate or
restore the execution worktree. Permanent session deletion performs checkpoint cleanup before the
owning checkout association is discarded, while Archive/Restore leaves it intact.

```text
draft opt-in
    |
    v
validate Git + clean source + finish-handshake capability
    |
    v
create detached worktree -> copy selected ignored setup files -> lock it
    |
    v
run the whole session and every project-relative tool in that checkout
    |
    v
agent commits, verifies, and calls archive_session after its final turn
    |
    +--> merge-and-clean: validate -> fast-forward -> unlock/remove -> archive
    |
    +--> keep-for-review: retain checkout --------------------------> archive
    |
    +--> publish: preflight credential -> push detached HEAD to opaque remote ref
    |             -> find/create draft or ready review -> persist receipt
    |             -> unlock/remove local worktree -----------------> archive
    |
    `--> any refused proof: retain checkout -> needsAttention (not archived)
```

The session record is minted before provisioning so its UUID is also the stable directory name.
The record is persisted only after provisioning succeeds; if session creation then fails, the
untouched worktree is removed with an ordinary, non-forced Git operation.

Scheduled drafts freeze the optional plan with the rest of their launch choices and validate it
again when they fire. A schedule must fail visibly if its project, checkout, runtime surface, or
Threading session tools are no longer available. Falling back to the ordinary project directory
would silently discard the isolation the user asked for.

## Finish handshake

Provisioning is offered only when the chosen surface can receive Threading's session-scoped MCP
bridge and the **This session** tool group is enabled. Native surfaces require
`.threadingBridge`; terminal surfaces require `.terminalThreadingBridge`. Immediate starts and
scheduled starts enforce the same rule again instead of trusting stale UI.

The opening brief assigns responsibilities explicitly:

- the agent works only in this checkout, commits intended changes, and runs checks;
- the agent does not merge, push, create a branch or review, or remove the worktree;
- `archive_session` is the completion signal and must not be called while blocked or incomplete;
- Threading alone performs delivery and disposal after the turn has ended.

A person choosing Archive is not that handshake. It preserves an active checkout as
`keepForReview`; only an agent-requested archive takes the validated delivery path.

## Merge and disposal invariants

`ManagedGitWorkspace.integrateAndClean` refuses before removal unless all of these are true:

1. the managed checkout exists and has no tracked or untracked changes;
2. the source checkout is clean and is still on the recorded target branch;
3. the managed `HEAD` descends from its recorded base commit;
4. the source is still at that base, or already contains the managed final commit;
5. Git accepts a fast-forward-only merge.

There is no conflict resolver and no forced worktree removal. A refusal persists
`needsAttention`, keeps the session visible, records the reason, and leaves the detached checkout
intact. Retrying is safe after the source checkout is repaired: a merge that already succeeded
but whose cleanup failed is recognised as already containing the final commit.

Archive Undo recreates the same stable path when successful local delivery already removed it.
This matters because provider transcript lookup can derive identity from the working directory.
If provider-side archiving fails after local integration, Threading performs the same restoration
before leaving the session visible.

## Remote publication invariants

Publication is authorized when the draft is submitted, not inferred from enabling isolation and
not selected by the agent. It has its own finish path:

1. preflight a native API credential before making any repository-visible change;
2. require a clean managed checkout whose final commit differs from and descends from the
   immutable base captured at provisioning;
3. push that exact commit, without force, directly to `refs/heads/threading/<session UUID>`;
4. look up an existing open review for that deterministic ref before creating one;
5. persist the final commit and provider-neutral review receipt before local cleanup;
6. remove only the locked managed worktree, never move or modify the source checkout.

The opaque ref is remote-only: Threading never creates a corresponding local branch or asks the
person to name one. The original base commit, rather than whatever the source checkout happens to
point at later, anchors the comparison and generated proposal. A transport failure while creating
the review is ambiguous and is never retried automatically. Browser fallback is also unsuitable
for unattended completion, so a missing native credential fails before the push and retains the
worktree as `needsAttention`.

Once the receipt exists, a repeated finish is idempotent and cleanup validates that the managed
`HEAD` is still the published commit. If the person archives during the network operation, the
receipt is kept but the checkout is deliberately retained. Archive Undo recreates a disposed
published checkout at the recorded final commit without changing its original comparison base.

The remote branch remains while its review is open: deleting it at local disposal would break the
review. Its disposal is a second provider lifecycle, automatically reconciled at launch, whenever
Threading becomes active, and on a tolerant ten-minute heartbeat. No additional setting is
needed: the publication opt-in authorized this one opaque app-owned ref, and cleaning that ref
after its review finishes is the disposal half of the same promise.

The reconciler reads the review by its durable number so closed reviews remain visible. Only a
closed or merged review advances to Git. The provider lifecycle read must be fresh: GitHub's
transport bypasses its normal URL cache, and GitLab asks `glab api` directly. A cached closed
response must not authorize deletion after a review was reopened. `ls-remote` must still report
the exact published commit.
Deletion uses `--force-with-lease=<ref>:<published commit>` and verifies absence
afterwards, so a ref moved between the read and write is preserved. Provider-side automatic
deletion records `alreadyAbsent`; a branch or review whose identity changed records
`ownershipLost` and is left in place. Transient API, credential, repository and Git failures keep
the pending state and retry without turning an archived session into a notification source.

## Worktree setup files

Tracked files arrive through Git. A repository may add `.worktreeinclude` to select ignored local
files needed by a new checkout, such as a development environment file. Only ignored regular
files are copied. Symlinks, paths escaping either root, and existing destinations are refused.
The copy happens before the worktree is locked and before any session record is persisted.

Worktree creation invokes `/usr/bin/git` directly, but Git can launch repository-owned programs
by name: clean/smudge filters, hooks, credential helpers and Git LFS's `post-checkout` executable.
A Finder-launched app does not inherit Homebrew or the user's other shell paths. All app-owned
Git children therefore receive the PATH reported by the user's login shell, cached once per shell;
operation-specific environment overrides remain final. Without that split, a repository whose
ordinary checkout works with Git LFS fails only when Threading creates its isolated checkout.

## Deterministic lifecycle proof

`ManagedWorkspaceLifecycleE2ETests` exercises the ordinary, non-network test path with a real
external process and real Git repositories. Every test creates its source checkout, nested
project, managed-worktree root and, where publication is involved, a bare remote inside one
temporary container. The test removes that whole container afterwards, so it cannot mutate a
developer checkout or leave branches and worktrees behind.

The fixture process has fixed output and two deliberately small behaviours: commit one known
file, or leave that file dirty. It is not an `AgentKind`, is never offered beside Claude or Codex,
and has no Draft settings. That boundary is intentional: the application should not acquire a
shipping provider merely to make its transport deterministic in tests.

The suite covers the durable local states (`active`, `integrated`, `kept`, `needsAttention` and
`published`) and the remote cleanup outcomes (`waiting`, `deleted`, `alreadyAbsent` and
`ownershipLost`). Publication uses production Git commands against a local bare remote plus a
fixed provider responder: GitHub's HTTP fixture preserves its existing path, while the GitLab
fixture records authenticated CLI requests and proves one merge-request POST. The cleanup
scenarios separately prove the shared exact-revision lease check before branch deletion.

Most scenarios prove provisioning, the process working directory, Git handoff, local delivery,
publication and disposal directly. Their final output line models the fixture asking to archive,
which keeps the state matrix small and makes failures local.

One whole-app scenario crosses the remaining boundary. A per-session DEBUG-only launch-plan
override starts the same deterministic fixture in a real terminal controller. The child reports
`turnStarted`, commits its known file, sends `archive_session` to the session-scoped loopback MCP
URL, reports `turnFinished`, and waits for Threading to terminate it. Production request decoding,
lifecycle relay, turn-end scheduler and `SessionCoordinator` then integrate the commit, archive
the session and dispose the worktree. The override cannot replace an existing controller and is
removed on discard, so it cannot become an agent identity, capability, or Draft setting.

These local tests deliberately stop at real hosted accounts. The live test below proves the real
GitHub transport and credentials; a local bare remote or fixed adapter cannot prove that a forge
accepted a change request or enforced its review lifecycle. GitLab coverage exercises the real
`glab api` invocation contract through an injected process boundary without reading or spending a
developer's GitLab credentials.

## Live GitHub proof

`ManagedWorkspaceGitHubE2ETests` is an explicit destructive test against the private
`everlof/threading-managed-workspace-e2e` fixture. Ordinary test runs skip it. Opt in with the
exact repository value as an Xcode build setting:

```sh
scripts/test.sh fast \
  THREADING_GITHUB_E2E_REPOSITORY=everlof/threading-managed-workspace-e2e \
  -only-testing:ThreadingTests/ManagedWorkspaceGitHubE2ETests
```

The fixture requires Git push access and a native GitHub API credential. Locally it deliberately
uses the same login-shell `gh` credential path as the app. In CI, do not copy a developer's broad
OAuth token: install a GitHub App or use a fine-grained token whose repository selection contains
only this fixture and whose permissions are **Contents: read/write** and **Pull requests:
read/write**.

Each run creates a disposable base ref and lets production code publish an opaque head ref, open
a draft PR, retain the head while the PR is open, close the PR, and lease-delete both refs. The
closed PR remains as immutable GitHub history; no `e2e/*` or `threading/*` branch may remain.
Best-effort cleanup uses the recorded revisions so an assertion failure cannot delete a ref that
somebody moved.

## Prior art and the chosen boundary

The shape takes useful pieces from several tools without adopting their branch-first assumption:

- t3code makes a worktree a per-thread launch choice, runs repository setup hooks, and adapts its
  finish action between commit, push, and pull-request creation;
- Conductor treats one agent task as one isolated workspace;
- Codex demonstrates that a managed worktree can be detached rather than branch-named;
- Worktrunk's transactional merge posture inspired proving the integration before disposal.

The resulting boundary keeps isolation local by default: session ownership supplies the name and
detached history removes branch garbage. Publication is a separately authorized lifecycle that
introduces only a deterministic remote ref, records the resulting review before disposal, and
never turns the source checkout into its staging area.
