#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
source_file="${script_dir}/main_actor_latency_lint.swift"
policy="${script_dir}/config/main-actor-latency.json"

swiftc_path="$(xcrun --find swiftc)"
toolchain_root="${swiftc_path%/usr/bin/swiftc}"
host_libs="${toolchain_root}/usr/lib/swift/host"
cache_root="${DERIVED_FILE_DIR:-${TMPDIR:-/tmp}/threading-main-actor-latency-${UID}}"
mkdir -p "${cache_root}"
binary="${cache_root}/main-actor-latency-lint"

if [[ ! -x "${binary}" || "${source_file}" -nt "${binary}" ]]; then
    xcrun swiftc \
        -O \
        -I "${host_libs}" \
        -L "${host_libs}" \
        -lSwiftSyntax \
        -lSwiftParser \
        "${source_file}" \
        -o "${binary}"
fi

DYLD_LIBRARY_PATH="${host_libs}${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}" \
    "${binary}" "${repo_root}" "${policy}" "$@"
