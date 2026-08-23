#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
APP_BUNDLE="$REPO_DIR/dist/Kinlogue.app"
VERIFICATION_REPORT="$REPO_DIR/dist/verification-report.json"
HELPER_NAME="KinlogueDICOMDecoderHelper.xpc"
HELPER_BUNDLE="$APP_BUNDLE/Contents/XPCServices/$HELPER_NAME"
HELPER_EXECUTABLE_NAME="KinlogueDICOMDecoderHelper"
HELPER_ENTITLEMENTS="$REPO_DIR/packaging/KinlogueDICOMDecoderHelper.entitlements"
HELPER_PROJECT="$REPO_DIR/packaging/KinlogueDICOMDecoderHelper.xcodeproj"
HELPER_PACKAGE_CACHE="$REPO_DIR/.build/dicom-xcode-packages"
PROBE_TARGET="KinlogueDICOMXPCProbe"
SWIFTC_EXECUTABLE="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
XCODEBUILD_EXECUTABLE="/usr/bin/xcodebuild"
XCRUN_EXECUTABLE="/usr/bin/xcrun"
PROBE_ROOT=""
STOPPED_HELPER_PID=""
STOPPED_HELPER_HOST=""
USE_VERIFIED_APP=false

fail() {
  echo "DICOM XPC verification failed: $1" >&2
  exit 1
}

cleanup() {
  if [[ -n "${STOPPED_HELPER_PID:-}" \
      && -n "${STOPPED_HELPER_HOST:-}" ]]; then
    if /bin/kill -0 "$STOPPED_HELPER_PID" >/dev/null 2>&1 \
        && helper_belongs_to_host "$STOPPED_HELPER_PID" "$STOPPED_HELPER_HOST"; then
      /bin/kill -KILL "$STOPPED_HELPER_PID" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "${PROBE_ROOT:-}" \
      && -d "$PROBE_ROOT" && ! -L "$PROBE_ROOT" \
      && "${PROBE_ROOT:h}" == /private/tmp \
      && "${PROBE_ROOT:t}" == kinlogue-dicom-xpc-probe.* ]]; then
    /bin/rm -rf -- "$PROBE_ROOT"
  fi
}
trap cleanup EXIT INT TERM HUP

bundle_hash() {
  local bundle="$1"
  local manifest="$2"

  (
    cd "$bundle"
    /usr/bin/find . -type f -print \
      | LC_ALL=C /usr/bin/sort \
      | while IFS= read -r relative_path; do
          file_hash="$(/usr/bin/shasum -a 256 -- "$relative_path" \
            | /usr/bin/awk '{print $1}')"
          /usr/bin/printf '%s\t%s\n' "$file_hash" "$relative_path"
        done
  ) >"$manifest"
  /usr/bin/shasum -a 256 -- "$manifest" | /usr/bin/awk '{print $1}'
}

if [[ "$#" -eq 1 && "${1:-}" == --use-verified-app ]]; then
  USE_VERIFIED_APP=true
elif [[ "$#" -ne 0 ]]; then
  fail "usage: verify-dicom-xpc.sh [--use-verified-app]"
fi
[[ -x "$SWIFTC_EXECUTABLE" && -x "$XCODEBUILD_EXECUTABLE" \
    && -x "$XCRUN_EXECUTABLE" ]] \
  || fail "the full Xcode Swift toolchain is unavailable"
SDK_PATH_INPUT=$($XCRUN_EXECUTABLE --sdk macosx --show-sdk-path) \
  || fail "the macOS SDK could not be resolved"
[[ -d "$SDK_PATH_INPUT" ]] || fail "the macOS SDK is unavailable"
SDK_PATH=$(cd "$SDK_PATH_INPUT" && /bin/pwd -P) \
  || fail "the macOS SDK could not be canonicalized"

