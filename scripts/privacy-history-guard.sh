#!/bin/zsh
set -euo pipefail

umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export LC_ALL=C
export LANG=C

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
TEMP_DIR=""

fail() {
  echo "privacy history guard: $1" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TEMP_DIR:-}" \
      && -d "$TEMP_DIR" && ! -L "$TEMP_DIR" \
      && "${TEMP_DIR:h}" == /private/tmp \
      && "${TEMP_DIR:t}" == kinlogue-privacy-history.* ]]; then
    /bin/rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT INT TERM HUP

usage() {
  echo "usage: scripts/privacy-history-guard.sh [--ref <public-bound-ref>]..." >&2
  exit 64
}

typeset -a REQUESTED_REFS
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --ref)
      [[ "$#" -ge 2 && -n "$2" ]] || usage
      REQUESTED_REFS+=("$2")
      shift 2
      ;;
    *) usage ;;
  esac
done

cd "$REPO_DIR"
[[ "$(/usr/bin/git rev-parse --is-inside-work-tree 2>/dev/null)" == true ]] \
  || fail "the script must run from a Git worktree"
[[ "$(/usr/bin/git rev-parse --show-toplevel 2>/dev/null)" == "$REPO_DIR" ]] \
  || fail "the script is not bound to the repository root"

typeset -a PUBLIC_REFS
typeset -A SEEN_REFS
add_public_ref() {
  local candidate="$1"
  [[ -n "$candidate" && -z "${SEEN_REFS[$candidate]:-}" ]] || return 0
  SEEN_REFS[$candidate]=1
  PUBLIC_REFS+=("$candidate")
}

if [[ "${#REQUESTED_REFS[@]}" -gt 0 ]]; then
  for requested_ref in "${REQUESTED_REFS[@]}"; do
    add_public_ref "$requested_ref"
  done
else
  add_public_ref HEAD
  while IFS= read -r discovered_ref; do
    add_public_ref "$discovered_ref"
  done < <(/usr/bin/git for-each-ref \
    --format='%(refname)' refs/heads refs/tags refs/remotes/origin)
fi

[[ "${#PUBLIC_REFS[@]}" -gt 0 ]] || fail "no public-bound refs were selected"
for public_ref in "${PUBLIC_REFS[@]}"; do
  /usr/bin/git rev-parse --verify --quiet "$public_ref^{commit}" >/dev/null \
    || fail "a selected public-bound ref is not a commit"
done

TEMP_DIR="$(/usr/bin/mktemp -d /private/tmp/kinlogue-privacy-history.XXXXXX)" \
  || fail "a private history-scan workspace could not be created"
[[ -d "$TEMP_DIR" && ! -L "$TEMP_DIR" \
    && "$(/usr/bin/stat -f '%u' "$TEMP_DIR")" == "$EUID" \
    && "$(/usr/bin/stat -f '%Lp' "$TEMP_DIR")" == 700 ]] \
  || fail "the history-scan workspace is not private"

PATH_LIST="$TEMP_DIR/paths"
OBJECT_LIST="$TEMP_DIR/objects"
OBJECT_STREAM="$TEMP_DIR/object-stream"

/usr/bin/git log --format= --name-only -z "${PUBLIC_REFS[@]}" -- >"$PATH_LIST" \
  || fail "reachable path enumeration failed"

is_allowed_repository_media_asset() {
  case "$1" in
    packaging/AppIcon.png \
      |packaging/Kinlogue.iconset/icon_16x16.png \
      |packaging/Kinlogue.iconset/icon_16x16@2x.png \
      |packaging/Kinlogue.iconset/icon_32x32.png \
      |packaging/Kinlogue.iconset/icon_32x32@2x.png \
      |packaging/Kinlogue.iconset/icon_128x128.png \
      |packaging/Kinlogue.iconset/icon_128x128@2x.png \
      |packaging/Kinlogue.iconset/icon_256x256.png \
      |packaging/Kinlogue.iconset/icon_256x256@2x.png \
      |packaging/Kinlogue.iconset/icon_512x512.png \
      |packaging/Kinlogue.iconset/icon_512x512@2x.png) return 0 ;;
    *) return 1 ;;
  esac
}

is_allowed_historical_secret_template() {
  [[ "${1:t}" == .env.example ]]
}

