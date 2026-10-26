#!/bin/zsh
set -euo pipefail
umask 077

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
DIST_DIR="$REPO_DIR/dist"
OUTPUT_DIR="$DIST_DIR/GoPreview"
APP_BUNDLE="$OUTPUT_DIR/KinlogueGoPreview.app"
SOURCE_DIR="$REPO_DIR/packaging/go-preview"
STAGING=""

fail() { print -u2 -- "Go preview build failed: $1"; exit 1; }
[[ "$#" -eq 0 ]] || fail "usage: build-go-preview.sh"

# This builder owns only its private GoPreview directory, never the Swift app.
if [[ -e "$DIST_DIR" || -L "$DIST_DIR" ]]; then
  [[ -d "$DIST_DIR" && ! -L "$DIST_DIR" ]] || fail "dist must be a real directory"
else
  /bin/mkdir "$DIST_DIR"
fi
[[ "$(/usr/bin/stat -f '%u' "$DIST_DIR")" == "$EUID" ]] || fail "dist has another owner"
if [[ -e "$OUTPUT_DIR" || -L "$OUTPUT_DIR" ]]; then
  [[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || fail "preview output must be a real directory"
else
  /bin/mkdir -m 700 "$OUTPUT_DIR"
  print -r -- 'kinlogue-go-preview-v1' > "$OUTPUT_DIR/.kinlogue-go-preview-owner"
fi
OWNER_FILE="$OUTPUT_DIR/.kinlogue-go-preview-owner"
[[ "$(/usr/bin/stat -f '%u:%Lp' "$OUTPUT_DIR")" == "$EUID:700" \
    && -f "$OWNER_FILE" && ! -L "$OWNER_FILE" \
    && "$(/usr/bin/stat -f '%u:%l' "$OWNER_FILE")" == "$EUID:1" \
    && "$(/bin/cat "$OWNER_FILE")" == 'kinlogue-go-preview-v1' ]] \
  || fail "preview directory is not owned by this builder"
LOCK_DIR="$OUTPUT_DIR/.build-lock"
/bin/mkdir -m 700 "$LOCK_DIR" 2>/dev/null \
  || fail "another build owns the preview directory (a killed build may leave .build-lock)"
cleanup() {
  if [[ -n "$STAGING" && -d "$STAGING" && ! -L "$STAGING" \
      && "${STAGING:h}" == "$OUTPUT_DIR" && "${STAGING:t}" == .build.* \
      && "$(/usr/bin/stat -f '%u' "$STAGING")" == "$EUID" ]]; then
    /bin/rm -rf -- "$STAGING"
  fi
  /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
if [[ -e "$APP_BUNDLE" || -L "$APP_BUNDLE" ]]; then
  [[ -d "$APP_BUNDLE" && ! -L "$APP_BUNDLE" ]] || fail "app target must be a real directory"
fi

# Capture setup-go's toolcache compiler before limiting command lookup. Keep it
# as one quoted executable path when invoking the nested verifier, never eval.
GO_EXECUTABLE="$(whence -p go)" || fail "Go is unavailable"
GO_EXECUTABLE=${GO_EXECUTABLE:A}
[[ -f "$GO_EXECUTABLE" && -x "$GO_EXECUTABLE" ]] || fail "Go is unavailable"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export GOTOOLCHAIN=local GOWORK=off GOENV=off GOFLAGS='-mod=readonly' CGO_ENABLED=0 GOOS=darwin
unset GOEXPERIMENT
case "$(/usr/bin/uname -m)" in
  arm64) export GOARCH=arm64 ;;
  x86_64) export GOARCH=amd64 ;;
  *) fail "unsupported build host architecture" ;;
esac
[[ "$("$GO_EXECUTABLE" version)" == "go version go1.27.3 darwin/$GOARCH" ]] \
  || fail "Go 1.27.3 is required"
if [[ -d "$APP_BUNDLE" ]]; then
  # Only this preservation check accepts the earlier read-only permission set.
  /bin/zsh "$SCRIPT_DIR/verify-go-preview.sh" --previous --go "$GO_EXECUTABLE" >/dev/null \
    || fail "existing preview app did not pass verification"
fi
for name in Info.plist Entitlements.plist en.lproj/InfoPlist.strings zh-Hans.lproj/InfoPlist.strings; do
  [[ -f "$SOURCE_DIR/$name" && ! -L "$SOURCE_DIR/$name" ]] || fail "packaging source is missing or linked"
done
[[ -f "$REPO_DIR/LICENSE" && ! -L "$REPO_DIR/LICENSE" ]] || fail "project license is missing or linked"
STAGING="$(/usr/bin/mktemp -d "$OUTPUT_DIR/.build.XXXXXX")"
STAGED_APP="$STAGING/KinlogueGoPreview.app"
RESOURCES="$STAGED_APP/Contents/Resources"
/bin/mkdir -p "$STAGED_APP/Contents/MacOS" "$RESOURCES/en.lproj" "$RESOURCES/zh-Hans.lproj" "$RESOURCES/ThirdPartyLicenses"
cd "$REPO_DIR"
REPLACEMENTS="$("$GO_EXECUTABLE" list -mod=readonly -m -f '{{if .Replace}}{{.Path}} {{.Version}} => {{.Replace.Path}} {{.Replace.Version}}{{end}}' all | /usr/bin/sed '/^$/d')"
[[ -z "$REPLACEMENTS" ]] \
  || fail "module replacements differ from the preview contract"
