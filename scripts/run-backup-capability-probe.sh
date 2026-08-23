#!/bin/zsh
set -euo pipefail

umask 077

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
ENTITLEMENTS_FILE="$REPO_DIR/packaging/KinlogueBackupCapabilityProbe.entitlements"
BUILD_ROOT="$REPO_DIR/.build/backup-capability-probe"
REPORT_DIRECTORY="$REPO_DIR/dist"
FINAL_REPORT="$REPORT_DIRECTORY/backup-capability-report.json"
FINAL_CHUNK_REPORT="$REPORT_DIRECTORY/backup-capability-chunk-report.json"
FINAL_NAMED_DATASET_REPORT="$REPORT_DIRECTORY/backup-capability-named-dataset-report.json"
USER_HOME_DIRECTORY="${HOME:-}"
USER_APPLICATIONS_DIRECTORY="$USER_HOME_DIRECTORY/Applications"
INTERACTIVE_BOOKMARK=false
SELECTED_CHUNK_BYTE_COUNT=262144
EXPECTED_GOLDEN_VECTOR_SHA256=25d744f5f364f17b6985f761a89fd3b21ad5b25895a3c231037115f9dafd6bbd
PROBE_TIMEOUT_SECONDS=120
NAMED_DATASET_TIMEOUT_SECONDS=1200
FIXTURE_TIMEOUT_SECONDS=30
EXPECTED_NAMED_DATASET_SOURCE_SHA256=f2ab03c9f7b22a2499e46e35c1e3580e323601d9e2cfc94d4071614e74469c9b
TEMP_DIRECTORY=""
INSTALLED_APP=""
PREVIOUS_APP=""
UPGRADE_APP=""
BOOKMARK_DIRECTORY=""
CONTAINER_DIRECTORY=""
WRITER_PID=""
ACTIVATION_PID=""
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
  if [[ -n "$ACTIVATION_PID" && "$ACTIVATION_PID" == <-> ]]; then
    /bin/kill -TERM "$ACTIVATION_PID" >/dev/null 2>&1 || true
    wait "$ACTIVATION_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$WRITER_PID" && "$WRITER_PID" == <-> ]]; then
    /bin/kill -TERM "$WRITER_PID" >/dev/null 2>&1 || true
    wait "$WRITER_PID" >/dev/null 2>&1 || true
  fi
  for owned_app in "$INSTALLED_APP" "$PREVIOUS_APP" "$UPGRADE_APP"; do
    [[ -n "$owned_app" ]] || continue
    [[ "$owned_app" == "$INSTALLED_APP" \
        || "$owned_app" == "$PREVIOUS_APP" \
        || "$owned_app" == "$UPGRADE_APP" ]] || continue
    [[ "$owned_app" == "$USER_APPLICATIONS_DIRECTORY/$APP_BASENAME" \
        || "$owned_app" == "$USER_APPLICATIONS_DIRECTORY/$APP_BASENAME.previous" \
        || "$owned_app" == "$USER_APPLICATIONS_DIRECTORY/$APP_BASENAME.upgrade" ]] || continue
    /usr/bin/find -P -x "$owned_app" -depth -mindepth 1 -delete \
      >/dev/null 2>&1 || true
    /bin/rmdir -- "$owned_app" >/dev/null 2>&1 || true
  done
  if [[ -n "$BOOKMARK_DIRECTORY" \
      && "$BOOKMARK_DIRECTORY" == /tmp/kinlogue-backup-bookmark-* ]]; then
    /usr/bin/find -P -x "$BOOKMARK_DIRECTORY" -depth -mindepth 1 -delete \
      >/dev/null 2>&1 || true
    /bin/rmdir -- "$BOOKMARK_DIRECTORY" >/dev/null 2>&1 || true
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

if [[ "$#" -gt 1 ]]; then
  fail "usage: $0 [--interactive-bookmark]"
fi
if [[ "$#" -eq 1 ]]; then
  [[ "$1" == "--interactive-bookmark" ]] \
    || fail "usage: $0 [--interactive-bookmark]"
  INTERACTIVE_BOOKMARK=true
fi

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
PREVIOUS_APP="$INSTALLED_APP.previous"
UPGRADE_APP="$INSTALLED_APP.upgrade"
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

STAGED_V1="$TEMP_DIRECTORY/v1.app"
make_app "$STAGED_V1" 1

SIGNED_ENTITLEMENTS="$TEMP_DIRECTORY/signed-entitlements.plist"
# The source plist is not evidence: dump the entitlements from the signed artifact.
/usr/bin/codesign -d --entitlements :- "$STAGED_V1" \
  >"$SIGNED_ENTITLEMENTS" 2>/dev/null \
  || fail "the signed entitlements could not be extracted"
/usr/bin/plutil -lint "$SIGNED_ENTITLEMENTS" >/dev/null \
  || fail "the signed entitlements are invalid"
for entitlement_key in \
  'com\.apple\.security\.app-sandbox' \
  'com\.apple\.security\.files\.user-selected\.read-write' \
  'com\.apple\.security\.files\.bookmarks\.app-scope'; do
  [[ "$(/usr/bin/plutil -extract "$entitlement_key" raw -expect bool \
      "$SIGNED_ENTITLEMENTS")" == true ]] \
    || fail "the signed artifact is missing a required entitlement"
done
NORMALIZED_ENTITLEMENTS="$TEMP_DIRECTORY/normalized-entitlements.plist"
/bin/cp -p "$SIGNED_ENTITLEMENTS" "$NORMALIZED_ENTITLEMENTS"
for entitlement_key in \
  'com\.apple\.security\.app-sandbox' \
  'com\.apple\.security\.files\.user-selected\.read-write' \
  'com\.apple\.security\.files\.bookmarks\.app-scope'; do
  /usr/bin/plutil -remove "$entitlement_key" "$NORMALIZED_ENTITLEMENTS"
done
[[ "$(/usr/bin/plutil -convert json -o - "$NORMALIZED_ENTITLEMENTS")" == '{}' ]] \
  || fail "the signed artifact has an unexpected entitlement"

SIGNATURE_METADATA="$TEMP_DIRECTORY/signature.txt"
/usr/bin/codesign -d --verbose=4 "$STAGED_V1" >/dev/null 2>"$SIGNATURE_METADATA"
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
/usr/bin/ditto "$STAGED_V1" "$INSTALLED_APP"
/usr/bin/codesign --verify --strict "$INSTALLED_APP"
INSTALLED_EXECUTABLE="$INSTALLED_APP/Contents/MacOS/KinlogueBackupCapabilityProbe"

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

all_statuses_passed() {
  local cell_status
  for cell_status in "$@"; do
    [[ "$cell_status" == passed ]] || return 1
  done
}

json_string() {
  /usr/bin/plutil -extract "$2" raw -expect string "$1"
}

json_bool() {
  /usr/bin/plutil -extract "$2" raw -expect bool "$1"
}

