#!/bin/bash
set -euo pipefail

################################################################################
# Script Name: rewire_frontdoor.sh
# Description: Point the stack's public runtime URLs at the load-balancer front
#              door (TLS-terminated :443, no port) instead of the raw engine
#              ports, so the whole browser SSO flow transits the LB:
#
#   PingFederate (console API -> replicate to engine):
#     - federationInfo.baseUrl -> https://ping.<domain>   (=> OIDC issuer)
#     - pingaccess-client already carries the no-port redirect URI
#   PingAccess (admin API):
#     - PingFederate runtime issuer -> https://ping.<domain>
#     - sample-app virtual host port -> 443 (matches Host + X-Forwarded-Proto:https)
#
#   Idempotent: only writes when a value differs; re-replicates PF config each run
#   so the engine picks up the new issuer.
################################################################################

source ./pingconfig.env
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "${_LIB_DIR}/logging.sh"
# shellcheck disable=SC1091
source "${_LIB_DIR}/rest_helpers.sh"

PF_BASE_URL="${LB_PF_BASE_URL}"        # https://ping.example.com
PA_ISSUER="${LB_PF_BASE_URL}"
# PA admin password was rotated off the stock 2Access during configure.
_PA_PASS="${PINGACCESS_ADMIN_PASSWORD}"
trap 'error "rewire_frontdoor.sh failed at line $LINENO"' ERR

