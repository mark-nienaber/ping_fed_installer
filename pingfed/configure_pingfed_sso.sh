#!/bin/bash
set -euo pipefail

################################################################################
# Script Name: configure_pingfed_sso.sh
# Description: Phase 2 (Part C) — build the PingFederate OAuth/OIDC + browser-SSO
#              machinery that PingAccess federates against.
#
#   Chain created (all idempotent, check-then-create via pf_ensure):
#     1. LDAP Password Credential Validator  -> validates end-user creds in PD
#     2. HTML Form IdP Adapter                -> login page, uses the PCV
#     3. IdP Adapter Grant Mapping            -> adapter -> OAuth persistent grant
#     4. Reference Access Token Manager       -> opaque bearer access tokens
#     5. Access Token Mapping (DEFAULT)       -> persistent-grant -> token attrs
#     6. OpenID Connect Policy (+ default)    -> issues ID tokens (sub)
#     7. Runtime base URL                     -> real hostname, so the OIDC
#                                                issuer isn't https://localhost
#     8. OAuth client "pingaccess-client"     -> authorization_code + redirect
#                                                URIs to PingAccess /pa/oidc/cb
#
#   Field names / type ids / enum constants below were verified live against
#   PingFederate 13.1's admin API (plugin ids must be alphanumeric <33 chars;
#   persistent-grant source constant is OAUTH_PERSISTENT_GRANT).
################################################################################

source ./pingconfig.env
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "${_LIB_DIR}/logging.sh"
# shellcheck disable=SC1091
source "${_LIB_DIR}/rest_helpers.sh"

trap 'error "configure_pingfed_sso.sh failed at line $LINENO"' ERR

# Stable object ids (alphanumeric — PF rejects hyphens in plugin ids)
PCV_ID="pdldappcv"
ADAPTER_ID="htmlform"
ATM_ID="referenceatm"
OIDC_POLICY_ID="oidcpolicy"
ATM_MAPPING_ID="default|${ATM_ID}"       # DEFAULT-context access-token mapping id

# -----------------------------------------------------------------------------
section "PingFederate — Phase 2 Part C: OAuth/OIDC + SSO"
pf_ready 12 5 || { error "PF admin API not reachable"; return 1 2>/dev/null || exit 1; }

# 1. LDAP Password Credential Validator -> PingDirectory (ou=people, uid={user})
pf_ensure "/passwordCredentialValidators/${PCV_ID}" POST "/passwordCredentialValidators" "$(cat <<JSON
{
  "id": "${PCV_ID}", "name": "PD LDAP PCV",
  "pluginDescriptorRef": {"id": "org.sourceid.saml20.domain.LDAPUsernamePasswordCredentialValidator"},
  "configuration": {"fields": [
      {"name": "LDAP Datastore", "value": "${PINGFED_PD_DATASTORE_ID}"},
      {"name": "Search Base", "value": "${PINGDIR_PEOPLE_DN}"},
      {"name": "Search Filter", "value": "uid=\${username}"},
      {"name": "Scope of Search", "value": "Subtree"} ]}
}
JSON
)" "LDAP PCV -> PingDirectory"

# 2. HTML Form IdP Adapter (references the PCV; username is the pseudonym)
pf_ensure "/idp/adapters/${ADAPTER_ID}" POST "/idp/adapters" "$(cat <<JSON
{
  "id": "${ADAPTER_ID}", "name": "HTML Form Adapter",
  "pluginDescriptorRef": {"id": "com.pingidentity.adapters.htmlform.idp.HtmlFormIdpAuthnAdapter"},
  "configuration": {
    "tables": [ {"name": "Credential Validators", "rows": [
        {"fields": [{"name": "Password Credential Validator Instance", "value": "${PCV_ID}"}]} ]} ],
    "fields": [ {"name": "Challenge Retries", "value": "3"},
      {"name": "Login Template", "value": "html.form.login.template.html"} ]
  },
  "attributeContract": {
    "coreAttributes": [{"name": "policy.action"}, {"name": "username", "pseudonym": true}],
    "maskOgnlValues": false
  }
}
JSON
)" "HTML Form IdP adapter"

# 3. IdP Adapter Grant Mapping — adapter identity -> OAuth persistent grant
pf_ensure "/oauth/idpAdapterMappings/${ADAPTER_ID}" POST "/oauth/idpAdapterMappings" "$(cat <<JSON
{
  "id": "${ADAPTER_ID}",
  "idpAdapterRef": {"id": "${ADAPTER_ID}"},
  "attributeContractFulfillment": {
    "USER_KEY":  {"source": {"type": "ADAPTER"}, "value": "username"},
    "USER_NAME": {"source": {"type": "ADAPTER"}, "value": "username"}
  }
}
JSON
)" "IdP adapter grant mapping"

# 4. Reference (opaque) Access Token Manager
pf_ensure "/oauth/accessTokenManagers/${ATM_ID}" POST "/oauth/accessTokenManagers" "$(cat <<JSON
{
  "id": "${ATM_ID}", "name": "Reference ATM",
  "pluginDescriptorRef": {"id": "org.sourceid.oauth20.token.plugin.impl.ReferenceBearerAccessTokenManagementPlugin"},
  "configuration": {"fields": [ {"name": "Token Length", "value": "28"}, {"name": "Token Lifetime", "value": "120"} ]},
  "attributeContract": {"extendedAttributes": [{"name": "subject"}, {"name": "username"}]}
}
JSON
)" "Reference Access Token Manager"

