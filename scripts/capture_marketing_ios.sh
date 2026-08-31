#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
manifest="${repository_directory}/Tests/UIEvidence/ios-coverage.json"
theme="threading"
requested_output=""
simulator="booted"

usage() {
  cat <<'EOF'
Usage: scripts/capture_marketing_ios.sh [options]

Capture five iOS marketing checkpoints and record their fixed-clock product walkthrough.

Options:
  --theme ID          One ios-coverage.json theme for the complete flow (default: threading)
  --output PATH       New artifact directory (default: .build/marketing-ios/<theme>-<time>)
  --simulator UDID    Simulator template passed to ui-evidence-ios.sh (default: booted)
  -h, --help          Show this help
EOF
}

while (($#)); do
  case "$1" in
    --theme)
      (($# >= 2)) || { printf 'error: --theme needs a value\n' >&2; exit 2; }
      theme="$2"
      shift 2
      ;;
    --output)
      (($# >= 2)) || { printf 'error: --output needs a value\n' >&2; exit 2; }
      requested_output="$2"
      shift 2
      ;;
    --simulator)
      (($# >= 2)) || { printf 'error: --simulator needs a value\n' >&2; exit 2; }
      simulator="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# The whole capture, in one named function.
#
# `Tests/UIEvidence/ios-coverage.json` names this as the entry point behind `ios-marketing-flow`,
# and `UIEvidenceRenderTests` checks that the name resolves — a manifest that points at nothing is
# how evidence quietly stops being produced. It shipped straight-line, so the claim was false and
# the check failed. Its sibling `ui-evidence-ios.sh` states `capture_fixture` the same way.
capture() {
  for command in ffmpeg ffprobe jq python3; do
    command -v "${command}" >/dev/null || {
      printf 'error: required command is unavailable: %s\n' "${command}" >&2
      exit 1
    }
  done
  if ! jq -e --arg theme "${theme}" '.themeIDs | index($theme) != null' \
      "${manifest}" >/dev/null; then
    printf 'error: unknown marketing theme: %s\n' "${theme}" >&2
    exit 2
  fi

  if [[ -n "${requested_output}" ]]; then
    case "${requested_output}" in
      /*) output_directory="${requested_output}" ;;
      *) output_directory="${repository_directory}/${requested_output}" ;;
    esac
  else
    run_id="$(date -u +'%Y%m%d-%H%M%S')"
    output_directory="${repository_directory}/.build/marketing-ios/${theme}-${run_id}"
  fi
  if [[ -e "${output_directory}" ]]; then
    printf 'error: marketing output already exists: %s\n' "${output_directory}" >&2
    exit 2
  fi

  evidence_directory="${output_directory}/evidence"
  video="${output_directory}/threading-ios-${theme}.mp4"
  "${script_directory}/ui-evidence-ios.sh" \
    --only ios-marketing-flow \
    --theme "${theme}" \
    --simulator "${simulator}" \
    --output "${evidence_directory}" \
    --record-marketing-video "${video}"

  screenshots_directory="${output_directory}/screenshots"
  mkdir -p "${screenshots_directory}"
  while IFS=$'\t' read -r capture_id filename; do
    cp "${evidence_directory}/current/ios/${capture_id}.png" \
      "${screenshots_directory}/${filename}"
  done < <(jq -r '
    .flows[] | select(.id == "ios-marketing-flow") | .shots[]
    | [.captureID, .filename] | @tsv
  ' "${manifest}")

  printf '\nMarketing screenshots: %s\n' "${screenshots_directory}"
  printf 'Marketing video: %s\n' "${video}"
  printf 'Evidence report: %s\n' "${evidence_directory}/report/index.html"
}

capture
