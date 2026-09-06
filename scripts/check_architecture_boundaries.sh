#!/usr/bin/env bash
#
# Cheap structural invariants that the Swift type checker cannot express across files.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
failed=0

if ! python3 "${script_directory}/check_transcript_boundaries.py" "${repository_directory}"; then
  failed=1
fi

if ! python3 "${script_directory}/tests/test_transcript_boundaries.py"; then
  echo "architecture-boundary: transcript source checker regression tests failed" >&2
  failed=1
fi

if ! python3 "${script_directory}/generate_diagnostic_contract.py" \
    --root "${repository_directory}" --check; then
  echo "architecture-boundary: regenerate the diagnostic contract projections" >&2
  echo "  with scripts/generate_diagnostic_contract.py after editing the one manifest" >&2
  failed=1
fi

if ! python3 "${script_directory}/check_logging_boundaries.py" "${repository_directory}"; then
  failed=1
fi

if ! "${script_directory}/check_main_actor_latency.sh"; then
  echo "architecture-boundary: main-actor code must coordinate bounded worker work, not perform it" >&2
  failed=1
fi

if ! "${script_directory}/check_main_actor_latency.sh" --self-test; then
  echo "architecture-boundary: main-actor latency checker regression tests failed" >&2
  failed=1
fi

# `Sources/` is one synchronized folder, so a new file under `Sources/ThreadingMobile` joins the
# Mac target unless the exception list says otherwise. Half the time that stops the Mac build
# outright; the other half it ships — six Swift files, 58 iPhone app icons and two recorded
# marketing screens were in the Mac app when this was written. See the script.
if ! python3 "${script_directory}/check_target_membership.py" "${repository_directory}"; then
  failed=1
fi

if ! python3 "${script_directory}/check_navigator_fact_parity.py" "${repository_directory}"; then
  echo "architecture-boundary: native navigator entity reads must map to a published fact" >&2
  echo "  while options and host-owned interaction state use their typed parity lanes" >&2
  failed=1
fi

if ! python3 "${script_directory}/check_dependency_boundaries.py" "${repository_directory}"; then
  echo "architecture-boundary: Core must depend on application capabilities, never AppDelegate," >&2
  echo "  windows, or new concrete controllers; reduce the explicit legacy debt in place" >&2
  failed=1
fi

if ! python3 "${script_directory}/check_module_boundaries.py" "${repository_directory}"; then
  echo "architecture-boundary: compiler-layer modules may import only lower-level contracts" >&2
  failed=1
fi

if ! python3 "${script_directory}/check_failopen_defaults.py" "${repository_directory}"; then
  echo "architecture-boundary: an unrecognised raw value must not become a specific case —" >&2
  echo "  give the type an explicit unknown case, or project it with an exhaustive switch" >&2
  failed=1
fi

if ! python3 "${script_directory}/check_status_integrity.py" "${repository_directory}"; then
  echo "architecture-boundary: badges, catalogue continuity and loaders must fail closed" >&2
  failed=1
fi

# Run as scripts, not through `-m unittest`. This phase's interpreter is Xcode's own
# (`Developer/usr/bin/python3`, 3.9.6), which is prepended to PATH ahead of any Homebrew
# install, and `-m unittest` there rejects an *absolute* file path — "No module named
# '/Users/…/test_module_boundaries'". So every `xcodebuild` failed the boundary phase while
# running the same two files by hand passed. Both tests already end in `unittest.main()` and
# resolve the repository from `__file__`, so this needs no cwd and no interpreter version.
if ! python3 "${script_directory}/tests/test_module_boundaries.py"; then
  echo "architecture-boundary: module boundary checker regression tests failed" >&2
  failed=1
fi

if ! python3 "${script_directory}/tests/test_dependency_boundaries.py"; then
  echo "architecture-boundary: dependency boundary checker regression tests failed" >&2
  failed=1
fi

if ! python3 "${script_directory}/tests/test_failopen_defaults.py"; then
  echo "architecture-boundary: fail-open default checker regression tests failed" >&2
  failed=1
fi

if ! python3 "${script_directory}/tests/test_status_integrity.py"; then
  echo "architecture-boundary: status-integrity checker regression tests failed" >&2
  failed=1
