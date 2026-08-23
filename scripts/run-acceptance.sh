#!/bin/zsh
set -u
setopt pipefail
unsetopt BG_NICE
umask 077
unset KINLOGUE_ACCEPTANCE_INTERNAL_SCAN_TEST_ROOT

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
PRODUCTION_EXECUTABLE="$REPO_DIR/dist/Kinlogue.app/Contents/MacOS/Kinlogue"
VERIFICATION_REPORT="$REPO_DIR/dist/verification-report.json"
REPORT_PATH="$REPO_DIR/dist/acceptance-report.json"

USER_HOME_DIRECTORY="${HOME:-}"
USER_APPLICATIONS_DIRECTORY=""
APPLICATIONS_DIRECTORY_CREATED=false
APPLICATIONS_DIRECTORY_IDENTITY=""

TEMP_DIRECTORY=""
TEMP_DIRECTORY_IDENTITY=""
TEMP_DIRECTORY_ALTERNATE=""
RUN_ID=""
BUILD_STAGE_DIRECTORY=""
BUILD_STAGE_DIRECTORY_IDENTITY=""
BUILD_STAGE_DIRECTORY_OWNED=false
STAGED_APP=""
STAGED_APP_IDENTITY=""
STAGED_APP_OWNED=false
INSTALLED_APP=""
INSTALLED_APP_IDENTITY=""
INSTALLED_APP_OWNED=false
ACCEPTANCE_EXECUTABLE=""
ACCEPTANCE_EXECUTABLE_HASH=""
ACCEPTANCE_BUNDLE_IDENTIFIER=""
RUN_OWNERSHIP_ESTABLISHED=false
ACTIVE_CHILD_PID=""
ACTIVE_ACCEPTANCE_PID=""
ACTIVE_ACCEPTANCE_LAUNCH=false
ACTIVE_LAUNCHER_OUTPUT=""
ACTIVE_LAUNCHER_ERROR=""
ACCEPTANCE_CANDIDATE=""
ACCEPTANCE_CANDIDATE_IDENTITY=""
ACCEPTANCE_CANDIDATE_OWNED=false
REPORT_OWNED=false
REPORT_IDENTITY=""
VERIFICATION_CANDIDATE=""
VERIFICATION_CANDIDATE_IDENTITY=""
VERIFICATION_CANDIDATE_OWNED=false
VERIFICATION_REPORT_OWNED=false
VERIFICATION_REPORT_IDENTITY=""
FAILURE_REPORTED=false
FAILURE_SCAN_ATTEMPTED=false
FAILURE_SCAN_CODE="KLA_SCAN_NOT_EXECUTED"
FAILURE_SCAN_COUNT=0
FAILURE_SCAN_DIGEST="0000000000000000000000000000000000000000000000000000000000000000"
FAILURE_STAGE="bootstrap"
PRODUCTION_REJECTION_UNIT_PASSED=false
PRODUCTION_BUNDLE_MARKER_PASSED=false
TARGETED_RETRIEVAL_UNDER_THIRTY_SECONDS=false
LAN_RECEIVER_PROBE_PASSED=false
LAN_RECEIVER_RESTART_PASSED=false
DICOM_ACCEPTANCE_PASSED=false
DICOM_INPUT_DIRECTORY=""
DICOM_INPUT_DIRECTORY_IDENTITY=""
DICOM_INPUT_DIRECTORY_OWNED=false
DICOM_FIXTURE_GENERATOR=""
DICOM_CACHED_WINDOW_P95_MILLISECONDS=0
DICOM_FOREGROUND_P95_MILLISECONDS=0
DICOM_MANAGED_FULL_READ_BYTES=0
DICOM_MAXIMUM_CONCURRENT_WORKERS=0
DICOM_MAXIMUM_LIVE_DESCRIPTORS=0
DICOM_MAXIMUM_MANAGED_FULL_READS_PER_OBJECT=0
DICOM_MAXIMUM_QUEUE_DEPTH=0
DICOM_MAXIMUM_WRITES_PER_OBJECT=0
DICOM_PEAK_ADDED_DISK_BYTES=0
DICOM_RSS_PEAK_DELTA_BYTES=0
DICOM_SOURCE_BYTES_READ=0
DICOM_STAGING_BYTES_WRITTEN=0
SUCCESSFUL_EXIT=false
FAILURE_FINALIZER_ACTIVE=false
FAILURE_FINALIZER_SIGNAL_PROBE=false
typeset -ar LAN_RECEIVER_BOOLEAN_FIELDS=(
  listenerAbsentBeforeStart
  listenerActiveAfterStart
  channelClosedAfterStop
  listenerAbsentAfterStop
  oldSessionRejected
  pairingRejected
  authenticationRejected
  hostRejected
  originRejected
  framingRejected
  uniqueFilesStored
  streamingUploadVerified
  interruptedUploadCleanupVerified
)
typeset -ar LAN_RESTART_BOOLEAN_FIELDS=(
  completedFilesAfterProcessRestart
  listenerAbsentAfterRestartStop
)

emit_failure() {
  if [[ "$FAILURE_REPORTED" == false ]]; then
    FAILURE_REPORTED=true
    /usr/bin/printf \
      '{"attachmentCount":0,"code":"KLA_RUN_FAILED","dicomCachedWindowP95Milliseconds":%s,"dicomForegroundP95Milliseconds":%s,"dicomManagedFullReadBytes":%s,"dicomMaximumConcurrentWorkers":%s,"dicomMaximumLiveDescriptors":%s,"dicomMaximumManagedFullReadsPerObject":%s,"dicomMaximumQueueDepth":%s,"dicomMaximumWritesPerObject":%s,"dicomPeakAddedDiskBytes":%s,"dicomRSSPeakDeltaBytes":%s,"dicomSourceBytesRead":%s,"dicomStagingBytesWritten":%s,"failureStage":"%s","memberCount":0,"ok":false,"recordCount":0,"scanCode":"%s","scanCount":%d,"scanSHA256":"%s","summarySHA256":"%064d","tokenSetSHA256":"%064d"}\n' \
      "$DICOM_CACHED_WINDOW_P95_MILLISECONDS" \
      "$DICOM_FOREGROUND_P95_MILLISECONDS" \
      "$DICOM_MANAGED_FULL_READ_BYTES" \
      "$DICOM_MAXIMUM_CONCURRENT_WORKERS" \
      "$DICOM_MAXIMUM_LIVE_DESCRIPTORS" \
      "$DICOM_MAXIMUM_MANAGED_FULL_READS_PER_OBJECT" \
      "$DICOM_MAXIMUM_QUEUE_DEPTH" \
      "$DICOM_MAXIMUM_WRITES_PER_OBJECT" \
      "$DICOM_PEAK_ADDED_DISK_BYTES" \
      "$DICOM_RSS_PEAK_DELTA_BYTES" \
      "$DICOM_SOURCE_BYTES_READ" \
      "$DICOM_STAGING_BYTES_WRITTEN" \
      "$FAILURE_STAGE" "$FAILURE_SCAN_CODE" "$FAILURE_SCAN_COUNT" \
      "$FAILURE_SCAN_DIGEST" 0 0
  fi
}

canonical_run_id() {
  [[ -n "$RUN_ID" ]] || return 1
  /usr/bin/printf '%s\n' "$RUN_ID" \
    | /usr/bin/grep -Eq '^[0-9a-f]{24,32}$'
}

directory_identity() {
  local directory="$1"
  [[ -d "$directory" && ! -L "$directory" ]] || return 1
  /usr/bin/stat -f '%d:%i' -- "$directory" 2>/dev/null
}

private_directory_is_current() {
  local directory="$1"
  local expected_identity="$2"
  [[ "$(directory_identity "$directory")" == "$expected_identity" ]] \
    || return 1
  [[ "$(/usr/bin/stat -f '%u:%Lp' -- "$directory" 2>/dev/null)" \
    == "$CURRENT_UID:700" ]]
}

file_identity() {
  local file="$1"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  /usr/bin/stat -f '%d:%i' -- "$file" 2>/dev/null
}

safe_remove_owned_directory() {
  local directory="$1"
  local expected_identity="$2"
  [[ "$(directory_identity "$directory")" == "$expected_identity" ]] \
    || return 1

  # Entering the directory binds `.` to the already-verified vnode. The
  # physical, single-filesystem walk therefore cannot be redirected to a
  # replacement subsequently installed at `directory`.
  (
    builtin cd -q -- "$directory" || exit 1
    [[ "$(directory_identity .)" == "$expected_identity" ]] || exit 1

    if [[ "${KINLOGUE_ACCEPTANCE_INTERNAL_FAULT_TEST:-}" \
        == "quarantine-replacement-race" ]]; then
      local candidate="${directory%.removal}"
      /usr/bin/touch -- "$candidate.race-ready" || exit 1
      local continued=false
      for _ in {1..500}; do
        if [[ -f "$candidate.race-continue" \
            && ! -L "$candidate.race-continue" ]]; then
          continued=true
          break
        fi
        /bin/sleep 0.01
      done
      [[ "$continued" == true ]] || exit 1
    fi

    /usr/bin/find -P -x . -depth -mindepth 1 -delete \
      >/dev/null 2>&1 || exit 1
  ) || return 1

  # Removing the root is deliberately non-recursive. If its pathname was
  # replaced while the descriptor-bound walk ran, leave that replacement
  # untouched and fail closed.
  [[ "$(directory_identity "$directory")" == "$expected_identity" ]] \
    || return 1
  /bin/rmdir -- "$directory" >/dev/null 2>&1 || return 1
  [[ ! -e "$directory" && ! -L "$directory" ]]
}

cleanup_temp_candidate() {
  local candidate="$1"
  local expected_identity="$2"
  [[ -n "$candidate" ]] || return 0
  [[ "$candidate" == /tmp/kinlogue-acceptance.* ]] || return 1
  if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
    return 0
  fi
  [[ "$(directory_identity "$candidate")" == "$expected_identity" ]] \
    || return 1
  local quarantine="$candidate.removal"
  [[ ! -e "$quarantine" && ! -L "$quarantine" ]] || return 1
  /bin/mv -- "$candidate" "$quarantine" >/dev/null 2>&1 || return 1
  [[ "$(directory_identity "$quarantine")" == "$expected_identity" ]] \
    || return 1
  safe_remove_owned_directory "$quarantine" "$expected_identity"
}

cleanup_temp() {
  local primary="$TEMP_DIRECTORY"
  local alternate="$TEMP_DIRECTORY_ALTERNATE"
  local cleanup_failed=false
  cleanup_temp_candidate "$primary" "$TEMP_DIRECTORY_IDENTITY" \
    || cleanup_failed=true
  if [[ -n "$alternate" && "$alternate" != "$primary" ]]; then
    cleanup_temp_candidate "$alternate" "$TEMP_DIRECTORY_IDENTITY" \
      || cleanup_failed=true
  fi
  [[ "$cleanup_failed" == false ]]
}

