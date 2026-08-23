#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
DIST_DIRECTORY="$REPO_DIR/dist"
APP_BUNDLE="$DIST_DIRECTORY/Kinlogue.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/Kinlogue"
ICON_FILE="$APP_BUNDLE/Contents/Resources/Kinlogue.icns"
THIRD_PARTY_NOTICE_SOURCE="$REPO_DIR/THIRD_PARTY_NOTICES.md"
THIRD_PARTY_NOTICE_FILE="$APP_BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md"
PHONE_ASSET_SOURCE_DIRECTORY="$REPO_DIR/Sources/KinloguePlatform/Resources/LANUpload"
PHONE_ASSET_BUNDLE_DIRECTORY="$APP_BUNDLE/Contents/Resources/Kinlogue_KinloguePlatform.bundle/LANUpload"
EN_INFO_PLIST_STRINGS="$APP_BUNDLE/Contents/Resources/en.lproj/InfoPlist.strings"
ZH_HANS_INFO_PLIST_STRINGS="$APP_BUNDLE/Contents/Resources/zh-hans.lproj/InfoPlist.strings"
REPORT_PATH="$REPO_DIR/dist/verification-report.json"
EXPECTED_DICOM_HELPER_BUNDLE="$APP_BUNDLE/Contents/XPCServices/KinlogueDICOMDecoderHelper.xpc"
DICOM_HELPER_BUNDLE="$EXPECTED_DICOM_HELPER_BUNDLE"
DICOM_HELPER_EXECUTABLE="$DICOM_HELPER_BUNDLE/Contents/MacOS/KinlogueDICOMDecoderHelper"
DICOM_HELPER_INFO_PLIST="$DICOM_HELPER_BUNDLE/Contents/Info.plist"
DICOM_HELPER_RESOURCES="$DICOM_HELPER_BUNDLE/Contents/Resources"
DICOM_HELPER_NOTICE="$DICOM_HELPER_RESOURCES/THIRD_PARTY_NOTICES.md"
DICOM_HELPER_ENTITLEMENTS_SOURCE="$REPO_DIR/packaging/KinlogueDICOMDecoderHelper.entitlements"
DICOM_HELPER_PROJECT="$REPO_DIR/packaging/KinlogueDICOMDecoderHelper.xcodeproj/project.pbxproj"
DICOM_HELPER_PROJECT_RESOLUTION="$REPO_DIR/packaging/KinlogueDICOMDecoderHelper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

EXPECTED_BUNDLE_IDENTIFIER="com.kinlogue.mac"
EXPECTED_SHORT_VERSION="0.5.0"
EXPECTED_BUILD_VERSION="5"
EXPECTED_MINIMUM_SYSTEM_VERSION="14.0"
EXPECTED_ICON_FILE="Kinlogue.icns"
EXPECTED_PLATFORM_RESOURCE_BUNDLE="Kinlogue_KinloguePlatform.bundle"
EXPECTED_ZIP_FOUNDATION_RESOURCE_BUNDLE="ZIPFoundation_ZIPFoundation.bundle"
EXPECTED_LOCALIZATIONS='["zh-Hans","en"]'
EXPECTED_THIRD_PARTY_NOTICE_FILE="THIRD_PARTY_NOTICES.md"
EXPECTED_THIRD_PARTY_NOTICE_SHA256="0cb360cee49618f8e90185ba8e0c7d36ce7a7c4f6174e688584ba8417365f904"
EXPECTED_LAN_PURPOSE="仅在您主动开启接收时，允许同一局域网中的设备向这台 Mac 上传资料。"
EXPECTED_EN_LAN_PURPOSE="When you explicitly start receiving, allow devices on the same local network to upload documents to this Mac."
EXPECTED_SWIFT_NIO_REVISION="0b18836bd8b0162e7e17a995a3fbee20ed8f3b2b"
EXPECTED_DICOM_SWIFT_REVISION="9ae0851e134af274651b646519b8a7aaeee05f05"
EXPECTED_DICOM_SWIFT_VERSION="1.3.3"
EXPECTED_ARGUMENT_PARSER_REVISION="6a52f3251125d74daf04fcbd5e6f08a75d074382"
EXPECTED_ARGUMENT_PARSER_VERSION="1.8.2"
EXPECTED_ZIPFOUNDATION_REVISION="22787ffb59de99e5dc1fbfe80b19c97a904ad48d"
EXPECTED_ZIPFOUNDATION_VERSION="0.9.20"
EXPECTED_DICOM_HELPER_IDENTIFIER="com.kinlogue.mac.dicom-decoder"

XCODE_DEVELOPER_DIR_INPUT="/Applications/Xcode.app/Contents/Developer"
[[ -d "$XCODE_DEVELOPER_DIR_INPUT" && ! -L "$XCODE_DEVELOPER_DIR_INPUT" ]] || {
  echo "Bundle verification failed: the full Xcode developer directory is unavailable" >&2
  exit 1
}
XCODE_DEVELOPER_DIR="$(cd "$XCODE_DEVELOPER_DIR_INPUT" && /bin/pwd -P)"
XCODE_TOOLCHAIN_BIN="$XCODE_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"
SWIFT_EXECUTABLE="$XCODE_TOOLCHAIN_BIN/swift"
XCODEBUILD_EXECUTABLE="$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild"
XCRUN_EXECUTABLE="/usr/bin/xcrun"
export PATH="$XCODE_TOOLCHAIN_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
[[ -x "$SWIFT_EXECUTABLE" && -x "$XCODEBUILD_EXECUTABLE" \
    && -x "$XCRUN_EXECUTABLE" ]] || {
  echo "Bundle verification failed: the selected Xcode toolchain is incomplete" >&2
  exit 1
}
export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
SDK_PATH_INPUT="$($XCRUN_EXECUTABLE --sdk macosx --show-sdk-path)" || {
  echo "Bundle verification failed: the selected Xcode SDK could not be resolved" >&2
  exit 1
}
[[ -d "$SDK_PATH_INPUT" ]] || {
  echo "Bundle verification failed: the selected Xcode SDK is unavailable" >&2
  exit 1
}
SDK_PATH="$(cd "$SDK_PATH_INPUT" && /bin/pwd -P)" || {
  echo "Bundle verification failed: the selected Xcode SDK could not be canonicalized" >&2
  exit 1
}
export SDKROOT="$SDK_PATH"

REQUIRE_CLEAN_SOURCE=true
REQUIRE_CLEAN_SOURCE_EXPLICIT=false
LAN_PREREQUISITES_ONLY=false
LAN_COMPOSITION_SCAN_STATUS="notExecuted"
ISOLATED_SWIFTPM_ROOT=""
TEMP_DIRECTORY=""

fail() {
  echo "Bundle verification failed: $1" >&2
  exit 1
}

invalidate_verification_report() {
  if [[ -e "$DIST_DIRECTORY" || -L "$DIST_DIRECTORY" ]]; then
    [[ -d "$DIST_DIRECTORY" && ! -L "$DIST_DIRECTORY" ]] \
      || fail "dist must be a real directory inside the repository"
  fi
  if [[ -e "$REPORT_PATH" || -L "$REPORT_PATH" ]]; then
    [[ -f "$REPORT_PATH" || -L "$REPORT_PATH" ]] \
      || fail "the verification report path is not a regular file"
    /bin/rm -f -- "$REPORT_PATH" \
      || fail "the previous verification report could not be invalidated"
  fi
}

create_isolated_swiftpm_root() {
  ISOLATED_SWIFTPM_ROOT="$(/usr/bin/mktemp -d \
    /private/tmp/kinlogue-swiftpm-release.XXXXXX)" \
    || fail "a private isolated SwiftPM root could not be created"
  [[ "$(/usr/bin/stat -f '%u' "$ISOLATED_SWIFTPM_ROOT")" == "$EUID" \
      && "$(/usr/bin/stat -f '%Lp' "$ISOLATED_SWIFTPM_ROOT")" == 700 ]] \
    || fail "the isolated SwiftPM root is not private to the current user"
}

