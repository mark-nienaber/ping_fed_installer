#!/bin/bash
set -euo pipefail

################################################################################
# Script Name: configure_pingaccess.sh
# Description: Phase 2 — configure PingAccess.
#
#   Part A — Admin bootstrap (first login):
#     - accept the click-through license agreement (SLA)
#     - change the default administrator password (2Access -> configured)
#
#   Part B — (next build step) PingFederate token provider, virtual host,
#            site, application and access rules.
#
#   Idempotent: detects whether the default password has already been rotated.
################################################################################

source ./pingconfig.env
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "${_LIB_DIR}/logging.sh"
# shellcheck disable=SC1091
source "${_LIB_DIR}/rest_helpers.sh"

trap 'error "configure_pingaccess.sh failed at line $LINENO"' ERR

PA_DEFAULT_PASS="2Access"

# Wait for the admin API to respond at all (any HTTP status = server up).
function wait_pa_up() {
    local i=0
    info "Waiting for PingAccess admin API to respond..."
    while [[ $i -lt 30 ]]; do
        local code
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
               -H 'X-XSRF-Header: PingAccess' "${PINGACCESS_ADMIN_API}/version" 2>/dev/null || echo 000)
        [[ "$code" =~ ^(200|401|403)$ ]] && { success "PingAccess admin API responding"; return 0; }
        sleep 3; ((i++)) || true
    done
    error "PingAccess admin API not responding"; return 1
}

# Resolve which password currently works (readiness-independent); sets _PA_PASS.
function resolve_pa_password() {
    _PA_PASS="$PA_DEFAULT_PASS"
    pa_request GET /users/1 >/dev/null 2>&1
    if [[ "$_PING_HTTP_CODE" == "200" ]]; then
        info "PingAccess still on default password"
        _PA_STATE="default"; return 0
    fi
    _PA_PASS="$PINGACCESS_ADMIN_PASSWORD"
    pa_request GET /users/1 >/dev/null 2>&1
    if [[ "$_PING_HTTP_CODE" == "200" ]]; then
        info "PingAccess password already rotated"
        _PA_STATE="rotated"; return 0
    fi
    error "Cannot authenticate to PingAccess with default or configured password"
    return 1
}

function accept_sla_and_rotate() {
    if [[ "${_PA_STATE}" == "rotated" ]]; then
        info "SLA + password already handled — skipping"; return 0
    fi

    # 1. Accept SLA (and clear firstLogin + the tutorial overlay) via PUT /users/1
    info "Accepting PingAccess license agreement (SLA)..."
    local user_json
    user_json=$(pa_request GET /users/1)
    # slaAccepted=true, firstLogin=false, showTutorial=false so the first console
    # login lands directly on a usable dashboard, not the SLA/tutorial wizard.
    local patched
    patched=$(echo "$user_json" | python3 -c "import sys,json;u=json.load(sys.stdin);u['slaAccepted']=True;u['firstLogin']=False;u['showTutorial']=False;print(json.dumps(u))")
    pa_request PUT /users/1 "$patched" >/dev/null 2>&1
    [[ "$_PING_HTTP_CODE" == "200" ]] && success "SLA accepted" || warning "SLA update returned HTTP $_PING_HTTP_CODE"

    # 2. Rotate the default admin password
    info "Changing PingAccess admin password..."
    local pw_body
    pw_body=$(python3 -c "import json;print(json.dumps({'currentPassword':'${PA_DEFAULT_PASS}','newPassword':'${PINGACCESS_ADMIN_PASSWORD}'}))")
    pa_request PUT /users/1/password "$pw_body" >/dev/null 2>&1
    if [[ "$_PING_HTTP_CODE" =~ ^20 ]]; then
        _PA_PASS="$PINGACCESS_ADMIN_PASSWORD"
        success "PingAccess admin password changed"
    else
        error "Password change failed (HTTP $_PING_HTTP_CODE)"; return 1
    fi
}

