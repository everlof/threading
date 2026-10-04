---
title: Managed work and recovery
description: Isolate, schedule, deliver, and recover long-running agent work safely.
group: Supervise
order: 55
---

# Managed work and recovery

Long-running agent work should survive interruptions without gaining hidden
authority. Managed workspaces, scheduled messages, curfews, automations, and
recovery policies each state what they will do before they do it.

## Managed workspaces

A managed workspace is an opt-in, session-owned Git worktree. The agent works
in the detached checkout while your source checkout stays untouched. The app
only offers this mode when the session has the tools required to complete its
delivery contract.

When the task finishes, you can:

- merge the result with a strict fast-forward check and clean up the worktree;
- keep the workspace for local review; or
- open a GitHub pull request or GitLab.com merge request, if you enabled
  that for the repository.

If validation or delivery cannot complete safely, the app refuses the finish,
keeps the workspace, and marks the session **Needs you**. The work stays in
the workspace.

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

## Curfews

A curfew is a scheduled end for a session. Set it when you write the session
or later from the row's menu: a time, the next 5-hour or 7-day window reset, or
a usage percentage from 1 to 100 for the account's window. At the curfew,
Threading holds the session and stops spending its usage. A percentage curfew
stays held across resets and restarts until you choose **Lift Curfew**.

## Automations

**Automations** in the sidebar runs a saved task on a schedule (daily,
selected weekdays, weekly, or an interval) or when a connected source reports
an event. A new automation starts paused, and only you can activate it. Tasks
can be read-only or allowed local edits and tests in a clean checkout or an
isolated worktree. No automation can push, deploy, or write back to its
source. A schedule never replays a backlog: choose **Skip missed runs** or
**Run once on return** for time the Mac was asleep or offline. Agents can draft
and manage automations through a tool, but enabling or running one always
shows you the exact settings first.

## Limits and startup recovery

When Claude Code refuses a turn over a usage limit, the app reads the refusal
from the transcript and marks the row with a red triangle and the reset time.
You can opt into **Continue at Reset**, which waits for the reset and sends a
continuation. The app never upgrades a plan, spends money, or switches
accounts on its own.

After a normal quit, configured sessions can restore normally. After an
unclean exit, the app holds automatic work until the previous state has been
inspected. Repeated startup failures enter Recovery Mode, which starts without
sessions, extensions, remote access, or other automatic work. From there you
can inspect the workspace and make a deliberate one-shot attempt to return to
normal startup.
