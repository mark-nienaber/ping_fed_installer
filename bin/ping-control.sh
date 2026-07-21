#!/usr/bin/env bash
# =============================================================================
# bin/ping-control.sh — Lifecycle control for the whole Ping stack
#
#   Start / stop / restart / status for every component, individually or as a
#   whole system in dependency order:
#
#     pd   PingDirectory node 1        pd2  PingDirectory node 2  (if COUNT>1)
#     pf   PingFederate console        pf2  PingFederate engine   (if COUNT>1)
#     pa   PingAccess                  app  sample protected app
#     lb   HAProxy load balancer       (if LB_ENABLED)
#
#   'start all' order: PD nodes -> PF console -> PF engine -> PA -> app -> LB.
#   'stop all' reverses it. Which components are part of "all" is driven by the
#   *_COUNT / LB_ENABLED / INSTALL_SAMPLE_APP settings in pingconfig.env.
#
# Usage:
#   ./bin/ping-control.sh start   [pd|pd2|pf|pf2|pa|app|lb|all]   (default: all)
#   ./bin/ping-control.sh stop    [ ... ]
#   ./bin/ping-control.sh restart [ ... ]
#   ./bin/ping-control.sh status  [ ... ]
# =============================================================================
set -uo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_ROOT}/lib/logging.sh"
cd "$SCRIPT_ROOT"
# shellcheck source=/dev/null
source "${SCRIPT_ROOT}/pingconfig.env"

PF_RUN_LOG="${LOG_DIR}/pingfederate-run.log"
PF2_RUN_LOG="${LOG_DIR}/pingfederate2-run.log"
PA_RUN_LOG="${LOG_DIR}/pingaccess-run.log"
APP_RUN_LOG="${LOG_DIR}/sample-app.log"
APP_PORT="${SAMPLE_APP_TARGET##*:}"; APP_PORT="${APP_PORT%%/*}"

# -----------------------------------------------------------------------------
# Shared helpers
# -----------------------------------------------------------------------------
_port_listening() {
    (command -v ss >/dev/null && ss -ltn 2>/dev/null | grep -q ":${1} ") \
      || (command -v netstat >/dev/null && netstat -tuln 2>/dev/null | grep -q ":${1} ")
}
_http_code() { curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "$1" 2>/dev/null || echo "000"; }

# JVM PIDs by PingFederate install dir. The trailing space after the dir is a
# boundary so node 1 (pf.home=/ping/pingfederate ) never matches node 2
# (pf.home=/ping/pingfederate-2 ). Never returns our own shell.
_pf_pids() { pgrep -f "pf.home=$1 " 2>/dev/null | grep -vw "$$" | tr '\n' ' '; }
# Generic PIDs for a signature, excluding our own shell.
_pids_for() { pgrep -f "$1" 2>/dev/null | grep -vw "$$" | tr '\n' ' '; }
_PD_PAT='com\.unboundid\.directory\.server\.core\.DirectoryServer'
_PA_PAT='com\.pingidentity\.pa\.cli\.Starter'

_launch_detached() {
    local dir=$1 log=$2
    mkdir -p "$LOG_DIR"
    ( cd "$dir" && setsid bash -c 'exec ./bin/run.sh' >"$log" 2>&1 </dev/null & )
}
_wait_http() {
    local name=$1 url=$2 timeout=${3:-180} waited=0 code
    info "Waiting for ${name} (up to ${timeout}s)..."
    while [[ $waited -lt $timeout ]]; do
        code=$(_http_code "$url")
        [[ "$code" =~ ^(200|302|401|403)$ ]] && { success "${name} ready (HTTP ${code})"; return 0; }
        sleep 5; waited=$((waited+5))
        [[ $((waited % 30)) -eq 0 ]] && info "  still waiting... (${waited}s, last HTTP ${code})"
    done
    error "${name} not ready after ${timeout}s"; return 1
}
_stop_pids() {
    local pids="$1" grace=${2:-30} waited=0
    [[ -z "${pids// }" ]] && return 0
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null
    while [[ $waited -lt $grace ]]; do
        local alive=0 p; for p in $pids; do kill -0 "$p" 2>/dev/null && alive=1; done
        [[ $alive -eq 0 ]] && return 0
        sleep 2; waited=$((waited+2))
    done
    warning "Processes did not exit within ${grace}s; sending SIGKILL"
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null; return 0
}
# Start/stop a PingDirectory instance by dir + LDAPS port.
_pd_start() {
    local dir=$1 port=$2 name=$3
    _port_listening "$port" && { success "${name} already running (LDAPS ${port})"; return 0; }
    info "Starting ${name}..."
    "${dir}/bin/start-server" >/dev/null 2>&1 || { error "${name} start-server failed"; return 1; }
    local w=0; while [[ $w -lt 60 ]]; do _port_listening "$port" && { success "${name} LDAPS listening on ${port}"; return 0; }; sleep 3; w=$((w+3)); done
    error "${name} not listening on ${port} after 60s"; return 1
}
_pd_stop() {
    local dir=$1 port=$2 name=$3
    _port_listening "$port" || { info "${name} already stopped"; return 0; }
    info "Stopping ${name}..."
    "${dir}/bin/stop-server" >/dev/null 2>&1 || true
    success "${name} stopped"
}

