# Repository setup hooks

> Status: **decision record** (2026-08-12). **Reject** automatic execution of a repository-declared
> command at checkout creation, at session launch, or at any other lifecycle moment.
> **Prototype**, on the trigger in §12, an *offer*: a fresh managed worktree may name the setup
> command its repository declares and put it one confirmed press away, through the machinery
> project scripts already have. Never for scheduled, remote or unattended sessions, under any
> recommendation. Not implementation work.

Part of the [decisions index](README.md). Read alongside
[`project-scripts.md`](../architecture/project-scripts.md) — whose closing section this record
turns into a decision — plus [`managed-workspaces.md`](../architecture/managed-workspaces.md),
[`execution-audit.md`](../architecture/execution-audit.md),
[`scheduled-messages.md`](../architecture/scheduled-messages.md),
[`permissions.md`](../architecture/permissions.md) and
[`session-activity.md`](../architecture/session-activity.md) (the Codex hook-trust story, which is
the closest existing analogue).

**The one-sentence version.** A setup command is checked-in code that changes by branch and by
commit, whose entire job usually requires network access, arbitrary filesystem writes and
subprocess execution — so it cannot be meaningfully sandboxed, which means the only real control
is *whether it runs at all*, which means it must be a press. And once it is a press, Threading
already has that press.

---

## 1. User problem and concrete use cases

1. **The unusable fresh worktree.** A session opts into a managed workspace. Git gives it tracked
   files; `node_modules`, `.venv`, `target/`, `Pods/` and generated code are ignored and therefore
   absent. The agent's first turn fails on a missing dependency, and its second turn spends the
   user's tokens working out why.
2. **The undiscoverable incantation.** The command is `pnpm install --frozen-lockfile && pnpm build:proto`
   and it lives in a `CONTRIBUTING.md` nobody opens. New checkouts need it; nobody remembers it.
3. **The repeated ceremony.** A user who creates a managed workspace per task pays the same setup
   sequence per task.
4. **The agent doing it badly.** Without a declared command, the agent guesses — often correctly,
   sometimes by running `npm install` in a pnpm repository, and always on the user's usage.

Case 1 is the sharp one, and it is specifically a *managed workspace* problem: an ordinary project
folder was already set up by whoever cloned it.

---

## 2. Existing Threading behaviour and overlap

**Project scripts already exist and are deliberately not this.**
[`project-scripts.md`](../architecture/project-scripts.md) is unusually explicit: *"Project scripts
are checked-in conveniences, not lifecycle hooks. … Nothing in discovery, checkout creation, app
launch, session launch, refresh, or preview handling executes repository code."*

What is already built and would be reused wholesale:

- `.threading.json` at the active checkout's repository root, `version: 1`, unknown fields are
  errors, ≤32 scripts, hard UTF-8 byte limits on every field, no control characters, and
  `workingDirectory` validated at parse *and* re-validated at invocation with symlinks resolved and
  containment re-proved.
- `ProjectScriptConfigurationWatcher` — one path-based FSEvents stream for the active root, filtered
  and coalesced, which reparses and atomically replaces `project.script.<id>` registry entries and
  **never starts a process**.
- A non-suppressible `runProjectScript` confirmation showing the repository-authored command and
  resolved cwd, defaulting Return to Cancel, and **re-resolving the script after approval** so a
  config, checkout or directory change while the sheet was open cancels the run.
- Execution as a named standalone project terminal, selected so output is visible, with the
  repository command passed as a quoted argument to `/bin/sh -lc` so it cannot splice into the host
  suffix, inside a child shell so an authored `exit` cannot mutate the interactive terminal.
- `ProjectScriptExecutionReceipt`, whose stated meaning is only that *this validated command reached
  that visible PTY* — completion is the exit line the user can see.
- Scripts are non-rebindable registry entries: a repository cannot claim a global chord.

**The managed-workspace provisioning path is where the hook would hang**, and it already does the
non-executing half of the job. `.worktreeinclude` lets a repository name **ignored local files** to
copy into a new checkout — a development `.env` being the motivating case — copying only ignored
regular files, refusing symlinks, paths escaping either root, and existing destinations, before the
worktree is locked and before any session record is persisted. That covers a real slice of case 1
with **zero execution**, and it is the reason the remaining slice is smaller than it looks.

