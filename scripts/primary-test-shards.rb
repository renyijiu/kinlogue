#!/usr/bin/ruby
# frozen_string_literal: true

SINGLE_TEST_BATCH_SIZE = 16
CONTAINERS_PER_SHARD = 2
DEDICATED_FRESH_RUNNER_CONTAINERS = [
  "KinloguePlatformTests.LANDerivedArtifactSinkTests",
].freeze

def fail_closed(message)
  warn("Primary test shard planning failed: #{message}")
  exit(1)
end

inventory_summary = ARGV.first == "--inventory-summary"
ARGV.shift if inventory_summary
fail_closed("expected a test-list file and optional partition") unless [1, 3].include?(ARGV.length)
fail_closed("inventory summary does not accept a partition") if inventory_summary && ARGV.length != 1
path = ARGV.fetch(0)
begin
  partition_index = ARGV.length == 3 ? Integer(ARGV.fetch(1), 10) : 0
  partition_count = ARGV.length == 3 ? Integer(ARGV.fetch(2), 10) : 1
rescue ArgumentError
  fail_closed("partition values must be integers")
end
unless (1..16).cover?(partition_count) && (0...partition_count).cover?(partition_index)
  fail_closed("partition must select one of at most sixteen runners")
end
begin
  stat = File.lstat(path)
rescue SystemCallError
  fail_closed("test-list file is unavailable")
end
fail_closed("test-list file must be a regular non-link") unless stat.file? && !stat.symlink?
fail_closed("test-list file exceeds the bounded size") if stat.size > 8 * 1_024 * 1_024

specifiers = File.readlines(path, chomp: true).reject(&:empty?)
fail_closed("test list is empty") if specifiers.empty?
fail_closed("test list contains duplicate specifiers") unless specifiers.uniq.length == specifiers.length

specifier_pattern = /\AKinlogue(?:Core|Platform|App|StorageProcess)Tests\.\S+\z/
unless specifiers.all? { |specifier| specifier.match?(specifier_pattern) }
  fail_closed("test list contains an unexpected specifier")
end

runtime_identifier = lambda do |specifier|
  specifier.sub(/\(.*\)\z/, "")
end
runtime_identifiers = specifiers.map(&runtime_identifier)
unless runtime_identifiers.uniq.length == runtime_identifiers.length
  fail_closed("test list contains runtime-ambiguous specifiers")
end

required_prefixes = [
  "KinlogueCoreTests.",
  "KinloguePlatformTests.",
  "KinlogueAppTests.",
  "KinlogueStorageProcessTests.",
]
required_prefixes.each do |prefix|
  fail_closed("required test target is missing") unless specifiers.any? { |value| value.start_with?(prefix) }
end

dicom_prefix = "KinloguePlatformTests.DICOMImportWorkflowIntegrationTests/"
acceptance_prefix = "KinlogueAppTests.AcceptanceScanScriptTests/"
installed_lan = "KinlogueAppTests.SyntheticAcceptanceRunnerTests/" \
  "installedLANProbeUsesProductionHTTPAndPersistsAcrossProcessPhases()"
real_socket = "KinloguePlatformTests.LANRealSocketBackpressureTests/" \
  "productionFileQueueStaysBoundedWithTwoStreamsSlowPeersAndDisconnect()"
case_alias = "KinloguePlatformTests." \
  "differentlyCasedVaultAliasesShareStableAndLegacyLockIdentity()"

fail_closed("isolated DICOM suite is missing") unless specifiers.any? { |value| value.start_with?(dicom_prefix) }
fail_closed("isolated acceptance suite is missing") unless specifiers.any? { |value| value.start_with?(acceptance_prefix) }
fail_closed("isolated installed LAN test is missing") unless specifiers.include?(installed_lan)
fail_closed("isolated real socket test is missing") unless specifiers.include?(real_socket)
fail_closed("conditional case-alias test is missing") unless specifiers.include?(case_alias)

isolated = lambda do |specifier|
  specifier.start_with?("KinlogueStorageProcessTests.") ||
    specifier.start_with?(dicom_prefix) ||
    specifier.start_with?(acceptance_prefix) ||
    specifier == installed_lan ||
    specifier == real_socket ||
    specifier == case_alias
end

