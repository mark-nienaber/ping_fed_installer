#!/bin/bash
set -euo pipefail

################################################################################
# Script Name: cluster_pingdir.sh
# Description: Stand up PingDirectory node 2 and join it to node 1 in a
#              replicated topology (single-host demo: node 2 gets its own
#              install dir + offset ports).
#
#   1. Extract + setup PD2 (same base DN, its own ports, smaller heap).
#   2. Create the same OAuth-grant indexes on PD2 (index config is per-server,
#      NOT replicated — data replicates, configuration does not).
#   3. dsreplication enable between node 1 and node 2 for the base DN.
#   4. dsreplication initialize-all — seed node 2 from node 1 (users, PF schema,
#      grant/session containers, ACIs, everything already configured on node 1).
#
#   Idempotent: install is marked; replication is skipped when the base DN is
#   already replicated across both servers.
#
#   Only runs when PINGDIR_COUNT > 1.
################################################################################

source ./pingconfig.env
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "${_LIB_DIR}/logging.sh"

PINGDIR_LOCATION="${PINGDIR_LOCATION:-ping}"
SETUP2_MARKER="${PINGDIR2_DIR}/.ping-setup-complete"
DSCONFIG2="${PINGDIR2_DIR}/bin/dsconfig"
REBUILD2="${PINGDIR2_DIR}/bin/rebuild-index"
DSREPL="${PINGDIR_DIR}/bin/dsreplication"
_PW_FILE=""

trap '[[ -n "$_PW_FILE" ]] && rm -f "$_PW_FILE"; error "cluster_pingdir.sh failed at line $LINENO"' ERR

function _pw_file() {
    _PW_FILE=$(mktemp); chmod 600 "$_PW_FILE"
    printf '%s' "$PINGDIR_ROOT_PASSWORD" > "$_PW_FILE"
}

# -----------------------------------------------------------------------------
# 1. Extract + setup PD2
# -----------------------------------------------------------------------------
function resolve_software() {
    PD_ZIP=$(find "${PINGDIR_SOFTWARE_DIR}" -maxdepth 1 -name 'PingDirectory-*.zip' -type f 2>/dev/null | head -n1)
    [[ -f "$PD_ZIP" ]] || { error "No PingDirectory-*.zip in ${PINGDIR_SOFTWARE_DIR}"; return 1; }
    [[ -f "${PINGDIR_LICENSE:-}" ]] || { error "No PingDirectory .lic in ${PINGDIR_SOFTWARE_DIR}"; return 1; }
}

function extract2() {
    if [[ -x "${PINGDIR2_DIR}/setup" ]]; then
        info "PD2 already extracted at ${PINGDIR2_DIR}"; return 0
    fi
    info "Extracting PingDirectory node 2 into ${PINGDIR2_DIR}..."
    local tmp; tmp=$(mktemp -d)
    unzip -q "$PD_ZIP" -d "$tmp"
    mkdir -p "${PINGDIR2_DIR}"
    cp -a "${tmp}/PingDirectory/." "${PINGDIR2_DIR}/"
    rm -rf "$tmp"
    [[ -x "${PINGDIR2_DIR}/setup" ]] || { error "setup tool missing after extract"; return 1; }
    success "PD2 extracted"
}

function setup2() {
    if [[ -f "$SETUP2_MARKER" ]]; then
        info "PD2 already set up (marker present) — skipping setup"; return 0
    fi
    _pw_file
    # Node 2 is seeded from node 1 by replication, so it needs only the base-DN
    # backend defined (--addBaseEntry keeps it a valid standalone until init
    # overwrites its content from node 1).
    info "Running PD2 setup (LDAP:${PINGDIR2_LDAP_PORT} LDAPS:${PINGDIR2_LDAPS_PORT} HTTPS:${PINGDIR2_HTTPS_PORT})..."
    (
        cd "$PINGDIR2_DIR"
        ./setup \
            --no-prompt \
            --acceptLicense \
            --licenseKeyFile "$PINGDIR_LICENSE" \
            --instanceName "$PINGDIR2_INSTANCE_NAME" \
            --location "$PINGDIR_LOCATION" \
            --rootUserDN "$PINGDIR_ROOT_DN" \
            --rootUserPasswordFile "$_PW_FILE" \
            --baseDN "$PINGDIR_BASE_DN" --addBaseEntry \
            --ldapPort "$PINGDIR2_LDAP_PORT" \
            --ldapsPort "$PINGDIR2_LDAPS_PORT" \
            --httpsPort "$PINGDIR2_HTTPS_PORT" \
            --enableStartTLS \
            --generateSelfSignedCertificate \
            --maxHeapSize "${PINGDIR2_MAX_HEAP:-768m}"
    )
    rm -f "$_PW_FILE"; _PW_FILE=""
    touch "$SETUP2_MARKER"
    success "PD2 setup completed"
}

