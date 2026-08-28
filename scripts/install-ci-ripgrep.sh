#!/bin/zsh
set -euo pipefail

umask 077

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
RIPGREP_VERSION="14.1.1"
ARCHIVE_NAME="ripgrep-${RIPGREP_VERSION}-aarch64-apple-darwin.tar.gz"
ARCHIVE_SHA256="24ad76777745fbff131c8fbc466742b011f925bfa4fffa2ded6def23b5b937be"
DOWNLOAD_URL="https://github.com/BurntSushi/ripgrep/releases/download/${RIPGREP_VERSION}/${ARCHIVE_NAME}"
TOOL_DIRECTORY="$REPO_DIR/.build/ci-tools/bin"
RIPGREP_BIN="$TOOL_DIRECTORY/rg"
TEMP_ROOT=""

fail() {
  /usr/bin/printf 'CI tool bootstrap failed: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TEMP_ROOT:-}" && -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" \
      && "${TEMP_ROOT:h}" == /private/tmp \
      && "${TEMP_ROOT:t}" == kinlogue-ci-tools.* ]]; then
    /bin/rm -rf -- "$TEMP_ROOT"
  fi
}
trap cleanup EXIT INT TERM HUP

[[ "$(/usr/bin/uname -m)" == arm64 ]] \
  || fail "the pinned archive only supports Apple Silicon"

if [[ -e "$RIPGREP_BIN" || -L "$RIPGREP_BIN" ]]; then
  [[ -f "$RIPGREP_BIN" && ! -L "$RIPGREP_BIN" && -x "$RIPGREP_BIN" ]] \
    || fail "the existing ripgrep executable was not a private regular file"
  "$RIPGREP_BIN" --version 2>/dev/null \
    | /usr/bin/grep -Eq \
      "^ripgrep ${RIPGREP_VERSION//./\\.} \(rev [0-9a-f]{10,40}\)$" \
    || fail "the existing ripgrep version did not match"
fi

TEMP_ROOT="$(/usr/bin/mktemp -d \
  /private/tmp/kinlogue-ci-tools.XXXXXXXX)" \
  || fail "the private download directory could not be created"
ARCHIVE_PATH="$TEMP_ROOT/$ARCHIVE_NAME"

/usr/bin/curl \
  --fail \
  --location \
  --proto '=https' \
  --tlsv1.2 \
  --output "$ARCHIVE_PATH" \
  "$DOWNLOAD_URL" \
  >/dev/null 2>&1 \
  || fail "the pinned ripgrep archive could not be downloaded"

ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "$ARCHIVE_PATH" \
  2>/dev/null | /usr/bin/awk '{print $1}')"
[[ "$ACTUAL_SHA256" == "$ARCHIVE_SHA256" ]] \
  || fail "the pinned ripgrep archive digest did not match"

/usr/bin/tar -xzf "$ARCHIVE_PATH" -C "$TEMP_ROOT" \
  >/dev/null 2>&1 \
  || fail "the pinned ripgrep archive could not be extracted"
EXTRACTED_BIN="$TEMP_ROOT/ripgrep-${RIPGREP_VERSION}-aarch64-apple-darwin/rg"
[[ -f "$EXTRACTED_BIN" && ! -L "$EXTRACTED_BIN" ]] \
  || fail "the pinned ripgrep executable was missing or linked"

/bin/mkdir -p "$TOOL_DIRECTORY" \
  || fail "the CI tool directory could not be created"
/bin/cp "$EXTRACTED_BIN" "$RIPGREP_BIN" \
  || fail "the pinned ripgrep executable could not be installed"
/bin/chmod 700 "$RIPGREP_BIN" \
  || fail "the pinned ripgrep executable could not be made private"

"$RIPGREP_BIN" --version \
  | /usr/bin/grep -Eq \
    "^ripgrep ${RIPGREP_VERSION//./\\.} \(rev [0-9a-f]{10,40}\)$" \
  || fail "the installed ripgrep version did not match"

/usr/bin/printf 'Installed ripgrep %s with verified SHA-256\n' \
  "$RIPGREP_VERSION"