fi

if ! python3 "${script_directory}/tests/test_navigator_fact_parity.py"; then
  echo "architecture-boundary: navigator fact parity checker regression tests failed" >&2
  failed=1
fi

# The event socket's reconnect counter is reset by the socket's first frame and by the socket's
# owner ending it, and by nothing else. A catalogue answer used to reset it too, so a socket
# failing every second beside a `304` every second never backed off (the 2026-09-06 iOS report;
# docs/REMOTE_ACCESS.md, "the sockets follow the route that answered last"). Counted rather than
# named, because the sites are statements inside one file and a name would drift.
remote_app_model="${repository_directory}/Sources/ThreadingMobile/RemoteAppModel.swift"
socket_recovery_resets="$(grep -cE '^[[:space:]]+connectionRecoveryAttempt = 0$' "${remote_app_model}" || true)"
if [[ "${socket_recovery_resets}" != "2" ]]; then
  echo "architecture-boundary: connectionRecoveryAttempt is reset at ${socket_recovery_resets} site(s); exactly 2 are allowed —" >&2
  echo "  the socket's first frame and disconnectThemeEvents. A catalogue answer is not a socket hello." >&2
  failed=1
else
  echo "socket-recovery-reset: clean"
fi

tool_handlers=(
  "${repository_directory}"/Sources/Threading/UI/Windows/AgentToolCoordinator+*.swift
)

session_coordinators=(
  "${repository_directory}"/Sources/Threading/UI/Windows/SessionCoordinator*.swift
)

conversation_controller="${repository_directory}/Sources/Threading/UI/Views/ConversationViewController.swift"
conversation_scheduling="${repository_directory}/Sources/Threading/UI/Views/ConversationScheduling.swift"
remote_access_server="${repository_directory}/Sources/Threading/Core/Remote/RemoteAccessServer.swift"
remote_access_coordinator="${repository_directory}/Sources/Threading/Core/Remote/RemoteAccessCoordinator.swift"
browser_controller="${repository_directory}/Sources/Threading/UI/Views/BrowserViewController.swift"
agent_session_command_adapter="${repository_directory}/Sources/Threading/UI/Windows/AgentToolCoordinator+SessionCommands.swift"
project_model="${repository_directory}/Sources/Threading/Models/Project.swift"
project_model_files=(
  "${repository_directory}/Sources/Threading/Models/AgentProviderCapabilities.swift"
  "${repository_directory}/Sources/Threading/Models/AgentSession.swift"
  "${repository_directory}/Sources/Threading/Models/ManagedWorkspace.swift"
  "${project_model}"
  "${repository_directory}/Sources/Threading/Models/PersistedUIDocuments.swift"
)
main_window_controller="${repository_directory}/Sources/Threading/UI/Windows/MainWindowController.swift"
extension_command_adapter="${repository_directory}/Sources/Threading/UI/Windows/AgentToolCoordinator+ExtensionCommands.swift"
extension_preview_service="${repository_directory}/Sources/Threading/UI/Extensions/ExtensionComponentAuthoringService.swift"
component_gallery_controller="${repository_directory}/Sources/Threading/UI/Windows/ComponentGalleryWindowController.swift"
mcp_tools="${repository_directory}/Sources/Threading/Core/MCP/MCPTools.swift"
mcp_catalog="${repository_directory}/Sources/Threading/Core/MCP/MCPToolCatalog.swift"
mcp_handler="${repository_directory}/Sources/Threading/UI/Windows/MainWindowMCPTools.swift"
app_settings="${repository_directory}/Sources/Threading/Core/Settings/AppSettings.swift"
settings_pages="${repository_directory}/Sources/Threading/UI/Preferences/SettingsPages.swift"
app_setting_definitions="${repository_directory}/Sources/Threading/Core/Settings/AppSettingDefinitions.swift"
main_window_test_support="${repository_directory}/Tests/ThreadingTests/MainWindowTestSupport.swift"

