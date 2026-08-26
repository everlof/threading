#!/usr/bin/env bash
# Shared, host-wide exclusion for Threading lanes that intentionally change CoreSimulator state.
# Source this file, then acquire the lane before reading or changing the device catalogue. The
# descriptor remains open until the calling shell exits, including through its cleanup trap.

threading_acquire_coresimulator_lane() {
    local lane_name="$1"
    if [[ "${THREADING_CORESIMULATOR_LOCK_HELD:-0}" == "1" ]]; then
        return 0
    fi

    if ! command -v lockf >/dev/null 2>&1; then
        printf 'error: lockf is required to coordinate CoreSimulator lanes\n' >&2
        return 69
    fi

    local user_temp_directory
    user_temp_directory="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
    if [[ -z "$user_temp_directory" ]]; then
        user_temp_directory="${TMPDIR:-/tmp}"
    fi
    local lock_path="${user_temp_directory%/}/codes.threading.coresimulator-lane.lock"

    if ! exec 9>>"$lock_path"; then
        printf 'error: could not open the CoreSimulator lane lock at %s\n' "$lock_path" >&2
        return 73
    fi
    if ! lockf -s -t 0 9; then
        local holder="another Threading lane"
        if [[ -s "$lock_path" ]]; then
            holder="$(tr '\n' ' ' < "$lock_path")"
            holder="${holder% }"
        fi
        exec 9>&-
        printf 'error: CoreSimulator is already reserved by %s; wait for it to finish and retry\n' \
            "$holder" >&2
        return 75
    fi

    THREADING_CORESIMULATOR_LOCK_HELD=1
    if ! printf '%s (pid %s, started %s UTC)\n' \
        "$lane_name" "$$" "$(date -u '+%Y-%m-%dT%H:%M:%S')" > "$lock_path"; then
        exec 9>&-
        THREADING_CORESIMULATOR_LOCK_HELD=0
        printf 'error: could not identify the CoreSimulator lane owner\n' >&2
        return 73
    fi
}