require_plist_key_absent() {
  local key="$1"
  local plist="$2"
  local label="$3"
  local diagnostic extraction_status escaped_key_path
  escaped_key_path=${key//./\\.}

  if diagnostic="$(LC_ALL=C /usr/bin/plutil -extract "$escaped_key_path" raw \
      "$plist" 2>&1 >/dev/null)"; then
    fail "$label contains the forbidden $key capability"
  else
    extraction_status=$?
  fi
  [[ "$extraction_status" -eq 1 ]] \
    || fail "$label could not be inspected safely for $key"
  case "$diagnostic" in
    *"No value at that key path or invalid key path: $escaped_key_path") ;;
    *) fail "$label could not be inspected safely for $key" ;;
  esac
}

require_exact_boolean_entitlements() {
  local plist="$1"
  local label="$2"
  shift 2
  local key key_count escaped_key_path
  for key in "$@"; do
    escaped_key_path=${key//./\\.}
    [[ "$(/usr/bin/plutil -extract "$escaped_key_path" raw -expect bool "$plist")" == true ]] \
      || fail "$label is missing the required $key entitlement"
  done
  key_count="$(/usr/bin/plutil -convert xml1 -o - "$plist" \
    | /usr/bin/grep -c '<key>')"
  [[ "$key_count" -eq "$#" ]] \
    || fail "$label contains values outside the exact entitlement allow-list"
}

cleanup() {
  if [[ -n "${TEMP_DIRECTORY:-}" \
      && -d "$TEMP_DIRECTORY" && ! -L "$TEMP_DIRECTORY" \
      && "${TEMP_DIRECTORY:h}" == "$REPO_DIR/dist" \
      && "${TEMP_DIRECTORY:t}" == .verification-report.* ]]; then
    /bin/rm -rf -- "$TEMP_DIRECTORY"
  fi
  if [[ -n "${ISOLATED_SWIFTPM_ROOT:-}" \
      && -d "$ISOLATED_SWIFTPM_ROOT" && ! -L "$ISOLATED_SWIFTPM_ROOT" \
      && "${ISOLATED_SWIFTPM_ROOT:h}" == /private/tmp \
      && "${ISOLATED_SWIFTPM_ROOT:t}" == kinlogue-swiftpm-release.* ]]; then
    /bin/rm -rf -- "$ISOLATED_SWIFTPM_ROOT"
  fi
}
trap cleanup EXIT INT TERM HUP

verify_dicom_helper_prerequisites() {
  local root="$1"
  local manifest_json="$2"
  local manifest="$root/Package.swift"
  local resolution="$root/Package.resolved"
  local helper_entitlements="$root/packaging/KinlogueDICOMDecoderHelper.entitlements"
  local helper_project="$root/packaging/KinlogueDICOMDecoderHelper.xcodeproj/project.pbxproj"
  local helper_resolution="$root/packaging/KinlogueDICOMDecoderHelper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  local third_party_notice="$root/THIRD_PARTY_NOTICES.md"

  for file in "$helper_entitlements" "$helper_project" \
      "$helper_resolution" "$third_party_notice"; do
    [[ -f "$file" && ! -L "$file" ]] \
      || fail "a DICOM Helper prerequisite file is missing or linked: $file"
  done
  [[ -s "$third_party_notice" ]] \
    || fail "the third-party notice is empty"
  [[ "$(/usr/bin/shasum -a 256 -- "$third_party_notice" \
      | /usr/bin/awk '{print $1}')" == "$EXPECTED_THIRD_PARTY_NOTICE_SHA256" ]] \
    || fail "the reviewed third-party notice content drifted"

  local manifest_index=0 manifest_identity="" dicom_manifest_index=""
  while manifest_identity="$(/usr/bin/plutil -extract \
      "dependencies.$manifest_index.sourceControl.0.identity" raw \
      -expect string "$manifest_json" 2>/dev/null)"; do
    [[ "$manifest_identity" == "dicom-swift" ]] \
      && dicom_manifest_index="$manifest_index"
    manifest_index=$((manifest_index + 1))
  done
  [[ -n "$dicom_manifest_index" ]] \
    || fail "the manifest must contain exact DICOM-Swift"
  [[ "$(/usr/bin/plutil -extract \
      "dependencies.$dicom_manifest_index.sourceControl.0.location.remote.0.urlString" raw \
      -expect string "$manifest_json")" \
      == "https://github.com/ThalesMMS/DICOM-Swift.git" ]] \
    || fail "DICOM-Swift must come from the approved official repository"
  [[ "$(/usr/bin/plutil -extract \
      "dependencies.$dicom_manifest_index.sourceControl.0.requirement.exact.0" raw \
      -expect string "$manifest_json")" == "$EXPECTED_DICOM_SWIFT_VERSION" ]] \
    || fail "DICOM-Swift must be pinned to exact version 1.3.3"

  local pin_index=0 pin_identity=""
  local dicom_pin_index="" xcode_dicom_pin_index=""
  while pin_identity="$(/usr/bin/plutil -extract "pins.$pin_index.identity" raw \
      -expect string "$resolution" 2>/dev/null)"; do
    [[ "$pin_identity" == "dicom-swift" ]] && dicom_pin_index="$pin_index"
    pin_index=$((pin_index + 1))
  done
  pin_index=0
  while pin_identity="$(/usr/bin/plutil -extract "pins.$pin_index.identity" raw \
      -expect string "$helper_resolution" 2>/dev/null)"; do
    [[ "$pin_identity" == "dicom-swift" ]] && xcode_dicom_pin_index="$pin_index"
    pin_index=$((pin_index + 1))
  done
  [[ -n "$dicom_pin_index" && -n "$xcode_dicom_pin_index" ]] \
    || fail "both root and Xcode resolutions must contain DICOM-Swift"
  for resolved_path_and_index in \
      "$resolution:$dicom_pin_index" \
      "$helper_resolution:$xcode_dicom_pin_index"; do
    local resolved_path="${resolved_path_and_index%:*}"
    local resolved_index="${resolved_path_and_index##*:}"
    [[ "$(/usr/bin/plutil -extract "pins.$resolved_index.state.revision" raw \
        -expect string "$resolved_path")" == "$EXPECTED_DICOM_SWIFT_REVISION" \
        && "$(/usr/bin/plutil -extract "pins.$resolved_index.state.version" raw \
        -expect string "$resolved_path")" == "$EXPECTED_DICOM_SWIFT_VERSION" ]] \
      || fail "a DICOM-Swift resolution drifted from exact 1.3.3"
  done

  local root_argument_parser_index="" root_zipfoundation_index=""
  local xcode_argument_parser_index="" xcode_zipfoundation_index=""
  local xcode_pin_count=0
  pin_index=0
  while pin_identity="$(/usr/bin/plutil -extract "pins.$pin_index.identity" raw \
      -expect string "$resolution" 2>/dev/null)"; do
    case "$pin_identity" in
      swift-argument-parser) root_argument_parser_index="$pin_index" ;;
      zipfoundation) root_zipfoundation_index="$pin_index" ;;
    esac
    pin_index=$((pin_index + 1))
  done
  pin_index=0
  while pin_identity="$(/usr/bin/plutil -extract "pins.$pin_index.identity" raw \
      -expect string "$helper_resolution" 2>/dev/null)"; do
    case "$pin_identity" in
      dicom-swift) ;;
      swift-argument-parser) xcode_argument_parser_index="$pin_index" ;;
      zipfoundation) xcode_zipfoundation_index="$pin_index" ;;
      *) fail "the Xcode Helper resolution contains an unexpected package" ;;
    esac
    xcode_pin_count=$((xcode_pin_count + 1))
    pin_index=$((pin_index + 1))
  done
  [[ "$xcode_pin_count" -eq 3 \
      && -n "$root_argument_parser_index" \
      && -n "$root_zipfoundation_index" \
      && -n "$xcode_argument_parser_index" \
      && -n "$xcode_zipfoundation_index" ]] \
    || fail "the Xcode Helper transitive resolution does not match the exact allow-list"
  for root_and_xcode_index in \
      "$root_argument_parser_index:$xcode_argument_parser_index:$EXPECTED_ARGUMENT_PARSER_REVISION:$EXPECTED_ARGUMENT_PARSER_VERSION" \
      "$root_zipfoundation_index:$xcode_zipfoundation_index:$EXPECTED_ZIPFOUNDATION_REVISION:$EXPECTED_ZIPFOUNDATION_VERSION"; do
    local root_resolved_index="${root_and_xcode_index%%:*}"
    local remaining_indices="${root_and_xcode_index#*:}"
    local xcode_resolved_index="${remaining_indices%%:*}"
    local expected_revision_and_version="${remaining_indices#*:}"
    local expected_revision="${expected_revision_and_version%%:*}"
    local expected_version="${expected_revision_and_version##*:}"
    [[ "$(/usr/bin/plutil -extract "pins.$root_resolved_index.state" json \
          -o - "$resolution")" \
        == "$(/usr/bin/plutil -extract "pins.$xcode_resolved_index.state" json \
          -o - "$helper_resolution")" \
        && "$(/usr/bin/plutil -extract "pins.$root_resolved_index.location" raw \
          -expect string "$resolution")" \
        == "$(/usr/bin/plutil -extract "pins.$xcode_resolved_index.location" raw \
          -expect string "$helper_resolution")" \
        && "$(/usr/bin/plutil -extract \
          "pins.$xcode_resolved_index.state.revision" raw -expect string \
          "$helper_resolution")" == "$expected_revision" \
        && "$(/usr/bin/plutil -extract \
          "pins.$xcode_resolved_index.state.version" raw -expect string \
          "$helper_resolution")" == "$expected_version" ]] \
      || fail "an Xcode Helper transitive resolution drifted or differs from root"
  done
  /usr/bin/grep -Fq 'productType = "com.apple.product-type.xpc-service"' \
    "$helper_project" \
    || fail "the checked-in DICOM Helper project is not an XPC service target"

  local helper_json
  helper_json="$(/usr/bin/plutil -convert json -o - "$helper_entitlements")"
  [[ "$helper_json" == '{"com.apple.security.app-sandbox":true}' ]] \
    || fail "DICOM Helper entitlements must contain only app sandbox"
  for forbidden_helper_entitlement in \
      com.apple.security.network.client \
      com.apple.security.network.server \
      com.apple.security.inherit; do
    require_plist_key_absent "$forbidden_helper_entitlement" \
      "$helper_entitlements" "the DICOM Helper source entitlements"
  done
}

