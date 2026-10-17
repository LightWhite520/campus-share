#!/bin/sh
set -eu
# Release owned slots before removing their service/routes.
if [ -x /usr/libexec/campus-share ]; then
	for f in /etc/campus-share/slots/*.json; do
		[ -f "$f" ] || continue
		id="${f##*/}"; id="${id%.json}"
		/usr/libexec/campus-share release "$id"
	done
fi
/etc/init.d/campus-share stop
/etc/init.d/campus-share disable
uci -q delete firewall.campus_share_lan || true
uci -q delete uhttpd.campus_share || true
uci commit firewall; uci commit uhttpd
/etc/init.d/firewall reload
/etc/init.d/uhttpd reload
rm -f /usr/sbin/campus-share-network-reload /usr/libexec/campus-share /etc/init.d/campus-share
rm -f /usr/share/luci/menu.d/luci-app-campus-share.json
rm -f /usr/share/rpcd/acl.d/luci-app-campus-share.json
rm -f /www/luci-static/resources/view/campus-share/overview.js
rm -f /tmp/luci-indexcache
echo 'Service removed. Configuration and private state retained under /etc for inspection.'