# ---- PingFederate: federation base URL (OIDC issuer) --------------------------
function pf_set_base_url() {
    local body; body=$(pf_request GET /serverSettings)
    local cur; cur=$(echo "$body" | python3 -c "import sys,json;print(json.load(sys.stdin)['federationInfo'].get('baseUrl',''))" 2>/dev/null || true)
    if [[ "$cur" == "$PF_BASE_URL" ]]; then
        info "PF baseUrl already ${PF_BASE_URL} — skipping"; return 0
    fi
    info "PF baseUrl ${cur} -> ${PF_BASE_URL}"
    local merged; merged=$(echo "$body" | NEW="$PF_BASE_URL" python3 -c "
import sys,json,os
d=json.load(sys.stdin); d['federationInfo']['baseUrl']=os.environ['NEW']; json.dump(d,sys.stdout)")
    local tmp; tmp=$(mktemp)
    pf_request PUT /serverSettings "$merged" > "$tmp" 2>/dev/null
    [[ "$_PING_HTTP_CODE" =~ ^20 ]] || { error "PF serverSettings PUT failed ($_PING_HTTP_CODE): $(head -c 200 "$tmp")"; rm -f "$tmp"; return 1; }
    rm -f "$tmp"; success "PF baseUrl updated"
}

function pf_replicate() {
    info "Replicating PF config console -> engine..."
    local tmp; tmp=$(mktemp)
    pf_request POST /cluster/replicate > "$tmp" 2>/dev/null
    [[ "$_PING_HTTP_CODE" =~ ^20 ]] && success "PF config replicated to engine(s)" \
        || warning "PF replicate HTTP $_PING_HTTP_CODE: $(head -c 160 "$tmp")"
    rm -f "$tmp"
}

# In HA the baseUrl change must reach the engine and show up in its OIDC discovery
# before PingAccess re-fetches it. If PA fetches too early it caches the console
# port (which serves no runtime in a cluster) and every login fails to connect.
function wait_pf_discovery_lb() {
    local want="${PF_BASE_URL}/as/authorization.oauth2" i=0 got
    info "Waiting for PF discovery to advertise the load-balancer endpoints..."
    while [[ $i -lt 20 ]]; do
        got=$(curl -sk "${PF_BASE_URL}/.well-known/openid-configuration" 2>/dev/null \
            | python3 -c "import sys,json;print(json.load(sys.stdin).get('authorization_endpoint',''))" 2>/dev/null || true)
        [[ "$got" == "$want" ]] && { success "discovery now advertises ${PF_BASE_URL}"; return 0; }
        sleep 3; i=$((i+1))
    done
    warning "PF discovery still not at the LB endpoint (got: ${got:-none}); PA may cache a stale endpoint"
    return 0
}

# Force PA to re-read PF discovery once everything is settled. The stored config
# does not change, but the PUT refreshes PA's cached authorization endpoint.
function pa_refresh_discovery() {
    local body; body=$(pa_request GET /pingfederate/runtime)
    pa_request PUT /pingfederate/runtime "$body" >/dev/null 2>&1
    [[ "$_PING_HTTP_CODE" =~ ^20 ]] && success "PA discovery cache refreshed" \
        || warning "PA discovery refresh HTTP $_PING_HTTP_CODE"
}

# ---- PingAccess: token-provider issuer + app virtual host port ----------------
function pa_set_issuer() {
    local body; body=$(pa_request GET /pingfederate/runtime)
    local cur; cur=$(echo "$body" | python3 -c "import sys,json;print(json.load(sys.stdin).get('issuer',''))" 2>/dev/null || true)
    if [[ "$cur" == "$PA_ISSUER" ]]; then info "PA issuer already ${PA_ISSUER} — skipping"; return 0; fi
    info "PA issuer ${cur} -> ${PA_ISSUER}"
    local merged; merged=$(echo "$body" | NEW="$PA_ISSUER" python3 -c "
import sys,json,os
d=json.load(sys.stdin); d['issuer']=os.environ['NEW']; json.dump(d,sys.stdout)")
    local tmp; tmp=$(mktemp)
    pa_request PUT /pingfederate/runtime "$merged" > "$tmp" 2>/dev/null
    [[ "$_PING_HTTP_CODE" =~ ^20 ]] || { error "PA runtime PUT failed ($_PING_HTTP_CODE): $(head -c 200 "$tmp")"; rm -f "$tmp"; return 1; }
    rm -f "$tmp"; success "PA issuer updated"
}

function pa_vhost_443() {
    # Flip the sample-app virtual host (app.example.com) to the public LB port.
    local body; body=$(pa_request GET /virtualhosts)
    local vh; vh=$(echo "$body" | HOST="$LB_HOSTNAME_APP" python3 -c "
import sys,json,os
for v in json.load(sys.stdin)['items']:
    if v['host']==os.environ['HOST']: print(json.dumps(v)); break")
    [[ -n "$vh" ]] || { error "no virtual host for ${LB_HOSTNAME_APP}"; return 1; }
    local port; port=$(echo "$vh" | python3 -c "import sys,json;print(json.load(sys.stdin)['port'])")
    if [[ "$port" == "$LB_HTTPS_PORT" ]]; then info "PA vhost ${LB_HOSTNAME_APP} already :${LB_HTTPS_PORT} — skipping"; return 0; fi
    local vid; vid=$(echo "$vh" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    info "PA vhost ${LB_HOSTNAME_APP}:${port} -> :${LB_HTTPS_PORT} (id ${vid})"
    local merged; merged=$(echo "$vh" | PORT="$LB_HTTPS_PORT" python3 -c "
import sys,json,os
d=json.load(sys.stdin); d['port']=int(os.environ['PORT']); json.dump(d,sys.stdout)")
    local tmp; tmp=$(mktemp)
    pa_request PUT "/virtualhosts/${vid}" "$merged" > "$tmp" 2>/dev/null
    [[ "$_PING_HTTP_CODE" =~ ^20 ]] || { error "PA vhost PUT failed ($_PING_HTTP_CODE): $(head -c 200 "$tmp")"; rm -f "$tmp"; return 1; }
    rm -f "$tmp"; success "PA vhost now ${LB_HOSTNAME_APP}:${LB_HTTPS_PORT}"
}

# -----------------------------------------------------------------------------
section "Rewire runtime URLs to the load-balancer front door"
if [[ "${LB_ENABLED:-false}" != "true" ]]; then
    info "LB_ENABLED=${LB_ENABLED:-false} — nothing to rewire"; exit 0
fi
pf_ready 6 3 || { error "PF console API not reachable"; exit 1; }
pf_set_base_url
pf_replicate
wait_pf_discovery_lb
pa_ready 6 3 || { error "PA admin API not reachable"; exit 1; }
pa_set_issuer
pa_vhost_443
pa_refresh_discovery
success "Front-door rewire complete: issuer + app now served via https://${LB_HOSTNAME_PF} / https://${LB_HOSTNAME_APP}"
