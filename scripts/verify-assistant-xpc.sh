#!/bin/zsh
set -euo pipefail

# Verifies the member-chat bridge as a signed, sandboxed XPC service inside a sandboxed host app.
#
# - With the production entitlements (scheme A): the locally installed Codex passes the capability
#   check, which runs it against a loopback stand-in and costs no quota; a codex outside the
#   sandbox exceptions is reported as an unsupported location.
# - With the production entitlements plus one read-only exception for this run's folder: the fake
#   CLI answers a turn, an npm-style wrapper finds its interpreter, cancelling the client's task
#   stops the turn and its descendants, and killing the bridge makes the supervisor stop them too.
#
# The probe host uses KinlogueAssistantXPCClient, the client the App uses.
#
# Only synthetic text is sent. Nothing reaches a provider.

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
SWIFT_EXECUTABLE="/usr/bin/swift"
SERVICE="com.kinlogue.mac.assistant-bridge"
TEST_SERVICE="com.kinlogue.mac.assistant-bridge-verification"
BRIDGE_NAME="KinlogueAssistantBridge"
PRODUCTION_ENTITLEMENTS="$REPO_DIR/packaging/KinlogueAssistantBridge.entitlements"
PROBE_ROOT=""

fail() {
  echo "Assistant XPC verification failed: $1" >&2
  exit 1
}

cleanup() {
  if [[ -n "${PROBE_ROOT:-}" ]]; then
    /usr/bin/pkill -KILL -f -- "$PROBE_ROOT/" >/dev/null 2>&1 || true
    if [[ -d "$PROBE_ROOT" && ! -L "$PROBE_ROOT" \
        && "${PROBE_ROOT:h}" == /private/tmp \
        && "${PROBE_ROOT:t}" == kinlogue-assistant-xpc.* ]]; then
      /bin/rm -rf -- "$PROBE_ROOT"
    fi
  fi
}
trap cleanup EXIT INT TERM

[[ "$#" -eq 0 ]] || fail "usage: verify-assistant-xpc.sh"
[[ -x "$SWIFT_EXECUTABLE" ]] || fail "swift is unavailable"
[[ -f "$PRODUCTION_ENTITLEMENTS" && ! -L "$PRODUCTION_ENTITLEMENTS" ]] \
  || fail "the bridge entitlements are missing"

cd "$REPO_DIR"
for product in "$BRIDGE_NAME" KinlogueAssistantXPCProbe KinlogueAssistantCLIFixture; do
  "$SWIFT_EXECUTABLE" build --disable-sandbox --product "$product" >/dev/null \
    || fail "could not build $product"
done
BIN_DIR="$("$SWIFT_EXECUTABLE" build --disable-sandbox --show-bin-path)"

PROBE_ROOT="$(/usr/bin/mktemp -d /private/tmp/kinlogue-assistant-xpc.XXXXXX)"
/bin/chmod 700 "$PROBE_ROOT"
/bin/cat > "$PROBE_ROOT/host.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
PLIST

# The verification copy differs from production only by one more read-only folder and its own
# bundle identifier, so it never shares the production bridge's container.
/bin/cp -- "$PRODUCTION_ENTITLEMENTS" "$PROBE_ROOT/test.entitlements"
/usr/bin/plutil -insert 'com\.apple\.security\.temporary-exception\.files\.absolute-path\.read-only' \
  -string "$PROBE_ROOT/test/" -append "$PROBE_ROOT/test.entitlements" \
  || fail "could not prepare the verification entitlements"

assemble_probe_app() {
  local app="$1" entitlements="$2" identifier="$3"
  /bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/XPCServices"
  /bin/cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.kinlogue.mac.assistant-xpc-probe</string>
<key>CFBundleExecutable</key><string>Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PLIST
  /bin/cp -- "$BIN_DIR/KinlogueAssistantXPCProbe" "$app/Contents/MacOS/Probe"
  local bridge="$app/Contents/XPCServices/$BRIDGE_NAME.xpc"
  "$REPO_DIR/scripts/assemble-assistant-bridge.sh" "$BIN_DIR/$BRIDGE_NAME" "$bridge" "$entitlements"
  if [[ "$identifier" != "$SERVICE" ]]; then
    /usr/bin/plutil -replace CFBundleIdentifier -string "$identifier" "$bridge/Contents/Info.plist"
    /usr/bin/codesign --force --sign - --entitlements "$entitlements" "$bridge"
  fi
  /usr/bin/codesign --force --sign - --entitlements "$PROBE_ROOT/host.entitlements" "$app"
  /usr/bin/codesign --verify --strict "$app" || fail "the probe app signature does not verify"
}

