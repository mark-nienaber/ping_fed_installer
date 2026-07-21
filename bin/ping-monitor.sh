#!/usr/bin/env bash
# =============================================================================
# bin/ping-monitor.sh — Operational status dashboard for the Ping stack.
#
#   A read-only, at-a-glance view of the whole system:
#     - component up/down + health (both PD nodes, PF console+engine, PA, app, LB)
#     - PingDirectory replication status (entries / backlog / in-sync)
#     - PingFederate cluster status (node roles + config replication)
#     - PF -> PD link security (LDAPS + failover hostnames)
#     - load-balancer backend routing
#     - resource snapshot (memory, per-JVM RSS)
#
# Usage:
#   ./bin/ping-monitor.sh              one-shot snapshot
#   ./bin/ping-monitor.sh --watch [N]  refresh every N seconds (default 5)
# =============================================================================
set -uo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_ROOT}/lib/logging.sh"
cd "$SCRIPT_ROOT"
# shellcheck source=/dev/null
source "${SCRIPT_ROOT}/pingconfig.env"

CLUSTERED_PD=$([[ "${PINGDIR_COUNT:-1}" -gt 1 ]] && echo 1 || echo 0)
CLUSTERED_PF=$([[ "${PINGFED_COUNT:-1}" -gt 1 ]] && echo 1 || echo 0)
LB_ON=$([[ "${LB_ENABLED:-false}" == "true" ]] && echo 1 || echo 0)
PF_A=(-u "${PINGFED_ADMIN_UID}:${DEFAULT_PASSWORD}" -H "X-XSRF-Header: PingFederate" -H "Accept: application/json")
PFADMIN="https://${PINGFED_HOSTNAME}:${PINGFED_ADMIN_PORT}/pf-admin-api/v1"
[[ "$LB_ON" == "1" ]] && RT_URL="$LB_PF_BASE_URL" || RT_URL="$PINGFED_BASE_URL"
[[ "$LB_ON" == "1" ]] && APP_URL="$LB_APP_BASE_URL" || APP_URL="https://${SAMPLE_APP_VIRTUAL_HOST}:${PINGACCESS_ENGINE_PORT}"

_listening() { ss -ltn 2>/dev/null | grep -q ":${1} "; }
_code() { curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || echo 000; }
UP="\033[32m● UP  \033[0m"; DOWN="\033[31m● DOWN\033[0m"
_row() { printf '  %-18s %b  %s\n' "$1" "$2" "$3"; }

