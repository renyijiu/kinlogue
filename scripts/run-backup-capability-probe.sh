#!/bin/zsh
set -euo pipefail

umask 077

# Builds the storage fixture, signs it ad hoc with only the App Sandbox entitlement, installs it
# in the user's Applications folder and runs the whole-root restore cases in that sandbox: one process kills
# itself at a chosen phase of the production restore transaction and a fresh process settles
# what was left. It needs a login session and cannot run in CI or an agent session.

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
ENTITLEMENTS_FILE="$REPO_DIR/packaging/KinlogueBackupCapabilityProbe.entitlements"
BUILD_ROOT="$REPO_DIR/.build/backup-capability-probe"
REPORT_DIRECTORY="$REPO_DIR/dist"
FINAL_REPORT="$REPORT_DIRECTORY/backup-capability-report.json"
USER_HOME_DIRECTORY="${HOME:-}"
USER_APPLICATIONS_DIRECTORY="$USER_HOME_DIRECTORY/Applications"
PROBE_TIMEOUT_SECONDS=120
FIXTURE_TIMEOUT_SECONDS=30
TEMP_DIRECTORY=""
INSTALLED_APP=""
CONTAINER_DIRECTORY=""
WRITER_PID=""
PROBE_PID=""

fail() {
  print -u2 -- "Backup capability probe failed: $1"
  exit 1
}

cleanup() {
  local original_status=$?
  trap - EXIT

  if [[ -n "$PROBE_PID" && "$PROBE_PID" == <-> ]]; then
    /bin/kill -TERM "$PROBE_PID" >/dev/null 2>&1 || true
    wait "$PROBE_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$WRITER_PID" && "$WRITER_PID" == <-> ]]; then
    /bin/kill -TERM "$WRITER_PID" >/dev/null 2>&1 || true
    wait "$WRITER_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$INSTALLED_APP" \
      && "$INSTALLED_APP" == "$USER_APPLICATIONS_DIRECTORY/$APP_BASENAME" ]]; then
    /usr/bin/find -P -x "$INSTALLED_APP" -depth -mindepth 1 -delete \
      >/dev/null 2>&1 || true
    /bin/rmdir -- "$INSTALLED_APP" >/dev/null 2>&1 || true
  fi
  if [[ -n "$CONTAINER_DIRECTORY" \
      && "$CONTAINER_DIRECTORY" == "$USER_HOME_DIRECTORY/Library/Containers/"com.kinlogue.mac.backup-capability.* ]]; then
    /usr/bin/find -P -x "$CONTAINER_DIRECTORY" -depth -mindepth 1 -delete \
      >/dev/null 2>&1 || true
    /bin/rmdir -- "$CONTAINER_DIRECTORY" >/dev/null 2>&1 || true
  fi
  if [[ -n "$TEMP_DIRECTORY" \
      && "$TEMP_DIRECTORY" == /tmp/kinlogue-backup-capability.* ]]; then
    /usr/bin/find -P -x "$TEMP_DIRECTORY" -depth -mindepth 1 -delete \
      >/dev/null 2>&1 || true
    /bin/rmdir -- "$TEMP_DIRECTORY" >/dev/null 2>&1 || true
  fi
  exit "$original_status"
}

[[ "$#" -eq 0 ]] || fail "usage: $0"

