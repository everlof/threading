#!/usr/bin/env bash
# Run in a Linux Swift toolchain (or a bounded compiler container). No deployment, credentials
# or application code is required. The output is an independently installable host bundle.
#
#   scripts/build-controller-host.sh ABSOLUTE_OUTPUT_DIRECTORY
#
# `threading-ptyd` is the same static musl, stripped, generation-stamped binary
# scripts/test-ptyd-linux.sh ships (scripts/linux/build-ptyd-static.sh builds it and runs the daemon
# suite against the exact file placed in the bundle). `threading-controller` is a release build with
# the Swift runtime linked statically against the host's glibc and SQLite, stripped at link.
#
# The manifest hashes the final bytes. Nothing downstream may strip, sign or otherwise rewrite a
# bundle file: install-host.py refuses any file whose digest differs from the manifest.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:?absolute output directory}"
case "$output" in /*) ;; *) exit 2 ;; esac
[[ "$(uname -s)" == Linux ]] || { echo 'Linux build host required' >&2; exit 2; }
mkdir -p "$output"
scratch="$output/build"
bash "$root/scripts/test-controller.sh" "$scratch"

# shellcheck source=linux/ptyd-generation.sh
source "$root/scripts/linux/ptyd-generation.sh"
threading_ptyd_generation "$root" || exit $?
GENERATION_SHORT_VERSION="$ptyd_short_version" \
    GENERATION_BUNDLE_VERSION="$ptyd_bundle_version" \
    GENERATION_SOURCE_REVISION="$ptyd_source_revision" \
    bash "$root/scripts/linux/build-ptyd-static.sh" "$root" "$scratch/ptyd-static" "$output"

swift build --package-path "$root/Targets/Controller" --scratch-path "$scratch/release-Controller" \
    -c release --static-swift-stdlib -Xlinker -s -j 2
install -m 0755 "$scratch/release-Controller/release/threading-controller" "$output/threading-controller"
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

# The installer's own verification, against a throwaway home: digests, architecture and controller
# capabilities as a host will check them. No service is started.
install_check_home="$(mktemp -d /tmp/threading_host_check_XXXXXX)"
trap 'rm -rf "$install_check_home"' EXIT
python3 "$output/install-host.py" "$output" --home "$install_check_home" >/dev/null
