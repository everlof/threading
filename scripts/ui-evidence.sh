#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
manifest="${repository_directory}/Tests/UIEvidence/coverage.json"
baseline_directory="${repository_directory}/Tests/UIEvidence/Baselines"
requested_output=""
accept_new_baselines=0
require_accepted=0
requested_only=""
requested_theme=""
journey_evidence_arguments=()

usage() {
  cat <<'EOF'
Usage: scripts/ui-evidence.sh [options]

Render the checked-in component and surface catalogue and build a static HTML report.

Options:
  --output PATH                 Use a new run directory instead of .build/ui-evidence-reports/…
  --journey-evidence PATH       Include evidence.json (or its report directory); repeatable
  --only ID[,ID…]               Capture only these coverage entries
  --theme ID                    For app-theme-chrome-matrix, render one stock theme id
  --accept-new-baselines        Copy only captures that do not have an approved baseline yet
  --require-accepted            Fail unless every rendered image exactly matches a baseline
  -h, --help                    Show this help
EOF
}

while (($#)); do
  case "$1" in
    --output)
      if (($# < 2)); then
        printf 'error: --output requires a path\n' >&2
        exit 2
      fi
      requested_output="$2"
      shift 2
      ;;
    --journey-evidence)
      if (($# < 2)); then
        printf 'error: --journey-evidence requires a path\n' >&2
        exit 2
      fi
      journey_evidence_arguments+=("--journey-evidence" "$2")
      shift 2
      ;;
    --accept-new-baselines)
      accept_new_baselines=1
      shift
      ;;
    --only)
      if (($# < 2)); then
        printf 'error: --only requires one or more comma-separated coverage entries\n' >&2
        exit 2
      fi
      requested_only="$2"
      shift 2
      ;;
    --theme)
      if (($# < 2)); then
        printf 'error: --theme requires a stock theme id\n' >&2
        exit 2
      fi
      requested_theme="$2"
      shift 2
      ;;
    --require-accepted)
      require_accepted=1
      shift
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

if [[ -n "${requested_output}" ]]; then
  case "${requested_output}" in
    /*) run_directory="${requested_output}" ;;
    *) run_directory="${repository_directory}/${requested_output}" ;;
  esac
else
  run_identifier="$(date -u +'%Y%m%d-%H%M%S')-$$"
  reports_root="${repository_directory}/.build/ui-evidence-reports"
  mkdir -p "${reports_root}"
  run_directory="${reports_root}/${run_identifier}"
fi

if [[ -e "${run_directory}" ]]; then
  printf 'error: UI evidence output already exists: %s\n' "${run_directory}" >&2
  exit 2
fi

current_directory="${run_directory}/current"
report_directory="${run_directory}/report"
# Evidence rendering is often run while Instruments or another test task is building the app.
# Keep its incremental products separate so those workflows cannot contend for Xcode's build.db.
derived_data_directory="${repository_directory}/.build/ui-evidence-derived-data"
mkdir -p "${current_directory}"

selected_tests=()
selection_arguments=()
if [[ -n "${requested_theme}" ]]; then
  if [[ -n "${requested_only}" && "${requested_only}" != "app-theme-chrome-matrix" ]]; then
    printf 'error: --theme can only target app-theme-chrome-matrix\n' >&2
    exit 2
  fi
  requested_only="app-theme-chrome-matrix"
fi
if [[ -n "${requested_only}" ]]; then
  IFS=',' read -r -a requested_entries <<<"${requested_only}"
  for entry in "${requested_entries[@]}"; do
    [[ -n "${entry}" ]] || continue
    selection_arguments+=(--only-entry "${entry}")
  done
fi
while IFS= read -r selector; do
  [[ -n "${selector}" ]] || continue
  selected_tests+=("-only-testing:${selector}")
done < <(
  python3 "${script_directory}/generate_ui_evidence_report.py" \
    --manifest "${manifest}" \
    --list-tests \
    "${selection_arguments[@]}"
)

if ((${#selected_tests[@]} == 0)); then
  printf 'error: UI evidence manifest selected no render tests\n' >&2
  exit 1
fi

cd "${repository_directory}"
export THREADING_RENDER_OUT="${current_directory}"
export THREADING_UI_EVIDENCE_OUT="${current_directory}"
if [[ -n "${requested_theme}" ]]; then
  export THREADING_UI_EVIDENCE_THEME_ID="${requested_theme}"
fi

scripts/test.sh fast -derivedDataPath "${derived_data_directory}" "${selected_tests[@]}"

generator_arguments=(
  --manifest "${manifest}"
  --current "${current_directory}"
  --baseline "${baseline_directory}"
  --output "${report_directory}"
)
generator_arguments+=("${journey_evidence_arguments[@]}")
generator_arguments+=("${selection_arguments[@]}")
generator_arguments+=(--environment "runner=macOS AppKit render tests")
if [[ -n "${requested_theme}" ]]; then
  generator_arguments+=(--environment "theme=${requested_theme}")
fi
if ((accept_new_baselines)); then
  generator_arguments+=(--accept-new-baselines)
fi
if ((require_accepted)); then
  generator_arguments+=(--require-accepted)
fi

set +e
report_path="$(python3 "${script_directory}/generate_ui_evidence_report.py" "${generator_arguments[@]}")"
generator_status=$?
set -e
if [[ -n "${report_path}" ]]; then
  printf '\nUI evidence report: %s\n' "${report_path}"
  printf 'Regression approval: %s/regression.html\n' "${report_directory}"
  printf 'Open it with: open %q\n' "${report_path}"
fi
if ((generator_status != 0)); then
  exit "${generator_status}"
fi
