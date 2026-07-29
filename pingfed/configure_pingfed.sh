#!/bin/bash
set -euo pipefail

################################################################################
# Script Name: configure_pingfed.sh
# Description: Phase 2 — configure PingFederate.
#
#   Part A — Admin authentication via PingDirectory (LDAP):
#     Stock PF has no headless native-admin seed, so we point PF admin console +
#     admin API at PingDirectory. The PF admin is then the LDAP user 'pfadmin'
#     provisioned by configure_pingdir. Fully headless — no browser wizard.
#
#   Part B — Configuration via /pf-admin-api/v1 (as pfadmin):
#     - LDAP datastore -> PingDirectory
#     - OAuth persistent-grant storage -> PingDirectory (externalized, not memory)
#     - sample OAuth/OIDC client for PingAccess
#
#   Idempotent: property edits are re-applied deterministically; API objects use
#   check-then-create (pf_ensure).
################################################################################

source ./pingconfig.env
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "${_LIB_DIR}/logging.sh"
# shellcheck disable=SC1091
source "${_LIB_DIR}/rest_helpers.sh"

PF_BIN="${PINGFED_DIR}/bin"
LDAP_PROPS="${PF_BIN}/ldap.properties"
RUN_PROPS="${PF_BIN}/run.properties"
PF_PID_FILE="${PF_BIN}/pingfederate.pid"
PF_RUN_LOG="${LOG_DIR}/pingfederate-run.log"
# Externalized-storage wiring lives in on-disk config, not the admin API:
#   - service-points.conf selects the active grant/session storage manager
#   - config-store/*.xml supplies each manager's datastore id + search base
PF_DATA_CS="${PINGFED_DIR}/server/default/data/config-store"
# Config-store file backing com.pingidentity.page.Login: holds the license-map
# whose items gate the admin console's first-run experience (license agreement +
# the Connect-to-PingOne Initial Setup Wizard).
PF_LOGIN_CS="${PF_DATA_CS}/com.pingidentity.page.Login.xml"
PF_SERVICE_POINTS="${PINGFED_DIR}/server/default/conf/service-points.conf"
PF_GRANT_MGR="org.sourceid.oauth20.token.AccessGrantManagerLDAPPingDirectoryImpl"
PF_SESSION_MGR="org.sourceid.saml20.service.session.data.impl.SessionStorageManagerLdapImpl"

trap 'error "configure_pingfed.sh failed at line $LINENO"' ERR

# Set KEY=VALUE in a Java .properties file (replace existing or append).
function set_prop() {
    local f=$1 k=$2 v=$3
    local ve; ve=$(printf '%s' "$v" | sed 's/[&|]/\\&/g')
    if grep -qE "^${k}=" "$f"; then
        sed -i "s|^${k}=.*|${k}=${ve}|" "$f"
    else
        printf '%s=%s\n' "$k" "$v" >> "$f"
    fi
}

# Set the content of a PingFederate config-store <c:item name="NAME">…</c:item>.
# The stock elements ship empty (e.g. <c:item name="SearchBase"></c:item>); this
# fills or replaces the value, matching the single-line element form on disk.
function set_config_store_item() {
    local f=$1 name=$2 value=$3
    local ve; ve=$(printf '%s' "$value" | sed 's/[&|]/\\&/g')
    grep -qE "<c:item name=\"${name}\">" "$f" || { error "config-store item ${name} not found in ${f##*/}"; return 1; }
    sed -i -E "s|(<c:item name=\"${name}\">)[^<]*(</c:item>)|\1${ve}\2|" "$f"
}

# Select an active service-point implementation in service-points.conf.
function set_service_point() {
    local key=$1 value=$2
    sed -i -E "s|^${key}=.*|${key}=${value}|" "$PF_SERVICE_POINTS"
}

