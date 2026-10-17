# A tunnel for the Linked Workrooms participant portal

> Status: **decision record** (2026-10-17). **Accept, narrowly.** A third-party tunnel may publish
> exactly one origin: the Linked Workrooms participant portal, while at least one room is open to a
> named person. It never carries the owner's own traffic, MCP, Remote Access or anything else.
> Implemented in [`linked-workrooms.md`](../architecture/linked-workrooms.md).

Part of the [decisions index](README.md). Read beside
[`named-cloudflare-tunnel.md`](named-cloudflare-tunnel.md), which rejected a tunnel for the owner's
phone, and the "Relay is gone" line in [`REMOTE_ACCESS.md`](../REMOTE_ACCESS.md).

## 1. The problem

A domain expert answering an agent's questions is not on the owner's tailnet, is not paired, and
has no Threading. They have a browser and a link the owner sent them. Something on the public
internet has to forward their request to the Mac that holds the questions.

## 2. Why the earlier rejections do not decide this one

The named-tunnel record rejected a third party terminating TLS **on the owner's daily route**, to
buy an address stability a sticky port already buys. Here:

- **The traffic is not the owner's.** The portal serves only the participant routes
  (`WorkroomPortal.routes`, pinned by a test): a person's own questions, their answers and their
  language. No session, file, terminal or credential of the owner passes through it.
- **There is no first-party alternative for an outsider.** A sticky port on the Mac's interface
  reaches the LAN and the tailnet; an expert is on neither.
- **It is temporary and scoped.** The tunnel runs only while a room is open to a named person,
  every opening is an approval that states the provider can read the traffic, each room expires,
  and Close All Workrooms ends it at once.

## 3. Providers

- **ngrok, with the user's own account (default).** A reserved domain keeps sent links working
  across restarts. The agent's local API is switched off by an overlay configuration so no other
  process of the user can open more tunnels on the account.
- **Cloudflare Quick Tunnel.** No account, but the address changes on every start, which breaks
  every link already sent — the exact failure that ended Relay. Offered for trying, and labelled
  so.
- **Tailscale Funnel (later).** Free, a stable `*.ts.net` name, and TLS terminates on the Mac
  itself, which removes the third-party reader entirely. The best long-term default; not built in
  the first slice.

## 4. What would reopen this

- Evidence that participants need to answer while the Mac sleeps or the app is quit — then the
  portal moves to a hosted controller with a real domain, and no tunnel is involved.
- Funnel shipping as a provider — then it should become the default and Quick Tunnels may be
  removed.
- Any proposal to put an owner route behind the same origin. That is the case the named-tunnel
  record rejected, and it stays rejected.