# =============================================================================
# Component handlers
# =============================================================================
pd_start()  { _pd_start "$PINGDIR_DIR"  "$PINGDIR_LDAPS_PORT"  "PingDirectory-1"; }
pd_stop()   { _pd_stop  "$PINGDIR_DIR"  "$PINGDIR_LDAPS_PORT"  "PingDirectory-1"; }
pd_status() { if _port_listening "$PINGDIR_LDAPS_PORT"; then success "PingDirectory-1 RUNNING  (LDAP ${PINGDIR_LDAP_PORT}/LDAPS ${PINGDIR_LDAPS_PORT}, pid $(_pids_for "$_PD_PAT" | awk '{print $1}'))"; else warning "PingDirectory-1 STOPPED"; fi; }

pd2_start()  { _pd_start "$PINGDIR2_DIR" "$PINGDIR2_LDAPS_PORT" "PingDirectory-2"; }
pd2_stop()   { _pd_stop  "$PINGDIR2_DIR" "$PINGDIR2_LDAPS_PORT" "PingDirectory-2"; }
pd2_status() { if _port_listening "$PINGDIR2_LDAPS_PORT"; then success "PingDirectory-2 RUNNING  (LDAP ${PINGDIR2_LDAP_PORT}/LDAPS ${PINGDIR2_LDAPS_PORT})"; else warning "PingDirectory-2 STOPPED"; fi; }

pf_start() {
    _port_listening "$PINGFED_ADMIN_PORT" && { success "PingFederate console already running (admin ${PINGFED_ADMIN_PORT})"; return 0; }
    info "Starting PingFederate console (detached)..."
    _launch_detached "$PINGFED_DIR" "$PF_RUN_LOG"
    _wait_http "PingFederate console" "https://${PINGFED_HOSTNAME}:${PINGFED_ADMIN_PORT}/pingfederate/app" 180
}
pf_stop()   { local p; p="$(_pf_pids "$PINGFED_DIR")"; [[ -z "${p// }" ]] && { info "PingFederate console already stopped"; return 0; }; info "Stopping PingFederate console (pid ${p})..."; _stop_pids "$p"; success "PingFederate console stopped"; }
pf_status() { if _port_listening "$PINGFED_ADMIN_PORT"; then success "PingFederate-1 RUNNING  (${_PF_ROLE1}, admin ${PINGFED_ADMIN_PORT}, pid $(_pf_pids "$PINGFED_DIR" | awk '{print $1}'))"; else warning "PingFederate-1 STOPPED"; fi; }

pf2_start() {
    _port_listening "$PINGFED2_ENGINE_PORT" && { success "PingFederate engine already running (${PINGFED2_ENGINE_PORT})"; return 0; }
    info "Starting PingFederate engine node 2 (detached)..."
    _launch_detached "$PINGFED2_DIR" "$PF2_RUN_LOG"
    _wait_http "PingFederate engine" "https://${PINGFED_HOSTNAME}:${PINGFED2_ENGINE_PORT}/pf/heartbeat.ping" 180
}
pf2_stop()   { local p; p="$(_pf_pids "$PINGFED2_DIR")"; [[ -z "${p// }" ]] && { info "PingFederate engine already stopped"; return 0; }; info "Stopping PingFederate engine (pid ${p})..."; _stop_pids "$p"; success "PingFederate engine stopped"; }
pf2_status() { if _port_listening "$PINGFED2_ENGINE_PORT"; then local c; c=$(_http_code "https://${PINGFED_HOSTNAME}:${PINGFED2_ENGINE_PORT}/pf/heartbeat.ping"); success "PingFederate-2 RUNNING  (CLUSTERED_ENGINE, engine ${PINGFED2_ENGINE_PORT} heartbeat ${c}, pid $(_pf_pids "$PINGFED2_DIR" | awk '{print $1}'))"; else warning "PingFederate-2 STOPPED"; fi; }

