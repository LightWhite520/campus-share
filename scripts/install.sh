#!/bin/sh
# Run on the router from the extracted project directory.
set -e
BASE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
[ "$(id -u)" = 0 ] || { echo 'Run as root'; exit 1; }
for cmd in uci ubus curl jsonfilter flock conntrack nft; do
	command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd"; exit 1; }
done
[ -f /etc/init.d/mwan3 ] || { echo 'mwan3 is required'; exit 1; }
BACKUP="/root/campus-share-install-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
for c in network firewall uhttpd mwan3 campus_share; do
	[ ! -f "/etc/config/$c" ] || cp -p "/etc/config/$c" "$BACKUP/$c"
done
# Refuse to merge into unrelated uncommitted UCI edits.
[ -z "$(uci changes)" ] || { echo 'Uncommitted UCI edits exist; install stopped'; exit 1; }
cp -R "$BASE/root/usr/." /usr/
mkdir -p /www/luci-static/resources/view/campus-share
cp "$BASE/htdocs/luci-static/resources/view/campus-share/overview.js" /www/luci-static/resources/view/campus-share/
cp -R "$BASE/root/www-campus-share" /www-campus-share
cp "$BASE/root/etc/init.d/campus-share" /etc/init.d/campus-share
[ -f /etc/config/campus_share ] || cp "$BASE/root/etc/config/campus_share" /etc/config/campus_share
chmod 755 /usr/sbin/campus-share-network-reload /usr/libexec/campus-share /etc/init.d/campus-share /www-campus-share/cgi-bin/api
chmod 600 /etc/config/campus_share
chmod 755 /usr/libexec/campus-share-setup
/usr/libexec/campus-share-setup
echo "Source installation complete. Backup: $BACKUP"
