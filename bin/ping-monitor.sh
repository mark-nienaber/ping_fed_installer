#!/usr/bin/env bash
# =============================================================================
# bin/ping-monitor.sh — Operational status monitor for the Ping stack.
#
#   Read-only. Three ways to run it:
#
#     snapshot   one pass, then exit                     (default)
#     --watch    stays up, refreshing the panels you ask for
#     --tail     follows the log files you ask for, labelled and interleaved
#
#   Panels can be selected, so "watch replication" or "watch cluster" is a
#   focused screen rather than the whole stack scrolling past.
#
# Usage:
#   ./bin/ping-monitor.sh                            snapshot, every panel
#   ./bin/ping-monitor.sh cluster replication        snapshot, just those panels
#   ./bin/ping-monitor.sh --watch                    live, every panel, 5s
#   ./bin/ping-monitor.sh --watch 2 replication      live, one panel, 2s
#   ./bin/ping-monitor.sh --tail sso                 follow a login across PA/PF/PD
#   ./bin/ping-monitor.sh --tail pf pd -n 100        follow chosen logs
#   ./bin/ping-monitor.sh --tail pd-access --raw     ... without the noise filter
#   ./bin/ping-monitor.sh --list                     panels and log sources
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

ALL_PANELS=(components replication cluster link lb resources)
ALL_SOURCES=(pf pf-audit pf2 pd pd-access pd2 pa pa-audit dash install)

_listening() { ss -ltn 2>/dev/null | grep -q ":${1} "; }
_code() { curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || echo 000; }
UP="\033[32m● UP  \033[0m"; DOWN="\033[31m● DOWN\033[0m"
_row() { printf '  %-18s %b  %s\n' "$1" "$2" "$3"; }
# A verdict line: the panel's own answer, so the reader is not left to interpret
# raw protocol fields. kind in {ok, warn, bad}.
_verdict() {
    local kind=$1; shift
    case "$kind" in
        ok)   printf '  %s%s%s  %s\n' "$_C_GREEN"  "$_SYM_CHECK" "$_C_RESET" "$*" ;;
        warn) printf '  %s%s%s  %s\n' "$_C_YELLOW" "$_SYM_WARN"  "$_C_RESET" "$*" ;;
        bad)  printf '  %s%s%s  %s\n' "$_C_RED"    "$_SYM_CROSS" "$_C_RESET" "$*" ;;
    esac
}
_note() { printf '  %s%s%s\n' "$_C_DIM" "$*" "$_C_RESET"; }

# ---------------------------------------------------------------- panels

panel_components() {
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
    _listening "${DASHBOARD_PORT:-8600}" && _row "Dashboard" "$UP" "https://${PING_HOSTNAME}:${DASHBOARD_PORT:-8600}" \
        || _row "Dashboard" "$DOWN" "not started — ./bin/ping-control.sh start dash"
}

