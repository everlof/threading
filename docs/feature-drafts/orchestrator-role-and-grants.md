# Orchestrating agents: the manager role, grants and supervision

> Status: **shipped** (2026-08-17). The explicit `ControlOperation` × `ControlGrant`
> authority model, project-scoped Manager role, grant-derived MCP catalogue and live
> `tools/list_changed`, targeted lifecycle operations, account/usage reads, guarded spawn,
> resume, move and managed-workspace finish, durable supervision/event records, bounded child
> subscriptions, and the complete Manager UI all shipped together.
>
> The durable decisions now live in
> [`control-plane.md`](../architecture/control-plane.md) — authority, refusals, catalogue exposure,
> bounds and supervision; [`accounts.md`](../architecture/accounts.md) — fresh readings,
> `"best"`, own-limit holds, moves and ceilings; [`sessions.md`](../architecture/sessions.md) —
> role/session separation, supervision lineage and user-visible attribution; and
> [`persistence.md`](../architecture/persistence.md) — schema-v4 grant, supervision and event
> ownership. User-facing operation is documented in the [User Guide](../../USER_GUIDE.md#manager-sessions).
> This pointer replaces the draft per this directory's rule.

The intentionally unshipped boundaries remain explicit in those records: no agent may confer or
widen authority; no Manager template implies cross-project reach; working children cannot be
archived or moved; dormant terminals cannot be resumed unattended; and structured provenance for
cross-session message bodies remains a later control-plane slice.