cleanup_owned_dicom_input() {
  [[ "$DICOM_INPUT_DIRECTORY_OWNED" == true ]] || return 0
  canonical_run_id || return 1
  local expected="$USER_HOME_DIRECTORY/Library/Containers/com.kinlogue.mac.acceptance.$RUN_ID/Data/Library/Application Support/Kinlogue/Acceptance/$RUN_ID/DICOMInput"
  [[ "$DICOM_INPUT_DIRECTORY" == "$expected" \
      && "$(directory_identity "$DICOM_INPUT_DIRECTORY")" \
        == "$DICOM_INPUT_DIRECTORY_IDENTITY" ]] || return 1
  safe_remove_owned_directory \
    "$DICOM_INPUT_DIRECTORY" "$DICOM_INPUT_DIRECTORY_IDENTITY" || return 1
  DICOM_INPUT_DIRECTORY_OWNED=false
  DICOM_INPUT_DIRECTORY=""
  DICOM_INPUT_DIRECTORY_IDENTITY=""
}

owned_installed_app_is_current() {
  [[ "$INSTALLED_APP_OWNED" == true ]] || return 1
  [[ "$INSTALLED_APP" \
      == "$USER_APPLICATIONS_DIRECTORY/Kinlogue-Acceptance-$RUN_ID.app" ]] \
    || return 1
  [[ "$(directory_identity "$INSTALLED_APP")" == "$INSTALLED_APP_IDENTITY" ]]
}

owned_staged_app_is_current() {
  [[ "$STAGED_APP_OWNED" == true ]] || return 1
  [[ "$STAGED_APP" \
      == "$BUILD_STAGE_DIRECTORY/Kinlogue-Acceptance-$RUN_ID.app" ]] \
    || return 1
  [[ "$(directory_identity "$STAGED_APP")" == "$STAGED_APP_IDENTITY" ]]
}

owned_build_stage_is_current() {
  [[ "$BUILD_STAGE_DIRECTORY_OWNED" == true ]] || return 1
  [[ "${BUILD_STAGE_DIRECTORY:h}" == "$REPO_DIR/dist/acceptance" ]] \
    || return 1
  /usr/bin/printf '%s\n' "${BUILD_STAGE_DIRECTORY:t}" \
    | /usr/bin/grep -Eq '^\.run-build\.[0-9A-Za-z]{8,32}$' \
    || return 1
  private_directory_is_current \
    "$BUILD_STAGE_DIRECTORY" "$BUILD_STAGE_DIRECTORY_IDENTITY"
}

cleanup_owned_build_stage() {
  [[ "$BUILD_STAGE_DIRECTORY_OWNED" == true ]] || return 0
  owned_build_stage_is_current || return 1
  local quarantine="$BUILD_STAGE_DIRECTORY.removal"
  [[ ! -e "$quarantine" && ! -L "$quarantine" ]] || return 1
  /bin/mv -- "$BUILD_STAGE_DIRECTORY" "$quarantine" \
    >/dev/null 2>&1 || return 1
  [[ "$(directory_identity "$quarantine")" \
      == "$BUILD_STAGE_DIRECTORY_IDENTITY" ]] || return 1
  safe_remove_owned_directory \
    "$quarantine" "$BUILD_STAGE_DIRECTORY_IDENTITY" || return 1
  BUILD_STAGE_DIRECTORY_OWNED=false
  STAGED_APP_OWNED=false
  return 0
}

cleanup_owned_installed_app() {
  [[ "$INSTALLED_APP_OWNED" == true ]] || return 0
  owned_installed_app_is_current || return 1
  local quarantine="$USER_APPLICATIONS_DIRECTORY/.Kinlogue-Acceptance-$RUN_ID.removal"
  [[ ! -e "$quarantine" && ! -L "$quarantine" ]] || return 1
  /bin/mv -- "$INSTALLED_APP" "$quarantine" >/dev/null 2>&1 || return 1
  [[ "$(directory_identity "$quarantine")" == "$INSTALLED_APP_IDENTITY" ]] \
    || return 1
  safe_remove_owned_directory \
    "$quarantine" "$INSTALLED_APP_IDENTITY" || return 1
  INSTALLED_APP_OWNED=false

  if [[ "$APPLICATIONS_DIRECTORY_CREATED" == true ]]; then
    [[ "$(directory_identity "$USER_APPLICATIONS_DIRECTORY")" \
        == "$APPLICATIONS_DIRECTORY_IDENTITY" ]] || return 1
    /bin/rmdir -- "$USER_APPLICATIONS_DIRECTORY" >/dev/null 2>&1 || return 1
    APPLICATIONS_DIRECTORY_CREATED=false
  fi
  return 0
}

cleanup_owned_staged_app() {
  [[ "$STAGED_APP_OWNED" == true ]] || return 0
  owned_staged_app_is_current || return 1
  local quarantine="$REPO_DIR/dist/acceptance/.Kinlogue-Acceptance-$RUN_ID.removal"
  [[ ! -e "$quarantine" && ! -L "$quarantine" ]] || return 1
  /bin/mv -- "$STAGED_APP" "$quarantine" >/dev/null 2>&1 || return 1
  [[ "$(directory_identity "$quarantine")" == "$STAGED_APP_IDENTITY" ]] \
    || return 1
  safe_remove_owned_directory \
    "$quarantine" "$STAGED_APP_IDENTITY" || return 1
  STAGED_APP_OWNED=false
  return 0
}

acceptance_process_pid() {
  [[ "$ACTIVE_ACCEPTANCE_LAUNCH" == true \
      && -n "$ACCEPTANCE_BUNDLE_IDENTIFIER" \
      && -n "$INSTALLED_APP" ]] || return 1
  local pid_info pid bundle_info
  pid_info="$(/usr/bin/lsappinfo info -only pid \
    -app "$ACCEPTANCE_BUNDLE_IDENTIFIER" 2>/dev/null)" || return 1
  pid="$(/usr/bin/printf '%s\n' "$pid_info" \
    | /usr/bin/grep -Eo '[0-9]+' | /usr/bin/tail -n 1)"
  /usr/bin/printf '%s\n' "$pid" \
    | /usr/bin/grep -Eq '^[1-9][0-9]*$' || return 1
  bundle_info="$(/usr/bin/lsappinfo info -only bundlepath \
    -app "$pid" 2>/dev/null)" || return 1
  [[ "$bundle_info" == *"$INSTALLED_APP"* ]] || return 1
  /bin/kill -0 "$pid" >/dev/null 2>&1 || return 1
  /usr/bin/printf '%s\n' "$pid"
}

refresh_active_acceptance_pid() {
  local pid
  pid="$(acceptance_process_pid)" || return 1
  ACTIVE_ACCEPTANCE_PID="$pid"
}

hard_kill_active_acceptance() {
  [[ "$ACTIVE_ACCEPTANCE_LAUNCH" == true ]] || return 0
  refresh_active_acceptance_pid >/dev/null 2>&1 || {
    /usr/bin/lsappinfo kill -hard "$ACCEPTANCE_BUNDLE_IDENTIFIER" \
      >/dev/null 2>&1 || return 1
    return 0
  }
  local pid="$ACTIVE_ACCEPTANCE_PID"
  /bin/kill -KILL "$pid" >/dev/null 2>&1 || return 1
  for _ in {1..600}; do
    if ! /bin/kill -0 "$pid" >/dev/null 2>&1; then
      ACTIVE_ACCEPTANCE_PID=""
      return 0
    fi
    /bin/sleep 0.05
  done
  return 1
}

start_installed_bundle() {
  local output_file="$1"
  local error_file="$2"
  shift 2
  owned_installed_app_is_current || return 1
  [[ -n "$ACCEPTANCE_BUNDLE_IDENTIFIER" \
      && "$ACCEPTANCE_BUNDLE_IDENTIFIER" \
        == "com.kinlogue.mac.acceptance.$RUN_ID" ]] || return 1
  [[ -f "$ACCEPTANCE_EXECUTABLE" && ! -L "$ACCEPTANCE_EXECUTABLE" \
      && -x "$ACCEPTANCE_EXECUTABLE" ]] || return 1
  [[ ! -e "$output_file" && ! -L "$output_file" \
      && ! -e "$error_file" && ! -L "$error_file" ]] || return 1
  /usr/bin/touch -- "$output_file" "$error_file" || return 1
  ACTIVE_LAUNCHER_OUTPUT="$output_file.launcher"
  ACTIVE_LAUNCHER_ERROR="$error_file.launcher"
  [[ ! -e "$ACTIVE_LAUNCHER_OUTPUT" \
      && ! -L "$ACTIVE_LAUNCHER_OUTPUT" \
      && ! -e "$ACTIVE_LAUNCHER_ERROR" \
      && ! -L "$ACTIVE_LAUNCHER_ERROR" ]] || return 1
  ACTIVE_ACCEPTANCE_PID=""
  ACTIVE_ACCEPTANCE_LAUNCH=true
  /usr/bin/open -n -W -g \
    --stdout "$output_file" --stderr "$error_file" \
    "$INSTALLED_APP" --args "$@" \
    >"$ACTIVE_LAUNCHER_OUTPUT" 2>"$ACTIVE_LAUNCHER_ERROR" &
  ACTIVE_CHILD_PID=$!
  return 0
}

wait_for_installed_bundle() {
  local maximum_poll_count="${1:-600}"
  local pid="$ACTIVE_CHILD_PID"
  /usr/bin/printf '%s\n' "$pid" \
    | /usr/bin/grep -Eq '^[1-9][0-9]*$' || return 1
  local exited=false
  local poll
  for ((poll = 1; poll <= maximum_poll_count; poll += 1)); do
    if ! /bin/kill -0 "$pid" >/dev/null 2>&1; then
      exited=true
      break
    fi
    refresh_active_acceptance_pid >/dev/null 2>&1 || true
    /bin/sleep 0.05
  done
  if [[ "$exited" != true ]]; then
    hard_kill_active_acceptance >/dev/null 2>&1 || true
    /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
  fi
  wait "$pid" >/dev/null 2>&1
  ACTIVE_CHILD_PID=""
  ACTIVE_ACCEPTANCE_PID=""
  ACTIVE_ACCEPTANCE_LAUNCH=false
  local launcher_output="$ACTIVE_LAUNCHER_OUTPUT"
  local launcher_error="$ACTIVE_LAUNCHER_ERROR"
  ACTIVE_LAUNCHER_OUTPUT=""
  ACTIVE_LAUNCHER_ERROR=""
  if [[ "$exited" != true ]]; then
    return 124
  fi
  [[ ! -s "$launcher_output" && ! -s "$launcher_error" ]] || return 1
  /bin/rm -f -- "$launcher_output" "$launcher_error" || return 1
  return 0
}