# build-app.sh performs the auditable Xcode package resolution, creates the
# standard nested .xpc, and signs each nested resource bundle before the
# sandboxed Helper and outer app. CI/release may reuse only the exact bundle
# and report produced by the immediately preceding clean-source verify-app.
if [[ "$USE_VERIFIED_APP" == true ]]; then
  [[ -z "$(/usr/bin/git -C "$REPO_DIR" status \
      --porcelain --untracked-files=normal)" ]] \
    || fail "--use-verified-app requires a clean source checkout"
  [[ -d "$APP_BUNDLE" && ! -L "$APP_BUNDLE" \
      && -f "$VERIFICATION_REPORT" && ! -L "$VERIFICATION_REPORT" ]] \
    || fail "the preverified app or verification report is unavailable"
  /usr/bin/plutil -convert json -o /dev/null "$VERIFICATION_REPORT" \
    || fail "the preverified app report is invalid"
  SOURCE_REVISION=$(/usr/bin/git -C "$REPO_DIR" rev-parse --verify HEAD) \
    || fail "the source revision is unavailable"
  [[ "$(/usr/bin/plutil -extract source.cleanRequired raw -expect bool \
        "$VERIFICATION_REPORT")" == true \
      && "$(/usr/bin/plutil -extract source.dirty raw -expect bool \
        "$VERIFICATION_REPORT")" == false \
      && "$(/usr/bin/plutil -extract source.revision raw -expect string \
        "$VERIFICATION_REPORT")" == "$SOURCE_REVISION" \
      && "$(/usr/bin/plutil -extract gates.bundleVerification raw -expect string \
        "$VERIFICATION_REPORT")" == passed ]] \
    || fail "the app was not produced by the current clean-source verification"
  PROBE_ROOT=$(/usr/bin/mktemp -d /private/tmp/kinlogue-dicom-xpc-probe.XXXXXX) \
    || fail "a private probe directory could not be created"
  /bin/chmod 700 "$PROBE_ROOT"
  EXPECTED_BUNDLE_HASH=$(/usr/bin/plutil -extract artifact.bundleSHA256 raw \
    -expect string "$VERIFICATION_REPORT")
  ACTUAL_BUNDLE_HASH=$(bundle_hash \
    "$APP_BUNDLE" "$PROBE_ROOT/preverified-bundle-manifest.txt")
  [[ "$ACTUAL_BUNDLE_HASH" == "$EXPECTED_BUNDLE_HASH" ]] \
    || fail "the preverified app changed after verify-app"
  /usr/bin/codesign --verify --strict "$APP_BUNDLE" \
    || fail "the preverified outer app failed strict signature verification"
else
  "$REPO_DIR/scripts/build-app.sh"
fi

[[ -d "$HELPER_BUNDLE" && ! -L "$HELPER_BUNDLE" ]] \
  || fail "the embedded Xcode-built Helper is unavailable"
[[ -z "$(/usr/bin/find "$HELPER_BUNDLE" -type l -print -quit)" ]] \
  || fail "the embedded Helper contains a symbolic link"

if [[ -z "$PROBE_ROOT" ]]; then
  PROBE_ROOT=$(/usr/bin/mktemp -d /private/tmp/kinlogue-dicom-xpc-probe.XXXXXX) \
    || fail "a private probe directory could not be created"
  /bin/chmod 700 "$PROBE_ROOT"
fi
PROBE_EXECUTABLE="$PROBE_ROOT/$PROBE_TARGET"

# SwiftPM intentionally does not publish this executable target, so compile
# the four reviewed Foundation-only probe sources directly with Xcode's
# pinned toolchain instead of adding a release product solely for the gate.
"$SWIFTC_EXECUTABLE" \
  -parse-as-library \
  -O \
  -D KINLOGUE_DICOM_XPC_CRASH_PROBE \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macos14.0 \
  -module-name KinlogueDICOMXPCProbeHost \
  "$REPO_DIR/Sources/KinlogueDICOMIPC/DICOMIPC.swift" \
  "$REPO_DIR/Sources/KinloguePlatform/DICOM/DICOMDecoderAdapter.swift" \
  "$REPO_DIR/Sources/KinlogueDICOMTestSupport/GeneratedDICOMFixture.swift" \
  "$REPO_DIR/Sources/KinlogueDICOMXPCProbe/KinlogueDICOMXPCProbe.swift" \
  -o "$PROBE_EXECUTABLE"
[[ -f "$PROBE_EXECUTABLE" && -x "$PROBE_EXECUTABLE" ]] \
  || fail "the non-published generated-fixture probe was not built"