# `AppEnvironment.live` is process composition, not a recovery value for feature code. Keeping
# its construction in AppDelegate makes missing dependencies a compiler error in every window,
# coordinator, and test instead of silently reconnecting them to the running app's singletons.
if rg -n \
  'AppEnvironment\.live\b|environment\s*=\s*\.live\b|environment:\s*\.live\b' \
  "${repository_directory}/Sources/Threading" \
  --glob '*.swift' \
  --glob '!**/App/AppDelegate.swift'; then
  echo "architecture-boundary: AppEnvironment.live may be constructed only by AppDelegate" >&2
  echo "  feature controllers and services must receive explicit capabilities" >&2
  failed=1
fi

# Authority ratchet for the tool hub. This counts every file that can add methods or state to
# AgentToolCoordinator, including the main-window adapters whose filenames do not share the
# AgentToolCoordinator prefix. A lower count is welcome; an increase has to move policy back out.
#
# Raised from 8,979 to 9,063 when the adopted-Simulator tools landed. Every built-in tool family
# reaches its implementation through MCPBuiltInToolExecuting, which only this coordinator conforms
# to, so a new family cannot avoid the hub the way a new service can. What it can avoid is putting
# policy there, and this one does: argument validation and result shaping are in
# SimulatorAgentCommandService, and the 94 lines counted here decode, reveal the pane, and map a
# result. Raise this number only for that shape again -- a family whose policy already lives in an
# application service -- and never to make room for logic that could have gone in one.
#
# Raised from 9,063 to 9,097 when the Device logs family landed, for exactly that shape: platform
# validation and result shaping are in DeviceLogAgentCommandService, and the 34 lines counted here
# decode one argument, reveal the pane, and map a result.
agent_tool_authority="$(python3 - "${repository_directory}" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1]) / "Sources" / "Threading"
declaration = re.compile(r"\b(?:class|extension)\s+AgentToolCoordinator\b")
print(sum(
    len(path.read_text(encoding="utf-8").splitlines())
    for path in root.rglob("*.swift")
    if declaration.search(path.read_text(encoding="utf-8"))
))
PY
)"
if (( agent_tool_authority > 9097 )); then
  echo "architecture-boundary: AgentToolCoordinator authority grew to ${agent_tool_authority}" >&2
  echo "  keep it at or below the 9,097-line application-service ratchet" >&2
  failed=1
fi

if rg -n 'enum AgentCommand\b|func decodeArguments\s*\(' "${mcp_tools}" \
  || rg -n 'tool:\s*\.[A-Za-z]' "${mcp_catalog}" \
  || rg -n 'switch\s+call\b' "${mcp_handler}"; then
  echo "architecture-boundary: built-in MCP identity, decoding, catalogue metadata, and" >&2
  echo "  execution routing must stay in the single typed declaration inventory" >&2
  failed=1
fi

if rg -n 'private\s+enum\s+Keys\b|forKey:\s*"' "${app_settings}" \
  || rg -n '\bentry\s*\(' "${settings_pages}"; then
  echo "architecture-boundary: setting keys, defaults, validation, row anchors, and remote" >&2
  echo "  metadata must stay in AppSettingDefinitions" >&2
  failed=1
fi

# A persisted setting is authored as one generic descriptor. Reconstructing descriptors from
# erased definitions made the declared Swift type a runtime precondition and turned `all` into
# the real source. The registry may only erase typed declarations.
if rg -n \
  'AppSettingDescriptor\s*\(\s*definition:|func descriptor<|private static func stored\(|preconditionFailure' \
  "${app_setting_definitions}" \
  || ! rg -q -F 'persistedDescriptors.map(\.definition)' "${app_setting_definitions}"; then
  echo "architecture-boundary: persisted settings must be authored as typed descriptors" >&2
  echo "  and AppSettingDefinitions.all must be their erased projection" >&2
  failed=1
fi

# The main-window helper names ProjectStore.shared intentionally: it consumes the redirected
# hosted-test graph. Defining it only on HostedStoreTestCase lets Swift reject every unsafe
# caller, including free-function and indirect helpers, instead of relying on a class-name audit.
if ! rg -q '^extension HostedStoreTestCase \{' "${main_window_test_support}" \
  || rg -n '^extension XCTestCase \{' "${main_window_test_support}" \
  || rg -n 'func makeMainWindowController\s*\(' \
      "${repository_directory}/Tests/ThreadingTests" \
      --glob '*.swift' \
      --glob '!MainWindowTestSupport.swift'; then
  echo "architecture-boundary: makeMainWindowController must exist only on HostedStoreTestCase" >&2
  echo "  so every caller receives the hosted-store redirect and teardown" >&2
  failed=1