selected_target_passed() {
  local output="$1"
  local target_available
  local private_available
  [[ "$(json_string "$output" status 2>/dev/null || true)" == passed \
      && "$(json_string "$output" targetCategory 2>/dev/null || true)" \
        == ordinaryDirectory \
      && "$(json_bool "$output" testBookmarkSeam 2>/dev/null || true)" == false \
      && "$(json_bool "$output" securityScopeStarted 2>/dev/null || true)" == true \
      && "$(json_bool "$output" coordinatedPublication 2>/dev/null || true)" == true \
      && "$(json_bool "$output" selectedIdentityMatched 2>/dev/null || true)" == true \
      && "$(json_bool "$output" repositoryIdentityMatched 2>/dev/null || true)" == true \
      && "$(json_bool "$output" nonSuccessWorkName 2>/dev/null || true)" == true \
      && "$(json_bool "$output" exclusiveNonOverwrite 2>/dev/null || true)" == true \
      && "$(json_bool "$output" finalIdentityReadBack 2>/dev/null || true)" == true \
      && "$(json_bool "$output" parentSynced 2>/dev/null || true)" == true \
      && "$(json_bool "$output" plaintextCanaryAbsent 2>/dev/null || true)" == true \
      && "$(json_bool "$output" targetAvailableCapacitySufficient \
        2>/dev/null || true)" == true \
      && "$(json_bool "$output" privateRestoreAvailableCapacitySufficient \
        2>/dev/null || true)" == true ]] || return 1
  target_available="$(/usr/bin/plutil -extract targetAvailableCapacityByteCount \
    raw -expect integer "$output")" || return 1
  private_available="$(/usr/bin/plutil -extract \
    privateRestoreAvailableCapacityByteCount raw -expect integer "$output")" \
    || return 1
  (( target_available > 0 && private_available > 0 ))
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

stop_activation_process() {
  if [[ -n "$ACTIVATION_PID" && "$ACTIVATION_PID" == <-> ]]; then
    /bin/kill -TERM "$ACTIVATION_PID" >/dev/null 2>&1 || true
    wait "$ACTIVATION_PID" >/dev/null 2>&1 || true
    ACTIVATION_PID=""
  fi
}

stop_writer_process() {
  if [[ -n "$WRITER_PID" && "$WRITER_PID" == <-> ]]; then
    /bin/kill -TERM "$WRITER_PID" >/dev/null 2>&1 || true
    wait "$WRITER_PID" >/dev/null 2>&1 || true
    WRITER_PID=""
  fi
}

IDENTITY_STATUS="blocked"
IDENTITY_MECHANICS_STATUS="blocked"
IDENTITY_CREATE_STATUS="blocked"
IDENTITY_RELAUNCH_STATUS="blocked"
IDENTITY_UPGRADE_STATUS="blocked"
IDENTITY_PERMISSION_FAILURE="notExecuted"
IDENTITY_ADVERSARIAL_STATUS="blocked"
IDENTITY_CREATE_OUT="$TEMP_DIRECTORY/identity-create.json"
IDENTITY_READ_OUT="$TEMP_DIRECTORY/identity-read.json"
if run_probe "$IDENTITY_CREATE_OUT" identity-create --run-id "$RUN_ID" \
    && [[ "$(json_string "$IDENTITY_CREATE_OUT" status)" == passed ]]; then
  IDENTITY_CREATE_STATUS="passed"
  if run_probe "$IDENTITY_READ_OUT" identity-read --run-id "$RUN_ID" \
      && [[ "$(json_string "$IDENTITY_READ_OUT" publicIdentity)" \
        == "$(json_string "$IDENTITY_CREATE_OUT" publicIdentity)" \
      && "$(json_string "$IDENTITY_READ_OUT" descriptorDigest)" \
        == "$(json_string "$IDENTITY_CREATE_OUT" descriptorDigest)" ]]; then
    IDENTITY_RELAUNCH_STATUS="passed"
  fi
fi

PUBLIC_ONLY_STATUS="blocked"
SEED_ONLY_STATUS="blocked"
CRYPTO_MECHANICS_STATUS="blocked"
CAPABILITY_DIRECTORY_ROOT="$CONTAINER_DIRECTORY/Data/Library/Application Support/Kinlogue/BackupCapability"
ENROLLMENT_DIRECTORY="$CAPABILITY_DIRECTORY_ROOT/$RUN_ID"
WRITER_RUN_ID="$RUN_ID-writer"
RECOVERY_RUN_ID="$RUN_ID-recovery"
WRITER_DIRECTORY="$CAPABILITY_DIRECTORY_ROOT/$WRITER_RUN_ID"
RECOVERY_DIRECTORY="$CAPABILITY_DIRECTORY_ROOT/$RECOVERY_RUN_ID"
ENROLLMENT_IDENTITY="$ENROLLMENT_DIRECTORY/device-identity.json"
ENROLLMENT_SEED="$ENROLLMENT_DIRECTORY/synthetic-recovery-seed.bin"
WRITER_IDENTITY="$WRITER_DIRECTORY/device-identity.json"
WRITER_CHECKPOINT="$WRITER_DIRECTORY/synthetic-checkpoint.json"
RECOVERY_SEED="$RECOVERY_DIRECTORY/synthetic-recovery-seed.bin"
RECOVERY_CHECKPOINT="$RECOVERY_DIRECTORY/synthetic-checkpoint.json"
PUBLIC_WRITER_OUT="$TEMP_DIRECTORY/crypto-public-writer.json"
PUBLIC_DENIAL_OUT="$TEMP_DIRECTORY/crypto-public-denial.json"
SEED_RECOVERY_OUT="$TEMP_DIRECTORY/crypto-seed-recovery.json"

if [[ "$IDENTITY_RELAUNCH_STATUS" == passed \
    && -f "$ENROLLMENT_IDENTITY" && ! -L "$ENROLLMENT_IDENTITY" \
    && -f "$ENROLLMENT_SEED" && ! -L "$ENROLLMENT_SEED" ]]; then
  /bin/mkdir "$WRITER_DIRECTORY" "$RECOVERY_DIRECTORY"
  /bin/chmod 0700 "$WRITER_DIRECTORY" "$RECOVERY_DIRECTORY"
  /bin/cp -p "$ENROLLMENT_IDENTITY" "$WRITER_IDENTITY"
  /bin/cp -p "$ENROLLMENT_SEED" "$RECOVERY_SEED"
  /bin/chmod 0600 "$WRITER_IDENTITY" "$RECOVERY_SEED"
  /bin/rm -- "$ENROLLMENT_SEED"

  if [[ ! -e "$WRITER_DIRECTORY/synthetic-recovery-seed.bin" \
      && ! -e "$RECOVERY_DIRECTORY/device-identity.json" \
      && ! -e "$RECOVERY_DIRECTORY/directory.bookmark" ]] \
      && run_probe "$PUBLIC_WRITER_OUT" crypto-public-writer \
        --run-id "$WRITER_RUN_ID" \
      && [[ "$(json_bool "$PUBLIC_WRITER_OUT" publicOnlyEncrypted)" == true \
      && "$(json_bool "$PUBLIC_WRITER_OUT" profileContainedRecoveryMaterial)" \
        == false \
      && -f "$WRITER_CHECKPOINT" && ! -L "$WRITER_CHECKPOINT" ]]; then
    if run_probe "$PUBLIC_DENIAL_OUT" crypto-public-decrypt \
        --run-id "$WRITER_RUN_ID"; then
      PUBLIC_DENIAL_EXIT=0
    else
      PUBLIC_DENIAL_EXIT=$?
    fi
    if [[ "$PUBLIC_DENIAL_EXIT" -ne 0 \
        && "$(json_string "$PUBLIC_DENIAL_OUT" code 2>/dev/null || true)" \
          == recoveryMaterialUnavailable ]]; then
      PUBLIC_ONLY_STATUS="passed"
    fi

    /bin/cp -p "$WRITER_CHECKPOINT" "$RECOVERY_CHECKPOINT"
    /bin/chmod 0600 "$RECOVERY_CHECKPOINT"
    if run_probe "$SEED_RECOVERY_OUT" crypto-seed-recover \
        --run-id "$RECOVERY_RUN_ID" \
        && [[ "$(json_bool "$SEED_RECOVERY_OUT" seedOnlyRecovered)" == true \
        && "$(json_bool "$SEED_RECOVERY_OUT" rootSignatureVerified)" == true \
        && "$(json_bool "$SEED_RECOVERY_OUT" deviceSignatureVerified)" == true \
        && "$(json_bool "$SEED_RECOVERY_OUT" reenrollmentVerified)" == true \
        && "$(json_string "$SEED_RECOVERY_OUT" checkpointDigest)" \
          == "$(json_string "$PUBLIC_WRITER_OUT" checkpointDigest)" ]]; then
      SEED_ONLY_STATUS="passed"
    fi
  fi
fi
if [[ "$PUBLIC_ONLY_STATUS" == passed && "$SEED_ONLY_STATUS" == passed ]]; then
  CRYPTO_MECHANICS_STATUS="passed"
fi

REPOSITORY_OUT="$TEMP_DIRECTORY/repository-publication.json"
REPOSITORY_PUBLICATION_STATUS="blocked"
CAPACITY_STATUS="blocked"
REPOSITORY_MECHANICS_STATUS="blocked"
REPOSITORY_BASELINE_STATUS="blocked"
REPOSITORY_ADVERSARIAL_STATUS="blocked"
CAPACITY_PREFLIGHT_STATUS="blocked"
if run_probe "$REPOSITORY_OUT" repository-publication --run-id "$RUN_ID" \
    && [[ "$(json_bool "$REPOSITORY_OUT" nonSuccessWorkName)" == true \
    && "$(json_bool "$REPOSITORY_OUT" exclusiveNonOverwrite)" == true \
    && "$(json_bool "$REPOSITORY_OUT" finalIdentityReadBack)" == true \
    && "$(json_bool "$REPOSITORY_OUT" parentSynced)" == true \
    && "$(json_bool "$REPOSITORY_OUT" coordinatedPublication)" == true \
    && "$(json_bool "$REPOSITORY_OUT" plaintextCanaryAbsent)" == true ]]; then
  REPOSITORY_BASELINE_STATUS="passed"
  if [[ "$(json_bool "$REPOSITORY_OUT" availableCapacitySufficient)" == true ]]; then
    CAPACITY_PREFLIGHT_STATUS="passed"
  fi
fi

REPOSITORY_PARENT_REPLACEMENT_OUT="$TEMP_DIRECTORY/repository-parent-replacement.json"
REPOSITORY_FINAL_REPLACEMENT_OUT="$TEMP_DIRECTORY/repository-final-replacement.json"
set +e
run_probe "$REPOSITORY_PARENT_REPLACEMENT_OUT" repository-publication \
  --run-id "$RUN_ID-repo-parent" --case-id parent-replacement
REPOSITORY_PARENT_REPLACEMENT_EXIT=$?
run_probe "$REPOSITORY_FINAL_REPLACEMENT_OUT" repository-publication \
  --run-id "$RUN_ID-repo-final" --case-id final-replacement
REPOSITORY_FINAL_REPLACEMENT_EXIT=$?
set -e
if [[ "$REPOSITORY_PARENT_REPLACEMENT_EXIT" -ne 0 \
    && "$REPOSITORY_FINAL_REPLACEMENT_EXIT" -ne 0 \
    && "$(json_string "$REPOSITORY_PARENT_REPLACEMENT_OUT" code 2>/dev/null || true)" \
      == repositoryInvalid \
    && "$(json_string "$REPOSITORY_FINAL_REPLACEMENT_OUT" code 2>/dev/null || true)" \
      == repositoryInvalid ]]; then
  REPOSITORY_ADVERSARIAL_STATUS="passed"
fi
if [[ "$REPOSITORY_BASELINE_STATUS" == passed \
    && "$REPOSITORY_ADVERSARIAL_STATUS" == passed ]]; then
  REPOSITORY_MECHANICS_STATUS="passed"
fi

BOOKMARK_STATUS="notExecuted"
BOOKMARK_STALE_STATUS="notExecuted"
BOOKMARK_UPGRADE_STATUS="notExecuted"
BOOKMARK_BASELINE_STATUS="notExecuted"
SELECTED_TARGET_ADVERSARIAL_STATUS="notExecuted"
ORDINARY_DIRECTORY_STATUS="notExecuted"
ORDINARY_DIRECTORY_CAPACITY_STATUS="notExecuted"
SELECTED_TARGET_AVAILABLE_CAPACITY_BYTE_COUNT=""
APP_PRIVATE_RESTORE_AVAILABLE_CAPACITY_BYTE_COUNT=""
if [[ "$INTERACTIVE_BOOKMARK" == true ]]; then
  BOOKMARK_STATUS="blocked"
  BOOKMARK_BASELINE_STATUS="blocked"
  BOOKMARK_UPGRADE_STATUS="blocked"
  BOOKMARK_STALE_STATUS="notExecuted"
  SELECTED_TARGET_ADVERSARIAL_STATUS="blocked"
  ORDINARY_DIRECTORY_STATUS="blocked"
  ORDINARY_DIRECTORY_CAPACITY_STATUS="blocked"
  BOOKMARK_DIRECTORY="/tmp/kinlogue-backup-bookmark-$RUN_ID"
  /bin/mkdir "$BOOKMARK_DIRECTORY"
  CREATE_BOOKMARK_OUT="$TEMP_DIRECTORY/bookmark-create.json"
  RESOLVE_BOOKMARK_OUT="$TEMP_DIRECTORY/bookmark-resolve.json"
  SELECTED_BASELINE_OUT="$TEMP_DIRECTORY/selected-target-baseline.json"
  SELECTED_PARENT_REPLACEMENT_OUT="$TEMP_DIRECTORY/selected-target-parent-replacement.json"
  SELECTED_FINAL_REPLACEMENT_OUT="$TEMP_DIRECTORY/selected-target-final-replacement.json"
  print -u2 -- "Choose the empty Kinlogue probe directory shown by the panel."
  if run_probe "$CREATE_BOOKMARK_OUT" bookmark-create \
      --run-id "$RUN_ID" --candidate-directory "$BOOKMARK_DIRECTORY" \
      && run_probe "$RESOLVE_BOOKMARK_OUT" bookmark-resolve --run-id "$RUN_ID" \
      && [[ "$(json_bool "$RESOLVE_BOOKMARK_OUT" scopeStarted)" == true ]] \
      && run_probe "$SELECTED_BASELINE_OUT" selected-target-publication \
        --run-id "$RUN_ID" --case-id baseline \
      && selected_target_passed "$SELECTED_BASELINE_OUT"; then
    BOOKMARK_BASELINE_STATUS="passed"
    SELECTED_TARGET_AVAILABLE_CAPACITY_BYTE_COUNT="$(/usr/bin/plutil -extract \
      targetAvailableCapacityByteCount raw -expect integer \
      "$SELECTED_BASELINE_OUT")"
    APP_PRIVATE_RESTORE_AVAILABLE_CAPACITY_BYTE_COUNT="$(/usr/bin/plutil -extract \
      privateRestoreAvailableCapacityByteCount raw -expect integer \
      "$SELECTED_BASELINE_OUT")"

    set +e
    run_probe "$SELECTED_PARENT_REPLACEMENT_OUT" selected-target-publication \
      --run-id "$RUN_ID" --case-id parent-replacement
    SELECTED_PARENT_REPLACEMENT_EXIT=$?
    run_probe "$SELECTED_FINAL_REPLACEMENT_OUT" selected-target-publication \
      --run-id "$RUN_ID" --case-id final-replacement
    SELECTED_FINAL_REPLACEMENT_EXIT=$?
    set -e
    if [[ "$SELECTED_PARENT_REPLACEMENT_EXIT" -ne 0 \
        && "$SELECTED_FINAL_REPLACEMENT_EXIT" -ne 0 \
        && "$(json_string "$SELECTED_PARENT_REPLACEMENT_OUT" code \
          2>/dev/null || true)" == repositoryInvalid \
        && "$(json_string "$SELECTED_FINAL_REPLACEMENT_OUT" code \
          2>/dev/null || true)" == repositoryInvalid ]]; then
      SELECTED_TARGET_ADVERSARIAL_STATUS="passed"
    fi
  else
    print -u2 -- "Ordinary-directory proof did not complete; rerun and choose the displayed probe directory within 120 seconds."
  fi
fi
if [[ "$BOOKMARK_BASELINE_STATUS" == passed \
    && "$SELECTED_TARGET_ADVERSARIAL_STATUS" != passed ]]; then
  print -u2 -- "The selected-directory replacement checks failed closed; inspect the generated report and rerun."
fi

STAGED_V2="$TEMP_DIRECTORY/v2.app"
make_app "$STAGED_V2" 2
/usr/bin/ditto "$STAGED_V2" "$UPGRADE_APP"
/bin/mv "$INSTALLED_APP" "$PREVIOUS_APP"
/bin/mv "$UPGRADE_APP" "$INSTALLED_APP"
/usr/bin/codesign --verify --strict "$INSTALLED_APP"
INSTALLED_EXECUTABLE="$INSTALLED_APP/Contents/MacOS/KinlogueBackupCapabilityProbe"
FINAL_SIGNED_ENTITLEMENTS="$TEMP_DIRECTORY/final-signed-entitlements.plist"
/usr/bin/codesign -d --entitlements :- "$INSTALLED_APP" \
  >"$FINAL_SIGNED_ENTITLEMENTS" 2>/dev/null \
  || fail "the final installed entitlements could not be extracted"
/usr/bin/plutil -lint "$FINAL_SIGNED_ENTITLEMENTS" >/dev/null \
  || fail "the final installed entitlements are invalid"
/usr/bin/cmp -s "$SIGNED_ENTITLEMENTS" "$FINAL_SIGNED_ENTITLEMENTS" \
  || fail "the upgrade changed the signed entitlement set"
FINAL_SIGNATURE_METADATA="$TEMP_DIRECTORY/final-signature.txt"
/usr/bin/codesign -d --verbose=4 "$INSTALLED_APP" \
  >/dev/null 2>"$FINAL_SIGNATURE_METADATA"

UPGRADE_IDENTITY_OUT="$TEMP_DIRECTORY/identity-upgrade.json"
if [[ "$IDENTITY_RELAUNCH_STATUS" == passed ]] \
    && run_probe "$UPGRADE_IDENTITY_OUT" identity-upgrade --run-id "$RUN_ID" \
    && [[ "$(json_string "$UPGRADE_IDENTITY_OUT" publicIdentity)" \
      == "$(json_string "$IDENTITY_CREATE_OUT" publicIdentity)" \
    && "$(/usr/bin/plutil -extract generation raw -expect integer \
      "$UPGRADE_IDENTITY_OUT")" == 2 ]]; then
  IDENTITY_UPGRADE_STATUS="passed"
fi
IDENTITY_RECORD="$CONTAINER_DIRECTORY/Data/Library/Application Support/Kinlogue/BackupCapability/$RUN_ID/device-identity.json"
IDENTITY_PERMISSION_OUT="$TEMP_DIRECTORY/identity-permission.json"
if [[ "$IDENTITY_UPGRADE_STATUS" == passed \
    && -f "$IDENTITY_RECORD" && ! -L "$IDENTITY_RECORD" ]]; then
  /bin/chmod 0644 "$IDENTITY_RECORD"
  set +e
  run_probe "$IDENTITY_PERMISSION_OUT" identity-read --run-id "$RUN_ID"
  IDENTITY_PERMISSION_EXIT=$?
  set -e
  /bin/chmod 0600 "$IDENTITY_RECORD"
  if [[ "$IDENTITY_PERMISSION_EXIT" -ne 0 \
      && "$(json_string "$IDENTITY_PERMISSION_OUT" code 2>/dev/null || true)" \
        == identityPermissionFailure ]] \
      && run_probe "$TEMP_DIRECTORY/identity-permission-recovered.json" \
        identity-read --run-id "$RUN_ID"; then
    IDENTITY_PERMISSION_FAILURE="passed"
  fi
fi

IDENTITY_ADVERSARIAL_RUN_ID="$RUN_ID-adversary"
IDENTITY_ADVERSARIAL_CREATE_OUT="$TEMP_DIRECTORY/identity-adversarial-create.json"
IDENTITY_PARENT_REPLACEMENT_OUT="$TEMP_DIRECTORY/identity-parent-replacement.json"
IDENTITY_FILE_REPLACEMENT_OUT="$TEMP_DIRECTORY/identity-file-replacement.json"
IDENTITY_UPGRADE_REPLACEMENT_OUT="$TEMP_DIRECTORY/identity-upgrade-replacement.json"
IDENTITY_ADVERSARIAL_FINAL_OUT="$TEMP_DIRECTORY/identity-adversarial-final.json"
if run_probe "$IDENTITY_ADVERSARIAL_CREATE_OUT" identity-create \
    --run-id "$IDENTITY_ADVERSARIAL_RUN_ID"; then
  set +e
  run_probe "$IDENTITY_PARENT_REPLACEMENT_OUT" identity-read \
    --run-id "$IDENTITY_ADVERSARIAL_RUN_ID" --case-id parent-replacement
  IDENTITY_PARENT_REPLACEMENT_EXIT=$?
  run_probe "$IDENTITY_FILE_REPLACEMENT_OUT" identity-read \
    --run-id "$IDENTITY_ADVERSARIAL_RUN_ID" --case-id leaf-replacement
  IDENTITY_FILE_REPLACEMENT_EXIT=$?
  run_probe "$IDENTITY_UPGRADE_REPLACEMENT_OUT" identity-upgrade \
    --run-id "$IDENTITY_ADVERSARIAL_RUN_ID" --case-id leaf-replacement
  IDENTITY_UPGRADE_REPLACEMENT_EXIT=$?
  set -e
  if [[ "$IDENTITY_PARENT_REPLACEMENT_EXIT" -ne 0 \
      && "$IDENTITY_FILE_REPLACEMENT_EXIT" -ne 0 \
      && "$IDENTITY_UPGRADE_REPLACEMENT_EXIT" -ne 0 \
      && "$(json_string "$IDENTITY_PARENT_REPLACEMENT_OUT" code 2>/dev/null || true)" \
        == identityInvalid \
      && "$(json_string "$IDENTITY_FILE_REPLACEMENT_OUT" code 2>/dev/null || true)" \
        == identityInvalid \
      && "$(json_string "$IDENTITY_UPGRADE_REPLACEMENT_OUT" code 2>/dev/null || true)" \
        == identityInvalid ]]; then
    if run_probe "$IDENTITY_ADVERSARIAL_FINAL_OUT" identity-read \
        --run-id "$IDENTITY_ADVERSARIAL_RUN_ID" \
        && [[ "$(/usr/bin/plutil -extract generation raw -expect integer \
          "$IDENTITY_ADVERSARIAL_FINAL_OUT")" == 1 ]]; then
      IDENTITY_ADVERSARIAL_STATUS="passed"
    fi
  fi
fi
if [[ "$IDENTITY_CREATE_STATUS" == passed \
    && "$IDENTITY_RELAUNCH_STATUS" == passed \
    && "$IDENTITY_UPGRADE_STATUS" == passed \
    && "$IDENTITY_PERMISSION_FAILURE" == passed \
    && "$IDENTITY_ADVERSARIAL_STATUS" == passed ]]; then
  IDENTITY_MECHANICS_STATUS="passed"
fi

if [[ "$BOOKMARK_BASELINE_STATUS" == "passed" \
    && "$SELECTED_TARGET_ADVERSARIAL_STATUS" == "passed" ]]; then
  UPGRADE_BOOKMARK_OUT="$TEMP_DIRECTORY/bookmark-upgrade-read.json"
  UPGRADE_SELECTED_TARGET_OUT="$TEMP_DIRECTORY/selected-target-upgrade.json"
  if run_probe "$UPGRADE_BOOKMARK_OUT" bookmark-resolve --run-id "$RUN_ID" \
      && [[ "$(json_bool "$UPGRADE_BOOKMARK_OUT" scopeStarted)" == true ]] \
      && run_probe "$UPGRADE_SELECTED_TARGET_OUT" selected-target-publication \
        --run-id "$RUN_ID" --case-id upgrade \
      && selected_target_passed "$UPGRADE_SELECTED_TARGET_OUT"; then
    BOOKMARK_UPGRADE_STATUS="passed"
  else
    BOOKMARK_UPGRADE_STATUS="blocked"
    print -u2 -- "The persisted bookmark or second exclusive publication did not survive the installed upgrade."
  fi
  if [[ "$BOOKMARK_UPGRADE_STATUS" == "passed" ]]; then
    MOVED_BOOKMARK_DIRECTORY="$BOOKMARK_DIRECTORY.moved"
    /bin/mv "$BOOKMARK_DIRECTORY" "$MOVED_BOOKMARK_DIRECTORY"
    BOOKMARK_DIRECTORY="$MOVED_BOOKMARK_DIRECTORY"
    STALE_BOOKMARK_OUT="$TEMP_DIRECTORY/bookmark-stale-read.json"
    FRESH_BOOKMARK_OUT="$TEMP_DIRECTORY/bookmark-fresh-read.json"
    STALE_SELECTED_TARGET_OUT="$TEMP_DIRECTORY/selected-target-stale.json"
    if run_probe "$STALE_BOOKMARK_OUT" bookmark-resolve \
        --run-id "$RUN_ID" --refresh-if-stale \
        && [[ "$(json_bool "$STALE_BOOKMARK_OUT" stale)" == true \
        && "$(json_bool "$STALE_BOOKMARK_OUT" refreshed)" == true ]] \
        && run_probe "$STALE_SELECTED_TARGET_OUT" selected-target-publication \
          --run-id "$RUN_ID" --case-id stale \
        && selected_target_passed "$STALE_SELECTED_TARGET_OUT" \
        && run_probe "$FRESH_BOOKMARK_OUT" bookmark-resolve --run-id "$RUN_ID" \
        && [[ "$(json_bool "$FRESH_BOOKMARK_OUT" stale)" == false ]]; then
      BOOKMARK_STALE_STATUS="passed"
      BOOKMARK_STATUS="passed"
      ORDINARY_DIRECTORY_STATUS="passed"
      ORDINARY_DIRECTORY_CAPACITY_STATUS="passed"
      REPOSITORY_PUBLICATION_STATUS="passed"
    else
      BOOKMARK_STALE_STATUS="blocked"
      print -u2 -- "The moved-directory bookmark refresh or post-refresh publication did not complete."
    fi
  fi
fi

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

real_writer_activation_case() {
  local case_id="real-writer"
  local activated_out="$TEMP_DIRECTORY/$case_id-activated.json"
  local final_out="$TEMP_DIRECTORY/$case_id-final.json"
  local activation_out="$TEMP_DIRECTORY/$case_id-execute.json"
  local root_path="$CONTAINER_DIRECTORY/Data/Library/Application Support/Kinlogue/BackupCapability/$RUN_ID/activation-$case_id/Vault"

  run_probe "$TEMP_DIRECTORY/$case_id-seed.json" activation-seed-writer \
    --run-id "$RUN_ID" --case-id "$case_id" --scenario existing || return 1

  coproc "$INSTALLED_EXECUTABLE" 2>/dev/null
  WRITER_PID=$!
  fixture_send handshake "" "" 2 || return 1
  fixture_expect handshake || return 1
  fixture_send loadCatalog "$root_path" || return 1
  fixture_expect catalogLoaded || return 1
  fixture_send holdCatalogCommit "" 1 || return 1
  fixture_expect leaseHeld || return 1

  "$INSTALLED_EXECUTABLE" --backup-capability activation-execute \
    --run-id "$RUN_ID" --case-id "$case_id" --scenario existing --fault none \
    >"$activation_out" 2>/dev/null &
  ACTIVATION_PID=$!
  /bin/sleep 1
  /bin/kill -0 "$ACTIVATION_PID" >/dev/null 2>&1 || return 1

  fixture_send release || return 1
  fixture_expect catalogCommitted || return 1
  local activation_status=0
  wait_for_pid "$ACTIVATION_PID" "$PROBE_TIMEOUT_SECONDS" \
    || activation_status=$?
  ACTIVATION_PID=""
  [[ "$activation_status" -eq 0 ]] || return 1
  run_probe "$activated_out" activation-verify \
    --run-id "$RUN_ID" --case-id "$case_id" || return 1
  [[ "$(json_string "$activated_out" rootState)" == new \
      && "$(json_bool "$activated_out" receiptPresent)" == false \
      && "$(json_bool "$activated_out" stagingPresent)" == false \
      && "$(json_bool "$activated_out" rollbackPresent)" == false \
      && "$(json_bool "$activated_out" semanticValidated)" == true ]] || return 1

  fixture_send commitLoadedCatalog "" 2 || return 1
  fixture_expect operationFailed rootReplaced || return 1
  run_probe "$final_out" activation-verify \
    --run-id "$RUN_ID" --case-id "$case_id" || return 1
  [[ "$(json_string "$final_out" rootState)" == new \
      && "$(json_bool "$final_out" mixedState)" == false \
      && "$(json_bool "$final_out" semanticValidated)" == true ]] || return 1
  fixture_send exit || return 1
  fixture_expect exiting || return 1
  wait_for_pid "$WRITER_PID" "$FIXTURE_TIMEOUT_SECONDS" || return 1
  WRITER_PID=""
}

ACTIVATION_MECHANICS_STATUS="passed"
ACTIVATION_STATUS="blocked"
if ! real_writer_activation_case; then
  ACTIVATION_MECHANICS_STATUS="blocked"
  stop_activation_process
  stop_writer_process
fi
activation_case existing after-intent old \
  || ACTIVATION_MECHANICS_STATUS="blocked"
activation_case existing after-writer-reset old \
  || ACTIVATION_MECHANICS_STATUS="blocked"
activation_case existing after-old-root-move old \
  || ACTIVATION_MECHANICS_STATUS="blocked"
activation_case existing after-new-root-activation new \
  || ACTIVATION_MECHANICS_STATUS="blocked"
activation_case existing after-validation new \
  || ACTIVATION_MECHANICS_STATUS="blocked"
activation_case existing after-commit new \
  || ACTIVATION_MECHANICS_STATUS="blocked"
activation_case absent after-intent absent \
  || ACTIVATION_MECHANICS_STATUS="blocked"
activation_case absent after-writer-reset absent \
  || ACTIVATION_MECHANICS_STATUS="blocked"
activation_case absent after-new-root-activation new \
  || ACTIVATION_MECHANICS_STATUS="blocked"
activation_case absent after-validation new \
  || ACTIVATION_MECHANICS_STATUS="blocked"
activation_case absent after-commit new \
  || ACTIVATION_MECHANICS_STATUS="blocked"

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
  ACTIVATION_MECHANICS_STATUS="blocked"
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
  ACTIVATION_MECHANICS_STATUS="blocked"
fi

CHUNK_OUT="$TEMP_DIRECTORY/chunk.json"
CHUNK_STATUS="blocked"
if run_probe "$CHUNK_OUT" chunk \
    && [[ "$(json_bool "$CHUNK_OUT" passed)" == true \
    && "$(/usr/bin/plutil -extract selectedChunkByteCount raw -expect integer \
      "$CHUNK_OUT")" == "$SELECTED_CHUNK_BYTE_COUNT" \
    && "$(json_string "$CHUNK_OUT" goldenVectorSHA256)" \
      == "$EXPECTED_GOLDEN_VECTOR_SHA256" ]]; then
  CHUNK_STATUS="passed"
fi

PROVISIONED_SIGNING_STATUS="notExecuted"
DEVELOPER_ID_SIGNING_STATUS="notExecuted"
FILE_PROVIDER_STATUS="notExecuted"
NAMED_DATASET_STATUS="blocked"
BACKUP_WALL_CLOCK_STATUS="blocked"
RESTORE_WALL_CLOCK_STATUS="blocked"
NAMED_DATASET_OUT="$TEMP_DIRECTORY/named-dataset.json"
if run_probe_with_timeout "$NAMED_DATASET_OUT" "$NAMED_DATASET_TIMEOUT_SECONDS" \
    named-dataset --run-id "$RUN_ID-named" --object-count 20000 \
      --stream-byte-count 2147483648; then
  NAMED_OBJECT_COUNT="$(/usr/bin/plutil -extract objectCount raw -expect integer \
    "$NAMED_DATASET_OUT" 2>/dev/null || true)"
  NAMED_FRAME_COUNT="$(/usr/bin/plutil -extract frameCount raw -expect integer \
    "$NAMED_DATASET_OUT" 2>/dev/null || true)"
  NAMED_PLAINTEXT_BYTES="$(/usr/bin/plutil -extract plaintextByteCount raw \
    -expect integer "$NAMED_DATASET_OUT" 2>/dev/null || true)"
  NAMED_FILE_BYTES="$(/usr/bin/plutil -extract fileByteCount raw -expect integer \
    "$NAMED_DATASET_OUT" 2>/dev/null || true)"
  NAMED_ALLOCATED_BYTES="$(/usr/bin/plutil -extract allocatedByteCount raw \
    -expect integer "$NAMED_DATASET_OUT" 2>/dev/null || true)"
  NAMED_BACKUP_MILLISECONDS="$(/usr/bin/plutil -extract \
    backupDurationMilliseconds raw -expect integer "$NAMED_DATASET_OUT" \
    2>/dev/null || true)"
  NAMED_RESTORE_MILLISECONDS="$(/usr/bin/plutil -extract \
    restoreDurationMilliseconds raw -expect integer "$NAMED_DATASET_OUT" \
    2>/dev/null || true)"
  NAMED_BACKUP_BUDGET="$(/usr/bin/plutil -extract backupBudgetMilliseconds raw \
    -expect integer "$NAMED_DATASET_OUT" 2>/dev/null || true)"
  NAMED_RESTORE_BUDGET="$(/usr/bin/plutil -extract restoreBudgetMilliseconds raw \
    -expect integer "$NAMED_DATASET_OUT" 2>/dev/null || true)"
  NAMED_PEAK_RSS="$(/usr/bin/plutil -extract peakRSSDeltaBytes raw -expect integer \
    "$NAMED_DATASET_OUT" 2>/dev/null || true)"
  NAMED_PEAK_RSS_BUDGET="$(/usr/bin/plutil -extract peakRSSDeltaBudgetBytes raw \
    -expect integer "$NAMED_DATASET_OUT" 2>/dev/null || true)"
  NAMED_FD_HIGH_WATER="$(/usr/bin/plutil -extract fileDescriptorHighWaterCount \
    raw -expect integer "$NAMED_DATASET_OUT" 2>/dev/null || true)"
  NAMED_FD_BUDGET="$(/usr/bin/plutil -extract fileDescriptorBudgetCount raw \
    -expect integer "$NAMED_DATASET_OUT" 2>/dev/null || true)"
  NAMED_SOURCE_SHA256="$(json_string "$NAMED_DATASET_OUT" sourceSHA256 \
    2>/dev/null || true)"
  NAMED_BACKUP_SHA256="$(json_string "$NAMED_DATASET_OUT" backupSHA256 \
    2>/dev/null || true)"
  NAMED_BACKUP_DIGEST_VALID=false
  if /usr/bin/printf '%s\n' "$NAMED_BACKUP_SHA256" \
      | /usr/bin/grep -Eq '^[0-9a-f]{64}$'; then
    NAMED_BACKUP_DIGEST_VALID=true
  fi
  if [[ "$(json_string "$NAMED_DATASET_OUT" status 2>/dev/null || true)" == passed \
      && "$(json_bool "$NAMED_DATASET_OUT" passed 2>/dev/null || true)" == true \
      && "$(json_string "$NAMED_DATASET_OUT" format 2>/dev/null || true)" \
        == KLG-U0-DATASET-PROBE-1 \
      && "$NAMED_OBJECT_COUNT" == 20000 \
      && "$NAMED_FRAME_COUNT" == 20000 \
      && "$NAMED_PLAINTEXT_BYTES" == 2147483648 \
      && "$NAMED_FILE_BYTES" == <-> \
      && "$NAMED_ALLOCATED_BYTES" == <-> \
      && "$NAMED_FILE_BYTES" -gt "$NAMED_PLAINTEXT_BYTES" \
      && "$NAMED_ALLOCATED_BYTES" -ge "$NAMED_PLAINTEXT_BYTES" \
      && "$(/usr/bin/plutil -extract selectedChunkByteCount raw -expect integer \
        "$NAMED_DATASET_OUT" 2>/dev/null || true)" == "$SELECTED_CHUNK_BYTE_COUNT" \
      && "$NAMED_SOURCE_SHA256" == "$EXPECTED_NAMED_DATASET_SOURCE_SHA256" \
      && "$NAMED_BACKUP_DIGEST_VALID" == true \
      && "$(json_bool "$NAMED_DATASET_OUT" fullReaderVerified 2>/dev/null || true)" \
        == true \
      && "$(json_bool "$NAMED_DATASET_OUT" footerAuthenticated 2>/dev/null || true)" \
        == true \
      && "$(json_bool "$NAMED_DATASET_OUT" nonSparse 2>/dev/null || true)" == true \
      && "$(json_bool "$NAMED_DATASET_OUT" exclusiveNonOverwrite \
        2>/dev/null || true)" == true \
      && "$(json_bool "$NAMED_DATASET_OUT" cleaned 2>/dev/null || true)" == true \
      && "$NAMED_PEAK_RSS" == <-> \
      && "$NAMED_PEAK_RSS_BUDGET" == <-> \
      && "$NAMED_PEAK_RSS" -le "$NAMED_PEAK_RSS_BUDGET" \
      && "$NAMED_FD_HIGH_WATER" == <-> \
      && "$NAMED_FD_BUDGET" == <-> \
      && "$NAMED_FD_HIGH_WATER" -le "$NAMED_FD_BUDGET" ]]; then
    NAMED_DATASET_STATUS="passed"
  fi
  if [[ "$NAMED_DATASET_STATUS" == passed \
      && "$NAMED_BACKUP_MILLISECONDS" == <-> \
      && "$NAMED_BACKUP_BUDGET" == 900000 \
      && "$NAMED_BACKUP_MILLISECONDS" -le "$NAMED_BACKUP_BUDGET" ]]; then
    BACKUP_WALL_CLOCK_STATUS="passed"
  fi
  if [[ "$NAMED_DATASET_STATUS" == passed \
      && "$NAMED_RESTORE_MILLISECONDS" == <-> \
      && "$NAMED_RESTORE_BUDGET" == 900000 \
      && "$NAMED_RESTORE_MILLISECONDS" -le "$NAMED_RESTORE_BUDGET" ]]; then
    RESTORE_WALL_CLOCK_STATUS="passed"
  fi
fi

CURRENT_OS_CAPABILITY_STATUS="blocked"
CURRENT_CAPABILITY_STATUSES=(
  "$IDENTITY_STATUS"
  "$PUBLIC_ONLY_STATUS"
  "$SEED_ONLY_STATUS"
  "$REPOSITORY_PUBLICATION_STATUS"
  "$CAPACITY_STATUS"
  "$BOOKMARK_STATUS"
  "$BOOKMARK_STALE_STATUS"
  "$BOOKMARK_UPGRADE_STATUS"
  "$ACTIVATION_STATUS"
  "$CHUNK_STATUS"
  "$ORDINARY_DIRECTORY_STATUS"
  "$FILE_PROVIDER_STATUS"
  "$NAMED_DATASET_STATUS"
  "$BACKUP_WALL_CLOCK_STATUS"
  "$RESTORE_WALL_CLOCK_STATUS"
)
if all_statuses_passed "${CURRENT_CAPABILITY_STATUSES[@]}"; then
  CURRENT_OS_CAPABILITY_STATUS="passed"
fi

MACOS14_STATUS="notExecuted"
MACOS15_STATUS="notExecuted"
MACOS26_STATUS="notExecuted"
OS_MAJOR="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)"
case "$OS_MAJOR" in
  14) MACOS14_STATUS="$CURRENT_OS_CAPABILITY_STATUS" ;;
  15) MACOS15_STATUS="$CURRENT_OS_CAPABILITY_STATUS" ;;
  26) MACOS26_STATUS="$CURRENT_OS_CAPABILITY_STATUS" ;;
