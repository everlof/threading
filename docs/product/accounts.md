---
title: Accounts
description: Use multiple provider identities without moving credential ownership.
group: Connect
order: 60
---

# Accounts

The app can make multiple Claude Code and Codex logins available when
starting work. Credentials remain owned and stored by the corresponding
provider CLI. Grok, Cursor, and OpenCode sessions are supported too, with one
login each: Grok signs in inside its terminal UI, Cursor uses the Mac login
from `agent login`, and OpenCode keeps provider accounts inside OpenCode
through `/connect`.

## Provider-owned authentication

The installed command-line tool signs in, refreshes credentials, and enforces
provider policy. The app launches the provider with the selected local account
and never turns those credentials into a separate cloud account. **Add Login**
in **Settings ▸ Agents & Accounts** starts the provider's own browser flow for
a new Claude Code or Codex login. A Claude login can also use a one-year token
from `claude setup-token` instead of the monthly browser sign-in.

## Why keep more than one account

Multiple identities are useful when you separate:

- personal and work projects;
- organizations with different policy or billing;
- provider plans with independent usage limits;
- test identities from day-to-day work.

Give accounts labels that describe their purpose, such as "Work" or "Spare",
so the session picker shows them instead of an opaque identifier.

## Availability and limits

For Claude Code and Codex, the app shows each login's usage windows in the
session header and in the account picker before a new session starts. Grok,
Cursor, and OpenCode report no usage windows. Treat these readings as
guidance, and check provider billing and account pages for the final word.

**Settings ▸ Usage** adds a local dashboard over 7, 30, or 90 days: cost and
token totals by provider, project, account, and model, read from local
transcripts, plus each account's limit history. Costs the provider does not
report are estimated from a versioned model price list and marked as
estimates. On iPhone, the companion app has a Usage sheet.

## Project choice versus account choice

A project is a local folder and review context. An account is the provider
identity used by a session. Changing one does not automatically change the
other, and existing sessions keep the provider context with which they were
started.

A project can name default accounts for its new chats, in order. A new chat
starts on the first account in the list that has usage left, and the list may
mix agents. You can also move an existing conversation to another login of
the same agent.