fi

if rg -n \
  '(ProjectStore|AgentRuntime|AppSettings|EventLog)\.shared\b' \
  "${session_coordinators[@]}"; then
  echo "architecture-boundary: SessionCoordinator must use its injected AppEnvironment" >&2
  failed=1
fi

if rg -n \
  '(ProjectStore|AgentRuntime|AppSettings|EventLog)\.shared\b' \
  "${main_window_controller}"; then
  echo "architecture-boundary: MainWindowController must use its injected AppEnvironment" >&2
  failed=1
fi

if rg -n 'ProjectStore\.shared\b' "${conversation_scheduling}"; then
  echo "architecture-boundary: conversation scheduling must use its injected current-session projection" >&2
  failed=1
fi

if rg -n '\b[A-Za-z][A-Za-z0-9_]*\.shared\b|\b(AppThemeLibrary|ThemeAssignments)\.' \
  "${remote_access_server}"; then
  echo "architecture-boundary: RemoteAccessServer must use its injected application interfaces" >&2
  failed=1
fi

remote_settings_locator_count="$(rg -o 'AppSettings\.shared\b' \
  "${remote_access_coordinator}" | wc -l | tr -d '[:space:]')"
if (( remote_settings_locator_count > 1 )); then
  echo "architecture-boundary: RemoteAccessCoordinator may name AppSettings.shared only" >&2
  echo "  once at its explicit shared composition root; instance policy uses injected settings" >&2
  failed=1
fi

if rg -n \
  'private var (preSettingsPage|history|pendingHistoryTarget)|\bhistory\.(visit|goBack|goForward|prune|canGo)' \
  "${main_window_controller}"; then
  echo "architecture-boundary: MainWindowController presents navigation destinations;" >&2
  echo "  timeline and Settings-detour state belong to WindowNavigationCoordinator" >&2
  failed=1
fi

if rg -n \
  'ExtensionProjectScaffolder|ExtensionComponentAuthoringCatalog|dependencies\.projects|Bundle\.main\.resourceURL' \
  "${extension_command_adapter}"; then
  echo "architecture-boundary: extension authoring handlers are transport/UI adapters;" >&2
  echo "  catalog validation and scaffolding belong to ExtensionAuthoringCommandService" >&2
  failed=1
fi

if rg -n 'static func (listJSON|describeJSON|validateJSON)' "${extension_preview_service}"; then
  echo "architecture-boundary: component identity/schema validation belongs to the catalog;" >&2
  echo "  the UI service owns preview rendering only" >&2
  failed=1
fi

if rg -n \
  'makeExecutionAuditStory|auditStoryRecord|makeConversationHandoffStory|makeAgentWorkSummarySample|private enum AuditStory' \
  "${component_gallery_controller}"; then
  echo "architecture-boundary: deterministic component stories belong beside their" >&2
  echo "  design components, not in ComponentGalleryWindowController" >&2
  failed=1
fi

if rg -n \
  '(ProjectStore|SessionAttachmentStore|DisplayPaneStore|ExtensionManager|MCPExternalToolRegistry|RemoteSessionMirrorRegistry|AppSettings|RemoteNotificationService)\.shared\b' \
  "${tool_handlers[@]}"; then
  echo "architecture-boundary: agent command handlers must use AgentToolDependencies" >&2
  failed=1
fi

# A cached native conversation outlives the record that first constructed it. Retaining that
# `AgentSession` made every later settings read a choice between current persistence and a stale
# fallback, and deletion silently selected the stale value. The controller now owns only the
# stable identity and reads mutable state through `CurrentSessionProjection`.
if rg -n \
  '\b(let|var)\s+agentSession\s*:\s*AgentSession\b|ProjectStore\.shared\.session\s*\(' \
  "${conversation_controller}"; then
  echo "architecture-boundary: ConversationViewController retains SessionID and reads the" >&2
  echo "  current AgentSession through its injected CurrentSessionProjection" >&2
  failed=1
