#!/bin/bash
set -euo pipefail

################################################################################
# Script Name: load-bulk-users.sh
# Description: Load N users that all share one attribute value, to give the
#              directory something expensive to search.
#
#   The attribute is deliberately NOT indexed. A filter on it has nothing
#   selective to work with, so the directory reads every candidate entry — an
#   unindexed search. With 5000 entries behind one value the cost is easy to see
#   and easy to compare against an indexed lookup on the same data.
#
#   Run search-bulk-attribute.sh next; it does the comparison and shows what the
#   access log recorded. Then run this again with --index to create the index and
#   re-run the search, which is the more useful half of the demo: same data, same
#   filter, one configuration change.
#
#   A note on the entry-limit story. The teaching version is that a key holding
#   more IDs than index-entry-limit (default 4000) stops being maintained, so the
#   search goes unindexed even though the index exists. On this build — PingDirectory
#   11.1 — creating an attribute index produces a COMPOSITE index, and 5000 entries
#   under one key did not trip the limit in testing: the search stayed indexed and
#   the access log showed no entry-limit flag. Verify the behaviour on the target
#   version before teaching the 4000 number as a hard rule.
#
#   Entries are added online through LDAP, not import-ldif, so they replicate to
#   the second directory — which also makes this a usable replication load test.
#
# Usage:
#   ./demo/load-bulk-users.sh              5000 users sharing departmentNumber=Engineering
#   ./demo/load-bulk-users.sh --index      create the index, to show the fix
#   ./demo/load-bulk-users.sh --drop-index remove it again, to show the problem
#   ./demo/load-bulk-users.sh -a title -v Analyst    a different attribute
#   ./demo/load-bulk-users.sh --delete     remove the users
################################################################################

cd "$(dirname "${BASH_SOURCE[0]}")/.."
source ./pingconfig.env
# shellcheck disable=SC1091
source ./lib/logging.sh

COUNT=5000
# departmentNumber, not department: "department" is an Active Directory attribute
# and is not in PingDirectory's default schema, so indexing it fails with "no such
# attribute defined in the schema". departmentNumber is the standard inetOrgPerson
# equivalent and needs no schema change. Worth knowing before a customer asks why
# their AD attribute names do not exist here.
ATTR="departmentNumber"
VALUE="Engineering"
PREFIX="bulkuser"
BACKEND="userRoot"
DELETE=0; MAKE_INDEX=0; DROP_INDEX=0

usage() {
    cat <<EOF

  ./demo/load-bulk-users.sh [-n COUNT] [-a ATTR] [-v VALUE] [--delete]

    -n COUNT    how many users to create (default ${COUNT})
    -a ATTR     the attribute they all share (default ${ATTR})
    -v VALUE    the value they all share    (default ${VALUE})
    --delete    delete the users this script created, and stop

  The point of the default is that 5000 > the 4000 index entry limit, so the
  single key ${ATTR}=${VALUE} stops being maintained. Run with -n 3000 first if
  you want to show the same search while the key is still under the limit.

EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n) COUNT="$2"; shift 2 ;;
        -a) ATTR="$2"; shift 2 ;;
        -v) VALUE="$2"; shift 2 ;;
        --delete) DELETE=1; shift ;;
        --index) MAKE_INDEX=1; shift ;;
        --drop-index) DROP_INDEX=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) error "unknown argument: $1"; usage; exit 2 ;;
    esac
done

LDAPMODIFY="${PINGDIR_DIR}/bin/ldapmodify"
LDAPSEARCH="${PINGDIR_DIR}/bin/ldapsearch"
DSCONFIG="${PINGDIR_DIR}/bin/dsconfig"
_PW_FILE=""; _LDIF=""
_cleanup() { [[ -n "$_PW_FILE" ]] && rm -f "$_PW_FILE"; [[ -n "$_LDIF" ]] && rm -f "$_LDIF"; return 0; }
trap '_cleanup' EXIT
trap 'error "load-bulk-users.sh failed at line $LINENO"' ERR