# PingAccess objects are created by POST with a server-assigned numeric id, so
# idempotency is by NAME: look the item up in its collection and reuse its id,
# or create it. Echoes the resolved id.
function pa_ensure_named() {   # COLLECTION NAME_FIELD NAME PAYLOAD LABEL
    local coll=$1 namefield=$2 name=$3 payload=$4 label=$5
    local existing
    existing=$(pa_request GET "/$coll" 2>/dev/null | python3 -c "
import sys,json
try: items=json.load(sys.stdin).get('items',[])
except: items=[]
for i in items:
    if str(i.get('$namefield'))=='''$name''': print(i.get('id')); break
")
    if [[ -n "$existing" ]]; then
        info "  $label already exists (id=$existing) — skipping" >&2
        printf '%s' "$existing"; return 0
    fi
    local tmp; tmp=$(mktemp)
    pa_request POST "/$coll" "$payload" > "$tmp" 2>/dev/null
    if [[ "$_PING_HTTP_CODE" =~ ^20 ]]; then
        local id; id=$(python3 -c "import sys,json;print(json.load(open('$tmp')).get('id',''))")
        success "  $label created (id=$id)" >&2
        rm -f "$tmp"; printf '%s' "$id"; return 0
    fi
    error "  $label failed (HTTP $_PING_HTTP_CODE): $(head -c 300 "$tmp")" >&2; rm -f "$tmp"; return 1
}

function configure_pa_api() {
    info "PingAccess API configuration (PF token provider, web session, vhost, site, app)..."

    # 1. PingFederate as the token provider (OIDC issuer). Trust group 2 = "Trust
    #    Any" so PA trusts PF's self-signed runtime cert in this dev topology
    #    (replace with a real trusted cert group for production).
    # PingAccess validates this issuer now by fetching its OIDC discovery, so it
    # must be reachable. In HA the console node serves no runtime, so point at the
    # live engine node; Phase 3 (rewire_frontdoor) re-points this to the load
    # balancer issuer once the front door is up.
    local pf_issuer="$PINGFED_BASE_URL"
    if [[ "${PINGFED_COUNT:-1}" -gt 1 ]]; then
        pf_issuer="https://${PINGFED_HOSTNAME}:${PINGFED2_ENGINE_PORT}"
    fi
    pa_request PUT /pingfederate/runtime "$(cat <<JSON
{ "issuer": "${pf_issuer}", "trustedCertificateGroupId": 2,
  "useProxy": false, "useSlo": false, "skipHostnameVerification": true }
JSON
)" >/dev/null 2>&1
    # Setting the token provider can make PA reload and reset the connection, so a
    # transient non-200 is possible even when the value was applied; confirm by GET.
    if [[ "$_PING_HTTP_CODE" != "200" ]]; then
        sleep 2
        local got; got=$(pa_request GET /pingfederate/runtime 2>/dev/null \
            | python3 -c "import sys,json;print(json.load(sys.stdin).get('issuer',''))" 2>/dev/null || true)
        [[ "$got" == "$pf_issuer" ]] && _PING_HTTP_CODE=200
    fi
    if [[ "$_PING_HTTP_CODE" == "200" ]]; then
        success "  PingFederate set as token provider (issuer ${pf_issuer})"
    else
        error "  Failed to set PF runtime (HTTP $_PING_HTTP_CODE)"; return 1
    fi

    # 2. Web session — the browser SSO session, backed by the pingaccess-client
    local ws_id
    ws_id=$(pa_ensure_named webSessions name "app-websession" "$(cat <<JSON
{ "name": "app-websession", "audience": "app",
  "clientCredentials": {"clientId": "${PINGFED_OIDC_CLIENT_ID}",
                        "clientSecret": {"value": "${PINGFED_OIDC_CLIENT_SECRET}"}},
  "scopes": ["openid"] }
JSON
)" "Web session (app-websession)")

    # 3. Virtual host for the protected app (host:enginePort)
    local vh_id
    vh_id=$(pa_ensure_named virtualhosts host "${SAMPLE_APP_VIRTUAL_HOST}" "$(cat <<JSON
{ "host": "${SAMPLE_APP_VIRTUAL_HOST}", "port": ${PINGACCESS_ENGINE_PORT} }
JSON
)" "Virtual host (${SAMPLE_APP_VIRTUAL_HOST}:${PINGACCESS_ENGINE_PORT})")

    # 4. Site — the backend origin PA reverse-proxies to
    local site_target="${SAMPLE_APP_TARGET#http://}"; site_target="${site_target#https://}"
    local site_id
    site_id=$(pa_ensure_named sites name "sample-app-site" "$(cat <<JSON
{ "name": "sample-app-site", "targets": ["${site_target}"], "secure": false }
JSON
)" "Site (-> ${site_target})")

    # 4b. Identity Mapping — inject the authenticated subject as an HTTP header
    #     (X-USER) so the backend app can see who logged in.
    local im_id
    im_id=$(pa_ensure_named identityMappings name "sub-to-header" "$(cat <<JSON
{ "name": "sub-to-header",
  "className": "com.pingidentity.pa.identitymappings.HeaderIdentityMapping",
  "configuration": {"headerClientCertificateMappings": [],
    "attributeHeaderMappings": [{"subject": true, "attributeName": "sub", "headerName": "X-USER"}]} }
JSON
)" "Identity mapping (sub -> X-USER)")

    # 5. Application — binds vhost + context root + site + web session + identity
    #    mapping; Web auth means every request must carry a valid PA web session
    #    (SSO via PF), and PA injects the X-USER header to the backend.
    local app_id
    app_id=$(pa_ensure_named applications name "sample-app" "$(cat <<JSON
{ "name": "sample-app", "contextRoot": "/", "virtualHostIds": [${vh_id}],
  "siteId": ${site_id}, "webSessionId": ${ws_id},
  "identityMappingIds": {"Web": ${im_id}},
  "defaultAuthType": "Web", "applicationType": "Web", "enabled": true }
JSON
)" "Application (sample-app)")

    success "PingAccess protects https://${SAMPLE_APP_VIRTUAL_HOST}:${PINGACCESS_ENGINE_PORT}/ via PingFederate SSO"
}

# -----------------------------------------------------------------------------
section "PingAccess — Phase 2 configuration"
wait_pa_up
resolve_pa_password
accept_sla_and_rotate
configure_pa_api
success "PingAccess configuration complete (admin password rotated)"