PRODUCTION_APP="$PROBE_ROOT/production/Probe.app"
TEST_APP="$PROBE_ROOT/testing/Probe.app"
assemble_probe_app "$PRODUCTION_APP" "$PRODUCTION_ENTITLEMENTS" "$SERVICE"
assemble_probe_app "$TEST_APP" "$PROBE_ROOT/test.entitlements" "$TEST_SERVICE"

canonical_json() {
  /usr/bin/plutil -convert json -o - - | /usr/bin/ruby -rjson -e 'puts JSON.generate(JSON.parse(STDIN.read).sort.to_h)'
}
signed_entitlements="$(/usr/bin/codesign -d --entitlements - --xml \
  "$PRODUCTION_APP/Contents/XPCServices/$BRIDGE_NAME.xpc" 2>/dev/null | canonical_json)"
expected_entitlements="$(canonical_json < "$PRODUCTION_ENTITLEMENTS")"
[[ "$signed_entitlements" == "$expected_entitlements" ]] \
  || fail "the signed bridge does not carry exactly the production entitlements"

probe() {
  local app="$1"
  shift
  "$REPO_DIR/scripts/run-with-deadline.sh" 300 "$app/Contents/MacOS/Probe" "$@" \
    | /usr/bin/grep -E '^KL_PROBE ' | /usr/bin/tail -1
}

expect_line() {
  local name="$1" line="$2" pattern="$3"
  if [[ "$line" =~ "$pattern" ]]; then
    echo "  passed: $name"
  else
    fail "$name: expected /$pattern/, got '$line'"
  fi
}

count_processes() {
  /usr/bin/pgrep -f -- "$1" | /usr/bin/wc -l | /usr/bin/awk '{print $1}'
}

wait_for_no_processes() {
  local pattern="$1" name="$2" deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    [[ "$(count_processes "$pattern")" -eq 0 ]] && { echo "  passed: $name"; return; }
    /bin/sleep 0.2
  done
  fail "$name: processes matching $pattern are still running"
}

echo "Production entitlements:"
LOCAL_CODEX=""
for candidate in /opt/homebrew/bin/codex /usr/local/bin/codex; do
  [[ -x "$candidate" ]] && { LOCAL_CODEX="$candidate"; break; }
done
if [[ -n "$LOCAL_CODEX" ]]; then
  line="$(probe "$PRODUCTION_APP" status "$SERVICE")"
  # The sandbox points the bridge's own HOME at its container; Codex must still find the login
  # under the real home, so a Codex that is logged in outside must be logged in inside too.
  if "$LOCAL_CODEX" login status 2>&1 | /usr/bin/grep -q 'Logged in'; then
    expect_line "the local Codex passes the capability check and finds its login inside the sandbox" "$line" \
      'kind=status failure=none version=[0-9][^ ]* loggedIn=true'
    expect_line "the local Codex lists the models it shows, with a default" "$line" \
      'models=[1-9][0-9]* default=[A-Za-z0-9]'
  else
    expect_line "the local Codex passes the capability check inside the sandbox" "$line" \
      'kind=status failure=notLoggedIn version=[0-9]'
  fi
else
  echo "  not run: no Codex in /opt/homebrew/bin or /usr/local/bin"
fi

FIXTURE_DIR="$PROBE_ROOT/test/fixture"
OUTSIDE_DIR="$PROBE_ROOT/outside/bin"
/bin/mkdir -p "$FIXTURE_DIR" "$OUTSIDE_DIR" "$PROBE_ROOT/test/bin" \
  "$PROBE_ROOT/test/npm/bin" "$PROBE_ROOT/test/npm/lib/codex/bin"