Provisioning also already has a failure story: the session record is minted before provisioning so
its UUID names the directory, persisted only after provisioning succeeds, and a failed creation
removes the untouched worktree with an ordinary non-forced Git operation.

**Git already runs repository-owned programs during provisioning**, and Threading already handles
it: clean/smudge filters, hooks, credential helpers and Git LFS's `post-checkout` all launch by
name, which is why app-owned Git children receive the PATH from the user's login shell. Worth
stating plainly because it bounds the claim this record can make: worktree creation is **not**
currently free of repository code execution. What it is free of is *Threading choosing to run a
command the repository wrote for Threading to run* — the difference between inheriting Git's own
extension points and inventing a new one.

**The closest analogue is the Codex hook installer**, and its design is the template for what a
trust model here would cost. Two separate opt-ins (`installsCodexHooks`, `bypassesCodexHookTrust`)
because only the second has a security cost; the file is merged rather than replaced and marked
with `MCPDefaults.hookMarker`; entries are rewritten **only on a real change** because *Codex pins a
trusted hook by hashing its text, so a URL carrying today's port would revoke the user's trust on
every app launch*; a known old command is left byte-for-byte intact for the same reason. That
paragraph is what "trust tied to the exact content hash" actually feels like to maintain.

**Sandboxing exists but does not fit.** `ExtensionSandboxPolicy` launches extensions through
`sandbox-exec` with a generated Seatbelt profile, and a signed App-Sandboxed helper is the staged
replacement. It is capability-specific and fails closed — and a setup command's capability set is
"network, arbitrary filesystem write inside the checkout, and spawn anything", which is not a
containment boundary, it is a description of a shell.

---

## 3. Lessons from t3code

They shipped it. Read from the local clone at `edc503a7a`:
`apps/server/src/project/ProjectSetupScriptRunner.ts`, 188 lines, plus
`packages/shared/src/projectScripts.ts`.

The mechanism, in full:

- `setupProjectScript(scripts)` is `scripts.find(s => s.runOnWorktreeCreate) ?? null` — **exactly one**
  setup script per project, first match wins, silently, with no diagnostic if two are declared.
- On worktree creation the runner resolves the project, opens a PTY at terminal id
  `setup-<scriptId>` with cwd set to the worktree and env
  `{ T3CODE_PROJECT_ROOT, T3CODE_WORKTREE_PATH }`, then writes `${script.command}\r`.
- It returns `{ status: "started", … }`.

What is absent is the entire security surface:

- **No trust prompt.** Nothing asks. Creating a worktree runs the command.
- **No content pinning.** The command is whatever the branch says today. Checking out a branch
  someone else wrote and creating a worktree from it runs their command.
- **No timeout, no output bound, no cancellation.** The runner does not wait, so there is nothing to
  cancel and no completion to report.
- **No receipt distinguishing queued, started, completed, refused or interrupted.** "Started" means
  bytes were written to a PTY.
- **No cleanup contract.** The worktree already exists; a failed setup leaves it in place with no
  record that setup failed.

The three errors it does model — `resolveProject`, `openTerminal`, `writeCommand` — are all about
the *host's* plumbing, not about the command.

Their own mobile client labels it honestly (`${script.name} (setup)`), which is the one thing worth
taking: the setup script is presented as a member of the same script list, not as a hidden
lifecycle.

**This is the exact design [`project-scripts.md`](../architecture/project-scripts.md) already
refuses**, and seeing it implemented does not change the argument — it sharpens it. The feature is
not hard to build. It is hard to make safe, and t3code did not try.

---

## 4. Proposed domain and host contract

Two things are specified: the trust model that automatic execution *would* require (so the rejection
is arguable and so a future implementer inherits the analysis), and the offer that is actually
recommended.

### 4.1 What automatic execution would require

Checked-in commands are **untrusted code that changes by branch and by commit**. That sentence is
the whole design constraint, and each clause below follows from it.

1. **Trust is a grant keyed to `(repositoryIdentity, SHA-256 of the exact declared command text +
   working directory + declared environment)`.** Not to the repository, not to the file, not to the
   script id. Two branches with different setup commands are two grants.
2. **Any change to that hash invalidates the grant**, silently and completely, and the next
   creation falls back to the offer. A "trust this repository's setup" grant that survives an edit
   is a grant to whoever can push to the branch.
