# Session Activity

Deriving dormant/idle/working/needsAttention, and the lifecycle hooks that replace the inference.

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
the guards exist because it cannot tell thinking from repainting. Claude's own hooks say so
outright, so `AgentLauncher.claudeCommand` now writes a `--settings` file for *terminal*
sessions too — lifecycle hooks only, no `PreToolUse`, because a terminal session raises the
CLI's own permission prompt and intercepting it would replace a working prompt with a second
one. `UserPromptSubmit`, `Stop`, `Notification` and `SessionStart` curl back to the listener
(`MCPDefaults.lifecyclePathPrefix`), and `HookLifecycleRelay` hands each report to the session's
tracker. Verified end to end against CLI 2.1.217: the three ordinary events arrive in order,
carrying the prompt text.

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

`--settings` **layers rather than replaces** (measured: with one `SessionStart` in the file, two
`SessionStart` hooks fire — ours and the user's own), so this does not disable whatever the user
already has wired into their agents.

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
- **The command guards on the token** (`[ -n "$SKALMAN_SESSION_TOKEN" ]`), because the file is
  read by every Codex run under that account, including the ones the user starts themselves.

Both halves are opt-in and separate (`AppSettings.installsCodexHooks`,
`bypassesCodexHookTrust`), because only the second has a security cost: installing writes to a
file the user owns, while `--dangerously-bypass-hook-trust` un-gates *every* hook in that folder
rather than only ours — and an agent can write to `hooks.json`. The safe path is one manual
approval in the Codex TUI, which the stable-text rule is what makes viable.

`SessionStart` also **replaces `CodexSessionDiscovery`'s job**: it hands over `session_id`
already attributed by the token in the URL, where discovery watches the rollout directory and
matches on a launch timestamp. `AgentRuntime.adoptReportedIdentifier` only updates a session
still `awaitingIdentifier`, so Claude's own report — of an id Skalman minted — is a no-op.

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
`SkalmanLogger` at `.debug`, which is the live `log stream` view, while the journal keeps only
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
(`skalman_payload=$(cat)`). A guard that returns without reading leaves Codex writing the event
into a pipe nobody drains, and it is the *unrouted* runs — the user's own terminal sessions —
that would pay for it. Found by a probe whose hook posted an empty body, and pinned by a test.
