#!/bin/sh
# ============================================================================
#   wm-apply.sh – apply default route based on decision.json or user request
#   (C) 2026 Pavel Bashkardin
# ============================================================================

CONFIG_DIR="/etc/wanmon"
CONFIG_FILE="$CONFIG_DIR/config.json"
IFACES_FILE="$CONFIG_DIR/ifaces.json"
STATE_DIR="/tmp/wanmon"
STATE_FILE="$STATE_DIR/decision.json"
LOCK_FILE="/tmp/wm-apply.lock"
LOGTAG="wm-apply"

# ----------------------------------------------------------------------------
# Read backup metric from config (fallback 20)
# ----------------------------------------------------------------------------
if [ -f "$CONFIG_FILE" ]; then
    BACKUP_METRIC=$(jq -r '.backup_metric // 20' "$CONFIG_FILE")
else
    BACKUP_METRIC=20
fi

# ----------------------------------------------------------------------------
# Prevent parallel runs
# ----------------------------------------------------------------------------
[ -f "$LOCK_FILE" ] && exit 0
touch "$LOCK_FILE"

# ----------------------------------------------------------------------------
# Parse command line arguments
# ----------------------------------------------------------------------------
USER_REQUEST=""
case $# in
    0)
        # No user request – use decision.json
        ;;
    1)
        USER_REQUEST="$1"
        ;;
    *)
        echo "Error: too many arguments. Usage: wm-apply.sh [iface]" >&2
        logger -t "$LOGTAG" "Too many arguments"
        rm -f "$LOCK_FILE"
        exit 1
        ;;
esac

# ----------------------------------------------------------------------------
# If user requested a specific interface, validate it against ifaces.json
# ----------------------------------------------------------------------------
if [ -n "$USER_REQUEST" ]; then
    if [ ! -f "$IFACES_FILE" ]; then
        echo "Error: ifaces.json not found, cannot validate interface" >&2
        logger -t "$LOGTAG" "ifaces.json not found"
        rm -f "$LOCK_FILE"
        exit 1
    fi

    if ! jq -e ".\"$USER_REQUEST\"" "$IFACES_FILE" >/dev/null 2>&1; then
        echo "Error: interface '$USER_REQUEST' not found in ifaces.json" >&2
        logger -t "$LOGTAG" "User requested unknown interface: $USER_REQUEST"
        rm -f "$LOCK_FILE"
        exit 1
    fi

    # Check if the interface actually exists in the system (via ifstatus or ip link)
    if ! ifstatus "$USER_REQUEST" >/dev/null 2>&1 && ! ip link show "$USER_REQUEST" >/dev/null 2>&1; then
        echo "Error: interface '$USER_REQUEST' does not exist in the system" >&2
        logger -t "$LOGTAG" "User requested non-existent interface: $USER_REQUEST"
        rm -f "$LOCK_FILE"
        exit 1
    fi

    preferred="$USER_REQUEST"
    # For user request, we don't need decision.json, but we'll still respect backup logic
else
    # ----------------------------------------------------------------------------
    # No user request – read preferred from decision.json
    # ----------------------------------------------------------------------------
    if [ ! -f "$STATE_FILE" ]; then
        logger -t "$LOGTAG" "No decision file and no user request"
        echo "No decision file and no user request" >&2
        rm -f "$LOCK_FILE"
        exit 1
    fi

    preferred=$(jq -r '.preferred // "none"' "$STATE_FILE")
    if [ "$preferred" = "none" ]; then
        logger -t "$LOGTAG" "No preferred interface, removing all default routes"
        echo "No preferred interface, removing all default routes"
        ip route del default 2>/dev/null
        ip route flush cache 2>/dev/null
        rm -f "$LOCK_FILE"
        exit 0
    fi
fi

# ----------------------------------------------------------------------------
# Determine backup interface (first available from ifaces.json not equal to preferred)
# ----------------------------------------------------------------------------
if [ ! -f "$IFACES_FILE" ]; then
    interfaces=""
