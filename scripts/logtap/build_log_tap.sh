#!/usr/bin/env bash
# Builds the Threading log tap for one platform and prints how to use it.
#
# The tap makes an app's stdout and stderr readable from the Mac as ordinary os_log entries, which
# is the only way to see `print()` output at all: it never reaches the unified log otherwise.
# See docs/feature-drafts/device-and-simulator-logs.md.
#
#   build_log_tap.sh iphoneos              # a real device: a static archive to force-load
#   build_log_tap.sh iphonesimulator       # a simulator: a dylib to inject at launch
#   build_log_tap.sh macosx                # a Mac app: a dylib to inject at launch
set -euo pipefail

platform="${1:-iphoneos}"
out="${THREADING_LOG_TAP_DIR:-${HOME}/Library/Caches/codes.threading/logtap}/${platform}"
source_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/threading_log_tap.c"
mkdir -p "${out}"

case "${platform}" in
  iphoneos)          target="arm64-apple-ios17.0" ;;
  iphonesimulator)   target="arm64-apple-ios17.0-simulator" ;;
  macosx)            target="arm64-apple-macos13.0" ;;
  *) printf 'error: unknown platform %s\n' "${platform}" >&2; exit 64 ;;
esac

sdk="$(xcrun --sdk "${platform}" --show-sdk-path)"

if [[ "${platform}" == "iphoneos" ]]; then
  # A device cannot have a dylib inserted at launch, so the tap is a static archive compiled into
  # the app by the linker. Nothing to embed, nothing extra to sign.
  xcrun -sdk "${platform}" clang -c -target "${target}" -isysroot "${sdk}" -O2 \
      "${source_file}" -o "${out}/threading_log_tap.o"
  xcrun -sdk "${platform}" ar rcs "${out}/libthreadingtap.a" "${out}/threading_log_tap.o"
  archive="${out}/libthreadingtap.a"
  cat <<EOF
Built ${archive}

Add it to a build. A command-line build setting is used rather than an -xcconfig on purpose:
a target that sets OTHER_LDFLAGS without \$(inherited) silently overrides an xcconfig, and many
projects do. A command-line setting outranks the target, and \$(inherited) keeps its own flags.

  xcodebuild -project <Project>.xcodeproj -scheme <Scheme> -configuration Debug \\
    -destination 'generic/platform=iOS' \\
    OTHER_LDFLAGS='\$(inherited) -Wl,-force_load,${archive}'

This links the tap into every target in that build. The tap installs once per process regardless,
guarded by a ${platform} process-global marker, so an app and the frameworks it embeds do not each
capture stdout.
EOF
else
  xcrun -sdk "${platform}" clang -dynamiclib -target "${target}" -isysroot "${sdk}" -O2 \
      "${source_file}" -o "${out}/libthreadingtap.dylib"
  dylib="${out}/libthreadingtap.dylib"
  echo "Built ${dylib}"
  echo
  if [[ "${platform}" == "iphonesimulator" ]]; then
    cat <<EOF
Inject it at launch. No build change at all:

  SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=${dylib} \\
    xcrun simctl launch --terminate-running-process <udid> <bundle-id>
EOF
  else
    cat <<EOF
Inject it at launch. No build change at all:

  DYLD_INSERT_LIBRARIES=${dylib} ./YourApp.app/Contents/MacOS/YourApp
EOF
  fi
fi
