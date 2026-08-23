#!/bin/zsh
set -euo pipefail

fail() {
  echo "Package graph verification failed: $1" >&2
  exit 1
}

[[ "$#" -eq 1 ]] || fail "expected one dump-package JSON path"

MANIFEST_JSON="$1"
[[ -f "$MANIFEST_JSON" && ! -L "$MANIFEST_JSON" ]] \
  || fail "the dump-package JSON is missing or linked"

extract_string() {
  local path="$1"
  local value=""
  value="$(/usr/bin/plutil -extract "$path" raw -expect string -o - \
    "$MANIFEST_JSON" 2>/dev/null)" \
    || fail "expected a string at $path"
  print -r -- "$value"
}

extract_json() {
  local path="$1"
  local value=""
  value="$(/usr/bin/plutil -extract "$path" json -o - \
    "$MANIFEST_JSON" 2>/dev/null)" \
    || fail "expected JSON at $path"
  print -r -- "$value"
}

array_count() {
  local path="$1"
  local count=""
  count="$(/usr/bin/plutil -extract "$path" raw -expect array -o - \
    "$MANIFEST_JSON" 2>/dev/null)" \
    || fail "expected an array at $path"
  [[ "$count" == <-> ]] || fail "invalid array size at $path"
  print -r -- "$count"
}

dictionary_keys() {
  local path="$1"
  local keys=""
  keys="$(/usr/bin/plutil -extract "$path" raw -expect dictionary -o - \
    "$MANIFEST_JSON" 2>/dev/null)" \
    || fail "expected a dictionary at $path"
  print -r -- "$keys"
}

sorted_lines() {
  if [[ "$#" -eq 0 ]]; then
    return
  fi
  /usr/bin/printf '%s\n' "$@" | LC_ALL=C /usr/bin/sort
}

dependency_signature() {
  local path="$1"
  local keys=""
  keys="$(dictionary_keys "$path")"

  case "$keys" in
    byName)
      [[ "$(array_count "$path.byName")" -eq 2 ]] \
        || fail "invalid target dependency tuple at $path"
      local target_name=""
      target_name="$(extract_string "$path.byName.0")"
      [[ "$(extract_json "$path.byName")" == "[\"$target_name\",null]" ]] \
        || fail "conditional target dependencies are not allow-listed at $path"
      print -r -- "target:$target_name"
      ;;
    product)
      [[ "$(array_count "$path.product")" -eq 4 ]] \
        || fail "invalid product dependency tuple at $path"
      local product_name="" package_name=""
      product_name="$(extract_string "$path.product.0")"
      package_name="$(extract_string "$path.product.1")"
      [[ "$(extract_json "$path.product")" \
          == "[\"$product_name\",\"$package_name\",null,null]" ]] \
        || fail "conditional product dependencies are not allow-listed at $path"
      print -r -- "product:$product_name@$package_name"
      ;;
    *)
      fail "unsupported dependency declaration at $path"
      ;;
  esac
}

product_signature() {
  local index="$1"
  local path="products.$index"
  local name="" target="" type_key="" product_type=""

  name="$(extract_string "$path.name")"
  [[ "$(array_count "$path.settings")" -eq 0 ]] \
    || fail "product $name has unexpected settings"
  [[ "$(array_count "$path.targets")" -eq 1 ]] \
    || fail "product $name must expose exactly one target"
  target="$(extract_string "$path.targets.0")"
  type_key="$(dictionary_keys "$path.type")"

  case "$type_key" in
    library)
      [[ "$(array_count "$path.type.library")" -eq 1 \
          && "$(extract_string "$path.type.library.0")" == "automatic" ]] \
        || fail "product $name has an unexpected library type"
      product_type="library:automatic"
      ;;
    executable)
      [[ "$(extract_json "$path.type")" == '{"executable":null}' ]] \
        || fail "product $name has an unexpected executable type"
      product_type="executable"
      ;;
    *)
      fail "product $name has an unsupported type"
      ;;
  esac

  print -r -- "$name|$product_type|$target"
}

package_dependency_count="$(array_count dependencies)"
[[ "$package_dependency_count" -eq 3 ]] \
  || fail "package dependencies do not match the exact allow-list"
package_dependency_identities=()
for ((index = 0; index < package_dependency_count; index++)); do
  [[ "$(dictionary_keys dependencies.$index)" == "sourceControl" \
      && "$(array_count dependencies.$index.sourceControl)" -eq 1 ]] \
    || fail "package dependencies do not match the exact allow-list"
  package_dependency_identities+=(
    "$(extract_string dependencies.$index.sourceControl.0.identity)"
  )
done
[[ "$(sorted_lines "${package_dependency_identities[@]}")" \
    == $'dicom-swift\nswift-nio\nzipfoundation' ]] \
  || fail "package dependencies do not match the exact allow-list"

