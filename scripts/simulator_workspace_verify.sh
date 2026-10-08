#!/usr/bin/env bash
# Installs the disposable animated workload on four explicitly named, already-booted test devices.
# The default manifest is the dedicated-device record from local workspace setup. Devices and the
# fixture remain available afterward; this lane never erases or shuts down a simulator.
set -euo pipefail
repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repository_directory}/scripts/coresimulator_lane_lock.sh"
device_ids="${THREADING_SIMULATOR_WORKSPACE_UDIDS:-}"
output_directory="${repository_directory}/.build/simulator-workspace-live/verification-$(date -u '+%Y%m%dT%H%M%SZ')"
setup_only=0
while (($#)); do
    case "$1" in
        --devices) device_ids="${2:?Provide four comma-separated dedicated device UDIDs}"; shift 2 ;;
        --output) output_directory="${2:?Provide a new output directory}"; shift 2 ;;
        --setup-only) setup_only=1; shift ;;
        --help|-h)
            printf '%s\n' 'Usage: scripts/simulator_workspace_verify.sh [--devices UUID,UUID,UUID,UUID] [--output PATH] [--setup-only]'
            exit 0 ;;
        *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done
threading_acquire_coresimulator_lane 'dedicated simulator workspace verification' || exit $?
cd "${repository_directory}"
if [[ -z "${device_ids}" ]]; then
    device_ids="$(python3 - <<'PY'
import json, pathlib
path = pathlib.Path('.build/simulator-workspace-live/devices.json')
if not path.exists():
    raise SystemExit('Provide four dedicated, booted device IDs with --devices.')
print(','.join(record['udid'] for record in json.loads(path.read_text())['devices']))
PY
)"
fi
export THREADING_SIMULATOR_WORKSPACE_UDIDS="${device_ids}"
scripts/build_simulator_workspace_fixture.sh
python3 - <<'PY'
import json, os, pathlib, subprocess, uuid
ids = os.environ['THREADING_SIMULATOR_WORKSPACE_UDIDS'].split(',')
if len(ids) != 4 or len(set(ids)) != 4:
    raise SystemExit('Exactly four distinct dedicated device IDs are required.')
for value in ids:
    uuid.UUID(value)
def run(*args, timeout=90):
    result = subprocess.run(['xcrun', 'simctl', *args], capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise SystemExit((result.stdout + result.stderr)[-4000:])
    return result.stdout
catalogue = json.loads(run('list', 'devices', '-j'))['devices']
devices = {device['udid']: device for group in catalogue.values() for device in group}
for value in ids:
    device = devices.get(value)
    if device is None or device['state'] != 'Booted':
        raise SystemExit(f'Dedicated device {value} must already be booted.')
application = pathlib.Path('.build/simulator-workspace-live/WorkspaceFixture.app').resolve()
for value in ids:
    run('install', value, str(application))
    run('launch', '--terminate-running-process', value, 'codes.threading.workspace-fixture',
        '--label=' + devices[value]['name'])
    print('Ready:', devices[value]['name'], value, flush=True)
containers = {value: run('get_app_container', value, 'codes.threading.workspace-fixture', 'data').strip() for value in ids}
pathlib.Path('.build/simulator-workspace-live/containers.json').write_text(json.dumps(containers))
PY
if [[ "${setup_only}" == 1 ]]; then exit 0; fi
if [[ "${output_directory}" != /* ]]; then output_directory="${repository_directory}/${output_directory}"; fi
if [[ -e "${output_directory}" ]]; then printf 'error: output already exists: %s\n' "${output_directory}" >&2; exit 2; fi
export THREADING_SIMULATOR_WORKSPACE_OUT="${output_directory}"
export THREADING_SIMULATOR_WORKSPACE_CONTAINERS="$(cat .build/simulator-workspace-live/containers.json)"
scripts/test.sh fast -derivedDataPath "${repository_directory}/.build/ui-evidence-derived-data" \
    -only-testing:ThreadingTests/SimulatorWorkspaceLiveIntegrationTests
printf 'Live workspace evidence: %s\n' "${output_directory}"
