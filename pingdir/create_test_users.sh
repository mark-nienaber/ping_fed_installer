#!/bin/bash
set -euo pipefail

################################################################################
# Script Name: create_test_users.sh
# Description: Phase 3 — seed test users (testuser1..N) into PingDirectory under
#              ou=people. These authenticate through the PingFederate HTML Form
#              adapter (LDAP PCV) during the PA->PF->PD SSO flow.
#
#   Idempotent: uses --defaultAdd --continueOnError and treats "already exists"
#   as success. Count comes from TEST_USER_COUNT (env or pingconfig.env).
################################################################################

source ./pingconfig.env
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "${_LIB_DIR}/logging.sh"

COUNT="${TEST_USER_COUNT:-5}"
LDAPMODIFY="${PINGDIR_DIR}/bin/ldapmodify"
_PW_FILE=""
trap '[[ -n "$_PW_FILE" ]] && rm -f "$_PW_FILE"; error "create_test_users.sh failed at line $LINENO"' ERR

_PW_FILE=$(mktemp); chmod 600 "$_PW_FILE"; printf '%s' "$PINGDIR_ROOT_PASSWORD" > "$_PW_FILE"

info "Creating ${COUNT} test user(s) under ${PINGDIR_PEOPLE_DN}"
for i in $(seq 1 "$COUNT"); do
    out=$("$LDAPMODIFY" --hostname localhost --port "$PINGDIR_LDAP_PORT" \
        --bindDN "$PINGDIR_ROOT_DN" --bindPasswordFile "$_PW_FILE" \
        --defaultAdd --continueOnError 2>&1 <<LDIF || true
dn: uid=testuser${i},${PINGDIR_PEOPLE_DN}
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
uid: testuser${i}
givenName: Test
sn: User ${i}
cn: Test User ${i}
mail: testuser${i}@example.com
userPassword: ${DEFAULT_PASSWORD}
LDIF
)
    if echo "$out" | grep -qiE 'Result Code: +0|ADD operation successful'; then
        success "  testuser${i} created"
    elif echo "$out" | grep -qiE 'already exists|Result Code: +68'; then
        info "  testuser${i} already exists — skipping"
    else
        error "  testuser${i} failed:"; echo "$out" | sed 's/^/    /' | head -5; exit 1
    fi
done

rm -f "$_PW_FILE"; _PW_FILE=""
success "Test users ready (testuser1..${COUNT}, password: ${DEFAULT_PASSWORD})"