verify_release_prerequisites() {
  local root="$1"
  local swiftpm_root="$2"
  local resolved_only="$3"
  local manifest="$root/Package.swift"
  local resolution="$root/Package.resolved"
  local info="$root/packaging/Info.plist"
  local production_entitlements="$root/packaging/Kinlogue.entitlements"
  local package_graph_verifier="$root/scripts/verify-package-graph.sh"

  for file in "$manifest" "$resolution" "$info" \
      "$production_entitlements" "$package_graph_verifier"; do
    [[ -f "$file" && ! -L "$file" ]] \
      || fail "a release prerequisite file is missing or linked: $file"
  done

  [[ "$(/usr/bin/sed -n '1p' "$manifest")" == '// swift-tools-version: 6.1' ]] \
    || fail "the package must use the Swift 6.1 manifest required by SwiftNIO"

  local cache_root metadata_root manifest_json graph_json scratch_root
  local dependency_cache config_root security_root
  cache_root="$swiftpm_root"
  scratch_root="$cache_root/scratch"
  if [[ "$resolved_only" == true ]]; then
    dependency_cache="$cache_root/cache"
    config_root="$cache_root/config"
    security_root="$cache_root/security"
  else
    dependency_cache="$cache_root/swiftpm-cache"
    config_root="$cache_root/swiftpm-config"
    security_root="$cache_root/swiftpm-security"
  fi
  /bin/mkdir -p \
    "$cache_root/module-cache/clang" \
    "$cache_root/module-cache/swiftpm" \
    "$dependency_cache" \
    "$config_root" \
    "$security_root"
  export CLANG_MODULE_CACHE_PATH="$cache_root/module-cache/clang"
  export SWIFTPM_MODULECACHE_OVERRIDE="$cache_root/module-cache/swiftpm"
  metadata_root="$(/usr/bin/mktemp -d "$cache_root/.lan-prerequisites.XXXXXX")"
  manifest_json="$metadata_root/manifest.json"
  graph_json="$metadata_root/graph.json"
  local swiftpm_arguments=(
    --disable-sandbox
    --cache-path "$dependency_cache"
    --config-path "$config_root"
    --security-path "$security_root"
  )
  if [[ "$resolved_only" == true ]]; then
    swiftpm_arguments+=(
      --scratch-path "$scratch_root"
      --disable-dependency-cache
      --only-use-versions-from-resolved-file
      --manifest-cache none
    )
  else
    swiftpm_arguments+=(--manifest-cache local)
  fi
  (
    cd "$root"
    "$SWIFT_EXECUTABLE" package "${swiftpm_arguments[@]}" dump-package >"$manifest_json"
    "$SWIFT_EXECUTABLE" package "${swiftpm_arguments[@]}" show-dependencies \
      --format json >"$graph_json"
  ) || {
    /bin/rm -rf -- "$metadata_root"
    fail "SwiftPM could not produce structured dependency metadata"
  }

  /bin/zsh "$package_graph_verifier" "$manifest_json" \
    || fail "the package graph does not match the release allow-list"

  local manifest_index=0 manifest_identity=""
  local nio_manifest_index=""
  while manifest_identity="$(/usr/bin/plutil -extract \
      "dependencies.$manifest_index.sourceControl.0.identity" raw \
      -expect string "$manifest_json" 2>/dev/null)"; do
    case "$manifest_identity" in
      swift-nio) nio_manifest_index="$manifest_index" ;;
    esac
    manifest_index=$((manifest_index + 1))
  done
  [[ -n "$nio_manifest_index" ]] \
    || fail "the manifest must contain exact SwiftNIO"
  [[ "$(/usr/bin/plutil -extract \
      "dependencies.$nio_manifest_index.sourceControl.0.location.remote.0.urlString" raw \
      -expect string "$manifest_json")" == "https://github.com/apple/swift-nio.git" ]] \
    || fail "SwiftNIO must come from the official repository"
  [[ "$(/usr/bin/plutil -extract \
      "dependencies.$nio_manifest_index.sourceControl.0.requirement.exact.0" raw \
      -expect string "$manifest_json")" == "2.101.3" ]] \
    || fail "SwiftNIO must be pinned to patched version 2.101.3"
  local pin_index=0 pin_identity="" nio_pin_index=""
  while pin_identity="$(/usr/bin/plutil -extract "pins.$pin_index.identity" raw \
      -expect string "$resolution" 2>/dev/null)"; do
    if [[ "$pin_identity" == "swift-nio" ]]; then
      nio_pin_index="$pin_index"
      break
    fi
    pin_index=$((pin_index + 1))
  done
  [[ -n "$nio_pin_index" ]] || fail "Package.resolved does not contain SwiftNIO"
  [[ "$(/usr/bin/plutil -extract "pins.$nio_pin_index.location" raw \
      -expect string "$resolution")" == "https://github.com/apple/swift-nio.git" ]] \
    || fail "Package.resolved has an unexpected SwiftNIO location"
  [[ "$(/usr/bin/plutil -extract "pins.$nio_pin_index.state.revision" raw \
      -expect string "$resolution")" \
      == "0b18836bd8b0162e7e17a995a3fbee20ed8f3b2b" ]] \
    || fail "Package.resolved has an unexpected SwiftNIO revision"
  [[ "$(/usr/bin/plutil -extract "pins.$nio_pin_index.state.version" raw \
      -expect string "$resolution")" == "2.101.3" ]] \
    || fail "Package.resolved has an unexpected SwiftNIO version"

  local graph_index=0 graph_identity="" graph_version=""
  while graph_identity="$(/usr/bin/plutil -extract "dependencies.$graph_index.identity" raw \
      -expect string "$graph_json" 2>/dev/null)"; do
    if [[ "$graph_identity" == "swift-nio" ]]; then
      graph_version="$(/usr/bin/plutil -extract \
        "dependencies.$graph_index.version" raw -expect string "$graph_json")"
      break
    fi
    graph_index=$((graph_index + 1))
  done
  [[ "$graph_version" == "2.101.3" ]] \
    || fail "the resolved SwiftPM dependency graph is not SwiftNIO 2.101.3"

  verify_dicom_helper_prerequisites "$root" "$manifest_json"

  if [[ "$resolved_only" == true ]]; then
    verify_swiftnio_checkout "$scratch_root"
  fi
  /bin/rm -rf -- "$metadata_root"

  [[ "$(/usr/bin/plutil -extract NSLocalNetworkUsageDescription raw \
      -expect string "$info")" == "$EXPECTED_LAN_PURPOSE" ]] \
    || fail "the production local-network purpose string is missing or unexpected"
  require_plist_key_absent NSBonjourServices "$info" \
    "the production source Info.plist"
  require_plist_key_absent NSAppTransportSecurity "$info" \
    "the production source Info.plist"
  require_exact_boolean_entitlements \
    "$production_entitlements" "production entitlements" \
    com.apple.security.app-sandbox \
    com.apple.security.files.user-selected.read-write \
    com.apple.security.files.bookmarks.app-scope \
    com.apple.security.network.server
}

