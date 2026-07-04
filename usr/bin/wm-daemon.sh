#!/bin/sh
# ============================================================================
#   wm-daemon.sh – main loop for wanmon
#   (C) 2026 Pavel Bashkardin
# ============================================================================

CONFIG_DIR="/etc/wanmon"
CONFIG_FILE="$CONFIG_DIR/config.json"
STATE_DIR="/tmp/wanmon"
LOCK="/tmp/wm-daemon.lock"
LOGTAG="wm-daemon"

# ----------------------------------------------------------------------------
# Read interval from config (fallback 10)
# ----------------------------------------------------------------------------
if [ -f "$CONFIG_FILE" ]; then
    interval=$(jq -r '.interval // 10' "$CONFIG_FILE")
    case "$interval" in
        ''|*[!0-9]*) interval=10 ;;
    esac
else
    interval=10
fi
INTERVAL="$interval"

# ----------------------------------------------------------------------------
#   handle_status() – check if daemon is running
# ----------------------------------------------------------------------------
handle_status() {
    if [ -f "$LOCK" ]; then
        pid=$(cat "$LOCK")
        if kill -0 "$pid" 2>/dev/null; then
            echo "wanmon daemon is running (PID $pid)"
            return 0
        else
            echo "wanmon daemon is not running (stale lock file)"
            return 1
        fi
    else
        echo "wanmon daemon is not running"
        return 1
    fi
}

# ----------------------------------------------------------------------------
#   handle_stop() – stop daemon gracefully
# ----------------------------------------------------------------------------
handle_stop() {
    if [ -f "$LOCK" ]; then
        pid=$(cat "$LOCK")
        if kill -0 "$pid" 2>/dev/null; then
            logger -t "$LOGTAG" "Stopping daemon (PID $pid)"
            kill "$pid"
            rm -f "$LOCK"
            echo "Daemon stopped"
        else
            echo "Daemon not running (stale lock file), removing lock"
            rm -f "$LOCK"
        fi
    else
        echo "Daemon is not running"
    fi
    exit 0
}

# ----------------------------------------------------------------------------
#   handle_init() – force reinitialize ifaces.json and clean temp files
# ----------------------------------------------------------------------------
handle_init() {
    echo "Reinitializing wanmon configuration..."
    /usr/bin/wm-init.sh

    if [ -d "$STATE_DIR" ]; then
        [ -f "$STATE_DIR/state.json" ] && rm -f "$STATE_DIR/state.json"
        [ -f "$STATE_DIR/decision.json" ] && rm -f "$STATE_DIR/decision.json"
        [ -f "$STATE_DIR/last_pref" ] && rm -f "$STATE_DIR/last_pref"
        if [ -d "$STATE_DIR/history" ]; then
            rm -rf "$STATE_DIR/history"
        fi
    fi
    mkdir -p "$STATE_DIR/history"

    echo "Temporary files cleaned, ifaces.json recreated"
    exit 0
}

# ----------------------------------------------------------------------------
#   handle_remove() – stop daemon and run full uninstall
# ----------------------------------------------------------------------------
handle_remove() {
    echo "Removing wanmon..."
    # Stop daemon if running
    if [ -f "$LOCK" ]; then
        pid=$(cat "$LOCK")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            rm -f "$LOCK"
            echo "Daemon stopped"
        else
            rm -f "$LOCK"
        fi
    fi
    # Run the uninstaller script
    if [ -x /usr/bin/wm-remove.sh ]; then
        /usr/bin/wm-remove.sh
    else
        echo "wm-remove.sh not found or not executable"
        exit 1
    fi
    exit 0
}

