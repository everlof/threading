---
title: Browser and execution audit
description: Grant browser access deliberately and inspect the work an agent performed.
group: Supervise
order: 45
---

# Browser and execution audit

The live browser lets an agent work with the same rendered pages you can see,
including persistent signed-in state when you choose to use it. It is separate
from the lightweight preview used to render local work.

## Browser authority

Browser access is granted per origin. Local development origins and external
sites have distinct permissions, and a redirect to a new origin requires new
authority. A grant answers where the agent may act; it does not silently grant
permission for every consequential action on that site.

The agent can inspect the page through bounded semantic operations, interact
with referenced elements, take screenshots, and use isolated or responsive
views. Stale element references fail instead of guessing at a changed target.

## Human boundaries

Passwords remain a human-takeover step by default. Submitting a form requires
confirmation, and file uploads go through the native file chooser. The browser
keeps navigation and interaction visible so you can take over whenever the
task crosses a boundary you want to handle yourself.

Visual baselines are also explicit. You approve the reference image before it
becomes a baseline, and later comparisons report the changed regions rather
than silently replacing the reference.

## Execution audit

Where a runtime exposes structured activity, the app records provider-neutral
events for tool calls, permission decisions, MCP activity, and results. The
audit is local, bounded, redacted, and hash-linked so unexpected changes are
detectable.

The audit records exact structured events, not prompts, hidden reasoning, or
guesses reconstructed from terminal prose. Coverage therefore varies by
runtime: when an integration cannot verify an action, the app does not invent
an audit event for it.

Browser permission history and execution activity complement one another. The
first explains what authority was granted; the second explains what supported
tools actually did.
