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

# Keep test execution serial because multiple suites coordinate real child
# processes. Build jobs remain bounded independently on smaller CI hosts.
KINLOGUE_BUILD_JOBS="${KINLOGUE_BUILD_JOBS:-4}"
if [[ ! "$KINLOGUE_BUILD_JOBS" =~ '^[0-9]+$' ]] \
    || [[ "$KINLOGUE_BUILD_JOBS" -lt 1 \
      || "$KINLOGUE_BUILD_JOBS" -gt 16 ]]; then
  print -u2 "KINLOGUE_BUILD_JOBS must be an integer from 1 through 16"
  exit 64
fi

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
SHARD_SUPERVISOR_TIMEOUT_SECONDS=$((KINLOGUE_ISOLATED_TEST_TIMEOUT_SECONDS - 5))

KINLOGUE_PRIMARY_TEST_PARTITION="${KINLOGUE_PRIMARY_TEST_PARTITION:-0/1}"
if [[ ! "$KINLOGUE_PRIMARY_TEST_PARTITION" =~ '^[0-9]+/[1-9][0-9]*$' ]]; then
  print -u2 "KINLOGUE_PRIMARY_TEST_PARTITION must use index/count integers"
  exit 64
fi
PRIMARY_PARTITION_INDEX="${KINLOGUE_PRIMARY_TEST_PARTITION%%/*}"
PRIMARY_PARTITION_COUNT="${KINLOGUE_PRIMARY_TEST_PARTITION#*/}"
if [[ "$PRIMARY_PARTITION_COUNT" -gt 16 \
      || "$PRIMARY_PARTITION_INDEX" -ge "$PRIMARY_PARTITION_COUNT" ]]; then
  print -u2 "KINLOGUE_PRIMARY_TEST_PARTITION must select one of at most sixteen runners"
  exit 64
fi

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

RUN_ISOLATED_GATES=true
for argument in "$@"; do
  if [[ "$argument" == "--filter" || "$argument" == --filter=* ]]; then
    RUN_ISOLATED_GATES=false
    break
  fi
done

# The final remote partition is intentionally one fixed, expensive LAN suite.
# SwiftPM only builds its XCTest bundle: hosted macOS 26 has stalled after a
# successful cold build in SwiftPM's runners and while directly running the
# whole XCTest class. Launch every fixed case in its own bounded process so a
# loader or behavioral stall is isolated to one named, content-free selector.
if [[ "$RUN_ISOLATED_GATES" == true \
      && ("$PRIMARY_PARTITION_COUNT" -eq 1 \
        || "$PRIMARY_PARTITION_INDEX" -eq $((PRIMARY_PARTITION_COUNT - 1))) ]]; then
  XCTEST_BIN_DIR="$(
    "$REPO_DIR/scripts/run-with-deadline.sh" \
      "$KINLOGUE_PRIMARY_TEST_TIMEOUT_SECONDS" \
      swift build "${SWIFT_TEST_ARGUMENTS[@]}" \
        --disable-swift-testing --enable-xctest \
        --show-bin-path
  )"
  XCTEST_BUNDLE="$XCTEST_BIN_DIR/KinloguePackageTests.xctest"
  "$REPO_DIR/scripts/run-with-deadline.sh" \
    "$KINLOGUE_PRIMARY_TEST_TIMEOUT_SECONDS" \
    swift build "${SWIFT_TEST_ARGUMENTS[@]}" \
      --build-tests \
      --disable-swift-testing --enable-xctest \
      -j "$KINLOGUE_BUILD_JOBS"
  if [[ ! -d "$XCTEST_BUNDLE" ]]; then
    print -u2 "dedicated XCTest bundle was not produced at the expected path"
    exit 70
  fi
  DERIVED_XCTEST_LOG="$(
    /usr/bin/mktemp "${TMPDIR:-/tmp}/kinlogue-derived-xctest.XXXXXX"
  )"
  /bin/chmod 600 "$DERIVED_XCTEST_LOG"
  trap '/bin/rm -f "$DERIVED_XCTEST_LOG"' EXIT HUP INT TERM
  DERIVED_XCTEST_CASES=(
    KinloguePlatformTests.LANDerivedArtifactSinkTests/testProductionAdmissionUsesTheDocumentedStoreAndOwnerBounds
    KinloguePlatformTests.LANDerivedArtifactSinkTests/testProductionStoreBudgetIsReservedBeforeAnyDerivedActorHop
    KinloguePlatformTests.LANDerivedArtifactSinkTests/testEmptyDataAndBuffersDoNotConsumeDerivedTurnsAndCloseWithFinish
    KinloguePlatformTests.LANDerivedArtifactSinkTests/testSharedAdmissionAppliesTotalLimitsAcrossOwners
    KinloguePlatformTests.LANDerivedArtifactSinkTests/testStreamsMultipleChunkKindsAndSyncsBeforeOneReplayableFinalize
    KinloguePlatformTests.LANDerivedArtifactSinkTests/testConcurrentFinishesJoinAndAbortCannotRunBesideFinalization
    KinloguePlatformTests.LANDerivedArtifactSinkTests/testConcurrentAbortsJoinOneDescriptorBoundCallbackAndRejectFinishAndWrite
    KinloguePlatformTests.LANDerivedArtifactSinkTests/testWriteFailureAndRacingTerminalCallsStillAbortExactlyOnce
    KinloguePlatformTests.LANDerivedArtifactSinkTests/testThirdPendingChunkIsRejectedBeforeCopyAndDrainsExactlyOnce
    KinloguePlatformTests.LANDerivedArtifactSinkTests/testTinyChunksCannotExceedConfiguredHighWaterMark
    KinloguePlatformTests.LANDerivedArtifactSinkTests/testByteBufferRetainedCapacityIsRejectedWithoutEnteringIO
    KinloguePlatformTests.LANDerivedArtifactSinkTests/testAbortRacingQueuedFinishDrainsPermitAndOwnsTerminalTransition
    KinloguePlatformTests.LANDerivedArtifactSinkTests/testRejectsNonPrivateOrHardLinkedDescriptorsAtOwnershipTransfer
  )
  for derived_xctest_case in "${DERIVED_XCTEST_CASES[@]}"; do
    print "KLT_DERIVED_XCTEST_CASE selector=$derived_xctest_case"
    : > "$DERIVED_XCTEST_LOG"
    "$REPO_DIR/scripts/run-with-deadline.sh" \
      "$KINLOGUE_ISOLATED_TEST_TIMEOUT_SECONDS" \
      /usr/bin/xcrun xctest \
        -XCTest "$derived_xctest_case" \
        "$XCTEST_BUNDLE" \
      2>&1 | /usr/bin/tee "$DERIVED_XCTEST_LOG"
    if ! /usr/bin/grep -Fq \
        "Executed 1 test, with 0 failures (0 unexpected)" \
        "$DERIVED_XCTEST_LOG"; then
      print -u2 "dedicated XCTest case did not emit its exact passing summary"
      exit 70
    fi
  done
  print "KLT_DERIVED_XCTEST_SUMMARY tests=13 failures=0"
  /bin/rm -f "$DERIVED_XCTEST_LOG"
  trap - EXIT HUP INT TERM
  "$REPO_DIR/scripts/verify-docs.sh"
  if [[ "$PRIMARY_PARTITION_COUNT" -gt 1 ]]; then
    exit 0
  fi