# ----------------------------------------------------------------------------
#   show_help() – print usage (internal help)
# ----------------------------------------------------------------------------
show_help() {
    cat <<EOF
Usage: wm-daemon.sh [OPTION]

Options:
  (no option)   Start daemon in background (or foreground if not daemonized)
  --stop        Stop the running daemon
  --init        Force re-initialize ifaces.json and clean temp files, then exit
  --status      Check if daemon is running
  --remove      Stop daemon and run full uninstall (wm-remove.sh)
  --help        Show this help

If no ifaces.json exists at startup, wm-init.sh is called automatically.
EOF
    exit 0
}

# ----------------------------------------------------------------------------
#   parse arguments
# ----------------------------------------------------------------------------
case "$1" in
    --stop)   handle_stop ;;
    --init)   handle_init ;;
    --status) handle_status ;;
    --remove) handle_remove ;;
    --help)   show_help ;;
    "")       ;;  # continue to start
    *)        echo "Unknown option: $1" >&2; show_help ;;
esac

# ----------------------------------------------------------------------------
#   Start daemon: prevent parallel runs
# ----------------------------------------------------------------------------
if [ -f "$LOCK" ]; then
    pid=$(cat "$LOCK")
    if kill -0 "$pid" 2>/dev/null; then
        echo "Daemon already running (PID $pid)" >&2
        exit 1
    else
        echo "Removing stale lock file"
        rm -f "$LOCK"
    fi
fi

echo $$ > "$LOCK"
logger -t "$LOGTAG" "Daemon started, interval ${INTERVAL}s"

# ----------------------------------------------------------------------------
#   Clean temporary runtime files on fresh start
# ----------------------------------------------------------------------------
if [ -d "$STATE_DIR" ]; then
    [ -f "$STATE_DIR/state.json" ] && rm -f "$STATE_DIR/state.json"
    [ -f "$STATE_DIR/decision.json" ] && rm -f "$STATE_DIR/decision.json"
    [ -f "$STATE_DIR/last_pref" ] && rm -f "$STATE_DIR/last_pref"
    if [ -d "$STATE_DIR/history" ]; then
        rm -rf "$STATE_DIR/history"
    fi
fi
mkdir -p "$STATE_DIR/history"

# ----------------------------------------------------------------------------
#   Initialize ifaces.json and config.json if missing
# ----------------------------------------------------------------------------
if [ ! -f "$CONFIG_DIR/ifaces.json" ]; then
    logger -t "$LOGTAG" "ifaces.json not found at startup, running wm-init.sh"
    /usr/bin/wm-init.sh >/dev/null 2>&1
fi

# Create default config.json if missing
if [ ! -f "$CONFIG_FILE" ]; then
    logger -t "$LOGTAG" "config.json not found, creating default"
    cat > "$CONFIG_FILE" <<EOF
{
  "interval": 10,
  "ping_host": "1.1.1.1",
  "ping_timeout": 2,
  "ping_samples": 5,
  "smooth_window": 5,
  "hysteresis_threshold": 20,
  "loss_divisor": 10,
  "hard_loss_limit": 80,
  "dead_score": 99999,
  "default_metric": 100,
  "backup_metric": 20
}
EOF
fi

# ----------------------------------------------------------------------------
#   Main loop – re-read interval each iteration to allow dynamic changes
# ----------------------------------------------------------------------------
while true; do
    # Re-read interval from config each cycle (in case it was changed)
    if [ -f "$CONFIG_FILE" ]; then
        new_interval=$(jq -r '.interval // 10' "$CONFIG_FILE")
        case "$new_interval" in
            ''|*[!0-9]*) ;;
            *) INTERVAL="$new_interval" ;;
        esac
    fi

    # Re-init if ifaces.json missing
    if [ ! -f "$CONFIG_DIR/ifaces.json" ]; then
        /usr/bin/wm-init.sh >/dev/null 2>&1
    fi

    /usr/bin/wm-state.sh >/dev/null 2>&1
    /usr/bin/wm-select.sh >/dev/null 2>&1
    /usr/bin/wm-apply.sh >/dev/null 2>&1

    sleep "$INTERVAL"
done