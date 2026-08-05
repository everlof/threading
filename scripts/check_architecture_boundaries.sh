#!/usr/bin/env bash
#
# Cheap structural invariants that the Swift type checker cannot express across files.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
failed=0

tool_handlers=(
  "${repository_directory}"/Sources/Threading/UI/Windows/AgentToolCoordinator+*.swift
)

if rg -n \
  '(ProjectStore|SessionAttachmentStore|DisplayPaneStore|ExtensionManager|MCPExternalToolRegistry|RemoteSessionMirrorRegistry|AppSettings|RemoteNotificationService)\.shared\b' \
  "${tool_handlers[@]}"; then
  echo "architecture-boundary: agent command handlers must use AgentToolDependencies" >&2
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

if (( failed )); then
  exit 1
fi

echo "architecture-boundary: clean"
