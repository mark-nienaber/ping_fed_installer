#!/bin/bash
set -euo pipefail

################################################################################
# Script Name: cluster_pingfed.sh
# Description: Turn the single PingFederate node into a 2-node cluster:
#              node 1 = CLUSTERED_CONSOLE (admin/config authority),
#              node 2 = CLUSTERED_ENGINE  (runtime OAuth/OIDC).
#
#   Runtime state (SSO sessions + OAuth grants) is already externalized to the
#   replicated PingDirectory, so the engine node is stateless — exactly what
#   makes horizontal PF scaling clean.
#
#   Approach (single-host demo; node 2 gets its own dir + offset ports):
#     1. Generate one cluster encryption key (bin/clusterkey.sh) and set it on
#        the console.
#     2. Switch node 1 to CLUSTERED_CONSOLE + TCP cluster discovery.
#     3. Clone node 1's full install to node 2 (so pf.jwk + MasterKeySet.xml +
#        all config match — required to decrypt the shared cluster key and to
#        run the same runtime config), then switch node 2 to CLUSTERED_ENGINE.
#     4. Restart the console, start the engine, confirm the engine joined and
#        push config to it (POST /cluster/replicate).
#
#   Idempotent: reuses an existing cluster key; re-clones only when node 2 is
#   absent. Only runs when PINGFED_COUNT > 1.
################################################################################

source ./pingconfig.env
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "${_LIB_DIR}/logging.sh"
# shellcheck disable=SC1091
source "${_LIB_DIR}/rest_helpers.sh"

PF1_DIR="${PINGFED_DIR}"
PF1_RP="${PF1_DIR}/bin/run.properties"
PF1_PID="${PF1_DIR}/bin/pingfederate.pid"
PF2_RP="${PINGFED2_DIR}/bin/run.properties"
PF2_PID="${PINGFED2_DIR}/bin/pingfederate.pid"
PF_RUN_LOG_1="${LOG_DIR}/pingfederate-run.log"
PF_RUN_LOG_2="${LOG_DIR}/pingfederate2-run.log"

# Host's non-loopback IPv4 — PF cluster binds NON_LOOPBACK, so TCP discovery
# must advertise that address (ping.example.com resolves to 127.0.0.1 here).
HOSTIP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
DISCOVERY="${HOSTIP}[${PINGFED_CLUSTER_BIND_PORT_1}],${HOSTIP}[${PINGFED_CLUSTER_BIND_PORT_2}]"
CLUSTER_KEY=""

trap 'error "cluster_pingfed.sh failed at line $LINENO"' ERR

function set_prop() {  # file key value
    local f=$1 k=$2 v=$3 ve
    ve=$(printf '%s' "$v" | sed 's/[&|]/\\&/g')
    if grep -qE "^${k}=" "$f"; then sed -i "s|^${k}=.*|${k}=${ve}|" "$f"
    else printf '%s=%s\n' "$k" "$v" >> "$f"; fi
}
function get_prop() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }

# Real java PID(s) for a given install dir. The trailing space after the dir is
# a boundary so node 1 (pf.home=/ping/pingfederate ) never matches node 2
# (pf.home=/ping/pingfederate-2 ).
function _pf_pids() { pgrep -f "pf.home=$1 " 2>/dev/null || true; }

function stop_pf() {  # dir pidfile label port
    local dir=$1 pidf=$2 label=$3 port=$4
    info "Stopping ${label}..."
    # Graceful via the pid file, then any lingering java for this pf.home.
    if [[ -f "$pidf" ]]; then
        local pid; pid=$(cat "$pidf" 2>/dev/null || true)
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    fi
    local pids; pids=$(_pf_pids "$dir")
    [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
    # Wait for the actual process to exit AND the port to close — the run.lck is
    # held until the java process is gone, so a port check alone races the next
    # start ("Another PingFederate instance is already running. Exiting.").
    local i=0
    while [[ $i -lt 45 ]]; do
        pids=$(_pf_pids "$dir")
        if [[ -z "$pids" ]] && ! ss -ltn 2>/dev/null | grep -q ":${port} "; then
            info "${label} stopped"; return 0
        fi
        sleep 2; ((i++)) || true
    done
    pids=$(_pf_pids "$dir"); [[ -n "$pids" ]] && kill -9 $pids 2>/dev/null || true
    sleep 3
    warning "${label} force-stopped after timeout"
}

function start_pf() {  # dir runlog label checkurl
    local dir=$1 runlog=$2 label=$3 url=$4
    info "Starting ${label}..."
    mkdir -p "$LOG_DIR"
    ( cd "$dir" && setsid bash -c 'exec ./bin/run.sh' > "$runlog" 2>&1 </dev/null & )
    local i=0
    while [[ $i -lt 48 ]]; do
        local code; code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || echo 000)
        [[ "$code" =~ ^(200|302|401)$ ]] && { success "${label} up ($url -> $code)"; return 0; }
        sleep 5; ((i++)) || true
    done
    error "${label} did not come up ($url); see $runlog"; return 1
}

