#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
SOURCE_APP="$REPO_DIR/dist/Kinlogue.app"
SOURCE_EXECUTABLE="$SOURCE_APP/Contents/MacOS/Kinlogue"
VERIFICATION_REPORT="$REPO_DIR/dist/verification-report.json"
DEFAULT_OUTPUT_DIRECTORY="$REPO_DIR/dist/acceptance"
OUTPUT_DIRECTORY="$DEFAULT_OUTPUT_DIRECTORY"
ENTITLEMENTS_FILE="$REPO_DIR/packaging/KinlogueAcceptance.entitlements"

fail() {
  echo "Acceptance bundle build failed: $1" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output-directory)
      [[ "$#" -ge 2 ]] || fail "--output-directory requires a path"
      OUTPUT_DIRECTORY="$2"
      shift 2
      ;;
    *)
      fail "usage: build-acceptance-app.sh [--output-directory PATH]"
      ;;
  esac
done

if [[ "$OUTPUT_DIRECTORY" != "$DEFAULT_OUTPUT_DIRECTORY" ]]; then
  [[ "${OUTPUT_DIRECTORY:h}" == "$DEFAULT_OUTPUT_DIRECTORY" ]] \
    || fail "the isolated output directory is outside the acceptance root"
  /usr/bin/printf '%s\n' "${OUTPUT_DIRECTORY:t}" \
    | /usr/bin/grep -Eq '^\.run-build\.[0-9A-Za-z]{8,32}$' \
    || fail "the isolated output directory name is invalid"
  [[ -d "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" ]] \
    || fail "the isolated output directory is unavailable"
  CURRENT_UID="$(/usr/bin/id -u)"
  [[ "$(/usr/bin/stat -f '%u:%Lp' -- "$OUTPUT_DIRECTORY")" \
      == "$CURRENT_UID:700" ]] \
    || fail "the isolated output directory is not private"
fi

bundle_hash() {
  local bundle="$1"
  local manifest="$2"
  (
    cd "$bundle"
    /usr/bin/find . -type f -print \
      | LC_ALL=C /usr/bin/sort \
      | while IFS= read -r relative_path; do
          file_hash="$(/usr/bin/shasum -a 256 -- "$relative_path" | /usr/bin/awk '{print $1}')"
          /usr/bin/printf '%s\t%s\n' "$file_hash" "$relative_path"
        done
  ) >"$manifest"
  /usr/bin/shasum -a 256 -- "$manifest" | /usr/bin/awk '{print $1}'
}

"$REPO_DIR/scripts/verify-app.sh"

[[ -d "$SOURCE_APP" && ! -L "$SOURCE_APP" ]] \
  || fail "the verified release app is unavailable"
[[ -f "$SOURCE_EXECUTABLE" && ! -L "$SOURCE_EXECUTABLE" ]] \
  || fail "the verified release executable is unavailable"
[[ -f "$VERIFICATION_REPORT" && ! -L "$VERIFICATION_REPORT" ]] \
  || fail "the verification report is unavailable"

[[ "$(/usr/bin/plutil -extract gates.bundleVerification raw -expect string "$VERIFICATION_REPORT")" \
  == "passed" ]] \
  || fail "the release verification report is not successful"
[[ "$(/usr/bin/plutil -extract artifact.bundleIdentifier raw -expect string "$VERIFICATION_REPORT")" \
  == "com.kinlogue.mac" ]] \
  || fail "the verification report does not describe the production bundle"
VERIFIED_EXECUTABLE_HASH="$(
  /usr/bin/plutil -extract artifact.executableSHA256 raw -expect string "$VERIFICATION_REPORT"
)"
if ! /usr/bin/printf '%s\n' "$VERIFIED_EXECUTABLE_HASH" \
  | /usr/bin/grep -Eq '^[0-9a-f]{64}$'; then
  fail "the verified executable hash is malformed"