# -----------------------------------------------------------------------------
# Part A — LDAP admin authentication against PingDirectory
# -----------------------------------------------------------------------------
function configure_ldap_admin_auth() {
    # Skip if already switched to LDAP (idempotent restart avoidance)
    if grep -qE '^pf\.console\.authentication=LDAP' "$RUN_PROPS" && \
       grep -qE '^pf\.admin\.api\.authentication=LDAP' "$RUN_PROPS"; then
        info "PF already configured for LDAP admin auth — verifying login"
        pf_ready 6 3 && return 0
        warning "LDAP auth set but login failed — re-applying config"
    fi

    info "Configuring PingFederate admin authentication against PingDirectory..."

    # One-time backups
    [[ -f "${LDAP_PROPS}.orig" ]] || cp "$LDAP_PROPS" "${LDAP_PROPS}.orig"
    [[ -f "${RUN_PROPS}.orig" ]]  || cp "$RUN_PROPS"  "${RUN_PROPS}.orig"

    # Obfuscate the PD search-bind password (cn=Directory Manager)
    export JAVA_HOME="${JAVA_HOME:-}"
    local obf
    obf=$("${PF_BIN}/obfuscate.sh" "$PINGDIR_ROOT_PASSWORD" 2>/dev/null | grep -oE 'OBF:[^[:space:]]+' | head -1)
    [[ -n "$obf" ]] || { error "Failed to obfuscate LDAP bind password"; return 1; }

    # ldap.properties — connection + user search + direct role assignment
    set_prop "$LDAP_PROPS" "ldap.url"       "$PINGFED_ADMIN_LDAP_URL"
    set_prop "$LDAP_PROPS" "ldap.type"      "PingDirectory"
    set_prop "$LDAP_PROPS" "ldap.username"  "$PINGDIR_ROOT_DN"
    set_prop "$LDAP_PROPS" "ldap.password"  "$obf"
    set_prop "$LDAP_PROPS" "search.base"    "$PINGDIR_PEOPLE_DN"
    set_prop "$LDAP_PROPS" "search.filter"  "uid={0}"
    # Direct role assignment by username (simpler + more reliable than group search)
    set_prop "$LDAP_PROPS" "role.admin"               "$PINGFED_ADMIN_UID"
    set_prop "$LDAP_PROPS" "role.cryptoManager"       "$PINGFED_ADMIN_UID"
    set_prop "$LDAP_PROPS" "role.userAdmin"           "$PINGFED_ADMIN_UID"
    set_prop "$LDAP_PROPS" "role.expressionAdmin"     "$PINGFED_ADMIN_UID"
    set_prop "$LDAP_PROPS" "role.dataCollectionAdmin" "$PINGFED_ADMIN_UID"

    # run.properties — switch console + admin API to LDAP
    set_prop "$RUN_PROPS" "pf.console.authentication"   "LDAP"
    set_prop "$RUN_PROPS" "pf.admin.api.authentication" "LDAP"

    success "LDAP admin auth configured; restarting PingFederate to apply"
    restart_pingfed
    pf_ready 40 5 || { error "PF admin API not reachable as ${_PF_USER} after LDAP switch"; return 1; }
    success "PingFederate admin login via PingDirectory works (user: ${_PF_USER})"
    pf_accept_license
}

# Each PF admin must accept the license agreement before the API is usable.
function pf_accept_license() {
    local body; body=$(pf_request GET /license/agreement)
    if echo "$body" | grep -q '"accepted":true'; then
        info "PF license agreement already accepted"; return 0
    fi
    local url; url=$(echo "$body" | python3 -c "import sys,json;print(json.load(sys.stdin).get('licenseAgreementUrl',''))" 2>/dev/null)
    pf_request PUT /license/agreement "{\"licenseAgreementUrl\":\"${url}\",\"accepted\":true}" >/dev/null
    if [[ "$_PING_HTTP_CODE" == "200" ]]; then
        success "PF license agreement accepted"
    else
        error "Failed to accept PF license agreement (HTTP $_PING_HTTP_CODE)"; return 1
    fi
}

