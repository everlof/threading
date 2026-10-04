---
title: Conversations, permissions, and subagents
description: Preview structured messages, consequential actions, and delegated work.
group: Supervise
order: 40
---

# Conversations, permissions, and subagents

The experimental Chat view turns a provider's event stream into a native
transcript. Your messages, agent responses, tool activity, questions,
permissions, and delegation each get their own presentation. Chat is
available for Claude Code, Codex, Grok, and Cursor sessions; Cursor sessions
use only Chat, and OpenCode sessions use only the terminal. The provider TUI
remains the established interface for the others.

## Conversations

Conversation content is grouped by turn so you can see what the agent was
asked, what it attempted, and what result it reached. Tool details stay
collapsed until you open them.

The app leaves provider history in the provider's own format. It reads
provider events for presentation and keeps what resume and audit need.

Type `/` in a native conversation to browse commands advertised by its live session. Codex
skills use `$`; Claude skills follow Claude’s advertised slash syntax. The catalog can change
while a session is open, and disabled actions remain visible with their reason but cannot be
run. Selecting an entry inserts it into the composer so its arguments can be completed before
submission.

## Permission requests

Consequential actions stay attached to the conversation that proposed them. A
permission request shows:

1. what action the agent wants to perform;
2. what command, file, host, or other resource is in scope;
3. whether the approval applies once or establishes a reusable rule.

In Claude Chat, a tool that would change something raises a card with the
command or the diff, one request at a time. Reading and searching pass without
asking. Codex Chat runs sandboxed with `workspace-write` instead of asking:
operations that need more fail, so use the Terminal surface when a task needs
Codex's interactive approvals. Cursor asks before it runs a shell command.

Approve only when the displayed action and scope match your intent. Declining
a request returns control to the agent so it can explain, narrow, or change
its approach.

## Questions

When an agent needs product or implementation judgment instead of a system
permission, it can ask a question with named options. The session enters
**Needs you**, and you answer in the conversation on the Mac or on a paired
iPhone. The answer becomes part of the same conversation context.

## Subagents

When Claude Code or Codex delegates work, both Chat and Terminal sessions show
a **Subagents** summary with live working and done counts. Each child row can
show:

- the task it received;
- its model, current tool, elapsed time, and token count;
- relevant tool or conversation activity;
- the result returned to its parent.

Select a child to open its own conversation in the display panel. Child output
stays out of the parent's transcript, so you can follow the parent's task and
each child's progress separately.

## Remote decisions

When remote access is on, your own paired iPhone can answer permission
requests. Someone you share one conversation with gets **View** or
**Collaborate**, and can answer permission requests only if you also turn on
**Allow approving agent requests**. A share covers that one conversation and
no other project or chat.