fi
VERIFIED_BUNDLE_HASH="$(
  /usr/bin/plutil -extract artifact.bundleSHA256 raw -expect string "$VERIFICATION_REPORT"
)"
if ! /usr/bin/printf '%s\n' "$VERIFIED_BUNDLE_HASH" \
  | /usr/bin/grep -Eq '^[0-9a-f]{64}$'; then
  fail "the verified bundle hash is malformed"
fi

RUN_ID="$(/usr/bin/uuidgen | /usr/bin/tr -d '-' | /usr/bin/tr '[:upper:]' '[:lower:]')"
if ! /usr/bin/printf '%s\n' "$RUN_ID" \
  | /usr/bin/grep -Eq '^[0-9a-f]{24,32}$'; then
  fail "the generated run identifier is not canonical"
fi

BUNDLE_IDENTIFIER="com.kinlogue.mac.acceptance.$RUN_ID"
TARGET_APP="$OUTPUT_DIRECTORY/Kinlogue-Acceptance-$RUN_ID.app"
TARGET_INFO_PLIST="$TARGET_APP/Contents/Info.plist"
TARGET_EXECUTABLE="$TARGET_APP/Contents/MacOS/Kinlogue"

if [[ -e "$OUTPUT_DIRECTORY" || -L "$OUTPUT_DIRECTORY" ]]; then
  [[ -d "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" ]] \
    || fail "the acceptance output directory is not a real directory"
else
  /bin/mkdir "$OUTPUT_DIRECTORY"
fi

TARGET_CREATED=false
BUILD_SUCCEEDED=false
PROVENANCE_DIRECTORY=""
cleanup() {
  if [[ -n "$PROVENANCE_DIRECTORY" ]]; then
    /bin/rm -rf -- "$PROVENANCE_DIRECTORY"
  fi
  if [[ "$TARGET_CREATED" == true && "$BUILD_SUCCEEDED" != true ]]; then
    /bin/rm -rf -- "$TARGET_APP"
  fi
}
trap cleanup EXIT

if ! /bin/mkdir "$TARGET_APP"; then
  fail "the unique acceptance target already exists; nothing was overwritten"
fi
TARGET_CREATED=true
PROVENANCE_DIRECTORY="$(
  /usr/bin/mktemp -d "$OUTPUT_DIRECTORY/.provenance-$RUN_ID.XXXXXX"
)"
VERIFIED_EXECUTABLE_COPY="$PROVENANCE_DIRECTORY/verified-release-executable"
ACCEPTANCE_EXECUTABLE_COPY="$PROVENANCE_DIRECTORY/acceptance-executable"
ACCEPTANCE_SIGNATURE_METADATA="$PROVENANCE_DIRECTORY/acceptance-signature-metadata.txt"
COPIED_BUNDLE_MANIFEST="$PROVENANCE_DIRECTORY/copied-bundle-manifest.txt"

/usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"
[[ -z "$(/usr/bin/find "$TARGET_APP" -type l -print -quit)" ]] \
  || fail "the copied release bundle contains a symbolic link"
TARGET_DICOM_HELPER="$TARGET_APP/Contents/XPCServices/KinlogueDICOMDecoderHelper.xpc"
[[ -d "$TARGET_DICOM_HELPER" && ! -L "$TARGET_DICOM_HELPER" ]] \
  || fail "the copied release bundle lost its DICOM Helper"
/usr/bin/codesign --verify --strict "$TARGET_DICOM_HELPER" \
  || fail "the copied DICOM Helper no longer has its verified signature"
/usr/bin/codesign --verify --strict "$TARGET_APP" \
  || fail "the copied release bundle no longer has its verified signature"
COPIED_BUNDLE_HASH="$(bundle_hash "$TARGET_APP" "$COPIED_BUNDLE_MANIFEST")"
[[ "$COPIED_BUNDLE_HASH" == "$VERIFIED_BUNDLE_HASH" ]] \
  || fail "the copied release bundle does not match the verification report"
/bin/chmod 755 "$TARGET_EXECUTABLE"

