#!/usr/bin/env bash
# =============================================================================
# bin/ping-validate.sh — End-to-end health + integration check for the stack.
#
#   Validates every component is up and the integration holds. Adapts to the
#   deployment: in clustered / load-balanced mode it also checks PingDirectory
#   replication, the PingFederate cluster, the secure+HA datastore, and that the
#   load balancer routes to the runtime tiers — and uses the LB/engine URLs
#   instead of the single-node engine ports. Read-only: makes no changes.
#
# Usage:  ./bin/ping-validate.sh
# Exit:   0 if all checks pass, 1 if any fail.
# =============================================================================
set -uo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_ROOT}/lib/logging.sh"
cd "$SCRIPT_ROOT"
# shellcheck source=/dev/null
source "${SCRIPT_ROOT}/pingconfig.env"

PASS=0; FAIL=0
ok()  { success "$1"; PASS=$((PASS+1)); }
bad() { error   "$1"; FAIL=$((FAIL+1)); }
_code() { curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "$@" 2>/dev/null || echo 000; }
_json() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }

CLUSTERED_PD=$([[ "${PINGDIR_COUNT:-1}" -gt 1 ]] && echo 1 || echo 0)
CLUSTERED_PF=$([[ "${PINGFED_COUNT:-1}" -gt 1 ]] && echo 1 || echo 0)
LB_ON=$([[ "${LB_ENABLED:-false}" == "true" ]] && echo 1 || echo 0)

# Effective runtime URLs: through the LB (clustered) or the raw engine ports.
if [[ "$LB_ON" == "1" ]]; then
    RT_URL="$LB_PF_BASE_URL"                                    # PF runtime front / OIDC issuer
    APP_URL="$LB_APP_BASE_URL"
else
    RT_URL="$PINGFED_BASE_URL"
    APP_URL="https://${SAMPLE_APP_VIRTUAL_HOST}:${PINGACCESS_ENGINE_PORT}"
fi

PF_A=(-u "${PINGFED_ADMIN_UID}:${DEFAULT_PASSWORD}" -H "X-XSRF-Header: PingFederate" -H "Accept: application/json")
PA_A=(-u "${PINGACCESS_ADMIN_USER}:${PINGACCESS_ADMIN_PASSWORD}" -H "X-XSRF-Header: PingAccess" -H "Accept: application/json")
PFADMIN="https://${PINGFED_HOSTNAME}:${PINGFED_ADMIN_PORT}/pf-admin-api/v1"
PAADMIN="${PINGACCESS_ADMIN_API}"
_ldap() { "${PINGDIR_DIR}/bin/ldapsearch" --port "${3:-$PINGDIR_LDAP_PORT}" --bindDN "$PINGDIR_ROOT_DN" \
            --bindPassword "$PINGDIR_ROOT_PASSWORD" --baseDN "$1" --searchScope base "(objectclass=*)" dn 2>/dev/null; }

banner "Ping stack validation  (mode: PD x${PINGDIR_COUNT:-1}, PF x${PINGFED_COUNT:-1}, LB=$([[ $LB_ON == 1 ]] && echo on || echo off))"

# ---------------------------------------------------------------- PingDirectory
section "PingDirectory"
_ldap "$PINGDIR_BASE_DN" >/dev/null 2>&1 && ok "node 1 LDAP up; base DN present" || bad "node 1 LDAP not answering on ${PINGDIR_LDAP_PORT}"
_ldap "$PINGFED_GRANTS_BASE_DN"   >/dev/null 2>&1 && ok "grant container present"   || bad "missing ${PINGFED_GRANTS_BASE_DN}"
_ldap "$PINGFED_SESSIONS_BASE_DN" >/dev/null 2>&1 && ok "session container present" || bad "missing ${PINGFED_SESSIONS_BASE_DN}"
if [[ "$CLUSTERED_PD" == "1" ]]; then
    _ldap "$PINGDIR_BASE_DN" "" "$PINGDIR2_LDAP_PORT" >/dev/null 2>&1 && ok "node 2 LDAP up (:${PINGDIR2_LDAP_PORT})" || bad "node 2 LDAP not answering on ${PINGDIR2_LDAP_PORT}"
    pw=$(mktemp); chmod 600 "$pw"; printf '%s' "$PINGDIR_ROOT_PASSWORD" > "$pw"
    rst=$("${PINGDIR_DIR}/bin/dsreplication" status --hostname localhost --port "$PINGDIR_LDAPS_PORT" --useSSL --trustAll \
            --adminUID "$PINGDIR_REPL_ADMIN_UID" --adminPasswordFile "$pw" --no-prompt 2>/dev/null)
    rm -f "$pw"
    if echo "$rst" | grep -qi 'Enabled' && echo "$rst" | grep -qi 'pingdirectory-1' && echo "$rst" | grep -qi 'pingdirectory-2'; then
        # backlog is the 5th ':'-delimited column of each replica row; all should be 0
        backlog=$(echo "$rst" | awk -F: '/pingdirectory-[12]/{gsub(/ /,"",$5); if($5!="0" && $5!="") print $5}')
        [[ -z "$backlog" ]] && ok "replication enabled + both nodes in sync (0 backlog)" || bad "replication backlog non-zero ($backlog)"
    else
        bad "replication not enabled across both nodes"
    fi
fi

