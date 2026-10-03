#!/usr/bin/env bash
# Run in a Linux Swift toolchain (or a bounded compiler container). No deployment, credentials
# or application code is required. The output is an independently installable host bundle.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:?absolute output directory}"
case "$output" in /*) ;; *) exit 2 ;; esac
[[ "$(uname -s)" == Linux ]] || { echo 'Linux build host required' >&2; exit 2; }
mkdir -p "$output"
scratch="$output/build"
bash "$root/scripts/test-controller.sh" "$scratch"
for component in Controller PTYHost; do
    swift build --package-path "$root/Targets/$component" --scratch-path "$scratch/release-$component" -c release --static-swift-stdlib -j 2
done
install -m 0755 "$scratch/release-Controller/release/threading-controller" "$output/threading-controller"
install -m 0755 "$scratch/release-PTYHost/release/threading-ptyd" "$output/threading-ptyd"
cp "$root/Targets/Controller/Support/host-state.py" "$output/host-state.py"
cp "$root/Targets/Controller/Support/install-host.py" "$output/install-host.py"
python3 - "$output" <<'PY'
import hashlib, json, pathlib, platform, subprocess, sys
root = pathlib.Path(sys.argv[1])
files = ['threading-controller', 'threading-ptyd', 'host-state.py', 'install-host.py']
capabilities = json.loads(subprocess.check_output([str(root / 'threading-controller'), '--version']))
manifest = {'version': 1, 'system': platform.system(), 'machine': platform.machine(), 'controller': capabilities,
            'files': {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in files}}
(root / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
print(json.dumps({'bundle': str(root), 'schema': capabilities['schema'], 'machine': platform.machine()}))
PY
