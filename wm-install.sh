#!/bin/sh
# ============================================================================
#   wm-install.sh – install wanmon to OpenWrt
#   (C) 2026 Pavel Bashkardin
# ============================================================================

set -e

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
TARGET_INIT="/etc/init.d"
TARGET_ETC="/etc/wanmon"
TARGET_BIN="/usr/bin"
TARGET_LUA_CONTROLLER="/usr/lib/lua/luci/controller"
TARGET_LUA_VIEW="/usr/lib/lua/luci/view/wanmon"
TARGET_MENU="/usr/share/luci/menu.d"
TARGET_ACL="/usr/share/rpcd/acl.d"
TARGET_WWW="/www"
TARGET_CGI="/www/cgi-bin"

# Files to copy (source:target)
FILES="
etc/init.d/wanmon:$TARGET_INIT/wanmon
etc/wanmon/config.json:$TARGET_ETC/config.json
usr/bin/wm-apply.sh:$TARGET_BIN/wm-apply.sh
usr/bin/wm-daemon.sh:$TARGET_BIN/wm-daemon.sh
usr/bin/wm-help.sh:$TARGET_BIN/wm-help.sh
usr/bin/wm-init.sh:$TARGET_BIN/wm-init.sh
usr/bin/wm-remove.sh:$TARGET_BIN/wm-remove.sh
usr/bin/wm-select.sh:$TARGET_BIN/wm-select.sh
usr/bin/wm-state.sh:$TARGET_BIN/wm-state.sh
usr/lib/lua/luci/controller/wanmon.lua:$TARGET_LUA_CONTROLLER/wanmon.lua
usr/lib/lua/luci/view/wanmon/status.htm:$TARGET_LUA_VIEW/status.htm
usr/share/luci/menu.d/luci-app-wanmon.json:$TARGET_MENU/luci-app-wanmon.json
usr/share/rpcd/acl.d/luci-app-wanmon.json:$TARGET_ACL/luci-app-wanmon.json
www/wanmon.html:$TARGET_WWW/wanmon.html
www/cgi-bin/wanmon.cgi:$TARGET_CGI/wanmon.cgi
"

# ----------------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------------
die() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARNING: $*" >&2
}

info() {
    echo "INFO: $*"
}

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root (use sudo)."
    fi
}

# Check for opkg
check_opkg() {
    if ! command -v opkg >/dev/null 2>&1; then
        die "opkg not found. This script is intended for OpenWrt."
    fi
}

# Install package if missing
install_pkg() {
    pkg="$1"
    if ! opkg list-installed | grep -q "^$pkg -"; then
        info "Installing package: $pkg"
        opkg update || warn "opkg update failed, continuing anyway"
        if ! opkg install "$pkg"; then
            die "Failed to install $pkg"
        fi
    else
        info "Package $pkg is already installed"
    fi
}

# Copy file with backup
copy_file() {
    src="$1"
    dst="$2"
    if [ ! -f "$src" ]; then
        warn "Source file not found: $src (skipping)"
        return 1
    fi
    # Create destination directory
    dst_dir="$(dirname "$dst")"
    if [ ! -d "$dst_dir" ]; then
        mkdir -p "$dst_dir" || die "Cannot create directory $dst_dir"
    fi
    # Backup existing file
    if [ -f "$dst" ]; then
        backup="${dst}.old"
        if [ ! -f "$backup" ]; then
            mv "$dst" "$backup"
            info "Backed up existing $dst to $backup"
        else
            rm -f "$dst"
        fi
    fi
    cp -f "$src" "$dst" || die "Failed to copy $src to $dst"
    info "Copied $src -> $dst"
}

# Set executable permissions
set_executable() {
    file="$1"
    if [ -f "$file" ]; then
        chmod +x "$file"
        info "Made executable: $file"
    fi
}

# ----------------------------------------------------------------------------
# Main installation
# ----------------------------------------------------------------------------
main() {
    check_root
    check_opkg

    info "=== wanmon installation started ==="

    # Install dependencies
    install_pkg "jq"
    install_pkg "jq"

    # Additional dependencies (usually already present)
    for pkg in "ip" "ping" "awk" "sed" "grep" "uci" "ubus" "logread"; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            warn "$pkg not found, but it is typically present in OpenWrt base."
        fi
    done

    info "Copying files from $PROJECT_ROOT to system..."

    # Create target directories
    mkdir -p "$TARGET_INIT" "$TARGET_ETC" "$TARGET_BIN" \
             "$TARGET_LUA_CONTROLLER" "$TARGET_LUA_VIEW" \
             "$TARGET_MENU" "$TARGET_ACL" \
             "$TARGET_WWW" "$TARGET_CGI"

    # Process each file
    for entry in $FILES; do
        src="${entry%:*}"
        dst="${entry#*:}"
        # Resolve relative paths
        src_full="$PROJECT_ROOT/$src"
        copy_file "$src_full" "$dst"
    done

    # Set executable permissions
    set_executable "/etc/init.d/wanmon"
    for script in /usr/bin/wm-*.sh; do
        set_executable "$script"
    done
    set_executable "/www/cgi-bin/wanmon.cgi"

    # Enable service
    if [ -x "/etc/init.d/wanmon" ]; then
        info "Enabling wanmon service..."
        /etc/init.d/wanmon enable || warn "Failed to enable service"
        info "Starting wanmon service..."
        /etc/init.d/wanmon start || warn "Failed to start service (you can start manually with 'wm-daemon.sh')"
    else
        warn "Service script not found after installation"
    fi

    info "=== wanmon installation completed ==="
    echo ""
    echo "You can manage the daemon with:"
    echo "  /usr/bin/wm-daemon.sh --help"
    echo "  /etc/init.d/wanmon {start|stop|restart|status}"
    echo ""
    echo "Web interface:"
    echo "  http://$(uci -q get network.lan.ipaddr || echo "router-ip")/wanmon.html"
    echo "  LuCI menu: Services -> WAN Monitor"
    echo ""
    echo "Configuration file: /etc/wanmon/config.json"
    echo "Interface weights: /etc/wanmon/ifaces.json (auto-generated at first start)"
    echo ""
    echo "To re-generate ifaces.json after network changes:"
    echo "  /usr/bin/wm-daemon.sh --init"
    echo ""
    echo "For diagnostic: /usr/bin/wm-help.sh --all"
}

# ----------------------------------------------------------------------------
# Run main
# ----------------------------------------------------------------------------
main