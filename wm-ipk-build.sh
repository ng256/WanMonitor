#!/bin/sh
set -e

# ============================================================================
#   wm-build_ipk.sh - build IPK package for wanmon (OpenWrt official way)
#   (C) 2026 Pavel Bashkardin
# ============================================================================

PKG_NAME="wanmon"
PKG_VERSION="1.0"
PKG_REVISION="1"
PKG_ARCH="all"
PKG_DEPENDS="jq"

# ----------------------------------------------------------------------------
# Parse arguments
# ----------------------------------------------------------------------------
DEBUG=0
for arg in "$@"; do
    if [ "$arg" = "--debug" ]; then
        DEBUG=1
        break
    fi
    if [ "$arg" = "--nodeps" ]; then
        NO_DEPS=1
        break
    fi
done

# ----------------------------------------------------------------------------
# Debug logging helper
# ----------------------------------------------------------------------------
debug() {
    if [ "$DEBUG" -eq 1 ]; then
        echo "$@"
    fi
}

# ----------------------------------------------------------------------------
# Check and install build dependencies (coreutils-stat, tar)
# ----------------------------------------------------------------------------
check_deps() {
    if [ "$NO_DEPS" -eq 1 ]; then
        debug "Skipping dependency check (--no-deps)"
        return
    fi

    need_install=""
    need_reason=""

    # Check stat
    if ! command -v stat >/dev/null 2>&1; then
        need_install="$need_install coreutils-stat"
        need_reason="${need_reason}
  - stat (required by ipk-build.sh)"
    elif stat --version 2>&1 | grep -i busybox; then
        need_install="$need_install coreutils-stat"
        need_reason="${need_reason}
  - stat (BusyBox version detected, full version required)"
    fi

    # Check tar (GNU version)
    if ! command -v tar >/dev/null 2>&1; then
        need_install="$need_install tar"
        need_reason="${need_reason}
  - tar (required by ipk-build.sh)"
    elif tar --version 2>&1 | grep -i busybox; then
        need_install="$need_install tar"
        need_reason="${need_reason}
  - tar (BusyBox version detected, GNU tar required)"
    fi

    if [ -z "$need_install" ]; then
        debug "All build dependencies satisfied."
        return
    fi

    echo "Missing build dependencies:"
    echo "$need_reason"

    if command -v opkg >/dev/null 2>&1; then
        echo "Installing missing packages via opkg: $need_install"
		debug "need_install = $need_install"
        opkg update || echo "WARNING: opkg update failed, continuing anyway"
        if ! opkg install $need_install; then
            echo "ERROR: Failed to install packages. Please install manually: $need_install"
            exit 1
        fi
        echo "Packages installed successfully."
    else
        echo "ERROR: opkg not found. Please install the following packages manually:"
        echo "  $need_install"
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------------
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/out"
PKG_ROOT="$OUT/$PKG_NAME"
IPKG_BUILD="$ROOT/tools/ipk-build.sh"

debug "================= DEBUG ================="
debug "PKG_NAME     = $PKG_NAME"
debug "PKG_VERSION  = $PKG_VERSION"
debug "PKG_REVISION = $PKG_REVISION"
debug "PKG_ARCH     = $PKG_ARCH"
debug "PKG_DEPENDS  = $PKG_DEPENDS"
debug "ROOT         = $ROOT"
debug "OUT          = $OUT"
debug "PKG_ROOT     = $PKG_ROOT"
debug "IPKG_BUILD   = $IPKG_BUILD"
debug "========================================="

# ----------------------------------------------------------------------------
# Run dependency check
# ----------------------------------------------------------------------------
check_deps

# ----------------------------------------------------------------------------
# Prepare dirs
# ----------------------------------------------------------------------------
rm -rf "$OUT"
mkdir -p "$PKG_ROOT"

echo "Building in: $PKG_ROOT"

# ----------------------------------------------------------------------------
# Copy files
# ----------------------------------------------------------------------------
copy() {
    src="$ROOT/$1"
    dst="$PKG_ROOT/$1"

    debug "COPY DEBUG:"
    debug "  src = $src"
    debug "  dst = $dst"

    if [ -e "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
        debug "  Copied $1"
    else
        debug "  Missing $1"
    fi
}

FILES="
etc/init.d/wanmon
etc/wanmon/config.json
usr/bin/wm-apply.sh
usr/bin/wm-daemon.sh
usr/bin/wm-help.sh
usr/bin/wm-init.sh
usr/bin/wm-remove.sh
usr/bin/wm-select.sh
usr/bin/wm-state.sh
usr/lib/lua/luci/controller/wanmon.lua
usr/lib/lua/luci/view/wanmon/status.htm
usr/share/luci/menu.d/luci-app-wanmon.json
usr/share/rpcd/acl.d/luci-app-wanmon.json
www/wanmon.html
www/cgi-bin/wanmon.cgi
"

echo "Copying wanmon files..."
for f in $FILES; do
    copy "$f"
done

# ----------------------------------------------------------------------------
# CONTROL file
# ----------------------------------------------------------------------------
mkdir -p "$PKG_ROOT/CONTROL"

echo "Writing control files..."
debug "CONTROL DEBUG:"
debug "  control = $PKG_ROOT/CONTROL/control"
cat > "$PKG_ROOT/CONTROL/control" <<EOF
Package: $PKG_NAME
Version: $PKG_VERSION-$PKG_REVISION
Depends: $PKG_DEPENDS
Architecture: $PKG_ARCH
Maintainer: Pavel Bashkardin
Description: WAN Monitor & Failover Controller
EOF

# ----------------------------------------------------------------------------
# postinst
# ----------------------------------------------------------------------------
debug "  postinst = $PKG_ROOT/CONTROL/postinst"
cat > "$PKG_ROOT/CONTROL/postinst" <<'EOF'
#!/bin/sh
/etc/init.d/wanmon enable 2>/dev/null
/etc/init.d/wanmon start 2>/dev/null
exit 0
EOF

debug "  prerm = $PKG_ROOT/CONTROL/prerm"
cat > "$PKG_ROOT/CONTROL/prerm" <<'EOF'
#!/bin/sh
/etc/init.d/wanmon stop 2>/dev/null
/etc/init.d/wanmon disable 2>/dev/null
exit 0
EOF

chmod +x "$PKG_ROOT/CONTROL/postinst"
chmod +x "$PKG_ROOT/CONTROL/prerm"

# ----------------------------------------------------------------------------
# Build package
# ----------------------------------------------------------------------------
debug "========== IPK BUILD =========="
debug "PKG_ROOT    = $PKG_ROOT"
debug "OUT         = $OUT"
debug "IPKG_BUILD  = $IPKG_BUILD"

if [ "$DEBUG" -eq 1 ]; then
    ls -l "$PKG_ROOT"
fi

if [ ! -x "$IPKG_BUILD" ]; then
    echo "ERROR: ipk-build not executable: $IPKG_BUILD"
    exit 1
fi

echo "Running builder..."

"$IPKG_BUILD" "$PKG_ROOT" "$OUT"

debug "BUILD DONE"
debug "OUTPUT DIR: $OUT"
