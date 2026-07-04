#!/bin/sh
# ============================================================================
#   wm-help.sh – diagnostic helper for wanmon
#   (C) 2026 Pavel Bashkardin
# ============================================================================

CONFIG_DIR="/etc/wanmon"
STATE_DIR="/tmp/wanmon"
CONFIG_FILE="$CONFIG_DIR/config.json"

# Global pretty mode flag (0 = raw, 1 = pretty)
PRETTY=0

# ----------------------------------------------------------------------------
#   print_section() – print a header line
# ----------------------------------------------------------------------------
print_section() {
    echo
    echo "=== $1 ==="
    echo
}

# ----------------------------------------------------------------------------
#   show_config() – show current configuration
# ----------------------------------------------------------------------------
show_config() {
    if [ $PRETTY -eq 1 ]; then
        print_section "Configuration"
        if [ -f "$CONFIG_FILE" ]; then
            echo "  interval            : $(jq -r '.interval // "N/A"' "$CONFIG_FILE")s"
            echo "  ping_host           : $(jq -r '.ping_host // "N/A"' "$CONFIG_FILE")"
            echo "  ping_timeout        : $(jq -r '.ping_timeout // "N/A"' "$CONFIG_FILE")s"
            echo "  ping_samples        : $(jq -r '.ping_samples // "N/A"' "$CONFIG_FILE")"
            echo "  smooth_window       : $(jq -r '.smooth_window // "N/A"' "$CONFIG_FILE")"
            echo "  hysteresis_threshold: $(jq -r '.hysteresis_threshold // "N/A"' "$CONFIG_FILE")"
            echo "  loss_divisor        : $(jq -r '.loss_divisor // "N/A"' "$CONFIG_FILE")"
            echo "  hard_loss_limit     : $(jq -r '.hard_loss_limit // "N/A"' "$CONFIG_FILE")%"
            echo "  dead_score          : $(jq -r '.dead_score // "N/A"' "$CONFIG_FILE")"
            echo "  default_metric      : $(jq -r '.default_metric // "N/A"' "$CONFIG_FILE")"
            echo "  backup_metric       : $(jq -r '.backup_metric // "N/A"' "$CONFIG_FILE")"
        else
            echo "  File not found: $CONFIG_FILE"
        fi
    else
        print_section "Configuration (config.json)"
        if [ -f "$CONFIG_FILE" ]; then
            jq '.' "$CONFIG_FILE"
        else
            echo "File not found: $CONFIG_FILE"
        fi
    fi
}

# ----------------------------------------------------------------------------
#   show_ifaces() – show interface policy (weights)
# ----------------------------------------------------------------------------
show_ifaces() {
    if [ $PRETTY -eq 1 ]; then
        print_section "Interface weights (policy)"
        if [ -f "$CONFIG_DIR/ifaces.json" ]; then
            jq -r 'to_entries[] | "  \(.key): \(.value)"' "$CONFIG_DIR/ifaces.json"
        else
            echo "  File not found: $CONFIG_DIR/ifaces.json"
        fi
    else
        print_section "Interface policy (ifaces.json)"
        if [ -f "$CONFIG_DIR/ifaces.json" ]; then
            jq '.' "$CONFIG_DIR/ifaces.json"
        else
            echo "File not found: $CONFIG_DIR/ifaces.json"
        fi
    fi
}

# ----------------------------------------------------------------------------
#   show_state() – show current telemetry (latency, loss, jitter)
# ----------------------------------------------------------------------------
show_state() {
    if [ $PRETTY -eq 1 ]; then
        print_section "Current telemetry"
        if [ -f "$STATE_DIR/state.json" ]; then
            jq -r 'to_entries[] | "  \(.key): latency \(.value.latency)ms, loss \(.value.loss)%, jitter \(.value.jitter)ms"' "$STATE_DIR/state.json"
        else
            echo "  File not found: $STATE_DIR/state.json"
        fi
    else
        print_section "Current telemetry (state.json)"
        if [ -f "$STATE_DIR/state.json" ]; then
            jq '.' "$STATE_DIR/state.json"
        else
            echo "File not found: $STATE_DIR/state.json"
        fi
    fi
}

# ----------------------------------------------------------------------------
#   show_decision() – show current decision and scores
# ----------------------------------------------------------------------------
show_decision() {
    if [ $PRETTY -eq 1 ]; then
        print_section "Current decision"
        if [ -f "$STATE_DIR/decision.json" ]; then
            pref=$(jq -r '.preferred // "none"' "$STATE_DIR/decision.json")
            echo "  Preferred: $pref"
            jq -r 'to_entries | map(select(.key != "preferred")) | .[] | "  \(.key) score: \(.value)"' "$STATE_DIR/decision.json"
        else
            echo "  File not found: $STATE_DIR/decision.json"
        fi
    else
        print_section "Current decision (decision.json)"
        if [ -f "$STATE_DIR/decision.json" ]; then
            jq '.' "$STATE_DIR/decision.json"
        else
            echo "File not found: $STATE_DIR/decision.json"
        fi
    fi
}

