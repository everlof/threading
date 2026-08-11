#!/usr/bin/env bash
set -euo pipefail

helper_directory="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
destination="${helper_directory}/threading-scenario"

# The fixture process is executable test support, not a shipping app capability. Always remove
# a helper left in a reused build directory unless this invocation explicitly requests it.
if [[ "${CONFIGURATION}" != "Debug" || "${THREADING_EMBED_UI_SCENARIO_HELPER:-NO}" != "YES" ]]; then
  rm -f "${destination}"
  exit 0
fi

source="${SRCROOT}/Packages/ThreadingScenarioKit/.build/debug/threading-scenario"
if [[ ! -x "${source}" ]]; then
  echo "error: missing UI scenario helper; run scripts/ui-test.sh so it is built first" >&2
  exit 1
fi

mkdir -p "${helper_directory}"
/usr/bin/ditto "${source}" "${destination}"
chmod 755 "${destination}"