fi

# WebKit callbacks and native presentation belong in the browser controller; download request,
# destination, completion, and bounded-history state belong to the application coordinator.
# Keeping that state out of the view controller makes the consent lifecycle testable without
# constructing WebKit or a window.
if rg -n \
  '\b(downloadDestinations|agentDownloadRequests|pendingAgentDownload)\b|\b(var|let)\s+recentDownloads\s*:' \
  "${browser_controller}"; then
  echo "architecture-boundary: BrowserViewController adapts WebKit downloads but download" >&2
  echo "  lifecycle state belongs to BrowserDownloadCoordinator" >&2
  failed=1
fi

if rg -n \
  'loadCompletion|loadReadiness|trackedLoadHasCommitted|trackedDocumentReadinessToken|observedDOMContentLoadedTokens|navigationToken' \
  "${browser_controller}"; then
  echo "architecture-boundary: BrowserViewController delegates tracked navigation state;" >&2
  echo "  navigation lifecycle belongs to BrowserNavigationCoordinator" >&2
  failed=1
fi

if rg -n \
  'agentActionSequence|activeAgentNavigationGuard|AgentNavigationGuard' \
  "${browser_controller}"; then
  echo "architecture-boundary: BrowserViewController adapts WebKit form decisions;" >&2
  echo "  agent form-submission policy belongs to BrowserAgentNavigationPolicy" >&2
  failed=1
fi

if rg -n \
  'action must be clear_site_data|page or tab changed before site data|recordsRemoved' \
  "${repository_directory}/Sources/Threading/UI/Windows/AgentToolCoordinator+BrowserCommands.swift"; then
  echo "architecture-boundary: browser storage command behavior belongs to" >&2
  echo "  BrowserStorageCommandService; the coordinator is a UI/WebKit adapter" >&2
  failed=1
fi

if rg -n 'dependencies\.(projects|archiveScheduler)\b|\bAppSettings\b' \
  "${agent_session_command_adapter}"; then
  echo "architecture-boundary: AgentToolCoordinator session handlers are transport adapters;" >&2
  echo "  session command behavior belongs to AgentSessionCommandService" >&2
  failed=1
fi

if rg -n '^import (AppKit|WebKit)\b' "${project_model_files[@]}"; then
  echo "architecture-boundary: persisted model declarations must remain AppKit-free" >&2
  failed=1
fi

if rg -n \
  '^(struct AgentSession|struct ManagedWorkspace|struct Persisted|struct AgentCapabilities|enum AgentKind)' \
  "${project_model}"; then
  echo "architecture-boundary: Project.swift owns project records only;" >&2
  echo "  provider, session, workspace, and persisted UI records have dedicated owners" >&2
  failed=1
fi

if rg -n 'SWIFT_STRICT_CONCURRENCY = targeted;' \
  "${repository_directory}/Threading.xcodeproj/project.pbxproj"; then
  echo "architecture-boundary: targeted concurrency checking must not be reintroduced" >&2
  failed=1
fi

# A view that is invalid between `init` and `viewDidLoad` should say so with an optional.
# Controllers whose views are required use lazy construction instead, making init order a
# compiler-checked dependency rather than a force-unwrap contract.
if rg -n \
  '\b(var|let)\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*[^=\n]+!([[:space:]]|$)' \
  "${repository_directory}/Sources/Threading" \
  --glob '*.swift'; then
  echo "architecture-boundary: implicitly unwrapped stored declarations are forbidden" >&2
  failed=1
fi

