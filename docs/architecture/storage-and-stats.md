# Reclaimable Storage and Project Stats

What can be rebuilt, and what a project is made of.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

`ArtifactScanner` finds build output a documented command can rebuild — inside a project, and in
the temporary locations agents build in — and the Storage settings page removes it. On the
machine it was built for: **87.61 GB across 45 directories**, and 58 GB of that in git worktrees
rather than the checkouts anyone opens — abandoned branches each holding a full `target/` and
their own copy of `node_modules`.

**Two gates decide, and neither alone is enough.** Inside a project, a path is offered only when
git considers it disposable *and* its directory name plus an ecosystem marker identify it as
known build output.

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

**Outside a project the necessary gate is replaced, never dropped.** Agents build in the scratch
locations too: measured on 2026-08-13 with 31 GiB free, `/private/tmp/claude-501` held **76 GB
across 170 session directories**, and **38.6 GiB of Xcode DerivedData sat in 24 trees** under
`/private/tmp` and `$TMPDIR`, 13.4 GiB of it in 8 whose workspace was already deleted. The project
scanner reported none of it and could not have: the verification copies an agent works in are
`rsync`'d **without `.git`** on purpose, so a build in them cannot touch the developer's index,
and `isDisposable` refuses a path outside any repository. Relaxing that for `/tmp` would point an
arbitrary-delete primitive at a directory full of other people's data. So `scanScratch(roots:)`
asks a different necessary question: **a manifest the producing tool wrote**. DerivedData carries
an `info.plist` naming its own `WorkspacePath`, beside `Build/` and `ModuleCache.noindex/` —
written by Xcode and by nothing else, where `target` beside a `Cargo.toml` is a guess by
comparison. Its `LastAccessedDate` is a better staleness reading than the newest mtime inside, so
`modifiedAt` is the newer of the two.

**Recognition there is by shape, never by name.** DerivedData has no fixed name — the trees
measured here are called `dd`, `dd2`, `verify-dd`, `dd-snap`, `threading-theme-polish-dd` and
`derived-data` — so `DerivedDataManifest.read(inDirectory:)` is a recognizer of its own, reachable
only from the scratch walk, and `kind(for:)`'s name-first contract is untouched. `isSafeToRemove`
routes by kind, so a name-gated finding is never waved through on a manifest; the scratch re-check
re-reads the plist, since a tree stops being Xcode's the moment its manifest goes, and re-confirms
containment in a root with symlinks resolved, `/tmp` and `/private/tmp` being one place.

**Three tiers, and the third is never offered.** A cache whose workspace still exists is
attributed to it; one whose workspace is gone is the safest thing this page will ever offer, since
nothing can rebuild into it. Everything else in a scratch root is declined whole, name-gated kinds
included: a `node_modules` beside a real `package.json` in an agent's working copy passes the
*sufficient* gate and is still refused, because a wrong answer there destroys the only copy of
work in progress. That leaves about 38 GiB of the 76 GB recoverable, and makes the rest safe.

**The walk's bounds are measurements.** The roots are `/private/tmp` (not `/tmp`, a symlink to it
— naming both walks 76 GB twice) and the per-user temporary directory, 8.1 GB here and cleaned by
macOS on a schedule nothing applies to `/private/tmp`. Depth is 7, separate from the project
scan's 8: every DerivedData tree measured sat within 6 levels of `/private/tmp`, most within 3.
The pruning is load-bearing rather than an optimisation — one `rsync`'d scratch tree holds
**87,998 files** — so a recognized DerivedData is not descended into, and any directory named for
a name-gated kind is skipped whole rather than walked for findings that would all be refused.

**Sizes count each inode once, the way `du` does.** Build directories are full of hard links —
one real Cargo `target/` held 37,810 files sharing 25,021 inodes — and summing per-file sizes
claimed 42.79 GB where the directory occupies 33.18 GiB, a 29% overstatement of the single
number the feature exists to report. The identifier is only fetched when `linkCount > 1`, so an
ordinary file costs nothing extra. `du` also descends into bundles and the measurement did not: it
enumerated with `.skipsPackageDescendants` until a fixture caught it reporting **8 KB for a tree
whose `.app` held 16 KB more**, which for a DerivedData's all-bundle `Build/Products` understates
the scope this was extended to cover.

**Findings are cached and the scan is passive.** `ArtifactScanService` keeps the results in
Application Support and refreshes them on a `.background` queue — the QoS whose I/O the system
throttles, which is right for a chore nobody is waiting on. Finding 45 directories means walking
every *other* directory in four projects first, a little over a minute here, so a page that
scanned on open would be empty every time it opened. It draws the cache instead and asks for
anything stale to be re-measured. A passive pass skips a project whose sessions are **working**:
an agent mid-build is both the worst moment to compete for the disk and the worst moment to
measure a directory it is still writing. A cached number is shown with its age, because one that
does not say when it was taken is claiming to be live.

**The scratch reading is a second file with a wider busy rule.** It persists as
`storage-scratch-scan.json` beside the projects' one rather than inside it: that store's value is
`[ProjectID: ProjectScan]`, a finding belonging to no project has nowhere to live in it, and
changing the shape would break decode of the cache the page paints from on first open, where a
second file needs no migration. It rides the same passive timer through `refreshStaleProjects()`.
Its busy rule is broader than a project's — a pass is skipped while **any** session anywhere is
working, because `/private/tmp` holds every session's scratchpad. And the reading goes stale as a
project's does not: during a five-minute measurement one session directory fell from **21 GB to
92 KB** with nobody acting, so `scratchArtifacts()` re-filters what has vanished at read time.

