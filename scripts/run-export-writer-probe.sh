#!/bin/zsh
set -euo pipefail

umask 077

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
BUILD_ROOT="$REPO_DIR/.build/export-writer-probe"
TEMP_DIRECTORY=""
ENTRY_COUNT=""
SCENARIO=""

fail() {
  print -u2 -- "Export writer probe failed: $1"
  exit 1
}

cleanup() {
  local original_status=$?
  local cleanup_failed=false
  trap - EXIT

  if [[ -n "${TEMP_DIRECTORY:-}" ]]; then
    if [[ "$TEMP_DIRECTORY" == /tmp/kinlogue-export-writer-probe.* \
        && -d "$TEMP_DIRECTORY" && ! -L "$TEMP_DIRECTORY" ]]; then
      /usr/bin/find -P -x "$TEMP_DIRECTORY" -depth -mindepth 1 -delete \
        >/dev/null 2>&1 || cleanup_failed=true
      /bin/rmdir -- "$TEMP_DIRECTORY" >/dev/null 2>&1 || cleanup_failed=true
    else
      cleanup_failed=true
    fi
  fi

  if [[ "$cleanup_failed" == true ]]; then
    print -u2 -- "Export writer probe cleanup failed"
    [[ "$original_status" -ne 0 ]] || original_status=1
  fi
  exit "$original_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ "$#" -eq 2 && "$1" == "--entries" ]]; then
  [[ "$2" == <-> && "$2" -ge 1 && "$2" -le 100000 ]] \
    || fail "--entries must be an integer from 1 through 100000"
  ENTRY_COUNT="$2"
  SCENARIO="attachment-limit"
elif [[ "$#" -eq 1 && "$1" == "--manifest-limit" ]]; then
  # One valid export-plan extreme can contain 20,000 repeated report-source
  # rows plus the catalog-wide 10,000 retained DICOM objects. The probe uses
  # distinct generic ZIP paths while every source provider returns zero data.
  ENTRY_COUNT=30000
  SCENARIO="manifest-limit"
else
  fail "usage: $0 --entries N | --manifest-limit"
fi

TEMP_DIRECTORY="$(/usr/bin/mktemp -d /tmp/kinlogue-export-writer-probe.XXXXXX)" \
  || fail "could not create the owned temporary directory"
[[ -d "$TEMP_DIRECTORY" && ! -L "$TEMP_DIRECTORY" ]] \
  || fail "the owned temporary directory is invalid"

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
  --product KinlogueExportWriterProbe >&2
BIN_DIRECTORY="$(swift build "${SWIFT_ARGUMENTS[@]}" --show-bin-path)"
PROBE_EXECUTABLE="$BIN_DIRECTORY/KinlogueExportWriterProbe"
[[ -x "$PROBE_EXECUTABLE" && ! -L "$PROBE_EXECUTABLE" ]] \
  || fail "the probe executable is unavailable"

"$PROBE_EXECUTABLE" \
  --entries "$ENTRY_COUNT" \
  --scenario "$SCENARIO" \
  --working-directory "$TEMP_DIRECTORY"
