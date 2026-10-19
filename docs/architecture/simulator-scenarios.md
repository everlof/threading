# Simulator scenarios

A project can declare the states its app's debug build knows how to open — a screen with sample
data, a theme, a step in a flow — in `.threading/scenarios.json`. The Simulator workspace then
opens any of them on every device it holds at once, iOS and Android side by side, and steps a flow
forward and back while the app runs, so the person sees each transition the app's users would.
An agent reaches the same thing through `simulator_scenario`.

Part of the [CLAUDE.md](../../CLAUDE.md) index. Read [`simulator-pane.md`](simulator-pane.md) for
the workspace, leases and the public-transaction rule, and [`android-devices.md`](android-devices.md)
for the Android plane.

## The file

`.threading/scenarios.json` at the session checkout's repository root (a session in a
subdirectory reads the same file). The editor schema is
[`docs/schemas/threading-scenarios.schema.json`](../schemas/threading-scenarios.schema.json);
`SimulatorScenarioGuide.example` is a complete file, and a test decodes it.

```json
{
  "version": 1,
  "apps": {
    "ios": { "bundleIdentifier": "com.example.shop", "urlScheme": "exampleshop" },
    "android": { "package": "com.example.shop", "activity": ".DebugScenesActivity", "urlScheme": "exampleshop" }
  },
  "scenarios": [
    { "id": "home/empty", "group": "Home", "title": "Home", "variant": "Empty",
      "launch": { "ios": ["-scene", "home", "-fixture", "empty"], "android": { "scene": "home", "fixture": "empty" } } },
    { "id": "order/delivery", "group": "Orders", "title": "Order from cart to delivery",
      "launch": { "ios": ["-scene", "order"], "android": { "scene": "order" } },
      "stepInterval": 1.5,
      "steps": [
        { "title": "Cart with three items", "link": "debug/step?n=0" },
        { "title": "Payment accepted", "link": "debug/step?n=1" }
      ] }
  ]
}
```

- `apps` names the app per platform: a bundle identifier, or a package and the debug activity
  Threading starts; `urlScheme` is the app's own scheme for step links.
- A scenario has an `id`, a `group` and `title` for the menu, an optional `variant` (scenarios that
  share a title in a group become one row with a submenu of variants) and an optional
  `appearance` that switches the device to light or dark first.
- `launch.ios` is launch arguments; `launch.android` is intent extras, typed by their JSON value
  (text `--es`, true/false `--ez`, whole numbers `--ei`/`--el`). A scenario is offered only on the
  platforms its launch names.
- `steps` is 2–64 states in order, each a title and a link relative to `urlScheme`. The launch opens
  the first; only the first may omit its link, and going back to it then starts the app again.

Like `.threading.json`, the version is exactly 1, unknown fields are errors so a misspelling cannot
look supported, and every bound is applied before or while decoding: a non-symlink regular file
inside the checkout of at most 1 MiB, 512 scenarios, 64 launch values and 64 steps each, bounded
text, and 16 diagnostics. A broken scenario is reported in the menu while the valid ones beside it
stay offered.

## Delivery

Choosing a scenario starts the installed app: `simctl launch --terminate-running-process` with the
arguments, or `am start -W -S -n <package>/<activity>` with the extras. Both first check that the
app is installed (`simctl get_app_container … app`, `pm path`) so a missing app is named as such
rather than as an `FBSOpenApplicationService` error. Starting an app is a public device mutation,
so it follows the pane's rule from [`simulator-pane.md`](simulator-pane.md#backend-boundary): the
direct stream stops for the bounded command and reconnects after it.

A step is delivered to the running app without starting it again, and without stopping the stream,
because seeing the change happen is the point:

- **Android**: `am start -W -a android.intent.action.VIEW -d <url> -f 0x20000000 -n
  <package>/<activity>`. `FLAG_ACTIVITY_SINGLE_TOP` hands the intent to the activity already on top,
  in `onNewIntent`.
