#!/bin/bash
set -euo pipefail

################################################################################
# Script Name: churn-changes.sh
# Description: Apply a continuous stream of modifications to directory 1, so
#              replication to directory 2 has something to carry and the
#              monitor has something to show.
#
#   Each iteration writes a new description onto one entry, cycling through the
#   entries so the same one is not hammered. Every write is a real replicated
#   change: it enters directory 1's change log, crosses the replication port,
#   and is applied on directory 2. That is what the replication panel is
#   measuring the backlog of.
#
#   Run it in one terminal and watch in another:
#       ./bin/ping-monitor.sh --watch 2 replication
#       ./bin/ping-monitor.sh --tail pd-access pd2-access
#
#   The second one is the more convincing view: the same change appears in
#   directory 1's log as a MODIFY from this script, and in directory 2's log as
#   a MODIFY from the replication subsystem, a moment later.
#
# Usage:
#   ./demo/churn-changes.sh                 forever, ~2 writes/second
#   ./demo/churn-changes.sh -c 500          stop after 500 changes
#   ./demo/churn-changes.sh -r 20           ~20 writes/second, to build a backlog
#   ./demo/churn-changes.sh -r 0            as fast as it will go
################################################################################

cd "$(dirname "${BASH_SOURCE[0]}")/.."
source ./pingconfig.env
# shellcheck disable=SC1091
source ./lib/logging.sh

COUNT=0                 # 0 = run until interrupted
RATE=2                  # writes per second; 0 = unthrottled
FILTER="(uid=*)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c) COUNT="$2"; shift 2 ;;
        -r) RATE="$2"; shift 2 ;;
        -f) FILTER="$2"; shift 2 ;;
        -h|--help) sed -n '5,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) error "unknown argument: $1"; exit 2 ;;
    esac
done

LDAPMODIFY="${PINGDIR_DIR}/bin/ldapmodify"
LDAPSEARCH="${PINGDIR_DIR}/bin/ldapsearch"
_PW_FILE=""
_written=0; _failed=0; _t0=$(date +%s)

_report() {
    local secs=$(( $(date +%s) - _t0 )); (( secs == 0 )) && secs=1
    printf '\n'
    success "${_written} entries carrying a churn value after ${secs}s, ${_failed} rejected"
    if [[ "${PINGDIR_COUNT:-1}" -gt 1 ]]; then
        info "check the backlog cleared:  ./bin/ping-monitor.sh replication"
    fi
}
_cleanup() { [[ -n "$_PW_FILE" ]] && rm -f "$_PW_FILE"; return 0; }
trap '_cleanup' EXIT
trap 'trap - INT TERM; _report; exit 0' INT TERM

_PW_FILE=$(mktemp); chmod 600 "$_PW_FILE"; printf '%s' "$PINGDIR_ROOT_PASSWORD" > "$_PW_FILE"

banner "Continuous changes on ${PINGDIR_INSTANCE_NAME}"

mapfile -t DNS < <("$LDAPSEARCH" --hostname localhost --port "$PINGDIR_LDAP_PORT" \
                   --bindDN "$PINGDIR_ROOT_DN" --bindPasswordFile "$_PW_FILE" \
                   --baseDN "$PINGDIR_PEOPLE_DN" --sizeLimit 0 "$FILTER" dn 2>/dev/null \
                   | awk '/^dn: /{print substr($0,5)}')

if [[ "${#DNS[@]}" -eq 0 ]]; then
    error "no entries matched ${FILTER} under ${PINGDIR_PEOPLE_DN}"
    info  "seed some first:  ./demo/load-bulk-users.sh -n 100"
    exit 1
fi

info "${#DNS[@]} entries to cycle through"
if [[ "${PINGDIR_COUNT:-1}" -gt 1 ]]; then
    info "PINGDIR_COUNT=${PINGDIR_COUNT} — every change below replicates to ${PINGDIR2_INSTANCE_NAME:-pingdirectory-2}"
else
    warning "PINGDIR_COUNT=1 — nothing to replicate to. Reinstall with HA=true for the replication view."
fi
[[ "$COUNT" -gt 0 ]] && info "stopping after ${COUNT} changes" || info "running until Ctrl-C"
[[ "$RATE" -gt 0 ]] && info "throttled to ~${RATE}/s" || warning "unthrottled — this will build a backlog, which is the point"
printf '\n'

_delay=0
[[ "$RATE" -gt 0 ]] && _delay=$(awk -v r="$RATE" 'BEGIN{printf "%.4f", 1/r}')

# One ldapmodify process, fed a stream of LDIF, rather than one process per change.
# Each invocation of the command-line tools starts a JVM, which costs roughly half a
# second — so a process per modification caps out near 2 changes/second and spends
# almost all of its time starting Java rather than writing to the directory. Feeding
# one long-lived process over one connection is both far faster and a fairer
# representation of what a real client does.
_generate() {
    local i=0 dn stamp
    while true; do
        dn="${DNS[$(( i % ${#DNS[@]} ))]}"
        stamp=$(date '+%Y-%m-%dT%H:%M:%S.%3N')
        printf 'dn: %s\nchangetype: modify\nreplace: description\ndescription: churn %d at %s\n\n' \
               "$dn" "$i" "$stamp"
        i=$(( i + 1 ))
        [[ "$COUNT" -gt 0 && "$i" -ge "$COUNT" ]] && break
        [[ "$RATE" -gt 0 ]] && sleep "$_delay"
    done
}

# The counter lives in this shell, so the modify stream is read here rather than in
# a subshell: a pipe would put the loop in a child and lose _written on exit.
_OUT=$(mktemp); trap '_cleanup; rm -f "$_OUT"' EXIT
_generate | "$LDAPMODIFY" --hostname localhost --port "$PINGDIR_LDAP_PORT" \
        --bindDN "$PINGDIR_ROOT_DN" --bindPasswordFile "$_PW_FILE" \
        --continueOnError > "$_OUT" 2>&1 &
_mod_pid=$!

# Progress from the directory's point of view: how many entries carry a churn
# description now. That measures what landed, not what was sent.
while kill -0 "$_mod_pid" 2>/dev/null; do
    sleep 2
    _written=$({ "$LDAPSEARCH" --hostname localhost --port "$PINGDIR_LDAP_PORT" \
                 --bindDN "$PINGDIR_ROOT_DN" --bindPasswordFile "$_PW_FILE" \
                 --baseDN "$PINGDIR_PEOPLE_DN" --sizeLimit 0 \
                 "(description=churn*)" dn 2>/dev/null || true; } | grep -c '^dn: ' || true)
    printf '\r  %s%d entries carry a churn value%s   %ds elapsed   ' \
        "$_C_GREEN" "$_written" "$_C_RESET" "$(( $(date +%s) - _t0 ))"
done
wait "$_mod_pid" 2>/dev/null || true

_failed=$(grep -ciE 'Result Code: +(1|32|50|53|65)\b' "$_OUT" || true)
_report