run_installed_bundle_with_deadline() {
  local output_file="$1"
  local error_file="$2"
  shift 2
  start_installed_bundle "$output_file" "$error_file" "$@" || return 1
  wait_for_installed_bundle
}

stop_active_child() {
  hard_kill_active_acceptance >/dev/null 2>&1 || true
  if /usr/bin/printf '%s\n' "$ACTIVE_CHILD_PID" \
      | /usr/bin/grep -Eq '^[1-9][0-9]*$'; then
    /bin/kill -KILL "$ACTIVE_CHILD_PID" >/dev/null 2>&1 || true
    wait "$ACTIVE_CHILD_PID" >/dev/null 2>&1 || true
  fi
  ACTIVE_CHILD_PID=""
  ACTIVE_ACCEPTANCE_PID=""
  ACTIVE_ACCEPTANCE_LAUNCH=false
  ACTIVE_LAUNCHER_OUTPUT=""
  ACTIVE_LAUNCHER_ERROR=""
}

scan_failure_artifacts() {
  [[ "$FAILURE_SCAN_ATTEMPTED" == false ]] || return 0
  FAILURE_SCAN_ATTEMPTED=true
  canonical_run_id || return 0
  [[ -n "$TEMP_DIRECTORY" && -d "$TEMP_DIRECTORY" && ! -L "$TEMP_DIRECTORY" ]] \
    || return 0
  "$REPO_DIR/scripts/scan-acceptance.sh" "$RUN_ID" \
    >"$TEMP_DIRECTORY/failure-scan.out" \
    2>"$TEMP_DIRECTORY/failure-scan.err"
  local output="$TEMP_DIRECTORY/failure-scan.out"
  if [[ -f "$output" && ! -L "$output" \
      && "$(/usr/bin/wc -l <"$output" | /usr/bin/tr -d ' ')" == "1" \
      && "$(/usr/bin/wc -c <"$output" | /usr/bin/tr -d ' ')" -le 512 ]] \
      && /usr/bin/plutil -convert json -o /dev/null "$output" \
        >/dev/null 2>&1; then
    local code count digest
    code="$(/usr/bin/plutil -extract code raw "$output" 2>/dev/null)"
    count="$(/usr/bin/plutil -extract count raw "$output" 2>/dev/null)"
    digest="$(/usr/bin/plutil -extract summarySHA256 raw "$output" 2>/dev/null)"
    if /usr/bin/printf '%s\n' "$code" \
        | /usr/bin/grep -Eq '^KLA_SCAN_(COMPLETE|MATCH|ERROR)$' \
      && /usr/bin/printf '%s\n' "$count" | /usr/bin/grep -Eq '^[0-9]+$' \
      && /usr/bin/printf '%s\n' "$digest" \
        | /usr/bin/grep -Eq '^[0-9a-f]{64}$'; then
      FAILURE_SCAN_CODE="$code"
      FAILURE_SCAN_COUNT="$count"
      FAILURE_SCAN_DIGEST="$digest"
    fi
  fi
  return 0
}

best_effort_isolated_cleanup() {
  [[ "$RUN_OWNERSHIP_ESTABLISHED" == true ]] || return 0
  canonical_run_id || return 0
  owned_installed_app_is_current || return 0
  [[ -n "$ACCEPTANCE_EXECUTABLE" \
      && "$ACCEPTANCE_EXECUTABLE" \
        == "$INSTALLED_APP/Contents/MacOS/Kinlogue" \
      && -f "$ACCEPTANCE_EXECUTABLE" && ! -L "$ACCEPTANCE_EXECUTABLE" \
      && -x "$ACCEPTANCE_EXECUTABLE" ]] || return 0

  local cleanup_out="$TEMP_DIRECTORY/failure-cleanup.out"
  local cleanup_err="$TEMP_DIRECTORY/failure-cleanup.err"
  run_installed_bundle_with_deadline \
    "$cleanup_out" "$cleanup_err" \
    --synthetic-smoke --acceptance-phase=cleanup
  if [[ $? -eq 0 && ! -s "$cleanup_err" ]] \
      && validate_phase_event \
        "$cleanup_out" KLA_CLEANUP_COMPLETE 0 0 0 false; then
    RUN_OWNERSHIP_ESTABLISHED=false
  fi
  return 0
}

remove_owned_reports() {
  if [[ "$REPORT_OWNED" == true \
      && "$(file_identity "$REPORT_PATH")" == "$REPORT_IDENTITY" ]]; then
    /bin/rm -f -- "$REPORT_PATH" >/dev/null 2>&1
    REPORT_OWNED=false
  fi
  if [[ "$ACCEPTANCE_CANDIDATE_OWNED" == true \
      && -n "$ACCEPTANCE_CANDIDATE" \
      && "$ACCEPTANCE_CANDIDATE" \
        == "$REPO_DIR/dist/.acceptance-report-$RUN_ID."* \
      && "$(file_identity "$ACCEPTANCE_CANDIDATE")" \
        == "$ACCEPTANCE_CANDIDATE_IDENTITY" ]]; then
    /bin/rm -f -- "$ACCEPTANCE_CANDIDATE" >/dev/null 2>&1
    ACCEPTANCE_CANDIDATE_OWNED=false
  fi
  if [[ "$VERIFICATION_CANDIDATE_OWNED" == true \
      && -n "$VERIFICATION_CANDIDATE" \
      && "$VERIFICATION_CANDIDATE" \
        == "$REPO_DIR/dist/.acceptance-verification-$RUN_ID."* \
      && "$(file_identity "$VERIFICATION_CANDIDATE")" \
        == "$VERIFICATION_CANDIDATE_IDENTITY" ]]; then
    /bin/rm -f -- "$VERIFICATION_CANDIDATE" >/dev/null 2>&1
    VERIFICATION_CANDIDATE_OWNED=false
  fi
  if [[ "$VERIFICATION_REPORT_OWNED" == true \
      && "$(file_identity "$VERIFICATION_REPORT")" \
        == "$VERIFICATION_REPORT_IDENTITY" ]]; then
    /bin/rm -f -- "$VERIFICATION_REPORT" >/dev/null 2>&1
    VERIFICATION_REPORT_OWNED=false
  fi
}

fail() {
  exit 1
}

finalize_failure() {
  [[ "$FAILURE_FINALIZER_ACTIVE" == false ]] || return 0
  FAILURE_FINALIZER_ACTIVE=true
  trap '' INT TERM HUP
  if [[ "$FAILURE_FINALIZER_SIGNAL_PROBE" == true ]]; then
    /bin/kill -TERM $$ >/dev/null 2>&1 || true
    /bin/kill -INT $$ >/dev/null 2>&1 || true
    /bin/kill -HUP $$ >/dev/null 2>&1 || true
  fi
  stop_active_child
  scan_failure_artifacts
  cleanup_owned_dicom_input >/dev/null 2>&1 || true
  best_effort_isolated_cleanup
  if [[ "$RUN_OWNERSHIP_ESTABLISHED" == false ]]; then
    cleanup_owned_installed_app >/dev/null 2>&1 || true
    cleanup_owned_build_stage >/dev/null 2>&1 || true
  fi
  remove_owned_reports
  emit_failure
  cleanup_temp >/dev/null 2>&1 || true
}

handle_exit() {
  local exit_status=$?
  trap - EXIT
  if [[ "$SUCCESSFUL_EXIT" == true && "$exit_status" -eq 0 ]]; then
    return 0
  fi
  finalize_failure
}

handle_signal() {
  local signal_status="$1"
  trap '' INT TERM HUP
  exit "$signal_status"
}

acceptance_handoff_checkpoint() {
  local checkpoint="$1"
  if [[ "${KINLOGUE_ACCEPTANCE_INTERNAL_FAULT_TEST:-}" \
      == "handoff-$checkpoint" ]]; then
    handle_signal 143
  fi
}

handoff_temp_directory() {
  local canonical_directory="$1"
  local disposable_file="${2:-}"
  local bootstrap_directory="$TEMP_DIRECTORY"

  [[ "$canonical_directory" == /tmp/kinlogue-acceptance.* \
      && ! -e "$canonical_directory" \
      && ! -L "$canonical_directory" ]] || return 1
  TEMP_DIRECTORY_ALTERNATE="$canonical_directory"
  acceptance_handoff_checkpoint before-rename
  if [[ -n "$disposable_file" ]]; then
    [[ "$disposable_file" == "$bootstrap_directory/"* \
        && -f "$disposable_file" \
        && ! -L "$disposable_file" ]] || return 1
    /bin/rm -f -- "$disposable_file" >/dev/null 2>&1 || return 1
  fi
  /bin/mv -- "$bootstrap_directory" "$canonical_directory" || return 1
  acceptance_handoff_checkpoint after-rename-before-primary
  TEMP_DIRECTORY="$canonical_directory"
  acceptance_handoff_checkpoint after-primary-before-alternate
  TEMP_DIRECTORY_ALTERNATE="$bootstrap_directory"
  private_directory_is_current \
    "$TEMP_DIRECTORY" "$TEMP_DIRECTORY_IDENTITY"
}

bundle_hash() {
  local bundle="$1"
  local manifest="$2"
  (
    cd "$bundle" || exit 1
    /usr/bin/find . -type f -print \
      | LC_ALL=C /usr/bin/sort \
      | while IFS= read -r relative_path; do
          file_hash="$(/usr/bin/shasum -a 256 -- "$relative_path" \
            | /usr/bin/awk '{print $1}')"
          /usr/bin/printf '%s\t%s\n' "$file_hash" "$relative_path"
        done
  ) >"$manifest" || return 1
  /usr/bin/shasum -a 256 -- "$manifest" | /usr/bin/awk '{print $1}'
}

json_value() {
  local key="$1"
  local file="$2"
  /usr/bin/plutil -extract "$key" raw "$file" 2>/dev/null
}

