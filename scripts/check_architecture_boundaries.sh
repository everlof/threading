#!/usr/bin/env bash
#
# Cheap structural invariants that the Swift type checker cannot express across files.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
failed=0

if ! python3 "${script_directory}/check_logging_boundaries.py" "${repository_directory}"; then
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

tool_handlers=(
  "${repository_directory}"/Sources/Threading/UI/Windows/AgentToolCoordinator+*.swift
)

session_coordinators=(
  "${repository_directory}"/Sources/Threading/UI/Windows/SessionCoordinator*.swift
)

conversation_controller="${repository_directory}/Sources/Threading/UI/Views/ConversationViewController.swift"
browser_controller="${repository_directory}/Sources/Threading/UI/Views/BrowserViewController.swift"
browser_download_coordinator="${repository_directory}/Sources/Threading/Application/Browser/BrowserDownloadCoordinator.swift"

if rg -n \
  '(ProjectStore|AgentRuntime|AppSettings|EventLog)\.shared\b' \
  "${session_coordinators[@]}"; then
  echo "architecture-boundary: SessionCoordinator must use its injected AppEnvironment" >&2
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

if rg -n '^import (AppKit|WebKit)\b' "${browser_download_coordinator}"; then
  echo "architecture-boundary: BrowserDownloadCoordinator must remain Foundation-only" >&2
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
  --glob '!**/Models/Project.swift'; then
  echo "architecture-boundary: compare AgentKind capabilities, not runtime identity — add a" >&2
  echo "  member to AgentCapabilities in Models/Project.swift and ask kind.supports(_:)" >&2
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

if (( failed )); then
  exit 1
fi

echo "architecture-boundary: clean"
