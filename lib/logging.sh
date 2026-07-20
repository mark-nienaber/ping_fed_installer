#!/usr/bin/env bash
# =============================================================================
# lib/logging.sh — Shared logging library for Ping (PD + PF + PA) Installer
#
# Provides consistent, professional CLI output across all installer scripts.
# Cross-platform: Linux + macOS (bash 3.2+). Respects NO_COLOR, dumb terminals.
#
# Usage:  source "$(dirname "${BASH_SOURCE[0]}")/../lib/logging.sh"
# =============================================================================

# Guard against double-sourcing
[[ -n "${_PLATFORM_LOGGING_LOADED:-}" ]] && return 0
_PLATFORM_LOGGING_LOADED=1

# ---------------------------------------------------------------------------
# Terminal capability detection
# ---------------------------------------------------------------------------
_COLOR_SUPPORTED=0
_UNICODE_SUPPORTED=0
_TERM_WIDTH=80
_IS_TTY=0

_detect_terminal() {
    # TTY check
    if [[ -t 1 ]]; then
        _IS_TTY=1
    fi

    # Color support: respect NO_COLOR (https://no-color.org/)
    if [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-dumb}" != "dumb" ]] && [[ $_IS_TTY -eq 1 ]]; then
        local colors=0
        colors=$(tput colors 2>/dev/null || printf '0')
        if [[ "$colors" -ge 8 ]]; then
            _COLOR_SUPPORTED=1
        fi
    fi

    # Unicode support
    local lang="${LANG:-}${LC_ALL:-}${LC_CTYPE:-}"
    case "$lang" in
        *UTF-8*|*utf-8*|*utf8*|*UTF8*)
            _UNICODE_SUPPORTED=1
            ;;
        *)
            # macOS fallback
            if command -v locale >/dev/null 2>&1; then
                local charmap
                charmap=$(locale charmap 2>/dev/null || printf '')
                if [[ "$charmap" == "UTF-8" ]]; then
                    _UNICODE_SUPPORTED=1
                fi
            fi
            ;;
    esac

    # Terminal width
    if [[ $_IS_TTY -eq 1 ]]; then
        _TERM_WIDTH=$(tput cols 2>/dev/null || printf '80')
    fi
}

_detect_terminal

# ---------------------------------------------------------------------------
# Color and symbol definitions
# ---------------------------------------------------------------------------
if [[ $_COLOR_SUPPORTED -eq 1 ]]; then
    _C_RESET=$'\033[0m'
    _C_BOLD=$'\033[1m'
    _C_DIM=$'\033[2m'
    _C_BLUE=$'\033[34m'
    _C_GREEN=$'\033[32m'
    _C_YELLOW=$'\033[33m'
    _C_RED=$'\033[31m'
    _C_CYAN=$'\033[36m'
    _C_WHITE=$'\033[37m'
else
    _C_RESET="" _C_BOLD="" _C_DIM="" _C_BLUE="" _C_GREEN=""
    _C_YELLOW="" _C_RED="" _C_CYAN="" _C_WHITE=""
fi

if [[ $_UNICODE_SUPPORTED -eq 1 ]]; then
    _SYM_CHECK="✔"
    _SYM_CROSS="✖"
    _SYM_WARN="⚠"
    _SYM_BULLET="•"
    _SYM_ARROW="›"
    _SYM_DASH="─"
else
    _SYM_CHECK="ok"
    _SYM_CROSS="!!"
    _SYM_WARN="!!"
    _SYM_BULLET="*"
    _SYM_ARROW=">"
    _SYM_DASH="-"
fi

# ---------------------------------------------------------------------------
# Timestamp
# ---------------------------------------------------------------------------
_timestamp() {
    printf '[%s]' "$(date '+%H:%M:%S')"
}

# ---------------------------------------------------------------------------
# Core logging functions
# ---------------------------------------------------------------------------
info() {
    printf '%s  %s%s%s  %s\n' "$(_timestamp)" "$_C_BLUE" "$_SYM_BULLET" "$_C_RESET" "$*"
}

success() {
    printf '%s  %s%s%s  %s\n' "$(_timestamp)" "$_C_GREEN" "$_SYM_CHECK" "$_C_RESET" "$*"
}

warning() {
    printf '%s  %s%s%s  %s\n' "$(_timestamp)" "$_C_YELLOW" "$_SYM_WARN" "$_C_RESET" "$*"
}

