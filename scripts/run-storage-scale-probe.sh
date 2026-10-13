#!/bin/zsh
set -euo pipefail

umask 077

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
BUILD_ROOT="$REPO_DIR/.build/storage-scale-probe"
WORK_PREFIX="kinlogue-storage-scale-probe."
WORK_PARENT="/tmp"
WORK_DIRECTORY=""
PROBE_TIMEOUT_SECONDS=3600
STARTUP_RUNS=3
SELECTED_TIERS=()
RUN_INBOX=false
# Publication latency grows with the queue, so filling to the 5,000-item limit
# takes well over an hour. The default stops at half; pass 4990 to go further.
INBOX_CHECKPOINTS="0,100,1000,2500"

# Report tiers are named by the number of stored objects they stand for: one
# single-page report is one original plus one OCR document. `photos` uses a
# 1 MiB original instead of 64 KiB. `capacity-20000` is a self-contained run
# that stages 20,000 unique originals and then backs the library up and
# restores it.
typeset -A TIER_ARGUMENTS=(
  reports-100 "--reports 50"
  reports-1000 "--reports 500"
  reports-5000 "--reports 2500"
  reports-20000 "--reports 9990"
  photos-20000 "--reports 9990 --attachment-bytes 1048576"
  capacity-20000 "--reports 20000"
)
TIER_ORDER=(
  reports-100 reports-1000 reports-5000 reports-20000
  photos-20000 capacity-20000
)
# With --inbox, these tiers also measure uploads into a large library.
INBOX_COUPLING_TIERS=(reports-20000)
# Byte-capacity tiers omit the query and mutation repetitions.
BYTE_ONLY_TIERS=(photos-20000)

fail() {
  print -u2 -- "Storage scale probe failed: $1"
  exit 1
}

remove_work_directory() {
  [[ -n "${WORK_DIRECTORY:-}" ]] || return 0
  if [[ "${WORK_DIRECTORY:t}" == ${WORK_PREFIX}* \
      && -d "$WORK_DIRECTORY" && ! -L "$WORK_DIRECTORY" ]]; then
    /usr/bin/find -P -x "$WORK_DIRECTORY" -depth -mindepth 1 -delete \
      >/dev/null 2>&1 || return 1
    /bin/rmdir -- "$WORK_DIRECTORY" >/dev/null 2>&1 || return 1
    WORK_DIRECTORY=""
    return 0
  fi
  return 1
}

cleanup() {
  local original_status=$?
  trap - EXIT
  if ! remove_work_directory; then
    print -u2 -- "Storage scale probe cleanup failed"
    [[ "$original_status" -ne 0 ]] || original_status=1
  fi
  exit "$original_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

usage="usage: $0 [--tier NAME]... [--all] [--inbox] [--inbox-checkpoints LIST] [--work-parent DIR]"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --tier)
      [[ "$#" -ge 2 && -n "${TIER_ARGUMENTS[$2]:-}" ]] || fail "$usage"
      SELECTED_TIERS+=("$2")
      shift 2
      ;;
    --all)
      SELECTED_TIERS=("${TIER_ORDER[@]}")
      RUN_INBOX=true
      shift
      ;;
    --inbox)
      RUN_INBOX=true
      shift
      ;;
    --inbox-checkpoints)
      [[ "$#" -ge 2 && "$2" =~ '^[0-9]+(,[0-9]+)*$' ]] || fail "$usage"
      INBOX_CHECKPOINTS="$2"
      RUN_INBOX=true
      shift 2
      ;;
    --work-parent)
      [[ "$#" -ge 2 && "$2" == /* ]] || fail "$usage"
      WORK_PARENT="$2"
      shift 2
      ;;
    *)
      fail "$usage"
      ;;
  esac
done
[[ "${#SELECTED_TIERS[@]}" -gt 0 || "$RUN_INBOX" == true ]] || fail "$usage"
[[ -d "$WORK_PARENT" && -O "$WORK_PARENT" || "$WORK_PARENT" == "/tmp" ]] \
  || fail "the work parent must be a directory owned by the current user"

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
  || fail "the probe executable is unavailable"

make_work_directory() {
  WORK_DIRECTORY="$(/usr/bin/mktemp -d "$WORK_PARENT/${WORK_PREFIX}XXXXXX")" \
    || fail "could not create the owned work directory"
  [[ -d "$WORK_DIRECTORY" && ! -L "$WORK_DIRECTORY" ]] \
    || fail "the owned work directory is invalid"
  WORK_DIRECTORY="$(cd "$WORK_DIRECTORY" && pwd -P)"
}

# Prints one result line. Exit status 75 means the probe declined the tier
# because the volume lacks the required free space.
probe() {
  local label="$1"
  shift
  local output=""
  local probe_status=0
  output="$("$REPO_DIR/scripts/run-with-deadline.sh" "$PROBE_TIMEOUT_SECONDS" \
    "$PROBE_EXECUTABLE" --storage-scale "$@" \
    --work-directory "$WORK_DIRECTORY")" || probe_status=$?
  if [[ "$probe_status" -eq 75 ]]; then
    print -r -- "KLS_STORAGE_SCALE $label skipped=insufficientDiskSpace"
    return 75
  fi
  [[ "$probe_status" -eq 0 && -n "$output" ]] || fail "$label exited with $probe_status"
  print -r -- "KLS_STORAGE_SCALE $label $output"
}

print -r -- "KLS_STORAGE_SCALE environment model=$(/usr/sbin/sysctl -n hw.model)" \
  "cpu=\"$(/usr/sbin/sysctl -n machdep.cpu.brand_string)\"" \
  "memory_bytes=$(/usr/sbin/sysctl -n hw.memsize)" \
  "os=$(/usr/bin/sw_vers -productVersion)" \
  "build=$(/usr/bin/sw_vers -buildVersion)" \
  "configuration=release" \
  "swift=\"$(swift --version 2>&1 | /usr/bin/head -1)\"" \
  "available_kib=$(/bin/df -k "$WORK_PARENT" | /usr/bin/awk 'NR == 2 { print $4 }')"

for tier in "${SELECTED_TIERS[@]}"; do
  make_work_directory
  if [[ "$tier" == capacity-20000 ]]; then
    probe "tier=$tier phase=capacity" logical-capacity ${=TIER_ARGUMENTS[$tier]} || true
  elif probe "tier=$tier phase=generate" logical-generate ${=TIER_ARGUMENTS[$tier]}; then
    for run in {1..$STARTUP_RUNS}; do
      probe "tier=$tier phase=startup run=$run" logical-startup ${=TIER_ARGUMENTS[$tier]}
    done
    if (( ! ${BYTE_ONLY_TIERS[(Ie)$tier]} )); then
      probe "tier=$tier phase=queries" logical-queries
      probe "tier=$tier phase=operations" logical-operations
    fi
    probe "tier=$tier phase=capture" logical-capture
    probe "tier=$tier phase=backup" logical-backup
    if [[ "$RUN_INBOX" == true ]] && (( ${INBOX_COUPLING_TIERS[(Ie)$tier]} )); then
      probe "tier=$tier phase=inbox" logical-inbox --inbox-checkpoints 0,100
    fi
  fi
  remove_work_directory || fail "could not remove the owned work directory"
done

if [[ "$RUN_INBOX" == true ]]; then
  make_work_directory
  probe "tier=empty-library phase=inbox" logical-inbox --inbox-checkpoints "$INBOX_CHECKPOINTS" || true
  remove_work_directory || fail "could not remove the owned work directory"
fi
