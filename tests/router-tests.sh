#!/bin/sh
# Run on OpenWrt. All mutating network tools and UCI configuration are isolated.
set -e
BASE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TESTROOT="$(mktemp -d /tmp/campus-share-tests.XXXXXX)"
trap 'rm -rf "$TESTROOT"' EXIT INT TERM
mkdir -p "$TESTROOT/bin" "$TESTROOT/config" "$TESTROOT/run" "$TESTROOT/state"
export CS_UCI_DIR="$TESTROOT/config" CS_RUN_DIR="$TESTROOT/run" CS_STATE_DIR="$TESTROOT/state"
export TESTROOT
export CS_LEASE_FILE="$TESTROOT/dhcp.leases"
cat > "$CS_LEASE_FILE" <<'LEASES'
0 02:00:00:00:00:50 192.0.2.50 TEST-LAPTOP *
0 02:00:00:00:00:51 192.0.2.51 Test-Phone *
LEASES
HELPER="$BASE/root/usr/libexec/campus-share"
export HELPER
export BASE
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
request() { printf '{"token":"%s","client":"%s","action":"claim","detected_device_type":"pc"}' "$1" "$2" | sh "$HELPER" request; }
invite() {
	result="$(sh "$HELPER" invite)"
	url="$(jget "$result" url)"; echo "${url##*=}"
}
# Old configurations keep random mode. Both modes restore existing identities.
uci -c "$CS_UCI_DIR" set network.synthetic_device=device
uci -c "$CS_UCI_DIR" set network.synthetic_device.name=synthetic_eth
uci -c "$CS_UCI_DIR" set network.synthetic_device.macaddr=02:00:00:00:00:99
uci -c "$CS_UCI_DIR" set network.spare_alpha.clientid=01020000000099
uci -c "$CS_UCI_DIR" commit network
(
 export CS_LIBRARY_ONLY=1
 . "$HELPER"
 slot_config only
 OWNER=02:00:00:00:00:50
 for mode in random client; do
  if [ "$mode" = client ]; then cfg set campus_share.main.mac_mode=client; fi
  prepare_identity
  if [ "$mode" = random ]; then
   case "$GENERATED_MAC" in 02:*) :;; *) fail random_mac_format;; esac
   [ "$GENERATED_MAC" != "$OWNER" ] || fail random_mac_is_owner
  else
   [ "$GENERATED_MAC" = "$OWNER" ] || fail client_mac_not_owner
  fi
  apply_identity
  [ "$(cfg get network.synthetic_device.macaddr)" = "$GENERATED_MAC" ] || fail mode_mac_not_applied
  [ "$(cfg get network.spare_alpha.clientid)" = "01$(echo "$GENERATED_MAC" | tr -d :)" ] || fail mode_clientid
  restore_identity
  [ "$(cfg get network.synthetic_device.macaddr)" = 02:00:00:00:00:99 ] || fail original_mac_not_restored
  [ "$(cfg get network.spare_alpha.clientid)" = 01020000000099 ] || fail original_clientid_not_restored
 done
 cfg set campus_share.main.mac_mode=invalid
 result="$(prepare_identity)"
 [ "$(jget "$result" error)" = invalid_mac_mode ] || fail invalid_mac_mode
)
uci -c "$CS_UCI_DIR" delete network.synthetic_device
uci -c "$CS_UCI_DIR" delete network.spare_alpha.clientid
uci -c "$CS_UCI_DIR" set campus_share.main.mac_mode=client
uci -c "$CS_UCI_DIR" commit
echo 'PASS: both MAC modes, legacy default, invalid mode and original identity restoration'
(
 # The production helper deliberately tolerates absent optional UCI/state keys.
 set +e
 export CS_LIBRARY_ONLY=1
 . "$HELPER"
 slot_config only
 OWNER=02:00:00:00:00:50; CLIENT=192.0.2.50
 DEVICE_TYPE=pc; DETECTED_DEVICE_TYPE=pc
 for original in missing empty '*' Previous-Name; do
  cfg -q delete network.spare_alpha.hostname || :
  case "$original" in missing) :;; empty) cfg set network.spare_alpha.hostname=;; *) cfg set "network.spare_alpha.hostname=$original";; esac
  prepare_identity; apply_identity
  [ "$(cfg get network.spare_alpha.hostname)" = TEST-LAPTOP ] || fail hostname_not_copied
  PHASE=pending; TOKEN=unused; NOTE=test; SINCE=0
  mkdir -p "$ROOT/slots"
  save_state
  HOSTNAME_MANAGED=0; OLD_HOSTNAME=wrong; CLIENT_HOSTNAME=wrong
  load_state
  [ "$CLIENT_HOSTNAME" = TEST-LAPTOP ] || fail hostname_state
  restore_identity
  case "$original" in
   missing) if cfg -q get network.spare_alpha.hostname >/dev/null; then fail hostname_not_deleted; fi;;
   empty) [ "$(cfg get network.spare_alpha.hostname)" = '' ] || fail empty_hostname_restore;;
   *) [ "$(cfg get network.spare_alpha.hostname)" = "$original" ] || fail hostname_restore;;
  esac
 done
 for lease in '0 02:00:00:00:00:51 192.0.2.50 Wrong-MAC *' '0 02:00:00:00:00:50 192.0.2.51 Wrong-IP *' '1 02:00:00:00:00:50 192.0.2.50 Expired *' '0 02:00:00:00:00:50 192.0.2.50 * *' '0 02:00:00:00:00:50 192.0.2.50 bad;name *'; do
  printf '%s\n' "$lease" > "$CS_LEASE_FILE"
  prepare_identity; apply_identity
  printf '%s' "$(cfg get network.spare_alpha.hostname)" | grep -Eq '^DESKTOP-[A-F0-9]{7}$' || fail unsafe_hostname_fallback
  restore_identity
 done
 rm "$CS_LEASE_FILE"
 prepare_identity; apply_identity
 printf '%s' "$(cfg get network.spare_alpha.hostname)" | grep -Eq '^DESKTOP-[A-F0-9]{7}$' || fail missing_lease_fallback
 restore_identity
 # Existing assignments without hostname metadata retain their live settings.
 printf '{"device_section":"csdev_only","device_created":1}' > "$STATE"
 load_state
 cfg set network.spare_alpha.hostname=Legacy-Name
 restore_identity
 [ "$(cfg get network.spare_alpha.hostname)" = Legacy-Name ] || fail legacy_hostname_changed
 cfg -q delete network.spare_alpha.hostname
 rm "$STATE"
 cfg commit network
)
cat > "$CS_LEASE_FILE" <<'LEASES'
0 02:00:00:00:00:50 192.0.2.50 TEST-LAPTOP *
0 02:00:00:00:00:51 192.0.2.51 Test-Phone *
LEASES
echo 'PASS: hostname matching, validation, fallback, state restoration and legacy compatibility'
(
 set +e
 export CS_LIBRARY_ONLY=1
 . "$HELPER"
 slot_config only
 OWNER=02:00:00:00:00:50; CLIENT=192.0.2.50
 for selected in pc phone; do
  for detected in pc phone unknown; do
   DEVICE_TYPE="$selected"; DETECTED_DEVICE_TYPE="$detected"
   prepare_identity
   if [ "$selected" = "$detected" ]; then
    [ "$CLIENT_HOSTNAME" = TEST-LAPTOP ] && [ "$HOSTNAME_SOURCE" = lease ] || fail matching_type_name
   else
    case "$selected" in pc) pattern='^DESKTOP-[A-F0-9]{7}$';; phone) pattern='^Android-[a-f0-9]{12}$';; esac
    printf '%s' "$CLIENT_HOSTNAME" | grep -Eq "$pattern" || fail generated_type_name
    [ "$HOSTNAME_SOURCE" = random ] || fail generated_name_source
    previous="$CLIENT_HOSTNAME"
    prepare_identity
    [ "$previous" != "$CLIENT_HOSTNAME" ] || fail reused_random_hostname
   fi
   PHASE=pending; TOKEN=unused; NOTE=test; SINCE=0
   save_state
   DEVICE_TYPE=wrong; DETECTED_DEVICE_TYPE=wrong; HOSTNAME_SOURCE=wrong
   load_state
   [ "$DEVICE_TYPE" = "$selected" ] && [ "$DETECTED_DEVICE_TYPE" = "$detected" ] || fail device_type_state
   case "$HOSTNAME_SOURCE" in lease|random) :;; *) fail hostname_source_state;; esac
  done
 done
 DEVICE_TYPE=''; DETECTED_DEVICE_TYPE=phone
 prepare_identity
 [ "$DEVICE_TYPE" = pc ] || fail default_device_type
 DEVICE_TYPE=invalid
 result="$(prepare_identity)"
 [ "$(jget "$result" error)" = invalid_device_type ] || fail invalid_device_type
 rm "$STATE"
)
echo 'PASS: computer/phone selection, mismatch/unknown generation, random names and persisted types'
A="$(invite)"; B="$(invite)"
case "$A" in ''|*[!a-f0-9]*) fail invite;; esac
[ "${#A}" = 48 ] || fail token_length
bad="$(request '../escape' 192.0.2.50)"
[ "$(jget "$bad" error)" = invalid_request ] || fail token_validation
bad="$(printf '{"token":"%s","client":"192.0.2.50","action":"claim","device_type":"invalid"}' "$A" | sh "$HELPER" request)"
[ "$(jget "$bad" error)" = invalid_device_type ] || fail invalid_claim_device_type
[ ! -f "$CS_STATE_DIR/slots/only.json" ] || fail invalid_claim_allocated
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
# The selected WAN must present the claiming client's identity to campus DHCP.
owner="$(jsonfilter -i "$CS_STATE_DIR/slots/only.json" -e '@.owner')"
[ "$(uci -c "$CS_UCI_DIR" get network.csdev_only.macaddr)" = "$owner" ] || fail client_mac_not_cloned
[ "$(uci -c "$CS_UCI_DIR" get network.spare_alpha.clientid)" = "01$(echo "$owner" | tr -d :)" ] || fail clientid_not_matching_owner
[ "$(uci -c "$CS_UCI_DIR" get network.spare_alpha.hostname)" = "$(awk -v m="$owner" '$2==m {print $4}' "$CS_LEASE_FILE")" ] || fail claim_hostname
[ "$(jsonfilter -i "$CS_STATE_DIR/slots/only.json" -e '@.device_type')" = pc ] || fail claim_default_type
if [ "$winner" = a ]; then winning_token="$A"; winning_ip=192.0.2.50; else winning_token="$B"; winning_ip=192.0.2.51; fi
result="$(printf '{"token":"%s","client":"%s","action":"claim","device_type":"phone","detected_device_type":"phone"}' "$winning_token" "$winning_ip" | sh "$HELPER" request)"
[ "$(jget "$result" device_type)" = pc ] || fail repeated_claim_changed_type
[ "$(jget "$result" hostname)" = "$(uci -c "$CS_UCI_DIR" get network.spare_alpha.hostname)" ] || fail public_hostname
echo 'PASS: authenticated client MAC cloning and matching DHCP client ID'
# Keep the portal adapter checks inside this suite's isolated fixture.
(
 . "$BASE/tests/portal-tests.sh"
)
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
if uci -c "$CS_UCI_DIR" -q get network.spare_alpha.hostname >/dev/null; then fail released_hostname_not_deleted; fi
[ -z "$(uci -c "$CS_UCI_DIR" -q get network.csdev_only)" ] || fail generated_device_not_removed
echo 'PASS: route normalization, fail-closed route, health, expiry and identity restoration'
# Release only changes isolated test UCI.
[ "$(uci -c "$CS_UCI_DIR" get network.spare_alpha.auto)" = 0 ] || fail auto_restore
result="$(REQUEST_METHOD=POST CONTENT_LENGTH=0 CONTENT_TYPE=application/json HTTP_HOST=192.0.2.1:8088 HTTP_ORIGIN=http://evil.invalid sh "$BASE/root/www-campus-share/cgi-bin/api")"
echo "$result" | grep -q invalid_origin || fail csrf_origin
echo 'PASS: source-origin protection, no real network mutation'

