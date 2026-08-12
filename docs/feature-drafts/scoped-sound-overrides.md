# Scoped sound overrides

> Status: **shipped** (August 2026). This draft was implemented in full — the `SoundChoice`
> collapse and checkbox migration, per-event bell/alert routing with bell-cause classification,
> the global silence gate (sidebar footer, Settings, ⇧⌘S), per-chat/project/terminal overrides
> with the three-level resolution chain, the one-click Sounds submenu, the Customize sheet and
> the Custom sounds audit section.
>
> The durable decisions live in
> [`session-activity.md`](../architecture/session-activity.md) — the resolution chain and its
> per-event terminus, the voiced/opt-in rule, the classification order and the
> `bell.otherProgram` gating, `SoundOwner` and the `homeProject` decision, the nil-means-follow
> writers, the sheet's `SoundScope` seam and its Reset-All contract, and the silence gate's
> gate-not-scope design. One deferred item — the session row's own override affordance — is
> recorded in `IMPROVEMENTS.md`. This pointer replaces the draft per this directory's rule.
