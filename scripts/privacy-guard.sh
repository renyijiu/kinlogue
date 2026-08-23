#!/bin/zsh
set -euo pipefail

umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
SYNTHETIC_MARKER="KINLOGUE_FORBIDDEN""_SYNTHETIC_PHI"
FILE_LIST=""

fail() {
  echo "privacy guard: $1" >&2
  exit 1
}

cleanup() {
  if [[ -n "${FILE_LIST:-}" \
      && -f "$FILE_LIST" && ! -L "$FILE_LIST" \
      && "${FILE_LIST:h}" == /private/tmp \
      && "${FILE_LIST:t}" == kinlogue-privacy-guard.* ]]; then
    /bin/rm -f -- "$FILE_LIST"
  fi
}
trap cleanup EXIT INT TERM HUP

cd "$REPO_DIR"

for disclosure in README.md PRIVACY.md; do
  [[ -f "$disclosure" && ! -L "$disclosure" ]] \
    || fail "a required privacy disclosure is missing or linked"
done
/usr/bin/grep -Fq '普通 HTTP' README.md \
  || fail "README does not disclose ordinary HTTP for LAN receiving"
/usr/bin/grep -Fq '普通 HTTP' PRIVACY.md \
  || fail "privacy notice does not disclose ordinary HTTP for LAN receiving"
/usr/bin/grep -Fq '不把报告或识别结果发送到互联网' PRIVACY.md \
  || fail "privacy notice does not distinguish LAN receiving from external transfer"
if /usr/bin/grep -E -n -- '没有账号、网络|不包含账号、网络连接|纯本地应用' \
    README.md PRIVACY.md >/dev/null 2>&1; then
  fail "a stale no-network privacy claim remains"
fi

PRIVATE_FIXTURE_DIRECTORY="$(
  /usr/bin/find . \
    \( -path './.git' -o -path './.build' -o -path './dist' \) -prune -o \
    -type d \
    \( -name PrivateFixtures \
      -o -name private-medical-records \
      -o -name real-medical-records \) \
    -print -quit
)" || fail "the repository directory audit could not be completed"
[[ -z "$PRIVATE_FIXTURE_DIRECTORY" ]] \
  || fail "a private medical fixture directory is present"

CHECKED_IN_MEDICAL_IMAGE="$(
  /usr/bin/find . \
    \( -path './.git' -o -path './.build' -o -path './dist' \) -prune -o \
    -type f \
    \( -iname '*.dcm' -o -iname '*.dicom' -o -iname '*.nii' \
      -o -iname '*.nii.gz' \) \
    -print -quit
)" || fail "the medical-image fixture audit could not be completed"
[[ -z "$CHECKED_IN_MEDICAL_IMAGE" ]] \
  || fail "a checked-in medical-image fixture is present; fixtures must be generated"

if /usr/bin/grep -n -E -- \
    '(PatientName|PatientID|PatientBirthDate|0010[,[:space:]]*0010|0010[,[:space:]]*0020)' \
    Sources/KinlogueDICOMTestSupport/*.swift \
    Sources/KinlogueDICOMAcceptanceFixtureGenerator/*.swift >/dev/null 2>&1; then
  fail "the generated DICOM fixture contains an identity-bearing patient field"
else
  DICOM_FIXTURE_SCAN_STATUS=$?
  [[ "$DICOM_FIXTURE_SCAN_STATUS" -eq 1 ]] \
    || fail "the generated DICOM fixture identity audit could not be completed"
fi

FILE_LIST="$(/usr/bin/mktemp /private/tmp/kinlogue-privacy-guard.XXXXXX)" \
  || fail "a private file-list workspace could not be created"
/usr/bin/find . \
  \( -path './.git' -o -path './.build' -o -path './dist' \) -prune -o \
  -type f -print0 >"$FILE_LIST" \
  || fail "the repository file audit could not be completed"

is_report_like_file() {
  case "${1:l}" in
    *.pdf|*.png|*.jpg|*.jpeg|*.heic|*.tif|*.tiff) return 0 ;;
    *) return 1 ;;
  esac
}

is_allowed_repository_media_asset() {
  case "$1" in
    ./packaging/AppIcon.png \
      |./packaging/Kinlogue.iconset/icon_16x16.png \
      |./packaging/Kinlogue.iconset/icon_16x16@2x.png \
      |./packaging/Kinlogue.iconset/icon_32x32.png \
      |./packaging/Kinlogue.iconset/icon_32x32@2x.png \
      |./packaging/Kinlogue.iconset/icon_128x128.png \
      |./packaging/Kinlogue.iconset/icon_128x128@2x.png \
      |./packaging/Kinlogue.iconset/icon_256x256.png \
      |./packaging/Kinlogue.iconset/icon_256x256@2x.png \
      |./packaging/Kinlogue.iconset/icon_512x512.png \
      |./packaging/Kinlogue.iconset/icon_512x512@2x.png) return 0 ;;
    *) return 1 ;;
  esac
}

CHECKED_IN_REPORT_LIKE_FILE=""
while IFS= read -r -d '' candidate; do
  if is_report_like_file "$candidate" \
      && ! is_allowed_repository_media_asset "$candidate"; then
    CHECKED_IN_REPORT_LIKE_FILE="$candidate"
    break
  fi
done <"$FILE_LIST"
[[ -z "$CHECKED_IN_REPORT_LIKE_FILE" ]] \
  || fail "a checked-in report-like PDF or image is present; only explicitly reviewed media assets are allowed"

scan_forbidden_value() {
  local forbidden_value="$1"
  local candidate scan_status

  while IFS= read -r -d '' candidate; do
    if /usr/bin/grep -F -l -- "$forbidden_value" "$candidate" \
        >/dev/null 2>&1; then
      return 0
    else
      scan_status=$?
      [[ "$scan_status" -eq 1 ]] \
        || return 2
    fi
  done <"$FILE_LIST"
  return 1
}

if scan_forbidden_value "$SYNTHETIC_MARKER"; then
  fail "synthetic forbidden marker found"
else
  SCAN_STATUS=$?
  [[ "$SCAN_STATUS" -eq 1 ]] \
    || fail "the synthetic forbidden marker audit could not be completed"
fi

if [[ -n ${KINLOGUE_FORBIDDEN_VALUES:-} ]]; then
  while IFS= read -r forbidden_value; do
    [[ -z "$forbidden_value" ]] && continue
    if scan_forbidden_value "$forbidden_value"; then
      fail "an externally supplied forbidden value was found"
    else
      SCAN_STATUS=$?
      [[ "$SCAN_STATUS" -eq 1 ]] \
        || fail "an externally supplied forbidden value audit could not be completed"
    fi
  done <<< "$KINLOGUE_FORBIDDEN_VALUES"
fi

echo "Privacy guard passed"
