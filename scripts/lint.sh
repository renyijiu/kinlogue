#!/bin/zsh
set -euo pipefail

umask 077

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
XCODE_DEVELOPER_DIR_INPUT="/Applications/Xcode.app/Contents/Developer"
SOURCE_LIST=""
MANIFEST_JSON=""

fail() {
  echo "Lint failed: $1" >&2
  exit 1
}

cleanup() {
  if [[ -n "${SOURCE_LIST:-}" && -f "$SOURCE_LIST" && ! -L "$SOURCE_LIST" \
      && "${SOURCE_LIST:h}" == /private/tmp \
      && "${SOURCE_LIST:t}" == kinlogue-lint-sources.* ]]; then
    /bin/rm -f -- "$SOURCE_LIST"
  fi
  if [[ -n "${MANIFEST_JSON:-}" && -f "$MANIFEST_JSON" && ! -L "$MANIFEST_JSON" \
      && "${MANIFEST_JSON:h}" == /private/tmp \
      && "${MANIFEST_JSON:t}" == kinlogue-lint-manifest.* ]]; then
    /bin/rm -f -- "$MANIFEST_JSON"
  fi
}
trap cleanup EXIT INT TERM HUP

/bin/zsh "$REPO_DIR/scripts/verify-docs.sh"

[[ -d "$XCODE_DEVELOPER_DIR_INPUT" && ! -L "$XCODE_DEVELOPER_DIR_INPUT" ]] \
  || fail "the full Xcode developer directory is unavailable"
XCODE_DEVELOPER_DIR="$(cd "$XCODE_DEVELOPER_DIR_INPUT" && /bin/pwd -P)"
XCODE_TOOLCHAIN_BIN="$XCODE_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"
SWIFT_EXECUTABLE="$XCODE_TOOLCHAIN_BIN/swift"
export PATH="$XCODE_TOOLCHAIN_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
[[ -x "$SWIFT_EXECUTABLE" ]] || fail "the selected Swift compiler is unavailable"

SOURCE_LIST="$(/usr/bin/mktemp /private/tmp/kinlogue-lint-sources.XXXXXX)" \
  || fail "the source list could not be created"
/usr/bin/find "$REPO_DIR/Sources" "$REPO_DIR/Tests" \
  -type f -name '*.swift' -print0 >"$SOURCE_LIST" \
  || fail "Swift source discovery failed"
/usr/bin/printf '%s\0' "$REPO_DIR/Package.swift" >>"$SOURCE_LIST"

while IFS= read -r -d '' source_file; do
  [[ -f "$source_file" && ! -L "$source_file" ]] \
    || fail "a Swift source is missing or linked: $source_file"
  hygiene_issue=""
  if ! hygiene_issue="$(LC_ALL=C /usr/bin/perl -ne '
      $trailing ||= /[[:blank:]]+$/;
      $tab ||= /\t/;
      $crlf ||= /\r/;
      END {
        if ($trailing) { print "trailing whitespace"; exit 1 }
        if ($tab) { print "tab indentation or tab characters"; exit 1 }
        if ($crlf) { print "CRLF line endings"; exit 1 }
      }
    ' -- "$source_file")"; then
    fail "$hygiene_issue found in ${source_file#$REPO_DIR/}"
  fi
done <"$SOURCE_LIST"

BUILD_ROOT="$REPO_DIR/.build/lint"
/bin/mkdir -p \
  "$BUILD_ROOT/cache" \
  "$BUILD_ROOT/config" \
  "$BUILD_ROOT/security" \
  "$BUILD_ROOT/module-cache/clang" \
  "$BUILD_ROOT/module-cache/swiftpm"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/module-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/module-cache/swiftpm"

cd "$REPO_DIR"
"$SWIFT_EXECUTABLE" build \
  --disable-sandbox \
  --cache-path "$BUILD_ROOT/cache" \
  --config-path "$BUILD_ROOT/config" \
  --security-path "$BUILD_ROOT/security" \
  --manifest-cache local \
  --only-use-versions-from-resolved-file \
  -Xswiftc -warnings-as-errors

MANIFEST_JSON="$(/usr/bin/mktemp /private/tmp/kinlogue-lint-manifest.XXXXXX)" \
  || fail "the package manifest output could not be created"
"$SWIFT_EXECUTABLE" package \
  --disable-sandbox \
  --cache-path "$BUILD_ROOT/cache" \
  --config-path "$BUILD_ROOT/config" \
  --security-path "$BUILD_ROOT/security" \
  --manifest-cache local \
  dump-package >"$MANIFEST_JSON" \
  || fail "SwiftPM could not dump the package graph"
/bin/zsh "$REPO_DIR/scripts/verify-package-graph.sh" "$MANIFEST_JSON"

echo "Lint passed"
