# Full release agent runbook

Use this file as the entire operating prompt for a Luna agent. Read broader architecture docs
only when a failing step requires a code change.

1. Wait for any work the user named to finish. Stop if another session is still editing this
   checkout. Review `git status --short`, release notes, and the user's publication scope.
   The Mac must be unlocked with its display awake for the visible-window tests. The driver
   checks this before starting, keeps automatic display sleep off for its lifetime, and restores
   normal idle behavior when it exits. It never changes saved settings or unlocks the screen.
   If a submodule changed, test and commit it in its owning repository first, explicitly publish
   the required owning-fork commit, then stage its updated gitlink here. Never push recursively.
2. Pick the next unused stable Mac tag from `gh release list --repo everlof/threading` and add
   its user-facing `CHANGELOG.md` entry. iOS versions are independent; the first version is 1.0.
   Inspect the existing marketing slides with `bundle exec fastlane ios screenshots`; update
   their source document before validation if they no longer represent the app.
3. Run, after the user has requested committing and publishing both apps and App Review:

   ```bash
   python3 scripts/release_all.py vX.Y.Z --commit-all --submit-review
   ```

4. Let the process run. It prints one JSON event per transition and a heartbeat every 45 seconds.
   Do not read successful build logs. If it fails, read the reported log's relevant error, fix the
   cause, and rerun the same command. Never suppress tests or weaken a boundary/baseline to pass.
5. Report the final commit, Mac release URL, iOS version/build and Apple's confirmed review state.
   State any device-only verification not performed. Submission is complete at Waiting for Review;
   approval is Apple's later action. The submitted app is set to manual release after approval.

`--verify-only` runs the full quality gate and GUI journeys without committing or publishing.
`--status` prints checkpoints. Without `--commit-all`, the checkout must already be clean;
without `--submit-review`, the driver ends after TestFlight. Passing these flags represents the
scope already authorized by the user; the script does not ask for it again.

Only when the user explicitly declines further UI automation, add
`--omit-ui-reason "<the user's request>"`. This retains any failed UI checkpoint, records the
omission separately, and reports `ui_verified: false`. Report that limitation with the release;
never use the option merely to get past a failing test. All other gates still run.

The driver checks Docker first, then runs the Linux runner contracts, portable proxy tests and
the complete packaged Linux preview suite. It runs all Mac and iOS test targets,
repository/package/controller/service checks and warning ceilings through `ci.sh --full-release`,
then the app-level XCUITest journeys. Hardware, live-provider, APNs and specialist performance
lanes have their own prerequisites and are not silently reported as covered.

An explicit `THREADING_MOBILE_TEST_DESTINATION` takes precedence. Otherwise the driver creates
an isolated iPhone simulator using an installed profile on the newest available iOS runtime,
and reuses the exact device recorded in `build/full-release/simulator.json`. It does not depend
on a particular iPhone model name or install into a developer's existing simulator. The same
destination reaches the quality gate and Fastlane's later validation.

All nonignored changes are tested before the requested commit. A private temporary index hashes
the complete candidate tree without altering the real index. Checkpoints bind to that tree;
changed input reruns tests. Publication still uses the existing macOS and TestFlight gates. No
publication gate is skipped by a checkpoint from the precommit checks.

Stale remote-host components trigger an explicit, nonrecursive push of the tested outer master
commit, builds/tests for both Linux architectures, publication and download verification, then
another tested commit of the generated manifest. This requires a running Docker engine. No
submodule remote is pushed. The Mac publisher owns tagging, notarization, signed Sparkle feeds,
plugin assets and Sentry symbols. Public SDK verification follows publication.

Local credentials are the existing Keychain, ignored `.release-local/`, `.sentryclirc`, and
`fastlane/.env` setup described in `docs/architecture/releasing.md`. Never print or commit them.
Fastlane's `beta receipt:<path>` records the validated IPA hash, source commit, version and build
number before upload. Retries retain that archive; they never select Apple's changing latest
build. A confirmed upload is never repeated while Apple's build list catches up. An existing
build without a confirmed upload receipt stops for reconciliation rather
than claiming an unrelated upload. `submit_review receipt:<path>` requires the recorded upload
and verifies the exact selected build and review state. Interrupted submissions can be retried.
Before submission the driver uploads the listing, renders the reviewed Marketeer slides at all
required iPhone sizes, and uploads them through Fastlane. Fastlane maps pixel dimensions to
Apple's historical display groups and verifies processing and checksums. The source document
stays unchanged. `bundle exec fastlane ios screenshots_status` reads Apple's actual states.

Logs and receipts live in ignored `build/full-release/<tag>/`. Keep them until the release is
finished. One checkout-wide lock prevents two drivers from publishing concurrently. The lock
does not prevent a human or another agent from editing; snapshot checks refuse that race.

App Privacy answers and account agreements may require App Store Connect's website. Use the
app's existing privacy manifest and architecture contract as the source; never invent answers.
If Apple refuses submission, preserve the error and fix the specific missing requirement. Do
not cancel someone else's submission or replace an already published version.
