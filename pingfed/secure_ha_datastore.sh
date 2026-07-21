#!/bin/bash
set -euo pipefail

################################################################################
# Script Name: secure_ha_datastore.sh
# Description: Make PingFederate's PingDirectory datastore SECURE and HIGHLY
#              AVAILABLE:
#
#     - LDAPS (useSsl) instead of plaintext ldap://:1389 — bind creds and all
#       directory traffic (users, sessions, grants) are now encrypted.
#     - Two hostnames (node 1 :1636 + node 2 :2636) so PingFederate fails over
#       to the replicated peer if one node is down.
#     - PingDirectory's self-signed certs imported into PF's trusted CA store,
#       with verifyHost against the cert SAN (the PD certs carry the host IP).
#
#   Runs on the console, then replicates to the engine (POST /cluster/replicate)
#   so both cluster nodes talk to the directory over LDAPS with failover.
#   Idempotent: a no-op once the datastore already uses SSL. Only meaningful when
#   PINGDIR_COUNT > 1 (needs the second node to fail over to).
################################################################################

source ./pingconfig.env
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "${_LIB_DIR}/logging.sh"
# shellcheck disable=SC1091
source "${_LIB_DIR}/rest_helpers.sh"

# The PD self-signed certs' SAN includes the host IP (not ping.example.com), so
# LDAPS must target an address that appears in the SAN for verifyHost to pass.
LDAPS_HOST="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
LDAPS_HOST="${LDAPS_HOST:-127.0.0.1}"
DS_ID="${PINGFED_PD_DATASTORE_ID}"

trap 'error "secure_ha_datastore.sh failed at line $LINENO"' ERR

# Import one PingDirectory server cert (fetched from its LDAPS port) into PF's
# trusted CA store. Self-signed end-entity certs are their own trust anchor.
function import_pd_ca() {
    local port=$1 label=$2
    local pem; pem=$(mktemp)
    if ! echo | openssl s_client -connect "127.0.0.1:${port}" 2>/dev/null | openssl x509 2>/dev/null > "$pem" || [[ ! -s "$pem" ]]; then
        error "could not fetch PD cert from :${port}"; rm -f "$pem"; return 1
    fi
    local b64; b64=$(base64 -w0 "$pem"); rm -f "$pem"
    local tmp; tmp=$(mktemp)
    pf_request POST /certificates/ca/import "{\"fileData\":\"${b64}\"}" > "$tmp" 2>/dev/null
    if [[ "$_PING_HTTP_CODE" =~ ^20 ]]; then
        success "  imported ${label} cert into PF trusted CAs"
    else
        error "  ${label} CA import failed (HTTP $_PING_HTTP_CODE): $(head -c 200 "$tmp")"; rm -f "$tmp"; return 1
    fi
    rm -f "$tmp"
}

function secure_datastore() {
    local body; body=$(pf_request GET "/dataStores/${DS_ID}")
    [[ "$_PING_HTTP_CODE" == "200" ]] || { error "datastore ${DS_ID} not found"; return 1; }
    if echo "$body" | grep -q '"useSsl":true'; then
        info "Datastore already LDAPS — verifying hostnames"
        echo "$body" | python3 -c "import sys,json;d=json.load(sys.stdin);print('  hostnames:',d.get('hostnames'),'useSsl:',d.get('useSsl'))"
        return 0
    fi

    info "Importing PingDirectory certs into PingFederate trust..."
    import_pd_ca "$PINGDIR_LDAPS_PORT"  "node 1 (:${PINGDIR_LDAPS_PORT})"
    import_pd_ca "$PINGDIR2_LDAPS_PORT" "node 2 (:${PINGDIR2_LDAPS_PORT})"

    info "Switching datastore to LDAPS + dual-node failover (${LDAPS_HOST}:${PINGDIR_LDAPS_PORT},${LDAPS_HOST}:${PINGDIR2_LDAPS_PORT})..."
    local merged; merged=$(echo "$body" | \
        H="$LDAPS_HOST" P1="$PINGDIR_LDAPS_PORT" P2="$PINGDIR2_LDAPS_PORT" python3 -c "
import sys, json, os
d = json.load(sys.stdin)
h, p1, p2 = os.environ['H'], os.environ['P1'], os.environ['P2']
hosts = ['%s:%s' % (h, p1), '%s:%s' % (h, p2)]   # node1 then node2 (failover)
d['hostnames'] = hosts
# hostnamesTags mirrors hostnames; PF rejects a mismatch between the two.
d['hostnamesTags'] = [{'hostnames': hosts, 'defaultSource': True}]
d['useSsl'] = True
d['useStartTLS'] = False
d['verifyHost'] = True
json.dump(d, sys.stdout)")
    local tmp; tmp=$(mktemp)
    pf_request PUT "/dataStores/${DS_ID}" "$merged" > "$tmp" 2>/dev/null
    if [[ "$_PING_HTTP_CODE" =~ ^20 ]]; then
        success "Datastore now LDAPS with failover across both nodes"
    else
        error "datastore PUT failed (HTTP $_PING_HTTP_CODE): $(head -c 300 "$tmp")"; rm -f "$tmp"; return 1
    fi
    rm -f "$tmp"
}

function replicate() {
    if [[ "${PINGFED_COUNT:-1}" -le 1 ]]; then return 0; fi
    info "Replicating config (CAs + datastore) console -> engine..."
    local tmp; tmp=$(mktemp)
    pf_request POST /cluster/replicate > "$tmp" 2>/dev/null
    [[ "$_PING_HTTP_CODE" =~ ^20 ]] && success "Replicated to engine(s)" \
        || warning "replicate HTTP $_PING_HTTP_CODE: $(head -c 160 "$tmp")"
    rm -f "$tmp"
}

# -----------------------------------------------------------------------------
section "PingFederate datastore — secure (LDAPS) + HA (failover)"
if [[ "${PINGDIR_COUNT:-1}" -le 1 ]]; then
    info "PINGDIR_COUNT=${PINGDIR_COUNT:-1} — single directory node, no failover peer; skipping"
    exit 0
fi
pf_ready 6 3 || { error "PF console API not reachable"; exit 1; }
secure_datastore
replicate
success "PingFederate datastore is encrypted (LDAPS) and HA across both PingDirectory nodes"
