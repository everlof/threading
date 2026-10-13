import Foundation

/// What a project needs to offer scenarios: a complete example file, a compact reference, the two
/// receivers an app adds to its debug build for steps, and a prompt that hands the job to a coding
/// agent working in the same checkout.
///
/// One source for the Simulator workspace's Scenario Help panel, the file its Create File writes,
/// and `docs/architecture/simulator-scenarios.md`. `SimulatorScenarioCatalogTests` decodes
/// `example` and checks that both receivers name the link drop's constants, so neither can drift
/// from what Threading reads and sends.
enum SimulatorScenarioGuide {
    static let example = """
        {
          "version": 1,
          "apps": {
            "ios": { "bundleIdentifier": "com.example.shop", "urlScheme": "exampleshop" },
            "android": { "package": "com.example.shop", "activity": ".DebugScenesActivity", "urlScheme": "exampleshop" }
          },
          "scenarios": [
            {
              "id": "home/empty",
              "group": "Home",
              "title": "Home",
              "variant": "Empty",
              "launch": {
                "ios": ["-scene", "home", "-fixture", "empty"],
                "android": { "scene": "home", "fixture": "empty" }
              }
            },
            {
              "id": "home/full-dark",
              "group": "Home",
              "title": "Home",
              "variant": "Many items, dark",
              "appearance": "dark",
              "launch": {
                "ios": ["-scene", "home", "-fixture", "full"],
                "android": { "scene": "home", "fixture": "full" }
              }
            },
            {
              "id": "order/delivery",
              "group": "Orders",
              "title": "Order from cart to delivery",
              "launch": {
                "ios": ["-scene", "order", "-step", "0"],
                "android": { "scene": "order", "step": 0 }
              },
              "stepInterval": 1.5,
              "steps": [
                { "title": "Cart with three items", "link": "debug/step?n=0" },
                { "title": "Payment accepted", "link": "debug/step?n=1" },
                { "title": "Courier on the way", "link": "debug/step?n=2" },
                { "title": "Delivered", "link": "debug/step?n=3" }
              ]
            }
          ]
        }

        """

    /// The iOS half of steps, for the app's debug build.
    static let iOSReceiver = """
        #if DEBUG
        import Foundation

        /// Threading scenario steps. Threading writes the step's URL to
        /// tmp/\(SimulatorAppLinkDrop.fileName) and posts the Darwin notification
        /// \(SimulatorAppLinkDrop.notificationName) inside the Simulator.
        enum ThreadingScenarioLinks {
            @MainActor private static var handle: ((URL) -> Void)?

            /// Call once at launch, e.g. ThreadingScenarioLinks.start { url in router.open(url) }.
            @MainActor static func start(_ handler: @escaping (URL) -> Void) {
                handle = handler
                CFNotificationCenterAddObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(), nil,
                    { _, _, _, _, _ in DispatchQueue.main.async { ThreadingScenarioLinks.deliver() } },
                    "\(SimulatorAppLinkDrop.notificationName)" as CFString, nil, .deliverImmediately
                )
            }

            @MainActor private static func deliver() {
                let file = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("\(SimulatorAppLinkDrop.fileName)")
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                try? FileManager.default.removeItem(at: file)
                handle?(url)
            }
        }
        #endif
        """

    /// The Android half of steps, in the debug activity `apps.android.activity` names.
    static let androidReceiver = """
        // src/debug/AndroidManifest.xml: <activity android:name=".DebugScenesActivity" android:exported="true" />
        // Threading starts it with `am start -S -n <package>/<activity>` and one extra per launch.android key,
        // and delivers a step with `am start -a android.intent.action.VIEW -d <url> -f \(AndroidControlDefaults.singleTopFlag)`.
        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            val scene = intent.getStringExtra("scene")
            val step = intent.getIntExtra("step", 0)
            // …open the scene with fixture data, at that step
        }

        override fun onNewIntent(intent: Intent) {
            super.onNewIntent(intent)
            setIntent(intent)
            intent.data?.let { url -> openStep(url) }   // exampleshop://debug/step?n=2
        }
        """

    struct Reference: Equatable {
        let term: String
        let detail: String
    }

