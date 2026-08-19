# Threading

A native macOS app for working with coding agents — Claude Code, Codex, Grok, and OpenCode —
in one window: a project sidebar, real terminals, and an experimental native chat surface that
renders conversations, tool calls, diffs, and permission requests as first-class UI. Sessions
outlive their processes, so a conversation can be closed and resumed later, moved between
accounts, or continued with another provider.

An iOS companion pairs with your Mac by QR code and drives the same sessions from your phone:
live conversations, the terminal, git review, and permission approvals, over your own tunnel
or tailnet. Nothing goes through a third-party server.

## Install

**macOS** — download the latest `Threading-x.y.z.zip` from
[Releases](https://github.com/everlof/threading/releases). The app is Developer ID signed,
notarized, and updates itself through Sparkle from the same releases feed.

**iOS** — the companion is a paid app on the App Store. It is also fully buildable from this
repository (see below): the price buys the convenience of a signed, updating build, not the
code. Buying it is what funds this project.

## Build from source

The project is Xcode-only — one `Threading.xcodeproj`, no root SwiftPM manifest.

For the complete cloud-free development environment, run:

```bash
./dev
```

That starts the loopback control plane, builds and opens an isolated Debug Mac app, then builds,
installs and opens the iOS app in an available iPhone Simulator. It installs the control-plane
Node dependencies when needed. Use `./dev --no-ios` for Mac-only work or `./dev --backend-only`
for the service alone; `./dev --help` lists the remaining options. Ctrl-C stops the backend but
leaves the apps open so an active local agent session is never terminated implicitly.

```bash
# The Mac app
xcodebuild -project Threading.xcodeproj -scheme Threading -configuration Debug build
open "$(ls -dt ~/Library/Developer/Xcode/DerivedData/Threading-*/Build/Products/Debug/Threading.app | head -1)"

# The iOS companion (simulator; a device needs your own signing team)
xcodebuild -project Threading.xcodeproj -scheme ThreadingMobile \
  -destination 'generic/platform=iOS Simulator' build

# Tests
scripts/test.sh          # fast: everything that keeps windows off screen
scripts/test.sh all      # the whole suite
```

Targets macOS 13+. The submodules under `Packages/Vendor/` (`ThinkingOrbs`, `LabelMorph`, and
`BorderBeamKit`) are cloned with `git clone --recurse-submodules`; SwiftTerm is vendored beside
them. First-party Swift packages live directly under `Packages/`, and auxiliary executables live
under `Targets/`.

## Documentation

- [`USER_GUIDE.md`](USER_GUIDE.md) — every user-facing feature and shortcut.
- [`docs/architecture/`](docs/architecture/) — one file per subsystem, recording the decisions
  and measurements behind it. Read the relevant file before changing a subsystem; the index is
  [`CLAUDE.md`](CLAUDE.md).
- [`docs/feature-drafts/`](docs/feature-drafts/) — researched proposals that are not committed
  product behavior yet; its README is the single priority index for those drafts.

## Licensing

The repository is licensed under the **GNU GPLv3** (see [`LICENSE`](LICENSE)), with these
carve-outs, each under its own terms:

- `Service/ThreadingControlPlane/` — the hosted rendezvous service, under the
  [Functional Source License](https://fsl.software) (FSL-1.1-ALv2, its own `LICENSE`). Read it,
  modify it, run it for your own Macs; you may not offer it as a competing service. Each version
  becomes Apache-2.0 two years after it is made available.
- `Packages/Vendor/SwiftTerm/` — a vendored fork of [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm),
  MIT (its `LICENSE` file governs that tree).
- `Packages/Vendor/ThinkingOrbs/`, `Packages/Vendor/LabelMorph/`, and
  `Packages/Vendor/BorderBeamKit/` — submodule forks, each MIT under its own
  `LICENSE`.
- `Sources/Threading/Resources/Fonts/` — open-licensed fallback fonts; provenance and license
  per family in its `*-SOURCE.md`.

The App Store build of the iOS companion is distributed by the copyright holder under the App
Store's terms rather than the GPL — which is why contributions require the lightweight
agreement described in [`CONTRIBUTING.md`](CONTRIBUTING.md).

The control plane is the one component with a running cost and an operator, so it is the one
component under a license that prevents a competing hosted instance. It stays readable on
purpose: the claim that no transcript, prompt, or terminal byte reaches the server is only worth
something if you can check it.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) — including the build gates (the repository enforces
its architecture, theme, and localization boundaries at build time), the test levels, and the
contributor license agreement.