/bin/cp -- "$BIN_DIR/KinlogueAssistantCLIFixture" "$FIXTURE_DIR/codex-real"
/bin/ln -s "$FIXTURE_DIR/codex-real" "$PROBE_ROOT/test/bin/codex"
/bin/ln -s "$FIXTURE_DIR/codex-real" "$OUTSIDE_DIR/codex"
/usr/bin/printf '#!/usr/bin/env klnode\n' > "$PROBE_ROOT/test/npm/lib/codex/bin/codex.js"
/usr/bin/printf '#!/bin/sh\nshift\nexec "%s" "$@"\n' "$FIXTURE_DIR/codex-real" > "$PROBE_ROOT/test/npm/bin/klnode"
/bin/chmod 755 "$PROBE_ROOT/test/npm/lib/codex/bin/codex.js" "$PROBE_ROOT/test/npm/bin/klnode"
/bin/ln -s "$PROBE_ROOT/test/npm/lib/codex/bin/codex.js" "$PROBE_ROOT/test/npm/bin/codex"
scenario() {
  /usr/bin/printf '{"check":"clean","turn":"%s"}' "$1" > "$FIXTURE_DIR/kl-fake-codex.json"
}
scenario answer

line="$(probe "$PRODUCTION_APP" status "$SERVICE" --executable "$OUTSIDE_DIR/codex" --model gpt-synthetic)"
expect_line "a codex outside the sandbox exceptions is an unsupported location" "$line" \
  'kind=status failure=unsupportedLocation'

echo "Verification entitlements (one extra read-only folder):"
line="$(probe "$TEST_APP" status "$TEST_SERVICE" --executable "$PROBE_ROOT/test/bin/codex" --model gpt-synthetic)"
expect_line "the capability check runs its loopback stand-in inside the sandbox" "$line" \
  'kind=status failure=none version=0\.162\.0 loggedIn=true'
expect_line "the bridge lists the models it shows, without the hidden one" "$line" \
  'models=2 default=gpt-synthetic$'
line="$(probe "$TEST_APP" respond "$TEST_SERVICE" --executable "$PROBE_ROOT/test/bin/codex" --model gpt-synthetic)"
expect_line "a turn returns the CLI's answer through the supervisor" "$line" \
  'kind=answer version=0\.162\.0 text=fake_answer_bytes=[0-9]+'
line="$(probe "$TEST_APP" status "$TEST_SERVICE" --executable "$PROBE_ROOT/test/npm/bin/codex" --model gpt-synthetic)"
expect_line "an npm-style wrapper finds its interpreter next to the requested path" "$line" \
  'kind=status failure=none'

CODEX_PATTERN="$FIXTURE_DIR/codex-real"
scenario hang
line="$(probe "$TEST_APP" respond "$TEST_SERVICE" --executable "$PROBE_ROOT/test/bin/codex" \
  --model gpt-synthetic --cancel-after 2)"
expect_line "cancelling the client's task stops the turn" "$line" 'kind=failure code=cancelled'
wait_for_no_processes "$CODEX_PATTERN" "the cancelled CLI and its descendants are gone"

BRIDGE_EXECUTABLE="$TEST_APP/Contents/XPCServices/$BRIDGE_NAME.xpc/Contents/MacOS/$BRIDGE_NAME"
"$TEST_APP/Contents/MacOS/Probe" respond "$TEST_SERVICE" --executable "$PROBE_ROOT/test/bin/codex" \
  --model gpt-synthetic >/dev/null 2>&1 &
HOST_PID=$!
deadline=$((SECONDS + 30))
while (( SECONDS < deadline )) && [[ "$(count_processes "$CODEX_PATTERN")" -lt 2 ]]; do
  /bin/sleep 0.2
done
[[ "$(count_processes "$CODEX_PATTERN")" -ge 2 ]] || fail "the hanging turn did not start"
service_pid="$(/usr/bin/pgrep -f -- "^$BRIDGE_EXECUTABLE\$" | /usr/bin/head -1)"
[[ -n "$service_pid" ]] || fail "the bridge service process was not found"
/bin/kill -KILL "$service_pid"
wait_for_no_processes "$CODEX_PATTERN" "killing the bridge stops the CLI and its descendants"
wait_for_no_processes "$BRIDGE_EXECUTABLE --supervise" "no supervisor outlives the bridge"
/bin/kill -KILL "$HOST_PID" >/dev/null 2>&1 || true
wait "$HOST_PID" 2>/dev/null || true

echo "Assistant XPC verification passed"
