#!/usr/bin/env bash
# =============================================================================
# bin/ping-test-sso.sh — Drive a full browser-style SSO login end to end and
#   assert it worked: hit the PingAccess-protected app, authenticate at the
#   PingFederate HTML Form (creds validated in PingDirectory), exchange the
#   OAuth code, land on the protected page, and confirm PingAccess injected the
#   authenticated identity. Then check the authentication session persisted to
#   PingDirectory.
#
# Usage:  ./bin/ping-test-sso.sh [username] [password]
#           defaults: testuser1 / $DEFAULT_PASSWORD
# Exit:   0 = SSO succeeded, 1 = failed (with diagnostics)
# =============================================================================
set -uo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_ROOT}/lib/logging.sh"
cd "$SCRIPT_ROOT"
# shellcheck source=/dev/null
source "${SCRIPT_ROOT}/pingconfig.env"

USER_NAME="${1:-testuser1}"
USER_PASS="${2:-$DEFAULT_PASSWORD}"
# In LB mode the app and PingFederate are reached through the HAProxy front door
# on :443, not the raw PA engine / PF engine ports (PA returns 403 off-vhost).
if [[ "${LB_ENABLED:-false}" == "true" ]]; then
    APP="https://${SAMPLE_APP_VIRTUAL_HOST}:${LB_HTTPS_PORT}/"
    PF_ENGINE="https://${PINGFED_HOSTNAME}:${LB_HTTPS_PORT}"
else
    APP="https://${SAMPLE_APP_VIRTUAL_HOST}:${PINGACCESS_ENGINE_PORT}/"
    PF_ENGINE="${PINGFED_BASE_URL}"
fi

CJ=$(mktemp); LP=$(mktemp); BODY=$(mktemp)
cleanup() { rm -f "$CJ" "$LP" "$BODY"; }
trap cleanup EXIT

banner "SSO end-to-end test — user ${USER_NAME}"

# 1. Unauthenticated hit -> PingAccess should redirect to PF authorization
info "1/5  GET ${APP} (expect redirect to PingFederate)"
AUTHZ=$(curl -sk -c "$CJ" -o /dev/null -w '%{redirect_url}' "$APP" 2>/dev/null)
[[ "$AUTHZ" == *"/as/authorization.oauth2"* ]] \
    || { error "PA did not redirect to PF authorization endpoint (got: ${AUTHZ:-<none>})"; exit 1; }
success "     redirected to PF authorization endpoint"

# 2. Load the HTML Form login page from PF
info "2/5  load PingFederate login page"
curl -sk -b "$CJ" -c "$CJ" "$AUTHZ" -o "$LP" 2>/dev/null
ACTION=$(grep -oiE 'action="[^"]*"' "$LP" | head -1 | sed 's/action="//;s/"//')
[[ -n "$ACTION" ]] || { error "no login form found (adapter/PCV misconfigured?)"; exit 1; }
RESUME="${PF_ENGINE}${ACTION}"
success "     login form served (resume: ${ACTION})"

# 3. Submit credentials -> PF authenticates against PingDirectory, returns code
info "3/5  submit credentials for ${USER_NAME}"
CB=$(curl -sk -b "$CJ" -c "$CJ" -o /dev/null -w '%{redirect_url}' \
        --data-urlencode "pf.username=${USER_NAME}" \
        --data-urlencode "pf.pass=${USER_PASS}" \
        --data-urlencode "pf.ok=clicked" \
        "$RESUME" 2>/dev/null)
[[ "$CB" == *"code="* ]] \
    || { error "login did not yield an authorization code — bad credentials or auth policy (no redirect to ${SAMPLE_APP_VIRTUAL_HOST}/pa/oidc/cb)"; exit 1; }
success "     authenticated; OAuth code issued"

# 4. Follow the PA callback (code -> token exchange, sets PA web session)
info "4/5  PingAccess exchanges code for tokens"
curl -sk -b "$CJ" -c "$CJ" -o /dev/null "$CB" 2>/dev/null
grep -qiE 'PA\.' "$CJ" || warning "     no PA.* session cookie observed (continuing)"
success "     token exchange done, web session established"

# 5. Access the protected app with the session; assert identity was injected
info "5/5  GET protected app with the SSO session"
HTTP=$(curl -sk -b "$CJ" -c "$CJ" -L -o "$BODY" -w '%{http_code}' "$APP" 2>/dev/null)
# Strip HTML tags so the X-USER header and its value (rendered in adjacent table
# cells) sit on one whitespace-separated line for the assertion.
STRIPPED=$(sed 's/<[^>]*>/ /g' "$BODY" | tr -s ' ')
if [[ "$HTTP" == "200" ]] && grep -qi 'reached the protected app' <<<"$STRIPPED" \
   && grep -qiE "X-USER +${USER_NAME}\b" <<<"$STRIPPED"; then
    success "     app returned 200 with injected identity X-USER=${USER_NAME}"
else
    error "protected app check failed (HTTP ${HTTP}); identity X-USER=${USER_NAME} not found"
    grep -oiE "X-USER +[^ ]*" <<<"$STRIPPED" | head -1
    exit 1
fi

# Bonus: confirm the authentication session was externalized to PingDirectory
info "verify: authentication session persisted in PingDirectory"
n=$("${PINGDIR_DIR}/bin/ldapsearch" --port "$PINGDIR_LDAP_PORT" --bindDN "$PINGDIR_ROOT_DN" \
      --bindPassword "$PINGDIR_ROOT_PASSWORD" --baseDN "$PINGFED_SESSIONS_BASE_DN" \
      --searchScope sub "(pf-authn-session-group-id=*)" dn 2>/dev/null | grep -c '^dn:' || echo 0)
[[ "${n:-0}" -ge 1 ]] \
    && success "     ${n} authentication session(s) stored under ${PINGFED_SESSIONS_BASE_DN}" \
    || warning "     no session rows found in ${PINGFED_SESSIONS_BASE_DN}"

printf '\n'
success "SSO END-TO-END TEST PASSED for ${USER_NAME}"