# A feature that asks *which runtime is this* answers only for the runtimes that existed the
# day it was written; every other one silently falls into its `else`. `AgentKind.capabilities`
# is the one place a runtime is named to decide what the host may do with it, and
# `supports(_:)` is how everything else asks.
#
# Only equality is banned. An exhaustive `switch` over `AgentKind` stays allowed and is often
# right — a transcript parser or a launch line genuinely differs per runtime, and the compiler
# makes adding a fifth case a build error there, which is exactly the reminder this check
# exists to reproduce for the comparisons it cannot see.
#
# `Models/Project.swift` is exempt because it declares `AgentKind`, `AgentCapabilities` and
# `AgentSessionConfiguration`: reconstructing a configuration from a decoded record, or
# refusing a lineage the enum has no case for, has to name the case it is talking about.
#
# The closure form is listed separately because it is how the rule was first evaded: a
# `AgentKind.allCases.filter { $0 == .claude }` reads like a policy, names no `kind` for the
# first pattern to catch, and had put the Usage report's real constraint — a reader that knows
# only Claude's transcript layout — a file away from the code that causes it.
if rg -n \
  '([Kk]ind\s*[!=]=\s*\.(claude|codex|grok|openCode)\b|\.(claude|codex|grok|openCode)\s*[!=]=\s*[A-Za-z_][A-Za-z0-9_.]*[Kk]ind\b|\$[0-9]\s*[!=]=\s*\.(claude|codex|grok|openCode)\b)' \
  "${repository_directory}/Sources/Threading" \
  --glob '*.swift' \
  --glob '!**/Models/AgentSession.swift'; then
  echo "architecture-boundary: compare AgentKind capabilities, not runtime identity — add a" >&2
  echo "  member to AgentCapabilities in Models/AgentProviderCapabilities.swift and ask kind.supports(_:)" >&2
  failed=1
fi

# The browser consent prompt is only worth the interruption if the page it names is the page that
# loads. An agent command therefore starts a navigation from an `ApprovedBrowserTarget` — the
# value the decision hands back — and never from the text the agent sent, which the prompt has
# already been raised about and which a second parse can resolve differently.
#
# It was `browser.navigate(to: input, …)` after authorizing `normalizedURL(from: input)`: the same
# function ran on both sides of the user's answer, so the two agreed by coincidence. The bug that
# exposed it was in the normalizer — `file:///notes.html` became `https://file:///notes.html`,
# whose host is the word "file" — and the alert asked about a host that does not exist.
# Page text on its way to an agent goes through the filled-credential scrubber, every time.
#
# `browser_fill_credentials` puts a real password into a real page, and snapshot redaction keys
# off the field's live `type` attribute — so a page that flips its own input to `type=text`, or
# copies the value into a div, hands the plaintext back in the very next snapshot. The tab retains
# what it filled precisely so it can be taken back out again, which only works if every path that
# returns page text remembers to ask.
#
# Four did not. `browser_snapshot` and the mutating-action funnel were scrubbed by hand while
# `browser_wait`, the navigation receipt, the performance summary and the accessibility audit each
# returned `agentText` raw — the same omission four times, which is the shape of a rule that wants
# enforcing rather than remembering. A `scrubFilledSecrets` within three lines is the test, because
# the call usually wraps a multi-line expression.
if ! python3 - "${tool_handlers[@]}" <<'PYTHON'; then
import pathlib, sys

failures = []
for path in sys.argv[1:]:
    lines = pathlib.Path(path).read_text().splitlines()
    for index, line in enumerate(lines):
        if ".agentText" not in line:
            continue
        window = lines[max(0, index - 3):index + 1]
        if any("scrubFilledSecrets" in candidate for candidate in window):
            continue
        failures.append(f"{path}:{index + 1}: {line.strip()}")

for failure in failures:
    print(failure)
sys.exit(1 if failures else 0)
PYTHON
  echo "architecture-boundary: page text returned to an agent must pass through" >&2
  echo "  browser.scrubFilledSecrets — a filled credential is otherwise readable from the" >&2
  echo "  next snapshot the page chooses to expose it in" >&2
  failed=1
fi

if rg -nU '\.navigate\(\s*+to:\s*+(?!approved\b)' "${tool_handlers[@]}" --pcre2; then
  echo "architecture-boundary: an agent navigation starts from the approved target, not from" >&2
  echo "  agent-supplied text — use authorizeBrowserTarget and pass what it hands back" >&2
  failed=1
fi

