#!/usr/bin/ruby
# frozen_string_literal: true

TARGET_SUITE = "KinloguePlatformTests.LANDerivedArtifactSinkTests"

def fail_closed(message)
  warn("Dedicated XCTest discovery failed: #{message}")
  exit(1)
end

fail_closed("expected one SwiftPM test-list file") unless ARGV.length == 1
path = ARGV.fetch(0)
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
unless specifiers.all? { |specifier| specifier.match?(/\AKinlogue(?:Core|Platform|App|StorageProcess)Tests\.\S+\z/) }
  fail_closed("test list contains an unexpected specifier")
end

prefix = "#{TARGET_SUITE}/"
selectors = specifiers.select { |specifier| specifier.start_with?(prefix) }
fail_closed("target suite is missing from the built test inventory") if selectors.empty?
unless selectors.all? { |selector| selector.match?(/\A#{Regexp.escape(prefix)}test[A-Za-z0-9_]+\z/) }
  fail_closed("target suite contains an unexpected XCTest selector")
end
fail_closed("target suite contains duplicate selectors") unless selectors.uniq.length == selectors.length

puts(selectors.sort)