error() {
    printf '%s  %s%s%s  %s\n' "$(_timestamp)" "$_C_RED" "$_SYM_CROSS" "$_C_RESET" "$*"
    printf '%s  %s%s%s  %s\n' "$(_timestamp)" "$_C_RED" "$_SYM_CROSS" "$_C_RESET" "$*" >&2
}

debug() {
    if [[ -n "${PLATFORM_DEBUG:-}" ]]; then
        printf '%s  %s[DBG]%s  %s\n' "$(_timestamp)" "$_C_DIM" "$_C_RESET" "$*"
    fi
}

# ---------------------------------------------------------------------------
# Banners and sections
# ---------------------------------------------------------------------------
_repeat_char() {
    local char="$1" count="$2" i
    for (( i=0; i<count; i++ )); do
        printf '%s' "$char"
    done
}

banner() {
    local text="$1"
    local width=70
    local line
    line=$(_repeat_char "=" "$width")
    printf '\n%s%s%s\n' "$_C_BOLD" "$line" "$_C_RESET"
    printf '%s  %s%s\n' "$_C_BOLD" "$text" "$_C_RESET"
    printf '%s%s%s\n\n' "$_C_BOLD" "$line" "$_C_RESET"
}

banner_with_time() {
    local text="$1"
    local time_str="$2"
    local width=70
    local line
    line=$(_repeat_char "=" "$width")
    local padding=$(( width - ${#text} - ${#time_str} - 4 ))
    if [[ $padding -lt 1 ]]; then padding=1; fi
    local spaces
    spaces=$(_repeat_char " " "$padding")
    printf '\n%s%s%s\n' "$_C_BOLD" "$line" "$_C_RESET"
    printf '%s  %s%s%s%s\n' "$_C_BOLD" "$text" "$spaces" "$time_str" "$_C_RESET"
    printf '%s%s%s\n\n' "$_C_BOLD" "$line" "$_C_RESET"
}

section() {
    local text="$1"
    printf '\n%s%s--- %s ---%s\n' "$_C_DIM" "$_C_BOLD" "$text" "$_C_RESET"
}

# ---------------------------------------------------------------------------
# Elapsed time formatting
# ---------------------------------------------------------------------------
_INSTALL_START_TIME=${_INSTALL_START_TIME:-$(date +%s)}

elapsed_since() {
    local start="$1"
    local now diff
    now=$(date +%s)
    diff=$(( now - start ))
    if [[ $diff -ge 3600 ]]; then
        printf '%dh %dm %ds' $(( diff / 3600 )) $(( (diff % 3600) / 60 )) $(( diff % 60 ))
    elif [[ $diff -ge 60 ]]; then
        printf '%dm %ds' $(( diff / 60 )) $(( diff % 60 ))
    else
        printf '%ds' "$diff"
    fi
}

total_elapsed() {
    elapsed_since "$_INSTALL_START_TIME"
}

# ---------------------------------------------------------------------------
# Step tracking (used by orchestrator)
# ---------------------------------------------------------------------------
_TOTAL_STEPS=0
_CURRENT_STEP=0
_STEP_START_TIME=0
_STEP_NAME=""

step_init() {
    _TOTAL_STEPS="${1:-0}"
    _CURRENT_STEP=0
    _INSTALL_START_TIME=$(date +%s)
}

step_begin() {
    _STEP_NAME="$1"
    _CURRENT_STEP=$(( _CURRENT_STEP + 1 ))
    _STEP_START_TIME=$(date +%s)
    printf '\n%s%s==> [%d/%d] %s%s\n' "$_C_BOLD" "$_C_CYAN" "$_CURRENT_STEP" "$_TOTAL_STEPS" "$_STEP_NAME" "$_C_RESET"
}

step_end() {
    local elapsed
    elapsed=$(elapsed_since "$_STEP_START_TIME")
    printf '%s    [%d/%d] completed (%s)%s\n' "$_C_DIM" "$_CURRENT_STEP" "$_TOTAL_STEPS" "$elapsed" "$_C_RESET"
}

# ---------------------------------------------------------------------------
# Task tracking (used by configure_am.sh for API calls)
# ---------------------------------------------------------------------------
_TASK_COUNT=0
_TASK_OK_COUNT=0
_TASK_FAIL_COUNT=0

task_reset() {
    _TASK_COUNT=0
    _TASK_OK_COUNT=0
    _TASK_FAIL_COUNT=0
}

task_begin() {
    local name="$1"
    local max_dots=$(( _TERM_WIDTH - ${#name} - 12 ))
    if [[ $max_dots -lt 4 ]]; then max_dots=4; fi
    local dots
    dots=$(_repeat_char "." "$max_dots")
    # Print task name with dots, no newline — task_end completes the line
    printf '  %s%s%s %s %s' "$_C_DIM" "$_SYM_ARROW" "$_C_RESET" "$name" "$_C_DIM$dots$_C_RESET "
    _TASK_COUNT=$(( _TASK_COUNT + 1 ))
}

task_end() {
    local result="${1:-ok}"
    local detail="${2:-}"
    case "$result" in
        ok|success)
            _TASK_OK_COUNT=$(( _TASK_OK_COUNT + 1 ))
            printf '%s%s%s\n' "$_C_GREEN" "$_SYM_CHECK" "$_C_RESET"
            ;;
        fail|error)
            _TASK_FAIL_COUNT=$(( _TASK_FAIL_COUNT + 1 ))
            if [[ -n "$detail" ]]; then
                printf '%s%s%s %s(%s)%s\n' "$_C_RED" "$_SYM_CROSS" "$_C_RESET" "$_C_RED" "$detail" "$_C_RESET"
            else
                printf '%s%s%s\n' "$_C_RED" "$_SYM_CROSS" "$_C_RESET"
            fi
            ;;
        skip)
            printf '%s-%s\n' "$_C_DIM" "$_C_RESET"
            ;;
    esac
}

task_summary() {
    if [[ $_TASK_FAIL_COUNT -gt 0 ]]; then
        printf '  %s[%d/%d tasks completed, %d failed]%s\n' "$_C_RED" "$_TASK_OK_COUNT" "$_TASK_COUNT" "$_TASK_FAIL_COUNT" "$_C_RESET"
    else
        printf '  %s[%d/%d tasks completed]%s\n' "$_C_DIM" "$_TASK_OK_COUNT" "$_TASK_COUNT" "$_C_RESET"
    fi
}

# ---------------------------------------------------------------------------
# Summary table (used by orchestrator at end)
# ---------------------------------------------------------------------------
_SUMMARY_NAMES=()
_SUMMARY_STATUSES=()
_SUMMARY_RESULTS=()

summary_init() {
    _SUMMARY_NAMES=()
    _SUMMARY_STATUSES=()
    _SUMMARY_RESULTS=()
}

summary_add() {
    local name="$1" status="$2" result="$3"
    _SUMMARY_NAMES[${#_SUMMARY_NAMES[@]}]="$name"
    _SUMMARY_STATUSES[${#_SUMMARY_STATUSES[@]}]="$status"
    _SUMMARY_RESULTS[${#_SUMMARY_RESULTS[@]}]="$result"
}

summary_print() {
    local time_str
    time_str="Total time: $(total_elapsed)"
    banner_with_time "Installation Summary" "$time_str"

    # Header
    printf '  %s%-20s %-16s %s%s\n' "$_C_BOLD" "Component" "Status" "Result" "$_C_RESET"
    printf '  %-20s %-16s %s\n' "$(_repeat_char "$_SYM_DASH" 18)" "$(_repeat_char "$_SYM_DASH" 14)" "$(_repeat_char "$_SYM_DASH" 6)"

    local ok_count=0 total_count=${#_SUMMARY_NAMES[@]}
    local i=0
    while [[ $i -lt $total_count ]]; do
        local name="${_SUMMARY_NAMES[$i]}"
        local status="${_SUMMARY_STATUSES[$i]}"
        local result="${_SUMMARY_RESULTS[$i]}"
        local sym
        case "$result" in
            ok)   sym="${_C_GREEN}  ${_SYM_CHECK}${_C_RESET}"; ok_count=$(( ok_count + 1 )) ;;
            fail) sym="${_C_RED}  ${_SYM_CROSS}${_C_RESET}" ;;
            skip) sym="${_C_DIM}  -${_C_RESET}" ;;
            *)    sym="  $result" ;;
        esac
        printf '  %-20s %-16s %b\n' "$name" "$status" "$sym"
        i=$(( i + 1 ))
    done

    printf '\n  %s%d of %d components installed successfully%s\n' "$_C_BOLD" "$ok_count" "$total_count" "$_C_RESET"
}

# Print access URLs in a clean aligned format
summary_urls() {
    printf '\n  %sAccess Points:%s\n' "$_C_BOLD" "$_C_RESET"
    while [[ $# -ge 2 ]]; do
        printf '    %-17s %s\n' "$1:" "$2"
        shift 2
    done

    local width=70
    printf '\n%s%s%s\n' "$_C_BOLD" "$(_repeat_char "=" "$width")" "$_C_RESET"
}