# -----------------------------------------------------------------------------
# 1. Cluster encryption key (shared across nodes; OBF, encrypted by pf.jwk)
# -----------------------------------------------------------------------------
function ensure_cluster_key() {
    local existing; existing=$(get_prop "$PF1_RP" pf.cluster.auth.pwd)
    if [[ -n "$existing" && "$(get_prop "$PF1_RP" pf.operational.mode)" == "CLUSTERED_CONSOLE" ]]; then
        info "Reusing existing cluster key from console run.properties"
        CLUSTER_KEY="$existing"; return 0
    fi
    info "Generating cluster encryption key..."
    export JAVA_HOME="${JAVA_HOME:-}"
    CLUSTER_KEY=$(cd "$PF1_DIR" && ./bin/clusterkey.sh generate 2>/dev/null | grep -oE 'OBF:[^[:space:]]+' | head -1)
    [[ -n "$CLUSTER_KEY" ]] || { error "clusterkey.sh produced no key"; return 1; }
    success "Cluster key generated"
}

# -----------------------------------------------------------------------------
# 2. Console node (node 1)
# -----------------------------------------------------------------------------
function configure_console() {
    [[ -f "${PF1_RP}.orig-precluster" ]] || cp "$PF1_RP" "${PF1_RP}.orig-precluster"
    info "Configuring node 1 as CLUSTERED_CONSOLE..."
    set_prop "$PF1_RP" pf.operational.mode CLUSTERED_CONSOLE
    set_prop "$PF1_RP" pf.cluster.node.index 1
    set_prop "$PF1_RP" pf.cluster.auth.pwd "$CLUSTER_KEY"
    set_prop "$PF1_RP" pf.cluster.bind.port "$PINGFED_CLUSTER_BIND_PORT_1"
    set_prop "$PF1_RP" pf.cluster.failure.detection.bind.port "$PINGFED_CLUSTER_FAILOVER_PORT_1"
    set_prop "$PF1_RP" pf.cluster.transport.protocol tcp
    set_prop "$PF1_RP" pf.cluster.tcp.discovery.initial.hosts "$DISCOVERY"
    success "Console configured (node.index=1, bind ${PINGFED_CLUSTER_BIND_PORT_1})"
}

# -----------------------------------------------------------------------------
# 3. Engine node (node 2) — clone from node 1 so keys + config match
# -----------------------------------------------------------------------------
function clone_engine() {
    if [[ -x "${PINGFED2_DIR}/bin/run.sh" ]]; then
        info "Node 2 already present at ${PINGFED2_DIR} — re-syncing config (keys/data) from node 1"
    else
        info "Cloning node 1 -> node 2 at ${PINGFED2_DIR}..."
    fi
    # Stop engine if running so files are quiescent during sync.
    if [[ -f "$PF2_PID" ]] && ss -ltn 2>/dev/null | grep -q ":${PINGFED2_ENGINE_PORT} "; then
        stop_pf "$PINGFED2_DIR" "$PF2_PID" "node 2 (engine)" "$PINGFED2_ENGINE_PORT"
    fi
    mkdir -p "$PINGFED2_DIR"
    rsync -a --delete \
        --exclude 'log/' --exclude 'logs/' \
        --exclude 'bin/pingfederate.pid' \
        --exclude 'run.lck' \
        "${PF1_DIR}/" "${PINGFED2_DIR}/"
    success "Node 2 filesystem synced from node 1"
}

