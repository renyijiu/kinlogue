#!/bin/zsh
set -u
setopt pipefail
umask 077
exec 2>/dev/null

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
RG_BIN="$(command -v rg 2>/dev/null)"

emit_result() {
  local code="$1"
  local ok="$2"
  local count="$3"
  local digest="$4"
  /usr/bin/printf \
    '{"code":"%s","count":%d,"ok":%s,"summarySHA256":"%s"}\n' \
    "$code" "$count" "$ok" "$digest"
}

zero_digest() {
  /usr/bin/printf '%064d' 0
}

if [[ $# -ne 1 ]]; then
  emit_result "KLA_SCAN_INVALID" false 1 "$(zero_digest)"
  exit 64
fi
if [[ -z "$RG_BIN" || ! -x "$RG_BIN" ]]; then
  emit_result "KLA_SCAN_ERROR" false 1 "$(zero_digest)"
  exit 70
fi

RUN_ID="$1"
if ! /usr/bin/printf '%s\n' "$RUN_ID" \
  | /usr/bin/grep -Eq '^[0-9a-f]{24,32}$'; then
  emit_result "KLA_SCAN_INVALID" false 1 "$(zero_digest)"
  exit 64
fi

USER_HOME_DIRECTORY="${HOME:-}"
CURRENT_UID="$(/usr/bin/id -u 2>/dev/null)"
CURRENT_USER="$(/usr/bin/id -un 2>/dev/null)"
PASSWD_HOME_DIRECTORY="$(/usr/bin/id -P "$CURRENT_USER" 2>/dev/null \
  | /usr/bin/awk -F: -v expected_uid="$CURRENT_UID" \
      '$3 == expected_uid { print $9; exit }')"
if [[ -z "$CURRENT_UID" || -z "$CURRENT_USER" \
    || -z "$PASSWD_HOME_DIRECTORY" \
    || "$USER_HOME_DIRECTORY" != "$PASSWD_HOME_DIRECTORY" \
    || "$USER_HOME_DIRECTORY" != /* \
    || "$USER_HOME_DIRECTORY" == "/" \
    || ! -d "$USER_HOME_DIRECTORY" \
    || -L "$USER_HOME_DIRECTORY" ]]; then
  emit_result "KLA_SCAN_ERROR" false 1 "$(zero_digest)"
  exit 70
fi

INTERNAL_SCAN_TEST_ROOT="${KINLOGUE_ACCEPTANCE_INTERNAL_SCAN_TEST_ROOT:-}"
SCAN_REPO_DIR="$REPO_DIR"
if [[ -n "$INTERNAL_SCAN_TEST_ROOT" ]]; then
  if ! /usr/bin/printf '%s\n' "$INTERNAL_SCAN_TEST_ROOT" \
      | /usr/bin/grep -Eq \
        '^/private/tmp/kinlogue-acceptance-scan-test\.[0-9A-Za-z-]{8,80}$' \
    || [[ ! -d "$INTERNAL_SCAN_TEST_ROOT" \
        || -L "$INTERNAL_SCAN_TEST_ROOT" \
        || "$(/usr/bin/stat -f '%u:%Lp' \
          "$INTERNAL_SCAN_TEST_ROOT" 2>/dev/null)" != "$CURRENT_UID:700" ]]; then
    emit_result "KLA_SCAN_ERROR" false 1 "$(zero_digest)"
    exit 70
  fi
  INTERNAL_SCAN_TEST_REPOSITORY="$INTERNAL_SCAN_TEST_ROOT/Repository"
  if [[ ! -d "$INTERNAL_SCAN_TEST_REPOSITORY" \
      || -L "$INTERNAL_SCAN_TEST_REPOSITORY" \
      || "$(/usr/bin/stat -f '%u:%Lp' \
        "$INTERNAL_SCAN_TEST_REPOSITORY" 2>/dev/null)" != "$CURRENT_UID:700" ]]; then
    emit_result "KLA_SCAN_ERROR" false 1 "$(zero_digest)"
    exit 70
  fi
  SCAN_REPO_DIR="$INTERNAL_SCAN_TEST_REPOSITORY"
fi

PRIVACY_HOME_DIRECTORY="$USER_HOME_DIRECTORY"
INTERNAL_SCAN_TEST_HOME="${KINLOGUE_ACCEPTANCE_INTERNAL_SCAN_TEST_HOME:-}"
if [[ -n "$INTERNAL_SCAN_TEST_HOME" ]]; then
  if [[ -z "$INTERNAL_SCAN_TEST_ROOT" \
      || "$INTERNAL_SCAN_TEST_HOME" \
        != "$INTERNAL_SCAN_TEST_ROOT/NonstandardHome" \
      || ! -d "$INTERNAL_SCAN_TEST_HOME" \
      || -L "$INTERNAL_SCAN_TEST_HOME" \
      || "$(/usr/bin/stat -f '%u:%Lp' \
        "$INTERNAL_SCAN_TEST_HOME" 2>/dev/null)" != "$CURRENT_UID:700" ]]; then
    emit_result "KLA_SCAN_ERROR" false 1 "$(zero_digest)"
    exit 70
  fi
  PRIVACY_HOME_DIRECTORY="$INTERNAL_SCAN_TEST_HOME"
fi

token_digest() {
  local domain="$1"
  /usr/bin/printf '%s\000%s' "$domain" "$RUN_ID" \
    | /usr/bin/shasum -a 256 \
    | /usr/bin/awk '{print $1}'
}

CANARY="KLA-$(token_digest 'kinlogue.acceptance.canary.v1')"
ORIGINAL_MAGIC="KLO-$(token_digest 'kinlogue.acceptance.original.v1')"
MEMBER_TOKEN="KLM-$(token_digest 'kinlogue.acceptance.member.v1')"
TITLE_TOKEN="KLT-$(token_digest 'kinlogue.acceptance.title.v1')"
ORGANIZATION_TOKEN="KLH-$(token_digest 'kinlogue.acceptance.organization.v1')"
DATE_SOURCE_TOKEN="KLD-$(token_digest 'kinlogue.acceptance.date-source.v1')"
CONCLUSION_TOKEN="KLC-$(token_digest 'kinlogue.acceptance.conclusion.v1')"

BUNDLE_ID="com.kinlogue.mac.acceptance.$RUN_ID"
if [[ -n "$INTERNAL_SCAN_TEST_ROOT" ]]; then
  SANDBOX_CONTAINER="$INTERNAL_SCAN_TEST_ROOT/Container"
  SANDBOX_CONTAINER_DATA="$INTERNAL_SCAN_TEST_ROOT/Data"
  SANDBOX_ROOT="$SANDBOX_CONTAINER_DATA/Library/Application Support/Kinlogue/Acceptance/$RUN_ID"
  UNCONTAINED_ROOT="$INTERNAL_SCAN_TEST_ROOT/Uncontained"
  INSTALLED_APP="$INTERNAL_SCAN_TEST_ROOT/Installed.app"
  ACCEPTANCE_TEMP_ROOT="$INTERNAL_SCAN_TEST_ROOT/Temp"
  CRASH_ROOT="$INTERNAL_SCAN_TEST_ROOT/CrashReports"
  REPORT_CANDIDATES=("$INTERNAL_SCAN_TEST_ROOT/Report.json")
else
  SANDBOX_CONTAINER="$USER_HOME_DIRECTORY/Library/Containers/$BUNDLE_ID"
  SANDBOX_CONTAINER_DATA="$SANDBOX_CONTAINER/Data"
  SANDBOX_ROOT="$SANDBOX_CONTAINER_DATA/Library/Application Support/Kinlogue/Acceptance/$RUN_ID"
  UNCONTAINED_ROOT="$USER_HOME_DIRECTORY/Library/Application Support/Kinlogue/Acceptance/$RUN_ID"
  INSTALLED_APP="$USER_HOME_DIRECTORY/Applications/Kinlogue-Acceptance-$RUN_ID.app"
  ACCEPTANCE_TEMP_ROOT="/tmp/kinlogue-acceptance.$RUN_ID"
  CRASH_ROOT="$USER_HOME_DIRECTORY/Library/Logs/DiagnosticReports"
  REPORT_CANDIDATES=(
    "$REPO_DIR"/dist/.acceptance-report-"$RUN_ID".*(N)
    "$REPO_DIR"/dist/.acceptance-verification-"$RUN_ID".*(N)
  )
fi

SCAN_ROOTS=(
  "$SCAN_REPO_DIR/Sources"
  "$SCAN_REPO_DIR/Tests"
  "$SCAN_REPO_DIR/scripts"
  "$SCAN_REPO_DIR/packaging"
  "$SCAN_REPO_DIR/docs"
  "$SCAN_REPO_DIR/.build"
  "$SCAN_REPO_DIR/dist"
  "$INSTALLED_APP"
  "$ACCEPTANCE_TEMP_ROOT"
  "$UNCONTAINED_ROOT"
)
PRIVACY_SCAN_ROOTS=(
  "$SANDBOX_CONTAINER_DATA"
  "$UNCONTAINED_ROOT"
  "$SCAN_REPO_DIR/dist/acceptance-report.json"
  "$ACCEPTANCE_TEMP_ROOT"
  "${REPORT_CANDIDATES[@]}"
)
PDF_PRIVACY_SCAN_ROOTS=(
  "$ACCEPTANCE_TEMP_ROOT"
  "$UNCONTAINED_ROOT"
  "$SCAN_REPO_DIR/dist/acceptance-report.json"
  "${REPORT_CANDIDATES[@]}"
)
SOURCE_VAULT_RELATIVE_PATH="Library/Application Support/Kinlogue/Acceptance/$RUN_ID/SourceVault"

MATCH_COUNT=0
SCAN_ERROR=false

scan_pattern_in_root() {
  local pattern="$1"
  local root="$2"
  [[ -e "$root" || -L "$root" ]] || return 0
  if [[ -L "$root" ]]; then
    SCAN_ERROR=true
    return 0
  fi
  "$RG_BIN" --hidden --no-ignore --no-messages -a -q \
    --fixed-strings -- "$pattern" "$root" \
    >/dev/null 2>&1
  local result_code=$?
  case "$result_code" in
    0) MATCH_COUNT=$((MATCH_COUNT + 1)) ;;
    1) ;;
    *) SCAN_ERROR=true ;;
  esac
}

scan_pattern_outside_source_vault() {
  local pattern="$1"
  local root="$SANDBOX_CONTAINER_DATA"
  [[ -e "$root" || -L "$root" ]] || return 0
  if [[ -L "$root" ]]; then
    SCAN_ERROR=true
    return 0
  fi
  (
    cd "$root" || exit 2
    "$RG_BIN" --hidden --no-ignore --no-messages -a -q --fixed-strings \
      --glob "!$SOURCE_VAULT_RELATIVE_PATH" \
      --glob "!$SOURCE_VAULT_RELATIVE_PATH/**" \
      -- "$pattern" . >/dev/null 2>&1
  )
  local result_code=$?
  case "$result_code" in
    0) MATCH_COUNT=$((MATCH_COUNT + 1)) ;;
    1) ;;
    *) SCAN_ERROR=true ;;
  esac
}

scan_pattern_in_app_bundle_except_executable() {
  local pattern="$1"
  local app_bundle="$2"
  [[ -e "$app_bundle" || -L "$app_bundle" ]] || return 0
  if [[ ! -d "$app_bundle" || -L "$app_bundle" ]]; then
    SCAN_ERROR=true
    return 0
  fi

  local executable="$app_bundle/Contents/MacOS/Kinlogue"
  if [[ ! -f "$executable" || -L "$executable" ]]; then
    SCAN_ERROR=true
    return 0
  fi

  local linked_path
  linked_path="$(
    /usr/bin/find "$app_bundle" -type l -print -quit 2>/dev/null
  )"
  local find_result=$?
  if [[ "$find_result" -ne 0 || -n "$linked_path" ]]; then
    SCAN_ERROR=true
    return 0
  fi

  (
    cd "$app_bundle" || exit 2
    "$RG_BIN" --hidden --no-ignore --no-messages -a -q --fixed-strings \
      --glob '!Contents/MacOS/Kinlogue' \
      -- "$pattern" . >/dev/null 2>&1
  )
  local result_code=$?
  case "$result_code" in
    0) MATCH_COUNT=$((MATCH_COUNT + 1)) ;;
    1) ;;
    *) SCAN_ERROR=true ;;
  esac
}

validate_source_vault_path() {
  local current="$SANDBOX_CONTAINER_DATA"
  local component
  local require_complete=false
  [[ -z "$INTERNAL_SCAN_TEST_ROOT" ]] && require_complete=true

  if [[ -L "$current" || (-e "$current" && ! -d "$current") ]]; then
    SCAN_ERROR=true
    return
  fi
  if [[ ! -e "$current" ]]; then
    [[ "$require_complete" == true ]] && SCAN_ERROR=true
    return
  fi
  for component in \
      Library \
      "Application Support" \
      Kinlogue \
      Acceptance \
      "$RUN_ID" \
      SourceVault; do
    current="$current/$component"
    if [[ -L "$current" || (-e "$current" && ! -d "$current") ]]; then
      SCAN_ERROR=true
      return
    fi
    if [[ ! -e "$current" ]]; then
      [[ "$require_complete" == true ]] && SCAN_ERROR=true
      return
    fi
  done
}

validate_managed_run_tree_symlinks() {
  local root="$SANDBOX_ROOT"
  [[ -e "$root" || -L "$root" ]] || return 0
  if [[ ! -d "$root" || -L "$root" ]]; then
    SCAN_ERROR=true
    return 0
  fi

  local linked_path
  linked_path="$(
    (
      cd "$root" || exit 2
      /usr/bin/find -P . \
        -path './SourceVault' -prune \
        -o -type l -print -quit
    ) 2>/dev/null
  )"
  local find_result=$?
  if [[ "$find_result" -ne 0 || -n "$linked_path" ]]; then
    SCAN_ERROR=true
  fi
}

scan_pattern_in_required_file() {
  local pattern="$1"
  local file="$2"
  if [[ ! -f "$file" || -L "$file" ]]; then
    SCAN_ERROR=true
    return 0
  fi
  "$RG_BIN" --no-ignore --no-messages -a -q \
    --fixed-strings -- "$pattern" "$file" \
    >/dev/null 2>&1
  local result_code=$?
  case "$result_code" in
    0) MATCH_COUNT=$((MATCH_COUNT + 1)) ;;
    1) ;;
    *) SCAN_ERROR=true ;;
  esac
}

PATTERNS=(
  "$CANARY"
  "$ORIGINAL_MAGIC"
  "$MEMBER_TOKEN"
  "$TITLE_TOKEN"
  "$ORGANIZATION_TOKEN"
  "$DATE_SOURCE_TOKEN"
  "$CONCLUSION_TOKEN"
)

validate_source_vault_path
validate_managed_run_tree_symlinks

for pattern in "${PATTERNS[@]}"; do
  for root in "${SCAN_ROOTS[@]}"; do
    scan_pattern_in_root "$pattern" "$root"
  done
  scan_pattern_outside_source_vault "$pattern"
done

# Synthetic records and PDF originals are expected inside SourceVault because
# the current MVP deliberately stores them as plaintext. Their run-specific
# canaries must not escape that exact vault directory into the rest of the
# container, the uncontained fallback path, the app, reports, temp artifacts,
# or matching crash reports. Absolute user paths remain forbidden everywhere,
# including SourceVault.
PDF_HEADER_PATTERN='%PDF-'
ABSOLUTE_USER_PATH_PREFIX="$PRIVACY_HOME_DIRECTORY/"
scan_pattern_outside_source_vault "$PDF_HEADER_PATTERN"
for root in "${PDF_PRIVACY_SCAN_ROOTS[@]}"; do
  scan_pattern_in_root "$PDF_HEADER_PATTERN" "$root"
done
scan_pattern_in_app_bundle_except_executable \
  "$PDF_HEADER_PATTERN" "$INSTALLED_APP"
scan_pattern_in_app_bundle_except_executable \
  "$PDF_HEADER_PATTERN" "$SCAN_REPO_DIR/dist/Kinlogue.app"
for root in "${PRIVACY_SCAN_ROOTS[@]}"; do
  scan_pattern_in_root "$ABSOLUTE_USER_PATH_PREFIX" "$root"
done

if [[ -d "$CRASH_ROOT" && ! -L "$CRASH_ROOT" ]]; then
  CRASH_LIST=()
  crash_root_identity_before="$(
    /usr/bin/stat -f '%d:%i' "$CRASH_ROOT" 2>/dev/null
  )"
  SCANNER_TEMP_ROOT="$(
    /usr/bin/mktemp -d "/tmp/kinlogue-acceptance-scan.$RUN_ID.XXXXXXXX" \
      2>/dev/null
  )"
  temp_create_result=$?
  CRASH_MANIFEST="${SCANNER_TEMP_ROOT:-}/crash-files.nul"
  cleanup_scanner_temp() {
    if [[ -n "${SCANNER_TEMP_ROOT:-}" ]]; then
      /bin/rm -f -- "${CRASH_MANIFEST:-}" >/dev/null 2>&1 || true
      /bin/rmdir -- "$SCANNER_TEMP_ROOT" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup_scanner_temp EXIT
  trap 'cleanup_scanner_temp; exit 130' INT
  trap 'cleanup_scanner_temp; exit 143' TERM
  trap 'cleanup_scanner_temp; exit 129' HUP

  current_uid="$(/usr/bin/id -u 2>/dev/null)"
  temp_uid="$(/usr/bin/stat -f '%u' "$SCANNER_TEMP_ROOT" 2>/dev/null)"
  if [[ "$temp_create_result" -ne 0 \
      || -z "$SCANNER_TEMP_ROOT" \
      || ! -d "$SCANNER_TEMP_ROOT" \
      || -L "$SCANNER_TEMP_ROOT" \
      || -z "$current_uid" \
      || "$temp_uid" != "$current_uid" \
      || -z "$crash_root_identity_before" ]] \
      || ! /bin/chmod 700 "$SCANNER_TEMP_ROOT" >/dev/null 2>&1; then
    SCAN_ERROR=true
  elif ! /usr/bin/find "$CRASH_ROOT" -type f -name '*Kinlogue*' -print0 \
      >"$CRASH_MANIFEST" 2>/dev/null; then
    SCAN_ERROR=true
  else
    crash_root_identity_after="$(
      /usr/bin/stat -f '%d:%i' "$CRASH_ROOT" 2>/dev/null
    )"
    load_crash_list() {
      local manifest_fd crash_file crash_read_result crash_filter_result
      exec {manifest_fd}<"$CRASH_MANIFEST" 2>/dev/null || return 1
      while true; do
        crash_file=""
        IFS= read -r -d $'\0' -u "$manifest_fd" crash_file 2>/dev/null
        crash_read_result=$?
        if [[ "$crash_read_result" -eq 1 && -z "$crash_file" ]]; then
          break
        fi
        if [[ "$crash_read_result" -ne 0 || -z "$crash_file" ]]; then
          exec {manifest_fd}<&- 2>/dev/null || true
          return 1
        fi
        if [[ ! -f "$crash_file" || -L "$crash_file" ]]; then
          exec {manifest_fd}<&- 2>/dev/null || true
          return 1
        fi
        "$RG_BIN" --no-ignore --no-messages -a -q --fixed-strings -- \
          "$BUNDLE_ID" "$crash_file" >/dev/null 2>&1
        crash_filter_result=$?
        case "$crash_filter_result" in
          0) CRASH_LIST+=("$crash_file") ;;
          1) ;;
          *)
            exec {manifest_fd}<&- 2>/dev/null || true
            return 1
            ;;
        esac
      done
      exec {manifest_fd}<&- 2>/dev/null || return 1
      return 0
    }

    if [[ -z "$crash_root_identity_after" \
        || "$crash_root_identity_after" != "$crash_root_identity_before" \
        || ! -d "$CRASH_ROOT" \
        || -L "$CRASH_ROOT" ]]; then
      SCAN_ERROR=true
    elif ! load_crash_list 2>/dev/null; then
      SCAN_ERROR=true
    else
      for pattern in "${PATTERNS[@]}"; do
        for crash_file in "${CRASH_LIST[@]}"; do
          scan_pattern_in_required_file "$pattern" "$crash_file"
        done
      done
      for crash_file in "${CRASH_LIST[@]}"; do
        scan_pattern_in_required_file "$PDF_HEADER_PATTERN" "$crash_file"
        scan_pattern_in_required_file "$ABSOLUTE_USER_PATH_PREFIX" "$crash_file"
      done
    fi
  fi
elif [[ -e "$CRASH_ROOT" || -L "$CRASH_ROOT" ]]; then
  SCAN_ERROR=true
fi

SCAN_DIGEST="$(
  /usr/bin/printf '%s\000%s\000%s\000%s\000%s\000%s\000%s' \
      "$CANARY" "$ORIGINAL_MAGIC" "$MEMBER_TOKEN" "$TITLE_TOKEN" \
      "$ORGANIZATION_TOKEN" "$DATE_SOURCE_TOKEN" "$CONCLUSION_TOKEN" \
    | /usr/bin/shasum -a 256 \
    | /usr/bin/awk '{print $1}'
)"

if [[ "$SCAN_ERROR" == true ]]; then
  emit_result "KLA_SCAN_ERROR" false $((MATCH_COUNT + 1)) "$SCAN_DIGEST"
  exit 70
fi
if [[ "$MATCH_COUNT" -ne 0 ]]; then
  emit_result "KLA_SCAN_MATCH" false "$MATCH_COUNT" "$SCAN_DIGEST"
  exit 1
fi

emit_result "KLA_SCAN_COMPLETE" true 0 "$SCAN_DIGEST"
