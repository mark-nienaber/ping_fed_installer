#!/bin/bash
set -euo pipefail

################################################################################
# Script Name: ping-setup.sh
# Description: Host prerequisites for the PingDirectory + PingFederate +
#              PingAccess installer. Installs a supported JDK (21 LTS by
#              default), creates the install user, base/product/log directories,
#              /etc/hosts entries, and the OS limits PingDirectory needs.
#
#              Run this ONCE on a fresh host before ./bin/install_ping.sh.
#
# Usage:
#   ./bin/ping-setup.sh            # full prerequisite setup
#   ./bin/ping-setup.sh java       # JDK only
#   ./bin/ping-setup.sh limits     # OS limits only
################################################################################

# Load configuration + logging (run from repo root or bin/)
if [[ -f ./pingconfig.env ]]; then
    source ./pingconfig.env
else
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pingconfig.env"
fi
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "${_LIB_DIR}/logging.sh"

# Don't leak passwords into shell history
set +H; unset HISTFILE 2>/dev/null || true

# JDK major version to install (21 LTS — supported by PD 11 / PF 13.1 / PA 9.1)
JDK_VERSION="${JDK_VERSION:-21}"

# -----------------------------------------------------------------------------
# JDK installation (cross-distro)
# -----------------------------------------------------------------------------
function install_java() {
    info "Ensuring OpenJDK ${JDK_VERSION} is installed..."

    if command -v java &>/dev/null; then
        local cur
        cur=$(java -version 2>&1 | head -n1 | awk -F '"' '{print $2}')
        if [[ "$cur" =~ ^${JDK_VERSION}\. ]]; then
            success "OpenJDK ${JDK_VERSION} already active (version: $cur)"
            _set_java_home; return 0
        fi
        info "Found Java $cur — installing OpenJDK ${JDK_VERSION}..."
    fi

    if command -v apt-get &>/dev/null; then
        sudo apt-get update -y
        sudo apt-get install -y "openjdk-${JDK_VERSION}-jdk"
    elif command -v dnf &>/dev/null; then
        if [[ -f /etc/os-release ]] && grep -q "ID.*amazon" /etc/os-release; then
            sudo dnf install -y --allowerasing "java-${JDK_VERSION}-amazon-corretto-devel"
        else
            sudo dnf install -y --allowerasing "java-${JDK_VERSION}-openjdk" "java-${JDK_VERSION}-openjdk-devel"
        fi
    elif command -v yum &>/dev/null; then
        sudo yum install -y "java-${JDK_VERSION}-openjdk" "java-${JDK_VERSION}-openjdk-devel"
    elif command -v zypper &>/dev/null; then
        sudo zypper install -y "java-${JDK_VERSION}-openjdk" "java-${JDK_VERSION}-openjdk-devel"
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm "jdk${JDK_VERSION}-openjdk"
    else
        error "No supported package manager found for JDK installation"; return 1
    fi

    # Make the freshly installed JDK the default (RPM alternatives).
    # Pick the VERSIONED dir (e.g. java-21-openjdk-21.0.11...), not the
    # unversioned symlink (java-21-openjdk) — RPM registers the alternative
    # under the versioned path, so `--set` on the symlink path silently fails.
    local newjava
    newjava=$(ls -d /usr/lib/jvm/java-${JDK_VERSION}-openjdk-* /usr/lib/jvm/java-${JDK_VERSION}-amazon-corretto-* 2>/dev/null \
              | grep -E "java-${JDK_VERSION}-(openjdk|amazon-corretto)-[0-9]" | sort -V | tail -1)
    if [[ -n "$newjava" && -x "$newjava/bin/java" ]] && command -v alternatives &>/dev/null; then
        sudo alternatives --install /usr/bin/java  java  "$newjava/bin/java"  2100 || true
        sudo alternatives --set     java  "$newjava/bin/java"  2>/dev/null || true
        [[ -x "$newjava/bin/javac" ]] && sudo alternatives --install /usr/bin/javac javac "$newjava/bin/javac" 2100 || true
        [[ -x "$newjava/bin/javac" ]] && sudo alternatives --set javac "$newjava/bin/javac" 2>/dev/null || true
    fi

    _set_java_home

    local installed
    installed=$(java -version 2>&1 | head -n1 | awk -F '"' '{print $2}')
    if [[ "$installed" =~ ^${JDK_VERSION}\. ]]; then
        success "OpenJDK ${JDK_VERSION} installed (version: $installed)"
    else
        error "Expected JDK ${JDK_VERSION}, active java is $installed"; return 1
    fi
}

