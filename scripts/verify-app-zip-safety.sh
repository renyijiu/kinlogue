#!/bin/zsh
set -euo pipefail

umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

fail() {
  echo "App ZIP safety verification failed: $1" >&2
  exit 1
}

[[ "$#" -eq 1 && "$1" == /* ]] \
  || fail "usage: verify-app-zip-safety.sh /absolute/path/Kinlogue.app.zip"

APP_ARCHIVE="$1"
[[ -f "$APP_ARCHIVE" && ! -L "$APP_ARCHIVE" ]] \
  || fail "the app archive must be a real regular file"

TEMP_DIRECTORY="$(/usr/bin/mktemp -d /private/tmp/kinlogue-zip-safety.XXXXXX)" \
  || fail "a private inspection directory could not be created"

cleanup() {
  [[ -d "${TEMP_DIRECTORY:-}" && ! -L "${TEMP_DIRECTORY:-}" \
      && "${TEMP_DIRECTORY:t}" == kinlogue-zip-safety.* \
      && "${TEMP_DIRECTORY:h}" == /private/tmp ]] \
    && /bin/rm -rf -- "$TEMP_DIRECTORY"
}
trap cleanup EXIT INT TERM HUP

ENTRY_LIST="$TEMP_DIRECTORY/entries.txt"
TYPE_LIST="$TEMP_DIRECTORY/types.txt"
/usr/bin/zipinfo -1 "$APP_ARCHIVE" >"$ENTRY_LIST" \
  || fail "the app archive central directory could not be read"
/usr/bin/zipinfo -l "$APP_ARCHIVE" \
  | /usr/bin/awk '
      /^[d-][rwxStTs-]{9}[[:space:]]/ {
        print substr($1, 1, 1) "\t" $NF
      }
    ' >"$TYPE_LIST" \
  || fail "the app archive entry types could not be read"

ENTRY_COUNT="$(/usr/bin/wc -l <"$ENTRY_LIST" | /usr/bin/awk '{print $1}')"
TYPE_COUNT="$(/usr/bin/wc -l <"$TYPE_LIST" | /usr/bin/awk '{print $1}')"
[[ "$ENTRY_COUNT" -gt 0 && "$ENTRY_COUNT" -eq "$TYPE_COUNT" ]] \
  || fail "the app archive entry list is empty or ambiguous"

typeset -A SEEN_PATHS
typeset -A ENTRY_TYPES
index=1
while IFS= read -r entry; do
  [[ -n "$entry" && "$entry" =~ '^[A-Za-z0-9._/-]+$' ]] \
    || fail "an app archive entry has an unsupported or ambiguous name"
  [[ "$entry" == "Kinlogue.app" || "$entry" == "Kinlogue.app/" \
      || "$entry" == Kinlogue.app/* ]] \
    || fail "the app archive contains an entry outside Kinlogue.app"
  [[ "$entry" != /* && "$entry" != *'\\'* && "$entry" != *//* \
      && ! "$entry" =~ '(^|/)\.\.?(/|$)' ]] \
    || fail "the app archive contains an unsafe path"

  normalized="${entry%/}"
  folded="${(L)normalized}"
  [[ -z "${SEEN_PATHS[$folded]-}" ]] \
    || fail "the app archive contains a duplicate or case-folding path conflict"
  SEEN_PATHS[$folded]=1

  type_line="$(/usr/bin/sed -n "${index}p" "$TYPE_LIST")"
  entry_type="${type_line%%$'\t'*}"
  typed_entry="${type_line#*$'\t'}"
  [[ "$typed_entry" == "$entry" ]] \
    || fail "the app archive central directory could not be correlated safely"
  if [[ "$entry" == */ ]]; then
    [[ "$entry_type" == d ]] \
      || fail "a directory-named app archive entry is not a directory"
  else
    [[ "$entry_type" == - ]] \
      || fail "the app archive contains a non-regular entry"
  fi
  ENTRY_TYPES[$folded]="$entry_type"
  index=$((index + 1))
done <"$ENTRY_LIST"

[[ "${ENTRY_TYPES[kinlogue.app]-}" == d ]] \
  || fail "the app archive root must be an explicit directory"
for candidate in "${(k)ENTRY_TYPES[@]}"; do
  [[ "${ENTRY_TYPES[$candidate]}" == - ]] || continue
  for descendant in "${(k)ENTRY_TYPES[@]}"; do
    if [[ "$descendant" == "$candidate"/* ]]; then
      fail "the app archive contains a file/descendant path conflict"
    fi
  done
done

echo "App ZIP safety verification passed"
