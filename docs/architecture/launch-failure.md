# When An Agent Will Not Start

A launch that dies on the way up: keeping what it said, telling the truth about it afterwards,
refusing the ones we can see coming, and handing the rest to an agent.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

## The moment, measured

A screen recording, 3.4 seconds long, of pressing **Resume Session** on a Codex conversation.
Frame by frame at 15fps:

```
f_026   the pane is a terminal; Codex draws its banner, "Resuming session…"
f_028   Error: Failed to resume session from …/rollout-2026-08-20T20-28-39-….jsonl:
        thread/resume failed during TUI bootstrap: … thread-store internal error:
        failed to resume local thread recorder: final paginated rollout record
        … is missing an ordinal (code -32603)
f_029   the dormant placeholder, "The conversation is saved and will pick up where it left off."
```

**One frame.** The only account of what went wrong existed for about seventy milliseconds, and
what replaced it was a sentence that was no longer true beside a button that would do the same
thing again. Four facts fall out of that recording and each is load-bearing:

- **The exit code was already being stored and read by nothing.** `AgentSession.lastExitCode` was
  written in `AgentSessionViewController` and had no readers anywhere in the app. The information
  needed to tell this apart from an ordinary ending had been on disk the whole time.
- **The teardown was unconditional.** `TerminalContainerViewController.agentSession(_:didExitWithCode:)`
  detached the child and showed the dormant placeholder for *every* exit, whether the agent had
  worked for an hour or died in 900ms. The conversation surface next door had already decided the
  opposite way, in a comment that reads like a warning nobody had generalised: *"the view is kept
  rather than swapped for the dormant placeholder: the conversation it is showing is the only
  record of the turn on screen."*
- **Selecting the row retried it.** Selecting a dormant session is the reopen gesture, so every
  click re-ran the same doomed command — a process spent to reproduce a failure the user had
  already read.
- **The fault was knowable before launching.** Codex numbers rollout records with an `ordinal`
  and resumes by reading the tail. The specimen's last nine records — written the next morning,
  starting with Threading's own `set_session_name` prompt — had none. That is checkable from
  64KB of a 38.9 MB file, in under a millisecond, without starting anything.

## The narrow rule, and why it is narrow

The tempting check is "does the final record carry an ordinal". It is wrong, and measuring is
what showed it: of **1,842 rollouts** on the machine this was written against, **1,818 carried no
ordinals at all** — the older format — and one picked at random resumed perfectly well under the
same CLI that refused the broken one. **23** ended with an ordinal. Exactly **one** was in the
fatal state: numbered, then not.

So `CodexRolloutHealth` asks for the *mixed* shape — the tail contains an ordinal somewhere and
the final record has none. The naive rule would have condemned 98% of the user's conversations.
`TranscriptResumeHealthTests` holds all three shapes so nobody re-derives the naive one.

The repair was confirmed the same way, in an isolated `CODEX_HOME`: the original copy reproduced
the error and exited 1; a copy with ordinals written onto those nine tail records booted the TUI
and stayed up. The conversation was never lost — the file was refusable, not unreadable.

## Four layers

Detection, evidence, refusal and repair are separate and only the first two are provider-neutral.

The execution directory is also a preflight. A project record can outlive a checkout removed
outside Threading; allowing the login shell to discover that spends a session row and loses the
only copy of a fresh opening prompt before the provider writes a transcript. The composer asks
`ProjectLaunchPreflight` before it creates the row and therefore keeps the brief on refusal. The
terminal launch path asks the same check so an existing row gets a durable, named failure instead
of an empty exit-code-1 report from the shell's failed `cd`.

- **`SessionLaunchFailure`** is the record: origin (a process exit, or a preflight refusal),
  exit code, how long it lived, a summary, the bounded captured output, the conversation file,
  and an optional recognised-cause slug. It is `Codable` on `AgentSession`, so what a launch said
  outlives the process, the pane and the app. Nothing here names a runtime.
- **Classification** is `SessionLaunchFailure.looksLikeLaunchFailure`: a non-zero status **and** a
  life shorter than `youngProcessWindow`. Both are required. A status alone catches every agent
  quit with a signal; a short life alone catches a session opened and closed on purpose.