function ensure2_started() {
    if ss -ltn 2>/dev/null | grep -q ":${PINGDIR2_LDAPS_PORT} "; then
        success "PD2 already running (LDAPS ${PINGDIR2_LDAPS_PORT} listening)"; return 0
    fi
    info "Starting PD2..."
    "${PINGDIR2_DIR}/bin/start-server" || { error "PD2 start-server failed"; return 1; }
    local waited=0
    while [[ $waited -lt 60 ]]; do
        ss -ltn 2>/dev/null | grep -q ":${PINGDIR2_LDAPS_PORT} " && { success "PD2 LDAPS listening on ${PINGDIR2_LDAPS_PORT}"; return 0; }
        sleep 3; waited=$((waited+3))
    done
    error "PD2 LDAPS ${PINGDIR2_LDAPS_PORT} not listening after 60s"; return 1
}

# -----------------------------------------------------------------------------
# 2. Grant indexes on PD2 (config is per-server; not replicated)
# -----------------------------------------------------------------------------
# Wait until node 1's runtime schema (accessGrant* attributes, added by
# configure_pingdir) has replicated to node 2 — indexes reference those
# attributes and can't be created until the schema is present locally.
function _wait_pd2_schema() {
    local ls="${PINGDIR2_DIR}/bin/ldapsearch" i=0
    info "Waiting for accessGrant* schema to replicate to PD2..."
    while [[ $i -lt 24 ]]; do
        if "$ls" --hostname localhost --port "$PINGDIR2_LDAPS_PORT" --useSSL --trustAll \
              --bindDN "$PINGDIR_ROOT_DN" --bindPasswordFile "$_PW_FILE" \
              --baseDN cn=schema --searchScope base "(objectClass=*)" attributeTypes 2>/dev/null \
              | grep -qi "'accessGrantGuid'"; then
            success "PD2 schema has accessGrant* attributes"; return 0
        fi
        sleep 5; ((i++)) || true
    done
    error "accessGrant* schema did not replicate to PD2 within 120s"; return 1
}

function index2() {
    _pw_file
    _wait_pd2_schema
    info "Creating OAuth-grant indexes on PD2 (config is per-server, not replicated)..."
    local specs=(
        "accessGrantGuid:equality" "accessGrantUniqueUserIdentifier:equality"
        "accessGrantHashedRefreshTokenValue:equality" "accessGrantClientId:equality"
        "accessGrantGrantType:equality" "accessGrantExpires:ordering"
    )
    local existing
    existing=$("$DSCONFIG2" --no-prompt \
        --hostname localhost --port "$PINGDIR2_LDAPS_PORT" --useSSL --trustAll \
        --bindDN "$PINGDIR_ROOT_DN" --bindPasswordFile "$_PW_FILE" \
        list-local-db-indexes --backend-name userRoot 2>/dev/null || true)
    local spec attr itype
    for spec in "${specs[@]}"; do
        attr="${spec%%:*}"; itype="${spec##*:}"
        if grep -qiw -- "$attr" <<<"$existing"; then
            info "  PD2 index ${attr} already present — skipping"; continue
        fi
        "$DSCONFIG2" --no-prompt \
            --hostname localhost --port "$PINGDIR2_LDAPS_PORT" --useSSL --trustAll \
            --bindDN "$PINGDIR_ROOT_DN" --bindPasswordFile "$_PW_FILE" \
            create-local-db-index --backend-name userRoot \
            --index-name "$attr" --set "index-type:${itype}" >/dev/null
        success "  PD2 index created: ${attr} (${itype})"
    done
    rm -f "$_PW_FILE"; _PW_FILE=""
}

