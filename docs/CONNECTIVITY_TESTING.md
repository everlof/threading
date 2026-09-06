# Connectivity resilience testing

Connectivity has three different failure domains, so one test style cannot make the release
claim on its own:

1. **Software contracts** make deadlines, reconnect backoff, single-flight refresh, route races,
   the route the sockets take, hosted tunnel lifetime, trust, discovery and listener lifecycle
   deterministic. Run `scripts/test-connectivity.sh
   software` and `scripts/test-connectivity.sh topology`; the client half runs in an iOS
   Simulator. Those simulator phases take the shared host-wide CoreSimulator lane before invoking
   Xcode, so evidence, dogfood and chaos lanes cannot shut down their device mid-run.
2. **Two shipping apps under process faults** must launch the ordinary macOS and iOS products,
   pair them in disposable state, and kill either process at named protocol checkpoints. This
   complete lane is not yet automated. `simulator-chaos` covers the real Debug ThreadingMobile
   process and real sockets now, but its isolated Mac endpoint is an XCTest-hosted shipping server
   rather than the macOS app process, so it is deliberately not evidence for the full claim.
3. **Physical topology** covers actual radios, device suspension, cellular handoff, VPN/Tailscale,
   NAT and conditioned networks. Run the physical hardware lane below. Its results are evidence for
   the exact device and topology used, not a replacement for the first two lanes.

## Simulator process-chaos lane

Run the real Debug ThreadingMobile product against an isolated instance of Threading's
HTTP/WebSocket server,
then alternate `SIGKILL` and `SIGABRT` while the refresh and events socket are connected. A final
case freezes the server, waits until the next app process records `hostRefreshStarted`, aborts that
in-flight process, resumes the server and requires another clean connection:

```bash
scripts/test-connectivity.sh simulator-chaos
scripts/test-connectivity.sh simulator-chaos --cycles 10
```

The default run creates and later deletes a fresh iPhone Simulator, so it cannot overwrite an
installed app or paired state in a developer's normal simulator. Every relaunch must add a new
`hostRefreshSucceeded` and events `socketConnected` record to the app's durable share-safe
journal. `--simulator <UDID>` deliberately reuses an explicit device instead. Build products are
incrementally cached under `.build/connectivity-simulator-derived-data`; override that location
with `THREADING_CONNECTIVITY_DERIVED_DATA` when a runner provides its own cache volume.

This is real client-process and wire coverage, including abnormal termination and state survival
inside the simulator app container. It does not kill the macOS product, exercise TLS pairing or
Keychain persistence, or reproduce physical radio and suspension behavior. Those remain separate
release claims.

## Physical-device lane

List available devices, then select one explicitly:

```bash
scripts/connectivity-hardware.sh --list-devices
scripts/test-connectivity.sh hardware --device "My iPhone" --scenario all
scripts/test-connectivity.sh hardware --device "My iPhone" --scenario automatic --non-interactive
```

The app must already be installed and paired with a Mac whose Remote Access is enabled. The
runner never installs or erases the app and does not modify its Keychain. Apple CoreDevice tooling
foregrounds, suspends, resumes and SIGKILLs only the selected app. It also copies
`Library/Application Support/Threading/Diagnostics` from the app container after each step.

`automatic` runs the smoke, SIGKILL/relaunch, and suspend/resume scenarios without prompts. The
phone must start unlocked, remain attached, and already be paired; the Mac must stay awake and
reachable. This makes the lifecycle subset suitable for an unattended local soak or a dedicated
device runner, although a locked phone, trust dialog, cable failure, or sleeping Mac will still
produce an ordinary bounded test failure. Change the default ten-second freeze with
`--suspend-seconds`.

Radio controls are deliberately guided. Public `devicectl` has app lifecycle and file-copy
commands, but no arbitrary touch or Wi-Fi/airplane-mode command. Meta's `idb` exposes tap, swipe
and text primitives for the Simulator; its device support is only a restricted HID subset and
general physical-device taps remain unavailable. An on-device XCUITest runner is the supported
route for automating app UI on a real phone. Until Threading has that UI-test target, the operator
makes the system-setting changes and pulls to refresh when prompted.

Each scenario step is a checkpoint, not a timer. The script repeatedly copies the share-safe JSONL
journal under a fixed deadline and passes only after a new matching event appears:

| Scenario | Controlled fault | Required evidence |
|---|---|---|
| `automatic` | smoke, SIGKILL/relaunch and suspend/resume in sequence | all three lifecycle checkpoints below |
| `smoke` | terminate existing app and foreground it | new refresh success and events WebSocket hello |
| `kill` | SIGKILL iOS, then relaunch | new refresh success and events WebSocket hello after the kill marker |
| `suspend` | suspend and resume iOS | new `hostRefreshSucceeded` after resume |
| `airplane` | guided Airplane Mode on/off | bounded `hostRefreshFailed`, then `hostRefreshSucceeded` |
| `handoff` | guided Wi-Fi off/on | non-LAN `hostRefreshSucceeded`, then recovery with Wi-Fi |
| `conditioned` | guided Network Link Conditioner on/off | terminal refresh result under impairment, then success |

A refresh after a resume is usually **conditional** now: one request on the route that answered
last, carrying the catalogue edition in hand, answered `304` when nothing changed
(`MobileRefreshPolicy`, [`REMOTE_ACCESS.md`](REMOTE_ACCESS.md)). It still records
`hostRefreshStarted` and `hostRefreshSucceeded` — with `status: 304` rather than `200` — so every
checkpoint above keeps its marker. A dashboard that merely comes back on screen while the event
socket is healthy records nothing, because it asks nothing; a lane that needs a refresh must
suspend, kill, or cut the network, all of which end the socket.

The default evidence root is `.build/connectivity-hardware/<UTC stamp>/`. It contains every
`devicectl` JSON result, the copied journal and the exact record that satisfied each checkpoint.
On failure, the runner prints the post-marker timeline and leaves the evidence intact.

Use `--scenario` to run one case and `--timeout` to raise the per-checkpoint deadline for a very
slow profile. A conditioned run may succeed or fail while impairment is active; the contract is
that it reaches a terminal result and succeeds again after the conditioner is disabled.

## What simulator software can and cannot trigger

Simulator automation can launch and kill both app processes, drive app UI, revoke supported TCC
permissions and inject deterministic transport failures behind Threading's existing seams. It
cannot faithfully create a real cellular carrier path, radio firmware transition, physical lock
and deep suspension, an arbitrary home-router/NAT topology, or a true Wi-Fi-to-cellular handoff.
The status-bar airplane icon is cosmetic, and `simctl` does not publish a network or Airplane Mode
toggle. Those cases stay in the physical lane.

For release sweeps, use Apple's Network Link Conditioner on a physical device and include at least
good Wi-Fi, high latency/loss, cellular with Wi-Fi disabled, IPv6-capable service, Tailscale/VPN,
and one network where local discovery is unavailable. Record the device/OS and topology beside
the preserved evidence directory.

References: [idb UI automation](https://fbidb.io/docs/idb/ui/), [idb physical-device UI limitation](https://github.com/facebook/idb/issues/836), [Apple: Testing a release build](https://developer.apple.com/documentation/Xcode/testing-a-release-build).
