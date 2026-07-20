#!/usr/bin/env bash
# =============================================================================
# lib/rest_helpers.sh — Admin REST API helpers for PingFederate + PingAccess
#
# Both products use HTTPS + HTTP Basic auth + a required anti-CSRF header
# (X-XSRF-Header). These helpers wrap curl, expose the HTTP status via the
# global _PING_HTTP_CODE, and print the response body to stdout so callers can
# implement idempotent create-or-skip logic.
#
# Requires: curl, pingconfig.env sourced first.
# =============================================================================
[[ -n "${_PING_REST_LOADED:-}" ]] && return 0
_PING_REST_LOADED=1

# Populated by _ping_request on every call
_PING_HTTP_CODE="000"

# -----------------------------------------------------------------------------
# _ping_request BASE USER PASS XSRF METHOD PATH [DATA]
#   Performs the call; echoes body to stdout; sets _PING_HTTP_CODE.
#   PATH is appended to BASE. DATA (optional) is sent as JSON.
# -----------------------------------------------------------------------------
function _ping_request() {
    local base=$1 user=$2 pass=$3 xsrf=$4 method=$5 path=$6 data="${7:-}"
    local tmp; tmp=$(mktemp)
    local code
    if [[ -n "$data" ]]; then
        code=$(curl -sk -o "$tmp" -w '%{http_code}' -X "$method" \
            -u "${user}:${pass}" \
            -H "X-XSRF-Header: ${xsrf}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            --max-time 30 -d "$data" "${base}${path}" 2>/dev/null) || code="000"
    else
        code=$(curl -sk -o "$tmp" -w '%{http_code}' -X "$method" \
            -u "${user}:${pass}" \
            -H "X-XSRF-Header: ${xsrf}" \
            -H "Accept: application/json" \
            --max-time 30 "${base}${path}" 2>/dev/null) || code="000"
    fi
    _PING_HTTP_CODE="$code"
    cat "$tmp"; rm -f "$tmp"
}

# -----------------------------------------------------------------------------
# PingFederate — basic auth as the LDAP admin (pfadmin), XSRF "PingFederate"
# -----------------------------------------------------------------------------
: "${_PF_USER:=${PINGFED_ADMIN_UID:-pfadmin}}"
: "${_PF_PASS:=${PINGFED_ADMIN_PASSWORD:-}}"

function pf_request() {  # METHOD PATH [DATA]
    _ping_request "$PINGFED_ADMIN_API" "$_PF_USER" "$_PF_PASS" "PingFederate" "$@"
}

function pf_ready() {    # [max_attempts] [sleep]
    local max=${1:-40} nap=${2:-5} i=0
    info "Waiting for PingFederate admin API (auth as ${_PF_USER})..."
    while [[ $i -lt $max ]]; do
        pf_request GET /version >/dev/null 2>&1
        [[ "$_PING_HTTP_CODE" == "200" ]] && { success "PingFederate admin API ready"; return 0; }
        ((i++)); sleep "$nap"
    done
    error "PingFederate admin API not ready (last HTTP $_PING_HTTP_CODE)"; return 1
}

# Idempotent create: if GET exists_path is 200, skip; else PUT/POST create_path.
# pf_put_idempotent EXISTS_PATH CREATE_METHOD CREATE_PATH DATA LABEL
function pf_ensure() {
    local exists=$1 method=$2 path=$3 data=$4 label=$5
    pf_request GET "$exists" >/dev/null 2>&1
    if [[ "$_PING_HTTP_CODE" == "200" ]]; then
        info "  $label already exists — skipping"
        return 0
    fi
    # Plain redirect (NOT $(...)) so _PING_HTTP_CODE updates in THIS shell.
    local tmp; tmp=$(mktemp)
    pf_request "$method" "$path" "$data" > "$tmp" 2>/dev/null
    if [[ "$_PING_HTTP_CODE" =~ ^20 ]]; then
        success "  $label created (HTTP $_PING_HTTP_CODE)"; rm -f "$tmp"; return 0
    fi
    error "  $label failed (HTTP $_PING_HTTP_CODE): $(head -c 300 "$tmp")"; rm -f "$tmp"; return 1
}

# -----------------------------------------------------------------------------
# PingAccess — basic auth as administrator, XSRF "PingAccess"
# Password rotates during config, so read from _PA_USER/_PA_PASS (defaults to
# the stock 2Access until configure_pingaccess changes it).
# -----------------------------------------------------------------------------
: "${_PA_USER:=${PINGACCESS_ADMIN_USER:-administrator}}"
: "${_PA_PASS:=2Access}"

function pa_request() {  # METHOD PATH [DATA]
    _ping_request "$PINGACCESS_ADMIN_API" "$_PA_USER" "$_PA_PASS" "PingAccess" "$@"
}

function pa_ready() {    # [max_attempts] [sleep]
    local max=${1:-40} nap=${2:-5} i=0
    info "Waiting for PingAccess admin API..."
    while [[ $i -lt $max ]]; do
        pa_request GET /version >/dev/null 2>&1
        [[ "$_PING_HTTP_CODE" == "200" ]] && { success "PingAccess admin API ready"; return 0; }
        ((i++)); sleep "$nap"
    done
    error "PingAccess admin API not ready (last HTTP $_PING_HTTP_CODE)"; return 1
}

# pa_ensure EXISTS_PATH METHOD CREATE_PATH DATA LABEL  (same contract as pf_ensure)
function pa_ensure() {
    local exists=$1 method=$2 path=$3 data=$4 label=$5
    pa_request GET "$exists" >/dev/null 2>&1
    if [[ "$_PING_HTTP_CODE" == "200" ]]; then
        info "  $label already exists — skipping"
        return 0
    fi
    local tmp; tmp=$(mktemp)
    pa_request "$method" "$path" "$data" > "$tmp" 2>/dev/null
    if [[ "$_PING_HTTP_CODE" =~ ^20 ]]; then
        success "  $label created (HTTP $_PING_HTTP_CODE)"; rm -f "$tmp"; return 0
    fi
    error "  $label failed (HTTP $_PING_HTTP_CODE): $(head -c 300 "$tmp")"; rm -f "$tmp"; return 1
}