# -----------------------------------------------------------------------------
# 3 + 4. Enable + initialize replication
# -----------------------------------------------------------------------------
function _repl_already() {
    # True if the base DN shows as replicated across both servers.
    "$DSREPL" status \
        --hostname localhost --port "$PINGDIR_LDAPS_PORT" --useSSL --trustAll \
        --adminUID "$PINGDIR_REPL_ADMIN_UID" --adminPasswordFile "$_PW_FILE" \
        --no-prompt 2>/dev/null | grep -q "$PINGDIR_BASE_DN" \
        && "$DSREPL" status \
        --hostname localhost --port "$PINGDIR_LDAPS_PORT" --useSSL --trustAll \
        --adminUID "$PINGDIR_REPL_ADMIN_UID" --adminPasswordFile "$_PW_FILE" \
        --no-prompt 2>/dev/null | grep -qi "${PINGDIR2_INSTANCE_NAME}\|:${PINGDIR2_LDAPS_PORT}\|:${PINGDIR2_LDAP_PORT}"
}

function enable_replication() {
    _pw_file
    if _repl_already; then
        success "Replication already enabled for ${PINGDIR_BASE_DN} across both nodes — skipping"
        rm -f "$_PW_FILE"; _PW_FILE=""; return 0
    fi

    info "Enabling replication node1(${PINGDIR_LDAPS_PORT}) <-> node2(${PINGDIR2_LDAPS_PORT}) for ${PINGDIR_BASE_DN}..."
    "$DSREPL" enable \
        --host1 localhost --port1 "$PINGDIR_LDAPS_PORT" --useSSL1 \
        --bindDN1 "$PINGDIR_ROOT_DN" --bindPasswordFile1 "$_PW_FILE" \
        --replicationPort1 "$PINGDIR_REPLICATION_PORT" \
        --host2 localhost --port2 "$PINGDIR2_LDAPS_PORT" --useSSL2 \
        --bindDN2 "$PINGDIR_ROOT_DN" --bindPasswordFile2 "$_PW_FILE" \
        --replicationPort2 "$PINGDIR2_REPLICATION_PORT" \
        --baseDN "$PINGDIR_BASE_DN" \
        --adminUID "$PINGDIR_REPL_ADMIN_UID" --adminPasswordFile "$_PW_FILE" \
        --trustAll --no-prompt --ignoreWarnings
    success "Replication enabled"

    info "Initializing node 2 from node 1 (seeding all data under ${PINGDIR_BASE_DN})..."
    "$DSREPL" initialize-all \
        --hostname localhost --port "$PINGDIR_LDAPS_PORT" --useSSL --trustAll \
        --baseDN "$PINGDIR_BASE_DN" \
        --adminUID "$PINGDIR_REPL_ADMIN_UID" --adminPasswordFile "$_PW_FILE" \
        --no-prompt
    success "Node 2 initialized from node 1"
    rm -f "$_PW_FILE"; _PW_FILE=""
}

function show_status() {
    _pw_file
    info "Replication status:"
    "$DSREPL" status \
        --hostname localhost --port "$PINGDIR_LDAPS_PORT" --useSSL --trustAll \
        --adminUID "$PINGDIR_REPL_ADMIN_UID" --adminPasswordFile "$_PW_FILE" \
        --no-prompt 2>/dev/null | grep -viE 'tput:' | sed 's/^/    /' | head -30 || true
    rm -f "$_PW_FILE"; _PW_FILE=""
}

# -----------------------------------------------------------------------------
section "PingDirectory — clustering (node 2 + replication)"
if [[ "${PINGDIR_COUNT:-1}" -le 1 ]]; then
    info "PINGDIR_COUNT=${PINGDIR_COUNT:-1} — single node, nothing to cluster"; exit 0
fi
resolve_software
extract2
setup2
ensure2_started
enable_replication
index2
show_status
success "PingDirectory replication topology ready"