[[ -n "$USER_HOME_DIRECTORY" && "$USER_HOME_DIRECTORY" == /* ]] \
  || fail "the user home directory is unavailable"
[[ -f "$ENTITLEMENTS_FILE" && ! -L "$ENTITLEMENTS_FILE" ]] \
  || fail "the isolated probe entitlements are unavailable"

RUN_ID="$(/usr/bin/uuidgen | /usr/bin/tr -d '-' | /usr/bin/tr '[:upper:]' '[:lower:]')"
/usr/bin/printf '%s\n' "$RUN_ID" | /usr/bin/grep -Eq '^[0-9a-f]{32}$' \
  || fail "the run identifier is invalid"
BUNDLE_IDENTIFIER="com.kinlogue.mac.backup-capability.$RUN_ID"
APP_BASENAME="Kinlogue-Backup-Capability-$RUN_ID.app"
INSTALLED_APP="$USER_APPLICATIONS_DIRECTORY/$APP_BASENAME"
CONTAINER_DIRECTORY="$USER_HOME_DIRECTORY/Library/Containers/$BUNDLE_IDENTIFIER"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

TEMP_DIRECTORY="$(/usr/bin/mktemp -d /tmp/kinlogue-backup-capability.XXXXXX)" \
  || fail "could not create a private temporary directory"
[[ -d "$TEMP_DIRECTORY" && ! -L "$TEMP_DIRECTORY" ]] \
  || fail "the private temporary directory is invalid"

/bin/mkdir -p \
  "$BUILD_ROOT/cache" \
  "$BUILD_ROOT/config" \
  "$BUILD_ROOT/security" \
  "$BUILD_ROOT/module-cache/clang" \
  "$BUILD_ROOT/module-cache/swiftpm"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/module-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/module-cache/swiftpm"

SWIFT_ARGUMENTS=(
  --disable-sandbox
  --cache-path "$BUILD_ROOT/cache"
  --config-path "$BUILD_ROOT/config"
  --security-path "$BUILD_ROOT/security"
  --manifest-cache local
  --only-use-versions-from-resolved-file
  -c release
)

cd "$REPO_DIR"
swift build "${SWIFT_ARGUMENTS[@]}" \
  --product KinlogueStorageProcessFixture >&2
BIN_DIRECTORY="$(swift build "${SWIFT_ARGUMENTS[@]}" --show-bin-path)"
PROBE_EXECUTABLE="$BIN_DIRECTORY/KinlogueStorageProcessFixture"
[[ -x "$PROBE_EXECUTABLE" && ! -L "$PROBE_EXECUTABLE" ]] \
  || fail "the fixture executable is unavailable"

make_app() {
  local destination="$1"
  local build_number="$2"
  local info="$destination/Contents/Info.plist"
  local executable="$destination/Contents/MacOS/KinlogueBackupCapabilityProbe"

  /bin/mkdir -p "$destination/Contents/MacOS"
  /bin/cp -p "$PROBE_EXECUTABLE" "$executable"
  /bin/chmod 755 "$executable"
  /usr/bin/plutil -create xml1 "$info"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$BUNDLE_IDENTIFIER" "$info"
  /usr/bin/plutil -insert CFBundleName -string "Kinlogue Backup Capability Probe" "$info"
  /usr/bin/plutil -insert CFBundleDisplayName -string "Kinlogue Backup Capability Probe" "$info"
  /usr/bin/plutil -insert CFBundleExecutable -string "KinlogueBackupCapabilityProbe" "$info"
  /usr/bin/plutil -insert CFBundlePackageType -string APPL "$info"
  /usr/bin/plutil -insert CFBundleShortVersionString -string 1.0 "$info"
  /usr/bin/plutil -insert CFBundleVersion -string "$build_number" "$info"
  /usr/bin/plutil -insert LSUIElement -bool true "$info"
  /usr/bin/plutil -lint "$info" >/dev/null
  /usr/bin/codesign --force --sign - \
    --entitlements "$ENTITLEMENTS_FILE" "$destination"
  /usr/bin/codesign --verify --strict "$destination"
}

STAGED_APP="$TEMP_DIRECTORY/probe.app"
make_app "$STAGED_APP" 1

SIGNED_ENTITLEMENTS="$TEMP_DIRECTORY/signed-entitlements.plist"
# The source plist is not evidence: dump the entitlements from the signed artifact.
/usr/bin/codesign -d --entitlements :- "$STAGED_APP" \
  >"$SIGNED_ENTITLEMENTS" 2>/dev/null \
  || fail "the signed entitlements could not be extracted"
/usr/bin/plutil -lint "$SIGNED_ENTITLEMENTS" >/dev/null \
  || fail "the signed entitlements are invalid"
[[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.app-sandbox' raw -expect bool \
    "$SIGNED_ENTITLEMENTS")" == true ]] \
  || fail "the signed artifact is missing the App Sandbox entitlement"
NORMALIZED_ENTITLEMENTS="$TEMP_DIRECTORY/normalized-entitlements.plist"
/bin/cp -p "$SIGNED_ENTITLEMENTS" "$NORMALIZED_ENTITLEMENTS"
/usr/bin/plutil -remove 'com\.apple\.security\.app-sandbox' "$NORMALIZED_ENTITLEMENTS"
[[ "$(/usr/bin/plutil -convert json -o - "$NORMALIZED_ENTITLEMENTS")" == '{}' ]] \
  || fail "the signed artifact has an unexpected entitlement"

SIGNATURE_METADATA="$TEMP_DIRECTORY/signature.txt"
/usr/bin/codesign -d --verbose=4 "$STAGED_APP" >/dev/null 2>"$SIGNATURE_METADATA"
TEAM_IDENTIFIER="$(/usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2; exit }' \
  "$SIGNATURE_METADATA")"
SIGNATURE_KIND="$(/usr/bin/awk -F= '$1 == "Signature" { print $2; exit }' \
  "$SIGNATURE_METADATA")"
[[ "$TEAM_IDENTIFIER" == "not set" && "$SIGNATURE_KIND" == "adhoc" ]] \
  || fail "the automated route must be recorded as Team ID absent / ad-hoc"

if [[ -e "$USER_APPLICATIONS_DIRECTORY" || -L "$USER_APPLICATIONS_DIRECTORY" ]]; then
  [[ -d "$USER_APPLICATIONS_DIRECTORY" && ! -L "$USER_APPLICATIONS_DIRECTORY" ]] \
    || fail "the user Applications location is invalid"
else
  /bin/mkdir "$USER_APPLICATIONS_DIRECTORY"
fi
[[ ! -e "$INSTALLED_APP" && ! -L "$INSTALLED_APP" ]] \
  || fail "the run-specific installed path already exists"
/usr/bin/ditto "$STAGED_APP" "$INSTALLED_APP"
/usr/bin/codesign --verify --strict "$INSTALLED_APP"
INSTALLED_EXECUTABLE="$INSTALLED_APP/Contents/MacOS/KinlogueBackupCapabilityProbe"
INSTALLED_SIGNED_ENTITLEMENTS="$TEMP_DIRECTORY/installed-signed-entitlements.plist"
/usr/bin/codesign -d --entitlements :- "$INSTALLED_APP" \
  >"$INSTALLED_SIGNED_ENTITLEMENTS" 2>/dev/null \
  || fail "the installed entitlements could not be extracted"
/usr/bin/cmp -s "$SIGNED_ENTITLEMENTS" "$INSTALLED_SIGNED_ENTITLEMENTS" \
  || fail "installing changed the signed entitlement set"
INSTALLED_SIGNATURE_METADATA="$TEMP_DIRECTORY/installed-signature.txt"
/usr/bin/codesign -d --verbose=4 "$INSTALLED_APP" \
  >/dev/null 2>"$INSTALLED_SIGNATURE_METADATA"

run_probe_with_timeout() {
  local output="$1"
  local timeout_seconds="$2"
  local started=$SECONDS
  local exit_status
  shift 2
  "$INSTALLED_EXECUTABLE" --backup-capability "$@" >"$output" 2>/dev/null &
  PROBE_PID=$!
  while /bin/kill -0 "$PROBE_PID" >/dev/null 2>&1; do
    if (( SECONDS - started >= timeout_seconds )); then
      /bin/kill -TERM "$PROBE_PID" >/dev/null 2>&1 || true
      wait "$PROBE_PID" >/dev/null 2>&1 || true
      PROBE_PID=""
      return 124
    fi
    /bin/sleep 0.1
  done
  if wait "$PROBE_PID"; then
    exit_status=0
  else
    exit_status=$?
  fi
  PROBE_PID=""
  return "$exit_status"
}

run_probe() {
  local output="$1"
  shift
  run_probe_with_timeout "$output" "$PROBE_TIMEOUT_SECONDS" "$@"
}

wait_for_pid() {
  local pid="$1"
  local timeout_seconds="$2"
  local started=$SECONDS
  local exit_status
  while /bin/kill -0 "$pid" >/dev/null 2>&1; do
    if (( SECONDS - started >= timeout_seconds )); then
      /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
      /bin/sleep 1
      /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
      return 124
    fi
    /bin/sleep 0.1
  done
  if wait "$pid"; then
    exit_status=0
  else
    exit_status=$?
  fi
  return "$exit_status"
}

json_string() {
  /usr/bin/plutil -extract "$2" raw -expect string "$1"
}

json_bool() {
  /usr/bin/plutil -extract "$2" raw -expect bool "$1"
}

fixture_send() {
  local operation="$1"
  local root_path="${2:-}"
  local variant="${3:-}"
  local protocol_version="${4:-}"
  local command_file="$TEMP_DIRECTORY/writer-command.plist"
  local command_json

  /usr/bin/plutil -create xml1 "$command_file"
  /usr/bin/plutil -insert operation -string "$operation" "$command_file"
  if [[ -n "$root_path" ]]; then
    /usr/bin/plutil -insert rootPath -string "$root_path" "$command_file"
  fi
  if [[ -n "$variant" ]]; then
    /usr/bin/plutil -insert variant -integer "$variant" "$command_file"
  fi
  if [[ -n "$protocol_version" ]]; then
    /usr/bin/plutil -insert protocolVersion -integer "$protocol_version" "$command_file"
  fi
  command_json="$(/usr/bin/plutil -convert json -o - "$command_file")"
  print -r -p -- "$command_json"
}

fixture_expect() {
  local expected_event="$1"
  local expected_code="${2:-}"
  local response
  local response_file="$TEMP_DIRECTORY/writer-response.json"

  IFS= read -r -t "$FIXTURE_TIMEOUT_SECONDS" -p response || return 1
  print -rn -- "$response" >"$response_file"
  [[ "$(json_string "$response_file" event 2>/dev/null || true)" \
      == "$expected_event" ]] || return 1
  [[ "$(json_bool "$response_file" ok 2>/dev/null || true)" == true \
      || "$expected_event" == operationFailed ]] || return 1
  if [[ -n "$expected_code" ]]; then
    [[ "$(json_string "$response_file" code 2>/dev/null || true)" \
        == "$expected_code" ]] || return 1
  fi
}

stop_writer_process() {
  if [[ -n "$WRITER_PID" && "$WRITER_PID" == <-> ]]; then
    /bin/kill -TERM "$WRITER_PID" >/dev/null 2>&1 || true
    wait "$WRITER_PID" >/dev/null 2>&1 || true
    WRITER_PID=""
  fi
}
activation_case() {
  local scenario="$1"
  local fault="$2"
  local expected_root_state="$3"
  local case_id="$scenario-$fault"
  local seed_out="$TEMP_DIRECTORY/$case_id-seed.json"
  local crash_out="$TEMP_DIRECTORY/$case_id-crash.json"
  local reconcile_out="$TEMP_DIRECTORY/$case_id-reconcile.json"
  local verify_out="$TEMP_DIRECTORY/$case_id-verify.json"

  run_probe "$seed_out" activation-seed --run-id "$RUN_ID" \
    --case-id "$case_id" --scenario "$scenario"
  set +e
  run_probe "$crash_out" activation-execute --run-id "$RUN_ID" \
    --case-id "$case_id" --scenario "$scenario" --fault "$fault"
  local crash_status=$?
  set -e
  [[ "$crash_status" -eq 137 || "$crash_status" -eq 9 ]] || return 1
  run_probe "$reconcile_out" activation-reconcile \
    --run-id "$RUN_ID" --case-id "$case_id"
  run_probe "$verify_out" activation-verify \
    --run-id "$RUN_ID" --case-id "$case_id"
  [[ "$(json_string "$verify_out" rootState)" == "$expected_root_state" \
      && "$(json_bool "$verify_out" mixedState)" == false \
      && "$(json_bool "$verify_out" receiptPresent)" == false \
      && "$(json_bool "$verify_out" stagingPresent)" == false \
      && "$(json_bool "$verify_out" rollbackPresent)" == false \
      && "$(json_bool "$verify_out" semanticValidated)" == true ]] || return 1
}

# A library has a single owner. While another process holds it, activation must be
# turned away before it prepares anything; once the owner lets go, the same
# activation succeeds and the former owner opens the restored library.
occupied_library_activation_case() {
  local case_id="real-writer"
  local refused_out="$TEMP_DIRECTORY/$case_id-refused.json"
  local untouched_out="$TEMP_DIRECTORY/$case_id-untouched.json"
  local activated_out="$TEMP_DIRECTORY/$case_id-activated.json"
  local root_path="$CONTAINER_DIRECTORY/Data/Library/Application Support/Kinlogue/BackupCapability/$RUN_ID/activation-$case_id/Vault"

  run_probe "$TEMP_DIRECTORY/$case_id-seed.json" activation-seed \
    --run-id "$RUN_ID" --case-id "$case_id" --scenario existing || return 1

  coproc "$INSTALLED_EXECUTABLE" 2>/dev/null
  WRITER_PID=$!
  fixture_send handshake "" "" 2 || return 1
  fixture_expect handshake || return 1
  fixture_send openSQLite "$root_path" || return 1
  fixture_expect sqliteOpened || return 1

  local refused_status=0
  run_probe "$refused_out" activation-execute --run-id "$RUN_ID" \
    --case-id "$case_id" --scenario existing --fault none || refused_status=$?
  [[ "$refused_status" -ne 0 \
      && "$(json_string "$refused_out" code 2>/dev/null || true)" \
        == libraryOccupied ]] || return 1

  fixture_send closeSQLite || return 1
  fixture_expect sqliteClosed || return 1
  run_probe "$untouched_out" activation-verify \
    --run-id "$RUN_ID" --case-id "$case_id" || return 1
  [[ "$(json_string "$untouched_out" rootState)" == old \
      && "$(json_bool "$untouched_out" receiptPresent)" == false \
      && "$(json_bool "$untouched_out" stagingPresent)" == false \
      && "$(json_bool "$untouched_out" rollbackPresent)" == false ]] || return 1

  run_probe "$TEMP_DIRECTORY/$case_id-execute.json" activation-execute \
    --run-id "$RUN_ID" --case-id "$case_id" --scenario existing --fault none \
    || return 1
  run_probe "$activated_out" activation-verify \
    --run-id "$RUN_ID" --case-id "$case_id" || return 1
  [[ "$(json_string "$activated_out" rootState)" == new \
      && "$(json_bool "$activated_out" mixedState)" == false \
      && "$(json_bool "$activated_out" receiptPresent)" == false \
      && "$(json_bool "$activated_out" stagingPresent)" == false \
      && "$(json_bool "$activated_out" rollbackPresent)" == false \
      && "$(json_bool "$activated_out" semanticValidated)" == true ]] || return 1

  fixture_send openSQLite "$root_path" || return 1
  fixture_expect sqliteOpened || return 1
  fixture_send closeSQLite || return 1
  fixture_expect sqliteClosed || return 1
  fixture_send exit || return 1
  fixture_expect exiting || return 1
  wait_for_pid "$WRITER_PID" "$FIXTURE_TIMEOUT_SECONDS" || return 1
  WRITER_PID=""
}

ACTIVATION_STATUS="passed"
if ! occupied_library_activation_case; then
  ACTIVATION_STATUS="blocked"
  stop_writer_process
fi
activation_case existing after-intent old \
  || ACTIVATION_STATUS="blocked"
activation_case existing after-writer-reset old \
  || ACTIVATION_STATUS="blocked"
activation_case existing after-old-root-move old \
  || ACTIVATION_STATUS="blocked"
activation_case existing after-new-root-activation new \
  || ACTIVATION_STATUS="blocked"
activation_case existing after-validation new \
  || ACTIVATION_STATUS="blocked"
activation_case existing after-commit new \
  || ACTIVATION_STATUS="blocked"
activation_case absent after-intent absent \
  || ACTIVATION_STATUS="blocked"
activation_case absent after-writer-reset absent \
  || ACTIVATION_STATUS="blocked"
activation_case absent after-new-root-activation new \
  || ACTIVATION_STATUS="blocked"
activation_case absent after-validation new \
  || ACTIVATION_STATUS="blocked"
activation_case absent after-commit new \
  || ACTIVATION_STATUS="blocked"

TRUNCATE_CASE="receipt-truncated"
run_probe "$TEMP_DIRECTORY/truncate-seed.json" activation-seed --run-id "$RUN_ID" \
  --case-id "$TRUNCATE_CASE" --scenario existing
set +e
run_probe "$TEMP_DIRECTORY/truncate-crash.json" activation-execute \
  --run-id "$RUN_ID" --case-id "$TRUNCATE_CASE" --scenario existing \
  --fault after-intent
TRUNCATE_CRASH_STATUS=$?
set -e
if [[ "$TRUNCATE_CRASH_STATUS" -ne 137 && "$TRUNCATE_CRASH_STATUS" -ne 9 ]]; then
  ACTIVATION_STATUS="blocked"
fi
run_probe "$TEMP_DIRECTORY/truncate.json" activation-truncate-receipt \
  --run-id "$RUN_ID" --case-id "$TRUNCATE_CASE"
set +e
run_probe "$TEMP_DIRECTORY/truncate-reconcile.json" activation-reconcile \
  --run-id "$RUN_ID" --case-id "$TRUNCATE_CASE"
TRUNCATE_RECONCILE_STATUS=$?
set -e
if [[ "$TRUNCATE_RECONCILE_STATUS" -eq 0 \
    || "$(json_string "$TEMP_DIRECTORY/truncate-reconcile.json" code 2>/dev/null || true)" \
      != "receiptInvalid" ]]; then
  ACTIVATION_STATUS="blocked"
fi

/bin/mkdir -p "$REPORT_DIRECTORY"
TEMP_REPORT="$TEMP_DIRECTORY/capability-report.json"
/usr/bin/plutil -create xml1 "$TEMP_REPORT"
/usr/bin/plutil -insert schemaVersion -integer 3 "$TEMP_REPORT"
/usr/bin/plutil -insert evidenceID -string "$RUN_ID" "$TEMP_REPORT"
/usr/bin/plutil -insert sourceRevision -string "$(git rev-parse HEAD)" "$TEMP_REPORT"
if [[ -n "$(git status --short --untracked-files=all)" ]]; then
  /usr/bin/plutil -insert sourceTreeDirty -bool true "$TEMP_REPORT"
  /usr/bin/plutil -insert evidenceClass -string architectureEvidence "$TEMP_REPORT"
else
  /usr/bin/plutil -insert sourceTreeDirty -bool false "$TEMP_REPORT"
  /usr/bin/plutil -insert evidenceClass -string candidateEvidence "$TEMP_REPORT"
fi
/usr/bin/plutil -insert osVersion -string "$(/usr/bin/sw_vers -productVersion)" "$TEMP_REPORT"
/usr/bin/plutil -insert osBuild -string "$(/usr/bin/sw_vers -buildVersion)" "$TEMP_REPORT"
/usr/bin/plutil -insert timestampUTC -string \
  "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$TEMP_REPORT"
/usr/bin/plutil -insert signingRoute -string adHoc "$TEMP_REPORT"
/usr/bin/plutil -insert signingTeamID -string absent "$TEMP_REPORT"
/usr/bin/plutil -insert signedEntitlements -string passed "$TEMP_REPORT"
/usr/bin/plutil -insert provisionedSigning -string notExecuted "$TEMP_REPORT"
/usr/bin/plutil -insert developerIDSigning -string notExecuted "$TEMP_REPORT"
/usr/bin/plutil -insert activation -string "$ACTIVATION_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert probeSourceSHA256 -string \
  "$(/usr/bin/shasum -a 256 \
    "$REPO_DIR/Sources/KinlogueStorageProcessFixture/BackupCapabilityProbe.swift" \
    | /usr/bin/awk '{print $1}')" "$TEMP_REPORT"
/usr/bin/plutil -insert installedExecutableSHA256 -string \
  "$(/usr/bin/shasum -a 256 "$INSTALLED_EXECUTABLE" \
    | /usr/bin/awk '{print $1}')" "$TEMP_REPORT"
/usr/bin/plutil -insert signedEntitlementsSHA256 -string \
  "$(/usr/bin/shasum -a 256 "$INSTALLED_SIGNED_ENTITLEMENTS" \
    | /usr/bin/awk '{print $1}')" "$TEMP_REPORT"
/usr/bin/plutil -insert installedSignatureMetadataSHA256 -string \
  "$(/usr/bin/shasum -a 256 "$INSTALLED_SIGNATURE_METADATA" \
    | /usr/bin/awk '{print $1}')" "$TEMP_REPORT"
/usr/bin/plutil -insert installedBundleIdentifier -string \
  "$(/usr/bin/plutil -extract CFBundleIdentifier raw \
    "$INSTALLED_APP/Contents/Info.plist")" "$TEMP_REPORT"
/usr/bin/plutil -insert installedBundleVersion -string \
  "$(/usr/bin/plutil -extract CFBundleShortVersionString raw \
    "$INSTALLED_APP/Contents/Info.plist")" "$TEMP_REPORT"
/usr/bin/plutil -insert installedBundleBuild -string \
  "$(/usr/bin/plutil -extract CFBundleVersion raw \
    "$INSTALLED_APP/Contents/Info.plist")" "$TEMP_REPORT"

/usr/bin/plutil -lint "$TEMP_REPORT" >/dev/null
/usr/bin/plutil -convert json "$TEMP_REPORT"
/bin/cp -p "$TEMP_REPORT" "$FINAL_REPORT"

print -- "Backup capability report: dist/backup-capability-report.json"
print -- "Whole-root activation: $ACTIVATION_STATUS"
print -- "Signing route: ad hoc; provisioned / Developer ID: notExecuted"

[[ "$ACTIVATION_STATUS" == passed ]] || exit 2
