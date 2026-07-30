# Session Activity

Deriving dormant/idle/working/awaitingUser/needsAttention, and the lifecycle hooks that replace
the inference.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

`SessionActivityTracker` derives `dormant` / `idle` / `working` / `needsAttention` from PTY
output, because an idle agent writes nothing at all — measured at zero bytes over 19s while
sitting at its prompt. This works for any program rather than one specific agent.

Four guards keep it honest:

- A **byte threshold** (`workingByteThreshold`), so the terminal echoing typed characters is
  not mistaken for work.
- A **quiet interval**, so gaps within a burst of output do not flicker the state.
- A **resize quiet period** (`noteTerminalResized`). Resizing sends `SIGWINCH` and full-screen
  terminal apps answer by repainting everything, which is a large burst of output that we
  caused. Suppression blocks a session *entering* `working`, but deliberately keeps an
  already-working session's timer alive — otherwise resizing mid-task would report it as
  finished.
- A **scroll quiet period** (`noteScrollForwarded`). When a program tracks the mouse, wheel
  events are forwarded to it (see the fork's `MacTerminalView.scrollWheel`) and it answers
  each one by repainting its content — the same we-caused-it output as a resize, extended by
  every event so a momentum gesture stays covered.

`needsAttention` is only raised when work finishes in a session that is *not* on screen;
`AgentRuntime.setVisibleSession` tracks which that is. A terminal bell raises it directly.

Output arrives on the main queue (`LocalProcess` defaults its dispatch queue to
`DispatchQueue.main`), which is what lets the tracker use `Timer` safely.

**An agent that reports its own turns is believed instead.** All of the above is a proxy, and
the guards exist because it cannot tell thinking from repainting. When
`AppSettings.reportsClaudeLifecycleEvents` is on, `AgentLauncher.claudeCommand` writes a
per-session `--settings` file for *terminal* sessions too — lifecycle hooks only, no
`PreToolUse`, because a terminal session raises the CLI's own permission prompt and intercepting
it would replace a working prompt with a second one. `UserPromptSubmit`, `Stop`, `Notification`,
`SessionStart`, `SubagentStart`, and
`SubagentStop` curl back to the listener
(`MCPDefaults.lifecyclePathPrefix`), and `HookLifecycleRelay` hands each report to the session's
tracker. Verified end to end against CLI 2.1.217: the three ordinary events arrive in order,
carrying the prompt text.

Reporting is on by default to preserve the richer terminal state, but it is observational and
optional. Off with no Remote Control override means no Claude settings file at all; off with an
override writes that key without a `hooks` dictionary. Native Claude still writes `PreToolUse`
because its headless process has no CLI approval prompt, but does not write lifecycle hooks. The
native structured stream remains the source of turn and child state either way.

The child pair does not drive `SessionActivityTracker`; it feeds the provider-neutral
`SubagentSessionState`. Start supplies the child id/type, and Stop supplies its transcript path
and last assistant message. Claude native deliberately ignores these hook child ids because its
structured stream uses the spawning Agent tool-use id as the stable UI identity; mixing the two
would create duplicate children. Claude terminal uses the hooks. Codex uses its child thread id
in both app-server and hooks, so the hook can enrich either surface without a second row.

**Not every subagent hook is about a subagent.** Claude reports the *root* agent's own turn
through `SubagentStop` as well: the root's `agent_id`, an **empty** `agent_type`, an
`agent_transcript_path` under `<session>/subagents/` that the CLI never writes, and the parent's
own `last_assistant_message`. Threading accepted them, so the navigator filled with rows that
opened onto nothing and could not be dismissed — nothing retracts a discovered child. Measured
across five sessions' persisted navigators: 17 of 20 recorded children had this shape, every one
of them with no transcript on disk and the parent's own prompt or turn summary as its message,
while all three real children named their type (`Explore`, `Plan`) and had their transcripts.

`HookLifecycleReport.describesChildAgent` is the admission rule: a named `agent_type` is a child;
an unnamed one is admitted only when the reported transcript exists, and an already-tracked id is
always admitted so a child accepted at Start still receives its Stop. This is the terminal
analogue of the rule `ClaudeSubagentEvent` already applies natively — "an explicit non-agent type
must never become a child row" — and it holds for Codex too, since the contract above has Start
supplying the type and Stop supplying a path that, for a real child, is on disk. A child that
satisfies neither is by definition one that cannot be opened.

Refusing them at the hook only stops new ones: a navigator keeps its rows across relaunches, so
`SubagentStateStore.load` applies the same rule to what is already on disk. Swept on read rather
than behind a version bump — the file's shape did not change, only which rows belong in it, and
the next save writes the result.

Three things shape it, and each was wrong first or would have been:

- **The lifecycle endpoint never blocks**, unlike the permission one. These hooks fire on the
  agent's own turn boundaries, so any pause is latency before the user's prompt is answered, and
  nothing reads the reply — `routeLifecycle` responds `.accepted` before it parses the body, and
  the hook runs with a 2-second timeout.
- **The hook must stay silent.** Claude feeds a `UserPromptSubmit` hook's stdout back to the
  model as context and reads a failing `Stop` hook as a reason to keep going, so a lifecycle
  report that leaked either would change the conversation it only observes. Hence
  `>/dev/null 2>&1 || true`, which is load-bearing rather than tidy.
- **Reporting latches** (`reportsOwnActivity`), and output then stops driving the state at all.
  The two signals disagree by design: a working agent is quiet while it waits on the model and
  noisy after its turn ends while the CLI redraws its footer. Falling back per-event would
  flicker between them. `markRunning` clears the latch, because the settings file is written per
  launch and can fail — a latched tracker with no reports coming would sit idle forever.

**The turn and the question are separate facts, and collapsing them cost a whole run.** The
tracker used to hold one enum and let each report assign the state it thought followed, which
made `UserPromptSubmit` the *only* way back into `working`. But an agent asks for a permission
inside a turn it goes on to finish: `Notification` arrives mid-turn, the row goes to
`needsAttention`, the user answers — and nothing says `working` again until their next prompt.
Worse, the natural response to an attention dot is to open the session, and opening it cleared
the flag to `idle`, so the row went completely blank while the agent worked on. Found with three
sessions showing no indicator at all while still appending to their own transcripts; the sidebar
had been read as "the loader is broken", and the loader was fine.

So `SessionActivityTracker` now keeps `turnInFlight`, `awaitsUser` and `isDormant`, and `settle()`
is the single place that turns them into a `SessionActivity`. Three rules fall out of that:

- **`awaitingUser` and a bell raise the flag without touching the turn.** Where nothing reports,
  the bell still ends the inferred turn — it is the only boundary a shell has, and leaving the
  turn open would strand it `working` with no quiet timer left to stop it.
- **Being looked at lowers the flag and returns to the turn**, so a session asked-and-answered
  mid-turn goes back to `working`, while one that genuinely finished off screen still goes `idle`.
- **Output may lower the flag, and may do nothing else.** Answering in place raises no hook at
  all, so a fresh burst inside a flagged turn is the only evidence the agent resumed. It is
  admitted on screen only — off screen the flag is the one thing saying the session is waiting,
  and nobody answers a prompt they are not looking at. It can never start or end a turn, which
  is what keeps the latch's guarantee intact.

**The same split is what lets the sidebar say *which* kind of attention a session wants.** The
flag raised inside an open turn is `awaitingUser` — a turn stopped dead — and the same flag with
the turn closed is `needsAttention`, a turn nobody has read. They cost the user different things,
and with ten sessions in the list only one of them is worth interrupting yourself for. The
distinction is free: it is the pair of facts `settle()` already holds. It also disambiguates a
report that used to be unreadable — Claude raises `Notification` both for a permission prompt and
once its prompt has sat idle a while, and the turn is what tells those apart.

Three consequences worth knowing before changing any of it:

- **The marks are ranked by what they cost, not by novelty.** Blocked is a filled dot in the
  warning role; unread is a hollow accent ring. Filled-versus-hollow carries the meaning on its
  own, so it survives Differentiate Without Colour — checked by rendering both and comparing the
  ink at the centre, since a colour-only distinction passes every assertion you would think to
  write about it.
- **`GitTurnBaselineStore` had to learn the difference.** It captures the Last Turn baseline on
  the edge into `working`, and answering a question mid-turn is now such an edge — re-baselining
  there would silently drop everything the turn had already changed. It skips the edge out of
  `awaitingUser`, which is the one that is a resumption rather than a start.
- **Extensions still see one state.** `ExtensionSessionActivity` is a published vocabulary an
  installed extension already switches on, so both map to `needs-attention` rather than handing
  every extension a value it has no branch for.

**A `Stop` is the end of a turn, not the end of the session — and the agent says which.** An
agent that backgrounds a test run ends its turn at once ("queued; will report when it lands"),
and the CLI wakes it a minute later by submitting the task's completion as a prompt of its own.
Read as a finish, that `Stop` posted *Finished its turn* and dropped a completed mark on a
session that then went on talking. Found in one transcript three times in six minutes — 11:07,
11:09 and 11:12, each about 45 seconds ahead of the wake that followed it.

The fact was already in the payload. Claude's `Stop` carries `background_tasks`, and the CLI's
own description of the field is the reason it is read: it exists so a hook can tell *"session is
done"* from *"session is paused waiting for background work to wake it"*. It lists shells,
detached children, MCP monitors and workflows whose status is `running` or `pending`, and is an
empty array when there are none — measured against 2.1.220 by ending a turn on top of a
`sleep 45`. Codex 0.144.6 sends no such key, so its sessions read zero and behave as they did.

`pausedOnOwnWork` is therefore a **fourth fact rather than a longer turn**, and the distinction
is the one the split above already paid for: the turn is what a `Notification` is read against,
so borrowing it here would make Claude's idle-prompt notice — which holds nothing up — arrive
looking like a blocked turn. Two rules follow:

- **It keeps the session out of `idle` without opening a turn.** `settle()` reports `working`,
  because "still going" is what the sidebar has to say and there is no third mark worth
  teaching every reader of `SessionActivity`.
- **It suppresses the unread mark too, not just the notification.** A turn ended on top of its
  own running work has said nothing for the user to read, so `noteTurnFinished` leaves
  `awaitsUser` down even off screen.

**Being in flight is not enough, and `BackgroundWorkLedger` is why.** The obvious rule — any
in-flight work keeps the session out of `idle` — is right for a test run and wrong for a dev
server: a process that lives for hours would hold *every* later turn open behind it and silence
the session for as long as it ran. But "will this speak again" is true of everything in the
list, because both CLIs wake a session when a background task ends, so it separates nothing.
What separates them is **when the work appeared**:

- Work the agent started **in the turn that just ended** is the reason that turn ended early.
  That is the pause.
- Work **carried over** from an earlier turn is parked. The turn really did hand back.

So the ledger keeps the ids that were already in flight at the previous boundary, and only a
boundary that brings something new pauses the session. Both surfaces carry identities rather
than counts for exactly this — `background_tasks[].id` on the hook, `tasks[].task_id` on the
stream — and both hold their own ledger, reset with the process. Traced against the transcript
that started this: three consecutive turns each queued a *new* task, so all three paused
correctly; a fourth turn with only the old task still running would not have.

Classifying the command instead (`npm run dev` is long-lived, `npm test` is not) was the
obvious alternative and is worse. It is a name-matching guess where an exact fact is already in
the payload, it covers only `shell` tasks and not subagents or monitors, and being wrong in the
long-lived direction re-opens the very bug this closes.

What it still holds open is a turn that starts long-lived work and is never followed by another
turn. Nothing further happens in that session to notify about, so what remains is a working
mark beside a session that does in fact still have something running — which is what the CLI's
own footer says for exactly as long.

The native surface has the same bug and a better signal: the stream sends
`system` / `background_tasks_changed` carrying the whole in-flight list on every change, so
`ConversationViewController` holds a level rather than reconstructing one. It is recorded and
deliberately **not** announced — work can only be backgrounded from inside a turn, so the rise
never changes the activity, and the fall lands in the gap between a task finishing and the CLI
waking the agent, where announcing it would post *Finished its turn* microseconds before the
turn resumed. `noteTurnBoundary()` reads the level, and it is called on the status *edge* only:
a status restated without one — a re-init, a model change — is not a boundary and must not
spend the ledger's judgement on a turn that never ended.

`--settings` **layers rather than replaces** (measured: with one `SessionStart` in the file, two
`SessionStart` hooks fire — ours and the user's own), so this does not disable whatever the user
already has wired into their agents.

**The activity states also feed macOS notifications** (`AttentionAlerts.swift`), and the
split above is what makes them worth having: `awaitingUser` posts with sound (a turn stopped
dead), `needsAttention` posts silently (unread), and the *visible* session finishing while the
app is inactive posts too — that case exists because the visible session settles to `idle`
precisely so it needs no in-app flag, and a native conversation reports `idle` off screen as
well. `AttentionAlertPolicy` is the pure judgement, tested as a matrix; `AttentionAlertCenter`
owns delivery. Three rules keep it honest: the `.finished` alert is gated on
`AgentRuntime.reportsOwnTurns` (a shell's working→idle is a quiet timer expiring, and
notifying on each `ls` would bury the rest); banners are suppressed while the app is frontmost
(`willPresent` returns nothing — in-app, the sidebar mark and the permission card are the
cues); and every alert is withdrawn the moment it stops being true — the edge out of an
attention state, the session coming on screen (`setVisibleSession` →
`sessionWasViewed`), or the app coming back to the front over the visible session. Hygiene is
half the feature. `start()` runs only from the real app startup, which is what keeps
`UNUserNotificationCenter` and its permission prompt out of the test host.

**A banner carries the project's icon as an attachment** (`AttentionAlertIcon`), on the
trailing side — the leading slot is the app's and cannot be taken. That was measured, not
assumed (July 2026, macOS 26): the one sanctioned replacement is a communication
notification's sender avatar, and it dead-ends twice — the
`com.apple.developer.usernotifications.communication` entitlement is *restricted*, so AMFI
refuses to spawn a dev-signed build that requests it, and a signed probe app whose
`updating(from:)` rewrite posted without error still rendered the generic icon, because
Apple grants that capability to the iOS family only. Details in
[`permissions.md`](permissions.md). Two rules the attachment must keep: it attaches a *copy*,
because scheduling an attachment **moves** the file into the system's store and the original
is `ProjectIconStore`'s; and a failed copy drops the icon, never the banner — the icon is
decoration, not payload.

**Which of the three arrive is the user's, on four levels**, because the kinds are not equally
welcome — being blocked is work stopping, a turn ending in the background is the chatty one —
and one switch forces a choice between all of it and none of it. `notifiesOnAttention` stays
the master, an outer gate rather than a fallback: it is what people reach for meaning "silence,
all of it", so a per-session exception must not outlive it. Under it sit a toggle per
`AttentionAlert` (stored as the *disabled* set, so a kind added later needs no defaults
migration), the sound (separate from the banner it rides on — wanting to see that a turn is
blocked without being pinged is a real answer), and `notificationsMuted` on the session and its
project. Those two are `Bool?` for the reason the theme's are: **inherit has to be a state**, or
a session inside a muted project offers an Unmute that does nothing. `AttentionAlertScope`
resolves session → project → not muted; the row menus write `nil` where the answer already
matches the project, so the session keeps *following* it. The judgement stays split: the
policy reads the state edge, `AttentionAlertCenter.wants` reads the preferences, and an edge
whose alert is unwanted **withdraws** rather than doing nothing — the notification already on
screen described the old state either way. Muting is not a settings change, so the row menus
call `preferencesChanged()` themselves: `ProjectStore` knows nothing about notifications and
should not learn.

**Clicking one opens its session through the sidebar**, on the same path as a local click —
`SessionNotificationOpened` → `ProjectSidebarViewController.select`. That path fails *silently*
by construction: a row that is not on screen has no index, `row(forItem:)` answers `-1`, and
every guard along the way reads that as "nothing to do", so the app simply stays where it was.
So the arrival has to open every level above the row first, and the chain is longer than the
sidebar looks — repository heading, project, branch heading, and the session a **side chat**
was forked from. That last level was missed, which meant a notification from a side chat the
user had folded away switched to nothing at all. `SidebarTreeBuilder.ancestors(of:in:)` walks
it, from the roots down rather than up from the row, because `NSOutlineView.parent(forItem:)`
only answers for an item it has already been asked to display. Settings is the other way in
from off screen: it replaces the session list entirely, so the arrival leaves it the way Back
does.

`Notification` is the one event with no Codex equivalent in 0.144.6, which is why
`HookLifecycleEvent.codexEventName` is optional and pinned by a test.

**Codex reports the same events, and everything hard about it follows from one difference:**
it has no `--settings` flag. Hooks live in `<CODEX_HOME>/hooks.json`, one file per *account*,
shared by every session — and owned by the user. Measured on 0.144.6: `codex exec` does fire
hooks, and the payload is Claude's apart from the spelling — `session_id`, `turn_id`,
`transcript_path`, `cwd`, `hook_event_name`, `prompt`, and `last_assistant_message` on `Stop`.

- **Routing is by environment, not by file.** `MCPDefaults.portEnvironmentKey` and
  `sessionTokenEnvironmentKey` are exported by `routed(_:for:)` and read by the hook command,
  which is what lets one shared file attribute every session correctly. Verified that a hook
  inherits the launch environment.
- **Which is also what keeps the file *stable*.** Codex pins a trusted hook by hashing its text,
  so a URL carrying today's port would revoke the user's trust on every app launch.
  `CodexHookInstaller` therefore rewrites only on a real change, and a second install returns
  false.
- **`CodexHookInstaller` merges rather than replaces**, marks its own entries with
  `MCPDefaults.hookMarker`, and removes only those on uninstall. This machine's own
  `~/.codex/hooks.json` was written by another tool, which is why that is a rule and not a
  nicety.
- **The command guards on the token** (`[ -n "$THREADING_SESSION_TOKEN" ]`), because the file is
  read by every Codex run under that account, including the ones the user starts themselves.

Both halves are opt-in and separate (`AppSettings.installsCodexHooks`,
`bypassesCodexHookTrust`), because only the second has a security cost: installing writes to a
file the user owns, while `--dangerously-bypass-hook-trust` un-gates *every* hook in that folder
rather than only ours — and an agent can write to `hooks.json`. The safe path is one manual
approval in the Codex TUI, which the stable-text rule is what makes viable.

`SessionStart` also **replaces `CodexSessionDiscovery`'s job**: it hands over `session_id`
already attributed by the token in the URL, where discovery watches the rollout directory and
matches on a launch timestamp. `AgentRuntime.adoptReportedIdentifier` only updates a session
still `awaitingIdentifier`, so Claude's own report — of an id Threading minted — is a no-op.

**Codex brokers permissions on the same hook, and honours the answer.** Measured on 0.144.6: a
`PreToolUse` reply of `permissionDecision: deny` stops the tool outright — the run logs
`PreToolUse Blocked`, the file was not written, and the reason reaches the model, which then
explains itself in its own words. Its payload names the tool with the same `tool_name` /
`tool_input` keys Claude uses, so `MCPServer.routePermission` parses both unchanged. What
differs is the *vocabulary* inside: the tool is `apply_patch` and its argument is a
`*** Begin Patch` envelope, which is the same mismatch `TranscriptReplay.normalised` and
`CodexPatch` already exist to absorb.

`ToolIdentity` knows **both vocabularies**, which is what the type is for — a behaviour,
independent of the provider spelling that introduced it. Codex's names were taken from 1008 real
rollouts rather than from a list, which is the only reason the long tail was found:
`exec` / `exec_command` / `shell_command` / `write_stdin` → `.bash`, `apply_patch` → `.edit`
(a patch has old *and* new text, so it feeds the same `DiffView`), `view_image` → `.read`,
`update_plan` → `.plan`. Everything Codex-specific — spawning agents, goals, simulators — stays
`.unknown` on purpose, because mapping a tool onto an identity also hands it that identity's
permissions.

**This fixes rendering, not prompting, and the difference is worth stating.** Measured across
those rollouts: 59,335 of 64,785 calls (92%) previously drew as unrecognised tools and now carry
the right glyph and diff — but only 204 (0.3%) become auto-allowed. 82% of all Codex tool calls
are shell execution, which legitimately prompts.

That asymmetry is Codex's, not ours: Claude has distinct `Read` / `Grep` / `Glob` tools that the
allowlist can admit, while Codex reads files by shelling out. So the *command* has to be read,
which is what `ShellCommandPolicy` does — the same thing Codex's own `untrusted` approval policy
does, and the only way one tool name covering both reading and writing can be judged at all.

**It is built to be wrong in one direction only.** A missed approval costs a click; a wrong one
runs something destructive unasked. So the allowlist is short and explicit, and anything that
could reach a command the policy never sees is refused outright: redirection, substitution,
backgrounding, a leading variable assignment, an absolute path in place of a bare name. Splitting
on operators is deliberately naive, and that is safe *because* it is naive — a `;` inside a
quoted argument splits into a segment whose first word is not allowlisted, so the line is refused
rather than admitted.

Three rules came from measuring 5,165 real Codex commands rather than from reasoning, and each
was wrong first:

- **`sed` had to be admitted, narrowly.** `sed -n '1,220p' file` is how Codex *reads* — 42% of
  its shell calls — and refusing it left the classifier admitting 20% of real traffic. It is
  also the one allowlisted command that can write (`-i`, `-f`, a `w` in the script), so the
  *script itself* must be a bare line range ending in `p`. Of 2,650 real calls, none used `-i`
  or `-f`.
- **`&&` is a chain, not a hazard.** Banning the character outright made a chain of reads
  prompt, which is most of them; every link is vetted independently instead, and a *lone* `&`
  is still refused because it detaches what came before it.
- **`sed -n '10,$p'` prompts anyway**, and is left prompting: the `$` ban runs first and cannot
  tell `$p` inside single quotes from a variable without tracking shell quoting. Refusing a rare
  legitimate form is the price of not having to be right about quoting.

Together those take real-world coverage from 20% to **59%**, measured by
`ShellCommandPolicyCorpusTests` running the policy over this machine's own rollouts — the unit
tests pin the rules, that one pins the thing the rules exist for, and it fails if a change
quietly undoes the measurement. A second corpus test asserts nothing destructive is ever
admitted.

The `PreToolUse` entry is written **unconditionally** and guarded on
`MCPDefaults.brokerEnvironmentKey`, which only `streamPlan` exports. Installing it per-surface
was the obvious alternative and is wrong: `hooks.json` would be rewritten every time a session
changed surface, and every rewrite costs the user's trust decision. An entry that is inert
until an environment variable appears is how one shared file serves two surfaces.

**A hook is invisible by construction**, which is the same problem `ProjectIconResearch` has and
is answered the same way: every run leaves a record. `EventLog.Category.hooks` is the durable
half, and it is deliberately *not* fed per turn — the boundaries themselves go to
`ThreadingLogger` at `.debug`, which is the live `log stream` view, while the journal keeps only
what a report weeks later would need:

- **The one transition that matters** — a session going from inferring its state to being told
  (`AgentRuntime.applyLifecycle`). "Did the hooks reach this session at all" is the first
  question any bug report raises, and this is the only line that answers it.
- **Every rejected report** — an unknown token, an unnamed event, an empty body. A report that
  arrived and was refused looks exactly like a hook that never ran, and the causes are
  unrelated.
- **A rewritten `hooks.json`**, because a rewrite is the moment the user's Codex trust decision
  stopped applying. It is the answer to "these worked yesterday".
- **A launch with no listener port**, which silently disables the whole feature.

`HookOutcomeLog` covers the one failure the app cannot otherwise see: a hook that never
*reaches* the listener leaves nothing here, because nothing arrived — while the agent sits on a
blocked tool. `--include-hook-events` is passed for that and only that, and Claude's
`hook_response` carries the `outcome`, `exit_code` and `stderr` this side never observed
(verified against a hook made to exit 7). It is read outside `StreamEvent`, which is a pure
function feeding the conversation's rendering: a diagnostic nothing draws does not belong in the
model the views are built from. The parsing is split from the logging so the decisions are
testable, and a *missing* `outcome` counts as a failure — the schema belongs to the CLI, and a
renamed field should make the journal noisy rather than quietly stop reporting.

One bug worth keeping: every command reads stdin **before** its guard
(`threading_payload=$(cat)`). A guard that returns without reading leaves Codex writing the event
into a pipe nobody drains, and it is the *unrouted* runs — the user's own terminal sessions —
that would pay for it. Found by a probe whose hook posted an empty body, and pinned by a test.

## The account's own status line

Claude draws a status line from its **interactive TUI** only. The runner is driven by an Ink
component's effects and renders into a `<Text>` in that tree, so a native conversation — which
runs `--print --output-format stream-json` and mounts no TUI — never invokes the command at all.
(The guards inside the runner itself are `disableAllHooks` and workspace trust; the print-mode
answer comes from the component never mounting, not from a check in the runner.) So a terminal
pane may already be showing the user facts, while a native pane never is. `ClaudeStatusLineCoverage` answers which facts those are, so the session's status
card (see [`git.md`](git.md)) can add the rest instead of printing them twice.

**Coverage cannot be read off the configuration.** The command is the user's own program with the
user's own authority. The status line on the machine this was written against ignored the
`total_lines_added` and `rate_limits` handed to it and printed `+1699 -331` and `5h 0%` instead,
because it shells out to `git -C "$cwd" diff --numstat` and reads usage from its own cache and a
`curl`. Its output is not a function of its input, so the only honest way to learn what it prints
is to run it and read the result. Verified by feeding it a payload whose numbers it contradicted.

**The payload carries only truth.** Every field is either a real value or absent — `cost` and
`rate_limits` are omitted rather than zeroed, because Threading cannot observe the former and must
not invent the latter. A status line is commonly a *caching bridge*: the one here writes
`~/Library/Application Support/Claudex/ClaudeStatus/<profile>.json`, which is the file
`ClaudeUsageCache` reads back for the account's usage. An earlier design probed by substituting
sentinel values to see which were echoed; against a bridge that would have cached Threading's own
fiction and fed it back as the account's usage. Passing only truth makes the run
indistinguishable from Claude's, which is also why it needs no consent the launch did not already
have.

The rule was then checked against that bridge rather than left as prudence: its `writeCache` opens
with `guard let rateLimits = status.rateLimits, rateLimits.containsValue else { return }`, so a
payload with no `rate_limits` cannot touch the usage cache. It does append a
`<profile>.heartbeat.json` entry recording `rate_limits_present: false` — a separate file nothing
here reads, and the only trace a coverage run leaves.

**Coverage is a search for values we already hold, not a parse.** If the output contains "Opus 5"
the model is covered. A script that abbreviates it to something unrecognised reads as *not*
covered and the card shows the model a second time — duplicating a fact is the safe direction for
a guess, and hiding one the user asked for is not. Two consequences worth keeping: fast mode is
only ever recognised when it is **on**, because "off" and "not shown" are the same absence; and
the line counts are matched as the `+N`/`N` pair a numstat summary prints, so a token total of
`1699` cannot pass for a diff stat.

Precedence follows the CLI's, which for this key is **not** a merge: a managed policy replaces the
user's `statusLine` outright, and below that `.claude/settings.local.json`,
`.claude/settings.json` and the account's `settings.json` override most-specific-first. The answer
is cached against the resolved command and the CLI version rather than against the account,
because coverage is a property of the program — two accounts pointing at one script share it, and
a newer CLI may hand that script a field it starts printing.

The same stdin rule as the hooks above applies in reverse here: the payload is written and the
handle **closed** before the output pipe is drained, because these commands open with
`input=$(cat)` and write nothing until they have EOF.