else
    interfaces=$(jq -r 'keys[]' "$IFACES_FILE")
fi

backup=""
for iface in $interfaces; do
    if [ "$iface" != "$preferred" ]; then
        backup="$iface"
        break
    fi
done

# ----------------------------------------------------------------------------
# Get device and gateway (nexthop) for an interface via ifstatus
# Returns: device|gateway
# ----------------------------------------------------------------------------
get_route_info() {
    iface="$1"
    if command -v ifstatus >/dev/null 2>&1; then
        json=$(ifstatus "$iface" 2>/dev/null)
        if echo "$json" | jq empty >/dev/null 2>&1; then
            device=$(echo "$json" | jq -r '.l3_device // .device // empty')
            gateway=$(echo "$json" | jq -r '.route[] | select(.target=="0.0.0.0") | .nexthop // empty')
            echo "$device|$gateway"
            return
        fi
    fi
    # Fallback: try UCI device and try to guess gateway from existing routes
    device=$(uci -q get network."$iface".device 2>/dev/null)
    gateway=""
    if [ -n "$device" ]; then
        gateway=$(ip route show default | grep "dev $device" | awk '{print $3}' | head -1)
    fi
    echo "$device|$gateway"
}

pref_info=$(get_route_info "$preferred")
pref_dev=$(echo "$pref_info" | cut -d'|' -f1)
pref_gw=$(echo "$pref_info" | cut -d'|' -f2)

backup_info=$(get_route_info "$backup")
backup_dev=$(echo "$backup_info" | cut -d'|' -f1)
backup_gw=$(echo "$backup_info" | cut -d'|' -f2)

if [ -z "$pref_dev" ]; then
    logger -t "$LOGTAG" "Cannot get device for $preferred"
    echo "Cannot get device for $preferred" >&2
    rm -f "$LOCK_FILE"
    exit 1
fi

if [ -z "$pref_gw" ]; then
    pref_gw=$(ip route show default | grep "dev $pref_dev" | awk '{print $3}' | head -1)
fi

# Flush all default routes
ip route del default 2>/dev/null
ip route flush cache 2>/dev/null

# Add primary route (with gateway if available, else device-only)
if [ -n "$pref_gw" ]; then
    ip route add default via "$pref_gw" dev "$pref_dev" 2>/dev/null
else
    ip route add default dev "$pref_dev" 2>/dev/null
fi

if [ $? -ne 0 ]; then
    logger -t "$LOGTAG" "Failed to set default via $pref_gw dev $pref_dev"
    echo "Failed to set default via $pref_gw dev $pref_dev" >&2
    rm -f "$LOCK_FILE"
    exit 1
fi

# Add backup route with configured metric
if [ -n "$backup_dev" ]; then
    if [ -z "$backup_gw" ]; then
        backup_gw=$(ip route show default | grep "dev $backup_dev" | awk '{print $3}' | head -1)
    fi
    if [ -n "$backup_gw" ]; then
        ip route add default via "$backup_gw" dev "$backup_dev" metric "$BACKUP_METRIC" 2>/dev/null
    else
        ip route add default dev "$backup_dev" metric "$BACKUP_METRIC" 2>/dev/null
    fi
fi

logger -t "$LOGTAG" "Default route switched to $preferred (via $pref_gw dev $pref_dev), backup: $backup_dev (metric $BACKUP_METRIC)"
echo "Default route switched to $preferred (via $pref_gw dev $pref_dev), backup: $backup_dev (metric $BACKUP_METRIC)"

# ----------------------------------------------------------------------------
# If user requested manually, also update last_pref to reflect manual choice
# (so that hysteresis doesn't fight against the user)
# ----------------------------------------------------------------------------
if [ -n "$USER_REQUEST" ]; then
    echo "$preferred" > "$STATE_DIR/last_pref"
fi

rm -f "$LOCK_FILE"