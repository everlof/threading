---
title: Git review
description: Inspect, stage, and commit agent changes at the right boundary.
group: Supervise
order: 50
---

# Git review

Git review connects an agent conversation to the repository changes it
produced. It is designed for choosing the right comparison first, then reading
the diff.

## Choose a comparison

Different questions require different boundaries:

- **Unstaged** shows working-tree changes not yet added to the index.
- **Staged** shows what the next commit would contain.
- **All uncommitted** combines staged and unstaged work.
- **Last turn** narrows review to the files associated with recent agent work.
- **Branch** compares the current branch with its base.
- **Commit** inspects a specific committed change.

The exact options available depend on repository state.

## Review text and images

Text changes use a structured diff with file navigation and line-level
context. Image changes use a visual comparison rather than presenting binary
file metadata as if it were useful review.

Generated files and large changes may need a different review strategy from
handwritten source. Use the file list to understand the shape of the change
before reading individual hunks.

## Stage deliberately

Staging is a review decision, not a cleanup step. Select the coherent work you
intend to include and leave unrelated edits in the working tree.

The app never assumes that every dirty file belongs to the active agent. A
project may contain human edits, another session’s work, or generated
artifacts at the same time.

## Commit at a coherent boundary

Before committing:

1. confirm the selected comparison;
2. run the relevant validation;
3. read the staged diff;
4. write a message that describes the outcome, not the activity.

Provider conversations and Git history answer different questions. The
conversation explains how the work unfolded; the commit records the durable
repository change.

