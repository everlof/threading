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

Nine binaries pass today: `Threading`, its three helpers, and Sparkle's five — `Sparkle`,
`Autoupdate`, `Updater`, `Downloader` and `Installer`. The loop is a `find` over the bundle
rather than a list, which is why adding Sparkle needed no change to it.

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
helper, the export signs all ten executables (five app-side, five Sparkle) as Developer ID,
hardened and timestamped. The release gate separately verifies that `Contents/Helpers/scc` is
the expected universal version after signing.

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
  helpers' quarantine state is worth checking against a real upgrade — that is the one piece of
  this app's state that lives outside the usual containers.
- ~~Whether Threading is distributed publicly at all.~~ Decided (2026-08-08): **public**,
  GPLv3 (root `LICENSE`; the vendored SwiftTerm and the submodule forks stay MIT under their
  own files). The model is Blink Shell's: the Mac app is free through the Sparkle feed, the
  iOS companion is a paid App Store build that anyone may also build from source — the store
  price buys the signed, updating convenience. The App Store build ships under the copyright
  holder's own terms, which the GPL cannot grant, so outside contributions require the grant
  in `CLA.md` (`CONTRIBUTING.md` says why; wire the CLA-Assistant GitHub app when the first
  real PR arrives). Public was also structurally forced: release assets on a private GitHub
  repo are not anonymously downloadable, so a private repo could never have served
  `SUFeedURL`. The Homebrew cask is now unblocked as a future step — claudex's
  `publish-homebrew-cask.sh` is the template.
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