esac

MANDATORY_U0_STATUSES=(
  "${CURRENT_CAPABILITY_STATUSES[@]}"
  "$PROVISIONED_SIGNING_STATUS"
  "$DEVELOPER_ID_SIGNING_STATUS"
  "$MACOS14_STATUS"
  "$MACOS15_STATUS"
  "$MACOS26_STATUS"
)
OVERALL_STATUS="blocked"
if all_statuses_passed "${MANDATORY_U0_STATUSES[@]}"; then
  OVERALL_STATUS="passed"
fi

/bin/mkdir -p "$REPORT_DIRECTORY"
TEMP_REPORT="$TEMP_DIRECTORY/capability-report.json"
/usr/bin/plutil -create xml1 "$TEMP_REPORT"
/usr/bin/plutil -insert schemaVersion -integer 2 "$TEMP_REPORT"
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
/usr/bin/plutil -insert provisionedSigning -string \
  "$PROVISIONED_SIGNING_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert developerIDSigning -string \
  "$DEVELOPER_ID_SIGNING_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert developerIDDescription -string "Developer ID not available" "$TEMP_REPORT"
/usr/bin/plutil -insert localIdentity -string "$IDENTITY_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert localIdentityMechanics -string \
  "$IDENTITY_MECHANICS_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert localIdentityCreate -string "$IDENTITY_CREATE_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert localIdentityRelaunch -string "$IDENTITY_RELAUNCH_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert localIdentityUpgrade -string "$IDENTITY_UPGRADE_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert identityPermissionFailure -string \
  "$IDENTITY_PERMISSION_FAILURE" "$TEMP_REPORT"
