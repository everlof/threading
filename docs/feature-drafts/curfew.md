# Curfew: a scheduled end for a session

> Status: **shipped** (August 2026). The slice was implemented in full — the deadline model and
> receipts, quiet hours and the three-scope resolution, the hold at every seam, the wind-down
> message, the `SessionCurfewCenter` ladder with bounded interrupts and the opt-in stop-agent
> escalation, the strip/row/chip/fold/draft-view surfaces and the Settings section.
>
> The durable decisions live in [`docs/architecture/curfew.md`](../architecture/curfew.md),
> which also lists what was measured, what is still owed (the Escape keystroke against the
> installed CLIs), and the recorded follow-ups: `CustomLimitTier.enforce`, the in-band
> `UserPromptSubmit` enforcement hook, iPhone mirroring, and per-session ceilings (which stay
> with [`usage-aware-accounts.md`](usage-aware-accounts.md) § C).