is_prohibited_historical_path() {
  local candidate="$1"
  local leaf="${candidate:t:l}"
  case "$leaf" in
    .env|.env.*) return 0 ;;
  esac
  case "${candidate:l}" in
    *.dcm|*.dicom|*.nii|*.nii.gz|*.pdf|*.png|*.jpg|*.jpeg|*.heic|*.tif|*.tiff \
      |*.kinloguebackup|*.key|*.p8|*.p12|*.pfx|*.mobileprovision) return 0 ;;
    *) return 1 ;;
  esac
}

while IFS= read -r -d '' historical_path; do
  [[ -n "$historical_path" ]] || continue
  if is_prohibited_historical_path "$historical_path" \
      && ! is_allowed_repository_media_asset "$historical_path" \
      && ! is_allowed_historical_secret_template "$historical_path"; then
    fail "a prohibited medical, report-like, backup, credential, or signing artifact path exists in reachable history"
  fi
done <"$PATH_LIST"

/usr/bin/git rev-list --objects --no-object-names "${PUBLIC_REFS[@]}" -- \
  | /usr/bin/sort -u >"$OBJECT_LIST" \
  || fail "reachable object enumeration failed"
if /usr/bin/grep -E -v -q -- '^[0-9a-f]{40,64}$' "$OBJECT_LIST"; then
  fail "reachable object enumeration returned an invalid identifier"
else
  SCAN_STATUS=$?
  [[ "$SCAN_STATUS" -eq 1 ]] \
    || fail "reachable object identifiers could not be validated"
fi
/usr/bin/git cat-file --batch <"$OBJECT_LIST" >"$OBJECT_STREAM" \
  || fail "reachable objects could not be read"

CREDENTIAL_PATTERN='(-----BEGIN ([A-Z0-9]+ )?PRIVATE[[:space:]]+KEY-----|A[K]IA[0-9A-Z]{16}|A[S]IA[0-9A-Z]{16}|g[h][pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{20,255}|x[o]x[baprs]-[A-Za-z0-9-]{10,255}|s[k]_live_[A-Za-z0-9]{16,255}|s[k]-(proj-)?[A-Za-z0-9_-]{20,255}|A[I]za[0-9A-Za-z_-]{35}|K[L]G1-([0-9A-F]{8}-){8}[0-9A-F]{8}|https?://[^/@[:space:]]+:[^/@[:space:]]+@)'
PRIVATE_INVENTORY_PATTERN='((私[有][^[:cntrl:]]{0,240}|真[实](资料|播放)[^[:cntrl:]]{0,240}|本机真[实][[:space:]]*UI[^[:cntrl:]]{0,240})[0-9]+[[:space:]]*(个|条|张|份)[^[:cntrl:]]{0,240}(S[e]ries|切[片]|对[象]|附[件]|报[告]|草[稿]|检[查]))|((Finder 核对|实际点击)[^[:cntrl:]]{0,240}[0-9]+([.][0-9]+)?[[:space:]]*(个|份|MB|MiB|GiB)[^[:cntrl:]]{0,240}(恢[复]点|[.]kinloguebackup))'

if /usr/bin/grep -a -E -q -- "$CREDENTIAL_PATTERN" "$OBJECT_STREAM"; then
  fail "a private key or common credential pattern exists in reachable history"
else
  SCAN_STATUS=$?
  [[ "$SCAN_STATUS" -eq 1 ]] \
    || fail "the credential history audit could not be completed"
fi

if /usr/bin/grep -a -E -q -- "$PRIVATE_INVENTORY_PATTERN" "$OBJECT_STREAM"; then
  fail "exact private-library inventory or interaction evidence exists in reachable history"
else
  SCAN_STATUS=$?
  [[ "$SCAN_STATUS" -eq 1 ]] \
    || fail "the private-library evidence history audit could not be completed"
fi

if [[ -n ${KINLOGUE_FORBIDDEN_VALUES:-} ]]; then
  while IFS= read -r forbidden_value; do
    [[ -n "$forbidden_value" ]] || continue
    if /usr/bin/grep -a -F -q -- "$forbidden_value" "$OBJECT_STREAM"; then
      fail "an externally supplied forbidden value found in reachable history"
    else
      SCAN_STATUS=$?
      [[ "$SCAN_STATUS" -eq 1 ]] \
        || fail "an externally supplied forbidden value history audit could not be completed"
    fi
  done <<< "$KINLOGUE_FORBIDDEN_VALUES"
fi

echo "Privacy history guard passed"
