#!/bin/sh
# Run on OpenWrt. All mutating network tools and UCI configuration are isolated.
set -e
BASE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TESTROOT="$(mktemp -d /tmp/campus-share-tests.XXXXXX)"
trap 'rm -rf "$TESTROOT"' EXIT INT TERM
mkdir -p "$TESTROOT/bin" "$TESTROOT/config" "$TESTROOT/run" "$TESTROOT/state"
export CS_UCI_DIR="$TESTROOT/config" CS_RUN_DIR="$TESTROOT/run" CS_STATE_DIR="$TESTROOT/state"
export TESTROOT
HELPER="$BASE/root/usr/libexec/campus-share"
export HELPER
cat > "$TESTROOT/config/campus_share" <<'CONFIG'
config settings 'main'
 option enabled '1'
 option policy 'shared'
 option lan_interface 'lan'
 option port '8088'
 option invite_timeout '1800'
 option pending_timeout '600'
 option probe_url 'http://example.invalid/probe'
 option probe_body 'expected-body'
 option portal_url 'http://192.0.2.1/'
config slot 'only'
 option enabled '1'
 option interface 'spare_alpha'
 option table '231'
 option label 'Synthetic spare'
CONFIG
cat > "$TESTROOT/config/network" <<'CONFIG'
config interface 'spare_alpha'
 option device 'synthetic_eth'
 option proto 'dhcp'
 option auto '0'
CONFIG
cat > "$TESTROOT/config/mwan3" <<'CONFIG'
config policy 'shared'
 option last_resort 'unreachable'
CONFIG
cat > "$TESTROOT/config/firewall" <<'CONFIG'
config zone 'out'
 option name 'test_wan'
 option masq '1'
 list network 'spare_alpha'
CONFIG
cat > "$TESTROOT/bin/ip" <<'MOCK'
#!/bin/sh
echo "$*" >> "$TESTROOT/ip.log"
case "$*" in
 *'neigh show'*) echo '192.0.2.50 dev br-lan lladdr 02:00:00:00:00:50 REACHABLE'; echo '192.0.2.51 dev br-lan lladdr 02:00:00:00:00:51 REACHABLE';;
 *'route show dev'*) echo '192.0.2.0/24 dev br-lan proto kernel';;
 *'rule del'*) exit 1;;
esac
exit 0
MOCK
for tool in ifup ifdown conntrack nft campus-share-network-reload; do
	printf '#!/bin/sh\nexit 0\n' > "$TESTROOT/bin/$tool"
done
printf '#!/bin/sh\nprintf portal-redirect\n' > "$TESTROOT/bin/curl"
chmod 755 "$TESTROOT/bin/"*
export PATH="$TESTROOT/bin:$PATH"
fail() { echo "FAIL: $*"; exit 1; }
jget() { jsonfilter -s "$1" -e "@.$2"; }
request() { printf '{"token":"%s","client":"%s","action":"claim"}' "$1" "$2" | sh "$HELPER" request; }
invite() {
	result="$(sh "$HELPER" invite)"
	url="$(jget "$result" url)"; echo "${url##*=}"
}
A="$(invite)"; B="$(invite)"
case "$A" in ''|*[!a-f0-9]*) fail invite;; esac
[ "${#A}" = 48 ] || fail token_length
bad="$(request '../escape' 192.0.2.50)"
[ "$(jget "$bad" error)" = invalid_request ] || fail token_validation
# Concurrent claims against one slot must never give it to two devices.
request "$A" 192.0.2.50 > "$TESTROOT/a.json" &
PA=$!
request "$B" 192.0.2.51 > "$TESTROOT/b.json" &
PB=$!
wait "$PA"; wait "$PB"
winner=''
for entry in a b; do
	result="$(cat "$TESTROOT/$entry.json")"
	if [ "$(jget "$result" ok)" = true ]; then
		[ -z "$winner" ] || fail double_allocation
		winner="$entry"
	fi
