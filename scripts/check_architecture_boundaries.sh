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

if (( failed )); then
  exit 1
fi

echo "architecture-boundary: clean"
