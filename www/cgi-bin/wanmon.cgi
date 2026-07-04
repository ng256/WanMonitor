#!/bin/sh
# ============================================================================
#   wanmon.cgi – JSON API backend for wanmon web interface
#   (C) 2026 Pavel Bashkardin
# ============================================================================

PATH=/usr/bin:/usr/sbin:/bin:/sbin
export PATH

# ----------------------------------------------------------------------------
#   Check if action parameter is provided
#   If not, return error (this is a JSON API endpoint)
# ----------------------------------------------------------------------------
if ! echo "$QUERY_STRING" | grep -q "action="; then
    echo "Content-Type: application/json; charset=UTF-8"
    echo
    echo '{"error":"Missing action parameter"}'
    exit 0
fi

# ----------------------------------------------------------------------------
#   Configuration paths
# ----------------------------------------------------------------------------
STATE_DIR="/tmp/wanmon"
DECISION_FILE="$STATE_DIR/decision.json"
STATE_FILE="$STATE_DIR/state.json"
IFACES_FILE="/etc/wanmon/ifaces.json"

# ----------------------------------------------------------------------------
#   Helper: read JSON file safely (return {} if not exists)
# ----------------------------------------------------------------------------
read_json() {
    file="$1"
    if [ -f "$file" ]; then
        cat "$file"
    else
        echo "{}"
    fi
}

# ----------------------------------------------------------------------------
#   Helper: check if daemon is running
# ----------------------------------------------------------------------------
is_running() {
    if [ -f "/tmp/wm-daemon.lock" ]; then
        pid=$(cat /tmp/wm-daemon.lock)
        if kill -0 "$pid" 2>/dev/null; then
            echo "true"
            return 0
        fi
    fi
    echo "false"
    return 1
}

