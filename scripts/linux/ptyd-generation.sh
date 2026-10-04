# Sourced, not run. The generation a Linux `threading-ptyd` reports in `hello`.
#
# `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` and `THREADING_SOURCE_REVISION` from the
# environment — the same names as the Xcode build settings, so whatever builds an app passes the
# same three values to both. Unset, they are 0.0.0, 0.0.0 and this checkout's HEAD — the local
# autoinstaller's shape — and the revision is left out when the daemon's sources differ from HEAD
# (or there is no git checkout), because a binary must not claim a commit it was not built from.
#
#   threading_ptyd_generation <repository directory>
#
# sets `ptyd_short_version`, `ptyd_bundle_version` and `ptyd_source_revision`, and fails when a
# value has characters outside [A-Za-z0-9._+-]: each becomes a C string literal on a compiler
# command line. Shared by scripts/test-ptyd-linux.sh and scripts/build-controller-host.sh.

threading_ptyd_generation() {
  local repository="$1"
  ptyd_short_version="${MARKETING_VERSION:-0.0.0}"
  ptyd_bundle_version="${CURRENT_PROJECT_VERSION:-0.0.0}"
  if [[ -n "${THREADING_SOURCE_REVISION+set}" ]]; then
    ptyd_source_revision="${THREADING_SOURCE_REVISION}"
  else
    local daemon_sources=(Targets/PTYHost Packages/ThreadingPTYHostKit Packages/ThreadingPTYClient Packages/ThreadingDomain)
    if command -v git >/dev/null 2>&1 \
      && git -C "${repository}" rev-parse --verify --quiet HEAD >/dev/null 2>&1 \
      && git -C "${repository}" diff --quiet HEAD -- "${daemon_sources[@]}" \
      && [[ -z "$(git -C "${repository}" ls-files --others --exclude-standard -- "${daemon_sources[@]}")" ]]; then
      ptyd_source_revision="$(git -C "${repository}" rev-parse HEAD)"
    else
      ptyd_source_revision=""
      echo "ptyd-generation: the daemon's sources differ from HEAD (or are not a git checkout); the binary names no revision" >&2
    fi
  fi
  local value
  for value in "${ptyd_short_version}" "${ptyd_bundle_version}" "${ptyd_source_revision}"; do
    if [[ ! "${value}" =~ ^[A-Za-z0-9._+-]*$ ]]; then
      echo "ptyd-generation: generation value '${value}' has characters outside [A-Za-z0-9._+-]" >&2
      return 64
    fi
  done
}
