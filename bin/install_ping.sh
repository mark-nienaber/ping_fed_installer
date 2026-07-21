#!/bin/bash
set -euo pipefail

################################################################################
# Script Name: install_ping.sh
# Description: Orchestration script for the PingDirectory + PingFederate +
#              PingAccess installer.
#
#   Three-phase architecture (dependency order PD -> PF -> PA):
#     Phase 1 — Install:     unzip + bring each product to a running baseline
#     Phase 2 — Configure:   PD schema/data -> PF datastore/adapters/clients
#                            -> PA sites/rules  (all Admin-API / CLI, idempotent)
#     Phase 3 — Integrate:   wire PA -> PF -> PD, sample protected app, test users
#
#   Usage:
#     ./bin/install_ping.sh [OPTIONS]
#
#   Options:
#     --all       Run all phases (default full install)
#     --phase1    Install only
#     --phase2    Configure only
#     --phase3    Integrate / sample content only
#     --force     Ignore .install-state and re-run completed phases
#     --help      Show this help
#
#   Phase state is tracked in .install-state so re-runs skip completed phases
#   unless --force is given. This also supports external orchestration (a UI or
#   remote runner) polling the state file between phases.
#
#   NOTE: product install/configure functions are STUBS in this scaffold — they
#   log intent and return success so the full phase machinery is testable before
#   the product logic lands. Real logic replaces the bodies marked [STUB].
################################################################################

# Load central configuration
source ./pingconfig.env

# Load shared logging library (fallback to plain echo if missing)
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
if [[ -f "${_LIB_DIR}/logging.sh" ]]; then
    source "${_LIB_DIR}/logging.sh"
else
    info()    { echo "[INFO]  $*"; }
    success() { echo "[OK]    $*"; }
    warning() { echo "[WARN]  $*"; }
    error()   { echo "[ERROR] $*"; }
    banner()  { echo "== $* =="; }
    step_init() { :; } ; step_begin() { echo "-> $*"; } ; step_end() { :; }
    summary_init(){ :; } ; summary_add(){ echo "  $*"; } ; summary_print(){ :; } ; summary_urls(){ :; }
fi

# Logging + state files
LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
SCRIPT_STATE_FILE="/tmp/.ping_install_state"          # per-run, for rollback
INSTALL_STATE_FILE="${SCRIPT_DIR}/.install-state"     # persists completed phases

# Phase control flags (set by parse_args)
_RUN_PHASE1=false
_RUN_PHASE2=false
_RUN_PHASE3=false
_FORCE=false

# -----------------------------------------------------------------------------
# Logging setup
# -----------------------------------------------------------------------------
function setup_logging() {
    sudo mkdir -p "$LOG_DIR"
    sudo chown "$USER:$USER" "$LOG_DIR" 2>/dev/null || true
    exec > >(tee -a "$LOG_FILE")
    exec 2>&1
    info "Logging to $LOG_FILE"
}

# -----------------------------------------------------------------------------
# Per-run state (for rollback) + persistent phase state
# -----------------------------------------------------------------------------
function save_state()      { echo "$1:$(date +%s)" >> "$SCRIPT_STATE_FILE"; }
function phase_mark_done() { echo "$1:$(date +%s)" >> "$INSTALL_STATE_FILE"; }
function phase_is_done() {
    local phase=$1
    [[ "$_FORCE" == "true" ]] && return 1
    [[ -f "$INSTALL_STATE_FILE" ]] && grep -q "^${phase}:" "$INSTALL_STATE_FILE"
}

# -----------------------------------------------------------------------------
# Usage / argument parsing
# -----------------------------------------------------------------------------
function _usage() {
    cat <<EOF

Usage: $0 <--all|--phase1|--phase2|--phase3> [--force]

  --all     Run all three phases (full install)
  --phase1  Install:    unzip + baseline start (PD -> PF -> PA)
  --phase2  Configure:  PD schema/data + PF datastore/adapters + PA sites/rules
  --phase3  Integrate:  wire PA->PF->PD, sample app, test users
  --force   Re-run even if a phase is already marked complete
EOF
}