fi

PRIMARY_TEST_LOG="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/kinlogue-primary-tests.XXXXXX")"
PRIMARY_TEST_LIST="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/kinlogue-test-list.XXXXXX")"
PRIMARY_TEST_SHARDS="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/kinlogue-test-shards.XXXXXX")"
/bin/chmod 600 "$PRIMARY_TEST_LOG"
/bin/chmod 600 "$PRIMARY_TEST_LIST" "$PRIMARY_TEST_SHARDS"
trap '/bin/rm -f "$PRIMARY_TEST_LOG" "$PRIMARY_TEST_LIST" "$PRIMARY_TEST_SHARDS"' \
  EXIT HUP INT TERM

if [[ "$RUN_ISOLATED_GATES" == true ]]; then
  # Build once, then derive exact non-overlapping Platform/App shards from the
  # executable test inventory. The planner fails closed for unknown targets,
  # missing isolated gates, omissions, and duplicate matches.
  "$REPO_DIR/scripts/run-with-deadline.sh" \
    "$KINLOGUE_PRIMARY_TEST_TIMEOUT_SECONDS" \
    swift test "${SWIFT_TEST_ARGUMENTS[@]}" \
      -j "$KINLOGUE_BUILD_JOBS" \
      list > "$PRIMARY_TEST_LIST"
  /usr/bin/ruby "$REPO_DIR/scripts/primary-test-shards.rb" \
    "$PRIMARY_TEST_LIST" \
    "$PRIMARY_PARTITION_INDEX" \
    "$PRIMARY_PARTITION_COUNT" > "$PRIMARY_TEST_SHARDS"

  if [[ "$PRIMARY_PARTITION_INDEX" -eq 0 ]]; then
    # The acceptance scanner starts many short-lived synthetic subprocesses.
    # Run it before primary/storage helper churn on constrained CI runners.
    "$REPO_DIR/scripts/run-with-deadline.sh" \
      "$KINLOGUE_ISOLATED_TEST_TIMEOUT_SECONDS" \
      swift test "${SWIFT_TEST_ARGUMENTS[@]}" \
      --skip-build --no-parallel \
      --filter AcceptanceScanScriptTests \
      -j 1
    "$REPO_DIR/scripts/run-with-deadline.sh" \
      "$KINLOGUE_PRIMARY_TEST_TIMEOUT_SECONDS" \
      swift test "${SWIFT_TEST_ARGUMENTS[@]}" \
        --skip-build --no-parallel -j "$KINLOGUE_BUILD_JOBS" \
        --filter KinlogueCoreTests \
        "$@" \
      2>&1 | /usr/bin/tee -a "$PRIMARY_TEST_LOG"
  fi

  while IFS=$'\t' read -r expected_test_count expected_suite_count shard_pattern; do
    [[ "$expected_test_count" =~ '^[1-9][0-9]*$' \
        && "$expected_suite_count" =~ '^[0-9]+$' \
        && -n "$shard_pattern" ]] || {
      print -u2 "primary test shard planner emitted an invalid record"
      exit 70
    }
    KINLOGUE_TEST_SUMMARY_MAX_SECONDS="$SHARD_SUPERVISOR_TIMEOUT_SECONDS" \
      "$REPO_DIR/scripts/run-with-deadline.sh" \
        "$KINLOGUE_ISOLATED_TEST_TIMEOUT_SECONDS" \
        "$REPO_DIR/scripts/run-test-shard.rb" \
        "$expected_test_count" "$expected_suite_count" \
        swift test "${SWIFT_TEST_ARGUMENTS[@]}" \
          --skip-build --no-parallel -j "$KINLOGUE_BUILD_JOBS" \
          --filter "$shard_pattern" \
          --skip DICOMImportWorkflowIntegrationTests \
          --skip AcceptanceScanScriptTests \
          --skip installedLANProbeUsesProductionHTTPAndPersistsAcrossProcessPhases \
          --skip productionFileQueueStaysBoundedWithTwoStreamsSlowPeersAndDisconnect \
          "$@" \
      2>&1 | /usr/bin/tee -a "$PRIMARY_TEST_LOG"
  done < "$PRIMARY_TEST_SHARDS"
