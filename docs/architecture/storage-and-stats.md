# Reclaimable Storage and Code Stats

What a project can rebuild, and what it is made of.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

`ArtifactScanner` finds build output a project can rebuild, and the Storage settings page
removes it. On the machine it was built for: **87.61 GB across 45 directories**, and 58 GB of
that in git worktrees rather than the checkouts anyone opens — abandoned branches each holding
a full `target/` and their own copy of `node_modules`.

**Two gates decide, and neither alone is enough.** A path is offered only when git considers it
disposable *and* its directory name plus an ecosystem marker identify it as known build output.

- Ignore status alone is the tempting rule, and it deletes your secrets: measured here,
  `git check-ignore` also says yes to `.env.local`, `.env.jira` and
  `ansible/runner-controller-secrets.yml`. It is *necessary* (the project does not keep this),
  never *sufficient*.
- The marker is not decoration either. `target`, `build` and `dist` are ordinary words; a
  `target` beside no `Cargo.toml` is somebody's data.
- **`check-ignore` answers about patterns, not tracking.** A committed directory matched by
  `.gitignore` still reports as ignored, because git's rule is that tracked files are unaffected
  by the ignore list. `ls-files` is therefore asked as well, and anything tracked inside refuses
  the whole directory. A test found this while being written, not a user.

Both gates are re-checked immediately before a delete: a listing being read is a listing going
stale. Removal is **immediate rather than to the Trash**, which for once is the safer-feeling
option that helps nobody — 30 GB in the Trash has not been reclaimed.

**Sizes count each inode once, the way `du` does.** Build directories are full of hard links —
one real Cargo `target/` held 37,810 files sharing 25,021 inodes — and summing per-file sizes
claimed 42.79 GB where the directory occupies 33.18 GiB, a 29% overstatement of the single
number the feature exists to report. The identifier is only fetched when `linkCount > 1`, so an
ordinary file costs nothing extra.

**Findings are cached and the scan is passive.** `ArtifactScanService` keeps the results in
Application Support and refreshes them on a `.background` queue — the QoS whose I/O the system
throttles, which is right for a chore nobody is waiting on. Finding 45 directories means walking
every *other* directory in four projects first, a little over a minute here, so a page that
scanned on open would be empty every time it opened. It draws the cache instead and asks for
anything stale to be re-measured. A passive pass skips a project whose sessions are **working**:
an agent mid-build is both the worst moment to compete for the disk and the worst moment to
measure a directory it is still writing. A cached number is shown with its age, because one that
does not say when it was taken is claiming to be live.

**Agents can see the listing and propose a cleanup, never perform one.** `list_reclaimable_storage`
returns the cache; `propose_storage_cleanup` puts named paths to the user as a sheet and removes
only what they approve. The gate that keeps this from being an arbitrary-delete primitive is that
**a proposal can only name paths already in the findings** — everything there has passed both of
the scanner's gates, and they are checked again at the moment of deletion. The tool answers only
once the user has decided, so the agent's next turn knows the outcome rather than assuming it.

**The instruction keys on the failure, not on a measurement.** An earlier version stated the disk's
free space in the `initialize` instructions, so an agent would know it was short. Wrong twice: the
reading is a snapshot taken at session start, while a session that fills the disk does so an hour
later — and an agent that runs out of room learns it from the write that failed, which is a better
signal than any advance warning. What it lacks at that moment is not the fact but the tool, which
is static. So the group's instruction triggers on the symptom ("No space left on device", ENOSPC,
a build dying partway) and tells it to look before reporting failure. `DiskSpace` survives for the
Storage page, where free space is the context that turns "87 GB reclaimable" into a decision.

The page groups **by checkout, not by project**, because six of one project's checkouts hold a
`web/node_modules` and a row reading `web/node_modules` under a heading reading `sonda` names
none of them. Each heading is `<project> · <worktree or branch> · <size>`; rows are relative to
their checkout. Rows state the rebuild command and the age, and a directory written in the last
fifteen minutes reads as **in use** — the first real scan found the largest directory on the
page had been written two minutes earlier, in a worktree with no Threading session to warn about.
That is the second of two independent in-flight checks, the other being a running session in
the project.

A row's size and its Remove are one control, `SettingsUI.controlGroup`, because a hand-rolled
stack of the two floated in the middle of the card in the real scrolling page while looking right
in every fixture. See the 2026-08-12 entry in
[`design-system.md`](design-system.md); the sizes read as a column only because that group is
flush to the trailing inset.

## Code Stats

Hovering a project row opens a popover of the project's code composition — total code lines
and files, a language bar, a legend — counted by **scc**, which is a tool the user installed
rather than a dependency: `CodeStatsRunner.locate` probes the known install paths and then
the login shell (taking the last non-empty line, since a login shell is free to print a
greeting before the answer). Runs pass `--no-min-gen` so vendored bundles do not dominate
a bar about what was *written* here, and scc honours `.gitignore` on its own, which is what
keeps `node_modules` out and the count honest.

A machine **known** to have no scc gets the install hint in the popover's place — a feature
whose only trace is a popover that never appears cannot be discovered, and the hover is the
moment the user is already asking the question the hint answers. Three rules keep it honest:
a project merely not counted *yet* still shows nothing ("not looked" is not "not
installed"); the miss is cached with a timestamp and re-probed once it ages past
`missingReprobeAfter`, so `brew install scc` starts counting within a minute with no
relaunch and no button; and only the first miss is logged, not the re-probes repeating it.

`CodeStatsService` is `ArtifactScanService`'s shape with the economics inverted: scc answers
a repository in tens of milliseconds (measured: 18ms for this repo's ~90k lines), so the
cache exists for the first glance after launch and for scc-less machines, not to amortise a
walk. The freshest trigger is the stopped-working edge — the same
`sessionStateDidChange` moment that re-reads the branch — because a session that just stopped
working is a project whose code most likely just changed. A hover also recounts, guarded by
`hoverRefreshAfter` so crossing rows does not launch a process per project; kicked at
*entry* rather than at the dwell, the count is usually fresh again before the popover opens.

`CodeStatsBar` holds the arithmetic apart from the drawing (the `ConversationMinimap` split):
which languages become segments, what folds into "Other", and segment widths. Two rules are
pinned by tests: **the fold never stands for one language** — with exactly one language past
the cap, "Other" would be a name withheld for nothing, so `maximumSegments` is one fewer than
`Design.Categorical.ramp` and the un-folded case colours it with the ramp's last hue — and
**every segment draws visibly** (a floor of `minimumSegmentWidth`, paid for proportionally),
because a 99%-one-language repository still has to show the others it names. Colours are the
categorical ramp: languages are things told apart, not things with a meaning each; the fold
draws in the quaternary text tone, visibly not a language of its own.

The popover is `SessionRowView`'s dwell-timer popover on `ProjectRowView`, at the session
popover's width on purpose — the two hang off neighbouring rows. `CodeStatsRenderTests`
draws it to PNGs both ways, which is what caught the legend packing its values beside the
names instead of into a column at the trailing edge.