# A selection's fill and the ink on it are one decision, and they were being made in different
# files. Every consumer took `Design.Surface.selection` alone and chose its own foreground, so the
# two drifted apart in both directions at once: `Design.Text.label` over Windows 98's 90%-opaque
# navy (1.47:1), and `Design.Text.selected` — an ink measured against the *opaque accent* — over
# Christmas's 20% wash of that accent (1.76:1). Neither call site was wrong to trust what it was
# handed; the role being available on its own is what made both possible.
#
# `SelectionSurface` vends the fill and the ink together and cannot give one without the other, so
# this keeps the role from being reachable around it. The theme files themselves are exempt: they
# *author* the role, which is the one place naming it is the point.
if rg -n '\.(color|resolved)\(\s*\.selection\b' \
  "${repository_directory}/Sources/Threading" \
  --glob '*.swift' \
  --glob '!**/UI/Design/SelectionSurface.swift' \
  --glob '!**/Core/Theme/**'; then
  echo "architecture-boundary: the selection role is vended by SelectionSurface, which hands" >&2
  echo "  back the fill and the ink measured against it — take the pair, not the fill" >&2
  failed=1
fi

# Typed events belong beside the subsystem that owns their payload and behavior. Keeping the
# declarations in TerminalConstants.swift made every event change touch a shared grab bag and
# let AppKit-only lifetime helpers leak into Core. The generic event transport lives in
# Core/Events; UI lifetime helpers live in UI/Infrastructure.
terminal_constants="${repository_directory}/Sources/Threading/Core/Constants/TerminalConstants.swift"
if rg -n \
  '^(protocol AppEvent\b|(final )?class (LocalEventMonitor|MainRunLoopTimer)\b|enum (AgentDefaults|AgentEnvironment|MCPDefaults)\b|struct [A-Za-z_][A-Za-z0-9_]*: AppEvent\b)' \
  "${terminal_constants}"; then
  echo "architecture-boundary: typed events, UI lifetime helpers, and subsystem defaults do" >&2
  echo "  not belong in Core/Constants/TerminalConstants.swift — place them beside their owner" >&2
  failed=1
fi

# A hover that reads its position off `mouseMoved` cannot be shielded by a covering surface:
# AppKit computes every crossing in the window inside that event, so `CoveredWindowPointer` can
# withhold `mouseEntered` beneath a dropdown but never `mouseMoved`. Each such override therefore
# asks `NSView.uncoveredPointerLocation(in:)` itself — and the rule was applied by hand to three
# views before the other seven were found, which is what this gate exists for. A view that *is*
# the covering surface, and one that never keeps hover, is named here with its reason rather than
# passed by omission.
if ! python3 - "${repository_directory}" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1]) / "Sources" / "Threading"
exempt = {
    # The dropdown's own overlay is the covering surface; nothing stands over it.
    "UI/Design/ThemedMenu.swift",
}
asks = re.compile(r"uncoveredPointerLocation\(in:")
override = re.compile(r"^(\s*)(?:open |public |internal )?override func mouseMoved\(with")
failures = []
for path in sorted(root.rglob("*.swift")):
    relative = path.relative_to(root).as_posix()
    if relative in exempt:
        continue
    lines = path.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        match = override.match(line)
        if not match:
            continue
        indent = match.group(1)
        body = []
        for candidate in lines[index + 1:]:
            if candidate.startswith(indent + "}"):
                break
            body.append(candidate)
        if not any(asks.search(candidate) for candidate in body):
            failures.append(f"{relative}:{index + 1}")
if failures:
    for failure in failures:
        print(f"  {failure}", file=sys.stderr)
    sys.exit(1)
PY
then
  echo "architecture-boundary: a mouseMoved override reads the pointer without asking" >&2
  echo "  NSView.uncoveredPointerLocation(in:) — a position under a covering surface is not" >&2
  echo "  this view's; ask it, or name the view as the surface in the exemption list" >&2
  failed=1
fi

