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
INSTALL_GUIDE="$REPO_DIR/docs/adhoc-candidate-install.md"
RELEASE_PARENT="$DIST_DIRECTORY/release"
STAGE_DIRECTORY=""
TEMP_DIRECTORY=""

fail() {
  echo "Ad-hoc candidate packaging failed: $1" >&2
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

verify_adhoc_signature() {
  local app="$1"
  local label="$2"
  local executable="$app/Contents/MacOS/Kinlogue"
  local info_plist="$app/Contents/Info.plist"
  local signature_metadata="$TEMP_DIRECTORY/$label-signature-metadata.txt"
  local signed_entitlements="$TEMP_DIRECTORY/$label-signed-entitlements.plist"
  local remaining_entitlements="$TEMP_DIRECTORY/$label-remaining-entitlements.plist"

  [[ -d "$app" && ! -L "$app" \
      && -f "$executable" && ! -L "$executable" && -x "$executable" \
      && -f "$info_plist" && ! -L "$info_plist" ]] \
    || fail "$label app structure or executable permissions are invalid"
  [[ "$(/usr/bin/lipo -archs "$executable")" == arm64 ]] \
    || fail "$label app must contain only the arm64 architecture"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" \
    || fail "$label app signature verification failed"
  /usr/bin/codesign -d --verbose=4 "$app" \
    >/dev/null 2>"$signature_metadata"
  /usr/bin/grep -Fqx "Signature=adhoc" "$signature_metadata" \
    || fail "$label app is not ad-hoc signed"
  /usr/bin/grep -Fqx "Identifier=com.kinlogue.mac" "$signature_metadata" \
    || fail "$label app identifier drifted"
  /usr/bin/grep -Fqx "TeamIdentifier=not set" "$signature_metadata" \
    || fail "$label app unexpectedly claims a signing team"
  if /usr/bin/grep -q '^Authority=' "$signature_metadata"; then
    fail "$label app unexpectedly contains a signing authority"
  fi

  /usr/bin/codesign -d --entitlements :- "$app" \
    >"$signed_entitlements" 2>/dev/null
  /usr/bin/plutil -lint "$signed_entitlements" >/dev/null \
    || fail "$label ad-hoc signed entitlements are invalid"
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
      && "${STAGE_DIRECTORY:t}" == .adhoc-candidate.* ]]; then
    /bin/rm -rf -- "$STAGE_DIRECTORY"
  fi
  if [[ -n "${TEMP_DIRECTORY:-}" \
      && -d "$TEMP_DIRECTORY" && ! -L "$TEMP_DIRECTORY" \
      && "${TEMP_DIRECTORY:h}" == /private/tmp \
      && "${TEMP_DIRECTORY:t}" == kinlogue-adhoc-candidate.* ]]; then
    /bin/rm -rf -- "$TEMP_DIRECTORY"
  fi
}
trap cleanup EXIT INT TERM HUP

[[ "$#" -eq 1 ]] \
  || fail "usage: package-adhoc-candidate.sh v<short-version>"
RELEASE_TAG="$1"
[[ "$RELEASE_TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] \
  || fail "the release tag is invalid"

[[ -z "$(/usr/bin/git -C "$REPO_DIR" status --porcelain --untracked-files=normal)" ]] \
  || fail "the source tree must be clean before candidate packaging"
[[ -d "$APP_BUNDLE" && ! -L "$APP_BUNDLE" \
    && -f "$INFO_PLIST" && ! -L "$INFO_PLIST" \
    && -f "$PRE_DISTRIBUTION_REPORT" && ! -L "$PRE_DISTRIBUTION_REPORT" \
    && -f "$INSTALL_GUIDE" && ! -L "$INSTALL_GUIDE" ]] \
  || fail "the verified candidate inputs are incomplete"
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
    && "$(/usr/bin/plutil -extract artifact.architectures raw -expect string \
      "$PRE_DISTRIBUTION_REPORT")" == arm64 \
    && "$(/usr/bin/plutil -extract artifact.bundleHashFormat raw -expect string \
      "$PRE_DISTRIBUTION_REPORT")" == sha256-content-manifest-v1 ]] \
  || fail "the pre-distribution report artifact contract drifted"
