---
title: Overview
description: The mental model for supervising local coding agents.
group: Start
order: 10
---

# Keep local coding sessions together

The app is not another coding agent and it does not resell model access. It is
a native workspace for supervising agent processes you already use, including
Claude Code, Codex, Grok, and OpenCode. Each runtime exposes different
capabilities, so the app only offers controls that its integration can verify.

Your provider CLI still owns the conversation with its model. Your project
folder still owns the files and Git repository. The app connects those layers
and gives them a coherent interface for attention, conversation, permissions,
delegation, and review.

> **The useful mental model:** provider CLI → conversation → project changes.
> The app keeps those layers connected without pretending they are the same
> thing.

## What the app adds

- **Attention state.** See which sessions are working, waiting for you, or
  ready to review without reading every line of output.
- **Native conversations.** Follow agent messages, tool activity, questions,
  permissions, and results in one structured transcript.
- **Visible delegation.** Inspect subagents as a tree instead of losing their
  work inside one flattened log.
- **Review surfaces.** Move from the conversation to the exact Git or image
  change it produced.
- **Local accounts.** Use the provider accounts and command-line tools already
  installed on your Mac.
- **Durable work.** Isolate risky tasks in managed workspaces, schedule the
  next step, and recover safely when a provider or the app stops unexpectedly.
- **Inspectable browser work.** Grant browser access by origin, compare visual
  changes, and keep an exact local audit of supported tool activity.
- **Optional remote access.** Pair a browser or iPhone with a specific
  conversation when you want to follow work away from the desk.

## Local-first by design

The desktop app runs on your Mac and starts local provider processes. It does
not require a hosted project mirror or a new provider subscription. Remote access is
an optional, explicitly paired feature; it is not required for normal use.

Extensions follow the same principle. They declare capabilities and
permissions, and the host keeps control of resources and native interface
rendering.

## Where to go next

Start with [Getting started](getting-started.md), then read
[Sessions and attention](sessions-and-attention.md) to understand the status
model that makes concurrent agent work manageable. For longer-running tasks,
continue with [Managed work and recovery](managed-work-and-recovery.md).