SOURCE_EXECUTABLE_HASH="$(/usr/bin/shasum -a 256 -- "$SOURCE_EXECUTABLE" | /usr/bin/awk '{print $1}')"
COPIED_EXECUTABLE_HASH="$(/usr/bin/shasum -a 256 -- "$TARGET_EXECUTABLE" | /usr/bin/awk '{print $1}')"
[[ "$SOURCE_EXECUTABLE_HASH" == "$VERIFIED_EXECUTABLE_HASH" ]] \
  || fail "the release executable changed after verification"
[[ "$COPIED_EXECUTABLE_HASH" == "$VERIFIED_EXECUTABLE_HASH" ]] \
  || fail "the copied executable does not match the verification report"
/bin/cp -p "$TARGET_EXECUTABLE" "$VERIFIED_EXECUTABLE_COPY"

/usr/bin/plutil -replace CFBundleIdentifier -string "$BUNDLE_IDENTIFIER" "$TARGET_INFO_PLIST"
/usr/bin/plutil -replace CFBundleDisplayName -string "续页 验收" "$TARGET_INFO_PLIST"
/usr/bin/plutil -insert KinlogueAcceptanceEnabled -bool true "$TARGET_INFO_PLIST"
/usr/bin/plutil -insert KinlogueAcceptanceRunID -string "$RUN_ID" "$TARGET_INFO_PLIST"
/usr/bin/plutil -lint "$TARGET_INFO_PLIST" >/dev/null

/usr/bin/codesign --force --sign - \
  --entitlements "$ENTITLEMENTS_FILE" \
  "$TARGET_APP"
/usr/bin/codesign --verify --strict "$TARGET_DICOM_HELPER"
/usr/bin/codesign --verify --strict "$TARGET_APP"
/usr/bin/codesign -d --verbose=4 "$TARGET_APP" \
  >/dev/null 2>"$ACCEPTANCE_SIGNATURE_METADATA"
SIGNED_IDENTIFIER="$(
  /usr/bin/awk -F= '$1 == "Identifier" { sub(/^[^=]*=/, ""); print; exit }' \
    "$ACCEPTANCE_SIGNATURE_METADATA"
)"
SIGNATURE_KIND="$(
  /usr/bin/awk -F= '$1 == "Signature" { sub(/^[^=]*=/, ""); print; exit }' \
    "$ACCEPTANCE_SIGNATURE_METADATA"
)"
TEAM_IDENTIFIER="$(
  /usr/bin/awk -F= '$1 == "TeamIdentifier" { sub(/^[^=]*=/, ""); print; exit }' \
    "$ACCEPTANCE_SIGNATURE_METADATA"
)"
[[ "$SIGNED_IDENTIFIER" == "$BUNDLE_IDENTIFIER" ]] \
  || fail "the signed acceptance identifier does not match Info.plist"
[[ "$SIGNATURE_KIND" == "adhoc" && "$TEAM_IDENTIFIER" == "not set" ]] \
  || fail "the acceptance artifact must be ad-hoc signed without a team"
if /usr/bin/grep -q '^Authority=' "$ACCEPTANCE_SIGNATURE_METADATA"; then
  fail "the acceptance artifact unexpectedly contains a signing authority"
fi

/bin/cp -p "$TARGET_EXECUTABLE" "$ACCEPTANCE_EXECUTABLE_COPY"
/usr/bin/codesign --remove-signature "$VERIFIED_EXECUTABLE_COPY"
/usr/bin/codesign --remove-signature "$ACCEPTANCE_EXECUTABLE_COPY"
UNSIGNED_VERIFIED_HASH="$(
  /usr/bin/shasum -a 256 -- "$VERIFIED_EXECUTABLE_COPY" | /usr/bin/awk '{print $1}'
)"
UNSIGNED_ACCEPTANCE_HASH="$(
  /usr/bin/shasum -a 256 -- "$ACCEPTANCE_EXECUTABLE_COPY" | /usr/bin/awk '{print $1}'
)"
[[ "$UNSIGNED_ACCEPTANCE_HASH" == "$UNSIGNED_VERIFIED_HASH" ]] \
  || fail "re-signing changed executable content outside its code signature"