# Exercise CGI normalization with a capture helper, never the installed backend.
sed "s|/usr/libexec/campus-share request|cat > \"\$TESTROOT/cgi-request.json\"|" "$BASE/root/www-campus-share/cgi-bin/api" > "$TESTROOT/api"
body='{"action":"claim","token":"test","device_type":"phone","client":"203.0.113.99","detected_device_type":"phone"}'
for agent in 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' 'Mozilla/5.0 (Linux; Android 14)' 'Mozilla/5.0 (iPhone)' 'Mozilla/5.0 (Macintosh; Intel Mac OS X)' 'Unknown'; do
 printf '%s' "$body" | REQUEST_METHOD=POST CONTENT_LENGTH="${#body}" CONTENT_TYPE=application/json HTTP_HOST=192.0.2.1:8088 HTTP_ORIGIN=http://192.0.2.1:8088 REMOTE_ADDR=192.0.2.50 HTTP_USER_AGENT="$agent" sh "$TESTROOT/api" >/dev/null
 result="$(cat "$TESTROOT/cgi-request.json")"
 case "$agent" in *Windows*|*Macintosh*) detected=pc;; *Android*|*iPhone*) detected=phone;; *) detected=unknown;; esac
 [ "$(jget "$result" detected_device_type)" = "$detected" ] || fail cgi_device_detection
 [ "$(jget "$result" device_type)" = phone ] || fail cgi_device_selection
 [ "$(jget "$result" client)" = 192.0.2.50 ] || fail cgi_source_override
