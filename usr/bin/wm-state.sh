#!/bin/sh
# ============================================================================
#   wm-state.sh – measure latency, loss, jitter for all interfaces
#   (C) 2026 Pavel Bashkardin
# ============================================================================

CONFIG_DIR="/etc/wanmon"
CONFIG_FILE="$CONFIG_DIR/config.json"
STATE_DIR="/tmp/wanmon"
IFACES="$CONFIG_DIR/ifaces.json"
OUTFILE="$STATE_DIR/state.json"
mkdir -p "$STATE_DIR"

# ----------------------------------------------------------------------------
# Read configuration (with fallbacks)
# ----------------------------------------------------------------------------
if [ -f "$CONFIG_FILE" ]; then
    PING_HOST=$(jq -r '.ping_host // "1.1.1.1"' "$CONFIG_FILE")
    TIMEOUT_SEC=$(jq -r '.ping_timeout // 2' "$CONFIG_FILE")
    SAMPLES=$(jq -r '.ping_samples // 5' "$CONFIG_FILE")
else
    PING_HOST="1.1.1.1"
    TIMEOUT_SEC=2
    SAMPLES=5
fi

# ----------------------------------------------------------------------------
# Sanity checks
# ----------------------------------------------------------------------------
if [ ! -f "$IFACES" ]; then
    logger -t wm-state "No ifaces.json found"
    echo "No ifaces.json found" >&2
    exit 1
fi

interfaces=$(jq -r 'keys[]' "$IFACES")

# ----------------------------------------------------------------------------
# Get interface status and physical device via ifstatus
# ----------------------------------------------------------------------------
get_interface_info() {
    iface="$1"
    if command -v ifstatus >/dev/null 2>&1; then
        json=$(ifstatus "$iface" 2>/dev/null)
        if echo "$json" | jq empty >/dev/null 2>&1; then
            echo "$json" | jq -r '[.up // false, (.l3_device // .device // "")] | join("|")'
            return
        fi
    fi
    echo "false|"
}

# ----------------------------------------------------------------------------
# Measure quality for a single interface
# Returns: "latency|loss|jitter"
#   latency  = median RTT (ms)
#   loss     = packet loss percentage
#   jitter   = median absolute deviation from median (MAD)
# ----------------------------------------------------------------------------
measure_quality() {
    iface="$1"
    info=$(get_interface_info "$iface")
    IFS='|' read -r up device <<EOF
$info
EOF

    if [ "$up" != "true" ] || [ -z "$device" ]; then
        echo "0|100|0"
        return
    fi

    ip link show "$device" >/dev/null 2>&1 || { echo "0|100|0"; return; }

    # Collect successful ping times (integer ms)
    values=""
    count=0
    i=0
    while [ $i -lt $SAMPLES ]; do
        raw=$(ping -I "$device" -c 1 -W "$TIMEOUT_SEC" "$PING_HOST" 2>/dev/null \
            | sed -n 's/.*time[=<]\([0-9.]*\).*/\1/p')
        if [ -n "$raw" ]; then
            t=$(echo "$raw" | awk '{if ($1 < 1) print 1; else print int($1)}')
            values="$values $t"
            count=$((count + 1))
        fi
        i=$((i + 1))
    done

    loss=$(((SAMPLES - count) * 100 / SAMPLES))
    if [ "$count" -eq 0 ]; then
        echo "0|100|0"
        return
    fi

    # Compute median and MAD in one awk pass
    stats=$(echo "$values" | tr ' ' '\n' | grep -v '^$' | awk -v n="$count" '
        { a[NR] = $1 }
        END {
            # Median
            if (n % 2 == 1) {
                med = a[(n+1)/2]
            } else {
                med = int((a[n/2] + a[n/2+1]) / 2)
            }
            # MAD: mean absolute deviation from median
            sum = 0
            for (i=1; i<=n; i++) {
                diff = a[i] - med;
                if (diff < 0) diff = -diff;
                sum += diff
            }
            mad = int(sum / n)
            print med, mad
        }
    ')
    median=$(echo "$stats" | awk '{print $1}')
    jitter=$(echo "$stats" | awk '{print $2}')
    echo "$median|$loss|$jitter"
}

# ----------------------------------------------------------------------------
# Build JSON
# ----------------------------------------------------------------------------
json='{}'
for iface in $interfaces; do
    result=$(measure_quality "$iface")
    IFS='|' read -r latency loss jitter <<EOF
$result
EOF
    json=$(echo "$json" | jq \
        --arg i "$iface" \
        --argjson l "$latency" \
        --argjson p "$loss" \
        --argjson j "$jitter" \
        '. + {($i): {latency: $l, loss: $p, jitter: $j}}')
done

if echo "$json" | jq '.' > "$OUTFILE"; then
    logger -t wm-state "state.json updated"
    echo "state.json updated"
else
    logger -t wm-state "failed to write state.json"
    echo "failed to write state.json" >&2
    exit 1
fi