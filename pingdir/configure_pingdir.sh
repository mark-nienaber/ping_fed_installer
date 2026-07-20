#!/bin/bash
set -euo pipefail

################################################################################
# Script Name: configure_pingdir.sh
# Description: Phase 2 — configure PingDirectory content + schema for the
#              integrated stack.
#
#   1. Directory content: ou=people / ou=groups / ou=applications, the
#      PingFederate LDAP-admin user (uid=pfadmin) + group (cn=pf-admins),
#      and the PingFederate datastore service account (cn=pingfederate).
#   2. PingFederate schema (loaded from PF's own shipped LDIFs):
#        - OAuth access-grant schema + ou=AccessGrant container
#        - authentication-session schema + ou=sessions container
#      This is what makes PF sessions + OAuth grants persist in PingDirectory
#      instead of memory (the customer requirement).
#   3. ACIs granting the service account read on people and read/write on the
#      grant + session containers.
#
#   All operations are idempotent (ldapmodify --continueOnError; "already
#   exists" / "attribute exists" are treated as success).
################################################################################

source ./pingconfig.env
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "${_LIB_DIR}/logging.sh"

LDAPMODIFY="${PINGDIR_DIR}/bin/ldapmodify"
PF_CONF="${PINGFED_DIR}/server/default/conf"
_PW_FILE=""

trap '[[ -n "$_PW_FILE" ]] && rm -f "$_PW_FILE"; error "configure_pingdir.sh failed at line $LINENO"' ERR

function _pw_file() {
    _PW_FILE=$(mktemp); chmod 600 "$_PW_FILE"
    printf '%s' "$PINGDIR_ROOT_PASSWORD" > "$_PW_FILE"
}

# ldapmodify wrapper — plaintext LDAP on :1389, continue on "already exists".
# Reads LDIF from stdin. Returns 0 even on benign 68/20 (exists) errors.
function pd_modify() {
    local out rc
    out=$("$LDAPMODIFY" \
            --hostname localhost --port "$PINGDIR_LDAP_PORT" \
            --bindDN "$PINGDIR_ROOT_DN" --bindPasswordFile "$_PW_FILE" \
            --defaultAdd --continueOnError 2>&1) || rc=$?
    rc=${rc:-0}
    # Filter benign "already exists" noise
    if [[ $rc -ne 0 ]]; then
        if echo "$out" | grep -qiE 'already exists|entry already|attribute or value exists|Result Code: +(20|68)'; then
            return 0
        fi
        error "ldapmodify failed (rc=$rc):"; echo "$out" | sed 's/^/    /' | head -15
        return 1
    fi
    return 0
}

function pd_modify_file() {
    local f=$1
    "$LDAPMODIFY" \
        --hostname localhost --port "$PINGDIR_LDAP_PORT" \
        --bindDN "$PINGDIR_ROOT_DN" --bindPasswordFile "$_PW_FILE" \
        --defaultAdd --continueOnError --filename "$f" 2>&1 | \
        grep -viE 'already exists|result code 0|processing MODIFY|processing ADD' | sed 's/^/    /' || true
}

# -----------------------------------------------------------------------------
# 1. Base directory content
# -----------------------------------------------------------------------------
function create_content() {
    info "Creating directory content (OUs, PF admin user/group, service account)..."
    pd_modify <<LDIF
dn: ${PINGDIR_PEOPLE_DN}
objectClass: top
objectClass: organizationalUnit
ou: people

dn: ${PINGDIR_GROUPS_DN}
objectClass: top
objectClass: organizationalUnit
ou: groups

dn: ${PINGDIR_APPS_DN}
objectClass: top
objectClass: organizationalUnit
ou: applications

dn: ${PINGFED_ADMIN_USER_DN}
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
uid: ${PINGFED_ADMIN_UID}
givenName: Ping
sn: Admin
cn: PingFederate Admin
mail: ${PINGFED_ADMIN_UID}@example.com
userPassword: ${PINGFED_ADMIN_PASSWORD}

dn: ${PINGFED_ADMIN_GROUP_DN}
objectClass: top
objectClass: groupOfUniqueNames
cn: pf-admins
description: PingFederate administrators
uniqueMember: ${PINGFED_ADMIN_USER_DN}

dn: ${LDAP_BIND_DN}
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
uid: pingfederate
givenName: PingFederate
sn: Service
cn: pingfederate
description: PingFederate datastore service account
userPassword: ${LDAP_BIND_PASSWORD}
LDIF
    success "Directory content created"
}

# -----------------------------------------------------------------------------
# 2. PingFederate schema (from PF's shipped PingDirectory LDIFs)
# -----------------------------------------------------------------------------
function load_pf_schema() {
    local grant_attrs="${PF_CONF}/access-grant/ldif-scripts/access-grant-attributes-ldap-pingdirectory.ldif"
    local grant_struct="${PF_CONF}/access-grant/ldif-scripts/access-grant-ldap-pingdirectory.ldif"
    local sess_attrs="${PF_CONF}/authentication-session/ldif-scripts/authentication-session-attributes-ldap-pingdirectory.ldif"

    for f in "$grant_attrs" "$grant_struct" "$sess_attrs"; do
        [[ -f "$f" ]] || { error "PF schema LDIF missing: $f"; return 1; }
    done

    info "Loading PF OAuth access-grant schema into PingDirectory..."
    pd_modify_file "$grant_attrs"

    # Both the grant structure LDIF and the session attributes LDIF contain a
    # container entry using the placeholder '<Your DC Here>' alongside their
    # cn=schema modifications — substitute the base DN in each before applying.
    info "Loading PF access-grant container + objectClass (ou=AccessGrant)..."
    local tmp; tmp=$(mktemp)
    sed "s|<Your DC Here>|${PINGDIR_BASE_DN}|g" "$grant_struct" > "$tmp"
    pd_modify_file "$tmp"

    info "Loading PF authentication-session schema + container (ou=AuthenticationSessions)..."
    sed "s|<Your DC Here>|${PINGDIR_BASE_DN}|g" "$sess_attrs" > "$tmp"
    pd_modify_file "$tmp"
    rm -f "$tmp"

    success "PF schema loaded; grant + session containers present"
}

# -----------------------------------------------------------------------------
# 3. ACIs — service account access to people + grant/session subtrees
# -----------------------------------------------------------------------------
function apply_acis() {
    info "Applying ACIs for the PingFederate service account..."
    local grant_dn="ou=AccessGrant,${PINGDIR_BASE_DN}"
    pd_modify <<LDIF
dn: ${PINGDIR_PEOPLE_DN}
changetype: modify
add: aci
aci: (targetattr="*")(version 3.0; acl "PF read people"; allow (read,search,compare) userdn="ldap:///${LDAP_BIND_DN}";)

dn: ${grant_dn}
changetype: modify
add: aci
aci: (targetattr="*")(version 3.0; acl "PF access grants rw"; allow (all) userdn="ldap:///${LDAP_BIND_DN}";)

dn: ${PINGFED_SESSIONS_BASE_DN}
changetype: modify
add: aci
aci: (targetattr="*")(version 3.0; acl "PF sessions rw"; allow (all) userdn="ldap:///${LDAP_BIND_DN}";)
LDIF
    success "ACIs applied"
}

# -----------------------------------------------------------------------------
section "PingDirectory — Phase 2 configuration"
_pw_file
create_content
load_pf_schema
apply_acis
rm -f "$_PW_FILE"; _PW_FILE=""
success "PingDirectory configuration complete"