validate_phase_event() {
  local file="$1"
  local expected_code="$2"
  local expected_members="$3"
  local expected_records="$4"
  local expected_attachments="$5"
  local expected_targeted_retrieval="$6"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  [[ "$(/usr/bin/wc -l <"$file" | /usr/bin/tr -d ' ')" == "1" ]] || return 1
  [[ "$(/usr/bin/wc -c <"$file" | /usr/bin/tr -d ' ')" -le 512 ]] || return 1
  /usr/bin/plutil -convert json -o /dev/null "$file" >/dev/null 2>&1 || return 1
  [[ "$(json_value code "$file")" == "$expected_code" ]] || return 1
  [[ "$(json_value ok "$file")" == "true" ]] || return 1
  [[ "$(json_value memberCount "$file")" == "$expected_members" ]] || return 1
  [[ "$(json_value recordCount "$file")" == "$expected_records" ]] || return 1
  [[ "$(json_value attachmentCount "$file")" == "$expected_attachments" ]] || return 1
  [[ "$(json_value targetedRetrievalUnderThirtySeconds "$file")" \
    == "$expected_targeted_retrieval" ]] || return 1
  local digest
  digest="$(json_value summarySHA256 "$file")"
  /usr/bin/printf '%s\n' "$digest" \
    | /usr/bin/grep -Eq '^[0-9a-f]{64}$' || return 1
  local token_digest
  token_digest="$(json_value tokenSetSHA256 "$file")"
  /usr/bin/printf '%s\n' "$token_digest" \
    | /usr/bin/grep -Eq '^[0-9a-f]{64}$' || return 1
  local expected_line
  expected_line="$(/usr/bin/printf \
    '{"attachmentCount":%d,"code":"%s","memberCount":%d,"ok":true,"recordCount":%d,"summarySHA256":"%s","targetedRetrievalUnderThirtySeconds":%s,"tokenSetSHA256":"%s"}' \
    "$expected_attachments" "$expected_code" "$expected_members" \
    "$expected_records" "$digest" "$expected_targeted_retrieval" \
    "$token_digest")"
  [[ "$(/bin/cat "$file")" == "$expected_line" ]] || return 1
  return 0
}

validate_lan_receiver_event() {
  local file="$1"
  local expected_code="$2"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  [[ "$(/usr/bin/wc -l <"$file" | /usr/bin/tr -d ' ')" == "1" ]] || return 1
  [[ "$(/usr/bin/wc -c <"$file" | /usr/bin/tr -d ' ')" -le 2048 ]] || return 1
  /usr/bin/plutil -convert json -o /dev/null "$file" >/dev/null 2>&1 || return 1
  [[ "$(json_value code "$file")" == "$expected_code" ]] || return 1
  [[ "$(json_value ok "$file")" == "true" ]] || return 1
  [[ "$(json_value executableSHA256 "$file")" \
    == "$ACCEPTANCE_EXECUTABLE_HASH" ]] || return 1
  if [[ "$expected_code" == "KLA_LAN_RECEIVER_COMPLETE" ]]; then
    local field
    for field in "${LAN_RECEIVER_BOOLEAN_FIELDS[@]}"; do
      [[ "$(json_value $field "$file")" == "true" ]] || return 1
    done
  elif [[ "$expected_code" == "KLA_LAN_RESTART_COMPLETE" ]]; then
    local field
    for field in "${LAN_RESTART_BOOLEAN_FIELDS[@]}"; do
      [[ "$(json_value $field "$file")" == "true" ]] || return 1
    done
  else
    return 1
  fi
  return 0
}

validate_dicom_event() {
  local file="$1"
  local expected_code="$2"
  local expected_studies="$3"
  local expected_series="$4"
  local expected_viewable="$5"
  local expected_inert="$6"
  local expected_retained="$7"
  local expected_rendered="$8"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  [[ "$(/usr/bin/wc -l <"$file" | /usr/bin/tr -d ' ')" == "1" ]] || return 1
  [[ "$(/usr/bin/wc -c <"$file" | /usr/bin/tr -d ' ')" -le 4096 ]] || return 1
  /usr/bin/plutil -convert json -o /dev/null "$file" >/dev/null 2>&1 || return 1
  [[ "$(json_value code "$file")" == "$expected_code" \
      && "$(json_value ok "$file")" == "true" \
      && "$(json_value memberCount "$file")" == "4" \
      && "$(json_value recordCount "$file")" == "96" \
      && "$(json_value studyCount "$file")" == "$expected_studies" \
      && "$(json_value seriesCount "$file")" == "$expected_series" \
      && "$(json_value viewableInstanceCount "$file")" == "$expected_viewable" \
      && "$(json_value inertObjectCount "$file")" == "$expected_inert" \
      && "$(json_value retainedObjectCount "$file")" == "$expected_retained" \
      && "$(json_value renderedSliceCount "$file")" == "$expected_rendered" \
      && "$(json_value rssCloseWithinLimit "$file")" == "true" ]] || return 1
  local digest
  digest="$(json_value summarySHA256 "$file")"
  /usr/bin/printf '%s\n' "$digest" \
    | /usr/bin/grep -Eq '^[0-9a-f]{64}$' || return 1
  if [[ "$expected_code" == "KLA_DICOM_IMPORT_COMPLETE" ]]; then
    [[ "$(json_value maximumConcurrentWorkers "$file")" -le 2 \
        && "$(json_value maximumQueueDepth "$file")" -le 2 \
        && "$(json_value maximumLiveDescriptors "$file")" -le 8 \
        && "$(json_value liveDescriptorCount "$file")" -eq 0 \
        && "$(json_value liveWorkerCount "$file")" -eq 0 \
        && "$(json_value maximumManagedFullReadsPerObject "$file")" -le 3 \
        && "$(json_value maximumWritesPerObject "$file")" -le 2 \
        && "$(json_value foregroundP95Milliseconds "$file")" -lt 150 \
        && "$(json_value cachedWindowP95Milliseconds "$file")" -lt 16 ]] \
      || return 1
    [[ "$(json_value sourceBytesRead "$file")" \
        == "$(json_value stagingBytesWritten "$file")" ]] || return 1
    [[ "$(json_value rssPeakDeltaBytes "$file")" -le 335544320 ]] || return 1
  fi
}

capture_dicom_import_metrics() {
  local file="${1:-$TEMP_DIRECTORY/dicom-import.json}"
  DICOM_CACHED_WINDOW_P95_MILLISECONDS="$(json_value \
    cachedWindowP95Milliseconds "$file")" || return 1
  DICOM_FOREGROUND_P95_MILLISECONDS="$(json_value \
    foregroundP95Milliseconds "$file")" || return 1
  DICOM_MANAGED_FULL_READ_BYTES="$(json_value managedFullReadBytes "$file")" \
    || return 1
  DICOM_MAXIMUM_CONCURRENT_WORKERS="$(json_value \
    maximumConcurrentWorkers "$file")" || return 1
  DICOM_MAXIMUM_LIVE_DESCRIPTORS="$(json_value \
    maximumLiveDescriptors "$file")" || return 1
  DICOM_MAXIMUM_MANAGED_FULL_READS_PER_OBJECT="$(json_value \
    maximumManagedFullReadsPerObject "$file")" || return 1
  DICOM_MAXIMUM_QUEUE_DEPTH="$(json_value maximumQueueDepth "$file")" \
    || return 1
  DICOM_MAXIMUM_WRITES_PER_OBJECT="$(json_value \
    maximumWritesPerObject "$file")" || return 1
  DICOM_PEAK_ADDED_DISK_BYTES="$(json_value peakAddedDiskBytes "$file")" \
    || return 1
  DICOM_RSS_PEAK_DELTA_BYTES="$(json_value rssPeakDeltaBytes "$file")" \
    || return 1
  DICOM_SOURCE_BYTES_READ="$(json_value sourceBytesRead "$file")" \
    || return 1
  DICOM_STAGING_BYTES_WRITTEN="$(json_value stagingBytesWritten "$file")" \
    || return 1

  local value
  for value in \
    "$DICOM_CACHED_WINDOW_P95_MILLISECONDS" \
    "$DICOM_FOREGROUND_P95_MILLISECONDS" \
    "$DICOM_MANAGED_FULL_READ_BYTES" \
    "$DICOM_MAXIMUM_CONCURRENT_WORKERS" \
    "$DICOM_MAXIMUM_LIVE_DESCRIPTORS" \
    "$DICOM_MAXIMUM_MANAGED_FULL_READS_PER_OBJECT" \
    "$DICOM_MAXIMUM_QUEUE_DEPTH" \
    "$DICOM_MAXIMUM_WRITES_PER_OBJECT" \
    "$DICOM_PEAK_ADDED_DISK_BYTES" \
    "$DICOM_RSS_PEAK_DELTA_BYTES" \
    "$DICOM_SOURCE_BYTES_READ" \
    "$DICOM_STAGING_BYTES_WRITTEN"; do
    /usr/bin/printf '%s\n' "$value" \
      | /usr/bin/grep -Eq '^[0-9]+$' || return 1
  done
}

run_dicom_phase() {
  local phase="$1"
  local expected_code="$2"
  shift 2
  local output_file="$TEMP_DIRECTORY/$phase.json"
  local error_file="$TEMP_DIRECTORY/$phase.err"
  start_installed_bundle \
    "$output_file" "$error_file" \
    --synthetic-smoke "--acceptance-phase=$phase" || return 1
  wait_for_installed_bundle 18000
  local phase_status=$?
  if [[ -f "$output_file" && ! -L "$output_file" \
      && "$(json_value code "$output_file")" == "KLA_DICOM_FAILED" \
      && "$(json_value ok "$output_file")" == "false" ]]; then
    capture_dicom_import_metrics "$output_file" >/dev/null 2>&1 || true
    local failure_step
    failure_step="$(json_value failureStep "$output_file")"
    if /usr/bin/printf '%s\n' "$failure_step" | /usr/bin/grep -Eq \
        '^(phase|context|input-ownership|environment|initial-snapshot|import-operation|import-outcome|save|saved-snapshot|viewer-metadata|viewer-content|viewer-render|viewer-limits|metrics|restart|delete)$'; then
      FAILURE_STAGE="$phase-$failure_step"
    else
      FAILURE_STAGE="$phase-app-failure"
    fi
    return 1
  fi
  if [[ "$phase_status" -eq 124 ]]; then
    FAILURE_STAGE="$phase-timeout"
    return 1
  fi
  if [[ "$phase_status" -ne 0 ]]; then
    FAILURE_STAGE="$phase-launch-failure"
    return 1
  fi
  if [[ -s "$error_file" ]]; then
    FAILURE_STAGE="$phase-stderr"
    return 1
  fi
  validate_dicom_event "$output_file" "$expected_code" "$@" || {
    FAILURE_STAGE="$phase-invalid-event"
    return 1
  }
}

