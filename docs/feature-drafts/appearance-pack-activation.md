# Theme commands and pack activation

> Status: **superseded**, 2026-10-05. The theme commands shipped and remain; pack activation
> shipped on 2026-10-04 and was retired the next day. See the
> [appearance packs decision record](../decisions/appearance-packs.md). A pointer remains so links
> resolve.

This draft specified palette commands for themes and packs, one durable activation state, and the
ownership rules that let a pack's extensions be switched with its theme.

- **What shipped and stays**, recorded in
  [`appearance-activation.md`](../architecture/appearance-activation.md): one host selection
  operation shared by Settings, MCP, shortcuts and the iPhone; stable **Use … Theme**,
  **Use … Terminal Theme…** and **Enable/Disable … Extension** commands; installed themes that
  outlive runtime disable; the asynchronous commit, migration and recovery of the durable record.
- **What was retired**: pack recipes and the active pack, the manual/pack ownership union, digest
  receipts checked before a pack-owned start, and every pack command and surface.

The full proposal, including the state-transition table and acceptance list, is in the history at
`fb61307ca:docs/feature-drafts/appearance-pack-activation.md`.