create_host() {
  local host_name="$1"
  local helper_source="$2"
  local mode="$3"
  local bundle_identifier="$4"
  local canary="${5:-}"
  local crash_control_directory="${6:-}"
  local host_app="$PROBE_ROOT/$host_name.app"
  local host_info="$host_app/Contents/Info.plist"
  local host_helper="$host_app/Contents/XPCServices/$HELPER_NAME"

  /bin/mkdir -p "$host_app/Contents/MacOS" "$host_app/Contents/XPCServices"
  /bin/cp -- "$PROBE_EXECUTABLE" "$host_app/Contents/MacOS/$PROBE_TARGET"
  /bin/chmod 755 "$host_app/Contents/MacOS/$PROBE_TARGET"
  /usr/bin/ditto "$helper_source" "$host_helper"

  /usr/bin/plutil -create xml1 "$host_info"
  /usr/bin/plutil -insert CFBundlePackageType -string APPL "$host_info"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$bundle_identifier" "$host_info"
  /usr/bin/plutil -insert CFBundleExecutable -string "$PROBE_TARGET" "$host_info"
  /usr/bin/plutil -insert CFBundleVersion -string 1 "$host_info"
  /usr/bin/plutil -insert CFBundleShortVersionString -string 1.0 "$host_info"
  /usr/bin/plutil -insert LSMinimumSystemVersion -string 14.0 "$host_info"
  /usr/bin/plutil -insert KLDProbeMode -string "$mode" "$host_info"
  if [[ -n "$canary" ]]; then
    /usr/bin/plutil -insert KLDProbeCanary -string "$canary" "$host_info"
  fi
  if [[ -n "$crash_control_directory" ]]; then
    /usr/bin/plutil -insert KLDProbeCrashControlDirectory \
      -string "$crash_control_directory" "$host_info"
  fi

  for resource_bundle in \
      "$host_helper/Contents/Resources/DICOMDecoder_DicomCore.bundle" \
      "$host_helper/Contents/Resources/ZIPFoundation_ZIPFoundation.bundle"; do
    [[ -d "$resource_bundle" && ! -L "$resource_bundle" ]] \
      || fail "the Helper is missing a standard Xcode resource bundle"
    /usr/bin/codesign --verify --strict "$resource_bundle" \
      || fail "a Helper resource bundle failed strict signature verification"
  done
  /usr/bin/codesign --verify --strict "$host_helper" \
    || fail "the embedded Helper failed strict signature verification"

  # The copied Helper remains independently signed. Sign only the outer probe;
  # recursive signing would erase the boundary being tested.
  /usr/bin/codesign --force --sign - "$host_app"
  /usr/bin/codesign --verify --strict "$host_app" \
    || fail "the probe host failed strict signature verification"
  /bin/echo "$host_app"
}

helper_belongs_to_host() {
  local helper_pid="$1"
  local host_app="$2"
  local helper_executable="$host_app/Contents/XPCServices/$HELPER_NAME/Contents/MacOS/$HELPER_EXECUTABLE_NAME"
  /usr/sbin/lsof -nP -a -p "$helper_pid" -d txt -Fn 2>/dev/null \
    | /usr/bin/grep -Fxq "n$helper_executable"
}

helper_pids_for_host() {
  local host_app="$1"
  local helper_pids helper_pid
  helper_pids=$(/usr/bin/pgrep -x "$HELPER_EXECUTABLE_NAME" 2>/dev/null || true)
  for helper_pid in ${(f)helper_pids}; do
    [[ -n "$helper_pid" ]] || continue
    helper_belongs_to_host "$helper_pid" "$host_app" || continue
    /bin/echo "$helper_pid"
  done
}

refuse_existing_helper_processes() {
  if /usr/bin/pgrep -x "$HELPER_EXECUTABLE_NAME" >/dev/null 2>&1; then
    fail "refusing to interrupt an existing DICOM Helper; close the other Kinlogue instance and retry"
  fi
}

wait_for_helper_exit() {
  local host_app="$1"
  local attempt
  for attempt in {1..80}; do
    if [[ -z "$(helper_pids_for_host "$host_app")" ]]; then
      return 0
    fi
    /bin/sleep 0.025
  done
  return 1
}