3. **The grant is revocable and auditable in Settings**, listing repository, command text, hash and
   grant time, with per-row and bulk revoke — the shape Settings ▸ Tools already uses for
   persistent browser origin grants and submission exemptions.
4. **The grant does not live in `UserDefaults`.** [`agent-browser.md`](../architecture/agent-browser.md)
   states the reason for its own case: an agent with shell access can `defaults write`, which is
   tolerable for a browser origin grant because it yields no password, and was **not** tolerable for
   submission exemptions, which therefore live in process memory. A grant that causes command
   execution at worktree creation is squarely in the second category. Either it is process-memory
   only — which makes it useless, since worktree creation is rare — or it is stored somewhere the
   agent's own shell cannot rewrite, and Threading has no such store today. **This is the clause
   that has no good answer, and it is the main reason for the rejection.**
5. **The command is visible before it runs**, in the same non-suppressible form the existing
   confirmation uses: verbatim text, resolved cwd, and the environment additions named.
6. **cwd is the execution checkout's validated root**, re-resolved and re-contained at invocation,
   never the app process's directory, never the logical project folder.
7. **The environment is enumerated, not inherited wholesale.** The login-shell PATH (as every
   app-owned Git child already gets), plus a small named set — and explicitly *not* the MCP routing
   variables `MCPDefaults.portEnvironmentKey` / `sessionTokenEnvironmentKey`, which would hand a
   repository-authored command the session-scoped control-plane endpoint.
8. **A wall-clock timeout**, after which the process group is signalled — the group, not the pid,
   for the reason `AgentChildProcess` already spawns through `posix_spawn` with
   `POSIX_SPAWN_SETPGROUP`: signalling only the parent leaves a backgrounded fleet running.
9. **Bounded output**, with the bound stated in the receipt when it is hit, and a ring rather than
   an unbounded buffer.
10. **Cancellable at any time**, by a person, with the same group signal.
11. **A durable receipt distinguishing queued, started, completed (with exit status), refused,
    timed-out, cancelled and interrupted-by-quit.** Not the optimistic "started". The natural home
    is [Execution Audit](../architecture/execution-audit.md) — it is already the append-only,
    hash-linked, owner-only record of what ran — but note it is currently *per session* and a
    worktree-creation event may precede the session record, which is a real modelling problem, not a
    detail.
12. **A cleanup contract.** If setup fails, the worktree exists and is probably unusable. The
    options are: keep it and mark the session `needsAttention` with the reason (consistent with how
    a refused delivery proof is handled), or remove it. Removing it after a command has run inside
    it is the dangerous choice — the command may have created files the user wants — so keeping and
    flagging is the only safe answer, and it must be stated rather than defaulted into.
13. **Never for a scheduled, remote or unattended session.** See §5.
14. **Sandboxing is not available.** Stated explicitly so nobody proposes it as the mitigation: the
    command needs network (package installation), arbitrary write inside the checkout, and
    subprocess spawn. A Seatbelt profile granting those is not a boundary. The extension helper's
    "no network, capability-specific" posture is the opposite of what this workload needs.

### 4.2 What is actually proposed: the offer

No new trust model, no new execution path, no new grant store.

