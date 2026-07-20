#!/bin/bash
set -euo pipefail

################################################################################
# Script Name: pingfed.sh
# Description: Phase 1 — install PingFederate to a running baseline.
#              Extracts the product, drops the license into
#              server/default/conf/pingfederate.lic (verified path, PF 13.1
#              admin reference guide), and starts the server via bin/run.sh.
#
#              Admin-account bootstrap (native console/API auth), datastore to
#              PingDirectory, adapters, OAuth/OIDC clients and externalized
#              session/grant storage are applied later by Phase 2
#              (configure_pingfed).
#
#              Idempotent: completed install is marked; re-runs only ensure the
#              server is running.
#
# Zip layout: pingfederate-<ver>/pingfederate/{bin,server,...}  (inner
# 'pingfederate' dir is <pf_install>). License path is relative to that root.
################################################################################

source ./pingconfig.env
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "${_LIB_DIR}/logging.sh"

INSTALL_MARKER="${PINGFED_DIR}/.ping-install-complete"
PF_LICENSE_TARGET="${PINGFED_DIR}/server/default/conf/pingfederate.lic"
PF_RUN_LOG="${LOG_DIR}/pingfederate-run.log"

function resolve_software() {
    PF_ZIP=$(find "${PINGFED_SOFTWARE_DIR}" -maxdepth 1 -name 'pingfederate-*.zip' -type f 2>/dev/null | head -n1)
    [[ -f "$PF_ZIP" ]] || { error "No pingfederate-*.zip in ${PINGFED_SOFTWARE_DIR}"; return 1; }
    [[ -f "${PINGFED_LICENSE:-}" ]] || { error "No PingFederate .lic in ${PINGFED_SOFTWARE_DIR}"; return 1; }
    info "Software: $(basename "$PF_ZIP")"
    info "License:  $(basename "$PINGFED_LICENSE")"
}

function extract() {
    if [[ -x "${PINGFED_DIR}/bin/run.sh" ]]; then
        info "PingFederate already extracted at ${PINGFED_DIR}"; return 0
    fi
    info "Extracting PingFederate into ${PINGFED_DIR}..."
    local tmp; tmp=$(mktemp -d)
    unzip -q "$PF_ZIP" -d "$tmp"
    # Inner 'pingfederate' directory is the install root (<pf_install>)
    local root; root=$(find "$tmp" -maxdepth 2 -type d -name pingfederate | head -n1)
    [[ -d "$root" ]] || { error "Could not locate inner 'pingfederate' dir in zip"; rm -rf "$tmp"; return 1; }
    mkdir -p "${PINGFED_DIR}"
    cp -a "${root}/." "${PINGFED_DIR}/"
    rm -rf "$tmp"
    [[ -x "${PINGFED_DIR}/bin/run.sh" ]] || { error "run.sh missing after extract"; return 1; }
    success "Extracted"
}

function place_license() {
    mkdir -p "$(dirname "$PF_LICENSE_TARGET")"
    cp -f "$PINGFED_LICENSE" "$PF_LICENSE_TARGET"
    chmod 640 "$PF_LICENSE_TARGET"
    success "License installed at server/default/conf/pingfederate.lic"
}

function _port_listening() {
    local port=$1
    (command -v ss >/dev/null && ss -ltn 2>/dev/null | grep -q ":${port} ") \
      || (command -v netstat >/dev/null && netstat -tuln 2>/dev/null | grep -q ":${port} ")
}

function ensure_started() {
    if _port_listening "$PINGFED_ADMIN_PORT"; then
        success "PingFederate admin already listening on ${PINGFED_ADMIN_PORT}"
    else
        info "Starting PingFederate (bin/run.sh, background)..."
        mkdir -p "$LOG_DIR"
        ( cd "$PINGFED_DIR" && nohup ./bin/run.sh > "$PF_RUN_LOG" 2>&1 & )
    fi

    info "Waiting for PingFederate admin console (up to 180s)..."
    local waited=0
    while [[ $waited -lt 180 ]]; do
        local code
        code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 \
               "https://${PINGFED_HOSTNAME}:${PINGFED_ADMIN_PORT}/pingfederate/app" 2>/dev/null || echo "000")
        if [[ "$code" =~ ^(200|302|401)$ ]]; then
            success "PingFederate admin console ready (HTTP $code) on ${PINGFED_ADMIN_PORT}"
            return 0
        fi
        sleep 5; waited=$((waited+5))
        [[ $((waited % 30)) -eq 0 ]] && info "  still waiting... (${waited}s, last HTTP $code)"
    done
    error "PingFederate admin console not ready after 180s (see $PF_RUN_LOG)"; return 1
}

trap 'error "pingfed.sh failed at line $LINENO"' ERR

section "PingFederate — Phase 1 install"
resolve_software
extract
place_license
ensure_started
touch "$INSTALL_MARKER"
success "PingFederate baseline ready (engine :${PINGFED_ENGINE_PORT}, admin :${PINGFED_ADMIN_PORT})"