pa_start() {
    _port_listening "$PINGACCESS_ADMIN_PORT" && { success "PingAccess already running (admin ${PINGACCESS_ADMIN_PORT})"; return 0; }
    info "Starting PingAccess (detached)..."
    _launch_detached "$PINGACCESS_DIR" "$PA_RUN_LOG"
    _wait_http "PingAccess admin console" "https://${PINGACCESS_HOSTNAME}:${PINGACCESS_ADMIN_PORT}/" 180
}
pa_stop()   { local p; p="$(_pids_for "$_PA_PAT")"; [[ -z "${p// }" ]] && { info "PingAccess already stopped"; return 0; }; info "Stopping PingAccess (pid ${p})..."; _stop_pids "$p"; success "PingAccess stopped"; }
pa_status() { if _port_listening "$PINGACCESS_ADMIN_PORT"; then local c; c=$(_http_code "https://${PINGACCESS_HOSTNAME}:${PINGACCESS_ENGINE_PORT}/"); success "PingAccess     RUNNING  (admin ${PINGACCESS_ADMIN_PORT}, engine ${PINGACCESS_ENGINE_PORT} HTTP ${c})"; else warning "PingAccess     STOPPED"; fi; }

# Sample app — matched by its unique script arg; port owner is the reliable stop.
_APP_PAT='sample-app\.py'
app_start() {
    _port_listening "$APP_PORT" && { success "Sample app already running (:${APP_PORT})"; return 0; }
    info "Starting sample app (localhost:${APP_PORT})..."
    mkdir -p "$LOG_DIR"
    ( setsid python3 "${SCRIPT_ROOT}/pingaccess/sample-app.py" "$APP_PORT" >"$APP_RUN_LOG" 2>&1 </dev/null & )
    local w=0; while [[ $w -lt 15 ]]; do curl -s -o /dev/null --max-time 3 "http://localhost:${APP_PORT}/" 2>/dev/null && { success "Sample app serving on :${APP_PORT}"; return 0; }; sleep 1; w=$((w+1)); done
    error "Sample app did not respond on :${APP_PORT}"; return 1
}
app_stop()   { local p; p="$(_pids_for "$_APP_PAT")"; [[ -z "${p// }" ]] && { info "Sample app already stopped"; return 0; }; info "Stopping sample app (pid ${p})..."; _stop_pids "$p"; success "Sample app stopped"; }
app_status() { if _port_listening "$APP_PORT"; then success "Sample app     RUNNING  (origin :${APP_PORT})"; else warning "Sample app     STOPPED"; fi; }

lb_start()  { info "Starting HAProxy load balancer..."; sudo systemctl start haproxy 2>/dev/null && success "HAProxy started" || { error "HAProxy start failed (systemctl status haproxy)"; return 1; }; }
lb_stop()   { info "Stopping HAProxy..."; sudo systemctl stop haproxy 2>/dev/null && success "HAProxy stopped" || warning "HAProxy stop failed"; }
lb_status() { if _port_listening "$LB_HTTPS_PORT"; then local a; a=$(sudo systemctl is-active haproxy 2>/dev/null); success "Load Balancer  RUNNING  (HAProxy :${LB_HTTPS_PORT}, systemd ${a})"; else warning "Load Balancer  STOPPED"; fi; }

# =============================================================================
# Dispatch
# =============================================================================
ACTION="${1:-status}"
TARGET="${2:-all}"
_PF_ROLE1="STANDALONE"; [[ "${PINGFED_COUNT:-1}" -gt 1 ]] && _PF_ROLE1="CLUSTERED_CONSOLE"

# Components that make up "all", in dependency (start) order, per config.
_all_order=(pd)
[[ "${PINGDIR_COUNT:-1}" -gt 1 ]] && _all_order+=(pd2)
_all_order+=(pf)
[[ "${PINGFED_COUNT:-1}" -gt 1 ]] && _all_order+=(pf2)
_all_order+=(pa)
[[ "${INSTALL_SAMPLE_APP:-true}" == "true" ]] && _all_order+=(app)
[[ "${LB_ENABLED:-false}" == "true" ]] && _all_order+=(lb)

case "$TARGET" in
    pd|pd2|pf|pf2|pa|app|lb|all) : ;;
    *) error "Unknown target '$TARGET' (expected: pd|pd2|pf|pf2|pa|app|lb|all)"; exit 2 ;;
esac
case "$ACTION" in start|stop|restart|status) : ;; *) error "Unknown action '$ACTION' (expected: start|stop|restart|status)"; exit 2 ;; esac

do_action() {
    case "$2" in
        start)   ${1}_start ;;
        stop)    ${1}_stop ;;
        status)  ${1}_status ;;
        restart) ${1}_stop; ${1}_start ;;
    esac
}

# Order: dependency order for start/status, reversed for stop.
if [[ "$TARGET" == "all" ]]; then
    order=("${_all_order[@]}")
else
    order=("$TARGET")
fi
if [[ "$ACTION" == "stop" ]]; then
    rev=(); for ((i=${#order[@]}-1; i>=0; i--)); do rev+=("${order[i]}"); done
    order=("${rev[@]}")
fi

banner "Ping stack — ${ACTION} (${TARGET})"
rc=0
for prod in "${order[@]}"; do
    do_action "$prod" "$ACTION" || rc=1
done
exit $rc
