#!/bin/zsh
set -euo pipefail

# Builds the assistant bridge XPC bundle from a compiled bridge executable and signs it with the
# given entitlements. build-app.sh and verify-assistant-xpc.sh both use this, so the bundle layout
# and signing exist in one place.

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
BUNDLE_NAME="KinlogueAssistantBridge.xpc"
EXECUTABLE_NAME="KinlogueAssistantBridge"
INFO_SOURCE="$REPO_DIR/packaging/KinlogueAssistantBridge-Info.plist"

fail() {
  echo "Assistant bridge assembly failed: $1" >&2
  exit 1
}

[[ "$#" -eq 3 ]] \
  || fail "usage: assemble-assistant-bridge.sh <bridge executable> <destination .xpc> <entitlements>"
EXECUTABLE="$1"
DESTINATION="$2"
ENTITLEMENTS="$3"

[[ -f "$EXECUTABLE" && ! -L "$EXECUTABLE" && -x "$EXECUTABLE" ]] \
  || fail "the bridge executable is missing, linked or not executable"
[[ -f "$ENTITLEMENTS" && ! -L "$ENTITLEMENTS" ]] \
  || fail "the entitlements file is missing or linked"
[[ -f "$INFO_SOURCE" && ! -L "$INFO_SOURCE" ]] \
  || fail "the bridge Info.plist is missing or linked"
[[ "$DESTINATION" == /* && "${DESTINATION:t}" == "$BUNDLE_NAME" ]] \
  || fail "the destination must be an absolute path ending in $BUNDLE_NAME"
[[ -d "${DESTINATION:h}" && ! -L "${DESTINATION:h}" ]] \
  || fail "the destination folder must be an existing real directory"
[[ ! -e "$DESTINATION" && ! -L "$DESTINATION" ]] \
  || fail "the destination already exists"

/bin/mkdir -p "$DESTINATION/Contents/MacOS"
/bin/cp -- "$INFO_SOURCE" "$DESTINATION/Contents/Info.plist"
/bin/cp -- "$EXECUTABLE" "$DESTINATION/Contents/MacOS/$EXECUTABLE_NAME"
/bin/chmod 755 "$DESTINATION/Contents/MacOS/$EXECUTABLE_NAME"
[[ -z "$(/usr/bin/find "$DESTINATION" -type l -print -quit)" ]] \
  || fail "symbolic links are not allowed in the bridge bundle"
/usr/bin/codesign --force --sign - --entitlements "$ENTITLEMENTS" "$DESTINATION"
/usr/bin/codesign --verify --strict "$DESTINATION"