stop_helper_processes() {
  local host_app="$1"
  local helper_pids helper_pid
  helper_pids=$(helper_pids_for_host "$host_app")
  for helper_pid in ${(f)helper_pids}; do
    [[ -n "$helper_pid" ]] || continue
    /bin/kill -TERM "$helper_pid" >/dev/null 2>&1 || true
  done
  wait_for_helper_exit "$host_app"
}

launch_and_monitor() {
  local host_app="$1"
  local expected_output="$2"
  local label="$3"
  local stdout_file="$PROBE_ROOT/$label.stdout"
  local stderr_file="$PROBE_ROOT/$label.stderr"
  local open_pid="" helper_pids="" helper_pid="" socket_output=""
  local open_status=0 helper_seen=false socket_seen=false

  refuse_existing_helper_processes

  # NSXPC service launch is mediated by launchd. This gate must run in a
  # normal macOS session (or an explicitly approved unsandboxed CI step).
  /usr/bin/open -n -W -g -o "$stdout_file" --stderr "$stderr_file" "$host_app" &
  open_pid=$!
  while /bin/kill -0 "$open_pid" >/dev/null 2>&1; do
    helper_pids=$(/usr/bin/pgrep -x "$HELPER_EXECUTABLE_NAME" 2>/dev/null || true)
    for helper_pid in ${(f)helper_pids}; do
      [[ -n "$helper_pid" ]] || continue
      helper_belongs_to_host "$helper_pid" "$host_app" || continue
      helper_seen=true
      if socket_output=$(/usr/sbin/lsof -nP -a -p "$helper_pid" -i 2>/dev/null); then
        [[ -z "$socket_output" ]] || socket_seen=true
      fi
    done
    /bin/sleep 0.01
  done
  set +e
  wait "$open_pid"
  open_status=$?
  set -e

  [[ "$helper_seen" == true ]] || fail "$label never observed the embedded Helper"
  [[ "$socket_seen" == false ]] || fail "$label observed a Helper network socket"
  if [[ "$open_status" -ne 0 ]] \
      || ! /usr/bin/grep -Fxq "$expected_output" "$stdout_file"; then
    print_probe_diagnostics "$stdout_file" "$stderr_file"
    fail "$label did not produce its fixed success result"
  fi
  stop_helper_processes "$host_app" \
    || fail "$label DICOM Helper could not be stopped after the probe"
}

wait_for_control_marker() {
  local marker="$1"
  local open_pid="$2"
  local attempt
  for attempt in {1..500}; do
    if [[ -e "$marker" || -L "$marker" ]]; then
      [[ -f "$marker" && ! -L "$marker" \
          && "$(/usr/bin/stat -f '%u:%Lp:%l' -- "$marker")" \
            == "$(/usr/bin/id -u):600:1" ]]
      return
    fi
    /bin/kill -0 "$open_pid" >/dev/null 2>&1 || return 1
    /bin/sleep 0.01
  done
  return 1
}

wait_for_single_host_helper() {
  local host_app="$1"
  local open_pid="$2"
  local helper_pids=""
  local attempt
  for attempt in {1..500}; do
    helper_pids="$(helper_pids_for_host "$host_app")"
    if [[ -n "$helper_pids" ]]; then
      [[ "$helper_pids" != *$'\n'* ]] || return 1
      /bin/echo "$helper_pids"
      return
    fi
    /bin/kill -0 "$open_pid" >/dev/null 2>&1 || return 1
    /bin/sleep 0.01
  done
  return 1
}

wait_for_helper_stop() {
  local helper_pid="$1"
  local state=""
  local attempt
  for attempt in {1..100}; do
    state="$(/bin/ps -o state= -p "$helper_pid" 2>/dev/null)"
    [[ "$state" == *T* ]] && return
    /bin/kill -0 "$helper_pid" >/dev/null 2>&1 || return 1
    /bin/sleep 0.005
  done
  return 1
}

create_control_marker() {
  local marker="$1"
  (
    set -o noclobber; umask 077
    : >"$marker"
  )
}

print_probe_diagnostics() {
  local stdout_file="$1"
  local stderr_file="$2"
  [[ ! -s "$stdout_file" ]] || /bin/cat "$stdout_file" >&2
  [[ ! -s "$stderr_file" ]] || /bin/cat "$stderr_file" >&2
}

