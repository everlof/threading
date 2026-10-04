#!/usr/bin/env bash
#
# Build `threading-ptyd` and `threading-mcp-bridge` for Linux and run their tests there, in a
# Linux container.
#
#   scripts/test-ptyd-linux.sh                 # this Mac's architecture
#   scripts/test-ptyd-linux.sh --arch amd64    # x86_64, emulated
#   scripts/test-ptyd-linux.sh --arch all      # both
#   scripts/test-ptyd-linux.sh --no-static     # skip the static release binary
#
# For each architecture it runs, in order:
#   1. the ThreadingPTYHostKit package tests (the wire contract) on Linux;
#   2. a debug build of the daemon and the package's test target, which is the same
#      PTYHostDaemonTests suite the hosted macOS target runs, through a symlink;
#   3. a static musl release build (Swift Static Linux SDK) — the binary a remote execution host
#      runs — then the daemon suite again against that exact binary, and a check that it links
#      nothing dynamically. That step is scripts/linux/build-ptyd-static.sh, which
#      scripts/build-controller-host.sh runs too, so both ship the same build.
#
# Every suite must skip exactly the cases scripts/linux/ptyd-expected-skips.txt lists (none for the
# wire-contract package): a skip nobody expected is coverage the lane lost without failing.
#
# The static binary reports a generation in `hello`, as the macOS helper does from its Info.plist;
# scripts/linux/ptyd-generation.sh says where it comes from. The debug build names none and is
# tested to report `? (?)`.
#
# The static binaries land in build/linux/<arch>/threading-ptyd and threading-mcp-bridge. Build
# products and the SDK are cached in Docker volumes, so a second run compiles only what changed.
# The container runs with `--init` because the restart tests orphan a child on purpose and need
# something to reap it.
#
# Tests run one case per process through scripts/linux/xctest-watchdog.sh, which works around an
# open swift-corelibs-xctest deadlock on Linux and says so every time it does; read its header
# before trusting or changing that.
#
# See docs/feature-drafts/remote-execution-hosts.md.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"

# shellcheck source=linux/toolchain.sh
source "${script_directory}/linux/toolchain.sh"
# shellcheck source=linux/ptyd-generation.sh
source "${script_directory}/linux/ptyd-generation.sh"

architectures=()
build_static=1

usage() {
  sed -n '3,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

native_architecture() {
  case "$(uname -m)" in
    arm64|aarch64) echo arm64 ;;
    x86_64|amd64) echo amd64 ;;
    *) echo "test-ptyd-linux: unsupported host architecture $(uname -m)" >&2; exit 64 ;;
  esac
}

while (( $# > 0 )); do
  case "$1" in
    --arch)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      case "$2" in
        arm64|amd64) architectures=("$2") ;;
        all) architectures=(arm64 amd64) ;;
        *) usage >&2; exit 64 ;;
      esac
      shift 2
      ;;
    --no-static) build_static=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
(( ${#architectures[@]} > 0 )) || architectures=("$(native_architecture)")

threading_ptyd_generation "${repository_directory}" || exit $?

if ! docker info >/dev/null 2>&1; then
  echo "test-ptyd-linux: Docker is not running. Start Docker Desktop and try again." >&2
  exit 69
fi

run_architecture() {
  local architecture="$1"
  local sdk_triple
  case "${architecture}" in
    arm64) sdk_triple="aarch64-swift-linux-musl" ;;
    amd64) sdk_triple="x86_64-swift-linux-musl" ;;
  esac
  local output_directory="${repository_directory}/build/linux/${architecture}"
  mkdir -p "${output_directory}"

  echo "==> threading-ptyd on linux/${architecture}"
  docker run --rm --init \
    --platform "linux/${architecture}" \
    --volume "${repository_directory}:/src:ro" \
    --volume "threading-ptyd-linux-${architecture}:/work" \
    --volume "${output_directory}:/out" \
    --env "BUILD_STATIC=${build_static}" \
    --env "SDK_TRIPLE=${sdk_triple}" \
    --env "GENERATION_SHORT_VERSION=${ptyd_short_version}" \
    --env "GENERATION_BUNDLE_VERSION=${ptyd_bundle_version}" \
    --env "GENERATION_SOURCE_REVISION=${ptyd_source_revision}" \
    "${threading_linux_swift_image}" \
    bash -euo pipefail -c '
      package=/src/Targets/PTYHost
      watchdog=/src/scripts/linux/xctest-watchdog.sh
      expected_skips=/src/scripts/linux/ptyd-expected-skips.txt
      echo "--- kernel $(uname -r), $(swift --version 2>&1 | head -1)"

      echo "--- expected-skip contract of the watchdog"
      /src/scripts/linux/tests/test-xctest-watchdog.sh

      echo "--- ThreadingPTYHostKit tests"
      kit=/src/Packages/ThreadingPTYHostKit
      swift build --package-path "${kit}" --scratch-path /work/kit --build-tests
      "${watchdog}" --expected-skips /dev/null \
        "$(swift build --package-path "${kit}" --scratch-path /work/kit --show-bin-path)/ThreadingPTYHostKitPackageTests.xctest"

      echo "--- debug build and daemon tests"
      swift build --package-path "${package}" --scratch-path /work/debug --build-tests
      tests="$(swift build --package-path "${package}" --scratch-path /work/debug --show-bin-path)/ThreadingPTYHostPackageTests.xctest"
      "${watchdog}" --expected-skips "${expected_skips}" "${tests}"

      if [[ "${BUILD_STATIC}" == 1 ]]; then
        /src/scripts/linux/build-ptyd-static.sh /src /work /out

        echo "--- threading-mcp-bridge static release build (${SDK_TRIPLE})"
        bridge=/src/Targets/MCPBridge
        bridge_static=(--package-path "${bridge}" --scratch-path /work/bridge-static
          --swift-sdks-path /work/sdks --swift-sdk "${SDK_TRIPLE}" -c release -Xlinker -s)
        swift build "${bridge_static[@]}" --product threading-mcp-bridge
        install -m 0755 "$(swift build "${bridge_static[@]}" --show-bin-path)/threading-mcp-bridge" \
          /out/threading-mcp-bridge
        if ldd /out/threading-mcp-bridge >/dev/null 2>&1; then
          echo "test-ptyd-linux: /out/threading-mcp-bridge links dynamically" >&2
          exit 1
        fi
        # The behaviour of the bridge is held by MCPBridgeTests against the embedded macOS build. What
        # only Linux can answer is that this binary runs: with no app behind the socket it must
        # still answer the handshake, in its own words, and exit when stdin ends.
        echo "--- threading-mcp-bridge answers a handshake with nothing behind its socket"
        handshake="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
        answer="$(printf "%s\n" "${handshake}" \
          | timeout 20 /out/threading-mcp-bridge --socket /tmp/no-threading.sock --token smoke \
            --cache /tmp/bridge-smoke-cache.json)"
        if ! grep -q "Threading is not running" <<<"${answer}"; then
          echo "test-ptyd-linux: the bridge did not answer the handshake: ${answer}" >&2
          exit 1
        fi
        ls -l /out/threading-mcp-bridge
      fi
    '
}

for architecture in "${architectures[@]}"; do
  run_architecture "${architecture}"
done
echo "test-ptyd-linux: passed on ${architectures[*]}"