product_count="$(array_count products)"
local_product_signatures=()
for ((index = 0; index < product_count; index++)); do
  local_product_signatures+=("$(product_signature "$index")")
done
actual_products="$(sorted_lines "${local_product_signatures[@]}")"
expected_products="$(sorted_lines \
  'Kinlogue|executable|KinlogueApp')"
[[ "$actual_products" == "$expected_products" ]] \
  || fail "products do not match the exact allow-list"

target_count="$(array_count targets)"
target_signatures=()
for ((index = 0; index < target_count; index++)); do
  target_signatures+=(\
    "$(extract_string "targets.$index.name")|$(extract_string "targets.$index.type")"\
  )
done
actual_targets="$(sorted_lines "${target_signatures[@]}")"
expected_targets="$(sorted_lines \
  'KinlogueCore|regular' \
  'KinlogueDICOMIPC|regular' \
  'KinlogueDICOMDecoderHelper|executable' \
  'KinlogueDICOMTestSupport|regular' \
  'KinlogueDICOMXPCProbe|executable' \
  'KinlogueDICOMAcceptanceFixtureGenerator|executable' \
  'KinloguePlatform|regular' \
  'KinlogueApp|executable' \
  'KinlogueCoreTests|test' \
  'KinloguePlatformTests|test' \
  'KinlogueAppTests|test' \
  'KinlogueStorageProcessFixture|executable' \
  'KinlogueExportWriterProbe|executable' \
  'KinlogueStorageProcessTests|test')"
[[ "$actual_targets" == "$expected_targets" ]] \
  || fail "targets do not match the exact allow-list"

target_index_named() {
  local expected_name="$1"
  local candidate_name=""
  for ((index = 0; index < target_count; index++)); do
    candidate_name="$(extract_string "targets.$index.name")"
    if [[ "$candidate_name" == "$expected_name" ]]; then
      print -r -- "$index"
      return
    fi
  done
  fail "target $expected_name is missing"
}

verify_target_dependencies() {
  local target_name="$1"
  shift
  local expected_dependencies=""
  expected_dependencies="$(sorted_lines "$@")"

  local target_index=""
  target_index="$(target_index_named "$target_name")"
  local count=""
  count="$(array_count "targets.$target_index.dependencies")"
  local signatures=()
  local dependency_index=0
  for ((dependency_index = 0; dependency_index < count; dependency_index++)); do
    signatures+=(\
      "$(dependency_signature "targets.$target_index.dependencies.$dependency_index")"\
    )
  done
  local actual_dependencies=""
  actual_dependencies="$(sorted_lines "${signatures[@]}")"

  [[ "$actual_dependencies" == "$expected_dependencies" ]] \
    || fail "$target_name direct dependencies do not match the exact allow-list"
}

verify_target_dependencies KinlogueCore
verify_target_dependencies KinlogueDICOMIPC
verify_target_dependencies KinlogueDICOMDecoderHelper \
  'target:KinlogueDICOMIPC' \
  'product:DicomCore@DICOM-Swift'
verify_target_dependencies KinlogueDICOMTestSupport \
  'target:KinlogueDICOMIPC'
verify_target_dependencies KinlogueDICOMXPCProbe \
  'target:KinloguePlatform' \
  'target:KinlogueDICOMTestSupport'
verify_target_dependencies KinlogueDICOMAcceptanceFixtureGenerator \
  'target:KinlogueDICOMTestSupport'
verify_target_dependencies KinloguePlatform \
  'target:KinlogueCore' \
  'target:KinlogueDICOMIPC' \
  'product:NIOCore@swift-nio' \
  'product:NIOHTTP1@swift-nio' \
  'product:NIOPosix@swift-nio' \
  'product:ZIPFoundation@ZIPFoundation'
verify_target_dependencies KinlogueApp \
  'target:KinlogueCore' \
  'target:KinloguePlatform'
verify_target_dependencies KinlogueCoreTests \
  'target:KinlogueCore'
verify_target_dependencies KinloguePlatformTests \
  'target:KinloguePlatform' \
  'target:KinlogueDICOMIPC' \
  'target:KinlogueDICOMTestSupport' \
  'product:NIOEmbedded@swift-nio' \
  'product:ZIPFoundation@ZIPFoundation'
verify_target_dependencies KinlogueAppTests \
  'target:KinlogueApp' \
  'target:KinlogueDICOMIPC' \
  'target:KinlogueDICOMTestSupport'
verify_target_dependencies KinlogueStorageProcessFixture \
  'target:KinlogueCore' \
  'target:KinlogueDICOMIPC' \
  'target:KinloguePlatform'
verify_target_dependencies KinlogueExportWriterProbe \
  'product:ZIPFoundation@ZIPFoundation'
verify_target_dependencies KinlogueStorageProcessTests \
  'target:KinlogueCore' \
  'target:KinlogueDICOMTestSupport' \
  'target:KinloguePlatform' \
  'target:KinlogueStorageProcessFixture'
