#!/usr/bin/env bash
#==============================================================================
# devcontainer-forward.sh
#
# Automatically detect Docker containers started via VS Code Dev Containers,
# identify their forwardPorts from devcontainer.json, and create iptables rules
# for direct host access.
#
# Use case: When VS Code runs in a VM (e.g., on Proxmox) with devcontainers,
# this script allows access to the devcontainer's services (like web apps on port 3000)
# from outside the VM, such as from your local machine (iMac), by forwarding
# ports from the VM's IP to the internal container IPs.
#
# Modes:
#   --check   : Validate required dependencies only.
#   --dry-run : Simulate full detection and rule generation. No system changes.
#   --run     : Apply iptables and NAT rules, showing exactly what was done.
#   --install : Perform run, then install as a persistent systemd service.
#   --status  : Show current forwarding status and service state.
#   --uninstall : Remove the systemd service and clear all rules/files.
#
# Logs activity to /var/log/devcontainer-forward.log
# Safe to re-run; old rules are automatically removed before reapplying.
#==============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------
LOG_FILE="/var/log/devcontainer-forward.log"
STATE_FILE="/var/lib/devcontainer-forward/state.json"
TMP_STATE_FILE="$(mktemp)"
SERVICE_FILE="/etc/systemd/system/devcontainer-forward.service"
CHAIN_NAT="DEVCONTAINER_FWD_NAT"
CHAIN_FILTER="DEVCONTAINER_FWD_FILTER"
IPTABLES_CMD="$(command -v iptables || true)"
DOCKER_CMD="$(command -v docker || true)"
JQ_CMD="$(command -v jq || true)"

MODE=""
for arg in "$@"; do
    case "$arg" in
        --check) MODE="check" ;;
        --dry-run) MODE="dry-run" ;;
        --run) MODE="run" ;;
        --install) MODE="install" ;;
        --status) MODE="status" ;;
        --uninstall) MODE="uninstall" ;;
        -h|--help)
            echo "Usage: $0 [--check|--dry-run|--run|--install|--status|--uninstall]"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: $0 [--check|--dry-run|--run|--install|--status|--uninstall]"
            exit 1
            ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "No mode specified. Use --dry-run, --run, or --install."
    exit 1
fi

#------------------------------------------------------------------------------
# Functions
#------------------------------------------------------------------------------

log() {
    local msg="$1"
    echo "$(date '+%F %T') $msg" | tee -a "$LOG_FILE"
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "This script must be run as root."
        exit 1
    fi
}

check_dependencies() {
    local missing=0
    for cmd in iptables docker jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Missing dependency: $cmd"
            missing=1
        fi
    done
    if [ $missing -ne 0 ]; then
        echo "One or more required commands are missing."
        exit 1
    fi
}

show_status() {
    echo "Devcontainer Forwarding Status"
    echo "=============================="
    if [ -f "$STATE_FILE" ]; then
        local count
        count=$(jq length "$STATE_FILE" 2>/dev/null || echo 0)
        echo "Active forwards: $count"
        jq -r '.[] | "  \(.port) -> \(.target) (\(.container_name))"' "$STATE_FILE" 2>/dev/null || echo "  No valid forwards."
    else
        echo "No forwards applied."
    fi
    echo
    echo "Service status:"
    if systemctl is-active --quiet devcontainer-forward.service 2>/dev/null; then
        echo "  Systemd service: Running"
    elif systemctl is-enabled --quiet devcontainer-forward.service 2>/dev/null; then
        echo "  Systemd service: Installed (not running)"
    else
        echo "  Systemd service: Not installed"
    fi
    echo
    echo "Iptables chains: Configured"
}

iptables_exec() {
    # Wrapper to simulate or execute iptables commands
    if [ "$MODE" = "dry-run" ]; then
        echo "[DRY-RUN] $IPTABLES_CMD $*" | tee -a "$LOG_FILE"
    else
        log "iptables: $*"
        $IPTABLES_CMD "$@"
    fi
}

setup_chains() {
    # Create chains if missing
    iptables_exec -t nat -N "$CHAIN_NAT" 2>/dev/null || true
    iptables_exec -N "$CHAIN_FILTER" 2>/dev/null || true
    # Ensure jump rules exist
    iptables_exec -t nat -C PREROUTING -j "$CHAIN_NAT" 2>/dev/null || \
        iptables_exec -t nat -A PREROUTING -j "$CHAIN_NAT"
    iptables_exec -D FORWARD -j "$CHAIN_FILTER" 2>/dev/null || true
    iptables_exec -I FORWARD 2 -j "$CHAIN_FILTER"
}

clear_old_rules() {
    log "Clearing old forwarding rules..."
    iptables_exec -t nat -F "$CHAIN_NAT" || true
    iptables_exec -F "$CHAIN_FILTER" || true
}