generate_dicom_acceptance_fixture() {
  local run_root="$USER_HOME_DIRECTORY/Library/Containers/com.kinlogue.mac.acceptance.$RUN_ID/Data/Library/Application Support/Kinlogue/Acceptance/$RUN_ID"
  [[ -d "$run_root" && ! -L "$run_root" ]] || return 1
  DICOM_INPUT_DIRECTORY="$run_root/DICOMInput"
  [[ ! -e "$DICOM_INPUT_DIRECTORY" && ! -L "$DICOM_INPUT_DIRECTORY" ]] \
    || return 1
  local output_file="$TEMP_DIRECTORY/dicom-fixture.json"
  local error_file="$TEMP_DIRECTORY/dicom-fixture.err"
  "$DICOM_FIXTURE_GENERATOR" \
    --output-directory "$DICOM_INPUT_DIRECTORY" \
    >"$output_file" 2>"$error_file" || return 1
  [[ ! -s "$error_file" \
      && -d "$DICOM_INPUT_DIRECTORY" \
      && ! -L "$DICOM_INPUT_DIRECTORY" \
      && "$(/usr/bin/stat -f '%u:%Lp' -- "$DICOM_INPUT_DIRECTORY")" \
        == "$CURRENT_UID:700" \
      && "$(json_value code "$output_file")" == "KLA_DICOM_FIXTURE_COMPLETE" \
      && "$(json_value ok "$output_file")" == "true" \
      && "$(json_value objectCount "$output_file")" == "217" \
      && "$(json_value seriesCount "$output_file")" == "3" \
      && "$(json_value viewableInstanceCount "$output_file")" == "216" \
      && "$(json_value inertObjectCount "$output_file")" == "1" ]] || return 1
  DICOM_INPUT_DIRECTORY_IDENTITY="$(directory_identity \
    "$DICOM_INPUT_DIRECTORY")" || return 1
  DICOM_INPUT_DIRECTORY_OWNED=true
}

run_lan_receiver_phase() {
  local phase="$1"
  local expected_code="$2"
  local output_file="$TEMP_DIRECTORY/$phase.json"
  local error_file="$TEMP_DIRECTORY/$phase.err"
  run_installed_bundle_with_deadline \
    "$output_file" "$error_file" \
    --synthetic-smoke "--acceptance-phase=$phase"
  local phase_status=$?
  if [[ -f "$output_file" && ! -L "$output_file" \
      && "$(json_value code "$output_file")" == "KLA_LAN_RECEIVER_FAILED" \
      && "$(json_value ok "$output_file")" == "false" ]]; then
    local reason
    reason="$(json_value reason "$output_file")"
    if /usr/bin/printf '%s\n' "$reason" \
        | /usr/bin/grep -Eq '^[A-Za-z0-9._-]{1,96}$'; then
      FAILURE_STAGE="$phase-$reason"
    fi
    return 1
  fi
  [[ "$phase_status" -eq 0 ]] || return 1
  [[ ! -s "$error_file" ]] || return 1
  validate_lan_receiver_event "$output_file" "$expected_code"
}

run_phase() {
  local phase="$1"
  local expected_code="$2"
  local expected_members="$3"
  local expected_records="$4"
  local expected_attachments="$5"
  local output_label="${6:-$phase}"
  local output_file="$TEMP_DIRECTORY/$output_label.json"
  local error_file="$TEMP_DIRECTORY/$output_label.err"
  run_installed_bundle_with_deadline \
    "$output_file" "$error_file" \
    --synthetic-smoke "--acceptance-phase=$phase"
  [[ $? -eq 0 ]] || return 1
  [[ ! -s "$error_file" ]] || return 1
  validate_phase_event \
    "$output_file" "$expected_code" \
    "$expected_members" "$expected_records" "$expected_attachments" true
}

run_claim_phase() {
  local output_file="$TEMP_DIRECTORY/claim.json"
  local error_file="$TEMP_DIRECTORY/claim.err"
  # Once claim starts, cleanup may be required even if the process is killed
  # before it emits its completion event.
  RUN_OWNERSHIP_ESTABLISHED=true
  run_installed_bundle_with_deadline \
    "$output_file" "$error_file" \
    --synthetic-smoke --acceptance-phase=claim
  local phase_status=$?
  [[ "$phase_status" -eq 0 && ! -s "$error_file" ]] || return 1
  validate_phase_event "$output_file" KLA_CLAIM_COMPLETE 0 0 0 false
}

run_cleanup_phase() {
  local output_file="$TEMP_DIRECTORY/cleanup.json"
  local error_file="$TEMP_DIRECTORY/cleanup.err"
  run_installed_bundle_with_deadline \
    "$output_file" "$error_file" \
    --synthetic-smoke --acceptance-phase=cleanup
  local phase_status=$?
  [[ "$phase_status" -eq 0 && ! -s "$error_file" ]] || return 1
  validate_phase_event "$output_file" KLA_CLEANUP_COMPLETE 0 0 0 false \
    || return 1
  RUN_OWNERSHIP_ESTABLISHED=false
  return 0
}

prepare_verification_candidate() {
  [[ -f "$VERIFICATION_REPORT" && ! -L "$VERIFICATION_REPORT" ]] || return 1
  VERIFICATION_CANDIDATE="$(/usr/bin/mktemp \
    "$REPO_DIR/dist/.acceptance-verification-$RUN_ID.XXXXXX")" || return 1
  [[ -f "$VERIFICATION_CANDIDATE" && ! -L "$VERIFICATION_CANDIDATE" ]] || return 1
  VERIFICATION_CANDIDATE_OWNED=true
  VERIFICATION_CANDIDATE_IDENTITY="$(file_identity \
    "$VERIFICATION_CANDIDATE")" || return 1
  /bin/cp -p -- "$VERIFICATION_REPORT" "$VERIFICATION_CANDIDATE" || return 1
  [[ "$PRODUCTION_REJECTION_UNIT_PASSED" == true \
      && "$PRODUCTION_BUNDLE_MARKER_PASSED" == true \
      && "$TARGETED_RETRIEVAL_UNDER_THIRTY_SECONDS" == true \
      && "$LAN_RECEIVER_PROBE_PASSED" == true \
      && "$LAN_RECEIVER_RESTART_PASSED" == true \
      && "$DICOM_ACCEPTANCE_PASSED" == true ]] || return 1
  [[ "$(/usr/bin/plutil -extract storage.confidentiality raw -expect string \
        "$VERIFICATION_CANDIDATE")" == "plaintext" ]] || return 1
  [[ "$(/usr/bin/plutil -extract storage.applicationLayerEncryption raw \
        -expect bool "$VERIFICATION_CANDIDATE")" == "false" ]] || return 1
  [[ "$(/usr/bin/plutil -extract storage.keychainDependency raw -expect bool \
        "$VERIFICATION_CANDIDATE")" == "false" ]] || return 1
  [[ "$(/usr/bin/plutil -extract storage.cloudSync raw -expect bool \
        "$VERIFICATION_CANDIDATE")" == "false" ]] || return 1
  [[ "$(/usr/bin/plutil -extract storage.backupContainerEncryption raw \
        -expect string "$VERIFICATION_CANDIDATE")" \
        == "hpke-x25519-chacha20poly1305+aes-256-gcm" ]] || return 1
  [[ "$(/usr/bin/plutil -extract storage.backupRecoveryPrivateKeyPersisted raw \
        -expect bool "$VERIFICATION_CANDIDATE")" == "false" ]] || return 1
  [[ "$(/usr/bin/plutil -extract storage.backupDeviceIdentityCanDecrypt raw \
        -expect bool "$VERIFICATION_CANDIDATE")" == "false" ]] || return 1
  [[ "$(/usr/bin/plutil -extract storage.builtInBackupRestore raw -expect bool \
        "$VERIFICATION_CANDIDATE")" == "true" ]] || return 1
  for gate in noSecurityFrameworkDependency noKeychainRuntime noLegacyCryptoRuntime; do
    [[ "$(/usr/bin/plutil -extract "gates.$gate" raw -expect string \
          "$VERIFICATION_CANDIDATE")" == "passed" ]] || return 1
  done
  for gate in \
    syntheticSmoke \
    installedAcceptance \
    canaryScan; do
    /usr/bin/plutil -replace "gates.$gate" -string passed \
      "$VERIFICATION_CANDIDATE" || return 1
  done
  /usr/bin/plutil -insert gates.targetedRetrieval -string passed \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert gates.productionRejectionUnit -string passed \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert gates.productionBundleMarker -string passed \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert gates.dicomInstalledAcceptance -string passed \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedDICOM -json '{}' \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedDICOM.cachedWindowP95Milliseconds \
    -integer "$DICOM_CACHED_WINDOW_P95_MILLISECONDS" \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedDICOM.foregroundP95Milliseconds \
    -integer "$DICOM_FOREGROUND_P95_MILLISECONDS" \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedDICOM.managedFullReadBytes \
    -integer "$DICOM_MANAGED_FULL_READ_BYTES" \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedDICOM.maximumConcurrentWorkers \
    -integer "$DICOM_MAXIMUM_CONCURRENT_WORKERS" \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedDICOM.maximumLiveDescriptors \
    -integer "$DICOM_MAXIMUM_LIVE_DESCRIPTORS" \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedDICOM.maximumManagedFullReadsPerObject \
    -integer "$DICOM_MAXIMUM_MANAGED_FULL_READS_PER_OBJECT" \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedDICOM.maximumQueueDepth \
    -integer "$DICOM_MAXIMUM_QUEUE_DEPTH" \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedDICOM.maximumWritesPerObject \
    -integer "$DICOM_MAXIMUM_WRITES_PER_OBJECT" \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedDICOM.peakAddedDiskBytes \
    -integer "$DICOM_PEAK_ADDED_DISK_BYTES" \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedDICOM.renderedSliceCount -integer 648 \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedDICOM.restartRenderedSliceCount -integer 3 \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedDICOM.rssCloseWithinLimit -bool true \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedDICOM.rssPeakDeltaBytes \
    -integer "$DICOM_RSS_PEAK_DELTA_BYTES" \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedDICOM.sourceBytesRead \
    -integer "$DICOM_SOURCE_BYTES_READ" \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedDICOM.stagingBytesWritten \
    -integer "$DICOM_STAGING_BYTES_WRITTEN" \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -replace gates.productionExecutableProbe \
    -string passed "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedLAN -json '{}' \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedLAN.executableSHA256 \
    -string "$ACCEPTANCE_EXECUTABLE_HASH" "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert installedLAN.harnessNetworkClientEntitlement \
    -bool true "$VERIFICATION_CANDIDATE" || return 1
  local field
  for field in \
    "${LAN_RECEIVER_BOOLEAN_FIELDS[@]}" \
    "${LAN_RESTART_BOOLEAN_FIELDS[@]}"; do
    /usr/bin/plutil -insert "installedLAN.$field" -bool true \
      "$VERIFICATION_CANDIDATE" || return 1
  done
  /usr/bin/plutil -insert gates.plaintextPersistence -string passed \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert gates.automatedOverall -string passed \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert gates.manualRealSample -string notExecuted \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -insert gates.manualAccessibility -string notExecuted \
    "$VERIFICATION_CANDIDATE" || return 1
  for gate in iOSSafari androidChrome macOS14Lifecycle macOS15Lifecycle; do
    /usr/bin/plutil -insert "gates.$gate" -string notExecutedManual \
      "$VERIFICATION_CANDIDATE" || return 1
  done
  /usr/bin/plutil -replace gates.overall -string pendingManual \
    "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -convert json "$VERIFICATION_CANDIDATE" || return 1
  /usr/bin/plutil -convert json -o /dev/null "$VERIFICATION_CANDIDATE" \
    >/dev/null 2>&1 || return 1
  /bin/chmod 644 "$VERIFICATION_CANDIDATE" || return 1
}