# 5. Access Token Mapping (DEFAULT/persistent-grant context) -> ATM attributes
#    NOTE: the persistent-grant source constant is OAUTH_PERSISTENT_GRANT and its
#    only default core attribute is USER_KEY.
pf_ensure "/oauth/accessTokenMappings/default%7C${ATM_ID}" POST "/oauth/accessTokenMappings" "$(cat <<JSON
{
  "id": "${ATM_MAPPING_ID}",
  "accessTokenManagerRef": {"id": "${ATM_ID}"},
  "context": {"type": "DEFAULT"},
  "attributeContractFulfillment": {
    "subject":  {"source": {"type": "OAUTH_PERSISTENT_GRANT"}, "value": "USER_KEY"},
    "username": {"source": {"type": "OAUTH_PERSISTENT_GRANT"}, "value": "USER_KEY"}
  }
}
JSON
)" "Access token mapping (DEFAULT)"

# 6. OpenID Connect Policy (issues ID tokens; sub <- access-token subject)
pf_ensure "/oauth/openIdConnect/policies/${OIDC_POLICY_ID}" POST "/oauth/openIdConnect/policies" "$(cat <<JSON
{
  "id": "${OIDC_POLICY_ID}", "name": "OIDC Policy",
  "accessTokenManagerRef": {"id": "${ATM_ID}"},
  "attributeContract": {"coreAttributes": [{"name": "sub"}], "extendedAttributes": []},
  "attributeMapping": {"attributeContractFulfillment": {
      "sub": {"source": {"type": "TOKEN"}, "value": "subject"} }}
}
JSON
)" "OpenID Connect policy"

# Make it the default OIDC policy (PUT is inherently idempotent)
pf_request PUT "/oauth/openIdConnect/settings" "{\"defaultPolicyRef\": {\"id\": \"${OIDC_POLICY_ID}\"}}" >/dev/null 2>&1
[[ "$_PING_HTTP_CODE" == "200" ]] && success "  Default OIDC policy set" || warning "  Default OIDC policy PUT -> HTTP $_PING_HTTP_CODE"

# 7. Runtime base URL so the OIDC issuer is the real hostname, not localhost
info "Setting runtime base URL (OIDC issuer) to https://${PINGFED_HOSTNAME}:${PINGFED_ENGINE_PORT}"
_ss=$(pf_request GET /serverSettings)
_ss_new=$(printf '%s' "$_ss" | python3 -c "import sys,json;d=json.load(sys.stdin);d.setdefault('federationInfo',{})['baseUrl']='https://${PINGFED_HOSTNAME}:${PINGFED_ENGINE_PORT}';print(json.dumps(d))")
pf_request PUT /serverSettings "$_ss_new" >/dev/null 2>&1
[[ "$_PING_HTTP_CODE" == "200" ]] && success "  Base URL updated" || warning "  serverSettings PUT -> HTTP $_PING_HTTP_CODE"

# 8. OAuth client for PingAccess (authorization_code; redirect to /pa/oidc/cb)
pf_ensure "/oauth/clients/${PINGFED_OIDC_CLIENT_ID}" POST "/oauth/clients" "$(cat <<JSON
{
  "clientId": "${PINGFED_OIDC_CLIENT_ID}", "name": "PingAccess Client", "enabled": true,
  "grantTypes": ["AUTHORIZATION_CODE"],
  "redirectUris": [
    "https://${SAMPLE_APP_VIRTUAL_HOST}:${PINGACCESS_ENGINE_PORT}/pa/oidc/cb",
    "https://${SAMPLE_APP_VIRTUAL_HOST}/pa/oidc/cb",
    "https://${PINGACCESS_HOSTNAME}:${PINGACCESS_ENGINE_PORT}/pa/oidc/cb",
    "https://localhost:${PINGACCESS_ENGINE_PORT}/pa/oidc/cb"
  ],
  "clientAuth": {"type": "SECRET", "secret": "${PINGFED_OIDC_CLIENT_SECRET}"},
  "defaultAccessTokenManagerRef": {"id": "${ATM_ID}"},
  "oidcPolicy": {"idTokenSigningAlgorithm": "RS256"},
  "bypassApprovalPage": true
}
JSON
)" "OAuth client (${PINGFED_OIDC_CLIENT_ID})"

# 9. Enable + persist authentication sessions. This is REQUIRED for the LDAP
#    session-storage manager to actually write sessions to PingDirectory — the
#    global policy ships disabled (enableSessions=false), so without this the
#    externalized session store stays empty even though the manager is active.
pf_request PUT "/session/authenticationSessionPolicies/global" \
  '{"enableSessions": true, "persistentSessions": true, "hashUniqueUserKeyAttribute": false, "idleTimeoutMins": 60, "maxTimeoutMins": 480}' >/dev/null 2>&1
[[ "$_PING_HTTP_CODE" == "200" ]] \
    && success "  Authentication sessions enabled + persisted to PingDirectory" \
    || warning "  Auth-session policy PUT -> HTTP $_PING_HTTP_CODE"

success "PingFederate OAuth/OIDC + SSO configuration complete"
