---
title: Sessions and attention
description: Follow agent state instead of terminal output volume.
group: Supervise
order: 30
---

# Sessions and attention

A session is one agent conversation attached to a project and a working
directory. It keeps the transcript, process state, provider identity, and
review context together.

The sidebar tracks whether the agent is progressing on its own, needs a
decision, or has produced work worth reviewing. How much text a process
printed does not change its state.

## Session states

### Working

The provider process is active and making progress. The row shows a spinner
and nothing louder.

### Needs you

The agent has asked a question or requested permission, and nothing moves
until you answer. The row shows a filled dot, and a macOS notification with
sound can reach you while the app is in the background.

### Ready to review

The agent finished a turn while you were looking elsewhere. The row shows a
hollow ring until you open it. Review the resulting changes before continuing
or committing.

### Idle

The agent has exited, so the row is greyed out. Its conversation and project
context are still available, and selecting the row resumes it.

## Multiple sessions

Sessions can run concurrently in one project or across several projects. Each
session keeps its own provider process and conversation history. When Claude
Code or Codex delegates work, a Subagents summary under the parent session
lists each child with its own status and progress.

## Persistence and recovery

The app stores session metadata separately from the provider transcript. It
restores project organization, attention state, and working context, and
leaves the provider conversation where the provider wrote it.

If a provider process exits, the session remains available for inspection.
Whether it can resume depends on the provider and the state recorded by its
CLI. By default an agent ends when Threading quits. **Settings ▸ Advanced ▸
Background host** (off by default, still being proven) keeps agents running
while the app is closed and hands them back on the next launch.

## Coordinating sessions

Supported sessions in the same project can discover one another, send a
message, steer a running turn, or wait for another session to finish. Every
cross-session message appears in the receiving transcript with its sender.
Each session also has a mailbox: a message to a busy or stopped session waits
there until the agent reads it.

A session cannot coordinate with another project, and a message never wakes a
dormant session unless you grant that sender permission to wake it.

## Practical habits

- Name sessions by outcome rather than by provider.
- Keep unrelated tasks in separate sessions.
- Treat **Needs you** as the primary inbox.
- Review completed changes before reusing a working directory for a different
  task.