function _set_java_home() {
    local jh
    jh=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")
    [[ -d "$jh" ]] || return 0
    export JAVA_HOME="$jh"
    echo "export JAVA_HOME=$jh" | sudo tee /etc/profile.d/ping-java.sh >/dev/null
    sudo chmod +x /etc/profile.d/ping-java.sh
    if id "$INSTALL_USER" &>/dev/null; then
        sudo -u "$INSTALL_USER" bash -c "grep -q 'JAVA_HOME=$jh' ~/.bashrc 2>/dev/null || echo 'export JAVA_HOME=$jh' >> ~/.bashrc"
    fi
    success "JAVA_HOME set to $jh"
}

# -----------------------------------------------------------------------------
# Install user
# -----------------------------------------------------------------------------
function create_install_user() {
    info "Checking/creating install user: $INSTALL_USER..."
    if id "$INSTALL_USER" &>/dev/null; then
        success "User $INSTALL_USER already exists"
    else
        sudo useradd -m -s /bin/bash "$INSTALL_USER"
        success "Created user $INSTALL_USER"
    fi
    sudo usermod -a -G wheel "$INSTALL_USER" 2>/dev/null || true
    sudo usermod -a -G sudo  "$INSTALL_USER" 2>/dev/null || true
    # Passwordless sudo for install operations
    echo "$INSTALL_USER ALL=(ALL) NOPASSWD: ALL" | sudo tee "/etc/sudoers.d/$INSTALL_USER" >/dev/null
    sudo chmod 440 "/etc/sudoers.d/$INSTALL_USER"
}

# -----------------------------------------------------------------------------
# Directories
# -----------------------------------------------------------------------------
function create_directories() {
    info "Creating base, product and log directories..."
    local dirs=("$BASE_INSTALL_DIR" "$PINGDIR_DIR" "$PINGFED_DIR" "$PINGACCESS_DIR" "$LOG_DIR" "/tmp/ping-installer")
    for d in "${dirs[@]}"; do
        sudo mkdir -p "$d"
        sudo chown -R "$INSTALL_USER":"$INSTALL_USER" "$d"
        sudo chmod -R 755 "$d"
    done
    success "Directories created under $BASE_INSTALL_DIR (owned by $INSTALL_USER)"
}

# -----------------------------------------------------------------------------
# /etc/hosts
# -----------------------------------------------------------------------------
function update_hosts() {
    info "Ensuring hostnames resolve via /etc/hosts..."
    [[ -f /etc/hosts.ping.backup ]] || sudo cp /etc/hosts /etc/hosts.ping.backup
    local names=("$PING_HOSTNAME" "$PINGDIR_HOSTNAME" "$PINGFED_HOSTNAME" "$PINGACCESS_HOSTNAME" "$SAMPLE_APP_VIRTUAL_HOST")
    for n in "${names[@]}"; do
        [[ -z "$n" ]] && continue
        if ! grep -qE "^[0-9.]+\s+.*\b${n}\b" /etc/hosts; then
            echo "127.0.0.1  $n" | sudo tee -a /etc/hosts >/dev/null
            info "  added 127.0.0.1 $n"
        fi
    done
    success "/etc/hosts updated"
}