done
echo 'PASS: CGI selection forwarding, browser detection and source-address protection'

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

# Explicit conversion may import existing primary uplinks, regardless of names.
uci -c "$CS_UCI_DIR" set mwan3.existing_used=interface
uci -c "$CS_UCI_DIR" set mwan3.existing_used.enabled=1
uci -c "$CS_UCI_DIR" set mwan3.primary_member=member
uci -c "$CS_UCI_DIR" set mwan3.primary_member.interface=existing_used
uci -c "$CS_UCI_DIR" set mwan3.secondary=policy
uci -c "$CS_UCI_DIR" add_list mwan3.shared.use_member=primary_member
uci -c "$CS_UCI_DIR" add_list mwan3.secondary.use_member=primary_member
uci -c "$CS_UCI_DIR" set network.unrelated=interface
uci -c "$CS_UCI_DIR" set network.unrelated.proto=static
uci -c "$CS_UCI_DIR" set network.unrelated.device=br-test
uci -c "$CS_UCI_DIR" commit
(
 set +e
 export CS_LIBRARY_ONLY=1
 . "$HELPER"
 pool_reload() { :; }
 result="$(prepare_pool_interface lan)"
 [ "$(jget "$result" error)" = lan_interface_protected ] || fail lan_takeover
 result="$(prepare_pool_interface unrelated)"
 [ "$(jget "$result" error)" = dhcp_interface_required ] || fail static_takeover
 result="$(prepare_pool_interface spare_alpha)"
 # No current assignment after the expiry test, but existing free pool entries are idempotent.
 [ "$(jget "$result" ok)" = true ] || fail existing_pool_conversion
 result="$(prepare_pool_interface existing_used)"
 [ "$(jget "$result" ok)" = true ] || fail primary_conversion
 [ "$(cfg get network.existing_used.auto)" = 0 ] || fail converted_interface_enabled
 if cfg -q get mwan3.primary_member >/dev/null; then fail old_member_retained; fi
 if cfg -q get mwan3.existing_used >/dev/null; then fail old_tracking_retained; fi
 for p in shared secondary; do
  case " $(cfg -q get mwan3.$p.use_member) " in *' primary_member '*) fail stale_policy_member;; esac
 done
 cfg show campus_share | grep -q "interface='existing_used'" || fail converted_not_imported
 [ "$(cfg get network.unrelated.device)" = br-test ] || fail unrelated_changed
 [ -n "$(find "$ROOT/backups" -name network -type f)" ] || fail conversion_backup_missing
)
echo 'PASS: primary uplink conversion, all-policy member removal, backups and LAN/static protection'