verify_swiftnio_checkout() {
  local scratch_root="$1"
  local checkout_root="$scratch_root/checkouts"
  [[ -d "$checkout_root" && ! -L "$checkout_root" ]] \
    || fail "the isolated SwiftPM checkout directory is missing or linked"

  local -a nio_checkouts
  nio_checkouts=(
    "$checkout_root"/swift-nio(N/)
    "$checkout_root"/swift-nio-*(N/)
  )
  [[ "${#nio_checkouts[@]}" -eq 1 \
      && -d "$nio_checkouts[1]" \
      && ! -L "$nio_checkouts[1]" ]] \
    || fail "the isolated SwiftNIO checkout is missing or ambiguous"
  [[ "$(/usr/bin/git -C "$nio_checkouts[1]" rev-parse --verify HEAD)" \
      == "$EXPECTED_SWIFT_NIO_REVISION" ]] \
    || fail "the isolated SwiftNIO checkout revision drifted"
  [[ -z "$(/usr/bin/git -C "$nio_checkouts[1]" status \
      --porcelain --untracked-files=all)" ]] \
    || fail "the isolated SwiftNIO checkout is dirty"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --lan-prerequisites-only)
      LAN_PREREQUISITES_ONLY=true
      ;;
    --require-clean-source)
      REQUIRE_CLEAN_SOURCE=true
      REQUIRE_CLEAN_SOURCE_EXPLICIT=true
      ;;
    *)
      fail "usage: verify-app.sh [--lan-prerequisites-only | --require-clean-source]"
      ;;
  esac
  shift
done

invalidate_verification_report

if [[ "$LAN_PREREQUISITES_ONLY" == true ]]; then
  [[ "$REQUIRE_CLEAN_SOURCE_EXPLICIT" == false ]] \
    || fail "--lan-prerequisites-only cannot be combined with release gates"
  verify_release_prerequisites "$REPO_DIR" "$REPO_DIR/.build" false
  echo "LAN prerequisite verification passed"
  exit 0
fi

if [[ "$REQUIRE_CLEAN_SOURCE" == true \
    && -n "$(/usr/bin/git -C "$REPO_DIR" status --porcelain --untracked-files=normal)" ]]; then
  fail "the release artifact must be built from a clean source checkout"
fi

create_isolated_swiftpm_root

plist_string() {
  /usr/bin/plutil -extract "$1" raw -expect string "$INFO_PLIST"
}

signature_value() {
  /usr/bin/awk -F= -v key="$1" '
    $1 == key {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' "$SIGNATURE_METADATA_FILE"
}

validate_icon_representation() {
  local filename="$1"
  local expected_size="$2"
  local representation="$ICONSET_PROBE/$filename"

  [[ -f "$representation" && ! -L "$representation" ]] \
    || fail "the application icon is missing $filename"
  local metadata
  metadata="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$representation" 2>/dev/null)" \
    || fail "the application icon representation $filename could not be decoded"
  /usr/bin/printf '%s\n' "$metadata" \
    | /usr/bin/grep -Fq "pixelWidth: $expected_size" \
    || fail "the application icon representation $filename has an unexpected width"
  /usr/bin/printf '%s\n' "$metadata" \
    | /usr/bin/grep -Fq "pixelHeight: $expected_size" \
    || fail "the application icon representation $filename has an unexpected height"
}

verify_release_prerequisites "$REPO_DIR" "$ISOLATED_SWIFTPM_ROOT" true
"$REPO_DIR/scripts/privacy-guard.sh"

DICOM_CORE_IMPORTS="$(LC_ALL=C /usr/bin/grep -r -l \
  --include='*.swift' '^import DicomCore$' "$REPO_DIR/Sources" \
  | LC_ALL=C /usr/bin/sort)"
[[ "$DICOM_CORE_IMPORTS" \
    == "$REPO_DIR/Sources/KinlogueDICOMDecoderHelper/KinlogueDICOMDecoderHelper.swift" ]] \
  || fail "only the isolated DICOM Helper may import DicomCore"
DICOM_HELPER_SOURCE="$REPO_DIR/Sources/KinlogueDICOMDecoderHelper/KinlogueDICOMDecoderHelper.swift"
[[ "$(/usr/bin/grep -F -c 'DCMDecoder(contentsOf:' "$DICOM_HELPER_SOURCE")" -eq 1 \
    && "$(/usr/bin/grep -F -c 'decoder.getFrame(0)' "$DICOM_HELPER_SOURCE")" -eq 1 ]] \
  || fail "the DICOM Helper decoder call path differs from the exact allow-list"
if /usr/bin/grep -E -n -- \
    '(StudyDataService|DicomWeb|DIMSE|DicomStorageSCP|JPIP|NWListener|URLSession)' \
    "$DICOM_HELPER_SOURCE" >/dev/null 2>&1; then
  fail "the DICOM Helper source constructs a forbidden upstream network or series API"
else
  DICOM_HELPER_CALL_SCAN_STATUS=$?
  [[ "$DICOM_HELPER_CALL_SCAN_STATUS" -eq 1 ]] \
    || fail "the DICOM Helper call allow-list audit could not be completed"
fi
/usr/bin/grep -Fq 'name: "KinlogueDICOMAcceptanceFixtureGenerator"' \
  "$REPO_DIR/Package.swift" \
  || fail "the DICOM acceptance generator target is missing"
if /usr/bin/awk \
    '/^[[:space:]]*products: \[/ { in_products = 1 } \
     /^[[:space:]]*dependencies: \[/ { in_products = 0 } \
     in_products { print }' "$REPO_DIR/Package.swift" \
    | /usr/bin/grep -Fq 'KinlogueDICOMAcceptanceFixtureGenerator'; then
  fail "the DICOM acceptance generator is unexpectedly published"
fi
if LC_ALL=C /usr/bin/grep -r -n -E --include='*.swift' \
    '(^|[^[:alnum:]_])(DCMDecoder|DicomWeb|DIMSE|DicomStorageSCP|JPIP)([^[:alnum:]_]|$)' \
    "$REPO_DIR/Sources/KinlogueCore" \
    "$REPO_DIR/Sources/KinloguePlatform" \
    "$REPO_DIR/Sources/KinlogueApp" >/dev/null 2>&1; then
  fail "the main-process source graph contains a DICOM decoder or network implementation"
else
  DICOM_SOURCE_SCAN_STATUS=$?
  [[ "$DICOM_SOURCE_SCAN_STATUS" -eq 1 ]] \
    || fail "the main-process DICOM implementation audit could not be completed"
fi

/usr/bin/grep -Fq 'LiveLANInboxService' \
  "$REPO_DIR/Sources/KinlogueApp/App/AppServices.swift" \
  || fail "the production app is not composed with the live LAN inbox service"
/usr/bin/grep -Fq 'com.apple.security.network.server' \
  "$REPO_DIR/packaging/Kinlogue.entitlements" \
  || fail "the production incoming-server entitlement is missing"