function parse_args() {
    if [[ $# -eq 0 ]]; then
        echo; echo "Error: no argument provided."; _usage; exit 1
    fi
    local has_phase=false
    for arg in "$@"; do
        case "$arg" in
            --all)    _RUN_PHASE1=true; _RUN_PHASE2=true; _RUN_PHASE3=true; has_phase=true ;;
            --phase1) _RUN_PHASE1=true; has_phase=true ;;
            --phase2) _RUN_PHASE2=true; has_phase=true ;;
            --phase3) _RUN_PHASE3=true; has_phase=true ;;
            --force)  _FORCE=true ;;
            --help|-h) _usage; exit 0 ;;
            *) echo; echo "Error: unknown argument '$arg'."; _usage; exit 1 ;;
        esac
    done
    if [[ "$has_phase" == "false" ]]; then
        echo; echo "Error: --force requires a phase argument."; _usage; exit 1
    fi
}

# -----------------------------------------------------------------------------
# Pre-flight validation
# -----------------------------------------------------------------------------
function preflight_checks() {
    info "Running pre-flight checks..."

    local required_tools=("java" "unzip" "curl" "python3")
    for tool in "${required_tools[@]}"; do
        command -v "$tool" &>/dev/null || { error "Required tool '$tool' not found"; return 1; }
    done
    success "Required tools present"

    # Java version
    local jv
    jv=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d. -f1)
    if [[ -n "$jv" && "$jv" -lt "${JAVA_MIN_VERSION}" ]]; then
        error "Java ${JAVA_MIN_VERSION}+ required (found: $jv)"; return 1
    fi
    success "Java version check passed (found: ${jv:-unknown})"

    # Disk space under (existing ancestor of) BASE_INSTALL_DIR
    local target="${BASE_INSTALL_DIR}"
    while [[ -n "$target" && ! -d "$target" ]]; do target="${target%/*}"; done
    [[ -z "$target" ]] && target="/"
    local free_gb
    free_gb=$(df -BG "$target" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || echo 0)
    # Only Phase 1 extracts software and needs the full budget. Phase 2/3 are
    # API/config calls with a negligible footprint — just warn there.
    if [[ "${_RUN_PHASE1:-false}" == "true" ]]; then
        if [[ "${free_gb:-0}" -lt "${REQUIRED_DISK_GB}" ]]; then
            error "Insufficient disk under $target: need ${REQUIRED_DISK_GB}GB, have ${free_gb}GB"; return 1
        fi
        success "Disk space check passed (${free_gb}GB free under $target)"
    elif [[ "${free_gb:-0}" -lt 1 ]]; then
        warning "Very low disk under $target (${free_gb}GB) — config may still proceed"
    else
        success "Disk check ok for config phase (${free_gb}GB free under $target)"
    fi

    validate_config
    [[ "${_RUN_PHASE1:-false}" == "true" ]] && { verify_software_files; check_ports_availability; }

    success "All pre-flight checks passed"
}

