# Linked Workrooms: structured questions to domain experts over a public link

> Draft, 2026-10-17. **Phase 1 implemented 2026-10-17**; its durable decisions are in
> [`docs/architecture/linked-workrooms.md`](../architecture/linked-workrooms.md). What remains
> here is the pilot and the later phases. Product direction: [Linked Workrooms](linked-workrooms.md).

## Pilot (Sonda)

- Settings ▸ Workrooms: switch Workrooms on and choose ngrok with a reserved domain. Add the
  expert, with Swedish as their language.
- When the owner asks, an agent in the Sonda checkout creates a room for a ticket sweep, linking
  its Jira issues. It asks the sweep's open decisions as structured questions, and asks for a
  confirmation of each implemented ticket in domain terms.
- The owner approves the opening, copies the person's link from Settings and sends it.
- Check on the real tunnel: a form post arrives with `Content-Length`, which `Host` the provider
  forwards, and the Swedish pages in iPhone Safari.

## Later phases

- **Phase 2:**
  - Tailscale Funnel: stable, free, and TLS ends on the Mac (reuse `TailscaleServeTransport.swift`).
  - A Threading-held ngrok token in the Keychain, for a Mac without an ngrok configuration. It
    must reach the child only through a 0600 file, never argv or the environment.
  - Keep the Mac awake while a room is open.
  - Notify the owner when an answer arrives.
  - Block the agent browser from the portal host.
  - An optional owner review before each question goes out.
  - Removing a person from Settings, and approvals on the iPhone.
  - A registered command for Close All Workrooms.
- **Phase 3:**
  - Questions from controller executions (`agent-mcp workroom_ask`, which also creates a
    `WorkQuestion` so the existing requeue stays the only scheduler).
  - Remote-host sessions.
  - Person mail between hosts once every peer is on v12.
  - Jira links shown in the portal, and reviewed publication of a decision summary to Jira.
- **Phase 4, only if measured as needed:** a `threading-workroomd` helper, or a portal hosted on
  Linux with a real domain.
