#!/bin/zsh
set -euo pipefail
umask 077

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
OUTPUT_DIR="$REPO_DIR/dist/GoPreview"
SOURCE_DIR="$REPO_DIR/packaging/go-preview"
APP_BUNDLE="$OUTPUT_DIR/KinlogueGoPreview.app"
PREVIOUS=0
GO_EXECUTABLE=''
fail() { print -u2 -- "Go preview verification failed: $1"; exit 1; }
if [[ "$#" -gt 0 && "$1" == --previous ]]; then
  PREVIOUS=1
  shift
elif [[ "$#" -ge 2 && "$1" == --bundle ]]; then
  APP_BUNDLE="$2"
  [[ "${APP_BUNDLE:t}" == KinlogueGoPreview.app \
      && "${APP_BUNDLE:h:h}" == "$OUTPUT_DIR" \
      && "${APP_BUNDLE:h:t}" == .build.* ]] || fail "only private build staging may be verified"
  shift 2
fi
if [[ "$#" -eq 2 && "$1" == --go ]]; then
  GO_EXECUTABLE="$2"
  [[ "$GO_EXECUTABLE" == /* ]] || fail "Go executable must be an absolute path"
  shift 2
fi
[[ "$#" -eq 0 ]] || fail "usage: verify-go-preview.sh [--previous | --bundle staging-app] [--go absolute-executable]"
[[ -d "$REPO_DIR/dist" && ! -L "$REPO_DIR/dist" \
    && -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" \
    && -d "${APP_BUNDLE:h}" && ! -L "${APP_BUNDLE:h}" \
    && -d "$APP_BUNDLE" && ! -L "$APP_BUNDLE" ]] || fail "preview bundle is missing or linked"
[[ -z "$(/usr/bin/find "$APP_BUNDLE" -type l -print -quit)" ]] || fail "bundle contains a symbolic link"
[[ -z "$(/usr/bin/find "$APP_BUNDLE" ! -type d ! -type f -print -quit)" ]] || fail "bundle contains a special file"
INFO="$APP_BUNDLE/Contents/Info.plist"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/KinlogueGoPreview"
RESOURCES="$APP_BUNDLE/Contents/Resources"
[[ -f "$INFO" && -f "$EXECUTABLE" && -x "$EXECUTABLE" ]] || fail "bundle entry points are missing"
/usr/bin/cmp -s "$INFO" "$SOURCE_DIR/Info.plist" || fail "bundle metadata differs from the preview contract"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$INFO")" == com.kinlogue.mac.gopreview \
    && "$(/usr/bin/plutil -extract CFBundleExecutable raw "$INFO")" == KinlogueGoPreview \
    && "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$INFO")" == 14.0 ]] || fail "bundle identity or minimum system is incorrect"
for locale in en zh-Hans; do
  /usr/bin/cmp -s "$RESOURCES/$locale.lproj/InfoPlist.strings" "$SOURCE_DIR/$locale.lproj/InfoPlist.strings" \
    || fail "localized bundle names differ from the source"
done
/usr/bin/cmp -s "$RESOURCES/LICENSE" "$REPO_DIR/LICENSE" || fail "project license is missing or changed"
while IFS= read -r file; do
  relative=${file#"$APP_BUNDLE/"}
  case "$relative" in
    Contents/Info.plist|Contents/MacOS/KinlogueGoPreview|Contents/_CodeSignature/CodeResources|Contents/Resources/LICENSE|Contents/Resources/BUILD_INFO.txt|Contents/Resources/en.lproj/InfoPlist.strings|Contents/Resources/zh-Hans.lproj/InfoPlist.strings|Contents/Resources/ThirdPartyLicenses/*.txt) ;;
    *) fail "bundle contains an unexpected file or helper" ;;
  esac
done < <(/usr/bin/find "$APP_BUNDLE" -type f)
/usr/bin/codesign --verify --strict "$APP_BUNDLE" 2>/dev/null || fail "code signature is invalid"
SIGNATURE="$(/usr/bin/codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)"
[[ "$SIGNATURE" == *$'\nIdentifier=com.kinlogue.mac.gopreview\n'* \
    && "$SIGNATURE" == *$'\nSignature=adhoc\n'* ]] || fail "signature is not the expected local preview identity"
ENTITLEMENTS="$(/usr/bin/codesign -d --entitlements :- "$APP_BUNDLE" 2>/dev/null)" \
  || fail "signed entitlements cannot be read"
ENTITLEMENTS="$(print -r -- "$ENTITLEMENTS" | /usr/bin/plutil -convert xml1 -o - -)" \
  || fail "signed entitlements are invalid"
FILE_PERMISSION='com\.apple\.security\.files\.user-selected\.read-write'
if [[ "$PREVIOUS" -eq 1 ]] \
    && print -r -- "$ENTITLEMENTS" | /usr/bin/plutil -extract 'com\.apple\.security\.files\.user-selected\.read-only' raw -expect bool - >/dev/null 2>&1; then
  FILE_PERMISSION='com\.apple\.security\.files\.user-selected\.read-only'
fi
[[ "$(print -r -- "$ENTITLEMENTS" | /usr/bin/plutil -extract 'com\.apple\.security\.app-sandbox' raw -expect bool - 2>/dev/null)" == true \
    && "$(print -r -- "$ENTITLEMENTS" | /usr/bin/plutil -extract "$FILE_PERMISSION" raw -expect bool - 2>/dev/null)" == true \
    && "$(print -r -- "$ENTITLEMENTS" | /usr/bin/grep -c '<key>')" -eq 2 ]] \
  || fail "entitlements must be exactly sandbox and user-selected read-write"
if [[ -z "$GO_EXECUTABLE" ]]; then
  GO_EXECUTABLE="$(whence -p go)" || fail "Go is unavailable"
fi
GO_EXECUTABLE=${GO_EXECUTABLE:A}
[[ -f "$GO_EXECUTABLE" && -x "$GO_EXECUTABLE" ]] || fail "Go is unavailable"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export GOTOOLCHAIN=local GOWORK=off GOENV=off GOFLAGS='-mod=readonly'
case "$(/usr/bin/uname -m)" in
  arm64) HOST_ARCH=arm64 ;;
  x86_64) HOST_ARCH=amd64 ;;
  *) fail "unsupported build host architecture" ;;
esac
[[ "$("$GO_EXECUTABLE" version)" == "go version go1.27.2 darwin/$HOST_ARCH" ]] \
  || fail "Go 1.27.2 is required"
BUILD_INFO="$("$GO_EXECUTABLE" version -m "$EXECUTABLE")" || fail "Go build information is unavailable"
RUNTIME_VERSION='go1.27.2'
# Earlier verified preview bundles are preserved, never treated as the new build.
if [[ "$PREVIOUS" -eq 1 && "${BUILD_INFO%%$'\n'*}" == *': go1.27.1' ]]; then
  RUNTIME_VERSION='go1.27.1'
fi
[[ "${BUILD_INFO%%$'\n'*}" == *": $RUNTIME_VERSION" \
    && "$BUILD_INFO" == *$'\n\tpath\tkinlogue/cmd/kinlogue\n'* \
    && "$BUILD_INFO" == *$'\n\tbuild\tCGO_ENABLED=0\n'* \
    && "$BUILD_INFO" == *$'\n\tbuild\t-trimpath=true\n'* \
    && "$BUILD_INFO" == *$'\n\tbuild\t-tags=mygo_noinspector\n'* ]] || fail "Go build settings differ from the preview contract"
for pin in $'github.com/egoist/mygo\tv0.2.15' $'github.com/ebitengine/purego\tv0.11.1' $'modernc.org/sqlite\tv1.60.1'; do
  print -r -- "$BUILD_INFO" | /usr/bin/awk -F '\t' -v pin="$pin" '$2 == "dep" && $3 "\t" $4 == pin { found = 1 } END { exit !found }' \
    || fail "direct dependency pin is incorrect"
done
# A replacement record belongs to its immediately preceding dependency. Only
# the in-repo mygo patch is accepted; every other module keeps its locked source.
print -r -- "$BUILD_INFO" | /usr/bin/awk -F '\t' -v previous="$PREVIOUS" '
  $2 == "=>" {
    count++
    if (dependency != "github.com/egoist/mygo\tv0.2.15" || $3 != "./third_party/mygo" || $4 != "(devel)" || $5 != "") invalid = 1
  }
  { dependency = ($2 == "dep") ? $3 "\t" $4 : "" }
  END { exit (invalid || count > 1 || (!previous && count != 1)) }
' || fail "module replacements differ from the preview contract"
if [[ "$PREVIOUS" -eq 0 ]]; then
  print -r -- "$BUILD_INFO" | /usr/bin/awk -F '\t' '$2 == "dep" && $3 == "filippo.io/age" && $4 == "v1.3.2" { found = 1 } END { exit !found }' \
    || fail "backup crypto pin is incorrect"
fi
[[ "$(print -r -- "$BUILD_INFO" | /usr/bin/sed '1d')" == "$(/bin/cat "$RESOURCES/BUILD_INFO.txt")" ]] \
  || fail "bundled build information does not describe this binary"
while IFS=$'\t' read -r module_path module_version; do
  license_name="${module_path//\//_}@$module_version.txt"
  [[ -s "$RESOURCES/ThirdPartyLicenses/$license_name" ]] || fail "a linked dependency license is missing"
done < <(print -r -- "$BUILD_INFO" | /usr/bin/awk -F '\t' '$2 == "dep" { print $3 "\t" $4 }')
[[ -s "$RESOURCES/ThirdPartyLicenses/$RUNTIME_VERSION.txt" ]] || fail "Go runtime license is missing"
print -- 'Verified Go preview identity, signature, sandbox, pinned modules, and bundle layout.'
