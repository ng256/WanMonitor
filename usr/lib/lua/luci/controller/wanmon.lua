module("luci.controller.wanmon", package.seeall)

function index()
    -- register "WAN Monitor" menu item in "Services"
    entry({"admin", "services", "wanmon"}, template("wanmon/status"), _("WAN Monitor"), 60).leaf = true
end