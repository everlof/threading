---
title: Remote companion
description: Pair an iPhone or browser with a deliberately shared conversation.
group: Connect
order: 70
---

# Remote companion

Remote companion access lets you follow or guide selected agent work away
from the Mac. It is optional and does not change the local-first desktop
workflow.

## Pair explicitly

A remote device begins with a one-time pairing flow initiated from the desktop app. The Mac and
native device keep the exchanged, device-bound owner credential in Keychain, so the relationship
survives restarts until the owner explicitly revokes that named device. Owner pairing exposes the
remote-manageable sessions on that Mac; it is intentionally stronger than sharing one
conversation with another person.

The connection is separately selectable: Relay for ordinary share links, Tailscale for a private
tailnet, or Private + Sharing for private owner pairing with an on-demand public relay. The owner
can separately allow relay fallback for paired devices or keep that relay warm; both controls are
off by default. A paired Mac is one logical device with policy-approved endpoints, so switching
between its private and relay route does not add a second Mac to the device picker.

One iPhone can pair with several Macs. The dashboard shows the active Mac once, offers the other
paired Macs as direct switch targets, and keeps each Mac's session list separate. The last active
Mac and open session are restored on launch. Tailscale and relay remain routes to the same saved
host identity, so a failover never moves a draft to another Mac or creates a duplicate device.

## Share a conversation

Choose the conversation you want to make available and grant an appropriate
role:

- **View** can follow the shared conversation.
- **Collaborate** can participate in the conversation.
- **Approve** can also respond to eligible permission requests.

Use the narrowest role that supports the intended collaboration.

## Revoke access

You can stop sharing a conversation, revoke a paired device, or disable remote access. Disabling
closes the listener and suspends paired devices without forgetting them; revocation removes the
device credential. Revocation should be treated as a normal control, not an emergency-only
feature.

## What remote access is not

Remote companion is not general remote desktop access and it is not an
automatic mirror of the whole Mac. The share boundary is the selected
conversation and the capabilities allowed by its role.

## iPhone and browser

The mobile and browser interfaces prioritize attention, conversation, and
decisions over full desktop parity. Detailed local workflows such as broad
repository navigation remain better suited to the Mac.

Experimental native conversations also carry their live command and skill catalog to the iPhone. Type `/` or
`$` to filter it, or use the composer’s plus button to browse everything the current Claude or
Codex session exposes. Choosing `/skills` narrows the list to skills. The Mac remains
authoritative when an action is submitted; skill instructions and local filesystem paths stay on
the Mac and are not included in the remote catalog.

Several devices may open the same session at once. On iPhone, presence describes other people:
your own devices stay hidden, and a collaborator's devices count as one person shown by name.
Solo use has no presence row. Viewing and typing state never act as a lock. Each Native composer
keeps its own draft. On iPhone, an agent-UI terminal does the same by default:
the device submits a completed line as one atomic PTY write, so another controller cannot splice
keystrokes into it. Collaboration settings can hide the roster or typing indicators independently
and can restore direct terminal typing for workflows that need raw character-by-character input.

Acknowledged submissions keep the draft visible until the Mac accepts it. A request id makes a
lost WebSocket result retryable within a bounded five-minute replay window without creating a
second turn; a conflicting, busy, rejected, or unavailable result leaves the draft intact.

Input authority is separately switchable per live session. **Collaborative** keeps all
interactive participants able to submit. **Focused** selects one controlling person while every
other device remains a watcher with an editable local draft. This is not a startup-only mode:
the owner can change it in the Mac Sharing pane or on a paired companion, the controller can hand
off, and the owner can always reclaim. The Remote Access setting only chooses the default for a
new shared session.

The Mac is the authority for every write surface: Native prompt, atomic terminal line, raw PTY
input, paste/drop, mouse reporting and local keyboard entry. The client-side disabled state is not
the authority.
The identity is a participant rather than a socket, so reconnecting through another advertised
Tailscale/relay endpoint or opening a second device does not accidentally acquire a second turn.
A guest's last disconnect starts a 30-second grace period before control returns to the owner;
revocation returns it immediately. In Focused mode terminal viewport leases are limited to the
controller's devices so watchers cannot reflow the active TUI.

**Request control** reuses the existing targeted human-attention event. It does not write to the
agent, and only the current controller is targeted; their **Requests for my input** preference
continues to govern push delivery. Handoffs and mode changes are visible live but deliberately do
not add another notification switch. A client that does not understand the new control frame
still cannot bypass the Mac's write gate; upgrading is required to expose the handoff UI.

Human attention is deliberately not another composer grammar. A separate **@** control lets a
collaborator ask one accepted chat member, including somebody currently away, for input and attach
a short optional note. The request is app-owned metadata: it sends neither a Claude or Codex
prompt nor terminal bytes. Open clients show a quiet collaboration event, while the selected
person can receive a push notification controlled by the independent **Requests for my input**
setting. Repeated requests to the same person are briefly collapsed; the feature does not create
assignments, claims, or a second task workflow.

Provider-neutral session activity can also notify when a chat changes into waiting for the
user's response. That event is distinct from a structured permission request and from a person
using **@**; it does not parse terminal text. The companion keeps all five notification categories
independent and offers both a master sound switch and per-category sound switches.

Working state is private to each client and scoped to the exact host and session. macOS, iPhone,
and the browser save unsent Native drafts immediately; iPhone and browser do the same for their
independent terminal composers. Conversation and terminal reading positions are saved at a
coalesced rate, and iPhone/browser restore the last open route. Returning to a session therefore
continues where that device stopped without copying a half-written message to another person's
composer. Draft-bearing records are not aged out automatically; disposable position-only history
is bounded.

Accepted one-chat memberships and unexpired invitations are durable on the Mac as well. Turning
Remote Access off, changing routes, or restarting Threading suspends them and disconnects live
sockets but does not silently make collaborators rejoin. **Stop Sharing** or an explicit member
revocation is the destructive boundary.