# ---------------------------------------------------------------- PingFederate
section "PingFederate"
[[ "$(_code "${PF_A[@]}" "$PFADMIN/version")" == "200" ]] && ok "admin API reachable (auth ${PINGFED_ADMIN_UID} via PD over LDAPS)" || bad "admin API/auth failing"
[[ "$(_code "${RT_URL}/pf/heartbeat.ping")" == "200" ]] && ok "runtime engine heartbeat 200 (${RT_URL})" || bad "engine heartbeat not 200 at ${RT_URL}"
issuer=$(curl -sk --max-time 8 "${RT_URL}/.well-known/openid-configuration" 2>/dev/null | _json "d.get('issuer','')")
[[ "$issuer" == "$RT_URL" ]] && ok "OIDC issuer = ${issuer}" || bad "OIDC issuer wrong/absent ('${issuer}', expected ${RT_URL})"
[[ "$(_code "${PF_A[@]}" "$PFADMIN/oauth/clients/${PINGFED_OIDC_CLIENT_ID}")" == "200" ]] && ok "OAuth client ${PINGFED_OIDC_CLIENT_ID} exists" || bad "OAuth client missing"

sp="${PINGFED_DIR}/server/default/conf/service-points.conf"
grep -qE '^access\.grant\.manager=.*LDAPPingDirectoryImpl$'  "$sp" 2>/dev/null && ok "grant manager externalized to PD"   || bad "grant manager not externalized"
grep -qE '^session\.storage\.manager=.*SessionStorageManagerLdapImpl$' "$sp" 2>/dev/null && ok "session manager externalized to PD" || bad "session manager not externalized"
en=$(curl -sk "${PF_A[@]}" "$PFADMIN/session/authenticationSessionPolicies/global" 2>/dev/null | _json "str(d.get('enableSessions'))+' '+str(d.get('persistentSessions'))")
[[ "$en" == "True True" ]] && ok "authentication sessions enabled + persistent" || bad "auth sessions not enabled/persistent ($en)"

# Secure + HA datastore (clustered PD)
if [[ "$CLUSTERED_PD" == "1" ]]; then
    ds=$(curl -sk "${PF_A[@]}" "$PFADMIN/dataStores/${PINGFED_PD_DATASTORE_ID}" 2>/dev/null)
    ssl=$(echo "$ds" | _json "d.get('useSsl')"); nhosts=$(echo "$ds" | _json "len(d.get('hostnames',[]))")
    [[ "$ssl" == "True" ]] && ok "datastore uses LDAPS (encrypted PF->PD)" || bad "datastore NOT using LDAPS (useSsl=$ssl)"
    [[ "${nhosts:-0}" -ge 2 ]] && ok "datastore has ${nhosts} hostnames (failover/HA)" || bad "datastore not HA (hostnames=${nhosts:-0})"
    grep -q '^ldap.url=ldaps://' "${PINGFED_DIR}/bin/ldap.properties" 2>/dev/null && ok "admin-console auth over LDAPS" || bad "admin-console auth not LDAPS"
fi

# PF cluster membership
if [[ "$CLUSTERED_PF" == "1" ]]; then
    cs=$(curl -sk "${PF_A[@]}" "$PFADMIN/cluster/status" 2>/dev/null)
    echo "$cs" | grep -q 'CLUSTERED_CONSOLE' && echo "$cs" | grep -q 'CLUSTERED_ENGINE' \
        && ok "PF cluster: console + engine both present" || bad "PF cluster incomplete"
    nrepl=$(echo "$cs" | _json "sum(1 for n in d.get('nodes',[]) if n.get('replicationStatus')=='SUCCEEDED')")
    [[ "${nrepl:-0}" -ge 2 ]] && ok "cluster config replicated to all nodes (SUCCEEDED x${nrepl})" || bad "cluster config not fully replicated (SUCCEEDED=${nrepl:-0})"
fi

# ---------------------------------------------------------------- PingAccess
section "PingAccess"
[[ "$(_code "${PA_A[@]}" "$PAADMIN/version")" == "200" ]] && ok "admin API reachable" || bad "admin API/auth failing"
paissuer=$(curl -sk "${PA_A[@]}" "$PAADMIN/pingfederate/runtime" 2>/dev/null | _json "d.get('issuer','')")
[[ "$paissuer" == "$RT_URL" ]] && ok "PF token provider issuer = ${paissuer}" || bad "PF token provider issuer wrong ('${paissuer}', expected ${RT_URL})"

# ---------------------------------------------------------------- Load balancer
if [[ "$LB_ON" == "1" ]]; then
    section "Load balancer"
    (command -v ss >/dev/null && ss -ltn 2>/dev/null | grep -q ":${LB_HTTPS_PORT} ") && ok "HAProxy listening on :${LB_HTTPS_PORT}" || bad "HAProxy not listening on :${LB_HTTPS_PORT}"
    [[ "$(_code "${LB_PF_BASE_URL}/pf/heartbeat.ping")" == "200" ]] && ok "LB -> PF engine (heartbeat 200)" || bad "LB not routing to PF engine"
    lbapp=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "${LB_APP_BASE_URL}/" 2>/dev/null || echo 000)
    [[ "$lbapp" =~ ^(302|200|401|403)$ ]] && ok "LB -> PA app (HTTP ${lbapp})" || bad "LB not routing to PA app (HTTP ${lbapp})"
fi

# ---------------------------------------------------------------- E2E wiring
section "End-to-end SSO wiring"
loc=$(curl -sk -o /dev/null -w '%{redirect_url}' --max-time 8 "${APP_URL}/" 2>/dev/null || true)
if [[ "$loc" == *"/as/authorization.oauth2"* && "$loc" == *"client_id=${PINGFED_OIDC_CLIENT_ID}"* ]]; then
    ok "protected app redirects to PF for SSO (${APP_URL} -> PF authz)"
else
    bad "PA->PF redirect not confirmed at ${APP_URL} (loc='${loc:0:60}')"
fi

printf '\n'
if [[ $FAIL -eq 0 ]]; then success "ALL CHECKS PASSED (${PASS}/${PASS})"; else error "${FAIL} check(s) FAILED, ${PASS} passed"; fi
[[ $FAIL -eq 0 ]]