# ----------------------------------------------------------------------------
#   show_route() – show current default routes (kernel)
# ----------------------------------------------------------------------------
show_route() {
    if [ $PRETTY -eq 1 ]; then
        print_section "Default route status"
        # Get only default routes
        default_lines=$(ip route show default | grep '^default')
        if [ -z "$default_lines" ]; then
            echo "  No default routes defined"
            return
        fi

        primary_dev=""; primary_gw=""
        backup_dev=""; backup_gw=""; backup_metric=""

        while IFS= read -r line; do
            # Extract dev, via, metric
            dev=$(echo "$line" | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); break}}}')
            via=$(echo "$line" | awk '{for(i=1;i<=NF;i++){if($i=="via"){print $(i+1); break}}}')
            metric=$(echo "$line" | awk '{for(i=1;i<=NF;i++){if($i=="metric"){print $(i+1); break}}}')
            if [ -z "$metric" ]; then
                # primary
                primary_dev="$dev"
                primary_gw="$via"
            else
                backup_dev="$dev"
                backup_gw="$via"
                backup_metric="$metric"
            fi
        done <<EOF
$default_lines
EOF

        # Resolve logical interface names
        get_iface() {
            dev="$1"
            if [ -n "$dev" ]; then
                iface=$(uci -q show network | grep ".device='$dev'" | sed -n "s/network\.\(.*\)\.device=.*/\1/p" | head -1)
                if [ -z "$iface" ]; then
                    iface="$dev"
                fi
                echo "$iface"
            else
                echo "none"
            fi
        }

        primary_iface=$(get_iface "$primary_dev")
        backup_iface=$(get_iface "$backup_dev")

        echo "  Primary : $primary_iface (dev $primary_dev, gw $primary_gw)"
        if [ -n "$backup_dev" ]; then
            echo "  Backup  : $backup_iface (dev $backup_dev, gw $backup_gw, metric $backup_metric)"
        else
            echo "  Backup  : none"
        fi
    else
        print_section "Current default routes (kernel)"
        default_routes=$(ip route show default)
        if [ -n "$default_routes" ]; then
            echo "$default_routes" | while read -r line; do
                if echo "$line" | grep -q "metric"; then
                    echo "  [backup]  $line"
                else
                    echo "  [primary] $line"
                fi
            done
        else
            echo "No default routes defined"
        fi
    fi
}

# ----------------------------------------------------------------------------
#   show_metrics() – show interface metrics from UCI and from routing table
# ----------------------------------------------------------------------------
show_metrics() {
    if [ $PRETTY -eq 1 ]; then
        print_section "Interface metrics (UCI)"
        uci_metrics=$(uci show network | grep '.metric=' | sed 's/^network\.//')
        if [ -n "$uci_metrics" ]; then
            echo "$uci_metrics" | while read -r line; do
                echo "  $line"
            done
        else
            echo "  No UCI metrics defined"
        fi

        print_section "Interface metrics (kernel routing table)"
        route_metrics=$(ip route show default | awk '{print "dev "$5" metric "$NF}' | sort -u)
        if [ -n "$route_metrics" ]; then
            echo "$route_metrics" | while read -r line; do
                echo "  $line"
            done
        else
            echo "  No default routes with metrics"
        fi
    else
        print_section "Interface metrics (UCI)"
        uci show network | grep '.metric=' | sed 's/^network\.//'

        print_section "Interface metrics (routing table – default routes only)"
        ip route show default | awk '{print "dev "$5" metric "$NF}' | sort -u
    fi
}

# ----------------------------------------------------------------------------
#   show_help() – print usage information
# ----------------------------------------------------------------------------
show_help() {
    cat <<EOF
wanmon diagnostic helper

Usage: wm-help.sh [OPTION]...

Options:
  --config      Show current configuration
  --ifaces      Show interface policy (weights from ifaces.json)
  --state       Show current telemetry (latency, loss, jitter)
  --decision    Show current decision and scores (decision.json)
  --route       Show current default routes (kernel)
  --metrics     Show interface metrics (UCI and kernel)
  --all         Show all sections (including config)
  --pretty      Format output in a human-readable table style
  --help        Show this help

If no option is given, this help is displayed.

Examples:
  wm-help.sh --route
  wm-help.sh --ifaces --state
  wm-help.sh --all --pretty   (show everything in pretty format)

Files:
  /etc/wanmon/config.json     – main configuration
  /etc/wanmon/ifaces.json     – interface weights (policy)
  /tmp/wanmon/state.json      – raw measurements
  /tmp/wanmon/decision.json   – scores and preferred interface
  /tmp/wanmon/history/        – score history per interface
  /tmp/wanmon/last_pref       – last preferred interface (for hysteresis)

Logs: use 'logread | grep wm-'
EOF
}

# ----------------------------------------------------------------------------
#   Main: parse arguments
# ----------------------------------------------------------------------------
# First pass: detect --pretty and remove it from the argument list
args=""
for arg in "$@"; do
    case "$arg" in
        --pretty) PRETTY=1 ;;
        *) args="$args $arg" ;;
    esac
done
# Recreate argument list without --pretty
set -- $args

if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

# Process remaining arguments
for arg in "$@"; do
    case "$arg" in
        --config)   show_config ;;
        --ifaces)   show_ifaces ;;
        --state)    show_state ;;
        --decision) show_decision ;;
        --route)    show_route ;;
        --metrics)  show_metrics ;;
        --all)      show_config
                    show_ifaces
                    show_state
                    show_decision
                    show_route
                    show_metrics
                    ;;
        --help)     show_help ;;
        *)          echo "Unknown option: $arg" >&2
                    echo "Try 'wm-help.sh --help'" >&2
                    exit 1
                    ;;
    esac
done