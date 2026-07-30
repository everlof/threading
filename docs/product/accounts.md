---
title: Accounts
description: Use multiple provider identities without moving credential ownership.
group: Connect
order: 60
---

# Accounts

The app can make multiple Claude Code and Codex identities available when
starting work. Credentials remain owned and stored by the corresponding
provider CLI.

## Provider-owned authentication

Signing in, refreshing credentials, and enforcing provider policy remain the
responsibility of the installed command-line tool. The app launches the
provider with the selected local account context; it does not turn those
credentials into a separate cloud account.

## Why keep more than one account

Multiple identities are useful when you separate:

- personal and work projects;
- organizations with different policy or billing;
- provider plans with independent usage limits;
- test identities from day-to-day work.

Give accounts labels that describe their purpose. A clear label is more useful
in the session picker than an opaque identifier.

## Availability and limits

Where the provider exposes enough information, the app can show account
availability or rate-limit state before a new session starts. Provider
reporting is not always identical, so treat these indicators as guidance
rather than a replacement for provider billing and account pages.

## Project choice versus account choice

A project is a local folder and review context. An account is the provider
identity used by a session. Changing one does not automatically change the
other, and existing sessions keep the provider context with which they were
started.