/usr/bin/plutil -insert identityAdversarialReplacement -string \
  "$IDENTITY_ADVERSARIAL_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert publicOnlyProfile -string "$PUBLIC_ONLY_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert seedOnlyProfile -string "$SEED_ONLY_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert cryptoMechanics -string "$CRYPTO_MECHANICS_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert repositoryPublication -string \
  "$REPOSITORY_PUBLICATION_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert repositoryPublicationMechanics -string \
  "$REPOSITORY_MECHANICS_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert repositoryAdversarialReplacement -string \
  "$REPOSITORY_ADVERSARIAL_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert capacityBudget -string "$CAPACITY_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert capacityPreflight -string \
  "$CAPACITY_PREFLIGHT_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert maximumSourceObjectCount -integer \
  "$(/usr/bin/plutil -extract maximumSourceObjectCount raw -expect integer \
    "$REPOSITORY_OUT")" "$TEMP_REPORT"
/usr/bin/plutil -insert maximumSourceByteCount -integer \
  "$(/usr/bin/plutil -extract maximumSourceByteCount raw -expect integer \
    "$REPOSITORY_OUT")" "$TEMP_REPORT"
/usr/bin/plutil -insert targetRequiredByteCount -integer \
  "$(/usr/bin/plutil -extract targetRequiredByteCount raw -expect integer \
    "$REPOSITORY_OUT")" "$TEMP_REPORT"
