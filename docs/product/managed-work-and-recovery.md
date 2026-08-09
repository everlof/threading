---
title: Managed work and recovery
description: Isolate, schedule, deliver, and recover long-running agent work safely.
group: Supervise
order: 55
---

# Managed work and recovery

Long-running agent work should survive interruptions without gaining hidden
authority. Managed workspaces, scheduled messages, and recovery policies make
that durability explicit.

## Managed workspaces

A managed workspace is an opt-in, session-owned Git worktree. The agent works
in the detached checkout while your source checkout stays untouched. The app
only offers this mode when the session has the tools required to complete its
delivery contract.

When the task finishes, you can:

- merge the result with a strict fast-forward check and clean up the worktree;
- keep the workspace for local review; or
- use a separately enabled GitHub pull-request workflow.

If validation or delivery cannot complete safely, the app refuses the finish,
keeps the workspace, and marks the session **Needs you**. It does not discard
the work to make the interface look complete.

## Scheduled and finish-triggered work

You can prepare a message or a whole session plan for a chosen time, a known
provider-limit reset, or the moment the current turn finishes. The launch plan
is frozen when it is scheduled so later interface changes do not silently
alter what will run.

Clock-based delivery requires the app to be running at the scheduled moment.
A missed item waits for **Send now** instead of being delivered unexpectedly
at the next launch. A dormant native session may be restored when its contract
allows it; the app will not type into a dormant terminal session whose restore
state is ambiguous.

## Limits and startup recovery

When a provider reports a structured rate limit, the default behavior is to
flag the session for attention. You can opt into waiting for the reset and
sending a continuation afterward. The app never upgrades a plan, spends money,
or switches accounts on its own.

After a normal quit, configured sessions can restore normally. After an
unclean exit, the app holds automatic work until the previous state has been
inspected. Repeated startup failures enter Recovery Mode, which starts without
sessions, extensions, remote access, or other automatic work. From there you
can inspect the workspace and make a deliberate one-shot attempt to return to
normal startup.