    static let reference: [Reference] = [
        .init(term: "File", detail: "<project>/\(SimulatorScenarioDefaults.relativePath), committed with your app."),
        .init(term: "apps", detail: "ios: bundleIdentifier and urlScheme. android: package, activity (the debug activity Threading starts) and urlScheme."),
        .init(term: "Scenario", detail: "id, group, title; optional variant (one title's variants share a row) and appearance (light or dark)."),
        .init(term: "launch.ios", detail: "Launch arguments, such as [\"-scene\", \"home\"]; read them from UserDefaults or ProcessInfo."),
        .init(term: "launch.android", detail: "Intent extras: text, true or false, or a whole number."),
        .init(term: "steps", detail: "2–64 states in order, each a title and a link relative to urlScheme. The launch opens the first."),
        .init(term: "Steps on iOS", detail: "Threading writes the link to the app's tmp/\(SimulatorAppLinkDrop.fileName) and posts \(SimulatorAppLinkDrop.notificationName), so there is no “Open in” prompt."),
        .init(term: "Steps on Android", detail: "A VIEW intent with FLAG_ACTIVITY_SINGLE_TOP reaches the running activity's onNewIntent."),
        .init(term: "Transitions", detail: "Apply a step through the app's own state updates so it animates; going back may reset first."),
        .init(term: "Agents", detail: "simulator_scenario lists, opens and steps scenarios on the devices in the workspace."),
    ]

    static let explanation = L10n.string("Scenarios open your app in states it declares: a screen with sample data, a theme, a step in a flow. Threading starts the app on every device in the workspace with the scenario's launch arguments, and steps through a flow while the app runs so you see each transition. The app needs a debug-only way to read them; Copy Agent Prompt asks an agent to add it.")

    /// A prompt for a coding agent working in the same checkout.
    static func agentPrompt(path: String) -> String {
        """
        Add Threading scenarios to this app: a debug-only way to open it in named states, listed in \(path), so Threading's Simulator workspace can open any state on an iOS Simulator and an Android device side by side, and step through a flow to show its transitions.

        1. Find what the app already has for showing itself in a given state without a server: SwiftUI or Compose previews with fixture data, UI-test launch arguments, a debug menu, a showcase or catalog screen, screenshot or snapshot test fixtures, mock repositories. Reuse those fixtures; do not invent a second set of sample data.
        2. Add a debug-only entry point, compiled out of release builds, that reads the launch input and opens that state with fixture data and no network:
           - iOS: launch arguments, such as `-scene home -fixture empty` (they arrive in `UserDefaults.standard`, `scene` = `home`, and in `ProcessInfo.processInfo.arguments`).
           - Android: an exported debug activity declared in `src/debug/AndroidManifest.xml`, reading intent extras (`getStringExtra`, `getIntExtra`, `getBooleanExtra`). Threading starts it with `am start -S -n <package>/<activity>` and one extra per key in `launch.android`.
           Keep the platforms 1:1: one scenario id shows the same state on both.
        3. Write \(path) in exactly this format (JSON, version 1; unknown fields are errors):

        \(example)
           Rules: `id` uses lowercase letters, digits and `._/-` and is unique; `group` and `title` organise the menu, and scenarios that share a title in a group become one row with a submenu of their `variant`s; `appearance` switches the device to light or dark first; `launch` names `ios` arguments, `android` extras (text, true/false or whole numbers) or both, and a scenario is offered only on the platforms it names. At most 512 scenarios, 64 launch values each, 64 steps.
        4. For a flow worth watching (onboarding, an order from cart to delivery, a match from invitation to result), add `steps`: 2–64 states in order, each a short `title` and a `link` relative to the app's `urlScheme` (`debug/step?n=2` becomes `exampleshop://debug/step?n=2`). The launch opens the first step. The app must move to a step while it runs, through the same state updates real data would cause, so the screen animates as it does for people using it. Going forward may apply the target step directly; going back may reset to the first step without animation and then apply the target. Give every step a link, the first included, so going back stays in place. Add the receivers in debug builds only:
           - iOS: `simctl openurl` asks "Open in …?" on every call, so Threading writes the URL to the app's `tmp/\(SimulatorAppLinkDrop.fileName)` and posts the Darwin notification `\(SimulatorAppLinkDrop.notificationName)` inside the Simulator. Add this and pass the URL to the code that handles the app's other links:

        \(iOSReceiver)

           - Android: Threading sends `am start -a android.intent.action.VIEW -d <url> -f \(AndroidControlDefaults.singleTopFlag) -n <package>/<activity>`, which reaches the running activity's `onNewIntent`:

        \(androidReceiver)

        5. If the app keeps its fixtures in a list (a showcase catalogue, a preview registry, a screenshot plan), generate \(path) from that list with a small script and add a check that fails when the file is stale, instead of writing it by hand. Say how to rerun the script next to it.
        6. Verify in Threading: build and install the debug app on the devices in the Simulator workspace (`simulator_prepare`, `simulator_install_launch`), call `simulator_scenario` without arguments to list what Threading read (a broken file lists its problems), open each scenario with `simulator_scenario` and `scenario: "<id>"` and look at it with `simulator_screenshot`, and step through each flow with `step` to confirm that every step changes the running app in place. When a state looks wrong, fix the app's fixture rather than the file.
        """
    }
}