/usr/bin/plutil -insert privateRestoreRequiredByteCount -integer \
  "$(/usr/bin/plutil -extract privateRestoreRequiredByteCount raw -expect integer \
    "$REPOSITORY_OUT")" "$TEMP_REPORT"
/usr/bin/plutil -insert ordinaryDirectoryTarget -string \
  "$ORDINARY_DIRECTORY_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert ordinaryDirectoryCapacityPreflight -string \
  "$ORDINARY_DIRECTORY_CAPACITY_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert selectedTargetAdversarialReplacement -string \
  "$SELECTED_TARGET_ADVERSARIAL_STATUS" "$TEMP_REPORT"
if [[ -n "$SELECTED_TARGET_AVAILABLE_CAPACITY_BYTE_COUNT" \
    && -n "$APP_PRIVATE_RESTORE_AVAILABLE_CAPACITY_BYTE_COUNT" ]]; then
  /usr/bin/plutil -insert selectedTargetAvailableCapacityByteCount -integer \
    "$SELECTED_TARGET_AVAILABLE_CAPACITY_BYTE_COUNT" "$TEMP_REPORT"
  /usr/bin/plutil -insert appPrivateRestoreAvailableCapacityByteCount -integer \
    "$APP_PRIVATE_RESTORE_AVAILABLE_CAPACITY_BYTE_COUNT" "$TEMP_REPORT"