if LC_ALL=C /usr/bin/grep -n -E -- \
    '(^|[^[:alnum:]_])(print|NSLog)[[:space:]]*\(|Logger[[:space:]]*\.' \
    "$REPO_DIR/Sources/KinloguePlatform/LAN"/*.swift >/dev/null 2>&1; then
  fail "the LAN receiver contains an unapproved raw logging path"
else
  LAN_LOG_SCAN_EXIT=$?
  [[ "$LAN_LOG_SCAN_EXIT" -eq 1 ]] \
    || fail "the LAN receiver logging audit could not be completed"
fi
LAN_COMPOSITION_SCAN_STATUS="passed"
[[ "$LAN_COMPOSITION_SCAN_STATUS" == passed ]] \
  || fail "the LAN composition audit was not executed"

"$REPO_DIR/scripts/build-app.sh" \
  --isolated-swiftpm-root "$ISOLATED_SWIFTPM_ROOT"
verify_swiftnio_checkout "$ISOLATED_SWIFTPM_ROOT/scratch"
MAIN_LINK_MAP="$ISOLATED_SWIFTPM_ROOT/Kinlogue-main-LinkMap.txt"
DICOM_HELPER_LINK_MAP="$(/usr/bin/find \
  "$ISOLATED_SWIFTPM_ROOT/dicom-xcode-derived/Build/Intermediates.noindex/KinlogueDICOMDecoderHelper.build/Release/KinlogueDICOMDecoderHelper.build" \
  -type f -name '*LinkMap*' -print -quit)"
[[ -f "$MAIN_LINK_MAP" && ! -L "$MAIN_LINK_MAP" && -s "$MAIN_LINK_MAP" \
    && -f "$DICOM_HELPER_LINK_MAP" && ! -L "$DICOM_HELPER_LINK_MAP" \
    && -s "$DICOM_HELPER_LINK_MAP" ]] \
  || fail "the release link-map evidence is missing"
if /usr/bin/grep -E -q -- \
    '(DicomCore|DicomWeb|DIMSE|DicomStorageSCP|JPIP)' "$MAIN_LINK_MAP"; then
  fail "the main executable link map contains DicomCore or DICOM network code"
fi
/usr/bin/grep -Fq 'DicomCore' "$DICOM_HELPER_LINK_MAP" \
  || fail "the DICOM Helper link map does not contain the approved decoder"

if [[ "$REQUIRE_CLEAN_SOURCE" == true \
    && -n "$(/usr/bin/git -C "$REPO_DIR" status --porcelain --untracked-files=normal)" ]]; then
  fail "the source checkout changed while the release artifact was being built"
fi

[[ -d "$APP_BUNDLE" && ! -L "$APP_BUNDLE" ]] \
  || fail "the release app is missing or is a symbolic link"
[[ -f "$INFO_PLIST" && ! -L "$INFO_PLIST" ]] \
  || fail "Info.plist is missing or is a symbolic link"
[[ -f "$EXECUTABLE" && ! -L "$EXECUTABLE" && -x "$EXECUTABLE" ]] \
  || fail "the main executable is missing, linked, or not executable"
[[ -f "$ICON_FILE" && ! -L "$ICON_FILE" && -s "$ICON_FILE" ]] \
  || fail "the application icon is missing, linked, or empty"
[[ -z "$(/usr/bin/find "$APP_BUNDLE" -type l -print -quit)" ]] \
  || fail "symbolic links are not allowed in the release bundle"
if LC_ALL=C /usr/bin/grep -r -a -F -q \
    'KinlogueDICOMAcceptanceFixtureGenerator' "$APP_BUNDLE"; then
  fail "the non-product DICOM acceptance generator leaked into the release bundle"
fi
XPC_SERVICE_COUNT="$(/usr/bin/find "$APP_BUNDLE/Contents/XPCServices" \
  -mindepth 1 -maxdepth 1 -type d -name '*.xpc' -print \
  | /usr/bin/wc -l | /usr/bin/awk '{print $1}')"
[[ "$XPC_SERVICE_COUNT" -eq 1 \
    && -d "$DICOM_HELPER_BUNDLE" && ! -L "$DICOM_HELPER_BUNDLE" \
    && -f "$DICOM_HELPER_INFO_PLIST" && ! -L "$DICOM_HELPER_INFO_PLIST" \
    && -f "$DICOM_HELPER_EXECUTABLE" && -x "$DICOM_HELPER_EXECUTABLE" \
    && ! -e "$DICOM_HELPER_BUNDLE/DICOMDecoder_DicomCore.bundle" \
    && ! -e "$DICOM_HELPER_BUNDLE/ZIPFoundation_ZIPFoundation.bundle" ]] \
  || fail "the app must contain exactly one standard-layout DICOM XPC service"
DICOM_HELPER_RESOURCE_ENTRIES="$(
  cd "$DICOM_HELPER_RESOURCES"
  /usr/bin/find . -mindepth 1 -maxdepth 1 -print | LC_ALL=C /usr/bin/sort
)"
EXPECTED_DICOM_HELPER_RESOURCE_ENTRIES="./DICOMDecoder_DicomCore.bundle
./THIRD_PARTY_NOTICES.md
./ZIPFoundation_ZIPFoundation.bundle"
[[ "$DICOM_HELPER_RESOURCE_ENTRIES" \
    == "$EXPECTED_DICOM_HELPER_RESOURCE_ENTRIES" ]] \
  || fail "the DICOM Helper resource allow-list does not match exactly"
[[ "$(/usr/bin/plutil -extract CFBundlePackageType raw -expect string \
      "$DICOM_HELPER_INFO_PLIST")" == "XPC!" \
    && "$(/usr/bin/plutil -extract CFBundleIdentifier raw -expect string \
      "$DICOM_HELPER_INFO_PLIST")" == "$EXPECTED_DICOM_HELPER_IDENTIFIER" \
    && "$(/usr/bin/plutil -extract CFBundleExecutable raw -expect string \
      "$DICOM_HELPER_INFO_PLIST")" == "KinlogueDICOMDecoderHelper" ]] \
  || fail "the DICOM Helper metadata is unexpected"
[[ -f "$DICOM_HELPER_NOTICE" && ! -L "$DICOM_HELPER_NOTICE" \
    && -s "$DICOM_HELPER_NOTICE" ]] \
  || fail "the DICOM Helper third-party notice is missing, linked, or empty"
/usr/bin/cmp -s "$THIRD_PARTY_NOTICE_SOURCE" "$DICOM_HELPER_NOTICE" \
  || fail "the DICOM Helper third-party notice differs from its source"
for signed_nested_bundle in \
    "$DICOM_HELPER_RESOURCES/DICOMDecoder_DicomCore.bundle" \
    "$DICOM_HELPER_RESOURCES/ZIPFoundation_ZIPFoundation.bundle"; do
  /usr/bin/codesign --verify --strict "$signed_nested_bundle" \
    || fail "a DICOM Helper nested resource bundle signature is invalid"
done
/usr/bin/codesign --verify --strict "$DICOM_HELPER_BUNDLE" \
  || fail "the DICOM Helper signature is invalid"
DICOM_HELPER_ENTITLEMENTS_JSON="$(/usr/bin/codesign -d --entitlements :- \
  "$DICOM_HELPER_BUNDLE" 2>/dev/null \
  | /usr/bin/plutil -convert json -o - -)" \
  || fail "the DICOM Helper signed entitlements could not be inspected"
[[ "$DICOM_HELPER_ENTITLEMENTS_JSON" \
    == '{"com.apple.security.app-sandbox":true}' ]] \
  || fail "the signed DICOM Helper entitlements exceed the exact sandbox allow-list"
RESOURCE_FILES="$(
  cd "$APP_BUNDLE/Contents/Resources"
  /usr/bin/find . -type f -print | LC_ALL=C /usr/bin/sort
)"
EXPECTED_RESOURCE_FILES="./$EXPECTED_ICON_FILE
./$EXPECTED_PLATFORM_RESOURCE_BUNDLE/Info.plist
./$EXPECTED_PLATFORM_RESOURCE_BUNDLE/LANUpload/app.js
./$EXPECTED_PLATFORM_RESOURCE_BUNDLE/LANUpload/index.html
./$EXPECTED_PLATFORM_RESOURCE_BUNDLE/LANUpload/styles.css
./$EXPECTED_THIRD_PARTY_NOTICE_FILE
./$EXPECTED_ZIP_FOUNDATION_RESOURCE_BUNDLE/PrivacyInfo.xcprivacy
./en.lproj/InfoPlist.strings
./en.lproj/Localizable.strings
./en.lproj/Localizable.stringsdict
./zh-hans.lproj/InfoPlist.strings
./zh-hans.lproj/Localizable.strings"
[[ "$RESOURCE_FILES" == "$EXPECTED_RESOURCE_FILES" ]] \
  || fail "the application bundle resource allow-list does not match exactly"
ZIP_FOUNDATION_PRIVACY_MANIFEST="$APP_BUNDLE/Contents/Resources/$EXPECTED_ZIP_FOUNDATION_RESOURCE_BUNDLE/PrivacyInfo.xcprivacy"
[[ -f "$ZIP_FOUNDATION_PRIVACY_MANIFEST" \
    && ! -L "$ZIP_FOUNDATION_PRIVACY_MANIFEST" \
    && -s "$ZIP_FOUNDATION_PRIVACY_MANIFEST" ]] \
  || fail "the main App ZIPFoundation privacy manifest is missing or unsafe"
/usr/bin/plutil -lint "$ZIP_FOUNDATION_PRIVACY_MANIFEST" >/dev/null \
  || fail "the main App ZIPFoundation privacy manifest is invalid"

[[ -f "$THIRD_PARTY_NOTICE_SOURCE" \
    && ! -L "$THIRD_PARTY_NOTICE_SOURCE" \
    && -s "$THIRD_PARTY_NOTICE_SOURCE" ]] \
  || fail "the source third-party notice is missing, linked, or empty"
[[ -f "$THIRD_PARTY_NOTICE_FILE" \
    && ! -L "$THIRD_PARTY_NOTICE_FILE" \
    && -s "$THIRD_PARTY_NOTICE_FILE" ]] \
  || fail "the bundled third-party notice is missing, linked, or empty"
SOURCE_THIRD_PARTY_NOTICE_HASH="$(
  /usr/bin/shasum -a 256 -- "$THIRD_PARTY_NOTICE_SOURCE" \
    | /usr/bin/awk '{ print $1 }'
)"
THIRD_PARTY_NOTICE_HASH="$(
  /usr/bin/shasum -a 256 -- "$THIRD_PARTY_NOTICE_FILE" \
    | /usr/bin/awk '{ print $1 }'
)"
[[ "$SOURCE_THIRD_PARTY_NOTICE_HASH" == "$EXPECTED_THIRD_PARTY_NOTICE_SHA256" \
    && "$THIRD_PARTY_NOTICE_HASH" == "$EXPECTED_THIRD_PARTY_NOTICE_SHA256" ]] \
  || fail "the third-party notice hash does not match the reviewed content"
/usr/bin/cmp -s "$THIRD_PARTY_NOTICE_SOURCE" "$THIRD_PARTY_NOTICE_FILE" \
  || fail "the bundled third-party notice differs from its source"

for phone_asset_name in app.js index.html styles.css; do
  phone_asset_source="$PHONE_ASSET_SOURCE_DIRECTORY/$phone_asset_name"
  phone_asset_bundle="$PHONE_ASSET_BUNDLE_DIRECTORY/$phone_asset_name"
  [[ -f "$phone_asset_source" \
      && ! -L "$phone_asset_source" \
      && -s "$phone_asset_source" ]] \
    || fail "a source phone asset is missing, linked, or empty: $phone_asset_name"
  [[ -f "$phone_asset_bundle" \
      && ! -L "$phone_asset_bundle" \
      && -s "$phone_asset_bundle" ]] \
    || fail "a bundled phone asset is missing, linked, or empty: $phone_asset_name"
  /usr/bin/cmp -s "$phone_asset_source" "$phone_asset_bundle" \
    || fail "a bundled phone asset differs from its source: $phone_asset_name"
done

/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null \
  || fail "Info.plist is invalid"
require_plist_key_absent NSBonjourServices "$INFO_PLIST" \
  "the production bundle Info.plist"
require_plist_key_absent NSAppTransportSecurity "$INFO_PLIST" \
  "the production bundle Info.plist"

[[ "$(plist_string CFBundlePackageType)" == "APPL" ]] \
  || fail "CFBundlePackageType must be APPL"
[[ "$(plist_string CFBundleExecutable)" == "Kinlogue" ]] \
  || fail "CFBundleExecutable must be Kinlogue"
[[ "$(plist_string CFBundleIconFile)" == "$EXPECTED_ICON_FILE" ]] \
  || fail "CFBundleIconFile must name the packaged application icon"
BUNDLE_IDENTIFIER="$(plist_string CFBundleIdentifier)"
SHORT_VERSION="$(plist_string CFBundleShortVersionString)"
BUILD_VERSION="$(plist_string CFBundleVersion)"
MINIMUM_SYSTEM_VERSION="$(plist_string LSMinimumSystemVersion)"
DEVELOPMENT_REGION="$(plist_string CFBundleDevelopmentRegion)"
LOCALIZATIONS="$(/usr/bin/plutil -extract CFBundleLocalizations json -o - "$INFO_PLIST")"
[[ "$BUNDLE_IDENTIFIER" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] \
  || fail "the production bundle identifier is unexpected"
[[ "$SHORT_VERSION" == "$EXPECTED_SHORT_VERSION" ]] \
  || fail "the short version is unexpected"
[[ "$BUILD_VERSION" == "$EXPECTED_BUILD_VERSION" ]] \
  || fail "the build version is unexpected"
[[ "$MINIMUM_SYSTEM_VERSION" == "$EXPECTED_MINIMUM_SYSTEM_VERSION" ]] \
  || fail "the minimum system version is unexpected"
[[ "$DEVELOPMENT_REGION" == "zh-Hans" ]] \
  || fail "the development localization must be Simplified Chinese"
[[ "$LOCALIZATIONS" == "$EXPECTED_LOCALIZATIONS" ]] \
  || fail "the application must declare exactly Simplified Chinese and English"
ICON_KIND="$(/usr/bin/file -b "$ICON_FILE")"
case "$ICON_KIND" in
  "Mac OS X icon"*) ;;
  *) fail "the packaged application icon is not a valid ICNS container" ;;
esac
ICON_METADATA="$(/usr/bin/sips -g format -g pixelWidth -g pixelHeight "$ICON_FILE" 2>/dev/null)" \
  || fail "the application icon could not be decoded"
/usr/bin/printf '%s\n' "$ICON_METADATA" | /usr/bin/grep -Fq 'format: icns' \
  || fail "the application icon decoder did not report ICNS format"
/usr/bin/printf '%s\n' "$ICON_METADATA" | /usr/bin/grep -Fq 'pixelWidth: 1024' \
  || fail "the application icon is missing its 1024-pixel representation"
/usr/bin/printf '%s\n' "$ICON_METADATA" | /usr/bin/grep -Fq 'pixelHeight: 1024' \
  || fail "the application icon is missing its 1024-pixel representation"

if /usr/bin/plutil -extract KinlogueAcceptanceEnabled raw "$INFO_PLIST" >/dev/null 2>&1 \
  || /usr/bin/plutil -extract KinlogueAcceptanceRunID raw "$INFO_PLIST" >/dev/null 2>&1 \
  || /usr/bin/plutil -extract KinlogueLANFeasibilityEnabled raw "$INFO_PLIST" >/dev/null 2>&1; then
  fail "the production bundle contains an acceptance identity marker"
fi
[[ "$(/usr/bin/plutil -extract NSLocalNetworkUsageDescription raw \
    -expect string "$INFO_PLIST")" == "$EXPECTED_LAN_PURPOSE" ]] \
  || fail "the production bundle local-network purpose is unexpected"

[[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw \
      -expect string "$EN_INFO_PLIST_STRINGS")" == "Kinlogue" ]] \
  || fail "the English application display name is missing"
[[ "$(/usr/bin/plutil -extract NSLocalNetworkUsageDescription raw \
      -expect string "$EN_INFO_PLIST_STRINGS")" == "$EXPECTED_EN_LAN_PURPOSE" ]] \
  || fail "the English local-network purpose is unexpected"
[[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw \
      -expect string "$ZH_HANS_INFO_PLIST_STRINGS")" == "续页" ]] \
  || fail "the Simplified Chinese application display name is missing"
[[ "$(/usr/bin/plutil -extract NSLocalNetworkUsageDescription raw \
      -expect string "$ZH_HANS_INFO_PLIST_STRINGS")" == "$EXPECTED_LAN_PURPOSE" ]] \
  || fail "the Simplified Chinese local-network purpose is unexpected"

ARCHITECTURES="$(/usr/bin/lipo -archs "$EXECUTABLE")"
[[ "$ARCHITECTURES" == "arm64" ]] \
  || fail "the release executable must contain only the arm64 architecture"
DICOM_HELPER_ARCHITECTURES="$(/usr/bin/lipo -archs "$DICOM_HELPER_EXECUTABLE")"
[[ "$DICOM_HELPER_ARCHITECTURES" == "arm64" ]] \
  || fail "the DICOM Helper executable must contain only arm64"
BINARY_PLATFORM="$(
  /usr/bin/vtool -show-build "$EXECUTABLE" \
    | /usr/bin/awk '$1 == "platform" { print $2; exit }'
)"
BINARY_MINIMUM_SYSTEM_VERSION="$(
  /usr/bin/vtool -show-build "$EXECUTABLE" \
    | /usr/bin/awk '$1 == "minos" { print $2; exit }'
)"
[[ "$BINARY_PLATFORM" == "MACOS" ]] \
  || fail "the release executable must target macOS"
[[ "$BINARY_MINIMUM_SYSTEM_VERSION" == "$EXPECTED_MINIMUM_SYSTEM_VERSION" ]] \
  || fail "the executable and Info.plist minimum system versions do not match"

OTOOL_LIBRARIES="$(/usr/bin/otool -L "$EXECUTABLE")" \
  || fail "the executable dependency list could not be inspected"
if /usr/bin/printf '%s\n' "$OTOOL_LIBRARIES" \
    | /usr/bin/grep -Fq '/System/Library/Frameworks/Security.framework/'; then
  fail "the plaintext MVP must not link Security.framework directly"
fi
MAIN_EXECUTABLE_SYMBOLS="$(/usr/bin/nm "$EXECUTABLE" 2>/dev/null)" \
  || fail "the main executable symbols could not be inspected"
case "$MAIN_EXECUTABLE_SYMBOLS" in
  *DCMDecoder*|*DicomCore*|*DicomWeb*|*DIMSE*|*DicomStorageSCP*|*JPIP*)
    fail "the main executable contains a DicomCore decoder or DICOM network symbol"
    ;;
esac
HELPER_EXECUTABLE_SYMBOLS="$(/usr/bin/nm "$DICOM_HELPER_EXECUTABLE" 2>/dev/null)" \
  || fail "the DICOM Helper symbols could not be inspected"
[[ "$HELPER_EXECUTABLE_SYMBOLS" == *DCMDecoder* ]] \
  || fail "the DICOM Helper executable does not contain the approved decoder"
LEGACY_RUNTIME_PATTERN='(^|[^[:alnum:]_])(EncryptedVault|VaultCipher)([^[:alnum:]_]|$)'
if LC_ALL=C /usr/bin/grep -r -n -E -- \
    "$LEGACY_RUNTIME_PATTERN" "$REPO_DIR/Sources" >/dev/null 2>&1; then
  fail "legacy encryption or recovery runtime types remain in production sources"
else
  LEGACY_SCAN_STATUS=$?
  [[ "$LEGACY_SCAN_STATUS" -eq 1 ]] \
    || fail "production source storage audit could not be completed"
fi
NO_KEYCHAIN_RUNTIME_PATTERN='(^|[^[:alnum:]_])(KeychainVaultKeyStore|SecItem[[:alnum:]_]*|kSec[[:alnum:]_]*)([^[:alnum:]_]|$)|^[[:space:]]*import[[:space:]]+Security([^[:alnum:]_]|$)'
if LC_ALL=C /usr/bin/grep -r -n -E -- \
    "$NO_KEYCHAIN_RUNTIME_PATTERN" "$REPO_DIR/Sources" >/dev/null 2>&1; then
  fail "Keychain or Security runtime types remain in production sources"
else
  KEYCHAIN_SCAN_STATUS=$?
  [[ "$KEYCHAIN_SCAN_STATUS" -eq 1 ]] \
    || fail "production source Keychain audit could not be completed"
fi

/usr/bin/codesign --verify --strict "$APP_BUNDLE" \
  || fail "the code signature is invalid"

TEMP_DIRECTORY="$(/usr/bin/mktemp -d "$REPO_DIR/dist/.verification-report.XXXXXX")"
ENTITLEMENTS_FILE="$TEMP_DIRECTORY/entitlements.plist"
SIGNATURE_METADATA_FILE="$TEMP_DIRECTORY/signature-metadata.txt"
BUNDLE_MANIFEST_FILE="$TEMP_DIRECTORY/bundle-manifest.txt"
RESOURCE_MANIFEST_FILE="$TEMP_DIRECTORY/resource-manifest.txt"
REPORT_TEMP_FILE="$TEMP_DIRECTORY/report.plist"
ICONSET_PROBE="$TEMP_DIRECTORY/Kinlogue.iconset"

/usr/bin/iconutil -c iconset "$ICON_FILE" -o "$ICONSET_PROBE" \
  || fail "the application icon could not be expanded into standard representations"
[[ -z "$(/usr/bin/find "$ICONSET_PROBE" -type l -print -quit)" ]] \
  || fail "expanded application icon representations must not be symbolic links"
ICON_REPRESENTATION_COUNT="$(
  /usr/bin/find "$ICONSET_PROBE" -type f -print \
    | /usr/bin/wc -l \
    | /usr/bin/awk '{ print $1 }'
)"
[[ "$ICON_REPRESENTATION_COUNT" -eq 10 ]] \
  || fail "the application icon must contain all 10 standard macOS representations"
validate_icon_representation icon_16x16.png 16
validate_icon_representation icon_16x16@2x.png 32
validate_icon_representation icon_32x32.png 32
validate_icon_representation icon_32x32@2x.png 64
validate_icon_representation icon_128x128.png 128
validate_icon_representation icon_128x128@2x.png 256
validate_icon_representation icon_256x256.png 256
validate_icon_representation icon_256x256@2x.png 512
validate_icon_representation icon_512x512.png 512
validate_icon_representation icon_512x512@2x.png 1024

/usr/bin/codesign -d --verbose=4 "$APP_BUNDLE" \
  >/dev/null 2>"$SIGNATURE_METADATA_FILE"

[[ "$(signature_value Signature)" == "adhoc" ]] \
  || fail "the local artifact must be ad-hoc signed"
[[ "$(signature_value Identifier)" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] \
  || fail "the signed identifier does not match Info.plist"
[[ "$(signature_value TeamIdentifier)" == "not set" ]] \
  || fail "the local artifact must not claim a signing team"
if /usr/bin/grep -q '^Authority=' "$SIGNATURE_METADATA_FILE"; then
  fail "the local artifact unexpectedly contains a signing authority"
fi

CD_HASH="$(signature_value CDHash)"
if ! /usr/bin/printf '%s\n' "$CD_HASH" \
  | /usr/bin/grep -Eq '^[0-9a-f]{40}$'; then
  fail "the signature CDHash is missing or malformed"
fi

/usr/bin/codesign -d --entitlements :- "$APP_BUNDLE" \
  >"$ENTITLEMENTS_FILE" 2>/dev/null
/usr/bin/plutil -lint "$ENTITLEMENTS_FILE" >/dev/null \
  || fail "the signed entitlements are invalid"
require_exact_boolean_entitlements \
  "$ENTITLEMENTS_FILE" "signed production entitlements" \
  com.apple.security.app-sandbox \
  com.apple.security.files.user-selected.read-write \
  com.apple.security.files.bookmarks.app-scope \
  com.apple.security.network.server

(
  cd "$APP_BUNDLE"
  /usr/bin/find . -type f -print \
    | LC_ALL=C /usr/bin/sort \
    | while IFS= read -r relative_path; do
        file_hash="$(/usr/bin/shasum -a 256 -- "$relative_path" | /usr/bin/awk '{print $1}')"
        /usr/bin/printf '%s\t%s\n' "$file_hash" "$relative_path"
      done
) >"$BUNDLE_MANIFEST_FILE"

(
  cd "$APP_BUNDLE/Contents/Resources"
  /usr/bin/find . -type f -print \
    | LC_ALL=C /usr/bin/sort \
    | while IFS= read -r relative_path; do
        file_hash="$(/usr/bin/shasum -a 256 -- "$relative_path" | /usr/bin/awk '{print $1}')"
        /usr/bin/printf '%s\t%s\n' "$file_hash" "$relative_path"
      done
) >"$RESOURCE_MANIFEST_FILE"

BUNDLE_HASH="$(/usr/bin/shasum -a 256 -- "$BUNDLE_MANIFEST_FILE" | /usr/bin/awk '{print $1}')"
RESOURCE_MANIFEST_HASH="$(/usr/bin/shasum -a 256 -- "$RESOURCE_MANIFEST_FILE" | /usr/bin/awk '{print $1}')"
EXECUTABLE_HASH="$(/usr/bin/shasum -a 256 -- "$EXECUTABLE" | /usr/bin/awk '{print $1}')"
DICOM_HELPER_EXECUTABLE_HASH="$(/usr/bin/shasum -a 256 -- \
  "$DICOM_HELPER_EXECUTABLE" | /usr/bin/awk '{print $1}')"
ICON_HASH="$(/usr/bin/shasum -a 256 -- "$ICON_FILE" | /usr/bin/awk '{print $1}')"
ENTITLEMENTS_HASH="$(/usr/bin/shasum -a 256 -- "$ENTITLEMENTS_FILE" | /usr/bin/awk '{print $1}')"
PACKAGE_RESOLVED_HASH="$(/usr/bin/shasum -a 256 -- "$REPO_DIR/Package.resolved" | /usr/bin/awk '{print $1}')"
DICOM_PROJECT_RESOLVED_HASH="$(/usr/bin/shasum -a 256 -- \
  "$DICOM_HELPER_PROJECT_RESOLUTION" | /usr/bin/awk '{print $1}')"
SOURCE_REVISION="$(/usr/bin/git -C "$REPO_DIR" rev-parse --verify HEAD)"
if [[ -n "$(/usr/bin/git -C "$REPO_DIR" status --porcelain --untracked-files=normal)" ]]; then
  SOURCE_DIRTY=true
else
  SOURCE_DIRTY=false
fi
SWIFT_VERSION="$("$SWIFT_EXECUTABLE" --version 2>/dev/null | /usr/bin/head -n 1)"
XCODE_VERSION="$("$XCODEBUILD_EXECUTABLE" -version | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/[[:space:]]*$//')"
SDK_VERSION="$("$XCRUN_EXECUTABLE" --sdk macosx --show-sdk-version)"
MACOS_VERSION="$(/usr/bin/sw_vers -productVersion)"
HOST_ARCHITECTURE="$(/usr/bin/uname -m)"
RESOLUTION_MODE="resolvedOnly"
DEPENDENCY_CACHE_ENABLED=false

/usr/bin/plutil -create xml1 "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert schemaVersion -integer 4 "$REPORT_TEMP_FILE"

/usr/bin/plutil -insert source -dictionary "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert source.revision -string "$SOURCE_REVISION" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert source.dirty -bool "$SOURCE_DIRTY" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert source.cleanRequired -bool "$REQUIRE_CLEAN_SOURCE" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert source.packageResolvedSHA256 -string "$PACKAGE_RESOLVED_HASH" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert source.dicomProjectResolvedSHA256 -string \
  "$DICOM_PROJECT_RESOLVED_HASH" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert source.dicomSwiftRevision -string \
  "$EXPECTED_DICOM_SWIFT_REVISION" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert source.resolutionMode -string \
  "$RESOLUTION_MODE" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert source.dependencyCacheEnabled -bool \
  "$DEPENDENCY_CACHE_ENABLED" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert source.swiftNIORevision -string \
  "$EXPECTED_SWIFT_NIO_REVISION" "$REPORT_TEMP_FILE"

/usr/bin/plutil -insert environment -dictionary "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert environment.developerDirectory -string "$XCODE_DEVELOPER_DIR" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert environment.swiftExecutable -string "$SWIFT_EXECUTABLE" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert environment.swiftVersion -string "$SWIFT_VERSION" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert environment.xcodebuildExecutable -string "$XCODEBUILD_EXECUTABLE" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert environment.xcodeVersion -string "$XCODE_VERSION" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert environment.xcrunExecutable -string "$XCRUN_EXECUTABLE" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert environment.sdkPath -string "$SDK_PATH" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert environment.sdkVersion -string "$SDK_VERSION" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert environment.macOSVersion -string "$MACOS_VERSION" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert environment.architecture -string "$HOST_ARCHITECTURE" "$REPORT_TEMP_FILE"

/usr/bin/plutil -insert artifact -dictionary "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert artifact.bundleIdentifier -string "$BUNDLE_IDENTIFIER" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert artifact.shortVersion -string "$SHORT_VERSION" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert artifact.buildVersion -string "$BUILD_VERSION" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert artifact.minimumSystemVersion -string "$MINIMUM_SYSTEM_VERSION" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert artifact.binaryMinimumSystemVersion -string "$BINARY_MINIMUM_SYSTEM_VERSION" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert artifact.architectures -string "$ARCHITECTURES" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert artifact.bundleSHA256 -string "$BUNDLE_HASH" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert artifact.bundleHashFormat -string "sha256-content-manifest-v1" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert artifact.executableSHA256 -string "$EXECUTABLE_HASH" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert artifact.dicomHelperBundleIdentifier -string \
  "$EXPECTED_DICOM_HELPER_IDENTIFIER" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert artifact.dicomHelperExecutableSHA256 -string \
  "$DICOM_HELPER_EXECUTABLE_HASH" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert artifact.iconFile -string "$EXPECTED_ICON_FILE" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert artifact.iconSHA256 -string "$ICON_HASH" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert artifact.iconRepresentations -integer "$ICON_REPRESENTATION_COUNT" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert artifact.resourceManifestSHA256 -string "$RESOURCE_MANIFEST_HASH" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert artifact.thirdPartyNoticeFile -string \
  "$EXPECTED_THIRD_PARTY_NOTICE_FILE" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert artifact.thirdPartyNoticeSHA256 -string \
  "$THIRD_PARTY_NOTICE_HASH" "$REPORT_TEMP_FILE"

/usr/bin/plutil -insert signing -dictionary "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert signing.kind -string "adHoc" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert signing.identifier -string "$BUNDLE_IDENTIFIER" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert signing.teamIdentifier -string "not set" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert signing.authorityStatus -string "absent" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert signing.cdHash -string "$CD_HASH" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert signing.entitlementsSHA256 -string "$ENTITLEMENTS_HASH" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert signing.developerID -dictionary "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert signing.developerID.status -string "notExecuted" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert signing.notarization -dictionary "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert signing.notarization.status -string "notExecuted" "$REPORT_TEMP_FILE"

/usr/bin/plutil -insert storage -dictionary "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert storage.confidentiality -string "plaintext" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert storage.applicationLayerEncryption -bool false "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert storage.integrityCheck -string "sha256" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert storage.keychainDependency -bool false "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert storage.cloudSync -bool false "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert storage.backupContainerEncryption -string "hpke-x25519-chacha20poly1305+aes-256-gcm" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert storage.backupRecoveryPrivateKeyPersisted -bool false "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert storage.backupDeviceIdentityCanDecrypt -bool false "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert storage.builtInBackupRestore -bool true "$REPORT_TEMP_FILE"

/usr/bin/plutil -insert gates -dictionary "$REPORT_TEMP_FILE"
for gate in \
  privacyGuard \
  releaseBuild \
  infoPlist \
  appIcon \
  bundleMetadata \
  architecture \
  signatureIntegrity \
  adHocSignature \
  entitlementAllowList \
  noSecurityFrameworkDependency \
  noKeychainRuntime \
  noLegacyCryptoRuntime \
  dependencyLock \
  dicomHelperStructure \
  dicomHelperSignature \
  dicomHelperEntitlementAllowList \
  dicomMainProcessIsolation \
  dicomXcodeResolutionLock \
  thirdPartyNotice \
  artifactHashing; do
  /usr/bin/plutil -insert "gates.$gate" -string "passed" "$REPORT_TEMP_FILE"
done
/usr/bin/plutil -insert gates.lanComposition -string \
  "$LAN_COMPOSITION_SCAN_STATUS" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert gates.bundleVerification -string "passed" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert gates.syntheticSmoke -string "notExecuted" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert gates.installedAcceptance -string "notExecuted" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert gates.canaryScan -string "notExecuted" "$REPORT_TEMP_FILE"
/usr/bin/plutil -insert gates.overall -string "notExecuted" "$REPORT_TEMP_FILE"

/usr/bin/plutil -convert json "$REPORT_TEMP_FILE"
/usr/bin/plutil -convert json -o /dev/null "$REPORT_TEMP_FILE" \
  || fail "the verification report is invalid"
/bin/chmod 644 "$REPORT_TEMP_FILE"
/bin/mv -f -- "$REPORT_TEMP_FILE" "$REPORT_PATH"

echo "Bundle verification passed"
echo "Verification report: $REPORT_PATH"
echo "Local install status: ad-hoc signed; no Apple developer account required"
echo "Public distribution status: Developer ID and notarization not executed"