"$GO_EXECUTABLE" build -mod=readonly -trimpath -buildvcs=false -tags mygo_noinspector \
  -ldflags '-s -w' -o "$STAGED_APP/Contents/MacOS/KinlogueGoPreview" ./cmd/kinlogue
/bin/cp "$SOURCE_DIR/Info.plist" "$STAGED_APP/Contents/Info.plist"
/bin/cp "$SOURCE_DIR/en.lproj/InfoPlist.strings" "$RESOURCES/en.lproj/InfoPlist.strings"
/bin/cp "$SOURCE_DIR/zh-Hans.lproj/InfoPlist.strings" "$RESOURCES/zh-Hans.lproj/InfoPlist.strings"
/bin/cp "$REPO_DIR/LICENSE" "$RESOURCES/LICENSE"

# Copy the licenses of modules actually linked into this binary. The complete
# build information records pinned upstream versions and module checksums,
# without absolute workstation paths.
"$GO_EXECUTABLE" version -m "$STAGED_APP/Contents/MacOS/KinlogueGoPreview" \
  | /usr/bin/sed '1d' > "$RESOURCES/BUILD_INFO.txt"
while IFS=$'\t' read -r module_path module_version; do
  module_dir="$("$GO_EXECUTABLE" list -mod=readonly -m -f '{{if .Replace}}{{.Replace.Dir}}{{else}}{{.Dir}}{{end}}' "$module_path")"
  [[ -d "$module_dir" && "$module_version" == v* ]] || fail "dependency metadata is unavailable"
  license_source=''
  for candidate in LICENSE LICENSE.txt LICENSE.md COPYING; do
    if [[ -f "$module_dir/$candidate" && ! -L "$module_dir/$candidate" ]]; then
      license_source="$module_dir/$candidate"
      break
    fi
  done
  [[ -n "$license_source" ]] || fail "a dependency license is unavailable"
  license_name="${module_path//\//_}@$module_version.txt"
  /bin/cp "$license_source" "$RESOURCES/ThirdPartyLicenses/$license_name"
done < <(/usr/bin/awk -F '\t' '$2 == "dep" { print $3 "\t" $4 }' "$RESOURCES/BUILD_INFO.txt")
GO_RUNTIME_ROOT="$("$GO_EXECUTABLE" env GOROOT)"
GO_RUNTIME_LICENSE="$GO_RUNTIME_ROOT/LICENSE"
# Homebrew places the distribution license beside libexec rather than inside it.
if [[ ! -f "$GO_RUNTIME_LICENSE" && "${GO_RUNTIME_ROOT:t}" == libexec ]]; then
  GO_RUNTIME_LICENSE="${GO_RUNTIME_ROOT:h}/LICENSE"
fi
[[ -f "$GO_RUNTIME_LICENSE" && ! -L "$GO_RUNTIME_LICENSE" ]] || fail "Go runtime license is unavailable"
/bin/cp "$GO_RUNTIME_LICENSE" "$RESOURCES/ThirdPartyLicenses/go1.27.3.txt"
/bin/chmod 755 "$STAGED_APP/Contents/MacOS/KinlogueGoPreview"
/usr/bin/codesign --force --sign - --entitlements "$SOURCE_DIR/Entitlements.plist" "$STAGED_APP" 2>/dev/null
/bin/zsh "$SCRIPT_DIR/verify-go-preview.sh" --bundle "$STAGED_APP" --go "$GO_EXECUTABLE"

# Publish only a verified app; retain an earlier generated build for recovery.
if [[ -e "$APP_BUNDLE" || -L "$APP_BUNDLE" ]]; then
  /bin/zsh "$SCRIPT_DIR/verify-go-preview.sh" --previous --go "$GO_EXECUTABLE" >/dev/null \
    || fail "existing app changed during the build"
  PREVIOUS_DIR="$(/usr/bin/mktemp -d "$OUTPUT_DIR/Previous.XXXXXX")"
  /bin/mv "$APP_BUNDLE" "$PREVIOUS_DIR/KinlogueGoPreview.app"
  if ! /bin/mv "$STAGED_APP" "$APP_BUNDLE"; then
    /bin/mv "$PREVIOUS_DIR/KinlogueGoPreview.app" "$APP_BUNDLE"
    fail "new app could not be published; earlier app restored"
  fi
else
  /bin/mv "$STAGED_APP" "$APP_BUNDLE"
fi
print -- 'Built dist/GoPreview/KinlogueGoPreview.app (local ad-hoc preview).'