- **`SessionLaunchDiagnosis`** turns the captured words into a sentence the user can act on. Every
  rule is a bonus: the lines are kept, shown and copyable without one, so a CLI rewording itself
  costs a better sentence and nothing else. Rules stay narrow because a *wrong* cause is worse
  than none — a user told the wrong reason stops reading the lines that say the right one.
- **`TranscriptResumeHealth`** is the preflight, dispatching per runtime and answering `usable`
  for every runtime with no such check.

### Where the preflight is asked, and where it is not

In `AgentSessionViewController.launch`, before a plan is built — **not** inside
`AgentLauncher.codexCommand`, and the difference matters. The command builder's only possible
response to a refusal is to fall through to a fresh launch, and silently starting a new
conversation in place of the one the user asked to reopen is worse than any failure it would be
avoiding. Claude's branch has gated `--resume` on `ClaudeTranscript.exists` since the wrong-slug
bug; this is the same question asked one step further, because Codex's failure mode is a file that
exists and cannot be opened.

The same launch boundary asks one live-ownership question before it builds a plan. Codex refuses a
second process for an identifier already held by `codex … resume <id>`, but the failed bootstrap
can exit without leaving useful terminal output; waiting for output therefore produced the generic
“stopped right after starting” record. `.detectableExternalResume` is the measured capability for
both facts — exact resume ownership is visible in argv, and concurrent ownership is a refusal —
and is currently Codex-only.

The process-table walk runs on a user-initiated worker. It takes one kernel snapshot, filters by the
runtime executable before reading argument vectors, and requires the exact adjacent `resume`, id
pair; an id merely mentioned elsewhere in a prompt is not ownership. The main actor rechecks that
the stored session still has the id that was inspected, then either continues through every normal
preflight or records a no-process `.preflight` failure with cause `identifier-in-use`. No argv or
identifier is logged. The existing failure surface says to close the conversation elsewhere and
try again, so selecting the row no longer spends a doomed process merely to discover the lock.

## What the user sees

`LaunchFailureView` replaces the dormant placeholder rather than annotating it, for the reason
`showRecoveryState` already gives about the recovery band: a surface and a placeholder saying the
same thing bury the one sentence that matters. Dormant means "this ended and can be picked up".
This means "this did not start, and pressing the same button will do the same thing."

The output well is the whole point of the component. Selectable (copying it is most of the point),
not editable (the surface must not offer to let somebody change a record of what happened), not
wrapped (a wrapped stack trace stops looking like the thing the terminal showed), scrolling inside
its own container. It hides rather than showing an empty box for a preflight refusal, which never
started a process and has nothing to quote.

A native conversation can also die while a command-shaped opening message is waiting for its
provider catalog. That message returns to the durable conversation draft before the ended surface
hides its composer; if somebody typed during launch, the opening command is restored first and the
newer draft follows it. An unavailable catalog may prevent semantic dispatch, but it cannot turn a
message the start composer already accepted into private, undrainable controller state.

Selection no longer retries. The retry is a button on the surface, which is a decision rather than
a side effect of navigating, and it clears the record first so the gate that sent us there does
not refuse it.

### The column states its own width, and the pane keeps its own

The column is capped at `LaunchFailureDefaults.wellMaximumWidth` (720) so the well stays a
quotation rather than a document, and it takes a *definite* preferred width rather than a cap,
because a `.centerX` stack given only "no wider than the pane" comes out as wide as whichever
sibling happens to be widest.

That preferred width is a **constant**, and it has to be. It was first written as
`stack.width == self.width - horizontalInset` at `.defaultHigh`, which reads as "stretch the
column to the pane" and is not what a two-way constraint says: with the column also capped at 720,
the only way to satisfy it is to hold *the pane* at 800. `NSSplitView` sizes a pane through its
item's `holdingPriority`, and the session pane deliberately keeps AppKit's default 250 so that it
is the pane absorbing a window resize, with the sidebar and display panel one step above at 260
(`SidebarDefaults.holdingPriority`). `.defaultHigh` beats all of it.

