#!/bin/bash
set -euo pipefail

################################################################################
# Script Name: pingdir.sh
# Description: Phase 1 — install PingDirectory to a running baseline.
#              Extracts the product zip, runs the non-interactive `setup` tool
#              (license, root user, base DN + base entry, LDAP/LDAPS/HTTPS ports,
#              StartTLS, self-signed cert), and starts the server.
#
#              Schema, service accounts, session/grant containers and sample
#              data are applied later by Phase 2 (configure_pingdir).
#
#              Idempotent: a completed install is marked and re-runs only ensure
#              the server is started.
#
# Flags verified against PingDirectory 11.1 docs/cli/setup.html.
################################################################################

source ./pingconfig.env
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "${_LIB_DIR}/logging.sh"

PINGDIR_LOCATION="${PINGDIR_LOCATION:-ping}"
PINGDIR_MAX_HEAP="${PINGDIR_MAX_HEAP:-1g}"
SETUP_MARKER="${PINGDIR_DIR}/.ping-setup-complete"
_PW_FILE=""

# -----------------------------------------------------------------------------
# Locate software + license
# -----------------------------------------------------------------------------
function resolve_software() {
    PD_ZIP=$(find "${PINGDIR_SOFTWARE_DIR}" -maxdepth 1 -name 'PingDirectory-*.zip' -type f 2>/dev/null | head -n1)
    [[ -f "$PD_ZIP" ]] || { error "No PingDirectory-*.zip in ${PINGDIR_SOFTWARE_DIR}"; return 1; }
    [[ -f "${PINGDIR_LICENSE:-}" ]] || { error "No PingDirectory .lic in ${PINGDIR_SOFTWARE_DIR}"; return 1; }
    info "Software: $(basename "$PD_ZIP")"
    info "License:  $(basename "$PINGDIR_LICENSE")"
}

# -----------------------------------------------------------------------------
# Extract zip into the install directory (zip top-level is PingDirectory/)
# -----------------------------------------------------------------------------
function extract() {
    if [[ -x "${PINGDIR_DIR}/setup" ]]; then
        info "PingDirectory already extracted at ${PINGDIR_DIR}"
        return 0
    fi
    info "Extracting PingDirectory into ${PINGDIR_DIR}..."
    local tmp; tmp=$(mktemp -d)
    unzip -q "$PD_ZIP" -d "$tmp"
    mkdir -p "${PINGDIR_DIR}"
    cp -a "${tmp}/PingDirectory/." "${PINGDIR_DIR}/"
    rm -rf "$tmp"
    [[ -x "${PINGDIR_DIR}/setup" ]] || { error "setup tool missing after extract"; return 1; }
    success "Extracted"
}

# -----------------------------------------------------------------------------
# Non-interactive setup
# -----------------------------------------------------------------------------
function run_setup() {
    if [[ -f "$SETUP_MARKER" ]]; then
        info "PingDirectory already set up (marker present) — skipping setup"
        return 0
    fi

    # Root password via 0600 temp file (keeps it out of the process table)
    _PW_FILE=$(mktemp); chmod 600 "$_PW_FILE"
    printf '%s' "$PINGDIR_ROOT_PASSWORD" > "$_PW_FILE"

    # Base population: sample data if requested, otherwise just the base entry
    local base_args=(--baseDN "$PINGDIR_BASE_DN")
    if [[ "${PINGDIR_SAMPLE_ENTRIES:-0}" -gt 0 ]]; then
        base_args+=(--sampleData "$PINGDIR_SAMPLE_ENTRIES")
    else
        base_args+=(--addBaseEntry)
    fi

    info "Running PingDirectory setup (LDAP:${PINGDIR_LDAP_PORT} LDAPS:${PINGDIR_LDAPS_PORT} HTTPS:${PINGDIR_HTTPS_PORT})..."
    (
        cd "$PINGDIR_DIR"
        ./setup \
            --no-prompt \
            --acceptLicense \
            --licenseKeyFile "$PINGDIR_LICENSE" \
            --instanceName "$PINGDIR_INSTANCE_NAME" \
            --location "$PINGDIR_LOCATION" \
            --rootUserDN "$PINGDIR_ROOT_DN" \
            --rootUserPasswordFile "$_PW_FILE" \
            "${base_args[@]}" \
            --ldapPort "$PINGDIR_LDAP_PORT" \
            --ldapsPort "$PINGDIR_LDAPS_PORT" \
            --httpsPort "$PINGDIR_HTTPS_PORT" \
            --enableStartTLS \
            --generateSelfSignedCertificate \
            --maxHeapSize "$PINGDIR_MAX_HEAP"
    )
    rm -f "$_PW_FILE"; _PW_FILE=""
    touch "$SETUP_MARKER"
    success "PingDirectory setup completed"
}

# -----------------------------------------------------------------------------
# Ensure the server is running + reachable on LDAPS
# -----------------------------------------------------------------------------
function _ldaps_listening() {
    (command -v ss >/dev/null && ss -ltn 2>/dev/null | grep -q ":${PINGDIR_LDAPS_PORT} ") \
      || (command -v netstat >/dev/null && netstat -tuln 2>/dev/null | grep -q ":${PINGDIR_LDAPS_PORT} ")
}

function ensure_started() {
    # setup (without --doNotStart) already starts the server. The LDAPS port is
    # the reliable signal — check it first and only start if it's not up, to
    # avoid a redundant start-server that fails on the server.lock file.
    if _ldaps_listening; then
        success "PingDirectory already running (LDAPS ${PINGDIR_LDAPS_PORT} listening)"
        return 0
    fi

    info "Starting PingDirectory..."
    "${PINGDIR_DIR}/bin/start-server" || { error "start-server failed"; return 1; }

    local waited=0
    while [[ $waited -lt 60 ]]; do
        if _ldaps_listening; then
            success "PingDirectory LDAPS listening on ${PINGDIR_LDAPS_PORT}"
            return 0
        fi
        sleep 3; waited=$((waited+3))
    done
    error "PingDirectory LDAPS port ${PINGDIR_LDAPS_PORT} not listening after 60s"; return 1
}

# -----------------------------------------------------------------------------
trap '[[ -n "$_PW_FILE" ]] && rm -f "$_PW_FILE"; error "pingdir.sh failed at line $LINENO"' ERR

section "PingDirectory — Phase 1 install"
resolve_software
extract
run_setup
ensure_started
success "PingDirectory baseline ready"