[[ "$(/usr/bin/plutil -extract signing.kind raw -expect string \
      "$PRE_DISTRIBUTION_REPORT")" == adHoc \
    && "$(/usr/bin/plutil -extract signing.developerID.status raw -expect string \
      "$PRE_DISTRIBUTION_REPORT")" == notExecuted \
    && "$(/usr/bin/plutil -extract signing.notarization.status raw -expect string \
      "$PRE_DISTRIBUTION_REPORT")" == notExecuted ]] \
  || fail "the verified input does not declare the expected ad-hoc trust boundary"

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
FINAL_DIRECTORY="$RELEASE_PARENT/$RELEASE_TAG-adhoc"
[[ ! -e "$FINAL_DIRECTORY" && ! -L "$FINAL_DIRECTORY" ]] \
  || fail "the candidate output already exists; overwrite is forbidden"
STAGE_DIRECTORY="$(/usr/bin/mktemp -d "$DIST_DIRECTORY/.adhoc-candidate.XXXXXX")" \
  || fail "the candidate staging directory could not be created"
TEMP_DIRECTORY="$(/usr/bin/mktemp -d /private/tmp/kinlogue-adhoc-candidate.XXXXXX)" \
  || fail "the candidate verification workspace could not be created"

PRE_PACKAGING_MANIFEST="$TEMP_DIRECTORY/pre-packaging-bundle-manifest.txt"
EXPECTED_BUNDLE_HASH="$(/usr/bin/plutil -extract artifact.bundleSHA256 raw \
  -expect string "$PRE_DISTRIBUTION_REPORT")"
ACTUAL_BUNDLE_HASH="$(bundle_hash "$APP_BUNDLE" "$PRE_PACKAGING_MANIFEST")"
[[ "$ACTUAL_BUNDLE_HASH" == "$EXPECTED_BUNDLE_HASH" ]] \
  || fail "the preverified app content changed before candidate packaging"
verify_adhoc_signature "$APP_BUNDLE" live

PRE_REPORT_NAME="pre-distribution-verification-report.json"
INSTALL_NAME="INSTALL.md"
/bin/cp -- "$PRE_DISTRIBUTION_REPORT" "$STAGE_DIRECTORY/$PRE_REPORT_NAME"
/bin/cp -- "$INSTALL_GUIDE" "$STAGE_DIRECTORY/$INSTALL_NAME"

ARTIFACT_NAME="Kinlogue-$SHORT_VERSION-arm64-adhoc.zip"
/usr/bin/ditto -c -k --keepParent \
  "$APP_BUNDLE" "$STAGE_DIRECTORY/$ARTIFACT_NAME"
"$REPO_DIR/scripts/verify-app-zip-safety.sh" \
  "$STAGE_DIRECTORY/$ARTIFACT_NAME"

EXTRACTION_DIRECTORY="$TEMP_DIRECTORY/final-zip-extraction"
/bin/mkdir -m 700 "$EXTRACTION_DIRECTORY"
/usr/bin/ditto -x -k \
  "$STAGE_DIRECTORY/$ARTIFACT_NAME" "$EXTRACTION_DIRECTORY"
[[ "$(cd "$EXTRACTION_DIRECTORY" \
      && /usr/bin/find . -mindepth 1 -maxdepth 1 -print)" == ./Kinlogue.app ]] \
  || fail "the final ZIP did not extract exactly one Kinlogue.app root"
EXTRACTED_APP="$EXTRACTION_DIRECTORY/Kinlogue.app"
[[ -z "$(/usr/bin/find "$EXTRACTION_DIRECTORY" -type l -print -quit)" ]] \
  || fail "the extracted final ZIP contains a symbolic link"
verify_adhoc_signature "$EXTRACTED_APP" extracted
EXTRACTED_MANIFEST="$TEMP_DIRECTORY/extracted-bundle-manifest.txt"
EXTRACTED_BUNDLE_HASH="$(bundle_hash "$EXTRACTED_APP" "$EXTRACTED_MANIFEST")"
[[ "$EXTRACTED_BUNDLE_HASH" == "$EXPECTED_BUNDLE_HASH" ]] \
  || fail "the extracted candidate bundle content does not match the verified input"