else
  "$REPO_DIR/scripts/run-with-deadline.sh" \
    "$KINLOGUE_PRIMARY_TEST_TIMEOUT_SECONDS" \
    swift test "${SWIFT_TEST_ARGUMENTS[@]}" \
      --no-parallel -j "$KINLOGUE_BUILD_JOBS" \
      "$@" \
    2>&1 | /usr/bin/tee -a "$PRIMARY_TEST_LOG"
fi

if [[ "$RUN_ISOLATED_GATES" == true ]]; then
  if [[ "$PRIMARY_PARTITION_COUNT" -eq 1 ]]; then
    KINLOGUE_REQUIRE_TEST_EVIDENCE=1 \
      KINLOGUE_TEST_RESULT_FILE="$PRIMARY_TEST_LOG" \
      "$REPO_DIR/scripts/verify-docs.sh"
  else
    "$REPO_DIR/scripts/verify-docs.sh"
  fi
fi

if [[ "$RUN_ISOLATED_GATES" == true && "$PRIMARY_PARTITION_INDEX" -eq 0 ]]; then
  "$REPO_DIR/scripts/run-with-deadline.sh" \
    "$KINLOGUE_ISOLATED_TEST_TIMEOUT_SECONDS" \
    swift test "${SWIFT_TEST_ARGUMENTS[@]}" \
    --no-parallel \
    --filter KinlogueStorageProcessTests \
    -j 1
  "$REPO_DIR/scripts/run-with-deadline.sh" \
    "$KINLOGUE_ISOLATED_TEST_TIMEOUT_SECONDS" \
    swift test "${SWIFT_TEST_ARGUMENTS[@]}" \
    --no-parallel \
    --filter differentlyCasedVaultAliasesShareStableAndLegacyLockIdentity \
    -j 1
  "$REPO_DIR/scripts/run-with-deadline.sh" \
    "$KINLOGUE_ISOLATED_TEST_TIMEOUT_SECONDS" \
    swift test "${SWIFT_TEST_ARGUMENTS[@]}" \
    --no-parallel \
    --filter DICOMImportWorkflowIntegrationTests \
    -j 1
  "$REPO_DIR/scripts/run-with-deadline.sh" \
    "$KINLOGUE_ISOLATED_TEST_TIMEOUT_SECONDS" \
    swift test "${SWIFT_TEST_ARGUMENTS[@]}" \
    --no-parallel \
    --filter installedLANProbeUsesProductionHTTPAndPersistsAcrossProcessPhases \
    -j 1
  KINLOGUE_ENFORCE_ISOLATED_LAN_RSS=1 \
    "$REPO_DIR/scripts/run-with-deadline.sh" \
      "$KINLOGUE_ISOLATED_TEST_TIMEOUT_SECONDS" \
      swift test "${SWIFT_TEST_ARGUMENTS[@]}" \
      --no-parallel \
      --filter productionFileQueueStaysBoundedWithTwoStreamsSlowPeersAndDisconnect \
      -j 1
fi
