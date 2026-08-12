---
title: Getting started
description: Go from installed provider CLIs to a supervised project.
group: Start
order: 20
---

# Getting started

The app uses the coding-agent command-line tools already installed on your
Mac. Install and sign in to at least one supported provider before creating
your first project.

## 1. Verify a provider CLI

Open a terminal and verify the tools you intend to use:

```sh
claude --version
codex --version
grok --version
opencode --version
```

Authentication remains with the provider CLI. If a command asks you to sign
in, complete that flow before returning to the app. You only need one
supported provider to begin, and the available native controls can differ by
runtime.

## 2. Open a project folder

Choose the local folder that contains the code or documents you want an agent
to work on. A project brings together:

- conversations and their current attention state;
- working directories and worktrees;
- terminals for direct process access;
- Git status, diffs, staging, and review;
- account and provider choices relevant to new sessions.

Opening a project does not upload or copy it. The folder remains the source of
truth on disk.

## 3. Start a session

Create a session, choose a provider, and describe a concrete task. The session
appears immediately in the project sidebar and moves through a small set of
states as the agent works.

You can keep several sessions active at once. The sidebar is designed to make
quiet progress recede and bring questions, permissions, and completed work
forward.

## 4. Respond where the request happened

Questions and permission requests appear in the conversation that caused
them. Review the proposed action and its scope, then approve, decline, or
answer without searching for the correct terminal window.

## 5. Review the result

When work reaches a reviewable boundary, open Git review from the same
project. Choose the comparison that matches your intent: unstaged, staged,
last turn, branch, or commit. Then inspect and stage only the work you want.

## Next

Read [Sessions and attention](sessions-and-attention.md) for the status model,
or [Git review](git-review.md) for the change-review workflow.
