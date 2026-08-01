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
tailnet, or Both for private owner pairing alongside public one-chat sharing.

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
