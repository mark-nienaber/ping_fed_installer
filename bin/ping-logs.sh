#!/usr/bin/env bash
# =============================================================================
# bin/ping-logs.sh — Quick access to the primary logs of each Ping product.
#
#   Shows (or follows) the main server log for PingDirectory, PingFederate or
#   PingAccess, plus the installer-captured run logs. Handy during config
#   iteration and troubleshooting.
#
# Usage:
#   ./bin/ping-logs.sh <pd|pf|pa|all> [-f] [-n LINES]   (default: all, 40 lines)
#     -f          follow (tail -f) instead of a one-shot tail
#     -n LINES    number of trailing lines to show (default 40)
#     -e          show the error/exception lines only
# =============================================================================
set -uo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_ROOT}/lib/logging.sh"
cd "$SCRIPT_ROOT"
# shellcheck source=/dev/null
source "${SCRIPT_ROOT}/pingconfig.env"

TARGET="all"; FOLLOW=0; LINES=40; ERRORS_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        pd|pf|pa|all) TARGET="$1" ;;
        -f) FOLLOW=1 ;;
        -e) ERRORS_ONLY=1 ;;
        -n) shift; LINES="${1:-40}" ;;
        *) error "Unknown arg '$1'"; exit 2 ;;
    esac
    shift
done

# Primary log file per product (first existing wins for the header tail).
pd_logs() { echo "${PINGDIR_DIR}/logs/errors" "${PINGDIR_DIR}/logs/access"; }
pf_logs() { echo "${PINGFED_DIR}/log/server.log" "${PINGFED_DIR}/log/admin-api.log" "${LOG_DIR}/pingfederate-run.log"; }
pa_logs() { echo "${PINGACCESS_DIR}/log/pingaccess.log" "${LOG_DIR}/pingaccess-run.log"; }

show_one() {
    local label=$1; shift
    local files=("$@") shown=0
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        section "${label}: ${f}"
        if [[ $ERRORS_ONLY -eq 1 ]]; then
            grep -iE 'error|severe|exception|fail|warn' "$f" 2>/dev/null | tail -n "$LINES" || true
        else
            tail -n "$LINES" "$f" 2>/dev/null || true
        fi
        shown=1
    done
    [[ $shown -eq 0 ]] && warning "${label}: no log files found"
}

# Follow mode: tail -f the primary log(s) of the single selected product.
if [[ $FOLLOW -eq 1 ]]; then
    [[ "$TARGET" == "all" ]] && { error "-f requires a single product (pd|pf|pa)"; exit 2; }
    files=$(${TARGET}_logs)
    existing=()
    for f in $files; do [[ -f "$f" ]] && existing+=("$f"); done
    [[ ${#existing[@]} -eq 0 ]] && { error "No log files present for ${TARGET}"; exit 1; }
    info "Following: ${existing[*]}  (Ctrl-C to stop)"
    exec tail -n "$LINES" -f "${existing[@]}"
fi

banner "Ping logs — ${TARGET}"
for p in pd pf pa; do
    [[ "$TARGET" == "all" || "$TARGET" == "$p" ]] || continue
    case "$p" in
        pd) show_one "PingDirectory" $(pd_logs) ;;
        pf) show_one "PingFederate"  $(pf_logs) ;;
        pa) show_one "PingAccess"    $(pa_logs) ;;
    esac
done