function validate_config() {
    info "Validating configuration..."
    local required_vars=(BASE_INSTALL_DIR DEFAULT_PASSWORD PING_HOSTNAME
                         PINGDIR_BASE_DN PINGFED_ADMIN_API PINGACCESS_ADMIN_API)
    local missing=()
    for v in "${required_vars[@]}"; do [[ -z "${!v:-}" ]] && missing+=("$v"); done
    [[ ${#missing[@]} -gt 0 ]] && { error "Missing config vars: ${missing[*]}"; return 1; }

    # Ensure host resolves (single-node: point at loopback)
    for h in "$PINGDIR_HOSTNAME" "$PINGFED_HOSTNAME" "$PINGACCESS_HOSTNAME"; do
        [[ -z "$h" ]] && continue
        if ! getent hosts "$h" &>/dev/null && ! grep -q "$h" /etc/hosts 2>/dev/null; then
            warning "Hostname $h not resolvable — adding to /etc/hosts"
            echo "127.0.0.1 $h" | sudo tee -a /etc/hosts >/dev/null
        fi
    done
    success "Configuration validated"
}

function verify_software_files() {
    info "Verifying software + license files..."
    local missing=()
    find "${PINGDIR_SOFTWARE_DIR}"     -name 'PingDirectory-*.zip' -type f 2>/dev/null | grep -q . || missing+=("PingDirectory zip in ${PINGDIR_SOFTWARE_DIR}")
    find "${PINGFED_SOFTWARE_DIR}"     -name 'pingfederate-*.zip'  -type f 2>/dev/null | grep -q . || missing+=("PingFederate zip in ${PINGFED_SOFTWARE_DIR}")
    find "${PINGACCESS_SOFTWARE_DIR}"  -name 'pingaccess-*.zip'    -type f 2>/dev/null | grep -q . || missing+=("PingAccess zip in ${PINGACCESS_SOFTWARE_DIR}")
    [[ -f "${PINGDIR_LICENSE:-}" ]]    || missing+=("PingDirectory .lic in ${PINGDIR_SOFTWARE_DIR}")
    [[ -f "${PINGFED_LICENSE:-}" ]]    || missing+=("PingFederate .lic in ${PINGFED_SOFTWARE_DIR}")
    [[ -f "${PINGACCESS_LICENSE:-}" ]] || missing+=("PingAccess .lic in ${PINGACCESS_SOFTWARE_DIR}")
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing software/licenses:"; for m in "${missing[@]}"; do error "  - $m"; done; return 1
    fi
    success "All software + license files found"
}

function check_ports_availability() {
    info "Checking port availability..."
    # Only guard ports for products NOT already installed — a completed install
    # legitimately holds its ports, and re-runs must not fail on that.
    local ports=()
    if [[ ! -f "${PINGDIR_DIR}/.ping-setup-complete" ]]; then
        ports+=("$PINGDIR_LDAP_PORT" "$PINGDIR_LDAPS_PORT" "$PINGDIR_HTTPS_PORT")
        [[ "${PINGDIR_COUNT:-1}" -gt 1 ]] && ports+=("$PINGDIR_REPLICATION_PORT")
    fi
    [[ ! -f "${PINGFED_DIR}/.ping-install-complete" ]] && \
        ports+=("$PINGFED_ADMIN_PORT" "$PINGFED_ENGINE_PORT")
    [[ ! -f "${PINGACCESS_DIR}/.ping-install-complete" ]] && \
        ports+=("$PINGACCESS_ADMIN_PORT" "$PINGACCESS_ENGINE_PORT" "$PINGACCESS_AGENT_PORT")
    if [[ ${#ports[@]} -eq 0 ]]; then
        success "All products already installed — no ports to reserve"; return 0
    fi
    local in_use=()
    for p in "${ports[@]}"; do
        if command -v ss >/dev/null 2>&1; then
            ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}$" && in_use+=("$p")
        else
            netstat -tuln 2>/dev/null | grep -q ":$p " && in_use+=("$p")
        fi
    done
    [[ ${#in_use[@]} -gt 0 ]] && { error "Ports already in use: ${in_use[*]}"; return 1; }
    success "All required ports are available"
}

# -----------------------------------------------------------------------------
# Generic HTTP readiness poll
# -----------------------------------------------------------------------------
function wait_for_service() {
    local name=$1 url=$2 max=${3:-30} nap=${4:-5}
    info "Waiting for $name at $url ..."
    for ((i=1; i<=max; i++)); do
        local code
        code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
        [[ "$code" =~ ^(200|302|401)$ ]] && { success "$name is ready (HTTP $code)"; return 0; }
        [[ $i -lt $max ]] && { info "  $name not ready (HTTP $code) — attempt $i/$max"; sleep "$nap"; }
    done
    error "$name failed to become ready after $((max*nap))s"; return 1
}

# =============================================================================
# Product install/configure functions  — [STUB] bodies for now
# Each returns 0 and records rollback state so the phase machinery is testable.
# =============================================================================

# ---- PingDirectory ----------------------------------------------------------
function install_pingdir() {
    info "Installing PingDirectory (unzip + setup + license + start)"
    if bash "$PINGDIR_SCRIPT"; then
        save_state "PINGDIR_INSTALLED"
        success "PingDirectory baseline running"
    else
        error "PingDirectory install failed"; return 1
    fi
}
function configure_pingdir() {
    info "Configuring PingDirectory (content, PF schema, session/grant containers, ACIs)"
    if bash "${SCRIPT_DIR}/pingdir/configure_pingdir.sh"; then
        success "PingDirectory configured"
    else
        error "PingDirectory configuration failed"; return 1
    fi
    if [[ "${PINGDIR_COUNT:-1}" -gt 1 ]]; then
        info "PINGDIR_COUNT=${PINGDIR_COUNT} — building replication topology (node 2 + peers)"
        bash "${SCRIPT_DIR}/pingdir/cluster_pingdir.sh" || { error "PingDirectory clustering failed"; return 1; }
    fi
}
function rollback_pingdir() {
    warning "[STUB] Rollback PingDirectory"
    [[ -x "${PINGDIR_DIR}/bin/stop-server" ]] && "${PINGDIR_DIR}/bin/stop-server" 2>/dev/null || true
    rm -rf "${PINGDIR_DIR}" 2>/dev/null || true
}

# ---- PingFederate -----------------------------------------------------------
function install_pingfed() {
    info "Installing PingFederate (unzip + license + start)"
    if bash "$PINGFED_SCRIPT"; then
        save_state "PINGFED_INSTALLED"
        success "PingFederate baseline running"
    else
        error "PingFederate install failed"; return 1
    fi
}
function configure_pingfed() {
    info "Configuring PingFederate (LDAP admin auth -> PD, license, datastore, externalized storage)"
    if ! bash "${SCRIPT_DIR}/pingfed/configure_pingfed.sh"; then
        error "PingFederate base configuration failed"; return 1
    fi
    info "Configuring PingFederate OAuth/OIDC + SSO machinery"
    if bash "${SCRIPT_DIR}/pingfed/configure_pingfed_sso.sh"; then
        success "PingFederate configured"
    else
        error "PingFederate OAuth/OIDC configuration failed"; return 1
    fi
    if [[ "${PINGFED_COUNT:-1}" -gt 1 ]]; then
        info "PINGFED_COUNT=${PINGFED_COUNT} — building console+engine cluster (node 2 + peers)"
        bash "${SCRIPT_DIR}/pingfed/cluster_pingfed.sh" || { error "PingFederate clustering failed"; return 1; }
    fi
    if [[ "${PINGDIR_COUNT:-1}" -gt 1 ]]; then
        info "PINGDIR_COUNT=${PINGDIR_COUNT} — securing PF->PD datastore (LDAPS) + failover across nodes"
        bash "${SCRIPT_DIR}/pingfed/secure_ha_datastore.sh" || { error "Datastore secure/HA reconfig failed"; return 1; }
    fi
}
function rollback_pingfed() {
    warning "[STUB] Rollback PingFederate"
    pkill -f "run.properties.*pingfederate|org.tanukisoftware.*pingfederate" 2>/dev/null || true
    rm -rf "${PINGFED_DIR}" 2>/dev/null || true
}

# ---- PingAccess -------------------------------------------------------------
function install_pingaccess() {
    info "Installing PingAccess (unzip + license + start)"
    if bash "$PINGACCESS_SCRIPT"; then
        save_state "PINGACCESS_INSTALLED"
        success "PingAccess baseline running"
    else
        error "PingAccess install failed"; return 1
    fi
}
function configure_pingaccess() {
    info "Configuring PingAccess (accept SLA, rotate admin password)"
    if bash "${SCRIPT_DIR}/pingaccess/configure_pingaccess.sh"; then
        success "PingAccess configured"
    else
        error "PingAccess configuration failed"; return 1
    fi
}
function rollback_pingaccess() {
    warning "[STUB] Rollback PingAccess"
    pkill -f "run.properties.*pingaccess|com.pingidentity.pa" 2>/dev/null || true
    rm -rf "${PINGACCESS_DIR}" 2>/dev/null || true
}

# ---- Cross-product integration (Phase 3) ------------------------------------
function integrate_stack() {
    # The PA->PF token provider, web session, virtual host, site, application and
    # identity mapping are provisioned in Phase 2 (configure_pingaccess Part B),
    # and PF's externalized session/grant storage + OAuth/OIDC in configure_pingfed*.
    # Phase 3 verifies the wiring is live end-to-end: an unauthenticated request to
    # the PA-protected vhost must redirect to the PingFederate authorization endpoint.
    info "Verifying PingAccess -> PingFederate SSO wiring"
    local code loc
    loc=$(curl -sk -o /dev/null -w '%{redirect_url}' "https://${SAMPLE_APP_VIRTUAL_HOST}:${PINGACCESS_ENGINE_PORT}/" 2>/dev/null || true)
    code=$(curl -sk -o /dev/null -w '%{http_code}' "https://${SAMPLE_APP_VIRTUAL_HOST}:${PINGACCESS_ENGINE_PORT}/" 2>/dev/null || echo 000)
    if [[ "$code" == "302" && "$loc" == *"/as/authorization.oauth2"* && "$loc" == *"client_id=${PINGFED_OIDC_CLIENT_ID}"* ]]; then
        success "PA redirects to PingFederate for SSO (client ${PINGFED_OIDC_CLIENT_ID})"
    else
        warning "PA->PF redirect not confirmed (HTTP $code). Ensure ${SAMPLE_APP_VIRTUAL_HOST} resolves and PA engine is up."
    fi
}
function deploy_sample_app() {
    # Launch the bundled backend origin that PingAccess reverse-proxies to.
    local port="${SAMPLE_APP_TARGET##*:}"; port="${port%%/*}"
    if (command -v ss >/dev/null && ss -ltn 2>/dev/null | grep -q ":${port} "); then
        success "Sample app origin already listening on :${port}"
        return 0
    fi
    info "Starting bundled sample app (localhost:${port})"
    mkdir -p "$LOG_DIR"
    ( setsid python3 "${SCRIPT_DIR}/pingaccess/sample-app.py" "$port" \
        > "${LOG_DIR}/sample-app.log" 2>&1 </dev/null & )
    local i=0
    while [[ $i -lt 15 ]]; do
        curl -s -o /dev/null --max-time 3 "http://localhost:${port}/" 2>/dev/null && { success "Sample app serving on :${port}"; return 0; }
        sleep 1; ((i++))
    done
    warning "Sample app did not respond on :${port} (see ${LOG_DIR}/sample-app.log)"
}
# Front-door load balancer (TLS termination) + rewire of runtime URLs. Runs last
# in Phase 3 so both the PF engine cluster and PA are already up; a no-op unless
# LB_ENABLED=true (typically alongside clustering).
function cluster_frontdoor() {
    if [[ "${LB_ENABLED:-false}" != "true" ]]; then
        info "LB_ENABLED=false — no load-balancer front door"; return 0
    fi
    info "Standing up load balancer (TLS termination) + rewiring runtime URLs to it"
    bash "${SCRIPT_DIR}/bin/setup_loadbalancer.sh" || { error "Load balancer setup failed"; return 1; }
    bash "${SCRIPT_DIR}/bin/rewire_frontdoor.sh"   || { error "Front-door rewire failed";   return 1; }
    success "Load-balancer front door ready (https://${LB_HOSTNAME_PF} / https://${LB_HOSTNAME_APP})"
}
function create_test_users() {
    local count="${TEST_USER_COUNT:-0}"
    [[ "$count" -le 0 ]] && { info "TEST_USER_COUNT=0 — skipping test users"; return 0; }
    info "Seeding ${count} test user(s) into PingDirectory (${PINGDIR_PEOPLE_DN})"
    if TEST_USER_COUNT="$count" bash "${SCRIPT_DIR}/pingdir/create_test_users.sh"; then
        success "${count} test user(s) present in PingDirectory"
    else
        error "Test user creation failed"; return 1
    fi
}

# -----------------------------------------------------------------------------
# Rollback dispatcher (reverse order of per-run state)
# -----------------------------------------------------------------------------
function cleanup_on_failure() {
    [[ -f "$SCRIPT_STATE_FILE" ]] || return 0
    error "Installation failed. Initiating rollback..."
    while IFS=: read -r state _; do
        case "$state" in
            PINGACCESS_INSTALLED) rollback_pingaccess ;;
            PINGFED_INSTALLED)    rollback_pingfed ;;
            PINGDIR_INSTALLED)    rollback_pingdir ;;
        esac
    done < <(tac "$SCRIPT_STATE_FILE")
    rm -f "$SCRIPT_STATE_FILE"
}

# =============================================================================
# Phases
# =============================================================================
function run_phase1() {
    if phase_is_done "PHASE1"; then info "Phase 1 already complete — skipping (use --force)"; return 0; fi
    banner "Phase 1 — Install (PD -> PF -> PA)"
    step_init 3
    step_begin "Install PingDirectory";  install_pingdir;    step_end
    step_begin "Install PingFederate";   install_pingfed;    step_end
    step_begin "Install PingAccess";     install_pingaccess; step_end
    phase_mark_done "PHASE1"
    success "Phase 1 complete"
}

function run_phase2() {
    if phase_is_done "PHASE2"; then info "Phase 2 already complete — skipping (use --force)"; return 0; fi
    banner "Phase 2 — Configure"
    step_init 3
    step_begin "Configure PingDirectory (schema/data/service account)"; configure_pingdir;    step_end
    step_begin "Configure PingFederate (datastore/adapter/clients)";    configure_pingfed;    step_end
    step_begin "Configure PingAccess (virtual host/site/app/rules)";    configure_pingaccess; step_end
    phase_mark_done "PHASE2"
    success "Phase 2 complete"
}

function run_phase3() {
    if phase_is_done "PHASE3"; then info "Phase 3 already complete — skipping (use --force)"; return 0; fi
    banner "Phase 3 — Integrate + Sample Content"
    step_init 3
    step_begin "Wire PA -> PF -> PD"; integrate_stack; step_end
    if [[ "${INSTALL_SAMPLE_APP:-true}" == "true" ]]; then
        step_begin "Deploy sample protected app"; deploy_sample_app; step_end
    else
        info "INSTALL_SAMPLE_APP=false — skipping sample app"
    fi
    if [[ "${INSTALL_TEST_USERS:-true}" == "true" ]]; then
        step_begin "Seed test users"; create_test_users; step_end
    else
        info "INSTALL_TEST_USERS=false — skipping test users"
    fi
    if [[ "${LB_ENABLED:-false}" == "true" ]]; then
        step_begin "Load balancer front door (TLS termination) + URL rewire"; cluster_frontdoor; step_end
    fi
    phase_mark_done "PHASE3"
    success "Phase 3 complete"
}

# -----------------------------------------------------------------------------
# Final status
# -----------------------------------------------------------------------------
function show_final_status() {
    summary_init
    summary_add "PingDirectory" "LDAPS :${PINGDIR_LDAPS_PORT}" "ok"
    [[ "${PINGDIR_COUNT:-1}" -gt 1 ]] && summary_add "PingDirectory-2" "LDAPS :${PINGDIR2_LDAPS_PORT} (replicated)" "ok"
    if [[ "${PINGFED_COUNT:-1}" -gt 1 ]]; then
        summary_add "PingFederate-1" "CLUSTERED_CONSOLE admin :${PINGFED_ADMIN_PORT}" "ok"
        summary_add "PingFederate-2" "CLUSTERED_ENGINE engine :${PINGFED2_ENGINE_PORT}" "ok"
    else
        summary_add "PingFederate"  "admin :${PINGFED_ADMIN_PORT} / engine :${PINGFED_ENGINE_PORT}" "ok"
    fi
    summary_add "PingAccess"    "admin :${PINGACCESS_ADMIN_PORT} / engine :${PINGACCESS_ENGINE_PORT}" "ok"
    [[ "${LB_ENABLED:-false}" == "true" ]] && summary_add "Load Balancer" "HAProxy :${LB_HTTPS_PORT} (TLS termination)" "ok"
    summary_print
    summary_urls \
        "PingFederate Admin" "https://${PINGFED_HOSTNAME}:${PINGFED_ADMIN_PORT}/pingfederate/app" \
        "PingAccess Admin"   "https://${PINGACCESS_HOSTNAME}:${PINGACCESS_ADMIN_PORT}" \
        "PingDirectory Admin API" "https://${PINGDIR_HOSTNAME}:${PINGDIR_HTTPS_PORT}"
    info "Installation log: $LOG_FILE"
}

# ========================
# Main
# ========================
trap 'error "Script failed at line $LINENO"; cleanup_on_failure; exit 1' ERR
trap 'warning "Script interrupted"; exit 130' INT TERM

parse_args "$@"
setup_logging

banner "Ping Installer (PingDirectory + PingFederate + PingAccess)"
info "Started at $(date)"
info "Phases:  Phase1=${_RUN_PHASE1} Phase2=${_RUN_PHASE2} Phase3=${_RUN_PHASE3}  Force=${_FORCE}"
info "Counts:  PD=${PINGDIR_COUNT} PF=${PINGFED_COUNT} PA=${PINGACCESS_COUNT}"

preflight_checks

[[ "$_RUN_PHASE1" == "true" ]] && run_phase1
[[ "$_RUN_PHASE2" == "true" ]] && run_phase2
[[ "$_RUN_PHASE3" == "true" ]] && run_phase3

rm -f "$SCRIPT_STATE_FILE"
show_final_status
success "Ping installation completed successfully!"