_PW_FILE=$(mktemp); chmod 600 "$_PW_FILE"; printf '%s' "$PINGDIR_ROOT_PASSWORD" > "$_PW_FILE"
_ld() { "$1" --hostname localhost --port "$PINGDIR_LDAP_PORT" \
              --bindDN "$PINGDIR_ROOT_DN" --bindPasswordFile "$_PW_FILE" "${@:2}"; }

# ---------------------------------------------------------------- delete mode
if [[ "$DELETE" == "1" ]]; then
    banner "Removing bulk users"
    dns=$(_ld "$LDAPSEARCH" --baseDN "$PINGDIR_PEOPLE_DN" \
              "(uid=${PREFIX}*)" dn 2>/dev/null | awk '/^dn: /{print substr($0,5)}' || true)
    if [[ -z "$dns" ]]; then info "none found — nothing to do"; exit 0; fi
    n=$(printf '%s\n' "$dns" | wc -l)
    info "deleting ${n} entries under ${PINGDIR_PEOPLE_DN}"
    _LDIF=$(mktemp)
    printf '%s\n' "$dns" | while IFS= read -r d; do
        printf 'dn: %s\nchangetype: delete\n\n' "$d"
    done > "$_LDIF"
    _ld "$LDAPMODIFY" --continueOnError --filename "$_LDIF" >/dev/null 2>&1 || true
    success "removed ${n} bulk users"
    info "the ${ATTR} index is left in place — dsconfig delete-local-db-index to remove it"
    exit 0
fi

# ---------------------------------------------------------------- the index
banner "Bulk load: ${COUNT} users sharing ${ATTR}=${VALUE}"

limit=$(_ld "$DSCONFIG" get-backend-prop --backend-name "$BACKEND" \
            --property index-entry-limit --no-prompt 2>/dev/null \
        | awk '/index-entry-limit/{print $NF}')
limit="${limit:-4000}"
info "backend ${BACKEND} index-entry-limit: ${limit} (context — see the note in this script's header)"

_indexed() {
    _ld "$DSCONFIG" list-local-db-indexes --backend-name "$BACKEND" --no-prompt 2>/dev/null \
        | awk '{print $1}' | grep -qix "$ATTR"
}

# ---------------------------------------------------------------- index toggles
if [[ "$DROP_INDEX" == "1" ]]; then
    section "Removing the index on ${ATTR}"
    if _indexed; then
        _ld "$DSCONFIG" delete-local-db-index --backend-name "$BACKEND" \
            --index-name "$ATTR" --no-prompt >/dev/null
        success "index removed — searches on ${ATTR} are unindexed again"
    else
        info "no index on ${ATTR} — nothing to remove"
    fi
    info "re-run the comparison:  ./demo/search-bulk-attribute.sh"
    exit 0
fi

if [[ "$MAKE_INDEX" == "1" ]]; then
    section "Equality index on ${ATTR}"
    # Check the schema before dsconfig does, because its rejection is four lines of
    # wrapped config DN with the actual reason buried at the end.
    if ! _ld "$LDAPSEARCH" --baseDN "cn=schema" --searchScope base \
            "(objectClass=*)" attributeTypes 2>/dev/null | grep -qi "NAME '${ATTR}'\|NAME ( '${ATTR}'"; then
        error "'${ATTR}' is not in the directory schema, so it cannot be indexed"
        info  "Standard inetOrgPerson attributes that need no schema change:"
        info  "    departmentNumber   title   employeeType   ou   businessCategory"
        info  "'department' is an Active Directory attribute and is NOT one of them."
        exit 1
    fi
    if _indexed; then
        info "index already exists"
    else
        _ld "$DSCONFIG" create-local-db-index --backend-name "$BACKEND" \
            --index-name "$ATTR" --set index-type:equality --no-prompt >/dev/null
        success "created equality index on ${ATTR}"
    fi

    # Creating the index does NOT index the entries that are already there — new
    # adds are indexed as they arrive, but everything loaded beforehand is invisible
    # to it until the index is built. Skip this and the search stays unindexed and
    # the demo appears not to work. The rebuild runs online: the backend stays
    # writable, and the index is unusable for searches only while it runs.
    section "Rebuilding the index over the entries already loaded"
    if "${PINGDIR_DIR}/bin/rebuild-index" --task --baseDN "$PINGDIR_BASE_DN" \
         --index "$ATTR" --hostname localhost --port "$PINGDIR_LDAP_PORT" \
         --bindDN "$PINGDIR_ROOT_DN" --bindPasswordFile "$_PW_FILE" 2>&1 \
       | grep -qi 'successfully completed'; then
        success "index rebuilt — existing entries are now indexed"
    else
        error "rebuild-index did not complete; the search will still report unindexed"
        exit 1
    fi
    info "now re-run:  ./demo/search-bulk-attribute.sh"
    exit 0
