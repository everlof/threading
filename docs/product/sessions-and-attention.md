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

The important signal is not how much text a process produced. It is whether
the agent is progressing independently, needs a decision, or has produced
work worth reviewing.

## Session states

### Working

The provider process is active and making progress. Working sessions remain
visible but should not compete for immediate attention.

### Needs you

The agent has asked a question or requested permission. The session moves
forward in the visual hierarchy because progress is blocked on a human
decision.

### Ready to review

The current task has reached a useful boundary. Open the conversation summary
and review the resulting changes before continuing or committing.

### Idle

The session is not currently active. Its conversation and project context are
still available.

## Multiple sessions

Sessions can run concurrently in one project or across several projects. Each
session keeps its own provider process and conversation history. When an agent
delegates work, child activity remains associated with the parent session but
is shown as a separate tree and timeline.

## Persistence and recovery

Session metadata is persisted separately from the provider transcript. This
lets the app restore project organization, attention state, and working
context while continuing to treat the provider conversation as provider-owned
data.

If a provider process exits, the session remains available for inspection.
Whether it can resume depends on the provider and the state recorded by its
CLI.

## Coordinating sessions

Supported sessions in the same project can discover one another, send a
message, steer queued work, or wait for another session to finish. Every
cross-session action stays visible in the transcript with its source, target,
and result; coordination is not a hidden backchannel.

The boundary is deliberately narrow. A session cannot coordinate with another
project, and sending a message does not silently wake a dormant provider
process. Those limits keep project scope and operator intent explicit.

## Practical habits

- Name sessions by outcome rather than by provider.
- Keep unrelated tasks in separate sessions.
- Treat **Needs you** as the primary inbox.
- Review completed changes before reusing a working directory for a different
  task.
