#!/bin/bash
set -euo pipefail

################################################################################
# Script Name: search-bulk-attribute.sh
# Description: Show what an unindexed search costs, by running it next to an
#              indexed one against the same data.
#
#   A number on its own means nothing — "the search took 400ms" is only alarming
#   with something to compare it to. So this runs three searches:
#
#     1. uid=<one entry>          indexed, unique key      the baseline
#     2. <attr>=<shared value>    no index — a full scan
#     3. the same search as the PingFederate service account
#
#   Search 3 is the one worth pausing on. Without the unindexed-search privilege
#   the directory REFUSES the search — result code 53, "unwilling to process the
#   unindexed search operation" — rather than running it slowly. That is the
#   safer failure, and it is the reason not to grant that privilege to the
#   account PingFederate binds with: a bind path that CAN fall back to a full
#   scan eventually will, at the worst possible moment.
#
#   Read the etime column, not the wall clock. Wall clock includes ~700ms of JVM
#   start-up for the ldapsearch tool itself, which swamps the difference; etime
#   is what the server spent, and it is the honest comparison.
#
#   The evidence lives in the access log: unindexed=true, and
#   usedPrivileges="unindexed-search" on the search that needed it.
#
# Usage:
#   ./demo/search-bulk-attribute.sh
#   ./demo/search-bulk-attribute.sh -a title -v Analyst
################################################################################

cd "$(dirname "${BASH_SOURCE[0]}")/.."
source ./pingconfig.env
# shellcheck disable=SC1091
source ./lib/logging.sh

ATTR="departmentNumber"
VALUE="Engineering"
PREFIX="bulkuser"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a) ATTR="$2"; shift 2 ;;
        -v) VALUE="$2"; shift 2 ;;
        -h|--help) sed -n '5,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) error "unknown argument: $1"; exit 2 ;;
    esac
done

LDAPSEARCH="${PINGDIR_DIR}/bin/ldapsearch"
ACCESS_LOG="${PINGDIR_DIR}/logs/access"
_PW_FILE=""; _SVC_PW=""
_cleanup() { [[ -n "$_PW_FILE" ]] && rm -f "$_PW_FILE"; [[ -n "$_SVC_PW" ]] && rm -f "$_SVC_PW"; return 0; }
trap '_cleanup' EXIT
trap 'error "search-bulk-attribute.sh failed at line $LINENO"' ERR

_PW_FILE=$(mktemp); chmod 600 "$_PW_FILE"; printf '%s' "$PINGDIR_ROOT_PASSWORD" > "$_PW_FILE"
_SVC_PW=$(mktemp);  chmod 600 "$_SVC_PW";  printf '%s' "$DEFAULT_PASSWORD"      > "$_SVC_PW"

# Run one search, report wall-clock ms and the row count, and return the marker
# we can find the matching access-log line by.
_run() {
    local label="$1" filter="$2" binddn="$3" pwfile="$4"
    local t0 t1 ms out rc entries
    t0=$(date +%s%3N)
    set +e
    out=$("$LDAPSEARCH" --hostname localhost --port "$PINGDIR_LDAP_PORT" \
          --bindDN "$binddn" --bindPasswordFile "$pwfile" \
          --baseDN "$PINGDIR_PEOPLE_DN" --sizeLimit 0 "$filter" dn 2>&1)
    rc=$?
    set -e
    t1=$(date +%s%3N); ms=$(( t1 - t0 ))
    entries=$(grep -c '^dn: ' <<<"$out" || true)

    if [[ $rc -eq 0 ]]; then
        printf '  %-42s %6s ms   %5s entries\n' "$label" "$ms" "$entries"
    else
        local reason
        reason=$(grep -oiE 'Result Code: +[0-9]+ \([^)]*\)' <<<"$out" | head -1)
        reason="${reason:-$(head -2 <<<"$out" | tr '\n' ' ')}"
        printf '  %-42s %6s ms   %s\n' "$label" "$ms" "REFUSED — ${reason}"
    fi
    return 0
}

banner "What an unindexed search costs"

# A real uid to use for the indexed baseline: prefer a bulk user so both searches
# hit the same entries, and fall back to any entry if the bulk load has not run.
#
# --sizeLimit 1 against thousands of matches returns result code 4, "size limit
# exceeded", which is a non-zero exit even though the entry we wanted came back.
# Hence the || true on every one of these: we are sampling, not asserting.
_first_uid() {
    "$LDAPSEARCH" --hostname localhost --port "$PINGDIR_LDAP_PORT" \
        --bindDN "$PINGDIR_ROOT_DN" --bindPasswordFile "$_PW_FILE" \
        --baseDN "$PINGDIR_PEOPLE_DN" --sizeLimit 1 "$1" uid 2>/dev/null \
        | awk '/^uid: /{print $2; exit}' || true
}
sample=$(_first_uid "(uid=${PREFIX}*)")
if [[ -z "$sample" ]]; then
    warning "no ${PREFIX}* entries found — run ./demo/load-bulk-users.sh first"
    sample=$(_first_uid "(uid=*)")