launch_crash_and_monitor() {
  local host_app="$1"
  local control_directory="$2"
  local expected_output="$3"
  local label="$4"
  local stdout_file="$PROBE_ROOT/$label.stdout"
  local stderr_file="$PROBE_ROOT/$label.stderr"
  local ready_marker="$control_directory/crash-ready"
  local armed_marker="$control_directory/crash-armed"
  local request_marker="$control_directory/crash-request-started"
  local open_pid="" helper_pid="" helper_pids="" observed_pid=""
  local socket_output=""
  local open_status=0 socket_seen=false

  refuse_existing_helper_processes
  /usr/bin/open -n -W -g -o "$stdout_file" --stderr "$stderr_file" "$host_app" &
  open_pid=$!

  if ! wait_for_control_marker "$ready_marker" "$open_pid"; then
    print_probe_diagnostics "$stdout_file" "$stderr_file"
    fail "the production Helper crash probe did not become ready"
  fi
  helper_pid="$(wait_for_single_host_helper "$host_app" "$open_pid")" \
    || fail "the production Helper crash probe did not own exactly one Helper"
  if socket_output=$(/usr/sbin/lsof -nP -a -p "$helper_pid" -i 2>/dev/null); then
    [[ -z "$socket_output" ]] || socket_seen=true
  fi
  /bin/kill -STOP "$helper_pid" \
    || fail "the production Helper crash probe could not pause the Helper"
  STOPPED_HELPER_PID="$helper_pid"
  STOPPED_HELPER_HOST="$host_app"
  wait_for_helper_stop "$helper_pid" \
    || fail "the production Helper crash probe could not confirm the paused Helper"
  helper_belongs_to_host "$helper_pid" "$host_app" \
    || fail "the paused Helper no longer belonged to the crash probe"

  create_control_marker "$armed_marker" \
    || fail "the production Helper crash probe could not publish its arm marker"
  if ! wait_for_control_marker "$request_marker" "$open_pid"; then
    print_probe_diagnostics "$stdout_file" "$stderr_file"
    fail "the production Helper crash probe never submitted its decode request"
  fi
  helper_belongs_to_host "$helper_pid" "$host_app" \
    || fail "the paused Helper identity changed before SIGKILL"
  /bin/kill -KILL "$helper_pid" \
    || fail "the production Helper crash probe could not send SIGKILL"
  STOPPED_HELPER_PID=""
  STOPPED_HELPER_HOST=""

  while /bin/kill -0 "$open_pid" >/dev/null 2>&1; do
    helper_pids="$(helper_pids_for_host "$host_app")"
    for observed_pid in ${(f)helper_pids}; do
      [[ -n "$observed_pid" ]] || continue
      if socket_output=$(/usr/sbin/lsof -nP -a -p "$observed_pid" -i 2>/dev/null); then
        [[ -z "$socket_output" ]] || socket_seen=true
      fi
    done
    /bin/sleep 0.01
  done
  set +e
  wait "$open_pid"
  open_status=$?
  set -e

  [[ "$socket_seen" == false ]] || fail "$label observed a Helper network socket"
  if [[ "$open_status" -ne 0 ]] \
      || ! /usr/bin/grep -Fxq "$expected_output" "$stdout_file"; then
    print_probe_diagnostics "$stdout_file" "$stderr_file"
    fail "$label did not produce its fixed success result"
  fi
  stop_helper_processes "$host_app" \
    || fail "$label DICOM Helper could not be stopped after recovery"
}

sign_helper() {
  local helper="$1"
  local resource_bundle
  for resource_bundle in \
      "$helper/Contents/Resources/DICOMDecoder_DicomCore.bundle" \
      "$helper/Contents/Resources/ZIPFoundation_ZIPFoundation.bundle"; do
    [[ -d "$resource_bundle" && ! -L "$resource_bundle" ]] \
      || fail "the watchdog Helper is missing a standard resource bundle"
    /usr/bin/codesign --force --sign - "$resource_bundle"
  done
  /usr/bin/codesign --force --sign - \
    --entitlements "$HELPER_ENTITLEMENTS" "$helper"
  /usr/bin/codesign --verify --strict "$helper" \
    || fail "the watchdog Helper failed strict signature verification"
}

