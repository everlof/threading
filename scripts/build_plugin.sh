#!/usr/bin/env bash
# Builds one of Threading's own plugin packages the way a third party builds theirs.
#
# Usage: scripts/build_plugin.sh <plugin-package-dir> [--install]
#
# The recipe itself lives in the SDK, at Packages/ThreadingPluginKit/Tools/build-plugin.sh, and
# this is a thin wrapper that supplies the two things that are ours rather than anyone's: our
# reverse-DNS identifier and our signing identity. Keeping the steps in the SDK is what makes
# `NativePluginParityTests` meaningful — it exercises the script we hand out, not a private one.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package="${1:?usage: build_plugin.sh <plugin-package-dir> [--install]}"
package="$(cd "${package}" && pwd)"
name="$(basename "${package}")"

identity="${THREADING_PLUGIN_IDENTITY:-Developer ID Application: MJUKIS AB (SMQ3E8Y57T)}"
identifier="codes.threading.plugin.$(echo "${name}" | tr '[:upper:]' '[:lower:]' | sed 's/plugin$//')"

exec "${root}/Packages/ThreadingPluginKit/Tools/build-plugin.sh" \
    "${package}" \
    --identifier "${identifier}" \
    --identity "${identity}" \
    "${@:2}"
