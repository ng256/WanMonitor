#!/bin/sh
set -e

# ============================================================================
#   wm-build_ipk.sh – build IPK package for wanmon (OpenWrt official way)
#   (C) 2026 Pavel Bashkardin
# ============================================================================

PKG_NAME="wanmon"
PKG_VERSION="1.0"
PKG_REVISION="1"
PKG_ARCH="all"
PKG_DEPENDS="jq"

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/out"
PKG_ROOT="$OUT/$PKG_NAME"
IPKG_BUILD="$ROOT/tools/ipk-build.sh"

# ----------------------------------------------------------------------------
# DEBUG: variables dump
# ----------------------------------------------------------------------------
echo "================= DEBUG ================="
echo "PKG_NAME     = $PKG_NAME"
echo "PKG_VERSION  = $PKG_VERSION"
echo "PKG_REVISION = $PKG_REVISION"
echo "PKG_ARCH     = $PKG_ARCH"
echo "PKG_DEPENDS  = $PKG_DEPENDS"
echo "ROOT         = $ROOT"
echo "OUT          = $OUT"
echo "PKG_ROOT     = $PKG_ROOT"
echo "IPKG_BUILD   = $IPKG_BUILD"
echo "========================================="

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

    echo "COPY DEBUG:"
    echo "  src = $src"
    echo "  dst = $dst"

    if [ -e "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
        echo "  Copied $1"
    else
        echo "  Missing $1"
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

for f in $FILES; do
    copy "$f"
done

# ----------------------------------------------------------------------------
# CONTROL file
# ----------------------------------------------------------------------------
mkdir -p "$PKG_ROOT/CONTROL"

echo "Writing control files..."

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
cat > "$PKG_ROOT/CONTROL/postinst" <<'EOF'
#!/bin/sh
/etc/init.d/wanmon enable 2>/dev/null
/etc/init.d/wanmon start 2>/dev/null
exit 0
EOF

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
echo "========== IPK BUILD =========="
echo "PKG_ROOT    = $PKG_ROOT"
echo "OUT         = $OUT"
echo "IPKG_BUILD  = $IPKG_BUILD"

ls -l "$PKG_ROOT"

if [ ! -x "$IPKG_BUILD" ]; then
    echo "ERROR: ipk-build not executable: $IPKG_BUILD"
    exit 1
fi

echo "Running builder..."

"$IPKG_BUILD" "$PKG_ROOT" "$OUT"

echo "BUILD DONE"
echo "OUTPUT DIR: $OUT"