primary = specifiers.select do |specifier|
  (specifier.start_with?("KinloguePlatformTests.") ||
    specifier.start_with?("KinlogueAppTests.")) && !isolated.call(specifier)
end
fail_closed("no Platform or App primary tests remain") if primary.empty?

groups = primary.group_by { |specifier| specifier.include?("/") ? specifier.split("/", 2).first : specifier }
isolated_group_keys = specifiers.select(&isolated).map do |specifier|
  specifier.include?("/") ? specifier.split("/", 2).first : specifier
end.to_h { |group| [group, true] }
shards = []
multi_groups = []
single_groups = []
dedicated_groups = []
groups.keys.sort.each do |group|
  values = groups.fetch(group)
  if DEDICATED_FRESH_RUNNER_CONTAINERS.include?(group)
    fail_closed("a dedicated container overlaps an isolated gate") if isolated_group_keys.key?(group)
    dedicated_groups << [group, values]
  elsif isolated_group_keys.key?(group)
    values.sort.each do |specifier|
      single_groups << [group, runtime_identifier.call(specifier), true]
    end
  elsif values.length > 1
    multi_groups << [group, values]
  else
    specifier = values.fetch(0)
    single_groups << [group, runtime_identifier.call(specifier), !specifier.include?("/")]
  end
end
unless dedicated_groups.map(&:first).sort == DEDICATED_FRESH_RUNNER_CONTAINERS.sort
  fail_closed("a dedicated fresh-runner container is missing")
end

multi_groups.each_slice(CONTAINERS_PER_SHARD) do |batch|
  alternatives = batch.map { |group, _| "#{Regexp.escape(group)}/" }
  values = batch.flat_map(&:last)
  shards << ["^(?:#{alternatives.join('|')})", values, false]
end

dedicated_groups.each do |group, values|
  shards << ["^(?:#{Regexp.escape(group)}/)", values, true]
end

single_groups.each_slice(SINGLE_TEST_BATCH_SIZE) do |batch|
  alternatives = batch.map do |group, identifier, exact|
    if exact
      "#{Regexp.escape(identifier)}\\b"
    else
      "#{Regexp.escape(group)}/"
    end
  end
  shards << ["^(?:#{alternatives.join('|')})", batch.map { |_, specifier, _| specifier }, false]
end
shards.sort_by!(&:first)

compiled = shards.map { |pattern, _, _| Regexp.new(pattern) }
primary.each do |specifier|
  identifier = runtime_identifier.call(specifier)
  unless compiled.count { |pattern| pattern.match?(identifier) } == 1
    fail_closed("a primary test is omitted or duplicated")
  end
end
(specifiers - primary).each do |specifier|
  identifier = runtime_identifier.call(specifier)
  if compiled.any? { |pattern| pattern.match?(identifier) }
    fail_closed("an excluded test entered a primary shard")
  end
end

if inventory_summary
  core_specifiers = specifiers.select { |specifier| specifier.start_with?("KinlogueCoreTests.") }
  primary_shards = shards.reject { |_, _, dedicated| dedicated }
  test_count = core_specifiers.length + primary_shards.sum { |_, values, _| values.length }
  suite_count = core_specifiers.map do |specifier|
    specifier.split("/", 2).first if specifier.include?("/")
  end.compact.uniq.length
  suite_count += primary_shards.sum do |_, values, _|
    values.map do |specifier|
      specifier.split("/", 2).first if specifier.include?("/")
    end.compact.uniq.length
  end
  fail_closed("primary inventory is empty") unless test_count.positive?
  puts("KLT_PRIMARY_TEST_INVENTORY tests=#{test_count} suites=#{suite_count}")
  exit(0)
end

selected_shards = if partition_count == 1
                    shards.reject { |_, _, dedicated| dedicated }
                  elsif partition_index == partition_count - 1
                    shards.select { |_, _, dedicated| dedicated }
                  else
                    shards.reject { |_, _, dedicated| dedicated }
                      .each_with_index
                      .select { |_, index| index % (partition_count - 1) == partition_index }
                      .map(&:first)
                  end

selected_shards.each do |pattern, values, _|
  suite_count = values.map do |specifier|
    specifier.split("/", 2).first if specifier.include?("/")
  end.compact.uniq.length
  puts([values.length, suite_count, pattern].join("\t"))
end