function restart_pingfed() {
    info "Stopping PingFederate..."
    if [[ -f "$PF_PID_FILE" ]]; then
        local pid; pid=$(cat "$PF_PID_FILE" 2>/dev/null || true)
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    fi
    pkill -f 'org.pingidentity.RunPF' 2>/dev/null || true
    # Wait for the JVM to actually exit, not just for the port to close. run.sh
    # refuses to start while the pid in pingfederate.pid is still alive, so a
    # port-only wait races the shutdown and the restart silently no-ops.
    local i=0
    while pgrep -f 'org.pingidentity.RunPF' >/dev/null 2>&1; do
        if [[ $i -ge 30 ]]; then
            warning "PingFederate did not stop gracefully — sending SIGKILL"
            pkill -9 -f 'org.pingidentity.RunPF' 2>/dev/null || true
            sleep 2; break
        fi
        sleep 2; i=$((i+1))
    done
    # Belt and braces: wait for the admin port to release as well.
    i=0
    while ss -ltn 2>/dev/null | grep -q ":${PINGFED_ADMIN_PORT} "; do
        [[ $i -ge 15 ]] && break
        sleep 2; i=$((i+1))
    done
    # Clear the stale pidfile so run.sh's own "already running" guard is clean.
    : > "$PF_PID_FILE" 2>/dev/null || true

    info "Starting PingFederate..."
    mkdir -p "$LOG_DIR"
    # Fully detach (new session) so the JVM survives this script's shell exiting.
    ( cd "$PINGFED_DIR" && setsid bash -c 'exec ./bin/run.sh' > "$PF_RUN_LOG" 2>&1 </dev/null & )
    # Wait for admin console port
    i=0
    while [[ $i -lt 40 ]]; do
        local code
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
               "https://${PINGFED_HOSTNAME}:${PINGFED_ADMIN_PORT}/pingfederate/app" 2>/dev/null || echo 000)
        [[ "$code" =~ ^(200|302|401)$ ]] && { success "PingFederate admin console back up"; return 0; }
        sleep 5; ((i++)) || true
    done
    error "PingFederate admin console did not return after restart (see $PF_RUN_LOG)"; return 1
}

# -----------------------------------------------------------------------------
# Suppress PingFederate's first-run "Connect to PingOne" Initial Setup Wizard.
#
# On a fresh install the admin console forces this wizard until setup is marked
# complete — LDAP admin auth does NOT bypass it. There is no admin-API endpoint
# for this; the console's own setInitialSetupDone() writes a single config-store
# value: item "initial-setup-done"=true INSIDE the "license-map" map of the
# com.pingidentity.page.Login store (verified by disassembling
# InitialSetupConfigStore in pf-protocolengine.jar). We write the same value so
# a restarted console treats setup as done and goes straight to Sign On.
# Idempotent: a no-op once the item is present. Caller restarts PF to load it.
# -----------------------------------------------------------------------------
function complete_initial_setup() {
    local f="$PF_LOGIN_CS"
    if [[ -f "$f" ]] && grep -q 'name="initial-setup-done"' "$f"; then
        info "PF Initial Setup Wizard already marked complete — skipping"
        return 0
    fi
    info "Suppressing PingFederate Connect-to-PingOne Initial Setup Wizard..."

    if [[ ! -f "$f" ]]; then
        # pf_accept_license normally creates this file; recreate it if absent.
        cat > "$f" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<con:config xmlns:con="http://www.sourceid.org/2004/05/config">
    <con:map name="license-map">
        <con:item name="initial-setup-done">true</con:item>
    </con:map>
</con:config>
XML
    else
        [[ -f "${f}.orig" ]] || cp "$f" "${f}.orig"
        # Match the namespace prefix PF actually wrote (con: or c:) so the added
        # element stays in a declared namespace.
        local pfx; pfx=$(grep -oE '</[A-Za-z0-9]+:map>' "$f" | head -1 | sed -E 's#</([A-Za-z0-9]+):map>#\1#')
        pfx="${pfx:-con}"
        local item="        <${pfx}:item name=\"initial-setup-done\">true</${pfx}:item>"
        if grep -qE "<${pfx}:map name=\"license-map\">" "$f"; then
            # Insert the item just before the license-map's closing tag.
            awk -v line="$item" -v endtag="</${pfx}:map>" \
                'index($0,endtag) && !d { print line; d=1 } { print }' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
        else
            # No license-map yet: add the whole map before the config close.
            awk -v item="$item" -v pfx="$pfx" -v endtag="</${pfx}:config>" \
                'index($0,endtag) && !d { printf "    <%s:map name=\"license-map\">\n%s\n    </%s:map>\n", pfx, item, pfx; d=1 } { print }' \
                "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
        fi
    fi

    success "initial-setup-done=true written to ${f##*/}; restarting PF to apply"
    restart_pingfed
    pf_ready 40 5 || { error "PF admin API not ready after setup-wizard suppression"; return 1; }
    success "Initial Setup Wizard suppressed — console lands on Sign On"
}