[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -expect string "$TARGET_INFO_PLIST")" \
  == "$BUNDLE_IDENTIFIER" ]] \
  || fail "the acceptance bundle identifier is invalid"
[[ "$(/usr/bin/plutil -extract KinlogueAcceptanceEnabled raw -expect bool "$TARGET_INFO_PLIST")" \
  == "true" ]] \
  || fail "the acceptance marker is invalid"
[[ "$(/usr/bin/plutil -extract KinlogueAcceptanceRunID raw -expect string "$TARGET_INFO_PLIST")" \
  == "$RUN_ID" ]] \
  || fail "the acceptance run identifier is invalid"
if /usr/bin/plutil -extract KinlogueLANFeasibilityEnabled raw \
    "$TARGET_INFO_PLIST" >/dev/null 2>&1; then
  fail "the acceptance identity contains obsolete LAN feasibility metadata"
fi
[[ "$(/usr/bin/plutil -extract NSLocalNetworkUsageDescription raw \
    -expect string "$TARGET_INFO_PLIST")" \
    == "仅在您主动开启接收时，允许同一局域网中的设备向这台 Mac 上传资料。" ]] \
  || fail "the acceptance identity lost the production LAN purpose string"

TARGET_ENTITLEMENTS_PLIST="$PROVENANCE_DIRECTORY/acceptance-entitlements.plist"
/usr/bin/codesign -d --entitlements :- "$TARGET_APP" \
  >"$TARGET_ENTITLEMENTS_PLIST" 2>/dev/null \
  || fail "the acceptance entitlements could not be extracted"
/usr/bin/plutil -lint "$TARGET_ENTITLEMENTS_PLIST" >/dev/null \
  || fail "the acceptance entitlements are invalid"
for entitlement_key in \
  'com\.apple\.security\.app-sandbox' \
  'com\.apple\.security\.files\.user-selected\.read-write' \
  'com\.apple\.security\.files\.bookmarks\.app-scope' \
  'com\.apple\.security\.network\.server'; do
  [[ "$(/usr/bin/plutil -extract "$entitlement_key" raw -expect bool \
      "$TARGET_ENTITLEMENTS_PLIST")" == true ]] \
    || fail "the acceptance artifact is missing a required entitlement"
done
[[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.network\.client' raw \
    -expect bool "$TARGET_ENTITLEMENTS_PLIST")" == true ]] \
  || fail "the installed acceptance harness is missing loopback client permission"
STRIPPED_ENTITLEMENTS_PLIST="$PROVENANCE_DIRECTORY/stripped-entitlements.plist"
/bin/cp -p -- "$TARGET_ENTITLEMENTS_PLIST" "$STRIPPED_ENTITLEMENTS_PLIST"
for entitlement_key in \
  'com\.apple\.security\.app-sandbox' \
  'com\.apple\.security\.files\.user-selected\.read-write' \
  'com\.apple\.security\.files\.bookmarks\.app-scope' \
  'com\.apple\.security\.network\.server' \
  'com\.apple\.security\.network\.client'; do
  /usr/bin/plutil -remove "$entitlement_key" "$STRIPPED_ENTITLEMENTS_PLIST" \
    >/dev/null 2>&1 || true
done
[[ "$(/usr/bin/plutil -convert json -o - "$STRIPPED_ENTITLEMENTS_PLIST")" == '{}' ]] \
  || fail "the acceptance entitlements contain an unexpected capability"

BUILD_SUCCEEDED=true

echo "Built isolated acceptance app: $TARGET_APP"
echo "Acceptance run ID: $RUN_ID"
echo "Acceptance bundle ID: $BUNDLE_IDENTIFIER"
echo "Distribution status: ad-hoc signed; for isolated local acceptance only"
