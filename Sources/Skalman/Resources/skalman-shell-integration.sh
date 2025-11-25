#!/bin/bash
# Skalman Terminal Shell Integration
# Source this file in your .bashrc or .zshrc to enable AI output analysis
#
# Usage: source /path/to/skalman-shell-integration.sh

# Only enable if running inside Skalman
if [[ "$TERM_PROGRAM" != "Skalman" ]]; then
    return 0 2>/dev/null || exit 0
fi

# Configuration
__skalman_output_file="${TMPDIR:-/tmp}/skalman-last-output.txt"
__skalman_cmd_file="${TMPDIR:-/tmp}/skalman-last-cmd.txt"
__skalman_exit_file="${TMPDIR:-/tmp}/skalman-last-exit.txt"
__skalman_last_cmd=""
__skalman_enabled=1

# Disable output capture
skalman_disable_capture() {
    __skalman_enabled=0
    echo "Skalman output capture disabled"
}

# Enable output capture
skalman_enable_capture() {
    __skalman_enabled=1
    echo "Skalman output capture enabled"
}

# Send OSC 1337 sequence to notify Skalman of captured output
__skalman_notify() {
    local cmd="$1"
    local exit_code="$2"
    # OSC 1337 sequence: \e]1337;....\a
    printf '\e]1337;SkalmanOutput=%s;ExitCode=%d;Cmd=%s\a' \
        "$__skalman_output_file" \
        "$exit_code" \
        "$cmd"
}

# Pre-execution hook
__skalman_preexec() {
    [[ "$__skalman_enabled" -eq 0 ]] && return

    local cmd="$1"
    [[ -z "$cmd" ]] && return
    [[ "$cmd" == __skalman_* ]] && return
    [[ "$cmd" == "sk "* ]] && return

    __skalman_last_cmd="$cmd"
}

# Post-execution hook
__skalman_postexec() {
    local exit_code=$?

    [[ "$__skalman_enabled" -eq 0 ]] && return
    [[ -z "$__skalman_last_cmd" ]] && return

    # Save command and exit code
    echo "$__skalman_last_cmd" > "$__skalman_cmd_file"
    echo "$exit_code" > "$__skalman_exit_file"

    # Notify Skalman via OSC 1337
    __skalman_notify "$__skalman_last_cmd" "$exit_code"

    __skalman_last_cmd=""
}

# Bash setup
if [[ -n "$BASH_VERSION" ]]; then
    __skalman_bash_preexec() {
        [[ -n "$COMP_LINE" ]] && return
        [[ "$BASH_COMMAND" == "$PROMPT_COMMAND" ]] && return
        [[ "$BASH_COMMAND" == __skalman_* ]] && return

        __skalman_preexec "$BASH_COMMAND"
    }

    trap '__skalman_bash_preexec' DEBUG

    if [[ -z "$PROMPT_COMMAND" ]]; then
        PROMPT_COMMAND="__skalman_postexec"
    else
        PROMPT_COMMAND="__skalman_postexec;${PROMPT_COMMAND}"
    fi
fi

# Zsh setup
if [[ -n "$ZSH_VERSION" ]]; then
    autoload -Uz add-zsh-hook

    __skalman_zsh_preexec() {
        __skalman_preexec "$1"
    }

    __skalman_zsh_precmd() {
        __skalman_postexec
    }

    add-zsh-hook preexec __skalman_zsh_preexec
    add-zsh-hook precmd __skalman_zsh_precmd
fi

# Function to run a command and capture its output (for explicit capture)
sk() {
    "$@" 2>&1 | tee "$__skalman_output_file"
    local exit_code=${PIPESTATUS[0]}
    echo "$*" > "$__skalman_cmd_file"
    echo "$exit_code" > "$__skalman_exit_file"
    __skalman_notify "$*" "$exit_code"
    return $exit_code
}

echo "Skalman shell integration loaded. Use Cmd+Shift+E to analyze command output."
echo "  Tip: Use 'sk <command>' to explicitly capture output for analysis."
