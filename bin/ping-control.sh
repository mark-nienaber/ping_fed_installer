#!/usr/bin/env bash
# =============================================================================
# bin/ping-control.sh — Lifecycle control for the Ping stack
#
#   Start / stop / restart / status for PingDirectory, PingFederate and
#   PingAccess, individually or as a whole stack (in dependency order).
#
#   PD must be up before PF (PF authenticates admins + stores sessions/grants
#   against PD); PF should be up before PA (PA uses PF as its token provider).
#   'start all' honours PD -> PF -> PA; 'stop all' reverses it.
#
# Usage:
#   ./bin/ping-control.sh start   [pd|pf|pa|all]   (default: all)
#   ./bin/ping-control.sh stop    [pd|pf|pa|all]
#   ./bin/ping-control.sh restart [pd|pf|pa|all]
#   ./bin/ping-control.sh status  [pd|pf|pa|all]
# =============================================================================
set -uo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_ROOT}/lib/logging.sh"
# pingconfig.env keys SCRIPT_DIR off $(pwd); pin it to the project root so this
# script works from any working directory.
cd "$SCRIPT_ROOT"
# shellcheck source=/dev/null
source "${SCRIPT_ROOT}/pingconfig.env"

PF_RUN_LOG="${LOG_DIR}/pingfederate-run.log"
PA_RUN_LOG="${LOG_DIR}/pingaccess-run.log"

# -----------------------------------------------------------------------------
# Shared helpers
# -----------------------------------------------------------------------------
_port_listening() {
    local port=$1
    (command -v ss >/dev/null && ss -ltn 2>/dev/null | grep -q ":${port} ") \
      || (command -v netstat >/dev/null && netstat -tuln 2>/dev/null | grep -q ":${port} ")
}

# HTTP status of an admin endpoint (000 if unreachable)
_http_code() {
    curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "$1" 2>/dev/null || echo "000"
}

# Precise JVM main-class signatures per product. Matching these (rather than the
# install path) avoids ever matching the invoking shell — a shell whose command
# line merely contains the install path would otherwise be caught and killed.
_PD_PAT='com\.unboundid\.directory\.server\.core\.DirectoryServer'
_PF_PAT='org\.pingidentity\.RunPF'
_PA_PAT='com\.pingidentity\.pa\.cli\.Starter'

# PIDs of the running JVM(s) matching a signature; never returns our own PID.
_pids_for() {
    pgrep -f "$1" 2>/dev/null | grep -vw "$$" | tr '\n' ' '
}

# Launch a foreground run.sh fully detached from this shell so it survives the
# controlling terminal / tool session (setsid = new session, no SIGHUP/SIGTERM
# inheritance). Used for PF and PA, which ship no daemonising start script.
_launch_detached() {
    local dir=$1 log=$2
    mkdir -p "$LOG_DIR"
    ( cd "$dir" && setsid bash -c 'exec ./bin/run.sh' >"$log" 2>&1 </dev/null & )
}

# Poll an admin endpoint until it answers or we time out.
_wait_http() {
    local name=$1 url=$2 timeout=${3:-180} waited=0 code
    info "Waiting for ${name} (up to ${timeout}s)..."
    while [[ $waited -lt $timeout ]]; do
        code=$(_http_code "$url")
        if [[ "$code" =~ ^(200|302|401|403)$ ]]; then
            success "${name} ready (HTTP ${code})"
            return 0
        fi
        sleep 5; waited=$((waited+5))
        [[ $((waited % 30)) -eq 0 ]] && info "  still waiting... (${waited}s, last HTTP ${code})"
    done
    error "${name} not ready after ${timeout}s"
    return 1
}

# TERM a set of PIDs, escalate to KILL if still alive after grace period.
_stop_pids() {
    local pids="$1" grace=${2:-30} waited=0
    [[ -z "${pids// }" ]] && return 0
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null
    while [[ $waited -lt $grace ]]; do
        local alive=0 p
        for p in $pids; do kill -0 "$p" 2>/dev/null && alive=1; done
        [[ $alive -eq 0 ]] && return 0
        sleep 2; waited=$((waited+2))
    done
    warning "Processes did not exit within ${grace}s; sending SIGKILL"
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null
    return 0
}

# =============================================================================
# PingDirectory
# =============================================================================
pd_start() {
    if _port_listening "$PINGDIR_LDAPS_PORT"; then
        success "PingDirectory already running (LDAPS ${PINGDIR_LDAPS_PORT})"
        return 0
    fi
    info "Starting PingDirectory..."
    "${PINGDIR_DIR}/bin/start-server" >/dev/null 2>&1 || { error "start-server failed"; return 1; }
    local waited=0
    while [[ $waited -lt 60 ]]; do
        _port_listening "$PINGDIR_LDAPS_PORT" && { success "PingDirectory LDAPS listening on ${PINGDIR_LDAPS_PORT}"; return 0; }
        sleep 3; waited=$((waited+3))
    done
    error "PingDirectory not listening on ${PINGDIR_LDAPS_PORT} after 60s"; return 1
}