snapshot() {
    banner "Ping stack monitor   $(TZ= date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo)"

    section "Components"
    _listening "$PINGDIR_LDAPS_PORT"  && _row "PingDirectory-1" "$UP"   "LDAP ${PINGDIR_LDAP_PORT} / LDAPS ${PINGDIR_LDAPS_PORT}" || _row "PingDirectory-1" "$DOWN" ""
    if [[ "$CLUSTERED_PD" == "1" ]]; then
        _listening "$PINGDIR2_LDAPS_PORT" && _row "PingDirectory-2" "$UP" "LDAP ${PINGDIR2_LDAP_PORT} / LDAPS ${PINGDIR2_LDAPS_PORT}" || _row "PingDirectory-2" "$DOWN" ""
    fi
    _listening "$PINGFED_ADMIN_PORT" && _row "PingFederate-1" "$UP" "$([[ $CLUSTERED_PF == 1 ]] && echo CONSOLE) admin ${PINGFED_ADMIN_PORT}" || _row "PingFederate-1" "$DOWN" ""
    if [[ "$CLUSTERED_PF" == "1" ]]; then
        local hb; hb=$(_code "https://${PINGFED_HOSTNAME}:${PINGFED2_ENGINE_PORT}/pf/heartbeat.ping")
        _listening "$PINGFED2_ENGINE_PORT" && _row "PingFederate-2" "$UP" "ENGINE ${PINGFED2_ENGINE_PORT} heartbeat ${hb}" || _row "PingFederate-2" "$DOWN" ""
    fi
    _listening "$PINGACCESS_ADMIN_PORT" && _row "PingAccess" "$UP" "admin ${PINGACCESS_ADMIN_PORT} / engine ${PINGACCESS_ENGINE_PORT}" || _row "PingAccess" "$DOWN" ""
    local ap="${SAMPLE_APP_TARGET##*:}"; ap="${ap%%/*}"
    _listening "$ap" && _row "Sample app" "$UP" "origin :${ap}" || _row "Sample app" "$DOWN" ""
    if [[ "$LB_ON" == "1" ]]; then
        _listening "$LB_HTTPS_PORT" && _row "Load Balancer" "$UP" "HAProxy :${LB_HTTPS_PORT} (TLS)" || _row "Load Balancer" "$DOWN" ""
    fi

    if [[ "$CLUSTERED_PD" == "1" ]]; then
        section "PingDirectory replication"
        if _listening "$PINGDIR_LDAPS_PORT"; then
            local pw; pw=$(mktemp); chmod 600 "$pw"; printf '%s' "$PINGDIR_ROOT_PASSWORD" > "$pw"
            "${PINGDIR_DIR}/bin/dsreplication" status --hostname localhost --port "$PINGDIR_LDAPS_PORT" --useSSL --trustAll \
                --adminUID "$PINGDIR_REPL_ADMIN_UID" --adminPasswordFile "$pw" --no-prompt 2>/dev/null \
                | grep -viE 'tput:' | grep -E 'Server|pingdirectory-|:-' | sed 's/^/  /' | head -8
            rm -f "$pw"
        else
            printf '  (node 1 down — status unavailable)\n'
        fi
    fi

    if [[ "$CLUSTERED_PF" == "1" ]]; then
        section "PingFederate cluster"
        curl -sk "${PF_A[@]}" "$PFADMIN/cluster/status" 2>/dev/null | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except: print('  (console unavailable)'); sys.exit()
for n in d.get('nodes',[]):
    print('  node %s  %-18s %-22s repl=%s' % (n.get('index'), n.get('mode'), n.get('address'), n.get('replicationStatus')))
print('  replicationRequired:', d.get('replicationRequired'))
" 2>/dev/null || printf '  (console unavailable)\n'
    fi

    section "PingFederate -> PingDirectory link"
    local ds; ds=$(curl -sk "${PF_A[@]}" "$PFADMIN/dataStores/${PINGFED_PD_DATASTORE_ID}" 2>/dev/null)
    echo "$ds" | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except: print('  (unavailable)'); sys.exit()
print('  datastore: %s  useSsl=%s  hosts=%s' % (d.get('ldapType'), d.get('useSsl'), d.get('hostnames')))
" 2>/dev/null || printf '  (unavailable)\n'
    if grep -q '^ldap.url=ldaps://' "${PINGFED_DIR}/bin/ldap.properties" 2>/dev/null; then
        printf '  admin-auth: LDAPS  %s\n' "$(grep '^ldap.url=' "${PINGFED_DIR}/bin/ldap.properties" | cut -d= -f2-)"
    else
        printf '  admin-auth: %s\n' "$(grep '^ldap.url=' "${PINGFED_DIR}/bin/ldap.properties" 2>/dev/null | cut -d= -f2-)"
    fi

    if [[ "$LB_ON" == "1" ]]; then
        section "Load balancer routing"
        _row "LB -> PF engine" "$([[ $(_code "${RT_URL}/pf/heartbeat.ping") == 200 ]] && echo "$UP" || echo "$DOWN")" "${RT_URL}/pf/heartbeat.ping"
        local ac; ac=$(_code "${APP_URL}/")
        _row "LB -> PA app" "$([[ "$ac" =~ ^(200|302|401|403)$ ]] && echo "$UP" || echo "$DOWN")" "${APP_URL}/ (HTTP ${ac})"
    fi

    section "Resources"
    free -h 2>/dev/null | awk 'NR==1||/Mem|Swap/{print "  "$0}'
    printf '  per-JVM RSS:\n'
    local specs=( "PD-1:${PINGDIR_DIR}/config/config.ldif" )
    [[ "$CLUSTERED_PD" == "1" ]] && specs+=( "PD-2:${PINGDIR2_DIR}/config/config.ldif" )
    specs+=( "PF-1:pf.home=${PINGFED_DIR} " )
    [[ "$CLUSTERED_PF" == "1" ]] && specs+=( "PF-2:pf.home=${PINGFED2_DIR} " )
    specs+=( "PA  :com.pingidentity.pa.cli.Starter" )
    local spec label pat pid rss
    for spec in "${specs[@]}"; do
        label=${spec%%:*}; pat=${spec#*:}
        pid=$(pgrep -f "$pat" 2>/dev/null | grep -vw "$$" | head -1)
        if [[ -n "$pid" ]]; then
            rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
            printf '    %-5s %6.0f MB  (pid %s)\n' "$label" "$(( ${rss:-0} / 1024 ))" "$pid"
        else
            printf '    %-5s   --  (not running)\n' "$label"
        fi
    done
    printf '\n'
}

INTERVAL=0
if [[ "${1:-}" == "--watch" ]]; then INTERVAL="${2:-5}"; fi

if [[ "$INTERVAL" -gt 0 ]]; then
    trap 'exit 0' INT
    while true; do clear; snapshot; printf '  (refresh %ss — Ctrl-C to exit)\n' "$INTERVAL"; sleep "$INTERVAL"; done
else
    snapshot
fi
