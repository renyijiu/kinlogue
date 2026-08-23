#!/bin/zsh
set -euo pipefail

umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
DIST_DIRECTORY="$REPO_DIR/dist"
APP_BUNDLE="$DIST_DIRECTORY/Kinlogue.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
PRE_DISTRIBUTION_REPORT="$DIST_DIRECTORY/verification-report.json"
RELEASE_PARENT="$DIST_DIRECTORY/release"
STAGE_DIRECTORY=""
NOTARY_TEMP_DIRECTORY=""

fail() {
  echo "Distribution packaging failed: $1" >&2
  exit 1
}

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

verify_distribution_signature() {
  local app="$1"
  local label="$2"
  local executable="$app/Contents/MacOS/Kinlogue"
  local info_plist="$app/Contents/Info.plist"
  local signature_metadata="$NOTARY_TEMP_DIRECTORY/$label-signature-metadata.txt"
  local signed_entitlements="$NOTARY_TEMP_DIRECTORY/$label-signed-entitlements.plist"
  local remaining_entitlements="$NOTARY_TEMP_DIRECTORY/$label-remaining-entitlements.plist"

  [[ -d "$app" && ! -L "$app" \
      && -f "$executable" && ! -L "$executable" && -x "$executable" \
      && -f "$info_plist" && ! -L "$info_plist" ]] \
    || fail "$label app structure or executable permissions are invalid"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" \
    || fail "$label app signature verification failed"
  /usr/bin/codesign -d --verbose=4 "$app" \
    >/dev/null 2>"$signature_metadata"
  /usr/bin/grep -Fq "Authority=$KINLOGUE_CODESIGN_IDENTITY" \
    "$signature_metadata" \
    || fail "$label app does not contain the requested Developer ID authority"
  /usr/bin/grep -Fq "Identifier=com.kinlogue.mac" "$signature_metadata" \
    || fail "$label app identifier drifted"
  /usr/bin/grep -Fq "TeamIdentifier=$KINLOGUE_DEVELOPER_TEAM_ID" \
    "$signature_metadata" \
    || fail "$label app Team ID drifted"

  /usr/bin/codesign -d --entitlements :- "$app" \
    >"$signed_entitlements" 2>/dev/null
  /usr/bin/plutil -lint "$signed_entitlements" >/dev/null \
    || fail "$label Developer ID signed entitlements are invalid"
  /bin/cp -- "$signed_entitlements" "$remaining_entitlements"
  for entitlement in \
    com.apple.security.app-sandbox \
    com.apple.security.files.user-selected.read-write \
    com.apple.security.files.bookmarks.app-scope \
    com.apple.security.network.server; do
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" \
      "$remaining_entitlements" 2>/dev/null)" == true ]] \
      || fail "$label signed entitlements do not match the exact production allow-list"
    /usr/libexec/PlistBuddy -c "Delete :$entitlement" \
      "$remaining_entitlements" >/dev/null \
      || fail "$label signed entitlements could not be normalized"
  done
  [[ "$(/usr/bin/plutil -convert json -o - "$remaining_entitlements")" == '{}' ]] \
    || fail "$label signed entitlements contain values outside the exact production allow-list"
}

cleanup() {
  if [[ -n "${STAGE_DIRECTORY:-}" \
      && -d "$STAGE_DIRECTORY" && ! -L "$STAGE_DIRECTORY" \
      && "${STAGE_DIRECTORY:h}" == "$DIST_DIRECTORY" \
      && "${STAGE_DIRECTORY:t}" == .distribution.* ]]; then
    /bin/rm -rf -- "$STAGE_DIRECTORY"
  fi
  if [[ -n "${NOTARY_TEMP_DIRECTORY:-}" \
      && -d "$NOTARY_TEMP_DIRECTORY" && ! -L "$NOTARY_TEMP_DIRECTORY" \
      && "${NOTARY_TEMP_DIRECTORY:h}" == /private/tmp \
      && "${NOTARY_TEMP_DIRECTORY:t}" == kinlogue-notary.* ]]; then
    /bin/rm -rf -- "$NOTARY_TEMP_DIRECTORY"
  fi
}
trap cleanup EXIT INT TERM HUP

[[ "$#" -eq 1 ]] \
  || fail "usage: package-distribution.sh v<short-version>"