detect_containers() {
    log "Detecting containers and exposed ports..."
    $DOCKER_CMD ps --format '{{.ID}} {{.Names}}' | while read -r id name; do
        local ports
        ports="$($DOCKER_CMD inspect --format '{{json .NetworkSettings.Ports}}' "$id" | \
                 $JQ_CMD -r 'to_entries[] | select(.value != null) | .key' 2>/dev/null || true)"
        local ip
        ip="$($DOCKER_CMD inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$id")"
        [ -z "$ip" ] && continue
        for port_proto in $ports; do
            local port="${port_proto%/*}"
            local proto="${port_proto#*/}"
            local host_ip
            host_ip="$(hostname -I | awk '{print $1}')"
            local url="http://${host_ip}:${port}"
            echo "{\"container_id\":\"$id\",\"container_name\":\"$name\",\"target\":\"${ip}:${port}\",\"port\":${port},\"proto\":\"${proto}\",\"url\":\"${url}\"}" >>"$TMP_STATE_FILE"
        done
        # Check for devcontainer metadata and forwardPorts
        local metadata
        metadata="$($DOCKER_CMD inspect --format '{{index .Config.Labels "devcontainer.metadata"}}' "$id")"
        if [ -n "$metadata" ]; then
            local forward_ports
            forward_ports="$(echo "$metadata" | $JQ_CMD -r '.[] | .forwardPorts // empty | .[]' 2>/dev/null || true)"
            local host_ip
            host_ip="$(hostname -I | awk '{print $1}')"
            for port in $forward_ports; do
                local url="http://${host_ip}:${port}"
                echo "{\"container_id\":\"$id\",\"container_name\":\"$name\",\"target\":\"${ip}:${port}\",\"port\":${port},\"proto\":\"tcp\",\"url\":\"${url}\"}" >>"$TMP_STATE_FILE"
            done
        fi
    done
}

apply_rules() {
    local json_array
    json_array="$(jq -s . "$TMP_STATE_FILE" 2>/dev/null || echo "[]")"
    echo "$json_array" >"$TMP_STATE_FILE"

    if [ "$MODE" = "dry-run" ]; then
        echo
        echo "Dry-run complete. The following forwards would be active:"
        jq . "$TMP_STATE_FILE"
        echo "No changes were made."
        return
    fi

    jq -c '.[]' "$TMP_STATE_FILE" | while read -r item; do
        local port proto target
        port=$(echo "$item" | jq -r '.port')
        proto=$(echo "$item" | jq -r '.proto')
        target=$(echo "$item" | jq -r '.target')
        iptables_exec -t nat -A "$CHAIN_NAT" -p "$proto" --dport "$port" -j DNAT --to-destination "$target"
        iptables_exec -A "$CHAIN_FILTER" -p "$proto" -d "${target%:*}" --dport "$port" -j ACCEPT
    done

    mkdir -p "$(dirname "$STATE_FILE")"
    cp "$TMP_STATE_FILE" "$STATE_FILE"
    log "Applied $(jq length "$STATE_FILE") forward rules."
    echo
    echo "Rules applied successfully:"
    jq . "$STATE_FILE"
}

install_service() {
    log "Installing as systemd service..."
    # Copy script to system location
    cp "$(realpath "$0")" /usr/local/bin/devcontainer-forward.sh
    chmod +x /usr/local/bin/devcontainer-forward.sh
    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Devcontainer Forwarding Service
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/devcontainer-forward.sh --run

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable devcontainer-forward.service
    systemctl start devcontainer-forward.service
    log "Service installed and started."
}

uninstall_service() {
    log "Uninstalling systemd service..."
    systemctl stop devcontainer-forward.service 2>/dev/null || true
    systemctl disable devcontainer-forward.service 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    log "Clearing iptables rules..."
    # Flush the chains
    iptables_exec -t nat -F "$CHAIN_NAT" 2>/dev/null || true
    iptables_exec -F "$CHAIN_FILTER" 2>/dev/null || true
    # Remove jumps
    iptables_exec -t nat -D PREROUTING -j "$CHAIN_NAT" 2>/dev/null || true
    iptables_exec -D FORWARD -j "$CHAIN_FILTER" 2>/dev/null || true
    # Delete chains
    iptables_exec -t nat -X "$CHAIN_NAT" 2>/dev/null || true
    iptables_exec -X "$CHAIN_FILTER" 2>/dev/null || true
    log "Removing system files..."
    rm -f /usr/local/bin/devcontainer-forward.sh
    rm -f "$STATE_FILE"
    rm -f "$LOG_FILE"
    log "Uninstallation complete."
}

#------------------------------------------------------------------------------
# Main execution
#------------------------------------------------------------------------------

require_root
check_dependencies

case "$MODE" in
    check)
        echo "Dependency check complete. All required tools found."
        exit 0
        ;;
    dry-run)
        log "Running in dry-run mode..."
        setup_chains
        clear_old_rules
        detect_containers
        apply_rules
        ;;
    run)
        log "Running in live mode..."
        setup_chains
        clear_old_rules
        detect_containers
        apply_rules
        ;;
    install)
        log "Installing as persistent service..."
        setup_chains
        clear_old_rules
        detect_containers
        apply_rules
        install_service
        ;;
    status)
        show_status
        ;;
    uninstall)
        uninstall_service
        ;;
esac

exit 0
