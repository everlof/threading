---
title: Remote companion
description: Pair an iPhone or browser with a deliberately shared conversation.
group: Connect
order: 70
---

# Remote companion

Remote companion access lets you follow or guide agent work away from the Mac,
from the Threading iPhone app or a browser. It is a beta, off by default, and
the desktop app works the same without it. Turn it on in **Settings ▸ Remote
Access**.

## Pair explicitly

A remote device begins with a one-time pairing flow: scan the QR code that the
Mac shows. The phone pins the Mac's certificate, and both sides keep a
device-bound owner credential in Keychain, so the pairing survives restarts
until you revoke that named device. A paired owner device can see and manage
your unarchived chats and approve permission requests, which is more than
sharing one conversation with another person gives.

Each way in has its own switch in Remote Access settings:

- **This network** (on once Remote Access is on): the phone reaches the Mac
  over the same Wi-Fi, or over a VPN into that network.
- **Tailscale** (off by default): reach the Mac from anywhere on your tailnet.
  An optional sub-setting publishes it through Tailscale Serve for browsers on
  the tailnet.
- **Threading Direct**: **Enable Hosted Access** lets paired iPhones connect
  across networks without a VPN. It needs no Threading or Apple account.

Every way in works only while the Mac is awake. **Keep this Mac awake** can
hold it awake while plugged in, or always. A paired Mac is one device with
several addresses, so switching routes never adds a second Mac to the device
list.

One iPhone can pair with several Macs. The dashboard shows the active Mac once, offers the other
paired Macs as direct switch targets, and keeps each Mac's session list separate. The last active
Mac and open session are restored on launch. Every route leads to the same saved host identity,
so a failover never moves a draft to another Mac or creates a duplicate device.

## Share a conversation

To involve someone else, choose **… ▸ Share Chat…** on a session and pick a
role:

- **View** can follow the shared conversation.
- **Collaborate** can also type and send prompts.

**Allow approving agent requests** separately lets that person answer the
chat's permission requests. **Copy Link** copies one HTTPS invitation that
opens the Threading iPhone app or a web page, so a guest needs no account or
app. An invitation works once and expires after 24 hours if unused. Use the
narrowest role that fits. A standalone terminal can be shared the same way,
as **View only** or **Full control**.

## Revoke access

You can stop sharing a conversation, revoke a paired device, or disable remote access. Disabling
closes the listener and suspends paired devices without forgetting them. Revocation removes the
device credential, and you can use it any time a device should no longer have access.

## Scope

Remote companion gives no remote desktop access and mirrors nothing outside
Threading. A paired owner device reaches your Threading chats and standalone
terminals. A shared guest reaches only the one conversation or terminal you
shared, with the capabilities its role allows.

## iPhone and browser

The mobile and browser interfaces put attention, conversation, and decisions
first. On iPhone you can read and answer chats, use the provider TUI, answer
permission requests, check changed files in Git Review, start a chat, search
across projects and transcripts, and see account usage. Broad repository
navigation stays on the Mac.

Experimental native conversations also carry their live command and skill catalog to the iPhone. Type `/` or
`$` to filter it, or use the composer’s plus button to browse everything the current Claude or
Codex session exposes. Choosing `/skills` narrows the list to skills. The Mac remains
authoritative when an action is submitted; skill instructions and local filesystem paths stay on
the Mac and are not included in the remote catalog.

Several devices may open the same session at once. On iPhone, presence describes other people:
your own devices stay hidden, and a collaborator's devices count as one person shown by name.
Solo use has no presence row. Viewing and typing never lock the session. Each Native composer
keeps its own draft. On iPhone, an agent-UI terminal does the same by default:
the device submits a completed line as one atomic PTY write, so another controller cannot splice
keystrokes into it. Collaboration settings can hide the roster or typing indicators independently
and can restore direct terminal typing for workflows that need raw character-by-character input.

Acknowledged submissions keep the draft visible until the Mac accepts it. A request id makes a
lost WebSocket result retryable within a bounded five-minute replay window without creating a
second turn; a conflicting, busy, rejected, or unavailable result leaves the draft intact.

Input authority is separately switchable per live session. **Collaborative** keeps all
interactive participants able to submit. **Focused** selects one controlling person while every
other device remains a watcher with an editable local draft. The owner can change the mode at any
time in the Mac Sharing pane or on a paired companion, the controller can hand off, and the owner
can always reclaim control. The Remote Access setting only chooses the default for a new shared
session.

The Mac decides every write: Native prompt, atomic terminal line, raw PTY input, paste/drop,
mouse reporting and local keyboard entry. A client that shows a control as disabled is only
reflecting that decision.
The identity is a participant, not a socket, so reconnecting through another advertised
address or opening a second device does not acquire a second turn.
A guest's last disconnect starts a 30-second grace period before control returns to the owner;
revocation returns it immediately. In Focused mode terminal viewport leases are limited to the
controller's devices so watchers cannot reflow the active TUI.

**Request control** reuses the existing targeted human-attention event. It does not write to the
agent, and only the current controller is targeted; their **Requests for my input** preference
continues to govern push delivery. Handoffs and mode changes are visible live and have no
notification switch of their own. An older client that does not understand the control frame
still cannot bypass the Mac's write gate; it needs an upgrade to show the handoff UI.

A separate **@** control, outside the composer, lets a
collaborator ask one accepted chat member, including somebody currently away, for input and attach
a short optional note. The request is app-owned metadata: it sends neither a Claude or Codex
prompt nor terminal bytes. Open clients show a quiet collaboration event, while the selected
person can receive a push notification controlled by the independent **Requests for my input**
setting. Repeated requests to the same person are briefly collapsed. The feature creates no
assignments, claims, or task workflow.

Provider-neutral session activity can also notify when a chat changes into waiting for the
user's response. That event is distinct from a structured permission request and from a person
using **@**; it does not parse terminal text. The companion keeps each notification category
independent and offers both a master sound switch and per-category sound switches.

Working state is private to each client and scoped to the exact host and session. macOS, iPhone,
and the browser save unsent Native drafts immediately; iPhone and browser do the same for their
independent terminal composers. Conversation and terminal reading positions are saved at a
coalesced rate, and iPhone/browser restore the last open route. Returning to a session continues
where that device stopped, and a half-written message never reaches another person's composer. Draft-bearing records are not aged out automatically; disposable position-only history
is bounded.

Accepted one-chat memberships and unexpired invitations are durable on the Mac as well. Turning
Remote Access off, changing routes, or restarting Threading suspends them and disconnects live
sockets, and collaborators do not have to rejoin afterwards. Only **Stop Sharing** or revoking a
member removes access.