Measured in the running app, with one session in the window failed to launch: the session pane sat
at exactly 800pt through a 2560→1933pt window resize and through the divider, while the sidebar
swelled to 1759pt to take every remaining point, and no drag could widen the terminal. Nothing was
logged, because nothing was unsatisfiable — the split view was obeying a legal constraint that
outranked its own. It read as "the terminal has a maximum width".

**The rule this leaves: pane content states its own measure, and only a `<=` may mention the
pane's width.** `ScheduledSessionPlaceholderView` and `ThemedChartPlaceholderView` were already
written this way; the latter also records why the one *required* ceiling carries no negative
constant (a zero-width construction pass makes `width <= -80` unsatisfiable). The inset sits one
priority step above the column's own measure, so a pane between 720 and 800 spends the difference
on its margin rather than on the column.
`LaunchFailureViewTests.testAWidePaneKeepsTheWidthItWasGivenRatherThanTheColumnsOwn` is the
regression boundary, and it states its host's width at `.defaultLow` on purpose: a fixture that
pins the host at `.required` cannot see this defect at all.

## Reporting

**Report a Problem…** prefills the existing sheet (`ReportProblemViewController` →
`GitHubIssueSubmitter`), and the evidence goes in the **editable** field rather than travelling
alongside as something the user cannot see. Captured terminal output is arbitrary program text;
the one rule enforced about it is that nobody can send it without having been shown it, and the
way to guarantee that is to make it the thing they are looking at and free to cut. The environment
block stays `GitHubIssueEnvironment`'s — safe by construction — and is composed separately, as
[`github.md`](github.md) requires.

## Repair by agent

Offered only for a failure with a named conversation file **and** a cause about that file. A
missing executable and an expired login are real diagnoses with nothing to repair, and an agent
asked to fix "the session won't start" with nothing to work on will still do something, somewhere
in the user's home directory.

The safety property is a boundary, not a prompt:

- **Threading copies the file; the agent only ever edits the copy.** `LaunchRecoveryWorkspace`
  makes a fresh folder per attempt — a retry inheriting the last one's leftovers would hand the
  agent a directory of half-repaired files.
- **The agent never names its target.** `LaunchRecoveryTicket` links a repair chat to the one
  conversation Threading made it for, and `propose_conversation_repair` takes no target argument.
  An agent that decides to be helpful about a different conversation has no way to say so. The
  ticket lives in the repair folder rather than in memory, because a repair can span an app
  restart.
- **The claim is checked.** A repaired file must sit inside the prepared folder and must now pass
  the same structural check that condemned the original. That is not a promise the runtime will
  accept it — it is the strongest thing knowable without starting one, and exactly the assertion
  the agent's work was supposed to make true.
- **The swap is Threading's, and the user's.** `ConfirmationAlert.choose` under
  `.conversationRepairOutcome`, which is `.alwaysAsks(.newQuestionEachTime)`: each repair is a
  different agent's account of a different broken conversation, and "always accept what an agent
  proposes about my conversations" is the setting this deliberately cannot have.
- **The displaced original is kept**, beside the working copy rather than beside the original.
  One write into the provider's directory, with one file: a `before-repair-` sibling left in
  there is a second write into a directory whose contents are not ours to add to, and one the
  provider's own session listing would then have to ignore.

On acceptance the **original row is repaired in place** — same session, same name, same history,
now resumable — and the repair chat is archived. The alternative, letting the repair chat take
over the row, would leave the user talking to the recovery agent's chat rather than the
conversation they asked for.

Afterwards the user is offered the diagnosis as a prefilled report, whether or not the repair
worked: a clear account of a conversation that cannot be saved is worth more than silence.

## What is deliberately not here

- **No automatic repair of the ordinal fault.** Threading knows the shape of exactly one
  corruption today, and shipping a bespoke fixer for it would answer this bug and no other. The
  agent route generalises: it is briefed with whatever the runtime actually said.
- **No live terminal kept on screen.** It was the first design and it is worse: it fights
  `AgentRuntime`'s dormancy invariant, and it dies on app restart. A durable record survives the
  quit, feeds the report and the agent brief, and is what those two need anyway.
- **No new sidebar nesting.** `forkedFrom` is a real Claude fork operation with a transcript
  behind it, and a repair chat is not that. The chat's title names the conversation it is about.