- `.threading.json` gains one optional boolean on an existing script entry — the same field name
  t3code uses is fine — meaning **"this is the script a fresh checkout needs"**. At most one may
  carry it; two is a parse error (unlike t3code's silent first-wins), because the file's existing
  rule is that unknown or ambiguous input is an error rather than something that looks supported.
- Nothing about discovery changes. The watcher still starts no process.
- When Threading finishes provisioning a **managed worktree** and the repository declares such a
  script, the session's opening surface carries a one-line notice: *"This repository declares a
  setup command"*, the command text, and a **Run Setup** action.
- Pressing it is an ordinary `runProjectScript` invocation: the existing non-suppressible
  confirmation, the existing re-resolution after approval, the existing visible named terminal, the
  existing `/bin/sh -lc` quoting, the existing exit-status receipt.
- The notice is dismissible and does not block the session. The agent starts either way.
- Nothing is added for ordinary (non-managed) checkouts: they were set up by whoever cloned them.

The user gains discoverability (case 2) and one press instead of a lookup (cases 1 and 3). The
security posture is **unchanged**, because every byte of the execution path is the one that already
exists.

---

## 5. Security, privacy, destructive-action and scaling analysis

**The threat is ordinary and does not require an attacker.** Creating a worktree from a branch is a
routine act — reviewing a colleague's work, checking out a pull request, letting an agent create a
branch. Automatic execution turns *checking out a branch* into *running its author's code*. That is
a well-understood class (the reason `git` does not run hooks from a clone, the reason editors gate
workspace trust), and the mitigation everyone converges on is the same: a human decision keyed to
content, not to place.

**The agent is inside the threat model, not outside it.** An agent in this app has an unrestricted
shell. It can write `.threading.json`. If Threading executes a declared command at worktree
creation, then an agent — steered by prompt-injected page text, a poisoned dependency's README, or
an untrusted tool result — can write a setup command and then ask for a worktree. Content-hash
trust does not stop this on the *first* creation of a new command; only the human press does.

**Scheduled, remote and unattended sessions may never run a setup command. Under any
recommendation, including a future one that permits automatic execution.** The reasons are already
written down elsewhere in this codebase and all three apply:

- A **scheduled** message freezes its launch choices and re-validates them when it fires, and
  [`managed-workspaces.md`](../architecture/managed-workspaces.md) requires a schedule to *fail
  visibly* rather than silently discard the isolation the user asked for. There is no equivalent
  re-validation for a command whose text may have changed with the branch — and nobody is present
  to read the confirmation.
- **Remote** creation from the iPhone goes through the same Mac launch path, and the phone cannot
  show a terminal's output stream well enough for the visible-terminal guarantee to mean anything.
  The offer may appear on the phone; the press may not run without a Mac-side surface.
- The **startup relaunch** brings sessions back with nobody looking — the exact condition
  `noteUnattendedLaunch` exists for. It restores existing sessions and creates no worktrees, so this
  is a rule that keeps a future path closed rather than one that closes a current one.

**Privacy.** A setup command runs with the user's authority and can read anything they can, exfiltrate
over the network it needs, and read the environment it is handed — which is why §4.1(7) enumerates
rather than inherits, and why the MCP routing variables are named as excluded. The existing project
script path already has this property; what automatic execution removes is the person who decided to
accept it.

**Destructive.** A setup command can delete the checkout, and there is no undo. `.worktreeinclude`'s
copy is refusable and reversible; a command is not.

**Scaling.** Small and already handled: one bounded config file, ≤32 scripts, one active watcher,
and one process per press. The one new bound is output, per §4.1(9). The offer adds one line to a
surface that already exists and constructs no views for a repository nobody opened.

---

## 6. Dependencies on earlier roadmap goals

Shipped and sufficient for the offer: the `.threading.json` parser and its byte limits, the schema
at `docs/schemas/threading-project.schema.json`, `ProjectScriptService`'s checkout routing (which
already resolves a managed worktree's own config rather than the base project's),
`ProjectScriptConfigurationWatcher`, the `runProjectScript` confirmation and its re-resolution,
`ProjectScriptExecutionReceipt`, and managed-workspace provisioning.

Owed for the offer: one optional schema field (plus the two-is-an-error rule), one notice on the
session's opening surface, and one call into the existing invocation path.

Owed for automatic execution, and none of it exists: a store the agent's own shell cannot rewrite,
a content-hash grant model with revocation UI, a timeout and cancellation path around a
repository-authored process, a bounded-output ring, a worktree-creation-scoped audit record, and a
stated cleanup policy. That list is §4.1 restated as work.

---

## 7. Smallest shippable slice

The offer in §4.2, managed worktrees only:

- one optional boolean in `.threading.json`, at most one script carrying it;
- one notice with the command text and a **Run Setup** action on a freshly provisioned managed
  workspace;
- dismissible, non-blocking, no auto-run, no grant, no new execution code.

If even that is too much, the free version is smaller still and worth noting: `.worktreeinclude`
already exists, and documenting it in the user guide next to "your fresh worktree has no
`node_modules`" solves part of case 1 with no code at all.

---

## 8. Explicit non-goals

- Running a repository-declared command automatically at worktree creation, session launch, app
  launch, project add, config change, checkout switch or preview open.
- A trust grant scoped to a repository, a path or a script id rather than to exact content.
- Storing any execution-authorizing grant in `UserDefaults`.
- Running a setup command for a scheduled, remote-initiated or startup-relaunched session.
- Handing a repository-authored command the MCP routing environment, or any session token.
- Sandboxing a setup command and calling that containment.
- Running setup for ordinary project folders.
- More than one setup script per repository, or an ordered setup pipeline.
- Blocking the agent's first turn on setup completion. If setup matters that much, the user presses
  the button before sending, and the agent's own failure message is a better signal than a spinner.