**Agents can see the listing and propose a cleanup, never perform one.** `list_reclaimable_storage`
returns the cache; `propose_storage_cleanup` puts named paths to the user as a sheet and removes
only what they approve. Both scopes appear there, and a scratch line names the workspace its cache
was built for rather than a checkout it has none of, with no git subprocess run on it. The gate
that keeps this from being an arbitrary-delete primitive is that **a proposal can only name paths
already in the findings** — everything there has passed the pair of gates its kind answers to, and
is asked again at the moment of deletion. The tool answers only once the user has decided, so the
agent's next turn knows the outcome rather than assuming it.

**The instruction keys on the failure, not on a measurement.** An earlier version stated the disk's
free space in the `initialize` instructions, so an agent would know it was short. Wrong twice: the
reading is a snapshot taken at session start, while a session that fills the disk does so an hour
later — and an agent that runs out of room learns it from the write that failed, which is a better
signal than any advance warning. What it lacks at that moment is not the fact but the tool, which
is static. So the group's instruction triggers on the symptom ("No space left on device", ENOSPC,
a build dying partway) and tells it to look before reporting failure. `DiskSpace` survives for the
Storage page, where free space is the context that turns "87 GB reclaimable" into a decision.
That instruction now names both scopes and tells the agent to **lead with the lines marked
`ORPHANED`** — the tier with no plausible way to be wrong, and 13.4 GiB of it on a machine with
31 GiB free. The tool description states what was checked in the same two-scope terms: everything
listed is *ignored by git or identified as a build cache by Xcode's own manifest*.

The page groups **by checkout, not by project**, because six of one project's checkouts hold a
`web/node_modules` and a row reading `web/node_modules` under a heading reading `sonda` names
none of them. Each heading is `<project> · <worktree or branch> · <size>`; rows are relative to
their checkout. Rows state the rebuild command and the age, and a directory written in the last
fifteen minutes reads as **in use** — the first real scan found the largest directory on the
page had been written two minutes earlier, in a worktree with no Threading session to warn about.
That is the second of two independent in-flight checks, the other being a running session in
the project.

**A scratch finding is attributed when the page is read, and asks git nothing.** Whether a
workspace still exists, and whether it sits inside a project Threading knows, both change between
the walk and the reading, so the split is computed at draw time from `workspacePath`. A cache
built for a known project's workspace heads `<project> · build cache in /tmp` and sorts among that
project's checkouts by size; the tiers naming no project trail the page, orphans first under
**Left over from deleted workspaces**, then **Other build caches in temporary locations** for a
workspace that is alive and is not ours — filing that under the orphan heading would say a
directory somebody may be building in right now was left over from a deletion. Rows carry `built
for <workspace>`, and orphans `, which no longer exists`, which is the whole reason such a row is
safe. Removal re-checks the gates and forgets only what actually deleted, so a refused orphan
stays on the page; no rescan follows one here. The header's total, count and freshness age include
the scratch reading.

A row's size and its Remove are one control, `SettingsUI.controlGroup`, because a hand-rolled
stack of the two floated in the middle of the card in the real scrolling page while looking right
in every fixture. See the 2026-08-12 entry in
[`design-system.md`](design-system.md); the sizes read as a column only because that group is
flush to the trailing inset.

## Project Stats

Hovering a project row opens a compact, cached summary of two different questions:

- **What is it?** Total code lines and files, a language bar, and a legend, counted by the
  exact `scc` helper shipped in `Contents/Helpers`.
- **How active is it?** Commits in twelve fixed seven-day buckets and the latest commit time,
  read from Git and scoped to the project folder.

The app no longer depends on a user-installed executable or a Finder-launched process's `PATH`.
`ThirdParty/scc/scc` is a pinned universal arm64/x86_64 build reproduced from the two official
3.7.0 Darwin release archives by `scripts/update_bundled_scc.sh`. Xcode embeds and re-signs it;
CI and release verify both architectures and the exact version. Its MIT license is part of the
verified legal-notice bundle. The app invokes it from the project directory with `--no-min-gen`,
so minified and generated bundles do not dominate the bar while scc's normal `.gitignore`,
`.ignore`, and `.sccignore` handling keeps ignored dependencies out.

`ProjectStatsService` gives code composition and Git activity separate persisted caches,
utility queues, in-flight sets, and freshness clocks. A large bounded history query therefore
cannot delay the code reading. Both refresh passively, on hover when aged, and at the
`sessionStateDidChange` stopped-working edge — the moment at which project facts most likely
changed. No measurement starts while that project's session is working. Hover triggers at row
entry rather than after the dwell, guarded by `hoverRefreshAfter`, so crossing rows cannot launch
a new pair of processes each time.

Publishing a result never encodes or writes its cache on the main actor. Each cache has a serial
utility writer that receives only the changed project reading, lazily owns a separate dictionary,
and folds completions into one verified whole-file write per two-second window. Passing the whole
main-actor dictionary to a background closure is not equivalent: retaining that snapshot makes
the next dictionary mutation copy every project. The exact-update boundary keeps both caller work
and background write frequency bounded as project count grows.

Git activity is intentionally an aggregate rather than a log. One query finds the latest commit;
a second reads at most 20,001 commit timestamps since the start of the oldest bucket. Each has a
15-second/512-KiB process bound. At 20,001 results the reading becomes `20,000+ commits` and the
chart is withheld: drawing a truncated distribution as complete would be false. Non-Git projects
omit the section, an unborn repository says **No commits yet**, and a dormant repository retains
its zero buckets and old latest-commit date. The two caches preserve those distinctions without
storing commit messages, authors, file paths, or diffs.

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
draws normal, truncated, non-Git, and no-commit states in both themes. The full Project Insights
surface remains an extension proposal rather than expanding this glanceable card; see
[`project-insights-extension.md`](../feature-drafts/project-insights-extension.md).