# -----------------------------------------------------------------------------
# OS limits — PingDirectory needs high file-descriptor + process limits
# (setup warns when the process limit is below 16383)
# -----------------------------------------------------------------------------
function set_system_limits() {
    info "Configuring OS limits for PingDirectory ($INSTALL_USER)..."
    sudo tee /etc/security/limits.d/ping.conf >/dev/null <<EOF
# PingDirectory / Ping stack runtime limits
$INSTALL_USER  soft  nofile  65535
$INSTALL_USER  hard  nofile  65535
$INSTALL_USER  soft  nproc   16383
$INSTALL_USER  hard  nproc   16383
EOF
    # Bump system-wide fs.file-max if lower than desired
    local want=1000000
    local have; have=$(cat /proc/sys/fs/file-max 2>/dev/null || echo 0)
    if [[ "$have" -lt "$want" ]]; then
        echo "fs.file-max = $want" | sudo tee /etc/sysctl.d/60-ping.conf >/dev/null
        sudo sysctl -p /etc/sysctl.d/60-ping.conf >/dev/null 2>&1 || true
    fi
    success "OS limits configured (nofile=65535, nproc=16383) — re-login for shell limits to apply"
}

# -----------------------------------------------------------------------------
# Firewall — open the stack's client-facing ports. Without this, firewalld (on by
# default on RHEL/CentOS) blocks every product port to remote machines even
# though the services bind 0.0.0.0, so admin consoles / the app are unreachable
# from anywhere but the host itself. Inter-node ports (PD replication 8989/8990,
# PF JGroups 7600-7702) stay closed — they only need localhost on this demo.
# -----------------------------------------------------------------------------
function configure_firewall() {
    if ! command -v firewall-cmd >/dev/null 2>&1 || ! sudo systemctl is-active --quiet firewalld 2>/dev/null; then
        info "firewalld not active — skipping (ensure ports are reachable by other means)"
        return 0
    fi
    info "Opening stack ports in firewalld..."
    # PD (both nodes): LDAP/LDAPS/Admin-API. PF: admin + engine (+node 2 engine).
    # PA: admin/engine/agent. LB: 443.
    local ports=(
        "$PINGDIR_LDAP_PORT" "$PINGDIR_LDAPS_PORT" "$PINGDIR_HTTPS_PORT"
        "$PINGFED_ADMIN_PORT" "$PINGFED_ENGINE_PORT"
        "$PINGACCESS_ADMIN_PORT" "$PINGACCESS_ENGINE_PORT" "$PINGACCESS_AGENT_PORT"
    )
    [[ "${PINGDIR_COUNT:-1}" -gt 1 ]] && ports+=("$PINGDIR2_LDAP_PORT" "$PINGDIR2_LDAPS_PORT" "$PINGDIR2_HTTPS_PORT")
    [[ "${PINGFED_COUNT:-1}" -gt 1 ]] && ports+=("$PINGFED2_ENGINE_PORT")
    [[ "${LB_ENABLED:-false}" == "true" ]] && ports+=("$LB_HTTPS_PORT")
    local p
    for p in "${ports[@]}"; do
        [[ -n "$p" ]] && sudo firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1
    done
    sudo firewall-cmd --reload >/dev/null
    success "firewalld ports open: $(sudo firewall-cmd --list-ports)"
}

# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------
function run_all() {
    banner "Ping Installer — Host Prerequisites"
    step_init 6
    step_begin "Create install user";        create_install_user;  step_end
    step_begin "Install OpenJDK ${JDK_VERSION}"; install_java;      step_end
    step_begin "Create directories";          create_directories;  step_end
    step_begin "Update /etc/hosts";           update_hosts;         step_end
    step_begin "Configure OS limits";         set_system_limits;    step_end
    step_begin "Open firewall ports";         configure_firewall;   step_end
    success "Host prerequisites complete — you can now run ./bin/install_ping.sh --all"
}

case "${1:-all}" in
    all)      run_all ;;
    java)     install_java ;;
    user)     create_install_user ;;
    dirs)     create_directories ;;
    hosts)    update_hosts ;;
    limits)   set_system_limits ;;
    firewall) configure_firewall ;;
    *) echo "Usage: $0 {all|java|user|dirs|hosts|limits|firewall}"; exit 1 ;;
esac
