#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
CATALOG="$REPO_DIR/Sources/KinlogueApp/Localization/Localizable.xcstrings"
RESOURCE_ROOT="$REPO_DIR/Sources/KinlogueApp/Resources"
ENGLISH_ROOT="$RESOURCE_ROOT/en.lproj"
MODE="${1:---check}"
TEMP_DIRECTORY=""

fail() {
  echo "Localization compilation failed: $1" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TEMP_DIRECTORY:-}" \
      && -d "$TEMP_DIRECTORY" && ! -L "$TEMP_DIRECTORY" \
      && "${TEMP_DIRECTORY:h}" == /private/tmp \
      && "${TEMP_DIRECTORY:t}" == kinlogue-localizations.* ]]; then
    /bin/rm -rf -- "$TEMP_DIRECTORY"
  fi
}
trap cleanup EXIT INT TERM HUP

case "$MODE" in
  --check|--write) ;;
  *) fail "usage: compile-localizations.sh [--check|--write]" ;;
esac

[[ -f "$CATALOG" && ! -L "$CATALOG" ]] \
  || fail "the string catalog is missing or linked"
[[ -d "$ENGLISH_ROOT" && ! -L "$ENGLISH_ROOT" ]] \
  || fail "the English resource directory is missing or linked"

TEMP_DIRECTORY="$(/usr/bin/mktemp -d /private/tmp/kinlogue-localizations.XXXXXX)" \
  || fail "a private temporary directory could not be created"
[[ "$(/usr/bin/stat -f '%u' "$TEMP_DIRECTORY")" == "$EUID" \
    && "$(/usr/bin/stat -f '%Lp' "$TEMP_DIRECTORY")" == 700 ]] \
  || fail "the temporary directory is not private to the current user"

/usr/bin/xcrun xcstringstool compile "$CATALOG" \
  --output-directory "$TEMP_DIRECTORY" \
  || fail "xcstringstool could not compile the catalog"

for resource in Localizable.strings Localizable.stringsdict; do
  generated="$TEMP_DIRECTORY/en.lproj/$resource"
  committed="$ENGLISH_ROOT/$resource"
  [[ -f "$generated" && ! -L "$generated" ]] \
    || fail "xcstringstool did not produce en.lproj/$resource"
  if [[ "$MODE" == --write ]]; then
    /bin/cp -- "$generated" "$committed"
  else
    [[ -f "$committed" && ! -L "$committed" ]] \
      || fail "the committed en.lproj/$resource is missing or linked"
    /usr/bin/cmp -s "$generated" "$committed" \
      || fail "en.lproj/$resource is stale; run scripts/compile-localizations.sh --write"
  fi
done

echo "Localization resources are $([[ "$MODE" == --write ]] && echo updated || echo current)"