# ----------------------------------------------------------------------------
#   Process actions
# ----------------------------------------------------------------------------
case "$QUERY_STRING" in

    # ------------------------------------------------------------------------
    # action=status | action=daemon
    # Returns: running (bool), pid (int), preferred (string), default_route (string)
    # ------------------------------------------------------------------------
    action=status|action=daemon)
        running=$(is_running)
        pid=0
        [ "$running" = "true" ] && pid=$(cat /tmp/wm-daemon.lock)
        preferred=$(jq -r '.preferred // "none"' "$DECISION_FILE" 2>/dev/null)
        default_route=$(ip route show default | head -1 | sed 's/^/"/;s/$/"/' | tr -d '\n')
        echo "Content-Type: application/json; charset=UTF-8"
        echo
        echo "{\"running\":$running,\"pid\":$pid,\"preferred\":\"$preferred\",\"default_route\":$default_route}"
        ;;

    # ------------------------------------------------------------------------
    # action=decision | action=scores
    # Returns: content of decision.json (scores and preferred)
    # ------------------------------------------------------------------------
    action=decision|action=scores)
        echo "Content-Type: application/json; charset=UTF-8"
        echo
        read_json "$DECISION_FILE"
        ;;

    # ------------------------------------------------------------------------
    # action=state | action=telemetry
    # Returns: content of state.json (latency, loss, jitter per interface)
    # ------------------------------------------------------------------------
    action=state|action=telemetry)
        echo "Content-Type: application/json; charset=UTF-8"
        echo
        read_json "$STATE_FILE"
        ;;

    # ------------------------------------------------------------------------
    # action=ifaces | action=policy
    # Returns: content of ifaces.json (interface bias weights)
    # ------------------------------------------------------------------------
    action=ifaces|action=policy)
        echo "Content-Type: application/json; charset=UTF-8"
        echo
        read_json "$IFACES_FILE"
        ;;

    # ------------------------------------------------------------------------
    # action=logs
    # Returns: JSON array with last 30 lines of wanmon logs
    # ------------------------------------------------------------------------
    action=logs)
        logs=$(logread | grep wm- | tail -30)
        json_array=$(echo "$logs" | awk '
            BEGIN { printf "[" }
            {
                gsub(/"/, "\\\"", $0)
                if (NR > 1) printf ","
                printf "\"%s\"", $0
            }
            END { printf "]" }
        ')
        echo "Content-Type: application/json; charset=UTF-8"
        echo
        echo "{\"logs\":$json_array}"
        ;;

    # ------------------------------------------------------------------------
    # action=switch&iface=<name>
    # Switches default route to specified interface (must be in ifaces.json)
    # Returns: success (bool), message, output (command output)
    # ------------------------------------------------------------------------
    action=switch)
        iface=$(echo "$QUERY_STRING" | sed -n 's/.*iface=\([^&]*\).*/\1/p')
        if [ -z "$iface" ]; then
            echo "Content-Type: application/json; charset=UTF-8"
            echo
            echo "{\"error\":\"Missing iface parameter\"}"
            exit 0
        fi
        if ! jq -e ".\"$iface\"" "$IFACES_FILE" >/dev/null 2>&1; then
            echo "Content-Type: application/json; charset=UTF-8"
            echo
            echo "{\"error\":\"Interface '$iface' not found in ifaces.json\"}"
            exit 0
        fi
        output=$(/usr/bin/wm-apply.sh "$iface" 2>&1 | sed 's/"/\\"/g')
        if [ $? -eq 0 ]; then
            echo "Content-Type: application/json; charset=UTF-8"
            echo
            echo "{\"success\":true,\"message\":\"Switched to $iface\",\"output\":\"$output\"}"
        else
            echo "Content-Type: application/json; charset=UTF-8"
            echo
            echo "{\"success\":false,\"message\":\"Failed to switch to $iface\",\"output\":\"$output\"}"
        fi
        ;;

    # ------------------------------------------------------------------------
    # action=stop
    # Stops the wanmon daemon
    # Returns: success (bool), message, output
    # ------------------------------------------------------------------------
    action=stop)
        echo "Content-Type: application/json; charset=UTF-8"
        echo
        output=$(/usr/bin/wm-daemon.sh --stop 2>&1 | sed 's/"/\\"/g')
        if [ $? -eq 0 ]; then
            echo "{\"success\":true,\"message\":\"Daemon stopped\",\"output\":\"$output\"}"
        else
            echo "{\"success\":false,\"message\":\"Failed to stop daemon\",\"output\":\"$output\"}"
        fi
        ;;

    # ------------------------------------------------------------------------
    # action=start
    # Starts the wanmon daemon (if not already running)
    # Returns: success (bool), message, output
    # ------------------------------------------------------------------------
    action=start)
        echo "Content-Type: application/json; charset=UTF-8"
        echo
        if [ "$(is_running)" = "true" ]; then
            echo "{\"success\":false,\"message\":\"Daemon is already running\"}"
            exit 0
        fi
        output=$(/usr/bin/wm-daemon.sh 2>&1 | sed 's/"/\\"/g')
        if [ $? -eq 0 ]; then
            echo "{\"success\":true,\"message\":\"Daemon started\",\"output\":\"$output\"}"
        else
            echo "{\"success\":false,\"message\":\"Failed to start daemon\",\"output\":\"$output\"}"
        fi
        ;;

    # ------------------------------------------------------------------------
    # action=restart
    # Restarts the wanmon daemon (stop + start)
    # Returns: success (bool), message, output
    # ------------------------------------------------------------------------
    action=restart)
        echo "Content-Type: application/json; charset=UTF-8"
        echo
        /usr/bin/wm-daemon.sh --stop >/dev/null 2>&1
        sleep 1
        output=$(/usr/bin/wm-daemon.sh 2>&1 | sed 's/"/\\"/g')
        if [ $? -eq 0 ]; then
            echo "{\"success\":true,\"message\":\"Daemon restarted\",\"output\":\"$output\"}"
        else
            echo "{\"success\":false,\"message\":\"Failed to restart daemon\",\"output\":\"$output\"}"
        fi
        ;;

    # ------------------------------------------------------------------------
    # Unknown action
    # ------------------------------------------------------------------------
    *)
        echo "Content-Type: application/json; charset=UTF-8"
        echo
        echo "{\"error\":\"Unknown action: $QUERY_STRING\"}"
        ;;
esac