#!/usr/bin/env bash
# The preview draws the exact provider artwork loaded by the shipping Mac asset catalogue.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
destination=Sources/WindowHarness/Resources/ProviderMarks
mkdir -p "$destination"
for provider in Claude Codex; do
  source="../../Sources/Threading/Resources/Assets.xcassets/AgentIcon${provider}.imageset/AgentIcon${provider}@2x.png"
  target="$destination/AgentIcon${provider}.png"
  if [[ ${1:-} == --verify ]]; then
    cmp "$source" "$target"
  else
    cp "$source" "$target"
  fi
done
echo 'provider marks are byte-identical to the production asset catalogue'