- Merging this with project scripts' *purpose*. A setup script is a project script wearing a label;
  it is not a second execution system, and it must never acquire one.

---

## 9. Acceptance and failure tests

For the offer:

1. A repository declaring a setup script provisions a managed worktree and **no process is
   spawned** — asserted by a spawn-counting seam, not by absence of output.
2. The notice names the command verbatim, including a command containing shell metacharacters,
   without interpreting them.
3. Pressing Run Setup raises the existing non-suppressible confirmation, and Return cancels.
4. Approving runs in the managed worktree's root, not the base project folder — the routing
   `ProjectScriptService` already implements, asserted here because this is a new caller.
5. Editing `.threading.json` while the confirmation is open cancels the run (existing
   re-resolution).
6. Two scripts declaring the setup flag is a **parse error** with a diagnostic, and neither is
   offered.
7. Dismissing the notice does not prevent the script appearing in Project ▸ Scripts and ⌘K.
8. A non-managed session shows no notice.
9. An ordinary project script without the flag is unchanged in every surface.

Boundary tests, which are the point:

10. No code path from managed-workspace provisioning reaches `ProjectScriptService`'s invocation.
11. No code path from `StartupSessionRelaunch`, `ScheduledMessageNotifier` or the remote session-start
    route reaches it either.
12. The environment handed to a project script contains neither `MCPDefaults.portEnvironmentKey`
    nor `sessionTokenEnvironmentKey`. This is worth asserting now regardless of this feature.

---

## 10. Estimated complexity and maintenance burden

**The offer: small.** One schema field, one notice, one existing call. Maintenance near zero.

**Automatic execution: large, and the maintenance is the wrong kind.** Not "this code needs
occasional attention" but "this is a standing security surface whose correctness depends on a grant
store that does not exist". The Codex hook-trust section in
[`session-activity.md`](../architecture/session-activity.md) is a preview of the ongoing cost:
several paragraphs of carefully preserved byte-for-byte behaviour, a pre-rename marker kept alive
across a product rename, and two separate opt-ins — all to avoid revoking a *user's* trust decision
about a file. A grant keyed to command content would need the same discipline, with the added
problem that the thing being trusted is edited by the agent the app is hosting.

---

## 11. Recommendation

**Reject automatic execution.** Not "not yet" in the ordinary sense: reject it until clause §4.1(4)
has an answer, because without a grant store the agent's own shell cannot rewrite, content-hash
trust is decoration. If that store ever exists — for this or for any other reason — the rest of
§4.1 is implementable and this becomes a live question again.

**Prototype the offer** on §12's trigger. It is cheap, it is discoverable, and it reuses an
execution path that has already been argued out.

**Keep the two concepts separate in the code and in the docs.** A setup script is a project script
with a label, offered at one extra moment. The moment it grows its own runner, its own environment
rules or its own receipt type, it has become the thing this record rejects, wearing the other
feature's name.

---

## 12. What should reopen this

**Build the offer** when a user reports a fresh managed worktree being unusable — the agent's first
turn failing on a missing dependency — and `.worktreeinclude` does not cover it because the missing
thing is *generated* rather than *ignored-but-present*. One report is enough; the fix is cheap.

**Reopen automatic execution** only if all of these arrive:

- a store for execution-authorizing grants that an unrestricted local shell cannot rewrite (Keychain
  with an ACL, or a signed sidecar), which would likely arrive for another reason first — the
  remote-access owner credentials already live in the login Keychain, which is the nearest
  precedent;
- a worktree-creation-scoped audit record, since Execution Audit is per-session and the creation may
  precede the session;
- and evidence that the *press* is the actual friction, not the discovery. If the offer ships and
  people press it without complaint, automation was never the problem.

**Do not treat t3code shipping it as evidence.** They shipped it without a trust model at all; the
existence of `runOnWorktreeCreate` in a competitor is a feature-parity argument, and feature parity
is not one of this project's reasons for doing anything.

**Watch:** if Git or the platform grows a standard, gated "workspace setup" mechanism — the way
editors converged on workspace trust — adopting the platform's answer would be better than owning
one, and would moot most of §4.1.