# A refusal beep is a sound, and this app has one switch for those. Fifty-eight call sites rang
# `NSSound.beep()` themselves, which is how Silence Sounds came to silence the bell and the
# banners while leaving the app's most frequent sound audible — and how a hosted test bundle,
# which drives exactly the branches that beep, came to make noise in the developer's room from a
# process nothing on screen accounts for. `SystemAlert.refuse()` asks the same gate the other two
# sounds ask, and answers for the automated lanes as well.
#
# `NotificationSound.swift` is exempt because `SoundPlayer.playSystemAlertAdmitted` is not a
# refusal: it is the *bell's* system sound, whose gate `TerminalBell.ring` consults ahead of the
# rate limiter, and which the settings audition reaches deliberately ungated.
#
# Comment lines are skipped rather than the files holding them: three of the notes explaining this
# seam quote the call they replaced, and a rule that made those unwriteable would erase the only
# record of why the seam exists.
if rg -n --pcre2 '^(?!\s*//).*NSSound\.beep\(\)' \
  "${repository_directory}/Sources/Threading" \
  --glob '*.swift' \
  --glob '!**/Core/Session/SystemAlert.swift' \
  --glob '!**/Core/Session/NotificationSound.swift'; then
  echo "architecture-boundary: refuse with SystemAlert.refuse(), not NSSound.beep() — a sound the" >&2
  echo "  user cannot silence is the one bug a silence switch does not survive" >&2
  failed=1
fi

# A settings destination is pinned into its pane in exactly one place.
#
# The Settings shell and the page fixtures each stated the same five constraints, and they
# drifted: the render tests pinned a page to a bare view's four edges and photographed answers
# beside their questions, while the shell centred the same page under a cap in a window and the
# app drew them in a ragged strip against the trailing edge. Nobody could see the difference,
# because the difference was two lists of constraints in two files.
#
# So `SettingsUI.install(page:in:top:)` owns the arrangement and the cap, and anything else that
# wants a settings page in a pane calls it. Naming `SettingsUIDefaults.pageWidth` outside that
# file is how a second copy starts.
#
# Comment lines are skipped: the note explaining the priorities in `install` quotes the constraint
# it replaced, and a rule that made that unwriteable would erase why the seam exists.
if rg -n --pcre2 '^(?!\s*//).*SettingsUIDefaults\.pageWidth' \
  "${repository_directory}/Sources/Threading" \
  --glob '*.swift' \
  --glob '!**/UI/Preferences/SettingsComponents.swift'; then
  echo "architecture-boundary: install a settings page with SettingsUI.install(page:in:top:) —" >&2
  echo "  a second copy of the canvas cap is how the app and its render fixtures drifted apart" >&2
  failed=1
fi

# The PTY host daemon is describable on one page, and this is what keeps it that way.
#
# `threading-ptyd` holds every hosted agent on the machine in one process. Its whole safety
# argument is that it owns four things per session — the child, the ring, the last window size,
# the exit status — and parses nothing: no projects, no themes, no transcripts, no accounts, no
# policy, no settings, no SQLite store, no journal of the app's, and no terminal emulation. A
# daemon that grew any of those would be a second writer to state the app reconciles, which this
# repository has already paid for twice: a concurrent `ProjectDatabase.save` deleted a user's real
# projects, and two processes appending to one journal left 23 unparseable lines.
#
# So the import list is the boundary, and the identifier list names the specific temptations. It
# is a lint rather than a note in a document because "the daemon should just log to the same place
# as the app" is a one-line change that reads as an improvement.
if rg -n --pcre2 '^\s*(?:@[A-Za-z_]+\s+)?import\s+(?!(?:Foundation|Darwin|Dispatch|ThreadingPTYHostKit)\s*$)' \
  "${repository_directory}/Targets/PTYHost" \
  --glob '*.swift'; then
  echo "architecture-boundary: threading-ptyd may import only Foundation, Darwin, Dispatch and" >&2
  echo "  ThreadingPTYHostKit — the wire contract is the only thing it shares with the app" >&2
  failed=1
fi

# Comment lines are skipped rather than the files holding them: the notes explaining why the
# daemon has its own journal, and why it never opens the app's store, have to be able to name
# what they are refusing.
if rg -n --pcre2 '^(?!\s*//).*\b(?:SwiftTerm|AppKit|ProjectStore|AppSettings|TerminalTheme|EventLog)\b' \
  "${repository_directory}/Targets/PTYHost" \
  --glob '*.swift'; then
  echo "architecture-boundary: threading-ptyd owns the child, the ring, the grid and the exit" >&2
  echo "  status, and nothing else — no store, no settings, no theme, no emulation, and its own" >&2
  echo "  journal in its own directory" >&2
  failed=1
fi

if (( failed )); then
  exit 1
fi

echo "architecture-boundary: clean"