fi
/usr/bin/plutil -insert fileProviderTarget -string "$FILE_PROVIDER_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert namedWorstCaseDataset -string "$NAMED_DATASET_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert backupWallClockBudget -string \
  "$BACKUP_WALL_CLOCK_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert restoreWallClockBudget -string \
  "$RESTORE_WALL_CLOCK_STATUS" "$TEMP_REPORT"
if [[ "$NAMED_DATASET_STATUS" == passed && -s "$NAMED_DATASET_OUT" ]]; then
  /usr/bin/plutil -insert namedDatasetObjectCount -integer \
    "$NAMED_OBJECT_COUNT" "$TEMP_REPORT"
  /usr/bin/plutil -insert namedDatasetFrameCount -integer \
    "$NAMED_FRAME_COUNT" "$TEMP_REPORT"
  /usr/bin/plutil -insert namedDatasetPlaintextByteCount -integer \
    "$NAMED_PLAINTEXT_BYTES" "$TEMP_REPORT"
  /usr/bin/plutil -insert namedDatasetFileByteCount -integer \
    "$NAMED_FILE_BYTES" "$TEMP_REPORT"
  /usr/bin/plutil -insert namedDatasetAllocatedByteCount -integer \
    "$NAMED_ALLOCATED_BYTES" "$TEMP_REPORT"
  /usr/bin/plutil -insert namedDatasetBackupMilliseconds -integer \
    "$NAMED_BACKUP_MILLISECONDS" "$TEMP_REPORT"
  /usr/bin/plutil -insert namedDatasetRestoreMilliseconds -integer \
    "$NAMED_RESTORE_MILLISECONDS" "$TEMP_REPORT"
  /usr/bin/plutil -insert namedDatasetBackupBudgetMilliseconds -integer \
    "$NAMED_BACKUP_BUDGET" "$TEMP_REPORT"
  /usr/bin/plutil -insert namedDatasetRestoreBudgetMilliseconds -integer \
    "$NAMED_RESTORE_BUDGET" "$TEMP_REPORT"
  /usr/bin/plutil -insert namedDatasetPeakRSSDeltaBytes -integer \
    "$NAMED_PEAK_RSS" "$TEMP_REPORT"
  /usr/bin/plutil -insert namedDatasetPeakRSSDeltaBudgetBytes -integer \
    "$NAMED_PEAK_RSS_BUDGET" "$TEMP_REPORT"
  /usr/bin/plutil -insert namedDatasetFileDescriptorHighWaterCount -integer \
    "$NAMED_FD_HIGH_WATER" "$TEMP_REPORT"
  /usr/bin/plutil -insert namedDatasetFileDescriptorBudgetCount -integer \
    "$NAMED_FD_BUDGET" "$TEMP_REPORT"
  /usr/bin/plutil -insert namedDatasetSourceSHA256 -string \
    "$NAMED_SOURCE_SHA256" "$TEMP_REPORT"
  /usr/bin/plutil -insert namedDatasetBackupSHA256 -string \
    "$NAMED_BACKUP_SHA256" "$TEMP_REPORT"