LOG_START=$(/bin/date '+%Y-%m-%d %H:%M:%S')
DICOM_CANARY="KLD-DICOM-$(( RANDOM ))-$(( RANDOM ))-$(( RANDOM ))"
ROUNDTRIP_HOST=$(create_host \
  KinlogueDICOMXPCProbe-RoundTrip \
  "$HELPER_BUNDLE" \
  roundTrip \
  com.kinlogue.mac.dicom-xpc-probe.roundtrip \
  "$DICOM_CANARY")
launch_and_monitor "$ROUNDTRIP_HOST" KLD_DICOM_XPC_OK roundtrip

CRASH_CONTROL_DIRECTORY="$PROBE_ROOT/crash-control"
/bin/mkdir -m 700 "$CRASH_CONTROL_DIRECTORY" \
  || fail "the production Helper crash control directory could not be created"
CRASH_HOST=$(create_host \
  KinlogueDICOMXPCProbe-Crash \
  "$HELPER_BUNDLE" \
  expectCrash \
  com.kinlogue.mac.dicom-xpc-probe.crash \
  "" \
  "$CRASH_CONTROL_DIRECTORY")
launch_crash_and_monitor \
  "$CRASH_HOST" \
  "$CRASH_CONTROL_DIRECTORY" \
  KLD_DICOM_XPC_CRASH_CONTAINED \
  crash

# Build the same Helper source with a compile-time-only hang fault. The release
# target never defines this flag; its internal watchdog must terminate this
# faulted process before the client's longer timeout expires.
FAULT_DERIVED_DATA="$PROBE_ROOT/watchdog-derived"
"$XCODEBUILD_EXECUTABLE" \
  -project "$HELPER_PROJECT" \
  -scheme "$HELPER_EXECUTABLE_NAME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$FAULT_DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$HELPER_PACKAGE_CACHE" \
  -onlyUsePackageVersionsFromResolvedFile \
  -disableAutomaticPackageResolution \
  -skipPackageUpdates \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  OTHER_SWIFT_FLAGS=-DKINLOGUE_DICOM_XPC_TEST_HANG \
  build >/dev/null
FAULT_HELPER="$FAULT_DERIVED_DATA/Build/Products/Release/$HELPER_NAME"
[[ -d "$FAULT_HELPER" && ! -L "$FAULT_HELPER" ]] \
  || fail "the compile-time watchdog fault Helper was not built"
sign_helper "$FAULT_HELPER"
WATCHDOG_HOST=$(create_host \
  KinlogueDICOMXPCProbe-Watchdog \
  "$FAULT_HELPER" \
  expectWatchdog \
  com.kinlogue.mac.dicom-xpc-probe.watchdog)
launch_and_monitor \
  "$WATCHDOG_HOST" KLD_DICOM_XPC_WATCHDOG_CONTAINED watchdog

LOG_OUTPUT="$PROBE_ROOT/helper-unified.log"
/usr/bin/log show \
  --start "$LOG_START" \
  --style compact \
  --predicate 'process == "KinlogueDICOMDecoderHelper"' \
  >"$LOG_OUTPUT" 2>/dev/null \
  || fail "the DICOM Helper unified log could not be audited"
if /usr/bin/grep -Fq -- "$DICOM_CANARY" "$LOG_OUTPUT" \
    || /usr/bin/grep -Fq -- "$DICOM_CANARY" "$PROBE_ROOT/roundtrip.stdout" \
    || /usr/bin/grep -Fq -- "$DICOM_CANARY" "$PROBE_ROOT/roundtrip.stderr"; then
  fail "a DICOM content canary escaped into logs or process output"
fi
if /usr/bin/grep -E -q -- '/Users/|/private/(tmp|var)/' "$LOG_OUTPUT"; then
  fail "the DICOM Helper emitted a private filesystem path"
fi
if LC_ALL=C /usr/bin/grep -R -F -l --exclude='Info.plist' \
    "$DICOM_CANARY" "$APP_BUNDLE" "$PROBE_ROOT" >/dev/null 2>&1; then
  fail "a DICOM content canary escaped into a built artifact"
else
  CANARY_SCAN_STATUS=$?
  [[ "$CANARY_SCAN_STATUS" -eq 1 ]] \
    || fail "the DICOM built-artifact canary audit could not be completed"
fi

echo "DICOM XPC verification passed: signatures, raw fixtures, crash/hang containment, logs, and zero runtime sockets"