RELEASE_TAG="$1"
[[ "$RELEASE_TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] \
  || fail "the release tag is invalid"

for required_name in \
    KINLOGUE_CODESIGN_IDENTITY \
    KINLOGUE_DEVELOPER_TEAM_ID \
    KINLOGUE_SIGNING_KEYCHAIN_PATH \
    KINLOGUE_NOTARY_KEY_PATH \
    KINLOGUE_NOTARY_KEY_ID \
    KINLOGUE_NOTARY_ISSUER_ID; do
  [[ -n "${(P)required_name:-}" ]] \
    || fail "the required environment value $required_name is missing"
done

[[ "$KINLOGUE_CODESIGN_IDENTITY" == 'Developer ID Application: '* \
    && "$KINLOGUE_CODESIGN_IDENTITY" != *$'\n'* ]] \
  || fail "the signing identity must be a single Developer ID Application identity"
[[ "$KINLOGUE_DEVELOPER_TEAM_ID" =~ '^[A-Z0-9]{10}$' ]] \
  || fail "the Developer Team ID is invalid"
[[ "$KINLOGUE_NOTARY_KEY_ID" =~ '^[A-Z0-9]{10}$' ]] \
  || fail "the notary key ID is invalid"
[[ "$KINLOGUE_NOTARY_ISSUER_ID" =~ '^[0-9a-fA-F-]{36}$' ]] \
  || fail "the notary issuer ID is invalid"

for private_file in "$KINLOGUE_SIGNING_KEYCHAIN_PATH" "$KINLOGUE_NOTARY_KEY_PATH"; do
  [[ "$private_file" == /* && -f "$private_file" && ! -L "$private_file" ]] \
    || fail "a signing input is missing, linked, or not an absolute regular file"
  [[ "$(/usr/bin/stat -f '%u' "$private_file")" == "$EUID" ]] \
    || fail "a signing input is not owned by the current user"
done
[[ "$(/usr/bin/stat -f '%Lp' "$KINLOGUE_NOTARY_KEY_PATH")" == 600 ]] \
  || fail "the notary private key must use mode 0600"

[[ -z "$(/usr/bin/git -C "$REPO_DIR" status --porcelain --untracked-files=normal)" ]] \
  || fail "the source tree must be clean before distribution packaging"

[[ -d "$APP_BUNDLE" && ! -L "$APP_BUNDLE" \
    && -f "$INFO_PLIST" && ! -L "$INFO_PLIST" \
    && -f "$PRE_DISTRIBUTION_REPORT" && ! -L "$PRE_DISTRIBUTION_REPORT" ]] \
  || fail "the verified local release inputs are incomplete"
[[ -z "$(/usr/bin/find "$APP_BUNDLE" -type l -print -quit)" ]] \
  || fail "the preverified app must not contain symbolic links"
/usr/bin/plutil -convert json -o /dev/null "$PRE_DISTRIBUTION_REPORT" \
  || fail "the pre-distribution verification report is invalid"

SOURCE_REVISION="$(/usr/bin/git -C "$REPO_DIR" rev-parse --verify HEAD)" \
  || fail "the source revision is unavailable"
[[ "$(/usr/bin/plutil -extract source.cleanRequired raw -expect bool \
      "$PRE_DISTRIBUTION_REPORT")" == true \
    && "$(/usr/bin/plutil -extract source.dirty raw -expect bool \
      "$PRE_DISTRIBUTION_REPORT")" == false ]] \
  || fail "the app was not preverified with the clean-source release gate"
[[ "$(/usr/bin/plutil -extract source.revision raw -expect string \
      "$PRE_DISTRIBUTION_REPORT")" == "$SOURCE_REVISION" ]] \
  || fail "the pre-distribution report source revision does not match HEAD"
[[ "$(/usr/bin/plutil -extract gates.bundleVerification raw -expect string \
      "$PRE_DISTRIBUTION_REPORT")" == passed ]] \
  || fail "the pre-distribution bundle verification gate is not passed"
[[ "$(/usr/bin/plutil -extract artifact.bundleIdentifier raw -expect string \
      "$PRE_DISTRIBUTION_REPORT")" == com.kinlogue.mac \
    && "$(/usr/bin/plutil -extract artifact.bundleHashFormat raw -expect string \
      "$PRE_DISTRIBUTION_REPORT")" == sha256-content-manifest-v1 ]] \
  || fail "the pre-distribution report artifact contract drifted"

SHORT_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw \
  -expect string "$INFO_PLIST")"
BUILD_VERSION="$(/usr/bin/plutil -extract CFBundleVersion raw \
  -expect string "$INFO_PLIST")"
[[ "$RELEASE_TAG" == "v$SHORT_VERSION" ]] \
  || fail "the release tag must exactly match Info.plist short version $SHORT_VERSION"

if [[ -e "$RELEASE_PARENT" || -L "$RELEASE_PARENT" ]]; then
  [[ -d "$RELEASE_PARENT" && ! -L "$RELEASE_PARENT" ]] \
    || fail "the release output parent must be a real directory"
else
  /bin/mkdir -p "$RELEASE_PARENT"
fi
FINAL_DIRECTORY="$RELEASE_PARENT/$RELEASE_TAG"
[[ ! -e "$FINAL_DIRECTORY" && ! -L "$FINAL_DIRECTORY" ]] \
  || fail "the release output already exists; overwrite is forbidden"
STAGE_DIRECTORY="$(/usr/bin/mktemp -d "$DIST_DIRECTORY/.distribution.XXXXXX")" \
  || fail "the distribution staging directory could not be created"
NOTARY_TEMP_DIRECTORY="$(/usr/bin/mktemp -d /private/tmp/kinlogue-notary.XXXXXX)" \
  || fail "the notarization workspace could not be created"

PRE_SIGNING_MANIFEST="$NOTARY_TEMP_DIRECTORY/pre-signing-bundle-manifest.txt"
EXPECTED_BUNDLE_HASH="$(/usr/bin/plutil -extract artifact.bundleSHA256 raw \
  -expect string "$PRE_DISTRIBUTION_REPORT")"
ACTUAL_BUNDLE_HASH="$(bundle_hash "$APP_BUNDLE" "$PRE_SIGNING_MANIFEST")"
[[ "$ACTUAL_BUNDLE_HASH" == "$EXPECTED_BUNDLE_HASH" ]] \
  || fail "the preverified app content changed before signing"

PRE_REPORT_NAME="pre-distribution-verification-report.json"
/bin/cp -- "$PRE_DISTRIBUTION_REPORT" "$STAGE_DIRECTORY/$PRE_REPORT_NAME"

/usr/bin/codesign --force --sign "$KINLOGUE_CODESIGN_IDENTITY" \
  --keychain "$KINLOGUE_SIGNING_KEYCHAIN_PATH" \
  --options runtime \
  --timestamp \
  --entitlements "$REPO_DIR/packaging/Kinlogue.entitlements" \
  "$APP_BUNDLE"
verify_distribution_signature "$APP_BUNDLE" live

NOTARY_ARCHIVE="$NOTARY_TEMP_DIRECTORY/Kinlogue-notary.zip"
/usr/bin/ditto -c -k --keepParent \
  "$APP_BUNDLE" "$NOTARY_ARCHIVE"
NOTARY_RESULT_NAME="notarization-result.json"
/usr/bin/xcrun notarytool submit "$NOTARY_ARCHIVE" \
  --key "$KINLOGUE_NOTARY_KEY_PATH" \
  --key-id "$KINLOGUE_NOTARY_KEY_ID" \
  --issuer "$KINLOGUE_NOTARY_ISSUER_ID" \
  --wait \
  --output-format json >"$STAGE_DIRECTORY/$NOTARY_RESULT_NAME"
[[ "$(/usr/bin/plutil -extract status raw -expect string \
    "$STAGE_DIRECTORY/$NOTARY_RESULT_NAME")" == Accepted ]] \
  || fail "Apple did not accept the notarization submission"
NOTARY_SUBMISSION_ID="$(/usr/bin/plutil -extract id raw -expect string \
  "$STAGE_DIRECTORY/$NOTARY_RESULT_NAME")"

/usr/bin/xcrun stapler staple "$APP_BUNDLE"
/usr/bin/xcrun stapler validate "$APP_BUNDLE"
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP_BUNDLE"

ARTIFACT_NAME="Kinlogue-$SHORT_VERSION.zip"
/usr/bin/ditto -c -k --keepParent \
  "$APP_BUNDLE" "$STAGE_DIRECTORY/$ARTIFACT_NAME"
"$REPO_DIR/scripts/verify-app-zip-safety.sh" \
  "$STAGE_DIRECTORY/$ARTIFACT_NAME"

EXTRACTION_DIRECTORY="$NOTARY_TEMP_DIRECTORY/final-zip-extraction"
/bin/mkdir -m 700 "$EXTRACTION_DIRECTORY"
/usr/bin/ditto -x -k \
  "$STAGE_DIRECTORY/$ARTIFACT_NAME" "$EXTRACTION_DIRECTORY"
[[ "$(cd "$EXTRACTION_DIRECTORY" \
      && /usr/bin/find . -mindepth 1 -maxdepth 1 -print)" == ./Kinlogue.app ]] \
  || fail "the final ZIP did not extract exactly one Kinlogue.app root"
EXTRACTED_APP="$EXTRACTION_DIRECTORY/Kinlogue.app"
[[ -z "$(/usr/bin/find "$EXTRACTION_DIRECTORY" -type l -print -quit)" ]] \
  || fail "the extracted final ZIP contains a symbolic link"
verify_distribution_signature "$EXTRACTED_APP" extracted
/usr/bin/xcrun stapler validate "$EXTRACTED_APP"
/usr/sbin/spctl --assess --type execute --verbose=4 "$EXTRACTED_APP"

ARTIFACT_SHA256="$(/usr/bin/shasum -a 256 -- \
  "$STAGE_DIRECTORY/$ARTIFACT_NAME" | /usr/bin/awk '{print $1}')"
PRE_REPORT_SHA256="$(/usr/bin/shasum -a 256 -- \
  "$STAGE_DIRECTORY/$PRE_REPORT_NAME" | /usr/bin/awk '{print $1}')"
METADATA_NAME="release-metadata.json"
METADATA_PLIST="$NOTARY_TEMP_DIRECTORY/release-metadata.plist"
/usr/bin/plutil -create xml1 "$METADATA_PLIST"
/usr/bin/plutil -insert schemaVersion -integer 1 "$METADATA_PLIST"
/usr/bin/plutil -insert releaseTag -string "$RELEASE_TAG" "$METADATA_PLIST"
/usr/bin/plutil -insert sourceRevision -string "$SOURCE_REVISION" "$METADATA_PLIST"
/usr/bin/plutil -insert shortVersion -string "$SHORT_VERSION" "$METADATA_PLIST"
/usr/bin/plutil -insert buildVersion -string "$BUILD_VERSION" "$METADATA_PLIST"
/usr/bin/plutil -insert distributionStatus -string draftPendingManualGates \
  "$METADATA_PLIST"
/usr/bin/plutil -insert artifact -dictionary "$METADATA_PLIST"
/usr/bin/plutil -insert artifact.file -string "$ARTIFACT_NAME" "$METADATA_PLIST"
/usr/bin/plutil -insert artifact.sha256 -string "$ARTIFACT_SHA256" "$METADATA_PLIST"
/usr/bin/plutil -insert artifact.preDistributionVerificationReportSHA256 \
  -string "$PRE_REPORT_SHA256" "$METADATA_PLIST"
/usr/bin/plutil -insert signing -dictionary "$METADATA_PLIST"
/usr/bin/plutil -insert signing.kind -string DeveloperID "$METADATA_PLIST"
/usr/bin/plutil -insert signing.identity -string "$KINLOGUE_CODESIGN_IDENTITY" \
  "$METADATA_PLIST"
/usr/bin/plutil -insert signing.teamIdentifier -string \
  "$KINLOGUE_DEVELOPER_TEAM_ID" "$METADATA_PLIST"
/usr/bin/plutil -insert notarization -dictionary "$METADATA_PLIST"
/usr/bin/plutil -insert notarization.status -string Accepted "$METADATA_PLIST"
/usr/bin/plutil -insert notarization.submissionID -string \
  "$NOTARY_SUBMISSION_ID" "$METADATA_PLIST"
/usr/bin/plutil -insert compatibility -dictionary "$METADATA_PLIST"
/usr/bin/plutil -insert compatibility.workflowReleaseGates -string passed \
  "$METADATA_PLIST"
/usr/bin/plutil -insert compatibility.installedAcceptance -string \
  PENDING_FORMAL_RELEASE_GATE "$METADATA_PLIST"
/usr/bin/plutil -insert compatibility.macOS14 -string \
  PENDING_FORMAL_RELEASE_GATE "$METADATA_PLIST"
/usr/bin/plutil -insert compatibility.macOS15 -string \
  PENDING_FORMAL_RELEASE_GATE "$METADATA_PLIST"
/usr/bin/plutil -insert compatibility.realPhoneMatrix -string \
  PENDING_FORMAL_RELEASE_GATE "$METADATA_PLIST"
/usr/bin/plutil -convert json -o "$STAGE_DIRECTORY/$METADATA_NAME" \
  "$METADATA_PLIST"
/usr/bin/plutil -convert json -o /dev/null "$STAGE_DIRECTORY/$METADATA_NAME" \
  || fail "the release metadata is invalid"

(
  cd "$STAGE_DIRECTORY"
  /usr/bin/shasum -a 256 -- \
    "$ARTIFACT_NAME" \
    "$METADATA_NAME" \
    "$NOTARY_RESULT_NAME" \
    "$PRE_REPORT_NAME" \
    >SHA256SUMS
)

/bin/mv -- "$STAGE_DIRECTORY" "$FINAL_DIRECTORY"
STAGE_DIRECTORY=""

echo "Distribution draft packaged: $FINAL_DIRECTORY"
echo "Artifact SHA-256: $ARTIFACT_SHA256"
echo "Manual compatibility and real-device gates remain pending"
