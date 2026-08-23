#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
XCODE_DEVELOPER_DIR_INPUT="/Applications/Xcode.app/Contents/Developer"
[[ -d "$XCODE_DEVELOPER_DIR_INPUT" && ! -L "$XCODE_DEVELOPER_DIR_INPUT" ]] || {
  echo "Build failed: the full Xcode developer directory is unavailable" >&2
  exit 1
}
XCODE_DEVELOPER_DIR="$(cd "$XCODE_DEVELOPER_DIR_INPUT" && /bin/pwd -P)"
XCODE_TOOLCHAIN_BIN="$XCODE_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"
SWIFT_EXECUTABLE="$XCODE_TOOLCHAIN_BIN/swift"
XCODEBUILD_EXECUTABLE="$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild"
XCRUN_EXECUTABLE="/usr/bin/xcrun"
export PATH="$XCODE_TOOLCHAIN_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
BUILD_CACHE_DIR="$REPO_DIR/.build/module-cache"
SWIFTPM_CACHE_DIR="$REPO_DIR/.build/swiftpm-cache"
SWIFTPM_CONFIG_DIR="$REPO_DIR/.build/swiftpm-config"
SWIFTPM_SECURITY_DIR="$REPO_DIR/.build/swiftpm-security"
DIST_DIRECTORY="$REPO_DIR/dist"
APP_BUNDLE="$DIST_DIRECTORY/Kinlogue.app"
ICONSET_DIRECTORY="$REPO_DIR/packaging/Kinlogue.iconset"
ICON_GENERATOR="$REPO_DIR/scripts/generate-icns.swift"
APP_ICON="$APP_BUNDLE/Contents/Resources/Kinlogue.icns"
APP_RESOURCE_BUNDLE_NAME="Kinlogue_KinlogueApp.bundle"
PLATFORM_RESOURCE_BUNDLE_NAME="Kinlogue_KinloguePlatform.bundle"
ZIP_FOUNDATION_RESOURCE_BUNDLE_NAME="ZIPFoundation_ZIPFoundation.bundle"
DICOM_HELPER_TARGET="KinlogueDICOMDecoderHelper"
DICOM_HELPER_BUNDLE_NAME="KinlogueDICOMDecoderHelper.xpc"
DICOM_HELPER_PROJECT="$REPO_DIR/packaging/KinlogueDICOMDecoderHelper.xcodeproj"
DICOM_HELPER_PROJECT_RESOLUTION="$DICOM_HELPER_PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
DICOM_HELPER_INFO_SOURCE="$REPO_DIR/packaging/KinlogueDICOMDecoderHelper-Info.plist"
DICOM_HELPER_ENTITLEMENTS_SOURCE="$REPO_DIR/packaging/KinlogueDICOMDecoderHelper.entitlements"
DICOM_XCODE_DERIVED_DATA="$REPO_DIR/.build/dicom-xcode-derived"
DICOM_XCODE_PACKAGE_CACHE="$REPO_DIR/.build/dicom-xcode-packages"
MAIN_LINK_MAP="$REPO_DIR/.build/Kinlogue-main-LinkMap.txt"
THIRD_PARTY_NOTICE_SOURCE="$REPO_DIR/THIRD_PARTY_NOTICES.md"
THIRD_PARTY_NOTICE_NAME="THIRD_PARTY_NOTICES.md"
ISOLATED_SWIFTPM_ROOT=""

fail() {
  echo "Build failed: $1" >&2
  exit 1
}

usage() {
  fail "usage: build-app.sh [--isolated-swiftpm-root /absolute/private/path]"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --isolated-swiftpm-root)
      [[ "$#" -ge 2 ]] || usage
      ISOLATED_SWIFTPM_ROOT="$2"
      shift
      ;;
    *)
      usage
      ;;
  esac
  shift
done

[[ -x "$SWIFT_EXECUTABLE" && -x "$XCODEBUILD_EXECUTABLE" \
    && -x "$XCRUN_EXECUTABLE" ]] \
  || fail "the selected Xcode toolchain is incomplete"
[[ -f "$THIRD_PARTY_NOTICE_SOURCE" \
    && ! -L "$THIRD_PARTY_NOTICE_SOURCE" \
    && -s "$THIRD_PARTY_NOTICE_SOURCE" ]] \
  || fail "the third-party notice must be a nonempty regular file"