# -----------------------------------------------------------------------------
# Part B — API configuration (placeholder; implemented after Part A verified)
# -----------------------------------------------------------------------------
function configure_pf_api() {
    info "PingFederate API configuration..."
    ensure_pd_datastore
    activate_externalized_storage
    complete_initial_setup
}

# -----------------------------------------------------------------------------
# LDAP datastore -> PingDirectory.
#
# Binds as the cn=pingfederate service account (LDAP_BIND_DN), NOT the PD root
# (cn=Directory Manager) — customer-realistic least privilege. configure_pingdir
# provisions this account and grants it exactly what PF needs via ACIs: read on
# ou=people (user authentication + attribute lookup) and read/write on the
# ou=AccessGrant + ou=AuthenticationSessions containers (externalized storage).
#
# Idempotent: creates the datastore if absent; if an earlier run created it under
# a different bind DN (e.g. the PD root), reconciles it to the service account by
# merging the new bind into the datastore's current representation and PUTting it
# back (preserving every other field PF set).
# -----------------------------------------------------------------------------
function ensure_pd_datastore() {
    local ds_payload
    ds_payload=$(cat <<JSON
{
  "type": "LDAP",
  "id": "${PINGFED_PD_DATASTORE_ID}",
  "name": "PingDirectory",
  "ldapType": "PING_DIRECTORY",
  "hostnames": ["${PINGDIR_HOSTNAME}:${PINGDIR_LDAP_PORT}"],
  "userDN": "${LDAP_BIND_DN}",
  "password": "${LDAP_BIND_PASSWORD}",
  "useSsl": false,
  "useStartTLS": false
}
JSON
)
    # Redirect to a file (not $( )) so pf_request runs in THIS shell and its
    # _PING_HTTP_CODE is accurate — a command substitution here would leave a
    # stale 200 from the prior call and send a not-found datastore down the
    # "merge existing" path, PUTting an error body with no type discriminator.
    local body gtmp; gtmp=$(mktemp)
    pf_request GET "/dataStores/${PINGFED_PD_DATASTORE_ID}" > "$gtmp" 2>/dev/null
    body=$(cat "$gtmp"); rm -f "$gtmp"
    if [[ "$_PING_HTTP_CODE" != "200" ]]; then
        pf_ensure "/dataStores/${PINGFED_PD_DATASTORE_ID}" POST "/dataStores" "$ds_payload" \
            "LDAP datastore -> PingDirectory (bind ${LDAP_BIND_DN})"
        return $?
    fi

    # Datastore exists — reconcile its bind DN to the service account.
    local cur_dn
    cur_dn=$(echo "$body" | python3 -c "import sys,json;print(json.load(sys.stdin).get('userDN',''))" 2>/dev/null || true)
    if [[ "$cur_dn" == "$LDAP_BIND_DN" ]]; then
        info "  LDAP datastore already binds as ${LDAP_BIND_DN} — skipping"
        return 0
    fi
    info "  Reconciling LDAP datastore bind '${cur_dn:-<unknown>}' -> '${LDAP_BIND_DN}'"

    # Merge the new bind into the datastore's current representation so no other
    # PF-managed field is lost on the round-trip (GET never returns the password).
    local merged tmp; tmp=$(mktemp)
    merged=$(echo "$body" | NEW_DN="$LDAP_BIND_DN" NEW_PW="$LDAP_BIND_PASSWORD" python3 -c "
import sys, json, os
d = json.load(sys.stdin)
d['userDN'] = os.environ['NEW_DN']
d['password'] = os.environ['NEW_PW']
json.dump(d, sys.stdout)
" 2>/dev/null)
    [[ -n "$merged" ]] || { error "  Failed to build datastore update payload"; rm -f "$tmp"; return 1; }

    pf_request PUT "/dataStores/${PINGFED_PD_DATASTORE_ID}" "$merged" > "$tmp" 2>/dev/null
    if [[ "$_PING_HTTP_CODE" =~ ^20 ]]; then
        success "  LDAP datastore bind updated to service account (HTTP $_PING_HTTP_CODE)"; rm -f "$tmp"; return 0
    fi
    error "  LDAP datastore bind update failed (HTTP $_PING_HTTP_CODE): $(head -c 300 "$tmp")"; rm -f "$tmp"; return 1
}

# -----------------------------------------------------------------------------
# Externalize OAuth persistent grants + authentication sessions to PingDirectory.
#
# PingFederate does NOT expose this over the admin API (verified against PF 13.1
# docs): the active storage manager is chosen in server/default/conf/
# service-points.conf, and each LDAP manager reads its datastore id + search base
# from a config-store XML. The PingDirectory schema, containers and ACIs are
# already provisioned by configure_pingdir. We set both managers to their
# PingDirectory LDAP implementation, point them at the pingdirectory-ldap
# datastore + the grant/session containers, then restart PF to load them.
# Idempotent: re-running detects the managers are already active and no-ops.
# -----------------------------------------------------------------------------
function activate_externalized_storage() {
    local grant_xml="${PF_DATA_CS}/${PF_GRANT_MGR}.xml"
    local sess_xml="${PF_DATA_CS}/${PF_SESSION_MGR}.xml"
    for f in "$grant_xml" "$sess_xml" "$PF_SERVICE_POINTS"; do
        [[ -f "$f" ]] || { error "Expected PF config file missing: $f"; return 1; }
    done

    if grep -qE "^access\.grant\.manager=${PF_GRANT_MGR//./\\.}$" "$PF_SERVICE_POINTS" && \
       grep -qE "^session\.storage\.manager=${PF_SESSION_MGR//./\\.}$" "$PF_SERVICE_POINTS"; then
        success "Grant + session storage already externalized to PingDirectory — skipping"
        return 0
    fi

    info "Externalizing OAuth grants + authentication sessions to PingDirectory..."
    # One-time backups of the stock (JDBC-default) config
    for f in "$grant_xml" "$sess_xml" "$PF_SERVICE_POINTS"; do
        [[ -f "${f}.orig" ]] || cp "$f" "${f}.orig"
    done

    # Point each LDAP manager at the PD datastore + its container
    set_config_store_item "$grant_xml" PingFederateDSJNDIName "$PINGFED_PD_DATASTORE_ID"
    set_config_store_item "$grant_xml" SearchBase             "$PINGFED_GRANTS_BASE_DN"
    set_config_store_item "$sess_xml"  PingFederateDSJNDIName "$PINGFED_PD_DATASTORE_ID"
    set_config_store_item "$sess_xml"  SearchBase             "$PINGFED_SESSIONS_BASE_DN"

    # Activate the LDAP PingDirectory managers (replace the JDBC defaults)
    set_service_point access.grant.manager   "$PF_GRANT_MGR"
    set_service_point session.storage.manager "$PF_SESSION_MGR"

    success "Config-store + service-points updated; restarting PingFederate to load LDAP managers"
    restart_pingfed
    pf_ready 40 5 || { error "PF admin API not ready after storage externalization"; return 1; }

    # Confirm PF initialised the LDAP managers without error at startup
    if grep -iE 'AccessGrantManagerLDAPPingDirectoryImpl|SessionStorageManagerLdapImpl' \
          "${PINGFED_DIR}/log/server.log" 2>/dev/null | grep -qiE 'error|exception|fail'; then
        warning "  Storage-manager errors present in server.log — review before relying on externalization"
    fi
    success "OAuth grants -> ${PINGFED_GRANTS_BASE_DN}; sessions -> ${PINGFED_SESSIONS_BASE_DN} (datastore ${PINGFED_PD_DATASTORE_ID})"
}

# -----------------------------------------------------------------------------
section "PingFederate — Phase 2 configuration"
configure_ldap_admin_auth
configure_pf_api
success "PingFederate configuration complete"