ARTIFACT_SHA256="$(/usr/bin/shasum -a 256 -- \
  "$STAGE_DIRECTORY/$ARTIFACT_NAME" | /usr/bin/awk '{print $1}')"
PRE_REPORT_SHA256="$(/usr/bin/shasum -a 256 -- \
  "$STAGE_DIRECTORY/$PRE_REPORT_NAME" | /usr/bin/awk '{print $1}')"
METADATA_NAME="release-metadata.json"
METADATA_PLIST="$TEMP_DIRECTORY/release-metadata.plist"
/usr/bin/plutil -create xml1 "$METADATA_PLIST"
/usr/bin/plutil -insert schemaVersion -integer 1 "$METADATA_PLIST"
/usr/bin/plutil -insert releaseTag -string "$RELEASE_TAG" "$METADATA_PLIST"
/usr/bin/plutil -insert sourceRevision -string "$SOURCE_REVISION" "$METADATA_PLIST"
/usr/bin/plutil -insert shortVersion -string "$SHORT_VERSION" "$METADATA_PLIST"
/usr/bin/plutil -insert buildVersion -string "$BUILD_VERSION" "$METADATA_PLIST"
/usr/bin/plutil -insert distributionStatus -string publicPrereleaseUnnotarized \
  "$METADATA_PLIST"
/usr/bin/plutil -insert artifact -dictionary "$METADATA_PLIST"
/usr/bin/plutil -insert artifact.file -string "$ARTIFACT_NAME" "$METADATA_PLIST"
/usr/bin/plutil -insert artifact.architecture -string arm64 "$METADATA_PLIST"
/usr/bin/plutil -insert artifact.sha256 -string "$ARTIFACT_SHA256" "$METADATA_PLIST"
/usr/bin/plutil -insert artifact.bundleSHA256 -string "$EXPECTED_BUNDLE_HASH" \
  "$METADATA_PLIST"
/usr/bin/plutil -insert artifact.preDistributionVerificationReportSHA256 \
  -string "$PRE_REPORT_SHA256" "$METADATA_PLIST"
/usr/bin/plutil -insert signing -dictionary "$METADATA_PLIST"
/usr/bin/plutil -insert signing.kind -string AdHoc "$METADATA_PLIST"
/usr/bin/plutil -insert signing.developerIdentity -string NotAvailable \
  "$METADATA_PLIST"
/usr/bin/plutil -insert notarization -dictionary "$METADATA_PLIST"
/usr/bin/plutil -insert notarization.status -string NotAvailable "$METADATA_PLIST"
/usr/bin/plutil -insert trust -dictionary "$METADATA_PLIST"
/usr/bin/plutil -insert trust.manualGatekeeperOverrideRequired -bool true \
  "$METADATA_PLIST"
/usr/bin/plutil -insert trust.appleMalwareReviewPerformed -bool false \
  "$METADATA_PLIST"
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
  || fail "the candidate release metadata is invalid"

/usr/bin/printf '%s  %s\n' "$ARTIFACT_SHA256" "$ARTIFACT_NAME" \
  >"$STAGE_DIRECTORY/$ARTIFACT_NAME.sha256"
(
  cd "$STAGE_DIRECTORY"
  /usr/bin/printf '%s  %s\n' "$ARTIFACT_SHA256" "$ARTIFACT_NAME" \
    >SHA256SUMS
  /usr/bin/shasum -a 256 -- \
    "$INSTALL_NAME" \
    "$METADATA_NAME" \
    "$PRE_REPORT_NAME" \
    >>SHA256SUMS
)

/bin/mv -- "$STAGE_DIRECTORY" "$FINAL_DIRECTORY"
STAGE_DIRECTORY=""

echo "Ad-hoc candidate packaged: $FINAL_DIRECTORY"
echo "Artifact SHA-256: $ARTIFACT_SHA256"
echo "Developer ID and notarization are unavailable; manual Gatekeeper override is required"