fi
/usr/bin/plutil -insert bookmark -string "$BOOKMARK_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert bookmarkStale -string "$BOOKMARK_STALE_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert bookmarkUpgrade -string "$BOOKMARK_UPGRADE_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert activation -string "$ACTIVATION_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert activationMechanics -string \
  "$ACTIVATION_MECHANICS_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert chunk -string "$CHUNK_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert planSHA256 -string \
  "$(/usr/bin/shasum -a 256 \
    "$REPO_DIR/docs/plans/2026-08-19-1418-feat-encrypted-folder-backup-restore-plan.md" \
    | /usr/bin/awk '{print $1}')" "$TEMP_REPORT"
/usr/bin/plutil -insert probeSourceSHA256 -string \
  "$(/usr/bin/shasum -a 256 \
    "$REPO_DIR/Sources/KinlogueStorageProcessFixture/BackupCapabilityProbe.swift" \
    | /usr/bin/awk '{print $1}')" "$TEMP_REPORT"
/usr/bin/plutil -insert installedExecutableSHA256 -string \
  "$(/usr/bin/shasum -a 256 "$INSTALLED_EXECUTABLE" \
    | /usr/bin/awk '{print $1}')" "$TEMP_REPORT"
/usr/bin/plutil -insert signedEntitlementsSHA256 -string \
  "$(/usr/bin/shasum -a 256 "$FINAL_SIGNED_ENTITLEMENTS" \
    | /usr/bin/awk '{print $1}')" "$TEMP_REPORT"
