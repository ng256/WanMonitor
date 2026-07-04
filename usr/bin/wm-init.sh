#!/bin/sh
# ============================================================================
#   wm-init.sh – create ifaces.json from active WAN zone interfaces
#   (C) 2026 Pavel Bashkardin
# ============================================================================

CONFIG_DIR="/etc/wanmon"
CONFIG_FILE="$CONFIG_DIR/config.json"
OUTFILE="$CONFIG_DIR/ifaces.json"
mkdir -p "$CONFIG_DIR"

# ----------------------------------------------------------------------------
# Read default metric from config (fallback to 100)
# ----------------------------------------------------------------------------
if [ -f "$CONFIG_FILE" ]; then
    default_metric=$(jq -r '.default_metric // 100' "$CONFIG_FILE")
else
    default_metric=100
fi

# Find firewall zone index
zone_idx=$(uci show firewall | grep -E "@zone\[[0-9]+\].name='wan'" | sed -n 's/.*@zone\[\([0-9]*\)\].*/\1/p')
if [ -n "$zone_idx" ]; then
    wan_zone_ifaces=$(uci -q get firewall.@zone[$zone_idx].network)
else
    wan_zone_ifaces="wan wwan"
fi

# Remove wan6 (IPv6 is not used for default route selection) and clean up
wan_zone_ifaces=$(echo "$wan_zone_ifaces" | tr ' ' '\n' | grep -v '^wan6$' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')
[ -z "$wan_zone_ifaces" ] && wan_zone_ifaces="wan wwan"

# Get all currently up interfaces (excluding loopback and LAN bridge)
if command -v ubus >/dev/null 2>&1; then
    all_ifaces=$(ubus call network.interface dump | jq -r '.interface[] | select(.up==true) | .interface')
else
    all_ifaces=$(ip -o addr show | awk '{print $2}' | grep -v 'lo' | grep -v 'br-lan' | sort -u)
fi

# Intersect: only those that are both in the wan zone and actually up
interfaces=""
for iface in $wan_zone_ifaces; do
    echo "$all_ifaces" | grep -q "^$iface$" && {
        if [ -z "$interfaces" ]; then
            interfaces="$iface"
        else
            interfaces="$interfaces $iface"
        fi
    }
done

# If no active WAN interfaces exist, remove stale policy file
if [ -z "$interfaces" ]; then
    logger -t wm-init "No active WAN interfaces found, removing ifaces.json"
    rm -f "$OUTFILE"
    exit 1
fi

# Build output JSON using default metric from config
json="{}"
for iface in $interfaces; do
    metric=$(uci -q get network.$iface.metric)
    [ -z "$metric" ] && metric="$default_metric"
    json=$(echo "$json" | jq --arg i "$iface" --argjson m "$metric" '. + {($i):$m}')
done

echo "$json" | jq '.' > "$OUTFILE"
logger -t wm-init "ifaces.json created with interfaces: $interfaces"
echo "ifaces.json created with interfaces: $interfaces"