# PingDirectory DATA replication: user entries flowing between replicas.
panel_replication() {
    [[ "$CLUSTERED_PD" == "1" ]] || return 0
    section "PingDirectory replication  (data — user entries between replicas)"
    if ! _listening "$PINGDIR_LDAPS_PORT"; then
        _verdict bad "node 1 is down — replication status unavailable"; return 0
    fi
    local pw out; pw=$(mktemp); chmod 600 "$pw"; printf '%s' "$PINGDIR_ROOT_PASSWORD" > "$pw"
    out=$("${PINGDIR_DIR}/bin/dsreplication" status --hostname localhost --port "$PINGDIR_LDAPS_PORT" \
            --useSSL --trustAll --adminUID "$PINGDIR_REPL_ADMIN_UID" --adminPasswordFile "$pw" \
            --no-prompt 2>/dev/null | grep -viE 'tput:')
    rm -f "$pw"
    # The status table pads its columns with " : ", but the server cell itself
    # contains "host:port" with no spaces — so split on the padded separator only.
    printf '%s' "$out" | python3 -c "
import re, sys
rows = []
for line in sys.stdin.read().splitlines():
    if ' : ' not in line or line.lstrip().startswith(('Server', '-')):
        continue
    f = [c.strip() for c in re.split(r' +: +', line.strip())]
    if len(f) >= 6 and f[2].isdigit():
        rows.append(f)
if not rows:
    print('  (no replicated backends reported)'); raise SystemExit
worst_backlog, conflicts = 0, 0
for name, loc, entries, confl, backlog, rate in (r[:6] for r in rows):
    b = int(backlog) if backlog.isdigit() else 0
    c = int(confl) if confl.isdigit() else 0
    worst_backlog = max(worst_backlog, b); conflicts += c
    print('  %-38s %6s entries   backlog %-5s conflicts %-4s rate %s' % (name, entries, backlog, confl, rate))
print('VERDICT %d %d' % (worst_backlog, conflicts))
" 2>/dev/null | while IFS= read -r line; do
        if [[ "$line" == VERDICT* ]]; then
            read -r _ backlog conflicts <<<"$line"
            if [[ "${backlog:-0}" -eq 0 ]]; then
                _verdict ok "in sync — no backlog on any replica"
            else
                _verdict warn "behind — ${backlog} change(s) not yet applied on the slowest replica"
            fi
            [[ "${conflicts:-0}" -gt 0 ]] && _verdict bad "${conflicts} conflict entry/entries — resolve before they diverge further"
        else
            printf '%s\n' "$line"
        fi
    done
    _note "Backlog is changes accepted elsewhere but not yet applied here. Near 0 means caught up."
}

# PingFederate CONFIG replication: admin console pushing configuration to engines.
# A different thing from the panel above, and the reason both are labelled.
panel_cluster() {
    [[ "$CLUSTERED_PF" == "1" ]] || return 0
    section "PingFederate cluster  (configuration — console out to engines)"
    curl -sk "${PF_A[@]}" "$PFADMIN/cluster/status" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('  (console unavailable)'); raise SystemExit
for n in d.get('nodes', []):
    print('  node %-3s %-18s %-22s v%-10s %s' % (
        n.get('index'), n.get('mode', '?'), n.get('address', '?'),
        n.get('version', '?'), n.get('replicationStatus', '?')))
print('MARK required=%s mixed=%s changed=%s pushed=%s' % (
    d.get('replicationRequired'), d.get('mixedMode'),
    d.get('lastConfigUpdateTime'), d.get('lastReplicationTime')))
" 2>/dev/null | while IFS= read -r line; do
        if [[ "$line" == MARK* ]]; then
            local required mixed changed pushed
            required=$(sed -n 's/.*required=\([^ ]*\).*/\1/p' <<<"$line")
            mixed=$(sed -n 's/.*mixed=\([^ ]*\).*/\1/p' <<<"$line")
            changed=$(sed -n 's/.*changed=\([^ ]*\).*/\1/p' <<<"$line")
            pushed=$(sed -n 's/.*pushed=\([^ ]*\).*/\1/p' <<<"$line")
            if [[ "$required" == "False" ]]; then
                _verdict ok "config in sync — every engine already has the console's current configuration"
            elif [[ "$required" == "True" ]]; then
                _verdict warn "config PENDING — the console holds changes the engines have not received"
                _note   "    push them:  curl -sk -u <admin> -H 'X-XSRF-Header: PingFederate' -X POST ${PFADMIN}/cluster/replicate"
                _note   "    or click Replicate Configuration in the admin console"
            else
                _verdict warn "config replication state unknown"
            fi
            [[ "$mixed" == "True" ]] && _verdict warn "mixed mode — nodes are not all on the same version"
            _note "last config change ${changed}, last push ${pushed}"
        else
            printf '%s\n' "$line"
        fi
    done
    _note "\"Replication required\" here means a pending configuration push, not directory data."
    _note "false is the healthy state: nothing is waiting to go out to the engines."
}