/usr/bin/plutil -insert installedSignatureMetadataSHA256 -string \
  "$(/usr/bin/shasum -a 256 "$FINAL_SIGNATURE_METADATA" \
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
if [[ -s "$CHUNK_OUT" ]]; then
  /bin/cp -p "$CHUNK_OUT" "$FINAL_CHUNK_REPORT"
  CHUNK_REPORT_SHA256="$(/usr/bin/shasum -a 256 "$FINAL_CHUNK_REPORT" \
    | /usr/bin/awk '{print $1}')"
  /usr/bin/plutil -insert selectedChunkByteCount -integer \
    "$SELECTED_CHUNK_BYTE_COUNT" "$TEMP_REPORT"
  /usr/bin/plutil -insert chunkGoldenVectorSHA256 -string \
    "$(json_string "$CHUNK_OUT" goldenVectorSHA256)" "$TEMP_REPORT"
  /usr/bin/plutil -insert chunkEvidenceSHA256 -string \
    "$CHUNK_REPORT_SHA256" "$TEMP_REPORT"
fi
if [[ -s "$NAMED_DATASET_OUT" ]]; then
  /bin/cp -p "$NAMED_DATASET_OUT" "$FINAL_NAMED_DATASET_REPORT"
  NAMED_DATASET_REPORT_SHA256="$(/usr/bin/shasum -a 256 \
    "$FINAL_NAMED_DATASET_REPORT" | /usr/bin/awk '{print $1}')"
  /usr/bin/plutil -insert namedDatasetEvidenceSHA256 -string \
    "$NAMED_DATASET_REPORT_SHA256" "$TEMP_REPORT"
fi

/usr/bin/plutil -insert overall -string "$OVERALL_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert macOS14 -string "$MACOS14_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert macOS15 -string "$MACOS15_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -insert macOS26 -string "$MACOS26_STATUS" "$TEMP_REPORT"
/usr/bin/plutil -lint "$TEMP_REPORT" >/dev/null
/usr/bin/plutil -convert json "$TEMP_REPORT"
/bin/cp -p "$TEMP_REPORT" "$FINAL_REPORT"

print -- "Backup capability report: dist/backup-capability-report.json"
print -- "Overall: $OVERALL_STATUS"
print -- "App-private device identity proof / mechanics: $IDENTITY_STATUS / $IDENTITY_MECHANICS_STATUS"
print -- "Public-only / seed-only proof; crypto mechanics: $PUBLIC_ONLY_STATUS / $SEED_ONLY_STATUS; $CRYPTO_MECHANICS_STATUS"
print -- "Repository / capacity proof; mechanics / preflight: $REPOSITORY_PUBLICATION_STATUS / $CAPACITY_STATUS; $REPOSITORY_MECHANICS_STATUS / $CAPACITY_PREFLIGHT_STATUS"
print -- "Security-scoped bookmark: $BOOKMARK_STATUS"
print -- "Whole-root activation proof / mechanics: $ACTIVATION_STATUS / $ACTIVATION_MECHANICS_STATUS"
print -- "Chunk sizing: $CHUNK_STATUS (selected $SELECTED_CHUNK_BYTE_COUNT bytes)"
print -- "Named 20,000-object / 2 GiB dataset: $NAMED_DATASET_STATUS"
print -- "Backup / restore wall-clock budget: $BACKUP_WALL_CLOCK_STATUS / $RESTORE_WALL_CLOCK_STATUS"
print -- "Provisioned / Developer ID: notExecuted"

[[ "$OVERALL_STATUS" == passed ]] || exit 2
