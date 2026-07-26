#!/usr/bin/env bash
set -euo pipefail

run_claude=0
if [[ "${1:-}" == "--claude" ]]; then
  run_claude=1
  shift
fi

required_variables=(
  SKALMAN_APNS_KEY_ID
  SKALMAN_APNS_TEAM_ID
  SKALMAN_APNS_PRIVATE_KEY_PATH
  SKALMAN_E2E_APNS_DEVICE_TOKEN
)
for variable_name in "${required_variables[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "Missing ${variable_name}. See docs/NOTIFICATION_E2E.md." >&2
    exit 2
  fi
done

if [[ ! -f "${SKALMAN_APNS_PRIVATE_KEY_PATH}" ]]; then
  echo "SKALMAN_APNS_PRIVATE_KEY_PATH does not point to a readable file." >&2
  exit 2
fi

if [[ "${run_claude}" == "1" ]]; then
  export SKALMAN_E2E_RUN_CLAUDE=1
else
  unset SKALMAN_E2E_RUN_CLAUDE
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"

exec xcodebuild \
  -project "${repository_directory}/Skalman.xcodeproj" \
  -scheme SkalmanNotificationE2E \
  -destination "platform=macOS" \
  test \
  "$@"