pd_stop() {
    if ! _port_listening "$PINGDIR_LDAPS_PORT" && [[ -z "$(_pids_for "$_PD_PAT")" ]]; then
        info "PingDirectory already stopped"; return 0
    fi
    info "Stopping PingDirectory..."
    "${PINGDIR_DIR}/bin/stop-server" >/dev/null 2>&1 || _stop_pids "$(_pids_for "$_PD_PAT")"
    success "PingDirectory stopped"
}

pd_status() {
    if _port_listening "$PINGDIR_LDAPS_PORT"; then
        success "PingDirectory  RUNNING   (LDAP ${PINGDIR_LDAP_PORT}, LDAPS ${PINGDIR_LDAPS_PORT}, pid $(_pids_for "$_PD_PAT"))"
    else
        warning "PingDirectory  STOPPED"
    fi
}

# =============================================================================
# PingFederate
# =============================================================================
pf_start() {
    if _port_listening "$PINGFED_ADMIN_PORT"; then
        success "PingFederate already running (admin ${PINGFED_ADMIN_PORT})"
        return 0
    fi
    info "Starting PingFederate (detached)..."
    _launch_detached "$PINGFED_DIR" "$PF_RUN_LOG"
    _wait_http "PingFederate admin console" \
        "https://${PINGFED_HOSTNAME}:${PINGFED_ADMIN_PORT}/pingfederate/app" 180
}

pf_stop() {
    local pids; pids="$(_pids_for "$_PF_PAT")"
    if [[ -z "${pids// }" ]]; then info "PingFederate already stopped"; return 0; fi
    info "Stopping PingFederate (pid ${pids})..."
    _stop_pids "$pids"
    success "PingFederate stopped"
}

pf_status() {
    if _port_listening "$PINGFED_ADMIN_PORT"; then
        local code; code=$(_http_code "https://${PINGFED_HOSTNAME}:${PINGFED_ENGINE_PORT}/pf/heartbeat.ping")
        success "PingFederate   RUNNING   (admin ${PINGFED_ADMIN_PORT}, engine ${PINGFED_ENGINE_PORT} heartbeat HTTP ${code}, pid $(_pids_for "$_PF_PAT"))"
    else
        warning "PingFederate   STOPPED"
    fi
}

# =============================================================================
# PingAccess
# =============================================================================
pa_start() {
    if _port_listening "$PINGACCESS_ADMIN_PORT"; then
        success "PingAccess already running (admin ${PINGACCESS_ADMIN_PORT})"
        return 0
    fi
    info "Starting PingAccess (detached)..."
    _launch_detached "$PINGACCESS_DIR" "$PA_RUN_LOG"
    _wait_http "PingAccess admin console" \
        "https://${PINGACCESS_HOSTNAME}:${PINGACCESS_ADMIN_PORT}/" 180
}

pa_stop() {
    local pids; pids="$(_pids_for "$_PA_PAT")"
    if [[ -z "${pids// }" ]]; then info "PingAccess already stopped"; return 0; fi
    info "Stopping PingAccess (pid ${pids})..."
    _stop_pids "$pids"
    success "PingAccess stopped"
}

pa_status() {
    if _port_listening "$PINGACCESS_ADMIN_PORT"; then
        local code; code=$(_http_code "https://${PINGACCESS_HOSTNAME}:${PINGACCESS_ENGINE_PORT}/")
        success "PingAccess     RUNNING   (admin ${PINGACCESS_ADMIN_PORT}, engine ${PINGACCESS_ENGINE_PORT} HTTP ${code}, pid $(_pids_for "$_PA_PAT"))"
    else
        warning "PingAccess     STOPPED"
    fi
}

# =============================================================================
# Dispatch
# =============================================================================
ACTION="${1:-status}"
TARGET="${2:-all}"

case "$TARGET" in
    pd|pf|pa|all) : ;;
    *) error "Unknown target '$TARGET' (expected: pd|pf|pa|all)"; exit 2 ;;
esac

do_action() {
    local prod=$1 act=$2
    case "$act" in
        start)   ${prod}_start ;;
        stop)    ${prod}_stop ;;
        status)  ${prod}_status ;;
        restart) ${prod}_stop; ${prod}_start ;;
    esac
}

case "$ACTION" in
    start|restart)   order="pd pf pa" ;;   # dependency order
    stop)            order="pa pf pd" ;;   # reverse
    status)          order="pd pf pa" ;;
    *) error "Unknown action '$ACTION' (expected: start|stop|restart|status)"; exit 2 ;;
esac

banner "Ping stack — ${ACTION} (${TARGET})"
rc=0
for prod in $order; do
    [[ "$TARGET" == "all" || "$TARGET" == "$prod" ]] || continue
    do_action "$prod" "$ACTION" || rc=1
done
exit $rc