fi
[[ -z "$sample" ]] && { error "no entries at all under ${PINGDIR_PEOPLE_DN}"; exit 1; }

matches=$({ "$LDAPSEARCH" --hostname localhost --port "$PINGDIR_LDAP_PORT" \
            --bindDN "$PINGDIR_ROOT_DN" --bindPasswordFile "$_PW_FILE" \
            --baseDN "$PINGDIR_PEOPLE_DN" --sizeLimit 0 "(${ATTR}=${VALUE})" dn 2>/dev/null \
            || true; } | grep -c '^dn: ' || true)
if "${PINGDIR_DIR}/bin/dsconfig" list-local-db-indexes --backend-name userRoot \
     --hostname localhost --port "$PINGDIR_LDAP_PORT" \
     --bindDN "$PINGDIR_ROOT_DN" --bindPasswordFile "$_PW_FILE" --no-prompt 2>/dev/null \
   | awk '{print $1}' | grep -qix "$ATTR"; then
    INDEXED=1; info "${matches} entries share ${ATTR}=${VALUE} — and ${ATTR} IS indexed"
else
    INDEXED=0; info "${matches} entries share ${ATTR}=${VALUE} — and ${ATTR} has NO index"
fi

_mark_from=$(wc -l < "$ACCESS_LOG" 2>/dev/null || echo 0)

section "Four searches, same directory, same 5000 entries"
_run "1. uid=${sample}  (indexed, unique key)"      "(uid=${sample})"     "$PINGDIR_ROOT_DN"       "$_PW_FILE"
_run "2. ${ATTR}=${VALUE}  (matches 5000)"          "(${ATTR}=${VALUE})"  "$PINGDIR_ROOT_DN"       "$_PW_FILE"
# The one that isolates the scan from the transfer. Matching nothing means there
# is no result set to build and no entries to return, so whatever time this takes
# is time spent looking — which is exactly the cost an index removes.
_run "3. ${ATTR}=NoSuchValue  (matches nothing)"    "(${ATTR}=NoSuchValue)" "$PINGDIR_ROOT_DN"     "$_PW_FILE"
_run "4. search 2, as the PingFederate service account" "(${ATTR}=${VALUE})" "$PINGFED_ADMIN_USER_DN" "$_SVC_PW"
printf '\n  %sWall clock above includes ~700ms of JVM start-up. Read etime below.%s\n' "$_C_DIM" "$_C_RESET"

section "What the server actually spent — from the access log"
if [[ -r "$ACCESS_LOG" ]]; then
    tail -n +$(( _mark_from + 1 )) "$ACCESS_LOG" 2>/dev/null | grep 'SEARCH RESULT' \
      | grep -E "uid=${sample}|${ATTR}=" \
      | while IFS= read -r line; do
            f=$(grep -o 'filter="[^"]*"' <<<"$line" | head -1)
            e=$(grep -o 'etime=[0-9.]*' <<<"$line" | head -1)
            r=$(grep -o 'resultCode=[0-9]*' <<<"$line" | head -1)
            n=$(grep -o 'entriesReturned=[0-9]*' <<<"$line" | head -1)
            u=$(grep -qo 'unindexed="\?true' <<<"$line" && echo " UNINDEXED" || echo "")
            printf '  %-42s %-14s %-8s %-20s%s\n' "${f#filter=}" "$e" "$r" "$n" "$u"
        done
    echo
    unindexed=$(tail -n +$(( _mark_from + 1 )) "$ACCESS_LOG" 2>/dev/null | grep -c 'unindexed="\?true' || true)
    if [[ "$unindexed" -gt 0 ]]; then
        warning "${unindexed} search(es) logged unindexed=true — the server read every candidate entry"
    elif [[ "$INDEXED" == "1" ]]; then
        success "nothing unindexed — the index on ${ATTR} is doing its job"
    else
        info "nothing logged unindexed; check the filter matched anything at all"
    fi
else
    warning "cannot read ${ACCESS_LOG}"
fi

banner "The point"
if [[ "$INDEXED" == "1" ]]; then
cat <<EOF
  ${ATTR} is indexed, so search 2 is now a key lookup like search 1. Same data,
  same filter, same 5000 entries — one configuration change.

  Put it back to see the difference again:
      ./demo/load-bulk-users.sh --drop-index && ./demo/search-bulk-attribute.sh
EOF
else
cat <<EOF
  Search 1 reads one key with one ID behind it. Search 2 has no index to use, so
  the server reads every candidate entry — and it costs that whether it matches
  5000 entries or none, because the work is in the scanning, not the returning.

  Search 3 is REFUSED, not run slowly: result code 53, "unwilling to process the
  unindexed search operation". That is the safer failure, and it is exactly why
  the PingFederate service account should not hold unindexed-search — a bind path
  that can fall back to a full scan eventually will, under load.

  Now fix it and run this again:
      ./demo/load-bulk-users.sh --index && ./demo/search-bulk-attribute.sh
EOF
fi
printf '\n  Watch these arrive live instead of after the fact:\n      ./bin/ping-monitor.sh --tail unindexed\n\n'
