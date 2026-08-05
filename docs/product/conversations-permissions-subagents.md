---
title: Conversations, permissions, and subagents
description: Keep messages, consequential actions, and delegated work legible.
group: Supervise
order: 40
---

# Conversations, permissions, and subagents

The conversation view turns a provider event stream into a structured,
native transcript. Human messages, agent responses, tool activity, questions,
permissions, and delegation remain distinct instead of becoming one long
terminal log.

## Conversations

Conversation content is grouped by turn so you can see what the agent was
asked, what it attempted, and what result it reached. Tool details can be
inspected when they matter without making every low-level event equally loud.

The app does not rewrite provider history into a new proprietary format. It
interprets provider events for presentation while preserving the boundaries
needed for resume and audit.

Type `/` in a native conversation to browse commands advertised by its live session. Codex
skills use `$`; Claude skills follow Claude’s advertised slash syntax. The catalog can change
while a session is open, and disabled actions remain visible with their reason but cannot be
run. Selecting an entry inserts it into the composer so its arguments can be completed before
submission.

## Permission requests

Consequential actions stay attached to the conversation that proposed them. A
permission request should make three things clear:

1. what action the agent wants to perform;
2. what command, file, host, or other resource is in scope;
3. whether the approval applies once or establishes a reusable rule.

Approve only when the displayed action and scope match your intent. Declining
a request returns control to the agent so it can explain, narrow, or change
its approach.

## Questions

When an agent needs product or implementation judgment rather than a system
permission, it can ask a question. The session enters **Needs you**, and the
answer becomes part of the same conversation context.

## Subagents

Delegated work is presented as a tree rooted in the parent session. Each child
can expose:

- the task it received;
- its current state and elapsed time;
- relevant tool or conversation activity;
- the result returned to its parent.

This preserves two useful views at once: the parent’s overall task and the
children’s independent progress. Completed delegation is not flattened into a
single anonymous block of output.

## Remote decisions

When remote access is enabled, a paired collaborator may be allowed to view,
participate in, or approve a specific shared conversation. The granted role
determines which controls are available; pairing a device does not grant
blanket access to every project.
