#!/usr/bin/env bash
#
# Build `threading-ptyd` for Linux and run its tests there, in a Linux container.
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
#      nothing dynamically.
#
# The static binaries land in build/linux/<arch>/threading-ptyd. Build products and the SDK are
# cached in Docker volumes, so a second run compiles only what changed. The container runs with
# `--init` because the restart tests orphan a child on purpose and need something to reap it.
#
# Tests run one case per process through scripts/linux/xctest-watchdog.sh, which works around an
# open swift-corelibs-xctest deadlock on Linux and says so every time it does; read its header
# before trusting or changing that.
#
# See docs/feature-drafts/remote-execution-hosts.md.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"

# The Linux toolchain matches the Swift in the Xcode this repository builds with, so both builds of
# the daemon are checked by the same compiler. Move all three together.
readonly swift_image="swift:6.3.2-noble"
readonly static_sdk_url="https://download.swift.org/swift-6.3.2-release/static-sdk/swift-6.3.2-RELEASE/swift-6.3.2-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz"
readonly static_sdk_checksum="3fd798bef6f4408f1ea5a6f94ce4d4052830c4326ab85ebc04f983f01b3da407"

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
    --env "STATIC_SDK_URL=${static_sdk_url}" \
    --env "STATIC_SDK_CHECKSUM=${static_sdk_checksum}" \
    --env "SDK_TRIPLE=${sdk_triple}" \
    "${swift_image}" \
    bash -euo pipefail -c '
      package=/src/Targets/PTYHost
      watchdog=/src/scripts/linux/xctest-watchdog.sh
      echo "--- kernel $(uname -r), $(swift --version 2>&1 | head -1)"

      echo "--- ThreadingPTYHostKit tests"
      kit=/src/Packages/ThreadingPTYHostKit
      swift build --package-path "${kit}" --scratch-path /work/kit --build-tests
      "${watchdog}" "$(swift build --package-path "${kit}" --scratch-path /work/kit --show-bin-path)/ThreadingPTYHostKitPackageTests.xctest"

      echo "--- debug build and daemon tests"
      swift build --package-path "${package}" --scratch-path /work/debug --build-tests
      tests="$(swift build --package-path "${package}" --scratch-path /work/debug --show-bin-path)/ThreadingPTYHostPackageTests.xctest"
      "${watchdog}" "${tests}"

      if [[ "${BUILD_STATIC}" == 1 ]]; then
        echo "--- static release build (${SDK_TRIPLE})"
        if ! swift sdk list --swift-sdks-path /work/sdks 2>/dev/null | grep -q static-linux; then
          swift sdk install "${STATIC_SDK_URL}" --checksum "${STATIC_SDK_CHECKSUM}" \
            --swift-sdks-path /work/sdks
        fi
        # Stripped at link: debug info is two thirds of the unstripped file (149 MB against 57 MB
        # on arm64, measured), and the stripped binary is the one a host is handed.
        static=(--package-path "${package}" --scratch-path /work/static
          --swift-sdks-path /work/sdks --swift-sdk "${SDK_TRIPLE}" -c release -Xlinker -s)
        swift build "${static[@]}" --product threading-ptyd
        install -m 0755 "$(swift build "${static[@]}" --show-bin-path)/threading-ptyd" /out/threading-ptyd

        if ldd /out/threading-ptyd >/dev/null 2>&1; then
          echo "test-ptyd-linux: /out/threading-ptyd links dynamically" >&2
          ldd /out/threading-ptyd >&2
          exit 1
        fi
        echo "--- daemon tests against the static binary"
        THREADING_PTYD_EXECUTABLE=/out/threading-ptyd \
          "${watchdog}" "${tests}" ThreadingPTYHostTests.PTYHostDaemonTests
        ls -l /out/threading-ptyd
      fi
    '
}

for architecture in "${architectures[@]}"; do
  run_architecture "${architecture}"
done
echo "test-ptyd-linux: passed on ${architectures[*]}"
