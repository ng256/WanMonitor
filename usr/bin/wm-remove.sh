#!/bin/sh
# ============================================================================
#   wm-remove.sh – uninstall wanmon completely
#   (C) 2026 Pavel Bashkardin
# ============================================================================

echo "=== wanmon uninstaller ==="
echo "This will stop the service and remove all wanmon files."
echo "Configuration (ifaces.json) will be preserved unless you choose to delete it."
read -p "Continue? (y/N): " confirm
case "$confirm" in
    y|Y) ;;
    *) echo "Aborted."; exit 0 ;;
esac

# Stop service if present
if [ -x /etc/init.d/wanmon ]; then
    /etc/init.d/wanmon stop 2>/dev/null
    /etc/init.d/wanmon disable 2>/dev/null
    echo "Service stopped and disabled."
fi

# Remove executable scripts
echo "Removing /usr/bin/wm-*.sh"
rm -f /usr/bin/wm-init.sh
rm -f /usr/bin/wm-state.sh
rm -f /usr/bin/wm-select.sh
rm -f /usr/bin/wm-apply.sh
rm -f /usr/bin/wm-daemon.sh
rm -f /usr/bin/wm-help.sh
rm -f /usr/bin/wm-remove.sh   # self-removal

# Remove service file
echo "Removing /etc/init.d/wanmon"
rm -f /etc/init.d/wanmon

# Remove configuration directory (but keep ifaces.json? ask user)
read -p "Remove /etc/wanmon directory (config, ifaces.json)? (y/N): " remove_config
case "$remove_config" in
    y|Y) rm -rf /etc/wanmon
         echo "Removed /etc/wanmon"
         ;;
    *) echo "Preserving /etc/wanmon"
esac

# Remove temporary runtime files (optional)
rm -rf /tmp/wanmon 2>/dev/null
rm -f /tmp/wm-*.lock 2>/dev/null

echo "wanmon uninstalled."