#!/usr/bin/env bash
# =============================================================================
# bin/ping-validate.sh — End-to-end health + integration check for the stack.
#
#   Validates each product is up, the PA->PF->PD wiring is live, and the
#   customer requirement (PF sessions + OAuth grants externalized to
#   PingDirectory) actually holds. Read-only: makes no changes.
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
ok()   { success "$1"; PASS=$((PASS+1)); }
bad()  { error   "$1"; FAIL=$((FAIL+1)); }

_code() { curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "$@" 2>/dev/null || echo 000; }
PF_A=(-u "${PINGFED_ADMIN_UID}:${DEFAULT_PASSWORD}" -H "X-XSRF-Header: PingFederate" -H "Accept: application/json")
PA_A=(-u "${PINGACCESS_ADMIN_USER}:${PINGACCESS_ADMIN_PASSWORD}" -H "X-XSRF-Header: PingAccess" -H "Accept: application/json")
PFADMIN="https://${PINGFED_HOSTNAME}:${PINGFED_ADMIN_PORT}/pf-admin-api/v1"
PAADMIN="${PINGACCESS_ADMIN_API}"
_ldap() { "${PINGDIR_DIR}/bin/ldapsearch" --port "$PINGDIR_LDAP_PORT" --bindDN "$PINGDIR_ROOT_DN" \
            --bindPassword "$PINGDIR_ROOT_PASSWORD" --baseDN "$1" --searchScope "${3:-base}" "${2:-(objectclass=*)}" dn 2>/dev/null; }

banner "Ping stack validation"

section "PingDirectory"
if _ldap "$PINGDIR_BASE_DN" >/dev/null 2>&1; then ok "LDAP up; base DN ${PINGDIR_BASE_DN} present"; else bad "PingDirectory LDAP not answering on ${PINGDIR_LDAP_PORT}"; fi
_ldap "$PINGFED_GRANTS_BASE_DN"   >/dev/null 2>&1 && ok "grant container ${PINGFED_GRANTS_BASE_DN} present"     || bad "missing ${PINGFED_GRANTS_BASE_DN}"
_ldap "$PINGFED_SESSIONS_BASE_DN" >/dev/null 2>&1 && ok "session container ${PINGFED_SESSIONS_BASE_DN} present" || bad "missing ${PINGFED_SESSIONS_BASE_DN}"

section "PingFederate"
[[ "$(_code "${PF_A[@]}" "$PFADMIN/version")" == "200" ]] && ok "admin API reachable (auth ${PINGFED_ADMIN_UID} via PD)" || bad "admin API/auth failing"
[[ "$(_code "${PINGFED_BASE_URL}/pf/heartbeat.ping")" == "200" ]] && ok "runtime engine heartbeat 200" || bad "engine heartbeat not 200"
issuer=$(curl -sk --max-time 8 "${PINGFED_BASE_URL}/.well-known/openid-configuration" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('issuer',''))" 2>/dev/null)
[[ "$issuer" == "${PINGFED_BASE_URL}" ]] && ok "OIDC issuer = ${issuer}" || bad "OIDC issuer wrong/absent ('${issuer}')"
[[ "$(_code "${PF_A[@]}" "$PFADMIN/oauth/clients/${PINGFED_OIDC_CLIENT_ID}")" == "200" ]] && ok "OAuth client ${PINGFED_OIDC_CLIENT_ID} exists" || bad "OAuth client missing"

# Externalized storage: managers active on disk + sessions enabled via API
sp="${PINGFED_DIR}/server/default/conf/service-points.conf"
grep -qE '^access\.grant\.manager=.*LDAPPingDirectoryImpl$'  "$sp" 2>/dev/null && ok "grant manager = LDAP PingDirectory"   || bad "grant manager not externalized"
grep -qE '^session\.storage\.manager=.*SessionStorageManagerLdapImpl$' "$sp" 2>/dev/null && ok "session manager = LDAP" || bad "session manager not externalized"
en=$(curl -sk "${PF_A[@]}" "$PFADMIN/session/authenticationSessionPolicies/global" 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('enableSessions'),d.get('persistentSessions'))" 2>/dev/null)
[[ "$en" == "True True" ]] && ok "authentication sessions enabled + persistent" || bad "auth sessions not enabled/persistent ($en)"

section "PingAccess"
[[ "$(_code "${PA_A[@]}" "$PAADMIN/version")" == "200" ]] && ok "admin API reachable" || bad "admin API/auth failing"
paissuer=$(curl -sk "${PA_A[@]}" "$PAADMIN/pingfederate/runtime" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('issuer',''))" 2>/dev/null)
[[ "$paissuer" == "${PINGFED_BASE_URL}" ]] && ok "PF set as token provider (issuer ${paissuer})" || bad "PF token provider not set ('${paissuer}')"

section "End-to-end SSO wiring"
loc=$(curl -sk -o /dev/null -w '%{redirect_url}' --max-time 8 "https://${SAMPLE_APP_VIRTUAL_HOST}:${PINGACCESS_ENGINE_PORT}/" 2>/dev/null || true)
if [[ "$loc" == *"/as/authorization.oauth2"* && "$loc" == *"client_id=${PINGFED_OIDC_CLIENT_ID}"* ]]; then
    ok "PA-protected app redirects to PF for SSO"
else
    bad "PA->PF redirect not confirmed (is ${SAMPLE_APP_VIRTUAL_HOST} resolvable + engine up?)"
fi

printf '\n'
if [[ $FAIL -eq 0 ]]; then
    success "ALL CHECKS PASSED (${PASS}/${PASS})"
else
    error "${FAIL} check(s) FAILED, ${PASS} passed"
fi
[[ $FAIL -eq 0 ]]
