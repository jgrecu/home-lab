#!/usr/bin/env bash
set -Eeuo pipefail

# Ensure gum is available before anything else
if ! command -v gum &>/dev/null; then
    printf "ERROR: 'gum' is required but not installed. See https://github.com/charmbracelet/gum\n" >&2
    exit 1
fi

# Log messages with different levels using gum
# Usage: log <level> <message> [key=value ...]
# Levels: debug, info, warn, error (error also exits with code 1)
function log() {
    local level="${1:-info}"
    local msg="${2:-}"
    shift 2 || true

    # Build structured key/value args for gum log
    local -a fields=()
    for item in "$@"; do
        if [[ "${item}" == *=* ]]; then
            fields+=("${item%%=*}" "${item#*=}")
        else
            fields+=("${item}")
        fi
    done

    # Route errors to stderr, everything else to stdout
    if [[ "${level}" == "error" ]]; then
        GUM_LOG_LEVEL="${LOG_LEVEL:-info}" \
            gum log --level error --time="2006-01-02T15:04:05Z" --structured \
            "${msg}" "${fields[@]}" >&2
        exit 1
    else
        GUM_LOG_LEVEL="${LOG_LEVEL:-info}" \
            gum log --level "${level}" --time="2006-01-02T15:04:05Z" --structured \
            "${msg}" "${fields[@]}"
    fi
}

# Check if required environment variables are set
function check_env() {
    local envs=("${@}")
    local missing=()
    local values=()

    for env in "${envs[@]}"; do
        if [[ -z "${!env-}" ]]; then
            missing+=("${env}")
        else
            values+=("${env}=${!env}")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log error "Missing required env variables" "envs=${missing[*]}"
    fi

    log debug "Env variables are set" "envs=${values[*]}"
}

# Check if required CLI tools are installed
function check_cli() {
    local deps=("${@}")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "${dep}" &>/dev/null; then
            missing+=("${dep}")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log error "Missing required deps" "deps=${missing[*]}"
    fi

    log debug "Deps are installed" "deps=${deps[*]}"
}
