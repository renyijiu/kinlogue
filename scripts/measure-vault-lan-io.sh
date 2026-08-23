#!/bin/sh

set -eu

output_file="$(mktemp -t kinlogue-vault-lan-io.XXXXXX)"
trap 'rm -f "$output_file"' EXIT
started_at="$(date +%s)"

if ! swift test --disable-sandbox --filter OptimizationMeasurement >"$output_file" 2>&1; then
    sed -n '1,240p' "$output_file" >&2
    exit 1
fi
if ! swift test --disable-sandbox \
    --filter screenProjectionReusesStableInventoryAndTracksExternalPartials \
    >>"$output_file" 2>&1; then
    sed -n '1,320p' "$output_file" >&2
    exit 1
fi
if ! swift test --disable-sandbox \
    --filter twoRealSwiftProcessesAllowExactlyOneStaleCatalogWriter \
    >>"$output_file" 2>&1; then
    sed -n '1,400p' "$output_file" >&2
    exit 1
fi

vault_resolutions="$(sed -n 's/.*VAULT_READ_OPTIMIZATION_METRICS manifest_resolutions=\([0-9][0-9]*\).*/\1/p' "$output_file" | tail -1)"
snapshot_peak_bytes="$(sed -n 's/.*snapshot_peak_bytes=\([0-9][0-9]*\).*/\1/p' "$output_file" | tail -1)"
idle_refreshes="$(sed -n 's/.*LAN_OBSERVATION_OPTIMIZATION_METRICS idle_full_refreshes=\([0-9][0-9]*\).*/\1/p' "$output_file" | tail -1)"
partial_refreshes="$(sed -n 's/.*partial_refreshes=\([0-9][0-9]*\).*/\1/p' "$output_file" | tail -1)"

if [ -z "$vault_resolutions" ] || [ -z "$snapshot_peak_bytes" ] \
    || [ -z "$idle_refreshes" ] || [ -z "$partial_refreshes" ]; then
    sed -n '1,320p' "$output_file" >&2
    exit 1
fi

finished_at="$(date +%s)"
measurement_seconds="$((finished_at - started_at))"
redundant_io_operations="$((vault_resolutions + idle_refreshes))"

printf '{"redundant_io_operations":%s,"vault_correctness_passed":1,"lan_correctness_passed":1,"cross_process_visibility_passed":1,"snapshot_peak_bytes":%s,"tests_passed":1,"vault_manifest_resolutions":%s,"lan_idle_full_refreshes":%s,"lan_partial_refreshes":%s,"measurement_seconds":%s}\n' \
    "$redundant_io_operations" \
    "$snapshot_peak_bytes" \
    "$vault_resolutions" \
    "$idle_refreshes" \
    "$partial_refreshes" \
    "$measurement_seconds"