prepare_acceptance_candidate() {
  [[ "$PRODUCTION_REJECTION_UNIT_PASSED" == true \
      && "$PRODUCTION_BUNDLE_MARKER_PASSED" == true \
      && "$TARGETED_RETRIEVAL_UNDER_THIRTY_SECONDS" == true \
      && "$LAN_RECEIVER_PROBE_PASSED" == true \
      && "$LAN_RECEIVER_RESTART_PASSED" == true \
      && "$DICOM_ACCEPTANCE_PASSED" == true ]] || return 1
  ACCEPTANCE_CANDIDATE="$(/usr/bin/mktemp \
    "$REPO_DIR/dist/.acceptance-report-$RUN_ID.XXXXXX")" || return 1
  [[ -f "$ACCEPTANCE_CANDIDATE" && ! -L "$ACCEPTANCE_CANDIDATE" ]] \
    || return 1
  ACCEPTANCE_CANDIDATE_OWNED=true
  ACCEPTANCE_CANDIDATE_IDENTITY="$(file_identity \
    "$ACCEPTANCE_CANDIDATE")" || return 1
  /usr/bin/printf \
    '{"acceptanceHarnessNetworkClientEntitlement":true,"androidChromeDeviceGate":"notExecutedManual","attachmentCount":96,"authenticationRejected":true,"channelClosedAfterStop":true,"code":"KLA_ACCEPTANCE_COMPLETE","completedFilesAfterProcessRestart":true,"dicomCachedWindowP95Milliseconds":%s,"dicomForegroundP95Milliseconds":%s,"dicomInstalledAcceptance":true,"dicomInertObjectCount":1,"dicomManagedFullReadBytes":%s,"dicomMaximumConcurrentWorkers":%s,"dicomMaximumLiveDescriptors":%s,"dicomMaximumManagedFullReadsPerObject":%s,"dicomMaximumQueueDepth":%s,"dicomMaximumWritesPerObject":%s,"dicomPeakAddedDiskBytes":%s,"dicomRSSCloseWithinLimit":true,"dicomRSSPeakDeltaBytes":%s,"dicomRenderedSliceCount":648,"dicomRestartRenderedSliceCount":3,"dicomSeriesCount":3,"dicomSourceBytesRead":%s,"dicomStagingBytesWritten":%s,"dicomViewableInstanceCount":216,"forcedTermination":true,"framingRejected":true,"hostRejected":true,"iOSSafariDeviceGate":"notExecutedManual","installedAcceptance":true,"interruptedUploadCleanupVerified":true,"listenerAbsentAfterRestartStop":true,"listenerAbsentAfterStop":true,"listenerAbsentBeforeStart":true,"listenerActiveAfterStart":true,"macOS14LifecycleGate":"notExecutedManual","macOS15LifecycleGate":"notExecutedManual","manualAccessibilityExecuted":false,"manualRealSampleExecuted":false,"memberCount":4,"ocrImportExecuted":false,"ok":true,"oldSessionRejected":true,"originRejected":true,"pairingRejected":true,"plaintextPersistenceVerified":true,"productionBundleMarkerVerified":true,"productionExecutableProbeExecuted":true,"productionExecutableSHA256":"%s","productionRejectionUnitPassed":true,"recordCount":96,"restartVerified":true,"scanMatchCount":0,"storageApplicationLayerEncryption":false,"storageConfidentiality":"plaintext","streamingUploadVerified":true,"summarySHA256":"%s","targetedRetrievalUnderThirtySeconds":%s,"tokenSetSHA256":"%s","uniqueFilesStored":true}\n' \
    "$DICOM_CACHED_WINDOW_P95_MILLISECONDS" \
    "$DICOM_FOREGROUND_P95_MILLISECONDS" \
    "$DICOM_MANAGED_FULL_READ_BYTES" \
    "$DICOM_MAXIMUM_CONCURRENT_WORKERS" \
    "$DICOM_MAXIMUM_LIVE_DESCRIPTORS" \
    "$DICOM_MAXIMUM_MANAGED_FULL_READS_PER_OBJECT" \
    "$DICOM_MAXIMUM_QUEUE_DEPTH" \
    "$DICOM_MAXIMUM_WRITES_PER_OBJECT" \
    "$DICOM_PEAK_ADDED_DISK_BYTES" \
    "$DICOM_RSS_PEAK_DELTA_BYTES" \
    "$DICOM_SOURCE_BYTES_READ" \
    "$DICOM_STAGING_BYTES_WRITTEN" \
    "$ACCEPTANCE_EXECUTABLE_HASH" "$SEED_DIGEST" \
    "$TARGETED_RETRIEVAL_UNDER_THIRTY_SECONDS" \
    "$TOKEN_SET_DIGEST" >"$ACCEPTANCE_CANDIDATE" \
    || return 1
  /bin/chmod 644 "$ACCEPTANCE_CANDIDATE" || return 1
}

prepare_internal_fault_temp() {
  local token="$1"
  TEMP_DIRECTORY="/tmp/kinlogue-acceptance.fault.$token"
  TEMP_DIRECTORY_ALTERNATE=""
  [[ ! -e "$TEMP_DIRECTORY" && ! -L "$TEMP_DIRECTORY" \
      && ! -e "$TEMP_DIRECTORY.removal" \
      && ! -L "$TEMP_DIRECTORY.removal" ]] || return 1
  /bin/mkdir -m 700 -- "$TEMP_DIRECTORY" || return 1
  TEMP_DIRECTORY_IDENTITY="$(directory_identity "$TEMP_DIRECTORY")" \
    || return 1
  private_directory_is_current \
    "$TEMP_DIRECTORY" "$TEMP_DIRECTORY_IDENTITY"
}

run_internal_fault_test() {
  local mode="$1"
  local token="${KINLOGUE_ACCEPTANCE_INTERNAL_TEST_TOKEN:-}"
  /usr/bin/printf '%s\n' "$token" \
    | /usr/bin/grep -Eq '^[0-9a-f]{24,32}$' || fail
  CURRENT_UID="$(/usr/bin/id -u 2>/dev/null)" || fail
  RUN_ID="$token"
  FAILURE_SCAN_ATTEMPTED=true
  prepare_internal_fault_temp "$token" || fail

  case "$mode" in
    double-signal-finalizer)
      FAILURE_FINALIZER_SIGNAL_PROBE=true
      fail
      ;;
    handoff-before-rename \
      | handoff-after-rename-before-primary \
      | handoff-after-primary-before-alternate)
      handoff_temp_directory "/tmp/kinlogue-acceptance.$token" || fail
      fail
      ;;
    staged-after-registration)
      /bin/mkdir -p -- "$REPO_DIR/dist/acceptance" || fail
      BUILD_STAGE_DIRECTORY="$REPO_DIR/dist/acceptance/.run-build.$token"
      [[ ! -e "$BUILD_STAGE_DIRECTORY" \
          && ! -L "$BUILD_STAGE_DIRECTORY" \
          && ! -e "$BUILD_STAGE_DIRECTORY.removal" \
          && ! -L "$BUILD_STAGE_DIRECTORY.removal" ]] || fail
      /bin/mkdir -m 700 -- "$BUILD_STAGE_DIRECTORY" || fail
      BUILD_STAGE_DIRECTORY_IDENTITY="$(directory_identity \
        "$BUILD_STAGE_DIRECTORY")" || fail
      BUILD_STAGE_DIRECTORY_OWNED=true
      private_directory_is_current \
        "$BUILD_STAGE_DIRECTORY" "$BUILD_STAGE_DIRECTORY_IDENTITY" || fail
      STAGED_APP="$BUILD_STAGE_DIRECTORY/Kinlogue-Acceptance-$RUN_ID.app"
      /bin/mkdir -m 700 -- "$STAGED_APP" || fail
      STAGED_APP_IDENTITY="$(directory_identity "$STAGED_APP")" || fail
      STAGED_APP_OWNED=true
      handle_signal 143
      ;;
    quarantine-replacement-race)
      /bin/mkdir -m 700 -- "$TEMP_DIRECTORY/owned-payload" || fail
      /usr/bin/touch -- "$TEMP_DIRECTORY/owned-payload/file" || fail
      cleanup_temp_candidate \
        "$TEMP_DIRECTORY" "$TEMP_DIRECTORY_IDENTITY"
      [[ $? -ne 0 ]] || fail
      fail
      ;;
    success-cleanup-failure)
      /bin/mkdir -m 700 -- "$TEMP_DIRECTORY.removal" || fail
      /usr/bin/touch -- "$TEMP_DIRECTORY.removal/sentinel" || fail
      if cleanup_temp; then
        SUCCESSFUL_EXIT=true
        /usr/bin/printf \
          '{"code":"KLA_UNEXPECTED_SUCCESS","ok":false}\n'
        exit 0
      fi
      fail
      ;;
    build-during-signal)
      RUN_ID=""
      /bin/mkdir -p -- "$REPO_DIR/dist/acceptance" || fail
      BUILD_STAGE_DIRECTORY="$REPO_DIR/dist/acceptance/.run-build.$token"
      [[ ! -e "$BUILD_STAGE_DIRECTORY" \
          && ! -L "$BUILD_STAGE_DIRECTORY" \
          && ! -e "$BUILD_STAGE_DIRECTORY.removal" \
          && ! -L "$BUILD_STAGE_DIRECTORY.removal" ]] || fail
      /bin/mkdir -m 700 -- "$BUILD_STAGE_DIRECTORY" || fail
      BUILD_STAGE_DIRECTORY_IDENTITY="$(directory_identity \
        "$BUILD_STAGE_DIRECTORY")" || fail
      BUILD_STAGE_DIRECTORY_OWNED=true
      private_directory_is_current \
        "$BUILD_STAGE_DIRECTORY" "$BUILD_STAGE_DIRECTORY_IDENTITY" || fail
      /bin/sleep 300 &
      ACTIVE_CHILD_PID=$!
      /bin/mkdir -m 700 -- \
        "$BUILD_STAGE_DIRECTORY/Kinlogue-Acceptance-unparsed.app" || fail
      /usr/bin/printf '%s\n' "$ACTIVE_CHILD_PID" \
        >"$BUILD_STAGE_DIRECTORY/child.pid" || fail
      /usr/bin/touch "$BUILD_STAGE_DIRECTORY/child-ready" || fail
      while /bin/kill -0 "$ACTIVE_CHILD_PID" >/dev/null 2>&1; do
        /bin/sleep 0.05
      done
      wait "$ACTIVE_CHILD_PID" >/dev/null 2>&1
      ACTIVE_CHILD_PID=""
      fail
      ;;
    *)
      fail
      ;;
  esac
}