- **iOS**: not `simctl openurl`. For a custom scheme iOS answers every call with an “Open in
  “App”?” alert (measured on iOS 26 with Xcode 26.5: the alert came back on each of three calls), so
  stepping would mean answering a system alert per step. Instead Threading writes the URL into the
  app's own `tmp/codes.threading.scenario-link` (the data container from `simctl get_app_container
  … data`) and posts the Darwin notification `codes.threading.scenario.link` with `simctl spawn
  <udid> notifyutil -p`. The app's debug build reads the file and hands the URL to its own link
  handling. Both commands returned in under 0.2 s while the pane's direct helper kept streaming, so
  a step is not a public transaction.

The file is written atomically, only into a container whose path CoreSimulator reported for that
exact device, and only when the app's `tmp` is a real directory: the app owns it and could have
made it a symbolic link out of its container.

Steps for one scenario are serialized: a quick run of Next presses reaches every device in order,
however long one delivery takes. Devices of one step are driven at once, so an iPhone and an
Android phone change together. A failure names its device and stops Play; the other devices still
move.

## The app's side

The app needs a debug-only way to read the launch input (launch arguments in `UserDefaults` or
`ProcessInfo`; extras in an exported debug activity) and, for steps, the two receivers in
`SimulatorScenarioGuide` (`iOSReceiver`, `androidReceiver`). A step should go through the same
state updates real data would cause so the screen animates as it ships; going back may reset to the
first step without animation and then apply the target. Scenario Help's **Copy Agent Prompt** hands
all of this to an agent working in the project, including how to generate the file from the app's
own fixture list and how to check the result with `simulator_scenario`.

## Surface

The workspace header shows a **Scenarios** button for a session with a checkout. With no file it
opens Scenario Help, the same panel shape as Device Logs' Bluetooth definitions help: what
scenarios are, what Threading found, a reference, the example, and Create File, Copy Example and
Copy Agent Prompt. With a file it reads it again and opens a menu: groups as submenus once there is
more than one, variants as a row's submenu, the open scenario checked, problems listed by message,
and Scenario Help at the bottom.

Scenario Help rederives its status and feedback ink and remeasures the fixed reference columns
when the theme or appearance changes. The popover then fits the current typography. The live
theme-switch render check covers readable status pixels and unclipped reference terms and action
labels under System, Cyberpunk and Swiss Minimalist.

A scenario with steps shows a `PaneNoticeView` band between the header and the devices, pushing
them down: the scenario's title, “Step 2 of 4: Payment accepted”, and Back, Next and Play (Pause
while playing; Play at the last step starts over), with ✕ to close the scenario, which leaves the
app as it is. Back and Next rest at the ends. The band is rebuilt on each change, so VoiceOver hears
each new step; keyboard focus on one of its buttons moves to the same button of the new band. A
refused choice or a device that failed shows in the band in the attention tone.

The palette has Simulator Scenarios…, Next Scenario Step, Previous Scenario Step and Play or Pause
Scenario, with no default shortcuts.

**Scaling.** One bounded file read off the main actor when the menu or the help opens, never on a
timer and with no watcher; the menu (at most 512 rows) is built when it opens; the band is one fixed
view. Applying a step is O(devices), at most four.

**Customization.** Host-only, like the rest of the workspace: Threading owns the file's discovery
and bounds, the interpretation of launches and links, device targeting, the public-transaction
rule, the link drop's location checks and the band's state. Themes style the button, menu, band and
help through the shared components; the file declares data and cannot add controls or run code.

## Agent route

`simulator_scenario` with no arguments lists what the workspace's devices can open (and the open
scenario, and the file's problems); with `scenario` it opens one on every device that can show it,
or only `device_id`, and with `step` it goes on to that step; with `step` alone it steps the open
scenario in place. It drives the same controller as the band, so the person sees what the agent
opened. The result names the devices that changed and any that failed; every device failing is an
error.
