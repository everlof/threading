---
title: Browser and execution audit
description: Grant browser access deliberately and inspect the work an agent performed.
group: Supervise
order: 45
---

# Browser and execution audit

The live browser (Cmd+Shift+B) is a real browser tab that belongs to one
session. The agent works with the same rendered pages you see, including
persistent signed-in state when you choose to use it. It is separate from the
lightweight preview used to render local work.

## Browser authority

Browser access is granted per origin. Local development origins and external
sites have distinct permissions, and a redirect to a new origin requires new
authority. A grant says where the agent may act. Consequential actions on that
site still ask.

The agent can inspect the page through bounded semantic operations, interact
with referenced elements, take screenshots, and use isolated or responsive
views. Stale element references fail instead of guessing at a changed target.

## Human boundaries

Passwords remain a human-takeover step by default: the browser focuses the
field and waits for you, and the agent never sees the value. You can instead
store a test account for the agent to sign in with. Submitting a form requires
confirmation, and file uploads go through the native file chooser. Navigation
and interaction stay visible, so you can take over at any point.

You approve a reference image before it becomes a visual baseline. Later
comparisons report the changed regions and leave the reference in place.

You can also pin a spot on a live page and write a note for the agent, which
reads the pins with the page.

## Execution audit

Where a runtime exposes structured activity, the app records provider-neutral
events for tool calls, permission decisions, MCP activity, and results. Open
**Execution Audit** from the display panel's **+** menu. The audit is local,
bounded, redacted, and hash-linked, so a changed record shows up in its
integrity status.

The audit records exact structured events. It never copies prompts, reasoning,
or assistant prose, and it does not reconstruct actions from terminal text.
Claude Code, Codex, and Grok Chat sessions provide structured events. Grok
Terminal and OpenCode sessions currently provide none, so their audit may be
empty.

Browser permission history records what authority was granted. Execution
activity records what supported tools did with it.