function configure_engine() {
    info "Configuring node 2 as CLUSTERED_ENGINE..."
    set_prop "$PF2_RP" pf.operational.mode CLUSTERED_ENGINE
    set_prop "$PF2_RP" pf.cluster.node.index 2
    set_prop "$PF2_RP" pf.cluster.auth.pwd "$CLUSTER_KEY"
    set_prop "$PF2_RP" pf.cluster.bind.port "$PINGFED_CLUSTER_BIND_PORT_2"
    set_prop "$PF2_RP" pf.cluster.failure.detection.bind.port "$PINGFED_CLUSTER_FAILOVER_PORT_2"
    set_prop "$PF2_RP" pf.cluster.transport.protocol tcp
    set_prop "$PF2_RP" pf.cluster.tcp.discovery.initial.hosts "$DISCOVERY"
    # Engine runtime port (node 1 keeps 9031); admin port shifted off 9999 since
    # engines don't serve the admin console but the port is still configured.
    set_prop "$PF2_RP" pf.https.port "$PINGFED2_ENGINE_PORT"
    set_prop "$PF2_RP" pf.admin.https.port 9998
    # Right-size the co-located engine's heap.
    printf '%s\n%s\n' "-Xmx${PINGFED2_MAX_HEAP:-768m}" "-XX:+UseG1GC" \
        > "${PINGFED2_DIR}/bin/jvm-memory.options"
    success "Engine configured (node.index=2, runtime ${PINGFED2_ENGINE_PORT}, bind ${PINGFED_CLUSTER_BIND_PORT_2})"
}

# -----------------------------------------------------------------------------
# 4. Bring the cluster up + push config to the engine
# -----------------------------------------------------------------------------
function bring_up() {
    # Restart console to apply CLUSTERED_CONSOLE mode.
    stop_pf "$PF1_DIR" "$PF1_PID" "node 1 (console)" "$PINGFED_ADMIN_PORT"
    start_pf "$PF1_DIR" "$PF_RUN_LOG_1" "node 1 (console)" \
        "https://${PINGFED_HOSTNAME}:${PINGFED_ADMIN_PORT}/pingfederate/app"
    pf_ready 40 5 || { error "console admin API not ready"; return 1; }

    # Start engine; heartbeat on its runtime port signals readiness.
    start_pf "$PINGFED2_DIR" "$PF_RUN_LOG_2" "node 2 (engine)" \
        "https://${PINGFED_HOSTNAME}:${PINGFED2_ENGINE_PORT}/pf/heartbeat.ping"
}

function join_and_replicate() {
    info "Checking cluster membership (console view)..."
    local i=0 nodes=0
    while [[ $i -lt 12 ]]; do
        local body; body=$(pf_request GET /cluster/status 2>/dev/null)
        nodes=$(echo "$body" | grep -oiE '"(mode|nodeIndex|address)"' | grep -ic node || true)
        if echo "$body" | grep -qi 'CLUSTERED_ENGINE'; then
            success "Engine node visible in cluster status"; break
        fi
        sleep 5; ((i++)) || true
    done

    info "Replicating configuration console -> engine(s)..."
    local tmp; tmp=$(mktemp)
    pf_request POST /cluster/replicate > "$tmp" 2>/dev/null
    if [[ "$_PING_HTTP_CODE" =~ ^20 ]]; then
        success "Configuration replicated to engine(s) (HTTP $_PING_HTTP_CODE)"
    else
        warning "Config replicate returned HTTP $_PING_HTTP_CODE: $(head -c 200 "$tmp") (engine already has cloned config)"
    fi
    rm -f "$tmp"
    info "Cluster status:"
    pf_request GET /cluster/status 2>/dev/null | python3 -m json.tool 2>/dev/null | sed 's/^/    /' | head -40 || true
}

# -----------------------------------------------------------------------------
section "PingFederate — clustering (console + engine)"
if [[ "${PINGFED_COUNT:-1}" -le 1 ]]; then
    info "PINGFED_COUNT=${PINGFED_COUNT:-1} — single node, nothing to cluster"; exit 0
fi
[[ -n "$HOSTIP" ]] || { error "could not determine non-loopback host IP for cluster discovery"; exit 1; }
ensure_cluster_key
configure_console
clone_engine
configure_engine
bring_up
join_and_replicate
success "PingFederate cluster ready (console node 1 + engine node 2)"
