#!/bin/sh
# ============================================================================
#   build-ipk.sh – build IPK package for wanmon
#   (C) 2026 Pavel Bashkardin
# ============================================================================

set -e

# Package metadata
PKG_NAME="wanmon"
PKG_VERSION="1.0"
PKG_REVISION="1"
PKG_ARCH="all"
PKG_MAINTAINER="Pavel Bashkardin"
PKG_DESCRIPTION="WAN Monitor & Failover Controller"

# Dependencies (opkg package names)
# jq is required; ip, awk, etc. are expected to be present in base system
DEPENDS="jq"

# Temporary build directories
BUILD_DIR="$(mktemp -d)"
PKG_ROOT="$BUILD_DIR/ipkg-root"
CONTROL="$PKG_ROOT/CONTROL"
DATA="$PKG_ROOT"

cleanup() {
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
# Create directory structure
# ----------------------------------------------------------------------------
mkdir -p "$CONTROL"
mkdir -p "$DATA"

# ----------------------------------------------------------------------------
# Copy all project files preserving relative paths
# ----------------------------------------------------------------------------
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"

# List of files/directories to copy (relative to project root)
COPY_LIST="
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

for item in $COPY_LIST; do
    src="$PROJECT_ROOT/$item"
    if [ ! -e "$src" ]; then
        echo "WARNING: $src not found, skipping"
        continue
    fi
    dst="$DATA/$item"
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    echo "  Copied $item"
done

# ----------------------------------------------------------------------------
# Create control file
# ----------------------------------------------------------------------------
cat > "$CONTROL/control" <<EOF
Package: $PKG_NAME
Version: $PKG_VERSION-$PKG_REVISION
Depends: $DEPENDS
Architecture: $PKG_ARCH
Maintainer: $PKG_MAINTAINER
Description: $PKG_DESCRIPTION
 This package provides automated WAN failover and monitoring.
 It measures latency, loss, jitter and switches default route.
EOF

# ----------------------------------------------------------------------------
# Create postinst script (runs after installation)
# ----------------------------------------------------------------------------
cat > "$CONTROL/postinst" <<'EOF'
#!/bin/sh
# postinst for wanmon

# Enable and start service
if [ -x /etc/init.d/wanmon ]; then
    /etc/init.d/wanmon enable
    /etc/init.d/wanmon start
fi

# Ensure config exists (if not already)
if [ ! -f /etc/wanmon/config.json ]; then
    mkdir -p /etc/wanmon
    cat > /etc/wanmon/config.json <<JSON
{
  "interval": 60,
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
JSON
fi

exit 0
EOF

# ----------------------------------------------------------------------------
# Create prerm script (runs before removal)
# ----------------------------------------------------------------------------
cat > "$CONTROL/prerm" <<'EOF'
#!/bin/sh
# prerm for wanmon

# Stop service if running
if [ -x /etc/init.d/wanmon ]; then
    /etc/init.d/wanmon stop
    /etc/init.d/wanmon disable
fi

# Remove temporary runtime files (optional)
# rm -rf /tmp/wanmon 2>/dev/null

exit 0
EOF

# ----------------------------------------------------------------------------
# Make scripts executable
# ----------------------------------------------------------------------------
chmod +x "$CONTROL/postinst" "$CONTROL/prerm"

# ----------------------------------------------------------------------------
# Build IPK using ipkg-build or manual ar
# ----------------------------------------------------------------------------
IPK_FILE="$PROJECT_ROOT/${PKG_NAME}_${PKG_VERSION}-${PKG_REVISION}_${PKG_ARCH}.ipk"

# Prepare temp dirs for tar archives
TMP_DATA="$BUILD_DIR/data"
TMP_CONTROL="$BUILD_DIR/control"
mkdir -p "$TMP_DATA" "$TMP_CONTROL"

# Copy data files (excluding CONTROL)
cd "$DATA"
find . -path ./CONTROL -prune -o -type f -print | while read -r file; do
    mkdir -p "$TMP_DATA/$(dirname "$file")"
    cp "$file" "$TMP_DATA/$file"
done
cd "$PROJECT_ROOT"

# Copy control files
cp -r "$CONTROL/"* "$TMP_CONTROL/"

# Create compressed archives (no compression for speed, but use gzip)
cd "$TMP_DATA"
tar -czf "$BUILD_DIR/data.tar.gz" .
cd "$TMP_CONTROL"
tar -czf "$BUILD_DIR/control.tar.gz" .

# Create debian-binary
echo "2.0" > "$BUILD_DIR/debian-binary"

# Assemble with ar
cd "$BUILD_DIR"
ar r "$IPK_FILE" debian-binary control.tar.gz data.tar.gz 2>/dev/null

echo ""
echo "============================================================"
echo "IPK package built successfully:"
echo "  $IPK_FILE"
echo ""
echo "You can install it with:"
echo "  opkg install $IPK_FILE"
echo "============================================================"

# Cleanup is done by trap