trap handle_exit EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM
trap 'handle_signal 129' HUP

if [[ -n "${KINLOGUE_ACCEPTANCE_INTERNAL_FAULT_TEST:-}" ]]; then
  run_internal_fault_test "$KINLOGUE_ACCEPTANCE_INTERNAL_FAULT_TEST"
  fail
fi

TEMP_DIRECTORY="$(/usr/bin/mktemp -d /tmp/kinlogue-acceptance.XXXXXX 2>/dev/null)" \
  || fail
[[ -d "$TEMP_DIRECTORY" && ! -L "$TEMP_DIRECTORY" ]] || fail
/bin/chmod 700 "$TEMP_DIRECTORY" || fail
TEMP_DIRECTORY_IDENTITY="$(directory_identity "$TEMP_DIRECTORY")" || fail

CURRENT_UID="$(/usr/bin/id -u 2>/dev/null)" || fail
CURRENT_USER="$(/usr/bin/id -un 2>/dev/null)" || fail
PASSWD_HOME_DIRECTORY="$(/usr/bin/id -P "$CURRENT_USER" 2>/dev/null \
  | /usr/bin/awk -F: -v expected_uid="$CURRENT_UID" \
      '$3 == expected_uid { print $9; exit }')"
[[ -n "$CURRENT_UID" && -n "$CURRENT_USER" \
    && -n "$PASSWD_HOME_DIRECTORY" \
    && "$USER_HOME_DIRECTORY" == "$PASSWD_HOME_DIRECTORY" ]] || fail
