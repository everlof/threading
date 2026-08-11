#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
scenario_directory="${repository_directory}/Fixtures/AgentScenarios"
scenario_files=()

while IFS= read -r -d '' scenario_file; do
  scenario_files+=("${scenario_file}")
done < <(find "${scenario_directory}" -type f -name '*.json' -print0)

if [[ "${#scenario_files[@]}" -eq 0 ]]; then
  echo "agent-scenarios: no tapes committed yet"
  exit 0
fi

swift run \
  --package-path "${repository_directory}/Packages/ThreadingScenarioKit" \
  threading-scenario validate \
  "${scenario_files[@]}"
