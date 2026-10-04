---
title: Overview
description: The mental model for supervising local coding agents.
group: Start
order: 10
---

# Keep local coding sessions together

Threading is a native Mac workspace for supervising the coding agents you
already use: Claude Code, Codex, Grok, OpenCode, and Cursor. It does not write
code itself and it does not resell model access. Each runtime exposes different
capabilities, so the app only offers controls that its integration can verify.

Your provider CLI still owns the conversation with its model. Your project
folder still owns the files and Git repository. The app connects those layers
and adds one interface for attention, conversation, permissions, delegation,
and review.

> Provider CLI → conversation → project changes. The app keeps the three
> connected and keeps them separate.

## What the app adds

- **Attention state.** See which sessions are working, waiting for you, or
  ready to review without reading every line of output.
- **Provider TUI.** Keep the provider's own terminal interface for Claude
  Code, Codex, Grok, and OpenCode sessions.
- **Experimental native conversations.** Claude Code, Codex, Grok, and Cursor
  sessions can show messages, tool activity, questions, permissions, and
  results in one structured transcript. Cursor sessions use only this view.
- **Visible delegation.** Inspect each subagent's task, progress, and result
  in its own row.
- **Review surfaces.** Move from the conversation to the exact Git or image
  change it produced, and open a GitHub pull request or GitLab merge request
  from the same pane.
- **Local accounts.** Use the provider accounts and command-line tools already
  installed on your Mac.
- **Durable work.** Isolate risky tasks in managed workspaces, schedule the
  next message, set a curfew, run automations on a schedule, and recover
  safely when a provider or the app stops unexpectedly.
- **A panel beside the chat.** Agents can show images, charts, and file
  comparisons there, drive an iOS Simulator, and stream device logs. You can
  keep a paired iPhone's screen in the same panel.
- **Inspectable browser work.** Grant browser access by origin, compare visual
  changes, and keep an exact local audit of supported tool activity.
- **Optional remote access.** Pair your iPhone with the Mac, or share one
  conversation with someone else through a link, to follow work away from the
  desk. Remote access is in beta.

## Local-first by design

The desktop app runs on your Mac and starts local provider processes. It needs
no hosted project mirror, no Threading account, and no new provider
subscription. Remote access stays off until you turn it on and pair a device.

Extensions declare their capabilities and permissions, and the app keeps
control of resources and draws their interface itself.

## Where to go next

Start with [Getting started](getting-started.md), then read
[Sessions and attention](sessions-and-attention.md) for the status model that
tells you which of several running sessions needs you. For longer-running tasks,
continue with [Managed work and recovery](managed-work-and-recovery.md).
