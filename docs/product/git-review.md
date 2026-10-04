---
title: Git review
description: Inspect, stage, and commit agent changes at the right boundary.
group: Supervise
order: 50
---

# Git review

Git Review (Cmd+Shift+R) opens a native diff of the session's checkout in the
display panel beside the conversation. Choose the comparison first, then read
the diff.

## Choose a comparison

Different questions require different boundaries:

- **Uncommitted**, the default, combines staged, unstaged, and untracked work.
- **Unstaged** shows working-tree changes not yet added to the index.
- **Staged** shows what the next commit would contain.
- **Last turn** shows what changed since the agent most recently started
  working. If another chat worked in the same folder during that turn, each
  file says which chat claimed it.
- **Branch** compares the current branch with the repository's default branch.
- **Commits** lists history with a branch graph; select a commit to read its
  diff.

The exact options available depend on repository state.

## Review text and images

Text changes use a syntax-highlighted diff with file navigation and
line-level context. Cmd+J filters the changed files by path. A changed PNG,
JPEG, GIF, WebP, HEIC, TIFF, BMP, or ICNS file opens as a visual comparison
with wipe, fade, difference, and side-by-side modes.

Use the file list to see the shape of a large or generated change before
reading individual hunks. To discuss a line with the agent, press the **+**
beside it to add the line to the chat or comment on it.

## Stage deliberately

Staging is a review decision. Select the coherent work you intend to include
and leave unrelated edits in the working tree. You can stage a file or a
single hunk, and commit from the same pane. Git Review offers no discard
button, so nothing it does throws away an agent's change.

The app never assumes that every dirty file belongs to the active agent. A
project may contain human edits, another session’s work, or generated
artifacts at the same time.

## Commit at a coherent boundary

Before committing:

1. confirm the selected comparison;
2. run the relevant validation;
3. read the staged diff;
4. write a message that describes the outcome.

The conversation explains how the work unfolded, and the commit records the
durable repository change.

## Pull and merge requests

For a checkout whose `origin` is on GitHub.com or GitLab.com, Git Review shows
the current branch's pull or merge request, its review state, and its checks.
The main button takes one explicit step at a time: push the branch, create the
request, push a newer head, or open the existing request. By default, creating
a request opens an editable title and description first. Codex can draft that
text, and only your press of **Publish** submits it. GitLab needs the official
`glab` CLI signed in to GitLab.com. Self-hosted GitLab is not supported yet.