for helper_source in \
    "$DICOM_HELPER_PROJECT/project.pbxproj" \
    "$DICOM_HELPER_PROJECT_RESOLUTION" \
    "$DICOM_HELPER_INFO_SOURCE" \
    "$DICOM_HELPER_ENTITLEMENTS_SOURCE"; do
  [[ -f "$helper_source" && ! -L "$helper_source" && -s "$helper_source" ]] \
    || fail "a DICOM Helper packaging source is missing, linked, or empty"
done
export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
SDKROOT_INPUT="$($XCRUN_EXECUTABLE --sdk macosx --show-sdk-path)" \
  || fail "the selected Xcode SDK could not be resolved"
[[ -d "$SDKROOT_INPUT" ]] \
  || fail "the selected Xcode SDK is unavailable"
SDKROOT="$(cd "$SDKROOT_INPUT" && /bin/pwd -P)" \
  || fail "the selected Xcode SDK could not be canonicalized"
export SDKROOT

SWIFTPM_RESOLVED_ARGUMENTS=()
if [[ -n "$ISOLATED_SWIFTPM_ROOT" ]]; then
  [[ "$ISOLATED_SWIFTPM_ROOT" == /* \
      && -d "$ISOLATED_SWIFTPM_ROOT" \
      && ! -L "$ISOLATED_SWIFTPM_ROOT" ]] \
    || fail "the isolated SwiftPM root must be an existing real absolute directory"
  ISOLATED_SWIFTPM_ROOT="$(cd "$ISOLATED_SWIFTPM_ROOT" && /bin/pwd -P)" \
    || fail "the isolated SwiftPM root could not be canonicalized"
  [[ "$(/usr/bin/stat -f '%u' "$ISOLATED_SWIFTPM_ROOT")" == "$EUID" ]] \
    || fail "the isolated SwiftPM root must be owned by the current user"
  BUILD_CACHE_DIR="$ISOLATED_SWIFTPM_ROOT/module-cache"
  SWIFTPM_CACHE_DIR="$ISOLATED_SWIFTPM_ROOT/cache"
  SWIFTPM_CONFIG_DIR="$ISOLATED_SWIFTPM_ROOT/config"
  SWIFTPM_SECURITY_DIR="$ISOLATED_SWIFTPM_ROOT/security"
  SWIFTPM_SCRATCH_DIR="$ISOLATED_SWIFTPM_ROOT/scratch"
  DICOM_XCODE_DERIVED_DATA="$ISOLATED_SWIFTPM_ROOT/dicom-xcode-derived"
  DICOM_XCODE_PACKAGE_CACHE="$ISOLATED_SWIFTPM_ROOT/dicom-xcode-packages"
  MAIN_LINK_MAP="$ISOLATED_SWIFTPM_ROOT/Kinlogue-main-LinkMap.txt"
  SWIFTPM_RESOLVED_ARGUMENTS=(
    --scratch-path "$SWIFTPM_SCRATCH_DIR"
    --disable-dependency-cache
    --only-use-versions-from-resolved-file
    --manifest-cache none
  )
fi

ensure_safe_distribution_directory() {
  if [[ -e "$DIST_DIRECTORY" || -L "$DIST_DIRECTORY" ]]; then
    [[ -d "$DIST_DIRECTORY" && ! -L "$DIST_DIRECTORY" ]] || {
      echo "Build failed: dist must be a real directory inside the repository" >&2
      exit 1
    }
  else
    /bin/mkdir "$DIST_DIRECTORY"
  fi
}

ensure_safe_distribution_directory

/bin/mkdir -p \
  "$BUILD_CACHE_DIR/clang" \
  "$BUILD_CACHE_DIR/swiftpm" \
  "$SWIFTPM_CACHE_DIR" \
  "$SWIFTPM_CONFIG_DIR" \
  "$SWIFTPM_SECURITY_DIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_CACHE_DIR/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_CACHE_DIR/swiftpm"

cd "$REPO_DIR"
"$REPO_DIR/scripts/compile-localizations.sh" --check
SWIFTPM_ARGUMENTS=(
  --disable-sandbox
  --cache-path "$SWIFTPM_CACHE_DIR"
  --config-path "$SWIFTPM_CONFIG_DIR"
  --security-path "$SWIFTPM_SECURITY_DIR"
)
if [[ -n "$ISOLATED_SWIFTPM_ROOT" ]]; then
  SWIFTPM_ARGUMENTS+=("${SWIFTPM_RESOLVED_ARGUMENTS[@]}")
else
  SWIFTPM_ARGUMENTS+=(--manifest-cache local)
fi

"$SWIFT_EXECUTABLE" build "${SWIFTPM_ARGUMENTS[@]}" \
  -c release --product Kinlogue -j 2 \
  -Xlinker -map -Xlinker "$MAIN_LINK_MAP"
"$XCODEBUILD_EXECUTABLE" \
  -project "$DICOM_HELPER_PROJECT" \
  -scheme "$DICOM_HELPER_TARGET" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DICOM_XCODE_DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$DICOM_XCODE_PACKAGE_CACHE" \
  -onlyUsePackageVersionsFromResolvedFile \
  -disableAutomaticPackageResolution \
  -skipPackageUpdates \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  LD_GENERATE_MAP_FILE=YES \
  build
BIN_DIR=$("$SWIFT_EXECUTABLE" build "${SWIFTPM_ARGUMENTS[@]}" \
  -c release --show-bin-path)
DICOM_HELPER_BUILD_PRODUCT="$DICOM_XCODE_DERIVED_DATA/Build/Products/Release/$DICOM_HELPER_BUNDLE_NAME"
DICOM_HELPER_LINK_MAP="$(/usr/bin/find \
  "$DICOM_XCODE_DERIVED_DATA/Build/Intermediates.noindex/KinlogueDICOMDecoderHelper.build/Release/KinlogueDICOMDecoderHelper.build" \
  -type f -name '*LinkMap*' -print -quit)"
[[ -d "$DICOM_HELPER_BUILD_PRODUCT" \
    && ! -L "$DICOM_HELPER_BUILD_PRODUCT" ]] \
  || fail "the Xcode-built DICOM Helper XPC service is unavailable"
[[ -f "$MAIN_LINK_MAP" && ! -L "$MAIN_LINK_MAP" && -s "$MAIN_LINK_MAP" \
    && -f "$DICOM_HELPER_LINK_MAP" && ! -L "$DICOM_HELPER_LINK_MAP" \
    && -s "$DICOM_HELPER_LINK_MAP" ]] \
  || fail "the main App and DICOM Helper link maps are unavailable"

ensure_safe_distribution_directory
if [[ -e "$APP_BUNDLE" || -L "$APP_BUNDLE" ]]; then
  [[ -d "$APP_BUNDLE" && ! -L "$APP_BUNDLE" ]] || {
    echo "Build failed: the release app target is not a real directory" >&2
    exit 1
  }
  /bin/rm -rf -- "$APP_BUNDLE"
fi
/bin/mkdir "$APP_BUNDLE"
/bin/mkdir -p \
  "$APP_BUNDLE/Contents/MacOS" \
  "$APP_BUNDLE/Contents/Resources" \
  "$APP_BUNDLE/Contents/XPCServices"
/bin/cp -- "$REPO_DIR/packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/bin/cp -- "$BIN_DIR/Kinlogue" "$APP_BUNDLE/Contents/MacOS/Kinlogue"
/bin/chmod 755 "$APP_BUNDLE/Contents/MacOS/Kinlogue"
PLATFORM_RESOURCE_BUNDLE="$BIN_DIR/$PLATFORM_RESOURCE_BUNDLE_NAME"
[[ -d "$PLATFORM_RESOURCE_BUNDLE" && ! -L "$PLATFORM_RESOURCE_BUNDLE" ]] \
  || fail "the KinloguePlatform SwiftPM resource bundle is unavailable"
/usr/bin/ditto \
  "$PLATFORM_RESOURCE_BUNDLE" \
  "$APP_BUNDLE/Contents/Resources/$PLATFORM_RESOURCE_BUNDLE_NAME"
ZIP_FOUNDATION_RESOURCE_BUNDLE="$BIN_DIR/$ZIP_FOUNDATION_RESOURCE_BUNDLE_NAME"
[[ -d "$ZIP_FOUNDATION_RESOURCE_BUNDLE" \
    && ! -L "$ZIP_FOUNDATION_RESOURCE_BUNDLE" \
    && -f "$ZIP_FOUNDATION_RESOURCE_BUNDLE/PrivacyInfo.xcprivacy" \
    && ! -L "$ZIP_FOUNDATION_RESOURCE_BUNDLE/PrivacyInfo.xcprivacy" \
    && -z "$(/usr/bin/find "$ZIP_FOUNDATION_RESOURCE_BUNDLE" -type l -print -quit)" ]] \
  || fail "the ZIPFoundation SwiftPM privacy resource bundle is unavailable"
/usr/bin/ditto \
  "$ZIP_FOUNDATION_RESOURCE_BUNDLE" \
  "$APP_BUNDLE/Contents/Resources/$ZIP_FOUNDATION_RESOURCE_BUNDLE_NAME"
APP_RESOURCE_BUNDLE="$BIN_DIR/$APP_RESOURCE_BUNDLE_NAME"
[[ -d "$APP_RESOURCE_BUNDLE" && ! -L "$APP_RESOURCE_BUNDLE" ]] \
  || fail "the KinlogueApp SwiftPM resource bundle is unavailable"
for localization in en.lproj zh-hans.lproj; do
  [[ -d "$APP_RESOURCE_BUNDLE/$localization" \
      && ! -L "$APP_RESOURCE_BUNDLE/$localization" ]] \
    || fail "the $localization app localization is unavailable"
  /usr/bin/ditto \
    "$APP_RESOURCE_BUNDLE/$localization" \
    "$APP_BUNDLE/Contents/Resources/$localization"
done
/bin/cp -- \
  "$THIRD_PARTY_NOTICE_SOURCE" \
  "$APP_BUNDLE/Contents/Resources/$THIRD_PARTY_NOTICE_NAME"

DICOM_HELPER_BUNDLE="$APP_BUNDLE/Contents/XPCServices/$DICOM_HELPER_BUNDLE_NAME"
/usr/bin/ditto "$DICOM_HELPER_BUILD_PRODUCT" "$DICOM_HELPER_BUNDLE"
[[ -f "$DICOM_HELPER_BUNDLE/Contents/MacOS/$DICOM_HELPER_TARGET" \
    && -x "$DICOM_HELPER_BUNDLE/Contents/MacOS/$DICOM_HELPER_TARGET" \
    && -d "$DICOM_HELPER_BUNDLE/Contents/Resources/DICOMDecoder_DicomCore.bundle" \
    && -d "$DICOM_HELPER_BUNDLE/Contents/Resources/ZIPFoundation_ZIPFoundation.bundle" \
    && -z "$(/usr/bin/find "$DICOM_HELPER_BUNDLE" -type l -print -quit)" ]] \
  || fail "the Xcode-built DICOM Helper layout is incomplete or unsafe"
/bin/cp -- \
  "$THIRD_PARTY_NOTICE_SOURCE" \
  "$DICOM_HELPER_BUNDLE/Contents/Resources/$THIRD_PARTY_NOTICE_NAME"
"$SWIFT_EXECUTABLE" "$ICON_GENERATOR" "$ICONSET_DIRECTORY" "$APP_ICON"

for helper_resource_bundle in \
    "$DICOM_HELPER_BUNDLE/Contents/Resources/DICOMDecoder_DicomCore.bundle" \
    "$DICOM_HELPER_BUNDLE/Contents/Resources/ZIPFoundation_ZIPFoundation.bundle"; do
  /usr/bin/codesign --force --sign - "$helper_resource_bundle"
  /usr/bin/codesign --verify --strict "$helper_resource_bundle"
done
/usr/bin/codesign --force --sign - \
  --entitlements "$DICOM_HELPER_ENTITLEMENTS_SOURCE" \
  "$DICOM_HELPER_BUNDLE"
/usr/bin/codesign --verify --strict "$DICOM_HELPER_BUNDLE"

/usr/bin/codesign --force --sign - \
  --entitlements "$REPO_DIR/packaging/Kinlogue.entitlements" \
  "$APP_BUNDLE"
/usr/bin/codesign --verify --strict "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