panel_link() {
    section "PingFederate -> PingDirectory link"
    curl -sk "${PF_A[@]}" "$PFADMIN/dataStores/${PINGFED_PD_DATASTORE_ID}" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('  (unavailable)'); raise SystemExit
print('  datastore: %s  useSsl=%s  hosts=%s' % (d.get('ldapType'), d.get('useSsl'), d.get('hostnames')))
" 2>/dev/null || printf '  (unavailable)\n'
    local url; url=$(grep '^ldap.url=' "${PINGFED_DIR}/bin/ldap.properties" 2>/dev/null | cut -d= -f2-)
    if [[ "$url" == ldaps://* ]]; then
        printf '  admin-auth: LDAPS  %s\n' "$url"
    else
        printf '  admin-auth: %s\n' "${url:-unknown}"
    fi
}

panel_lb() {
    [[ "$LB_ON" == "1" ]] || return 0
    section "Load balancer routing"
    _row "LB -> PF engine" "$([[ $(_code "${RT_URL}/pf/heartbeat.ping") == 200 ]] && echo "$UP" || echo "$DOWN")" "${RT_URL}/pf/heartbeat.ping"
    local ac; ac=$(_code "${APP_URL}/")
    _row "LB -> PA app" "$([[ "$ac" =~ ^(200|302|401|403)$ ]] && echo "$UP" || echo "$DOWN")" "${APP_URL}/ (HTTP ${ac})"
}

panel_resources() {
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
}

snapshot() {
    banner "Ping stack monitor   $(date '+%Y-%m-%d %H:%M:%S')"
    local p
    for p in "${PANELS[@]}"; do "panel_${p}"; done
    printf '\n'
}

# ---------------------------------------------------------------- log follow

# One file per source. Audit logs are separate sources because they answer a
# different question from the server logs: what a user did, not what broke.
_source_files() {
    case "$1" in
        pf)        echo "${PINGFED_DIR}/log/server.log" ;;
        pf-audit)  echo "${PINGFED_DIR}/log/audit.log" ;;
        pf2)       echo "${PINGFED2_DIR}/log/server.log" ;;
        pd)        echo "${PINGDIR_DIR}/logs/errors" ;;
        pd-access) echo "${PINGDIR_DIR}/logs/access" ;;
        pd2)       echo "${PINGDIR2_DIR}/logs/errors" ;;
        pa)        echo "${PINGACCESS_DIR}/log/pingaccess.log" ;;
        pa-audit)  echo "${PINGACCESS_DIR}/log/pingaccess_engine_audit.log" ;;
        dash)      echo "${LOG_DIR}/ping-dashboard.log" ;;
        install)   ls -1t "${LOG_DIR}"/install-*.log 2>/dev/null | head -1 ;;
    esac
}

# Chatter that is always the platform talking to itself, never the request you
# are watching. The directory access log is unusable for an SSO trace without
# this: topology monitoring and health-check connects outnumber real binds by
# an order of magnitude. --raw turns it off.
_source_filter() {
    case "$1" in
        # cn=monitor is matched unanchored: the noisy probes read subtrees of it
        # (cn=Version,cn=monitor, cn=System Information,cn=monitor), not the root.
        pd-access|pd2) echo 'CONNECT |DISCONNECT |SECURITY-NEGOTIATION|cn=monitor"|interServerComponent' ;;
        *)             echo "" ;;
    esac
}

