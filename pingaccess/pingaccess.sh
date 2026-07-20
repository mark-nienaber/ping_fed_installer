#!/bin/bash
set -euo pipefail

################################################################################
# Script Name: pingaccess.sh
# Description: Phase 1 — install PingAccess to a running baseline.
#              Extracts the product, drops the license into conf/pingaccess.lic,
#              and starts the server via bin/run.sh.
#
#              First-login default-password change (administrator / 2Access),
#              PingFederate token-provider wiring, virtual hosts, sites,
#              applications and rules are applied later by Phase 2/3
#              (configure_pingaccess / integrate_stack).
#
#              Idempotent: completed install is marked; re-runs only ensure the
#              server is running.
#
# Zip layout: pingaccess-<ver>/{bin,conf,data,...}  (the versioned dir IS the
# install root <PA_HOME>). License path: conf/pingaccess.lic.
################################################################################

source ./pingconfig.env
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "${_LIB_DIR}/logging.sh"

INSTALL_MARKER="${PINGACCESS_DIR}/.ping-install-complete"
PA_LICENSE_TARGET="${PINGACCESS_DIR}/conf/pingaccess.lic"
PA_RUN_LOG="${LOG_DIR}/pingaccess-run.log"

function resolve_software() {
    PA_ZIP=$(find "${PINGACCESS_SOFTWARE_DIR}" -maxdepth 1 -name 'pingaccess-*.zip' -type f 2>/dev/null | head -n1)
    [[ -f "$PA_ZIP" ]] || { error "No pingaccess-*.zip in ${PINGACCESS_SOFTWARE_DIR}"; return 1; }
    [[ -f "${PINGACCESS_LICENSE:-}" ]] || { error "No PingAccess .lic in ${PINGACCESS_SOFTWARE_DIR}"; return 1; }
    info "Software: $(basename "$PA_ZIP")"
    info "License:  $(basename "$PINGACCESS_LICENSE")"
    # PA validates license version at startup; warn on a minor mismatch.
    local lic_ver sw_ver
    lic_ver=$(grep -iE '^Version=' "$PINGACCESS_LICENSE" 2>/dev/null | cut -d= -f2 | tr -d ' \r')
    sw_ver=$(basename "$PA_ZIP" | sed -E 's/pingaccess-([0-9]+\.[0-9]+).*/\1/')
    if [[ -n "$lic_ver" && -n "$sw_ver" && "$lic_ver" != "$sw_ver" ]]; then
        warning "PingAccess license Version=${lic_ver} but software is ${sw_ver} — PA may reject it at startup (need a ${sw_ver} dev license)."
    fi
}

function extract() {
    if [[ -x "${PINGACCESS_DIR}/bin/run.sh" ]]; then
        info "PingAccess already extracted at ${PINGACCESS_DIR}"; return 0
    fi
    info "Extracting PingAccess into ${PINGACCESS_DIR}..."
    local tmp; tmp=$(mktemp -d)
    unzip -q "$PA_ZIP" -d "$tmp"
    local root; root=$(find "$tmp" -maxdepth 1 -type d -name 'pingaccess-*' | head -n1)
    [[ -d "$root" ]] || { error "Could not locate pingaccess-* dir in zip"; rm -rf "$tmp"; return 1; }
    mkdir -p "${PINGACCESS_DIR}"
    cp -a "${root}/." "${PINGACCESS_DIR}/"
    rm -rf "$tmp"
    [[ -x "${PINGACCESS_DIR}/bin/run.sh" ]] || { error "run.sh missing after extract"; return 1; }
    success "Extracted"
}

function place_license() {
    mkdir -p "$(dirname "$PA_LICENSE_TARGET")"
    cp -f "$PINGACCESS_LICENSE" "$PA_LICENSE_TARGET"
    chmod 640 "$PA_LICENSE_TARGET"
    success "License installed at conf/pingaccess.lic"
}

function _port_listening() {
    local port=$1
    (command -v ss >/dev/null && ss -ltn 2>/dev/null | grep -q ":${port} ") \
      || (command -v netstat >/dev/null && netstat -tuln 2>/dev/null | grep -q ":${port} ")
}

function ensure_started() {
    if _port_listening "$PINGACCESS_ADMIN_PORT"; then
        success "PingAccess admin already listening on ${PINGACCESS_ADMIN_PORT}"
    else
        info "Starting PingAccess (bin/run.sh, background)..."
        mkdir -p "$LOG_DIR"
        ( cd "$PINGACCESS_DIR" && nohup ./bin/run.sh > "$PA_RUN_LOG" 2>&1 & )
    fi

    info "Waiting for PingAccess admin console (up to 180s)..."
    local waited=0
    while [[ $waited -lt 180 ]]; do
        local code
        code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 \
               "https://${PINGACCESS_HOSTNAME}:${PINGACCESS_ADMIN_PORT}/" 2>/dev/null || echo "000")
        if [[ "$code" =~ ^(200|302|401)$ ]]; then
            success "PingAccess admin console ready (HTTP $code) on ${PINGACCESS_ADMIN_PORT}"
            return 0
        fi
        sleep 5; waited=$((waited+5))
        [[ $((waited % 30)) -eq 0 ]] && info "  still waiting... (${waited}s, last HTTP $code)"
    done
    error "PingAccess admin console not ready after 180s (see $PA_RUN_LOG)"; return 1
}

trap 'error "pingaccess.sh failed at line $LINENO"' ERR

section "PingAccess — Phase 1 install"
resolve_software
extract
place_license
ensure_started
touch "$INSTALL_MARKER"
success "PingAccess baseline ready (engine :${PINGACCESS_ENGINE_PORT}, admin :${PINGACCESS_ADMIN_PORT})"
