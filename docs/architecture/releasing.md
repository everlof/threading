# Releasing & Automatic Updates

How a distributable Threading.app is produced, and how Sparkle updates it. Sparkle is wired in:
`Core/Updates` is the only place that imports it, the switch is Settings ▸ General ▸ Software
Updates, and what an update check reveals is on the Privacy page. The custom `SPUUserDriver` is
built — every update stage renders as Threading's own sheets; see
[The UI is ours](#the-ui-is-ours-with-one-documented-exception). So is everything after the
stapled zip: `scripts/generate_appcast.sh`, `scripts/publish_release.sh`, and the release and
nightly workflows under `.github/workflows/`. What remains before the first tag is one manual
`generate_keys` run ([Keys](#keys--threadings-own-one-manual-step-from-real)) and installing the
five signing/notarization secrets named at the top of `.github/workflows/release.yml`.

## Distribution signing is not a build setting

The obvious move is to pin `CODE_SIGN_IDENTITY[sdk=macosx*] = "Developer ID Application"` in the
Release configuration. It fails, and the failure is worth recording because it looks like a
missing certificate and is not:

```
error: Threading has conflicting provisioning settings. Threading is automatically signed for
development, but a conflicting code signing identity Developer ID Application has been manually
specified.
```

Xcode's automatic signing issues *development* certificates for a `build` action. A manually
named distribution identity contradicts that, for every target at once — the app and all three
helpers. The alternatives are to switch every target to manual signing, or to treat distribution
as what Xcode considers it to be: an **export** concern.

`scripts/release.sh` therefore archives and exports:

```
xcodebuild archive        -configuration Release -destination 'generic/platform=macOS'
xcodebuild -exportArchive -exportOptionsPlist (method: developer-id, signingStyle: automatic)
```

Both invocations allow provisioning updates. That is load-bearing once the shipping app carries
managed capabilities such as Sign in with Apple: automatic signing cannot create or download the
matching profile from a command-line archive unless `-allowProvisioningUpdates` is present. The
release machine therefore needs the team signed in through Xcode; an unattended runner must
install the matching provisioning profile before invoking the same script.

The consequence to keep in mind: `xcodebuild build -configuration Release` still produces a
development-signed bundle carrying `get-task-allow`. That is fine — it is not the artefact
anyone ships — but it means "did the entitlement change work?" cannot be answered by looking at
a local Release build. See [`permissions.md`](permissions.md).

## Sign in with Apple cannot be shipped by Developer ID

Threading shipped `com.apple.developer.applesignin` for the hosted-access flow. It was removed on
23 August 2026, the first day the release pipeline was ever exercised, because it cannot be
delivered by the way this app is distributed — and until it went, no release could be exported at
all.

A restricted `com.apple.developer.*` entitlement has to be authorised by a provisioning profile
whatever the distribution method, so a Developer ID build needs one the moment it ships a
capability. Sign in with Apple never reaches a Developer ID profile. The App ID has the capability
enabled, and the portal's profile page lists it:

> Enabled Capabilities: In-App Purchase, Push Notifications, Sign In with Apple

That line describes the **App ID**, not the profile — note it also lists In-App Purchase, which
produces no entitlement either. The profile's own entitlements dict, which is what `exportArchive`
reads, carries only:

```
keychain-access-groups
com.apple.developer.aps-environment      ← Push does cross over
com.apple.application-identifier
com.apple.developer.team-identifier
```

Re-issuing does not change it; two regenerations produced two UUIDs and the same four keys. So the
export refuses, and the message names a feature the portal insists is enabled:

```
error: exportArchive "Threading.app" requires a provisioning profile with the
       Sign In with Apple feature.
```

**The bypass is a trap.** `codesign` will sign the entitlement with no profile at all — the bundle
verifies and satisfies its designated requirement — so it is tempting to skip `exportArchive` and
sign by hand. The result is an entitlement no embedded profile authorises, which the system
refuses at runtime. That ships a sign-in button that still does not work, and takes on re-signing
Sparkle's nested bundles inside-out, which the export otherwise does for free.

Nothing working was lost by removing it: the entitlement had never been in a distributed build,
because it never could be. The supported path for direct distribution is the web flow — a Services
ID with `ASWebAuthenticationSession` — and that is what hosted sign-in needs before the button
means anything outside a development build.

**What this bought.** It was the only `com.apple.developer.*` key in the entitlements file, so
there are now none, and a Developer ID export needs no profile whatsoever: no profile secret in
Actions, and no Xcode account for automatic signing to ask for one. `scripts/release.sh` signs
manually against the certificate alone.

The preflight stays, because the next restricted capability will hit this again. Before archiving,
it reads the entitlements file, and if a `com.apple.developer.*` key is present it requires an
installed profile that is a Developer ID profile, matches `TEAM.bundle-id`, and carries that key —
otherwise it says so in two seconds instead of after a ten-minute archive. With nothing restricted
it prints that no profile is needed and stands aside. It ignores `com.apple.security.cs.*`, which
are hardened-runtime flags no profile mentions and demanding them would fail every build.

## Keeping /Applications on master

`scripts/autoinstall.sh` rebuilds and installs Threading every time a commit lands on master. The
post-commit and post-merge hooks call `autoinstall.sh trigger`; a build already running when the
next commit arrives is cancelled and started again on the newer commit, so the installed copy
converges on master's tip rather than on whichever build finished last. `status`, `log`, `off` and
`on` are the rest of its surface, and `scripts/install_git_hooks.sh` installs the hooks.

**It builds a clone, not this tree.** Several agents edit this working tree at once and master
moves under them, so a build started here would compile a half-written state and would fight the
developer's own DerivedData. `~/.threading-autoinstall/checkout` is a `--local` clone reset to the
exact commit that triggered the round, with DerivedData beside it. A build is of a commit. The
builder passes that commit as `THREADING_SOURCE_REVISION`, reads `ThreadingSourceRevision` back
from the finished app, and refuses the product if the two differ. The stamp is empty in ordinary
and shipping builds; it proves only the local convergence loop's source, never a public version.

**A build action *can* be Developer ID signed** — this is the "switch every target to manual
signing" alternative the section above names, taken from the command line where it applies to
every target at once:

```
CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application: …"
PROVISIONING_PROFILE_SPECIFIER="" CODE_SIGN_ENTITLEMENTS=… CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
```

Two things make it work. The entitlements are derived from the app's own file with every
`com.apple.developer.*` key removed, because those are the profile-backed family and no
`codes.threading` profile exists on this machine — with Sign in with Apple left in, the build
fails outright with "requires a provisioning profile with the Sign In with Apple feature". And
`CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` strips the `get-task-allow` Xcode otherwise injects, so
the app you leave running all day is not one any process running as you can attach a debugger to.

The result is a bundle whose designated requirement is byte-identical to the shipping one —
`identifier "codes.threading"` and a Developer ID leaf for the team — which is what makes the
TCC grants survive the swap. It is *not* a shipping artefact: unnotarized, untimestamped, single
architecture, and missing the managed capability. It still cannot answer "did the entitlement
change work?"; only the export can.

**It never quits or moves the running app.** Threading hosts live agent sessions in PTYs, and any
agent committing to master would otherwise end a turn somebody is in the middle of. Once a build
is ready, the builder waits for `/Applications/Threading.app` to quit and only then calls the
installer. If master moves while it waits, that product is discarded and the newest commit is
built instead. The installer checks again both before and immediately after moving the outgoing
bundle, so a reopen during staging is refused and retried rather than turning a live bundle into
an update casualty.

**An install receipt follows the executable, not the placeholder version.** Local builds all
report `0.0.0`, so comparing `CFBundleVersion` can accept yesterday's app as today's. The installer
hashes the built executable, checks the staged copy before the swap, and checks the installed copy
again before returning success. The auto-installer writes its commit receipt only after that
return. This is the provenance boundary: a receipt can no longer say a fix reached `/Applications`
while the process still launches from an older binary.

That refusal is load-bearing for notifications. The old `--leave-running` path moved a live app
to `.Threading.app.parked-<pid>` and installed the replacement at its original URL. LaunchServices
kept the parked bundle registered for `codes.threading`; clicking a notification could therefore
launch the parked executable, which lost `SingleInstanceLock` and showed “Threading is already
running” instead of delivering the notification response to the existing process. The installer
now unregisters and removes legacy parked bundles once their recorded processes are gone, never
creates new ones, unregisters the outgoing stopped bundle, and force-registers the one surviving
`/Applications` URL.

**Detection uses `ps -o comm=`, not `pgrep -f`.** `pgrep` matches against argv, which a sandboxed
shell cannot read — and a git hook fired by an agent's commit is one. It returns nothing while the
app is plainly running, and nothing here means "not running, safe to replace".

**Cancellation is a process group.** `xcodebuild` is started under job control so it gets a group
of its own; the trigger sends `SIGTERM` to that group, which takes the compiler children with it,
while the builder stays alive in its own group to start the next round. The builder then compares
master's tip with the commit it was building: moved means start again, unchanged means the build
genuinely failed, which is reported once and out loud.

Measured on this machine: 509s for the first build of a fresh checkout, 24s for an incremental
rebuild with no source change, 27s from trigger to ready and, when Threading is not running,
installed and verified. On disk: 134MB of checkout and 2.5GB of DerivedData; no second runnable
application bundle is retained.

Before signing, the release script runs the same `scripts/ci.sh` gate as GitHub Actions:
architecture/localization/theme boundaries, SwiftLint, the three local package suites, and the
off-screen app test plan under complete concurrency checking. A deliberate emergency run may
set `THREADING_SKIP_RELEASE_CHECKS=1`; skipping is never the default. Notarization additionally
requires a clean worktree, so the exported bundle always corresponds to reviewable source.

Archive and export output is captured in `build/release/archive.log` and `export.log`. Their real
exit statuses are checked before any bundle-existence test. Do not pipe `xcodebuild` through
`grep … || true`: Xcode can create an archive directory before a later build phase fails, and a
mere directory check would then let a broken or stale artefact advance to signing.

The legal-notice phase resolves remote-package licenses from DerivedData by stripping the stable
`/Build/…` suffix from `BUILD_DIR`. Parent counting is not equivalent: a normal build places that
setting at `Build/Products`, while an archive moves it under
`Build/Intermediates.noindex/ArchiveIntermediates/…`. The phase is deliberately always out of date;
its input lists name `Package.resolved` as the remote dependency boundary, and the script validates
every resolved license before copying it into the bundle.

The app-owned extension catalogue is also a release artefact, not a source-tree promise. The
Embed Extension SDK phase assembles
`Contents/Resources/FirstPartyExtensions/codes.threading.storm.threadingextension` with the
prebuilt inert WebAssembly registration module, theme resources, and rebuildable vendored source.
`testBuiltAppShipsAnInspectableStormCatalogPackageAndItsSource` is the release gate: it resolves
the production catalogue from `Bundle.main`, inspects the exact built package, matches its
manifest to the host-owned entry, verifies the source snapshot, and runs registration through the
product policy. Before adding a catalogue entry, add its package to that phase and extend this
built-app gate. Never publish a Git-only entry: Git links are for inspection and are not cloned,
built, or used as update authority.

## The version is injected, not committed

Sparkle compares `CFBundleVersion`, so it has to increase per release. Threading's version fields
come from build settings (`$(MARKETING_VERSION)`, `$(CURRENT_PROJECT_VERSION)`), which means the
obvious approach — bump them like claudex bumps its Info.plist — would edit `project.pbxproj`
once per release. That is the most contended file in this repo, and the one whose conflicts are
worst. claudex gets away with it because its number lives in a standalone plist nothing else
touches.

So the release passes both values to `xcodebuild archive` and the project file never changes:

```
xcodebuild archive … MARKETING_VERSION=1.1.0 CURRENT_PROJECT_VERSION=1.1.0
```

**The git tag is the source of truth.** `release.sh` resolves the version from
`$THREADING_VERSION`, else `git describe --tags --exact-match HEAD` with the `v` stripped. Both
fields get the same dotted semver, as in claudex; `SUStandardVersionComparator` orders components
numerically, so `1.10.0 > 1.9.0` behaves.

Three guards, because the failure this prevents is silent — an app that ships the placeholder
forever is one no installed copy can ever see an update for:

- a version that is not dotted digits is refused, since Sparkle could not order it;
- `--notarize` without a tag or an explicit version is refused outright, so an untagged build
  cannot be shipped;
- after export, the versions are **read back off the built bundle** and compared. claudex checks
  its plist before building, which cannot catch a build setting that failed to take; reading the
  artefact does.

Without a tag, a plain `scripts/release.sh` still runs — it falls back to the project's value and
says so — because signing dry runs should not require ceremony.

### The placeholder is 0.0.0 on purpose

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are `0.0.0` in the macOS app's build settings
(the iOS companion keeps its own numbering; it does not ship through Sparkle). That value is only
ever seen by a build made without a tag — a local Release, or a signing dry run.

It is deliberately the lowest thing that sorts, so an untagged build can never believe it is
newer than the feed. The alternative bites in a specific way: while the placeholder was `1.0` and
the release line started at `0.1.0`, any locally built copy would have outranked every published
release and quietly stopped offering updates forever. A dev build reporting `0.0.0` in the About
box and in diagnostics is also a useful tell that it did not come from a release.

Nothing shipped before Sparkle existed, so the release line starts wherever it likes — `0.1.0` is
a reasonable first tag. The only rule from the first Sparkle-carrying build onward is that the
number goes up.

The remaining manual step is tagging: `git tag v0.1.0` before a release. This repo has no tags
yet, so the first one establishes the sequence.

## Channels

Four, of which the release pipeline can stamp three:

| Channel | Made by | Version | Badge |
|---|---|---|---|
| `release` | `scripts/release.sh` on a tag | the tag's semver | none |
| `beta` | `scripts/release.sh --channel beta` | *(pipeline not built yet — see below)* | BETA |
| `nightly` | `scripts/release.sh --channel nightly` with `THREADING_VERSION` | the date as dotted digits, e.g. `2026.8.2` | NIGHTLY |
| `dev` | every build made any other way | `0.0.0` | DEV |

The channel travels the version's road exactly: `release.sh` passes `THREADING_CHANNEL` to
`xcodebuild archive`, `Info.plist` carries it as `$(THREADING_CHANNEL)` under the
`ThreadingBuildChannel` key, and the value is **read back off the exported bundle** with the
same guard as the version fields. The placeholder story is also the version's: an uninjected
build expands to the empty string, which `AppInfo.buildChannel` reads as `.dev` — so a local
build can no more claim to be a release than it can carry a real number, and `release.sh`
refuses `--channel dev` outright while forcing an untagged dry run *onto* `dev`, because an
artefact with no real version is not a member of any channel whatever was asked for.

What the user sees is `BuildChannelBadge`: a quiet mark beside Settings in the sidebar's
footer naming the flavour — and nothing at all on a release build, because a mark every
install wore would be wallpaper. The exact version deliberately stays out of the chrome; the
badge answers "which kind of build is this screenshot", not "which build".

**But hovering it asks "which build", and it now answers.** The mark's Help Tag was the spoken
channel name and nothing else — `DEV` expanded to "Development build", a synonym for the three
letters already on screen. Hovering a build mark is the one gesture anybody makes to ask what
this copy of the app *is*, so the tag is now `BuildDetails.helpTag`: that sentence, then the
version pair, the Xcode configuration, when the executable was linked, the system and the
architecture. The same string is on `accessibilityHelp`, while `accessibilityLabel` stays the
sentence — a mark that recited a build every time VoiceOver passed it would be unusable.

`BuildDetails` is where those readings are assembled, once, for the badge and for the About
window (`docs/architecture/window-chrome.md`). Three rules are load-bearing:

- **The build date is the executable's modification time**, `BuildFingerprint`'s reason exactly:
  an unstamped build carries `0.0.0 (0.0.0)` whatever it is, so when it was linked is the only
  reading that separates this build from the one before it — which is what a `DEV` mark is being
  asked. One `stat`, on a surface somebody just pointed at.
- **A reading nobody can take is left out**, not filled in with a word meaning missing. A build
  date the filesystem will not give up is one fewer line; "Unknown" reads like a fault.
- **The channel is never a row.** The Help Tag opens with the sentence the mark stands for and the
  About window sets the mark beside the version, so a Channel line would state it twice — and on a
  release build would name the channel whose whole design is to go unmarked.

`Debug`/`Release` and `arm64`/`x86_64` stay untranslated: they are the build system's own names,
read against Xcode rather than against the reader's locale.

**Nightlies get their own feed, never a channel tag on the stable one.** A nightly's
`2026.x` outranks every `1.x` under `SUStandardVersionComparator`, so in a shared feed a
nightly install would permanently outrank stable and stop seeing updates the moment it
should return there. A separate `SUFeedURL` — a rolling `nightly` pre-release tag serving its
own `appcast.xml` — sidesteps the comparison entirely, and date-dotted versions satisfy both
the dotted-digits guard and Sparkle's ordering within the feed. The nightly pipeline is
`.github/workflows/nightly.yml`: manually dispatchable until its required repository secrets
are installed, skips an unmoved `master` by comparing HEAD to the rolling `nightly` tag, builds
`--channel nightly` with the date version through the same `release.sh` (whose quality gate is
`ci.sh`), embeds a commits-since-last-nightly notes file, and republishes the rolling prerelease
with its own `appcast.xml`. Re-enable its daily schedule only after all five secrets exist. The
app side is
`UpdateFeedPolicy`: a nightly-channel build's `SPUUpdaterDelegate` routes to
`releases/download/nightly/appcast.xml`, and the stable `SUFeedURL` in the plist stays the
single source of truth for everyone else. A dev build (`0.0.0`) additionally never checks on a
schedule — it is outranked by every release forever, so the daily check would nag daily
forever; Help ▸ Check for Updates… still works there.

**Beta is a feed feature, not a third pipeline.** Sparkle 2 items can carry
`<sparkle:channel>beta</sparkle:channel>` in the stable appcast, invisible to updaters unless
the delegate opts in — so "include beta updates" becomes a Settings toggle when wanted, with
no separate feed and no separate versioning scheme. The `--channel beta` stamp exists so
those builds wear their badge the day that arrives; until then nothing publishes it.

## Apple silicon only

Threading builds and ships for `arm64` alone. The decision is about what a person sees when they
look at `Threading.app` in the Finder, not about CPUs: measured on master at `0fbd79f9` (Xcode
26.5, `xcodebuild archive -configuration Release`, stripped, unsigned), the universal bundle was
107 MB on disk and 46 MB as the zip Sparkle serves; the same bundle thinned to `arm64` is 54.5 MB
and 24.5 MB. The second slice was half of the product, spread over every binary in it:

| Component | universal | arm64 | compressed, universal → arm64 |
|---|---|---|---|
| `Threading` (stripped) | 59.0 MB | 28.4 MB | 25.3 → 12.1 MB |
| `WebRTC.framework` (prebuilt; the app uses its data channel only) | 27.1 MB | 11.8 MB | 12.1 → 5.5 MB |
| `Helpers` (`scc`, wasm runner, two extension helpers) [^helpers] | 10.9 MB | 5.3 MB | 4.2 → 2.0 MB |
| `Resources` | 7.4 MB | 7.4 MB | 3.7 MB |
| `Sparkle.framework` | 2.8 MB | 1.6 MB | 0.9 → 0.5 MB |

Three things make it so, because any one of them alone would not:

[^helpers]: Measured on 2026-08-08, when `Contents/Helpers` held four binaries. It holds six
    now — `threading-mcp-bridge` and `threading-ptyd` were added since — and the row has not been
    re-measured. Nothing in the argument turns on the figure; the thinning ratio is what it is
    about.

1. **`ARCHS[sdk=macosx*] = arm64` at the project level** builds every Mac target — the app and
   its six helpers — for one slice, in every configuration; the iOS targets are untouched.
   Swift packages built inside the workspace do not read the project's `ARCHS`, though: with
   only the project setting, every package still compiled an `x86_64` slice the link then
   discarded — 139 compiles in one archive. `release.sh` and `autoinstall.sh` therefore also
   pass `ARCHS=arm64` on the command line, which reaches everything.
2. **`scripts/thin_app_architectures.sh` runs on the archive's app before export.**
   `WebRTC.xcframework` and `Sparkle.xcframework` arrive prebuilt and universal from their
   packages, and the build copies what it is given. Thinning happens before export rather than
   after because the export re-signs every nested binary with the Developer ID identity anyway,
   so the seals thinning breaks are replaced for free; thinning the exported app instead would
   mean re-signing Sparkle's five nested bundles inside-out by hand.
3. **The gates refuse a second slice.** The per-binary export verification below checks
   `lipo -archs` against `arm64` beside the four signing properties, and
   `ReleaseArchitectureTests` reads the Mach-O headers of the host app's own executables in
   every test run, so losing the project setting fails `fast` rather than the next release.

The bundled `scc` is the official arm64 3.7.0 executable byte for byte rather than a
`lipo`-combined pair, so it needs no thinning and its provenance is one checksum
(`ThirdParty/scc/PROVENANCE.md`; `scripts/check_bundled_scc.sh` requires exactly that slice).

What else was measured on the way — and why stripping, `-Osize`, on-demand resources and a
slimmer WebRTC are not the next step — is in
[`docs/decisions/bundle-size-levers.md`](../decisions/bundle-size-levers.md).

## The export is verified before it is uploaded

Notarization rejects a bundle whose *nested* code is development-signed, untimestamped, or
missing the hardened runtime, and it reports that only after the upload round-trip. The script
walks every Mach-O in the bundle and checks all four properties locally, which turns a ten-minute
server rejection into an immediate failure naming the binary:

| Checked per binary | Why |
|---|---|
| `Authority=Developer ID Application` | development-signed nested code fails notarization |
| `flags=…runtime` | the hardened runtime is a notarization precondition |
| `Timestamp=` | a secure timestamp is required, and is *not* added by a plain `codesign` |
| no `get-task-allow` | notarization rejects a debuggable binary outright |
| `lipo -archs` is exactly `arm64` | a second slice is 20 MB that no supported Mac can run — see [Apple silicon only](#apple-silicon-only) |

Twelve binaries pass today: `Threading`, its six helpers — `scc`, the wasm runner, the two
extension helpers, `threading-mcp-bridge` and `threading-ptyd` — and Sparkle's five: `Sparkle`,
`Autoupdate`, `Updater`, `Downloader` and `Installer`. The loop is a `find` over the bundle
rather than a list, which is why adding Sparkle needed no change to it, and why the PTY host
daemon needed none either.

### The launch agent's plist is a resource, not code

`Contents/Library/LaunchAgents/codes.threading.ptyd.plist` is the file
`SMAppService.agent(plistName:)` reads to register `threading-ptyd`
([`pty-host.md`](pty-host.md#registration-and-retirement)). It is copied by a **Copy Files** phase
into the app wrapper and it is *not* signed separately: a plist under `Contents/Library` is a
sealed resource of the app, covered by the app's own signature and by `codesign --verify --deep
--strict`. Nothing about the export changes for it.

**A helper is different, and this is the trap.** `codesign` treats everything under
`Contents/Helpers` as nested code — **including a shell script** — and refuses to seal the bundle
if any of it is unsigned ("code object is not signed at all / In subcomponent: …"). Anything ever
added there needs its own `CodeSignOnCopy`, which is what the **Embed Extension Helpers** phase
already sets for all six binaries.

**`BundleProgram` is bundle-relative on purpose, and that is what makes the swap safe.** launchd
binds a registration to a *path*, not to a code identity (measured 2026-08-23): replacing the
whole bundle leaves `SMAppService.status` at `enabled` and the job still resolvable, because the
path it resolves — `Contents/Helpers/threading-ptyd` inside `/Applications/Threading.app` — is
still there. An absolute `Program` would have been fine too until the day the app moved. What the
swap does *not* do is update the running daemon: launchd execs the new binary only on the next
start, so the old one goes on executing the deleted image. That is what `retire` is for, and the
app asks for it once per launch — see the [upgrade decision](pty-host.md#registration-and-retirement).

Packaging uses `ditto -c -k --keepParent --sequesterRsrc`, not `zip`. Sparkle unpacks with the
same tool, and only `ditto` preserves the symlinks and extended attributes inside a signed
bundle; a `zip`-ed app fails its own signature check on the other side.

`--notarize` is opt-in and needs a stored credential profile, so the script never uploads by
accident:

```
xcrun notarytool store-credentials threading-notary \
  --apple-id <apple-id> --team-id SMQ3E8Y57T --password <app-specific-password>
```

After stapling, the zip is rebuilt from the stapled app — the ticket lives inside the bundle, so
serving the pre-staple zip would ship an unstapled app that Gatekeeper still questions offline.

## Sparkle

Sparkle 2.9.4 (July 2026). `2.x` requires macOS 12+, and this app targets 13+, so the current
line is available with no floor to raise.

### claudex already does all of this — copy it

`~/repo/claudex` ships with Sparkle today, from the same team and the same Apple ID. Treat it as
the reference implementation rather than designing a second pipeline:

| claudex | What Threading takes from it |
|---|---|
| `scripts/generate-appcast.sh` | `--account mjukis-claudex`, `--ed-key-file` fallback for CI, phased rollout interval, Markdown release notes embedded by `generate_appcast`, and a closing `sign_update --verify` on the appcast |
| `scripts/publish-github-release.sh` | the appcast is served from GitHub Releases — claudex's `SUFeedURL` is `https://github.com/everlof/claudex/releases/latest/download/appcast.xml`, so Threading wants the equivalent under its own repo |
| `scripts/publish-homebrew-cask.sh` | a cask, if Threading should be `brew install`-able too |
| notary profile `mjukis-notary` | already stored on this machine; `scripts/release.sh` defaults to it, so `--notarize` needs no setup |

The pieces Threading's `release.sh` already has — archive, Developer ID export, per-binary
verification, `ditto` packaging, notarize, staple — overlap claudex's `release.sh`. What is
missing is everything *after* the stapled zip, and that is exactly what the table above covers.

Worth deciding early: whether these two apps eventually share one script with the product name
parameterised, or stay as two. Two is fine while they diverge; the duplication only starts
hurting at the third.

### Why the integration differs from the other three dependencies

`ThinkingOrbs` and `LabelMorph` are submodule forks, while SwiftTerm is a vendored fork in the
main repository; each has a seam that is ours (see [`dependencies.md`](dependencies.md)).
Sparkle has no such seam: everything worth
customising is reachable through its public API, so it is an `XCRemoteSwiftPackageReference` —
`upToNextMinorVersion` from 2.9.4, matching the existing `NativeDiffKit` reference rather than
pinning exactly, so security patches arrive without a project edit.

(An earlier draft of this file called it "the project's first remote package". It is not —
`NativeDiffKit` was already one, and its wiring is the pattern the Sparkle entries copy.)

`disable-library-validation` is already granted, so the embedded framework loads without further
entitlement work. SPM embeds `Sparkle.framework` automatically from the link; no Embed Frameworks
phase was needed.

**Sparkle brings five nested executables**, all of which notarization inspects:
`Autoupdate`, `Sparkle`, `Updater.app/Contents/MacOS/Updater`, and the `Downloader.xpc` and
`Installer.xpc` services. `scripts/release.sh` verifies them without modification, because its
check is a `find` over the bundle rather than a list of known binaries. With the bundled `scc`
helper, the MCP bridge and the PTY host daemon, the export signs all twelve executables (seven
app-side, five Sparkle) as Developer ID, hardened and timestamped. The release gate separately verifies that `Contents/Helpers/scc` is
the expected official arm64 build after signing.

### The UI is ours, with one documented exception

`SPUStandardUpdaterController` brings Sparkle's stock alert, progress and release-notes windows.
That is third-party AppKit chrome inside an app whose whole design system exists to prevent
exactly that, and `docs/THEME_BOUNDARY.md` forbids feature code from reaching stock controls at
all. The standard driver was a scaffold, and it is deleted: `AppUpdater` constructs
`SPUUpdater(hostBundle:applicationBundle:userDriver:delegate:)` directly around
`UpdateUserDriver`.

**`SPUUserDriver` is a full replacement, not a set of hooks**, and the implementation is split
where the tests want to stand. `UpdateFlow.swift` holds the provider-neutral vocabulary — what a
found update may offer, when a download fraction is honest, how a notes payload decodes — with
no Sparkle import; `UpdateUserDriver` reduces every callback to those values; `UpdatePresenter`
renders them as `ThemedAlert` sheets on the main window, with `ThemedProgressBar`/`ThemedSpinner`
for download and extraction, `ConfirmationAlert` for the two stages that ask a question
(`.installUpdate` and `.installUpdateAndRelaunch` in the `ConfirmationPrompt` register, under
the `.newQuestionEachTime` policy added for them), and "Check for Updates…" is an `AppCommand`
(`app.checkForUpdates`), so the Keyboard page lists it and can bind it a chord.

Decisions a reader would otherwise re-litigate:

- **Release notes render natively in the sheet, not in the display panel's web view** (an
  earlier draft of this file sketched the panel). The panel belongs to a session; an update
  belongs to the app, and can arrive with no session selected. `MarkdownView` already draws in
  the active theme, which no web view does for free.
- **The appcast embeds release notes as Markdown.** `scripts/generate_appcast.sh` hands
  `generate_appcast --embed-release-notes` a `.md` file, which it embeds as
  `<description sparkle:format="markdown">` — the exact shape the sheet renders — and the
  script fails the release if the generated feed carries any other format. Embedded notes
  need no second fetch; a feed that links notes instead still works, decoded through the
  declared encoding with UTF-8 and Latin-1 fallbacks.
- **Sparkle's first-run permission prompt never draws.** Threading already owns that choice as
  the Settings ▸ General switch, so the driver answers the request from the recorded setting,
  and the system profile is never sent — the Privacy page's description depends on that.
- **A scheduled check never interrupts.** An update found in the background waits until the app
  is active and has a window before its sheet appears; a user-initiated check answers on the
  spot, and its "Checking…" sheet appears only after 0.6 s so the common sub-second check shows
  nothing but the verdict.
- **A critical update is offered no Skip** — skipping suppresses every future prompt for that
  version — and an information-only item offers its `infoURL` page rather than an Install
  Sparkle forbids.
- **The no-update and error sheets speak Sparkle's own alert-ready strings**, because "no update
  for you" has reasons a hardcoded "You're up to date" would misreport: OS too old, channel
  gated, already newest.

**The one thing a custom driver cannot take over.** After the app terminates for the file swap,
Sparkle's own installer agent can put a small progress window on screen —
`Sparkle/InstallerProgress/InstallerProgressAppController.m`, launched from `AppInstaller.m`.
Reading that code, it is gated three ways: a hardcoded `shouldShowUIProgress`, a
`SUDisplayProgressTimeDelay` of 0.7 seconds, and a liveness ping — *"if the updater process is
still alive, showing the progress should not be our duty"*. So it appears only when our app is
already gone and the swap runs long. There is no Info.plist key or delegate callback to suppress
it.

That is acceptable: nothing a user interacts with is Sparkle's, and the window that remains shows
up when our app is not on screen. If it ever grates, the repo's own convention is the escape
hatch — all three existing dependencies are forks we modify directly, so forking Sparkle to drop
that one call would be consistent rather than exotic. Do not fork pre-emptively; a pinned remote
package is the right default until that window actually bothers someone.

Either way the decision belongs in `design-system.md` too, as a decision rather than an accident.

### Keys — Threading's own, one manual step from real

**The decision is made: Threading signs with its own EdDSA key, not claudex's.** An earlier
draft of this file chose to reuse the claudex keypair (account `mjukis-claudex`), which worked
while both apps signed on one private machine. The release pipeline now lives in GitHub
Actions, where the private key is a repository secret — and a shared key would extend
*claudex's* blast radius to anyone who compromises Threading's CI. Nothing has shipped through
Sparkle, so minting a separate key was free; after the first published build it would have
meant every install reinstalling by hand.

The key exists (`generate_keys --account mjukis-threading`, run 2026-08-07) and the plist
carries its public half. Key and plist cannot drift apart unnoticed:
`scripts/generate_appcast.sh` compares the signing account's public key against the shipped
plist and refuses to sign on a mismatch, and `generate_appcast` itself leaves the enclosure
unsigned when the app's key disagrees, which the script also treats as fatal. A half-made
key rotation fails the release rather than stranding installs.

Every tool needs the account named explicitly, since it is not the default global one; the
scripts default to it (`THREADING_SPARKLE_ACCOUNT` overrides):

```
sign_update --account mjukis-threading <archive>
generate_appcast --account mjukis-threading <release-dir>
generate_keys -p --account mjukis-threading      # re-print the public key
```

**Lose this key and no existing install can be updated again** — a new key means every user
reinstalls by hand. `generate_keys -x <file> --account mjukis-threading` exports it (base64 of
the 32-byte private seed) for an offline backup and for CI: the `SPARKLE_PRIVATE_KEY`
repository secret is that file's contents, which the workflows hand to the scripts through
`THREADING_SPARKLE_PRIVATE_KEY_FILE` (`--ed-key-file` under the hood, never the deprecated
`-s` flag).

**The feed is signed too, not just the archives.** `SURequireSignedFeed` and
`SUVerifyUpdateBeforeExtraction` are set in Info.plist (claudex's hardening, adopted): the
appcast must carry a valid EdDSA signature over itself — GitHub serving the feed is otherwise
part of the trusted surface — and an archive is verified before it is unpacked, so an
archive-parsing bug cannot be reached by unsigned bytes. Declaring `SURequireSignedFeed` is
also what makes `generate_appcast` sign the feed at all, which the script asserts.

### Steps

0. ~~Give `CFBundleVersion` a real incrementing value.~~ Done — see
   [The version is injected, not committed](#the-version-is-injected-not-committed). Tag a
   release (`git tag v1.1.0`) and `release.sh` carries the number into both fields.
1. Add the Sparkle package, pinned; set `Runpath Search Paths` to `@loader_path/../Frameworks`.
2. Back up the existing private key (above) before anything is published.
3. Info.plist: `SUFeedURL` (HTTPS, non-negotiable under ATS), the existing `SUPublicEDKey`, and
   `SUEnableAutomaticChecks`.
4. ~~Wire the updater with a custom `SPUUserDriver`.~~ Done — see
   [The UI is ours](#the-ui-is-ours-with-one-documented-exception). `SPUUpdater` is constructed
   in code (there is no MainMenu.xib; `NSMainNibFile` is empty) and "Check for Updates…" lives
   in the Help menu as the `app.checkForUpdates` `AppCommand`.
5. ~~Generate and publish the appcast.~~ Done — `scripts/generate_appcast.sh` (signing, the
   CHANGELOG.md-section release notes, markdown-format and signature assertions) and
   `scripts/publish_release.sh` (tag preflight, `release.sh --notarize`, the appcast, and the
   GitHub release carrying zip + `appcast.xml` together). The appcast step runs *after*
   notarize-and-staple, since the zip is rebuilt from the stapled bundle and re-signing a
   changed archive would invalidate the appcast's signature. **Neither script ever pushes**:
   `submodule.recurse` makes a push from this machine publish the forked submodules, so the
   tag is pushed by hand and `publish_release.sh` only verifies the remote already has it, at
   HEAD, annotated.
6. ~~Host the appcast and archives over HTTPS.~~ Done — GitHub Releases, claudex's pattern:
   the stable feed is `releases/latest/download/appcast.xml`, uploaded beside each release's
   zip so `latest` always resolves to a matching pair. Whatever serves the feed is part of the
   app's trusted surface, which is why the feed itself is now signed (`SURequireSignedFeed`)
   on top of the enclosure signatures. `.github/workflows/release.yml` runs the same
   `publish_release.sh` on a pushed `v*` tag, provisioning only what a fresh runner lacks
   (certificate, notary profile, the Sparkle key secret — see the workflow header for the
   secret names).
7. ~~A settings surface for update preferences.~~ Done long since — Settings ▸ General ▸
   Software Updates owns the switch, and Privacy stays about OS grants.

### What remains open

- Does an update need to preserve anything beyond `~/Library/Application Support/Threading`?
  Sparkle replaces the bundle, so the SQLite store and settings survive, but the extension
  helpers' quarantine state is worth checking against a real upgrade — that is one of two pieces
  of this app's state that live outside the usual containers. The other is now the PTY host's
  launchd registration, and that one is answered: it is path-bound, so a wholesale bundle
  replacement leaves it `enabled` and valid (measured 2026-08-23 across an autoinstall-shaped
  swap). The registration surviving is not the same as the *daemon* being upgraded, which is why
  `retire` exists.
- ~~Whether Threading is distributed publicly at all.~~ Decided (2026-08-08): **public**, GPLv3
  (root `LICENSE`; the vendored SwiftTerm and the submodule forks stay MIT under their own
  files; `Service/ThreadingControlPlane/` is FSL-1.1-ALv2 — see the next entry). The model is
  Blink Shell's: the Mac app is free through the Sparkle feed, the iOS companion is a paid App
  Store build that anyone may also build from source — the store price buys the signed,
  updating convenience. The App Store build ships under the copyright holder's own terms, which
  the GPL cannot grant, so outside contributions require the grant in `CLA.md`
  (`CONTRIBUTING.md` says why; wire the CLA-Assistant GitHub app when the first real PR
  arrives). Public was also structurally forced: release assets on a private GitHub repo are
  not anonymously downloadable, so a private repo could never have served `SUFeedURL`. The
  Homebrew cask is now unblocked as a future step — claudex's `publish-homebrew-cask.sh` is the
  template.
- ~~Which license the hosted control plane ships under.~~ Decided (2026-08-19):
  **FSL-1.1-ALv2**, carved out of the repository's GPLv3
  (`Service/ThreadingControlPlane/LICENSE`, taken verbatim from the canonical template with
  only the notice filled in). Two reasons, and the first is the load-bearing one: **GPLv3 has
  no network clause**, so on a Cloudflare Worker it grants nothing. Copyleft triggers on
  distribution, and nobody distributes a Worker — they deploy it. A fork could strip any
  metering from `auth.ts`, host it, and publish nothing while staying fully compliant. Second,
  `docs/OPEN_SOURCE.md` §4 already named the APNs/rendezvous seam as the intended paid surface,
  and §6.1 of that same analysis says the money seam must be licensed before the paywall exists
  rather than after. Doing it now relicenses 3,800 lines of plumbing nobody is attached to;
  doing it once device tiers land in `auth.ts` and `enrollment.ts` would mean relicensing the
  paywall itself, in public, with a GPL copy of it in the history. FSL rather than AGPL because
  AGPL binds only a *modified* fork to publish — it does not stop someone hosting an unmodified
  competing instance, which is the actual exposure. FSL rather than closed because the "no
  transcripts, prompts, or terminal bytes reach the server" claim is the product's
  differentiator, and an unauditable version of that claim is worth much less; FSL permits
  reading, local `npm run dev`, and self-hosting for your own Macs, and converts each version
  to Apache-2.0 after two years. No combined-work question with the GPL app: the Worker is
  TypeScript, `src/protocol.ts` hand-mirrors the contract, nothing links `ThreadingRemoteKit`,
  and the two talk over HTTP. Note the limit — commits of that directory already published
  under GPLv3 stay GPLv3 forever, so this binds new versions only.
- The repository now has its public-distribution `origin`. The release and nightly workflows
  remain dormant until the five GitHub Actions secrets named in `release.yml` are installed;
  the nightly schedule is deliberately disabled until then.
- The iOS companion's pipeline (TestFlight first, the App Store later) is not built. The
  review-context problem — App Review runs the app with no Mac reachable — is answered: the
  welcome screen's **Try the demo** enters a canned Mac (`DemoExperience`,
  `Sources/ThreadingMobile/`) whose script plays the server's half of the session socket
  through the app's real message handler, so the conversation, streaming, terminal, and
  composer all demonstrate themselves standalone. The submission checklist that goes with it:
  state in the App Review notes that no account or hardware is needed because the demo is one
  tap from the first screen, and attach a short video of real pairing (QR scan against a Mac)
  for the parts a reviewer cannot reach. `THREADING_MOBILE_RUNTIME_DEMO=1|session|terminal`
  drives the same runtime demo from the simulator for capturing that material.

Two questions this section used to carry are settled: the claudex key sharing is ended (see
[Keys](#keys--threadings-own-one-manual-step-from-real) — one manual `generate_keys` run
remains), and a dev build no longer schedules checks against the stable feed
(`UpdateFeedPolicy.allowsScheduledChecks`, tested in `UpdateFlowTests`).

## Agent CLI release notices

The same **Check for updates automatically** setting also authorizes a separate daily health
check for installed agent TUIs. Sparkle cannot answer this question: each provider owns its tool,
version scheme, release source and update command. `AgentKind.cliUpdateDefinition` therefore makes
the existing exhaustive five-runtime inventory the catalog: Claude Code (`@anthropic-ai/claude-code`),
Codex (`@openai/codex`), Grok (`@xai-official/grok`) and OpenCode (`opencode-ai`) read their public
npm `latest` documents; Cursor reads the version pinned by its public `cursor.com/install` script.
There is no authentication and no fallback source whose meaning Threading would have to guess.

Local discovery uses the same login-shell path as an agent launch, and for the same reason twice
over. A GUI application inherits none of the user's interactive `PATH`, so the lookup has to happen
inside a login shell — and the npm-published agents install a `#!/usr/bin/env node` launcher, which
cannot resolve its own interpreter outside that environment either. Running the tool directly with
the app's own environment was the first version of this, and it reported `claude` and `codex` as
*broken* on a machine where both work: `env: node: No such file or directory`, exit 127. So
`AgentCLIVersionProbe` puts `command -v` and the version command in **one** login shell per runtime
— one child, not two — with a sentinel distinguishing "not installed" (silence) from "the tool
answered badly" (a logged failure). It is a bounded one-shot child off the main thread: ten seconds
for the profile and the command together, 64 KiB of stdout, inherited agent identity removed.

Only installed tools reach the network. Their HTTPS reads run concurrently with a ten-second
timeout and a 256 KiB response cap enforced against the transfer rather than the result, so a
source that declares no length cannot be downloaded in full and rejected afterwards; a failed or
malformed source is logged and omitted without suppressing good answers from the others. The
catalog is the runtime inventory itself — `AgentCLIUpdateChecker` refuses a longer one instead of
silently truncating to it — so one daily sweep is at most one child process per runtime and one
small request per installed tool: five and five today, constant in projects, accounts, sessions,
files and transcripts. There is no user-data stress fixture to add for a cardinality that cannot
grow with user data.

`AgentCLIUpdateCoordinator` records attempts at a 24-hour cadence, cancels when the shared setting
turns off, and holds a result while the app is inactive or onboarding covers the window. Three
details of that sentence are load-bearing and each was wrong first:

- **The cadence needs a clock of its own.** Threading is left running for days, so "once a day"
  driven only by launch means "once per launch". An hourly poll asks whether the interval has
  elapsed, and returning to the app asks too; both go through the same `checkIfDue`.
- **The attempt is stamped on the answer, not the intent.** Writing it before the work meant that
  switching the setting off and on again — which cancels the in-flight check — had already spent
  the day's attempt, so the user's toggle appeared to do nothing.
- **The receipt is deduplicated on the action, not the presentation.** A fingerprint of
  tool/current/latest versions prevents the same receipt from returning, but it is recorded when a
  terminal actually starts the run. Recorded at presentation, a band that dwelled fourteen seconds
  behind another window, or one whose terminal refused to open, would have silenced those versions
  for ever.

`AppSettingsDidChange` is the shared app-settings notification, so it re-checks the schedule but
deliberately does not flush a held receipt: doing so dropped the band over the Settings pane the
user was working in.

The receipt uses the existing sidebar `Toast` component, remains for the unattended dwell, pauses
under the pointer like every toast, and aligns now/latest values through the toast's generic
comparison table. Checking never starts an updater. Pressing **Update** creates a durable
standalone terminal and sends it one host-built shell command; each provider command is a quoted
argument to its own login-shell child, runs sequentially, and leaves prompts, output and exit-code
receipts visible and interruptible. A failing provider does not suppress the next one. That
command spans several terminal lines, because the `printf` receipts carry real newlines — every
one of them a continuation the shell consumes before it runs anything, and none within the tty's
1023-byte canonical-mode limit (247 bytes at the longest, for a five-tool run).

That host-owned check also makes Threading the central update manager for every Codex process it
starts. Each Codex invocation therefore receives the documented one-run override
`check_for_update_on_startup=false`. Without it, a session restored in the background can stop at
Codex's own update menu before anybody opens the chat, duplicating Threading's receipt and leaving
the conversation unavailable for work. The override is applied to terminal, native and headless
launches so none of their streams can acquire unsolicited startup UI, and it never edits the
account's `config.toml`; Codex launched outside Threading keeps the user's own policy.

The customization-surface decision is deliberately **host-only**. Provider identity, trusted
release-source selection, version precedence and whether Threading may suggest an install command
are integrity behavior the host must own. Presentation is not a new hard-coded surface: it reuses
the theme-native toast extension component, while the host retains source selection, scheduling,
deduplication, trusted command selection and visible-terminal execution.

## Releasing beside the iOS companion

The Mac app and the iOS companion release on different clocks — Sparkle is self-controlled and
fast, the App Store adds review latency measured in days — and the trap is coupling them.
Lockstep version numbers, or any rule of the form "1.4 talks to 1.4", would mean a Mac release
can break installed iOS apps until Apple approves the matching update, which is precisely the
outage a versioning scheme exists to prevent. So the apps' marketing versions stay independent
(the iOS app already keeps its own numbering, and does not ship through Sparkle), and
compatibility hangs on one number pair instead:
`RemoteProtocol.current` / `RemoteProtocol.minimumSupported`
(`Packages/ThreadingRemoteKit/Sources/ThreadingRemoteKit/RemoteProtocol.swift`). Both ends carry the
pair compiled in, exchange it at the handshake, and a mismatch produces a directional "update
the Mac app" / "update this app" sentence (`RemoteUpdateTarget`), never a decode failure three
frames later. The protocol integer is the semver *major* of this relationship; nothing else is.

Three rules, in the order they get used:

1. **Additive changes are free.** A new message or field an old peer ignores bumps nothing.
   The Mac can ship any day; installed iOS apps keep working. This is the default shape of a
   protocol change, and the DTO tests in `RemoteProtocolTests` pin the tolerant-decoding side
   of it (older payloads keep decoding, new fields stay optional).
2. **A breaking change ships as an overlap, never a replacement.** Bump `current`, keep
   speaking the old version too, leave `minimumSupported` alone. Both apps can then release in
   any order, any time apart, and nothing installed breaks — the review-latency race is
   impossible by construction rather than unlikely. When a feature needs both sides, the Mac
   ships first: it is the server, Sparkle delivers it in days, and the iOS build that needs
   the new capability arrives to hosts that already have it.
3. **`minimumSupported` rises last, in its own release, with nothing else riding along** —
   and only after the App Store has delivered the iOS build that speaks the newer version,
   adoption has actually happened, and the Mac side's phased Sparkle rollout (a day per
   phase) has completed. Dropping an old path is never urgent, so this step never has a
   deadline; if it feels urgent, something upstream skipped rule 2.

`RemoteProtocolTests.testProtocolVersionsChangeOnlyThroughTheReleasingChecklist` pins both
numbers, so any change fails a test once, deliberately, and the failure message points back
here. The constants carry the same pointer.