fi

section "Index state"
if _indexed; then
    warning "${ATTR} is already indexed — the search will be fast, which is not the demo"
    info    "to show the problem first:  ./demo/load-bulk-users.sh --drop-index"
else
    info "${ATTR} has no index — a filter on it will be a full scan. That is the demo."
fi

# ---------------------------------------------------------------- the load
section "Generating LDIF"
_LDIF=$(mktemp)
awk -v n="$COUNT" -v p="$PREFIX" -v base="$PINGDIR_PEOPLE_DN" \
    -v attr="$ATTR" -v val="$VALUE" -v pw="$DEFAULT_PASSWORD" '
BEGIN {
    for (i = 1; i <= n; i++) {
        printf "dn: uid=%s%d,%s\n", p, i, base
        print  "objectClass: top"
        print  "objectClass: person"
        print  "objectClass: organizationalPerson"
        print  "objectClass: inetOrgPerson"
        printf "uid: %s%d\n", p, i
        print  "givenName: Bulk"
        printf "sn: User %d\n", i
        printf "cn: Bulk User %d\n", i
        printf "mail: %s%d@example.com\n", p, i
        printf "%s: %s\n", attr, val
        printf "userPassword: %s\n", pw
        print  ""
    }
}' > "$_LDIF"
info "$(wc -l < "$_LDIF") lines, $(du -h "$_LDIF" | cut -f1)"

# Count by asking the directory, not by parsing ldapmodify's output. The tool's
# per-operation wording varies by version and the count is the thing we actually
# care about, so measure the state rather than the transcript.
_matching() {
    { _ld "$LDAPSEARCH" --baseDN "$PINGDIR_PEOPLE_DN" --sizeLimit 0 \
          "(${ATTR}=${VALUE})" dn 2>/dev/null || true; } | grep -c '^dn: ' || true
}

section "Loading over LDAP (online, so it replicates)"
before=$(_matching)
start=$(date +%s)
out=$(_ld "$LDAPMODIFY" --defaultAdd --continueOnError --filename "$_LDIF" 2>&1 || true)
took=$(( $(date +%s) - start )); (( took == 0 )) && took=1
after=$(_matching)
added=$(( after - before ))

failed=$(grep -ciE 'Result Code: +(1|32|50|53|65)\b' <<<"$out" || true)
success "added    ${added} in ${took}s ($(( added / took ))/s)"
[[ "$before" -gt 0 ]] && info "existed  ${before} already — rerunning is safe"
if [[ "$failed" -gt 0 ]]; then
    error "failed   ${failed}"
    grep -iE 'Result Code: +(1|32|50|53|65)\b' <<<"$out" | head -3 | sed 's/^/    /'
fi
success "${after} entries now match (${ATTR}=${VALUE})"

banner "Next"
cat <<EOF
  Show what that costs to search, against an indexed lookup on the same data:
      ./demo/search-bulk-attribute.sh

  Watch bad searches arrive as they happen — this view stays empty until one does:
      ./bin/ping-monitor.sh --tail unindexed

  Then fix it and run the same comparison again:
      ./demo/load-bulk-users.sh --index
      ./demo/search-bulk-attribute.sh
EOF
if [[ "${PINGDIR_COUNT:-1}" -gt 1 ]]; then
cat <<EOF

  Those ${added} adds replicated to directory 2 as they were written:
      ./bin/ping-monitor.sh replication
      ./demo/churn-changes.sh          keep changes flowing to watch it live
EOF
fi