done
[ -n "$winner" ] || fail no_winner
[ "$(find "$CS_STATE_DIR/slots" -type f -name '*.json' | wc -l)" -eq 1 ] || fail slot_count
if [ "$winner" = a ]; then loser="$B"; loserip=192.0.2.51; else loser="$A"; loserip=192.0.2.50; fi
result="$(request "$loser" "$loserip")"
[ "$(jget "$result" error)" = no_free_slot ] || fail occupied_slot_reassigned
echo 'PASS: concurrent allocation, occupied slot protection, token validation'
# Three consecutive failed HTTP checks must remove active status.
(
 export CS_LIBRARY_ONLY=1
 . "$HELPER"
 lan_info
 slot_config only
 load_state
 # Verify host-address CIDRs are normalized before adding kernel routes.
 network_flush_cache() { :; }
 network_get_device() { export "$1=synthetic_eth"; }
 network_get_ipaddr() { export "$1=192.0.2.7"; }
 network_get_gateway() { export "$1=192.0.2.1"; }
 network_get_subnet() { export "$1=192.0.2.7/24"; }
 route_slot
 grep -q 'route replace 192.0.2.0/24 dev synthetic_eth' "$TESTROOT/ip.log" || fail route_normalization
 grep -q 'unreachable default table 231' "$TESTROOT/ip.log" || fail fail_closed_route
 PHASE=active; NOTE=sharing; FAILURES=0
 save_state
 route_slot() { SOURCE=192.0.2.100; return 0; }
 remove_member() { :; }
 tick
 [ "$(field "$STATE" phase)" = active ] || fail first_failure
 tick
 [ "$(field "$STATE" phase)" = active ] || fail second_failure
 tick
 [ "$(field "$STATE" phase)" = pending ] || fail third_failure
 SINCE=0; save_state
 tick
 [ ! -f "$CS_STATE_DIR/slots/only.json" ] || fail expired_slot
)
[ -z "$(uci -c "$CS_UCI_DIR" -q get network.spare_alpha.clientid)" ] || fail clientid_not_restored
[ -z "$(uci -c "$CS_UCI_DIR" -q get network.csdev_only)" ] || fail generated_device_not_removed
echo 'PASS: route normalization, fail-closed route, health, expiry and identity restoration'
# Release only changes isolated test UCI.
[ "$(uci -c "$CS_UCI_DIR" get network.spare_alpha.auto)" = 0 ] || fail auto_restore
result="$(REQUEST_METHOD=POST CONTENT_LENGTH=0 CONTENT_TYPE=application/json HTTP_HOST=192.0.2.1:8088 HTTP_ORIGIN=http://evil.invalid sh "$BASE/root/www-campus-share/cgi-bin/api")"
echo "$result" | grep -q invalid_origin || fail csrf_origin
echo 'PASS: source-origin protection, no real network mutation'

# Discovery works with arbitrary interface names and ignores busy uplinks.
uci -c "$CS_UCI_DIR" set network.spare_beta=interface
uci -c "$CS_UCI_DIR" set network.spare_beta.proto=dhcp
uci -c "$CS_UCI_DIR" set network.spare_beta.device=synthetic_beta
uci -c "$CS_UCI_DIR" set network.spare_beta.auto=0
uci -c "$CS_UCI_DIR" set network.existing_used=interface
uci -c "$CS_UCI_DIR" set network.existing_used.proto=dhcp
uci -c "$CS_UCI_DIR" set network.existing_used.device=synthetic_busy
uci -c "$CS_UCI_DIR" set network.existing_used.auto=1
uci -c "$CS_UCI_DIR" add_list firewall.out.network=spare_beta
uci -c "$CS_UCI_DIR" add_list firewall.out.network=existing_used
uci -c "$CS_UCI_DIR" commit
result="$(sh "$HELPER" discover)"
[ "$(jget "$result" imported)" = 1 ] || fail dynamic_discovery
result="$(sh "$HELPER" discover)"
[ "$(jget "$result" imported)" = 0 ] || fail repeated_discovery
[ "$(uci -c "$CS_UCI_DIR" get network.spare_beta.auto)" = 0 ] || fail discovery_started_interface
echo 'PASS: dynamic interface discovery, active uplink protection, idempotent import'