tail_mode() {
    local -a pids=() started=() files=()
    local colours=("$_C_CYAN" "$_C_GREEN" "$_C_YELLOW" "$_C_BLUE" "$_C_WHITE")
    local src f
    for src in "${SOURCES[@]}"; do
        f=$(_source_files "$src")
        if [[ -z "$f" || ! -f "$f" ]]; then
            warning "no log file for '${src}'${f:+ (${f})} — skipping"
            continue
        fi
        started+=("$src"); files+=("$f")
    done
    [[ ${#started[@]} -eq 0 ]] && { error "No log files to follow."; exit 1; }

    # Banner first: the children start emitting their backlog the moment they are
    # spawned, so anything printed after them lands in the middle of the output.
    banner "Following: ${started[*]}"
    [[ "$RAW" == "0" ]] && info "Filtering self-chatter (topology monitor, health-check connects) — --raw to see everything"
    info "Ctrl-C to stop"

    # Cleanup has to hold the tail PIDs specifically. $! on a pipeline is the
    # LAST stage, so killing it leaves tail -F running after the script exits —
    # they accumulate, one set per run. The spawn below redirects into a process
    # substitution instead of a pipeline, which makes $! the tail itself; the
    # filter stages then exit on their own when the pipe closes. EXIT catches
    # every other way out, and pkill -P is the backstop.
    # shellcheck disable=SC2317
    _stop() {
        trap - INT TERM EXIT
        [[ ${#pids[@]} -gt 0 ]] && kill "${pids[@]}" 2>/dev/null
        pkill -P $$ 2>/dev/null
        printf '\n'; exit 0
    }
    trap _stop INT TERM EXIT

    local i=0 prefix drop
    for i in "${!started[@]}"; do
        src="${started[$i]}"; f="${files[$i]}"
        prefix="${colours[$(( i % ${#colours[@]} ))]}$(printf '%-10s' "$src")${_C_RESET} "
        drop=$(_source_filter "$src")
        # -F survives rotation. Every stage flushes per line, or matches sit in a
        # buffer and the "live" tail arrives in bursts minutes late.
        if [[ -n "$drop" && "$RAW" == "0" ]]; then
            tail -F -n "$TAIL_LINES" "$f" 2>/dev/null \
                > >(grep -Ev --line-buffered "$drop" | awk -v p="$prefix" '{print p $0; fflush()}') &
        else
            tail -F -n "$TAIL_LINES" "$f" 2>/dev/null \
                > >(awk -v p="$prefix" '{print p $0; fflush()}') &
        fi
        pids+=($!)   # the tail itself, because of the process substitution above
    done
    wait
}

usage() {
    cat <<EOF

  ./bin/ping-monitor.sh [panel ...]                 snapshot (default: all panels)
  ./bin/ping-monitor.sh --watch [secs] [panel ...]  stay up, refreshing (default 5s)
  ./bin/ping-monitor.sh --tail <source ...> [-n N]  follow logs, labelled (--raw = no filtering)
  ./bin/ping-monitor.sh --list                      show panels and sources

  Panels:   ${ALL_PANELS[*]}
  Sources:  ${ALL_SOURCES[*]}
            sso  = pa-audit + pf-audit + pd-access, i.e. one login across all three

EOF
}

# ---------------------------------------------------------------- args

MODE="snapshot"; INTERVAL=5; TAIL_LINES=20; RAW=0
PANELS=(); SOURCES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch) MODE="watch"
                 # The interval is optional, so only consume the next argument
                 # when it is actually a number — otherwise it is a panel name.
                 [[ "${2:-}" =~ ^[0-9]+$ ]] && { INTERVAL="$2"; shift; } ;;
        --tail)  MODE="tail" ;;
        --raw)   RAW=1 ;;
        --list)  usage; exit 0 ;;
        -n)      shift; TAIL_LINES="${1:-20}" ;;
        -h|--help) usage; exit 0 ;;
        sso)     SOURCES+=(pa-audit pf-audit pd-access) ;;
        all)     [[ "$MODE" == "tail" ]] && SOURCES+=("${ALL_SOURCES[@]}") || PANELS+=("${ALL_PANELS[@]}") ;;
        *)
            if [[ " ${ALL_PANELS[*]} " == *" $1 "* ]]; then PANELS+=("$1")
            elif [[ " ${ALL_SOURCES[*]} " == *" $1 "* ]]; then SOURCES+=("$1")
            else error "Unknown argument '$1'"; usage; exit 2; fi ;;
    esac
    shift
done

if [[ "$MODE" == "tail" ]]; then
    [[ ${#SOURCES[@]} -eq 0 ]] && { error "--tail needs at least one source (try: sso)"; usage; exit 2; }
    tail_mode
fi

[[ ${#PANELS[@]} -eq 0 ]] && PANELS=("${ALL_PANELS[@]}")

if [[ "$MODE" == "watch" ]]; then
    trap 'exit 0' INT
    n=0
    while true; do
        n=$(( n + 1 ))
        started=$(date +%s)
        out=$(snapshot)
        clear
        printf '%s\n' "$out"
        printf '  %s[%s]  refresh %ss  ·  pass %d took %ss  ·  Ctrl-C to exit%s\n' \
            "$_C_DIM" "${PANELS[*]}" "$INTERVAL" "$n" "$(( $(date +%s) - started ))" "$_C_RESET"
        sleep "$INTERVAL"
    done
else
    snapshot
fi
