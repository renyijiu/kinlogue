#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
XCODE_TOOLCHAIN_BIN="$XCODE_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"
XCODE_MACOS_PLATFORM_DIR="$XCODE_DEVELOPER_DIR/Platforms/MacOSX.platform/Developer"
XCODE_SDK_DIR="$XCODE_MACOS_PLATFORM_DIR/SDKs/MacOSX.sdk"
BUILD_CACHE_DIR="$REPO_DIR/.build/module-cache"
SWIFTPM_CACHE_DIR="$REPO_DIR/.build/swiftpm-cache"
SWIFTPM_CONFIG_DIR="$REPO_DIR/.build/swiftpm-config"
SWIFTPM_SECURITY_DIR="$REPO_DIR/.build/swiftpm-security"
TESTING_FRAMEWORKS_DIR="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
TESTING_LIBRARIES_DIR="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

# Prefer one coherent full-Xcode compiler, SDK, and Swift Testing runtime. The
# system Command Line Tools can temporarily be on a different patch level.
if [[ -x "$XCODE_TOOLCHAIN_BIN/swift" \
      && -d "$XCODE_SDK_DIR" \
      && -d "$XCODE_MACOS_PLATFORM_DIR/Library/Frameworks" \
      && -f "$XCODE_MACOS_PLATFORM_DIR/usr/lib/lib_TestingInterop.dylib" ]]; then
  export PATH="$XCODE_TOOLCHAIN_BIN:$PATH"
  export SDKROOT="$XCODE_SDK_DIR"
  TESTING_FRAMEWORKS_DIR="$XCODE_MACOS_PLATFORM_DIR/Library/Frameworks"
  TESTING_LIBRARIES_DIR="$XCODE_MACOS_PLATFORM_DIR/usr/lib"
fi

mkdir -p \
  "$BUILD_CACHE_DIR/clang" \
  "$BUILD_CACHE_DIR/swiftpm" \
  "$SWIFTPM_CACHE_DIR" \
  "$SWIFTPM_CONFIG_DIR" \
  "$SWIFTPM_SECURITY_DIR"

export CLANG_MODULE_CACHE_PATH="$BUILD_CACHE_DIR/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_CACHE_DIR/swiftpm"

# Swift Testing schedules test cases independently of SwiftPM build jobs.
# Bound its otherwise effectively unlimited default so wall-clock assertions
# measure product behavior rather than executor starvation.
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-8}"
if [[ ! "$SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH" =~ '^[0-9]+$' ]] \
    || [[ "$SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH" -lt 1 \
      || "$SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH" -gt 64 ]]; then
  print -u2 "SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH must be an integer from 1 through 64"
  exit 64
fi
export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH

KINLOGUE_PRIMARY_TEST_TIMEOUT_SECONDS="${KINLOGUE_PRIMARY_TEST_TIMEOUT_SECONDS:-1800}"
KINLOGUE_ISOLATED_TEST_TIMEOUT_SECONDS="${KINLOGUE_ISOLATED_TEST_TIMEOUT_SECONDS:-300}"
for timeout_value in \
    "$KINLOGUE_PRIMARY_TEST_TIMEOUT_SECONDS" \
    "$KINLOGUE_ISOLATED_TEST_TIMEOUT_SECONDS"; do
  if [[ ! "$timeout_value" =~ '^[0-9]+$' ]] \
      || [[ "$timeout_value" -lt 60 || "$timeout_value" -gt 3600 ]]; then
    print -u2 "test deadlines must be integers from 60 through 3600 seconds"
    exit 64
  fi
done

cd "$REPO_DIR"

"$REPO_DIR/scripts/compile-localizations.sh" --check

SWIFT_TEST_ARGUMENTS=(
  --disable-sandbox
  --cache-path "$SWIFTPM_CACHE_DIR"
  --config-path "$SWIFTPM_CONFIG_DIR"
  --security-path "$SWIFTPM_SECURITY_DIR"
  --manifest-cache local
)

# Swift Testing lives outside the compiler's default framework and runtime
# search paths. Both paths above always come from the selected installation.
if [[ -d "$TESTING_FRAMEWORKS_DIR" && -f "$TESTING_LIBRARIES_DIR/lib_TestingInterop.dylib" ]]; then
  SWIFT_TEST_ARGUMENTS+=(
    -Xswiftc -F
    -Xswiftc "$TESTING_FRAMEWORKS_DIR"
    -Xlinker -F
    -Xlinker "$TESTING_FRAMEWORKS_DIR"
    -Xlinker -rpath
    -Xlinker "$TESTING_FRAMEWORKS_DIR"
    -Xlinker -rpath
    -Xlinker "$TESTING_LIBRARIES_DIR"
  )
fi

RUN_ISOLATED_RSS=true
for argument in "$@"; do
  if [[ "$argument" == "--filter" || "$argument" == --filter=* ]]; then
    RUN_ISOLATED_RSS=false
    break
  fi
done

PRIMARY_TEST_ARGUMENTS=("$@")
if [[ "$RUN_ISOLATED_RSS" == true ]]; then
  PRIMARY_TEST_ARGUMENTS+=(
    --skip productionFileQueueStaysBoundedWithTwoStreamsSlowPeersAndDisconnect
  )
fi

PRIMARY_TEST_LOG="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/kinlogue-primary-tests.XXXXXX")"
/bin/chmod 600 "$PRIMARY_TEST_LOG"
trap '/bin/rm -f "$PRIMARY_TEST_LOG"' EXIT HUP INT TERM

"$REPO_DIR/scripts/run-with-deadline.sh" \
  "$KINLOGUE_PRIMARY_TEST_TIMEOUT_SECONDS" \
  swift test "${SWIFT_TEST_ARGUMENTS[@]}" "${PRIMARY_TEST_ARGUMENTS[@]}" \
  2>&1 | /usr/bin/tee "$PRIMARY_TEST_LOG"

if [[ "$RUN_ISOLATED_RSS" == true ]]; then
  KINLOGUE_REQUIRE_TEST_EVIDENCE=1 \
    KINLOGUE_TEST_RESULT_FILE="$PRIMARY_TEST_LOG" \
    "$REPO_DIR/scripts/verify-docs.sh"
  KINLOGUE_ENFORCE_ISOLATED_LAN_RSS=1 \
  SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 \
    "$REPO_DIR/scripts/run-with-deadline.sh" \
      "$KINLOGUE_ISOLATED_TEST_TIMEOUT_SECONDS" \
      swift test "${SWIFT_TEST_ARGUMENTS[@]}" \
      --filter productionFileQueueStaysBoundedWithTwoStreamsSlowPeersAndDisconnect \
      -j 1
fi
