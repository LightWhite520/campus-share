#!/bin/sh
# Called by router-tests.sh with an already claimed, fully isolated fixture.
set -e
export CS_LIBRARY_ONLY=1
export CS_PORTAL_LIBRARY="$BASE/root/usr/libexec/campus-share-portal"
. "$HELPER"
. "$CS_PORTAL_LIBRARY"
slot_config only
load_state
cp "$STATE" "$TESTROOT/pre-login-state.json"
login_token="$TOKEN"; login_client="$CLIENT"
network_get_ipaddr() { export "$1=198.51.100.20"; }
network_flush_cache() { :; }
mkdir -p "$TESTROOT/auth-bin"
cat > "$TESTROOT/auth-bin/curl" <<'MOCK'
#!/bin/sh
printf '%s\n' "$@" >> "$TESTROOT/auth-args"
config="$(cat)"
printf '%s\n' "$config" >> "$TESTROOT/auth-urls"
[ "${AUTH_TEST_CASE:-}" != offline ] || exit 7
case "$config" in
 *'/PortalJsonAction.do?'*)
  challenge=0; [ "${AUTH_TEST_CASE:-}" != challenge ] || challenge=1
  printf '{"portalconfig":{"id":"1","timestamp":"12345","uuid":"synthetic-session","listpasscode":"%s","list2Auth":"0"},"serverForm":{"portalVer":"0","serverip":"198.51.100.1"}}' "$challenge";;
 *'/quickauth.do?'*)
  code=0; [ "${AUTH_TEST_CASE:-}" != rejected ] || code=1
  printf '{"code":%s,"message":"never reflect upstream account details"}' "$code";;
 *'/portal.do?'*) printf '<html>login</html>';;
 *)
  source=198.51.100.20; [ "${AUTH_TEST_CASE:-}" != stale ] || source=198.51.100.99
  if [ "${AUTH_TEST_CASE:-}" = unsafe ]; then
   printf '<html>login</html>\nhttp://portal.example/portal.do?wlanuserip=%s&wlanacname=bad value&vlan=10' "$source"
  elif [ "${AUTH_TEST_CASE:-}" = redirect ]; then
   printf '<html>login</html>\nhttp://portal.example/portal.do?wlanuserip=%s&wlanacname=test&vlan=10&rand=synthetic' "$source"
  else
   printf '<script>location.replace("http://portal.example/portal.do?wlanuserip=%s&wlanacname=test&vlan=10&hostname=Ignored&rand=synthetic");</script>\nhttp://192.0.2.1/' "$source"
  fi;;
esac
MOCK
chmod 755 "$TESTROOT/auth-bin/curl"
export PATH="$TESTROOT/auth-bin:$PATH"
login_request() {
 printf '{"token":"%s","client":"%s","action":"login","device_type":"phone","username":"synthetic&user","password":"p&ss+%% word"}' "$login_token" "$login_client" | public_request
}
for type in pc phone; do
 DEVICE_TYPE="$type"; PHASE=pending; NOTE=login_required
 save_state
 : > "$TESTROOT/auth-args"; : > "$TESTROOT/auth-urls"
 result="$(login_request)"
 [ "$(jget "$result" ok)" = true ] || fail login_failed
 [ "$(grep -c '^--interface$' "$TESTROOT/auth-args")" = 4 ] || fail login_interface_count
 [ "$(grep -c '^198.51.100.20$' "$TESTROOT/auth-args")" = 4 ] || fail login_wrong_source
 if [ "$type" = pc ]; then expected='Windows NT'; else expected='Android 14'; fi
 [ "$(grep -c "$expected" "$TESTROOT/auth-args")" = 4 ] || fail login_wrong_ua
 grep -q 'passwd=%70%26%73%73%2B%25%20%77%6F%72%64' "$TESTROOT/auth-urls" || fail login_password_encoding
 grep -q 'userid=%73%79%6E%74%68%65%74%69%63%26%75%73%65%72' "$TESTROOT/auth-urls" || fail login_username_encoding
 grep -q "hostname=$(portal_encode "$CLIENT_HOSTNAME")" "$TESTROOT/auth-urls" || fail login_hostname
 grep -q "mac=$(portal_encode "$GENERATED_MAC")" "$TESTROOT/auth-urls" || fail login_mac
 if grep -Eq 'passwd=|userid=|synthetic&user|p&ss' "$TESTROOT/auth-args"; then fail credentials_in_process_args; fi
 if grep -Eq 'passwd|password|synthetic&user|p&ss' "$STATE"; then fail credentials_persisted; fi
 [ "$(field "$STATE" phase)" = pending ] || fail login_promoted_without_probe
 [ -z "$(find "$RUN" -name 'portal-cookie.*')" ] || fail login_cookie_leak
done
for test_case in stale unsafe challenge rejected offline redirect; do
 export AUTH_TEST_CASE="$test_case"
 : > "$TESTROOT/auth-urls"
 result="$(login_request)"
 case "$test_case" in
  stale) expected=portal_identity_mismatch;;
  unsafe) expected=unsupported_portal;;
  challenge) expected=portal_interaction_required;;
  rejected) expected=authentication_rejected;;
  offline) expected=portal_unreachable;;
  redirect) [ "$(jget "$result" ok)" = true ] || fail http_redirect_login; continue;;
 esac
 [ "$(jget "$result" error)" = "$expected" ] || fail "login_$test_case"
 [ -z "$(find "$RUN" -name 'portal-cookie.*')" ] || fail failed_login_cookie_leak
 if [ "$test_case" != rejected ]; then
  if grep -q '/quickauth.do?' "$TESTROOT/auth-urls"; then fail unsafe_login_submitted; fi
 fi
done
unset AUTH_TEST_CASE
if [ "$login_client" = 192.0.2.50 ]; then login_client=192.0.2.51; else login_client=192.0.2.50; fi
: > "$TESTROOT/auth-urls"
result="$(login_request)"
[ "$(jget "$result" error)" = owner_mismatch ] || fail login_owner_check
[ ! -s "$TESTROOT/auth-urls" ] || fail unauthorized_login_submitted
cp "$TESTROOT/pre-login-state.json" "$STATE"
echo 'PASS: selected login UA, uplink binding, fresh portal parameters, credential handling, failures and owner protection'
