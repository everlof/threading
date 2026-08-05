# Releasing & Automatic Updates

How a distributable Threading.app is produced, and how Sparkle updates it. Sparkle is wired in:
`AppUpdater` is the only file that imports it, the switch is Settings ▸ General ▸ Software
Updates, and what an update check reveals is on the Privacy page. What remains planned rather
than done is the custom `SPUUserDriver` — see [The UI is ours](#the-ui-is-ours-with-one-documented-exception).

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
the dotted-digits guard and Sparkle's ordering within the feed. The nightly *pipeline* (a
scheduled workflow that runs `ci.sh`, skips an unmoved `master`, and needs the Developer ID
certificate, notary credentials and the Sparkle private key as CI secrets) is not built yet;
its open questions live below.

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

**It brings five nested executables**, all of which notarization inspects:
`Autoupdate`, `Sparkle`, `Updater.app/Contents/MacOS/Updater`, and the `Downloader.xpc` and
`Installer.xpc` services. `scripts/release.sh` verifies them without modification, because its
check is a `find` over the bundle rather than a list of known binaries — the export signs all
nine (four app-side, five Sparkle) as Developer ID, hardened and timestamped.

### The UI is ours, with one documented exception

`SPUStandardUpdaterController` brings Sparkle's stock alert, progress and release-notes windows.
That is third-party AppKit chrome inside an app whose whole design system exists to prevent
exactly that, and `docs/THEME_BOUNDARY.md` forbids feature code from reaching stock controls at
all. So the standard driver is not the plan; it is at most a scaffold to delete.

**`SPUUserDriver` is a full replacement, not a set of hooks.** Implement it and drive
`SPUUpdater` directly:

```swift
SPUUpdater(hostBundle:applicationBundle:userDriver:delegate:)
```

Every stage becomes ours: permission request, check-in-progress, update found, release notes,
download progress, extraction progress, ready-to-install, installing, installed, errors, and
dismiss. Nearly all of its methods are required — `showUpdateInFocus` is the only one explicitly
optional — which is the honest cost: the protocol is the whole lifecycle, not a themeable alert.

The mapping onto existing components is direct, which is what makes this affordable: the update
alert is a themed sheet, download and extraction are `ThemedProgressBar`, release notes render in
the display panel's web view, and "Check for Updates…" is an `AppCommand` like everything else,
so it picks up a keyboard binding for free.

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

### Keys — reusing the existing one

**Do not run `generate_keys`.** A Sparkle EdDSA key already exists in the login keychain and
Threading reuses it:

```
service:       https://sparkle-project.org
account:       mjukis-claudex
SUPublicEDKey: 1oYHD7FlQLUy7qQc9NISuCUFzscHMjMnk5Sm6d3/noM=
```

That is the claudex key. Sharing one keypair across both apps is a deliberate choice and works
without ceremony — the feed URL is per-app and the public key is baked into each bundle — but it
means the two share a blast radius: whoever can sign an update for one can sign one for the
other. The account name stays `mjukis-claudex` rather than being renamed, because renaming a
keychain account that claudex signs against would break claudex's releases for no gain.

Every tool needs the account named explicitly, since it is not the default global one:

```
sign_update --account mjukis-claudex <archive>
generate_appcast --account mjukis-claudex <release-dir>
generate_keys -p --account mjukis-claudex        # re-print the public key
```

**Lose this key and no existing install of either app can be updated again** — a new key means
every user reinstalls by hand. `generate_keys -x <file> --account mjukis-claudex` exports it
(base64 of the 32-byte private seed) for an offline backup; `-f <file>` imports it on a second
machine. For CI, pipe it from a secret rather than the deprecated `-s` flag:

```
echo "$SPARKLE_PRIVATE_KEY" | ./sign_update --ed-key-file - <archive>
```

### Steps

0. ~~Give `CFBundleVersion` a real incrementing value.~~ Done — see
   [The version is injected, not committed](#the-version-is-injected-not-committed). Tag a
   release (`git tag v1.1.0`) and `release.sh` carries the number into both fields.
1. Add the Sparkle package, pinned; set `Runpath Search Paths` to `@loader_path/../Frameworks`.
2. Back up the existing private key (above) before anything is published.
3. Info.plist: `SUFeedURL` (HTTPS, non-negotiable under ATS), the existing `SUPublicEDKey`, and
   `SUEnableAutomaticChecks`.
4. Wire the updater with a custom `SPUUserDriver`. There is no MainMenu.xib here
   (`NSMainNibFile` is empty), so the nib route in Sparkle's docs does not apply — construct
   `SPUUpdater` in code and hang "Check for Updates…" off the app menu as an `AppCommand`.
5. Extend `scripts/release.sh`: run `generate_appcast --account mjukis-claudex` over the release
   directory (it signs the archives, writes `appcast.xml`, and produces delta updates), then
   publish the zips and the appcast together. It runs *after* the notarize-and-staple step, since
   the zip has to be rebuilt from the stapled bundle and re-signing a changed archive would
   otherwise invalidate the appcast's signature.
6. Host the appcast and archives over HTTPS. Whatever serves them is now part of the app's
   trusted surface — a compromised feed is only stopped by the EdDSA signature, which is the
   reason `SUPublicEDKey` is baked into the bundle.
7. A settings surface for update preferences belongs on a page; General is the natural home, and
   Privacy should stay about OS grants.

### Open questions before starting

- Does an update need to preserve anything beyond `~/Library/Application Support/Threading`?
  Sparkle replaces the bundle, so the SQLite store and settings survive, but the extension
  helpers' quarantine state is worth checking against a real upgrade — that is the one piece of
  this app's state that lives outside the usual containers.
- Whether Threading is distributed publicly at all, or only to a handful of machines. A private
  feed changes nothing technically but makes the Homebrew cask and website steps moot.
- **Whether the claudex key sharing survives open-sourcing and nightly CI.** The shared keypair
  above was chosen when both apps signed on one private machine. A nightly pipeline puts the
  private key in GitHub Actions secrets of a public repository, which extends *claudex's* blast
  radius to anyone who compromises Threading's CI. Nothing has shipped through Sparkle yet, so
  the "lose this key and no install updates again" constraint has not started — minting
  Threading its own EdDSA key is free today and impossible after the first published build.
  Decide before anything publishes.
- A dev build (`0.0.0`) that checks the stable feed will be offered every release as an
  "update" forever. Harmless until the feed exists; once it does, `AppUpdater` probably wants
  to leave scheduled checks off for `.dev` builds while keeping the explicit menu command.
