# Notification end-to-end tests

Notification E2E tests deliberately live in the separate
`ThreadingNotificationE2E` target and scheme. The standard `Threading` scheme does not reference
that target, so an ordinary `xcodebuild test` cannot contact APNs, launch Claude, or spend agent
usage.

## What the tests prove

- `testAPNsAcceptsPermissionNotification` signs a real provider request, sends a permission
  notification to Apple, and requires HTTP 200 plus an `apns-id` receipt.
- `testClaudeNotifyUserToolReachesAPNs` launches the installed Claude Code CLI for one short
  turn, connects it to Threading's real loopback MCP server, requires one correctly routed
  `notify_user` call, forwards that call to APNs, and waits for Claude to receive the tool result
  and finish its turn.

The first test sends one push. The Claude test sends one more push only when `--claude` is
passed. Apple accepting a push proves the provider flow; the phone is still the final visual
check because Focus, notification summaries, and foreground state can affect presentation.

## One-time setup

1. Install and run a Debug build of Threading on a physical iPhone.
2. Complete the notification onboarding and leave **Permission requests** and **Agent updates I
   request** enabled.
3. Open Settings → Notifications in the debug app and tap **Copy APNs test token**.
4. Have an Apple APNs `.p8` key, its key ID, and the owning team ID available locally.
5. For the Claude test, make sure `claude` is installed, authenticated, and the Notifications
   tool group is enabled in the Mac app.

Development builds use the APNs sandbox. A TestFlight/App Store token requires
`THREADING_E2E_APNS_ENVIRONMENT=production`.

## Run

Set the following variables in the invoking shell or through a local secret manager. Never
commit the `.p8` key or device token.

```sh
export THREADING_APNS_KEY_ID="your-key-id"
export THREADING_APNS_TEAM_ID="your-team-id"
export THREADING_APNS_PRIVATE_KEY_PATH="/absolute/path/to/AuthKey.p8"
export THREADING_APNS_TOPIC="codes.threading.mobile"
export THREADING_E2E_APNS_DEVICE_TOKEN="token-copied-from-the-debug-app"
export THREADING_E2E_APNS_ENVIRONMENT="sandbox"
```

Test the provider directly, with no model usage:

```sh
bash scripts/run_notification_e2e.sh
```

Test the complete Claude → MCP → APNs flow as well:

```sh
bash scripts/run_notification_e2e.sh --claude
```

`THREADING_E2E_CLAUDE_MODEL` can optionally name a low-cost model available to the configured
Claude account. If omitted, Claude Code uses that account's default.

Both forms are also reachable as the `e2e` level of `scripts/test.sh` — `scripts/test.sh e2e`
and `scripts/test.sh e2e --claude` forward straight to this script. See "Test levels" in
CLAUDE.md for the other two levels.

Missing credentials cause the wrapper to stop before Xcode starts. Running the E2E scheme
directly from Xcode is also safe: tests whose explicit environment is missing report as skipped
instead of attempting a partial delivery.