[[ "$USER_HOME_DIRECTORY" == /* \
    && "$USER_HOME_DIRECTORY" != "/" \
    && -d "$USER_HOME_DIRECTORY" \
    && ! -L "$USER_HOME_DIRECTORY" ]] || fail
private_directory_is_current \
  "$TEMP_DIRECTORY" "$TEMP_DIRECTORY_IDENTITY" || fail
USER_APPLICATIONS_DIRECTORY="$USER_HOME_DIRECTORY/Applications"

if [[ -e "$REPORT_PATH" || -L "$REPORT_PATH" ]]; then
  [[ -f "$REPORT_PATH" && ! -L "$REPORT_PATH" ]] || fail
  /bin/rm -f -- "$REPORT_PATH" >/dev/null 2>&1 || fail
fi

BUILD_LOG="$TEMP_DIRECTORY/build.log"
ACCEPTANCE_OUTPUT_DIRECTORY="$REPO_DIR/dist/acceptance"
FAILURE_STAGE="acceptance-build"
if [[ -e "$ACCEPTANCE_OUTPUT_DIRECTORY" \
    || -L "$ACCEPTANCE_OUTPUT_DIRECTORY" ]]; then
  [[ -d "$ACCEPTANCE_OUTPUT_DIRECTORY" \
      && ! -L "$ACCEPTANCE_OUTPUT_DIRECTORY" ]] || fail
else
  /bin/mkdir -m 700 -- "$ACCEPTANCE_OUTPUT_DIRECTORY" || fail
fi
BUILD_STAGE_DIRECTORY="$(/usr/bin/mktemp -d \
  "$ACCEPTANCE_OUTPUT_DIRECTORY/.run-build.XXXXXXXX")" || fail
BUILD_STAGE_DIRECTORY_IDENTITY="$(directory_identity \
  "$BUILD_STAGE_DIRECTORY")" || fail
BUILD_STAGE_DIRECTORY_OWNED=true
private_directory_is_current \
  "$BUILD_STAGE_DIRECTORY" "$BUILD_STAGE_DIRECTORY_IDENTITY" || fail

"$REPO_DIR/scripts/build-acceptance-app.sh" \
  --output-directory "$BUILD_STAGE_DIRECTORY" >"$BUILD_LOG" 2>&1 &
ACTIVE_CHILD_PID=$!
BUILD_EXITED=false
for _ in {1..12000}; do
  if ! /bin/kill -0 "$ACTIVE_CHILD_PID" >/dev/null 2>&1; then
    BUILD_EXITED=true
    break
  fi
  /bin/sleep 0.05
done
if [[ "$BUILD_EXITED" != true ]]; then
  /bin/kill -KILL "$ACTIVE_CHILD_PID" >/dev/null 2>&1 || true
fi
wait "$ACTIVE_CHILD_PID" >/dev/null 2>&1
BUILD_STATUS=$?
ACTIVE_CHILD_PID=""
[[ "$BUILD_EXITED" == true && "$BUILD_STATUS" -eq 0 ]] || fail
RUN_ID="$(
  /usr/bin/awk -F': ' '$1 == "Acceptance run ID" { print $2; exit }' "$BUILD_LOG"
)"
canonical_run_id || fail

STAGED_APP="$BUILD_STAGE_DIRECTORY/Kinlogue-Acceptance-$RUN_ID.app"
[[ -d "$STAGED_APP" && ! -L "$STAGED_APP" ]] || fail
STAGED_APP_IDENTITY="$(directory_identity "$STAGED_APP")" || fail
STAGED_APP_OWNED=true

CANONICAL_TEMP_DIRECTORY="/tmp/kinlogue-acceptance.$RUN_ID"
handoff_temp_directory "$CANONICAL_TEMP_DIRECTORY" "$BUILD_LOG" || fail

PRODUCTION_UNIT_OUT="$TEMP_DIRECTORY/production-unit.out"
PRODUCTION_UNIT_ERR="$TEMP_DIRECTORY/production-unit.err"
FAILURE_STAGE="production-rejection"
if ! "$REPO_DIR/scripts/test.sh" \
    --filter productionSyntheticSmokeIsRejectedBeforeAnyRunnerCanStart -j 2 \
    >"$PRODUCTION_UNIT_OUT" 2>"$PRODUCTION_UNIT_ERR"; then
  fail
fi
if ! /usr/bin/grep -Fq \
    'KINLOGUE_PRODUCTION_REJECTION_UNIT_PASSED' \
    "$PRODUCTION_UNIT_OUT" "$PRODUCTION_UNIT_ERR"; then
  fail
fi
/bin/rm -f -- "$PRODUCTION_UNIT_OUT" "$PRODUCTION_UNIT_ERR" || fail
PRODUCTION_REJECTION_UNIT_PASSED=true

if [[ -e "$USER_APPLICATIONS_DIRECTORY" || -L "$USER_APPLICATIONS_DIRECTORY" ]]; then
  [[ -d "$USER_APPLICATIONS_DIRECTORY" && ! -L "$USER_APPLICATIONS_DIRECTORY" ]] \
    || fail
else
  /bin/mkdir -- "$USER_APPLICATIONS_DIRECTORY" || fail
  APPLICATIONS_DIRECTORY_CREATED=true
  APPLICATIONS_DIRECTORY_IDENTITY="$(directory_identity \
    "$USER_APPLICATIONS_DIRECTORY")" || fail
fi

INSTALLED_APP="$USER_APPLICATIONS_DIRECTORY/Kinlogue-Acceptance-$RUN_ID.app"
FAILURE_STAGE="install-copy"
[[ ! -e "$INSTALLED_APP" && ! -L "$INSTALLED_APP" ]] || fail
/bin/mkdir -- "$INSTALLED_APP" || fail
INSTALLED_APP_IDENTITY="$(directory_identity "$INSTALLED_APP")" || fail
INSTALLED_APP_OWNED=true
/usr/bin/ditto "$STAGED_APP" "$INSTALLED_APP" || fail
owned_installed_app_is_current || fail
[[ -z "$(/usr/bin/find "$INSTALLED_APP" -type l -print -quit)" ]] || fail
/usr/bin/codesign --verify --deep --strict "$INSTALLED_APP" >/dev/null 2>&1 || fail

STAGED_MANIFEST="$TEMP_DIRECTORY/staged.manifest"
INSTALLED_MANIFEST="$TEMP_DIRECTORY/installed.manifest"
STAGED_HASH="$(bundle_hash "$STAGED_APP" "$STAGED_MANIFEST")" || fail
INSTALLED_HASH="$(bundle_hash "$INSTALLED_APP" "$INSTALLED_MANIFEST")" || fail
[[ "$STAGED_HASH" == "$INSTALLED_HASH" ]] || fail

INSTALLED_INFO_PLIST="$INSTALLED_APP/Contents/Info.plist"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -expect string \
      "$INSTALLED_INFO_PLIST")" \
    == "com.kinlogue.mac.acceptance.$RUN_ID" ]] || fail
[[ "$(/usr/bin/plutil -extract KinlogueAcceptanceEnabled raw -expect bool \
      "$INSTALLED_INFO_PLIST")" == "true" ]] || fail
[[ "$(/usr/bin/plutil -extract KinlogueAcceptanceRunID raw -expect string \
      "$INSTALLED_INFO_PLIST")" == "$RUN_ID" ]] || fail
ACCEPTANCE_BUNDLE_IDENTIFIER="com.kinlogue.mac.acceptance.$RUN_ID"

ACCEPTANCE_EXECUTABLE="$INSTALLED_APP/Contents/MacOS/Kinlogue"
[[ -f "$ACCEPTANCE_EXECUTABLE" && ! -L "$ACCEPTANCE_EXECUTABLE" \
  && -x "$ACCEPTANCE_EXECUTABLE" ]] || fail
[[ -f "$PRODUCTION_EXECUTABLE" && ! -L "$PRODUCTION_EXECUTABLE" \
  && -x "$PRODUCTION_EXECUTABLE" ]] || fail
ACCEPTANCE_EXECUTABLE_HASH="$(
  /usr/bin/shasum -a 256 -- "$ACCEPTANCE_EXECUTABLE" \
    | /usr/bin/awk '{print $1}'
)" || fail
/usr/bin/printf '%s\n' "$ACCEPTANCE_EXECUTABLE_HASH" \
  | /usr/bin/grep -Eq '^[0-9a-f]{64}$' || fail

PRODUCTION_INFO_PLIST="$REPO_DIR/dist/Kinlogue.app/Contents/Info.plist"
[[ -f "$PRODUCTION_INFO_PLIST" && ! -L "$PRODUCTION_INFO_PLIST" ]] || fail
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -expect string \
      "$PRODUCTION_INFO_PLIST")" == "com.kinlogue.mac" ]] || fail
if /usr/bin/plutil -extract KinlogueAcceptanceEnabled raw \
    "$PRODUCTION_INFO_PLIST" >/dev/null 2>&1 \
  || /usr/bin/plutil -extract KinlogueAcceptanceRunID raw \
    "$PRODUCTION_INFO_PLIST" >/dev/null 2>&1; then
  fail
fi
PRODUCTION_BUNDLE_MARKER_PASSED=true

FAILURE_STAGE="dicom-fixture-generator-build"
DICOM_GENERATOR_BUILD_LOG="$TEMP_DIRECTORY/dicom-generator-build.log"
(
  cd "$REPO_DIR" || exit 1
  swift build --disable-sandbox -c release \
    --product KinlogueDICOMAcceptanceFixtureGenerator -j 2
) >"$DICOM_GENERATOR_BUILD_LOG" 2>&1 || fail
DICOM_GENERATOR_BIN_DIRECTORY="$(
  cd "$REPO_DIR" || exit 1
  swift build --disable-sandbox -c release --show-bin-path
)" || fail
DICOM_FIXTURE_GENERATOR="$DICOM_GENERATOR_BIN_DIRECTORY/KinlogueDICOMAcceptanceFixtureGenerator"
[[ -f "$DICOM_FIXTURE_GENERATOR" \
    && ! -L "$DICOM_FIXTURE_GENERATOR" \
    && -x "$DICOM_FIXTURE_GENERATOR" ]] || fail

FAILURE_STAGE="claim"
run_claim_phase || fail
FAILURE_STAGE="seed"
run_phase seed KLA_SEED_COMPLETE 4 96 96 || fail
SEED_DIGEST="$(json_value summarySHA256 "$TEMP_DIRECTORY/seed.json")"
TOKEN_SET_DIGEST="$(json_value tokenSetSHA256 "$TEMP_DIRECTORY/seed.json")"
TARGETED_RETRIEVAL_UNDER_THIRTY_SECONDS="$(json_value \
  targetedRetrievalUnderThirtySeconds "$TEMP_DIRECTORY/seed.json")"
[[ "$TARGETED_RETRIEVAL_UNDER_THIRTY_SECONDS" == true ]] || fail

FAILURE_STAGE="restart"
run_phase restart KLA_RESTART_COMPLETE 4 96 96 || fail
[[ "$(json_value summarySHA256 "$TEMP_DIRECTORY/restart.json")" \
    == "$SEED_DIGEST" ]] || fail
[[ "$(json_value tokenSetSHA256 "$TEMP_DIRECTORY/restart.json")" \
    == "$TOKEN_SET_DIGEST" ]] || fail
[[ "$(json_value targetedRetrievalUnderThirtySeconds \
      "$TEMP_DIRECTORY/restart.json")" \
    == "$TARGETED_RETRIEVAL_UNDER_THIRTY_SECONDS" ]] || fail

FAILURE_STAGE="dicom-fixture"
generate_dicom_acceptance_fixture || fail
FAILURE_STAGE="dicom-import"
run_dicom_phase dicom-import KLA_DICOM_IMPORT_COMPLETE \
  1 3 216 1 217 648 || fail
capture_dicom_import_metrics || fail
FAILURE_STAGE="dicom-restart"
run_dicom_phase dicom-restart KLA_DICOM_RESTART_COMPLETE \
  1 3 216 1 217 3 || fail
FAILURE_STAGE="dicom-delete"
run_dicom_phase dicom-delete KLA_DICOM_DELETE_COMPLETE \
  0 0 0 0 0 0 || fail
cleanup_owned_dicom_input || fail
DICOM_ACCEPTANCE_PASSED=true

FAILURE_STAGE="post-dicom-restart"
run_phase restart KLA_RESTART_COMPLETE 4 96 96 post-dicom-restart || fail
POST_DICOM_RESTART_FILE="$TEMP_DIRECTORY/post-dicom-restart.json"
[[ "$(json_value tokenSetSHA256 "$POST_DICOM_RESTART_FILE")" \
    == "$TOKEN_SET_DIGEST" ]] || fail
[[ "$(json_value targetedRetrievalUnderThirtySeconds \
      "$POST_DICOM_RESTART_FILE")" \
    == "$TARGETED_RETRIEVAL_UNDER_THIRTY_SECONDS" ]] || fail
SEED_DIGEST="$(json_value summarySHA256 "$POST_DICOM_RESTART_FILE")"
/usr/bin/printf '%s\n' "$SEED_DIGEST" \
  | /usr/bin/grep -Eq '^[0-9a-f]{64}$' || fail

FAILURE_STAGE="lan-receiver"
run_lan_receiver_phase lan-receiver KLA_LAN_RECEIVER_COMPLETE || fail
LAN_RECEIVER_PROBE_PASSED=true
FAILURE_STAGE="lan-receiver-restart"
run_lan_receiver_phase lan-receiver-restart KLA_LAN_RESTART_COMPLETE || fail
LAN_RECEIVER_RESTART_PASSED=true

FAILURE_STAGE="forced-termination-launch"
FORCED_OUT="$TEMP_DIRECTORY/forced-ready.json"
FORCED_ERR="$TEMP_DIRECTORY/forced-ready.err"
start_installed_bundle "$FORCED_OUT" "$FORCED_ERR" \
  --synthetic-smoke --acceptance-phase=forced-ready \
  || fail
FAILURE_STAGE="forced-termination-ready"
FORCED_EVENT_READY=false
for _ in {1..600}; do
  if validate_phase_event "$FORCED_OUT" KLA_FORCED_READY 4 96 96 true; then
    FORCED_EVENT_READY=true
    break
  fi
  if ! /bin/kill -0 "$ACTIVE_CHILD_PID" >/dev/null 2>&1; then
    break
  fi
  refresh_active_acceptance_pid >/dev/null 2>&1 || true
  /bin/sleep 0.05
done
[[ "$FORCED_EVENT_READY" == true && ! -s "$FORCED_ERR" ]] || {
  stop_active_child
  fail
}
FAILURE_STAGE="forced-termination-summary"
[[ "$(json_value summarySHA256 "$FORCED_OUT")" == "$SEED_DIGEST" ]] || fail
[[ "$(json_value tokenSetSHA256 "$FORCED_OUT")" == "$TOKEN_SET_DIGEST" ]] \
  || fail
FAILURE_STAGE="forced-termination-pid"
refresh_active_acceptance_pid >/dev/null 2>&1 || fail
FORCED_PID="$ACTIVE_ACCEPTANCE_PID"
FAILURE_STAGE="forced-termination-kill"
hard_kill_active_acceptance || fail
FAILURE_STAGE="forced-termination-launcher-wait"
wait_for_installed_bundle || fail
FAILURE_STAGE="forced-termination-process-exit"
if /bin/kill -0 "$FORCED_PID" >/dev/null 2>&1; then
  fail
fi

FAILURE_STAGE="after-force"
run_phase after-force KLA_AFTER_FORCE_COMPLETE 4 96 96 || fail
[[ "$(json_value summarySHA256 "$TEMP_DIRECTORY/after-force.json")" \
    == "$SEED_DIGEST" ]] || fail
[[ "$(json_value tokenSetSHA256 "$TEMP_DIRECTORY/after-force.json")" \
    == "$TOKEN_SET_DIGEST" ]] || fail
[[ "$(json_value targetedRetrievalUnderThirtySeconds \
      "$TEMP_DIRECTORY/after-force.json")" \
    == "$TARGETED_RETRIEVAL_UNDER_THIRTY_SECONDS" ]] || fail

FAILURE_STAGE="report-preparation"
prepare_acceptance_candidate || fail
prepare_verification_candidate || fail

FAILURE_STAGE="canary-scan"
SCAN_OUT="$TEMP_DIRECTORY/scan.json"
SCAN_ERR="$TEMP_DIRECTORY/scan.err"
if ! "$REPO_DIR/scripts/scan-acceptance.sh" "$RUN_ID" \
    >"$SCAN_OUT" 2>"$SCAN_ERR"; then
  fail
fi
[[ ! -s "$SCAN_ERR" ]] || fail
[[ "$(json_value code "$SCAN_OUT")" == "KLA_SCAN_COMPLETE" ]] || fail
[[ "$(json_value ok "$SCAN_OUT")" == "true" ]] || fail
[[ "$(json_value count "$SCAN_OUT")" == "0" ]] || fail
[[ "$(json_value summarySHA256 "$SCAN_OUT")" == "$TOKEN_SET_DIGEST" ]] || fail

FAILURE_STAGE="cleanup"
run_cleanup_phase || fail

SANDBOX_RUN_ROOT="$USER_HOME_DIRECTORY/Library/Containers/com.kinlogue.mac.acceptance.$RUN_ID/Data/Library/Application Support/Kinlogue/Acceptance/$RUN_ID"
UNCONTAINED_RUN_ROOT="$USER_HOME_DIRECTORY/Library/Application Support/Kinlogue/Acceptance/$RUN_ID"
[[ ! -e "$SANDBOX_RUN_ROOT" && ! -L "$SANDBOX_RUN_ROOT" ]] || fail
[[ ! -e "$UNCONTAINED_RUN_ROOT" && ! -L "$UNCONTAINED_RUN_ROOT" ]] || fail

FAILURE_STAGE="report-publication"
cleanup_owned_installed_app || fail
cleanup_owned_build_stage || fail

[[ "$VERIFICATION_CANDIDATE_OWNED" == true \
    && -f "$VERIFICATION_CANDIDATE" \
    && ! -L "$VERIFICATION_CANDIDATE" ]] || fail
[[ "$ACCEPTANCE_CANDIDATE_OWNED" == true \
    && "$(file_identity "$ACCEPTANCE_CANDIDATE")" \
      == "$ACCEPTANCE_CANDIDATE_IDENTITY" ]] || fail
FINAL_REPORT_LINE="$(/bin/cat "$ACCEPTANCE_CANDIDATE")" || fail
[[ -n "$FINAL_REPORT_LINE" ]] || fail
[[ ! -e "$REPORT_PATH" && ! -L "$REPORT_PATH" ]] || fail
cleanup_temp || fail
TEMP_DIRECTORY=""
TEMP_DIRECTORY_ALTERNATE=""
TEMP_DIRECTORY_IDENTITY=""
REPORT_OWNED=true
REPORT_IDENTITY="$ACCEPTANCE_CANDIDATE_IDENTITY"
/bin/mv -- "$ACCEPTANCE_CANDIDATE" "$REPORT_PATH" || fail
ACCEPTANCE_CANDIDATE_OWNED=false
VERIFICATION_REPORT_OWNED=true
VERIFICATION_REPORT_IDENTITY="$VERIFICATION_CANDIDATE_IDENTITY"
/bin/mv -f -- "$VERIFICATION_CANDIDATE" "$VERIFICATION_REPORT" || fail
VERIFICATION_CANDIDATE_OWNED=false
SUCCESSFUL_EXIT=true
/usr/bin/printf '%s\n' "$FINAL_REPORT_LINE" 2>/dev/null || true
exit 0
