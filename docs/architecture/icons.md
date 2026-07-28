# Icons

Agent marks, account chips, project icons and their discovery.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

Two kinds of icon, resolved differently on purpose.

**Agent marks** (`AgentBrandIcons`): a session row's icon slot shows the agent's own
favicon — Claude's coral starburst, OpenAI's knot — instead of an SF Symbol. Loose PNGs under
`Resources/Icons`, loaded via `Bundle.main` (the folder is an explicit-folder resource, so it
lands under `Contents/Resources/Icons/`), *not* the asset catalogue. The OpenAI knot is monochrome by design, so it
ships as a **template image** and tints with its context like the symbols beside it — which
is what makes it work in dark mode and dim for dormancy. Claude's mark keeps its brand
colour; tinting cannot dim a non-template image, so dormancy dims it through the view's
alpha instead (`SessionRowView.applyAgentIcon`).

**Account chips** (`AccountBadge`): the mark keeps the slot and an *alternate* account rides
its bottom-trailing corner as a 9pt chip — the account's emoji, else its discovered avatar,
else an initial on a hashed disc. The two facts a row carries, which agent and which account,
had been competing for one 16pt slot and the account was winning: an alternate account
replaced the mark with a flat `c.circle.fill`, so a sidebar of alternate accounts showed no
agent at all. The chip is laid out as an **overlay** rather than a second arranged view, so
rows with and without one still align, and it hangs `cornerOverhang` past the slot because
flush inside it covered the middle of a 13pt mark.

The initial comes from the **login email**, not the alias: aliases are named after the agent
and collide on it (`claude-dblock` and `claude-vlundborg` are both `c`), while the addresses
give `D` and `L`. Its disc hashes the whole address through `GeneratedProjectIcon.stableHash`,
so two accounts sharing an initial still differ by colour, on a brighter ramp than the project
tiles — a 9pt disc has far less area to carry a hue than a 16pt tile. The **default account
gets no chip**: its agent's mark already says everything the row knows.

`AccountAvatarStore.cachedEmail` memoizes the address, hit or miss. The badge asks on every
row configure and rows reconfigure constantly while an agent works, where the uncached answer
is a file read and a JWT decode for a value that cannot change while the app runs.

**Project icons** (`ProjectIcon` on `Project`; files owned by `ProjectIconStore`): the
project row shows the project's own mark, else a folder symbol. Every stored icon is
normalised through ImageIO — largest frame (`.ico` carries several), capped at 64px,
re-encoded PNG — so the sidebar never holds a 1024px app icon per row, and an HTML error
page served with a 200 fails the same decode gate that admits real images.

`ProjectIconDiscovery` fills empty slots free of any agent, and **probes known paths rather
than walking the tree**: a recursive scan would surface `node_modules/<lib>/favicon.ico` as
the project's mark. Only the `AppIcon.appiconset` search enumerates, bounded and skipping
dependency directories. Then the GitHub owner avatar (read from the *shared* git config via
`GitInfo.remoteOriginURL` — remotes belong to the repository, not a checkout), then the
favicon of the `package.json` homepage; the network sources only contact hosts the project
itself points at, plus one GitHub API call gating the avatar. Automatic discovery only ever
fills an **empty** slot; a user's explicit choice (`.custom`) is never displaced.

The avatar is admitted **only for organisation owners** (`isOrganization`, via
`api.github.com/users/<owner>`): a person's avatar puts the same face on every repo they
own, which distinguishes nothing — and any doubt (API error, rate limit) refuses rather
than guesses, because the failure mode of guessing is a face on every project. A project
with no discovered mark renders `GeneratedProjectIcon` at *draw time* — its initial on a
colour from a stable djb2 hash of the name (`hashValue` is process-salted and would
recolour the sidebar per launch) — never persisted, so the slot stays genuinely empty for
later discovery.

`SingleInstanceLock` (`flock`, held for the process lifetime) refuses a second instance at
launch, before anything touches the stores: two live instances share `projects.json`
last-writer-wins, and even *instantiating* `ProjectStore` writes it once — a relaunch
handoff between overlapping instances is how three projects lost their icon records. The
losing instance's quit path skips store teardown for the same reason.

The sidebar draws the *composed* rendition (`ProjectIconStore.displayImage`): rounded-rect
clipped, and set on a small **backplate** of the opposing tone when the icon's own
alpha-weighted mean luminance would vanish against the current appearance — a dark mark on
the dark sidebar gets a light plate, measured from the icon's pixels rather than guessed
from its source. The plate colours are fixed neutrals *on purpose*, an exception to the
system-colours rule: a plate exists to oppose the appearance, and every system colour
follows it. Rows retain the `ProjectIcon` and re-compose on
`viewDidChangeEffectiveAppearance`, since the decision is per-appearance.

`ProjectIconResearch` asks Codex to identify the mark — headless `codex exec`, read-only
sandbox, low reasoning effort, default account. Codex-only for the *sandbox*, not for policy:
the run reads an unfamiliar project's files and `--sandbox read-only` bounds it in one flag,
where Claude's headless mode — permitted, see `supportsNativeUI` — would need its tool surface
constrained explicitly for no gain here.
It is **manual-only** because it spends the user's own usage: each run is one explicit
"Research Icon with Codex" menu click, never a background default. A file path in its
answer is admitted only from inside the project's own folder — the run is sandboxed, but
our read of its answer is not.

**A headless child is invisible by construction, so every run leaves a record**: the
child's stdout and stderr — merged into one pipe, so a single reader can never deadlock
and the record holds the whole story — land in `IconResearch/<projectID>.jsonl` under
Application Support, written *before* the verdict so failed runs are exactly the ones
whose record survives. Stages log through `SkalmanLogger.agent`, and the sidebar exposes
the record as "Open Last Research Log". This observability exists because the first real
run failed silently and nothing could say where.

Agents can set the icon from inside a session via the `set_project_icon` MCP tool, its own
group on the Tools page.

**Account avatars** (`AccountAvatarStore`): a chip resolves emoji → discovered avatar →
hashed initial. The avatar comes from the account's login
email — Claude's `.claude.json` `oauthAccount.emailAddress`, the `email` claim of Codex's
`id_token` (decoded locally; the token itself is never used) — probed against Gravatar
(SHA-256, `d=404` so a miss is a status code) and then GitHub's public-email user search.
The person-avatar ban on project rows *inverts* here on purpose: an account is a person,
and different logins carry different faces, so the avatar distinguishes. Hits land in
`AccountAvatars/` and refresh the sidebar through the same notification an emoji edit posts;
behind `AppSettings.discoversAccountAvatars`, which is the only thing that lets an email hash
leave the machine.

Coverage is honestly thin — of five logins on this machine only one resolved, so the hashed
initial is the chip's working case rather than its fallback. The chip's cache key carries
`hasAvatar`, so one landing later replaces a drawn initial instead of being ignored.
