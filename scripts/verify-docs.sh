#!/bin/zsh
set -euo pipefail

umask 077

SCRIPT_DIR=${0:A:h}

fail() {
  echo "Documentation verification failed: $1" >&2
  exit 1
}

REPO_DIR=${KINLOGUE_DOCS_REPO_DIR:-${SCRIPT_DIR:h}}
[[ -d "$REPO_DIR" && ! -L "$REPO_DIR" ]] \
  || fail "repository root is missing or linked"
REPO_DIR=${REPO_DIR:A}
INFO_PLIST="$REPO_DIR/packaging/Info.plist"

[[ -x /usr/bin/ruby && ! -L /usr/bin/ruby ]] \
  || fail "the system Ruby interpreter is unavailable"
[[ -f "$INFO_PLIST" && ! -L "$INFO_PLIST" ]] \
  || fail "packaging/Info.plist is missing or linked"

# Keep the current candidate ledger tied to authoritative Info.plist keys.
# docs/acceptance/current-release.md is the single owner of the volatile test
# inventory and release states; navigation pages link to it instead of copying it.
SHORT_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
BUILD_VERSION="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
MINIMUM_SYSTEM="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$INFO_PLIST")"
FACT_DOCUMENT="$REPO_DIR/docs/acceptance/current-release.md"
[[ -f "$FACT_DOCUMENT" && ! -L "$FACT_DOCUMENT" ]] \
  || fail "current release evidence is missing or linked"
FACT_PATTERN="^<!-- release-facts: short=$SHORT_VERSION build=$BUILD_VERSION minimum-macos=$MINIMUM_SYSTEM tests=[0-9]+ suites=[0-9]+ automated-gates=(passed|not-verified) overall=(pendingManual|passed|blocked|notExecuted) -->$"
FACT_MARKERS=("${(@f)$(/usr/bin/grep -E -- "$FACT_PATTERN" "$FACT_DOCUMENT" || true)}")
[[ "${#FACT_MARKERS[@]}" -eq 1 && -n "$FACT_MARKERS[1]" ]] \
  || fail "docs/acceptance/current-release.md must contain exactly one current release-facts marker"
FACT_MARKER="$FACT_MARKERS[1]"
TEST_COUNT="${${FACT_MARKER##* tests=}%% suites=*}"
SUITE_COUNT="${${FACT_MARKER##* suites=}%% automated-gates=*}"
AUTOMATED_GATE_STATUS="${${FACT_MARKER##* automated-gates=}%% overall=*}"
OVERALL_STATUS="${${FACT_MARKER##* overall=}%% -->}"

REQUIRE_TEST_EVIDENCE="${KINLOGUE_REQUIRE_TEST_EVIDENCE:-0}"
[[ "$REQUIRE_TEST_EVIDENCE" == 0 || "$REQUIRE_TEST_EVIDENCE" == 1 ]] \
  || fail "KINLOGUE_REQUIRE_TEST_EVIDENCE must be 0 or 1"
if [[ "$REQUIRE_TEST_EVIDENCE" == 1 && -z "${KINLOGUE_TEST_RESULT_FILE:-}" ]]; then
  fail "test-evidence mode requires an observed full test result"
fi

if [[ -n "${KINLOGUE_TEST_RESULT_FILE:-}" ]]; then
  TEST_RESULT_FILE="$KINLOGUE_TEST_RESULT_FILE"
  [[ -f "$TEST_RESULT_FILE" && ! -L "$TEST_RESULT_FILE" ]] \
    || fail "the observed test result file is missing or linked"
  OBSERVED_TEST_SUMMARIES=("${(@f)$(/usr/bin/sed -nE \
    's/.*Test run with ([0-9]+) tests in ([0-9]+) suites passed.*/\1 \2/p' \
    "$TEST_RESULT_FILE")}")
  [[ "${#OBSERVED_TEST_SUMMARIES[@]}" -eq 1 \
      && -n "$OBSERVED_TEST_SUMMARIES[1]" ]] \
    || fail "the full test output must contain exactly one passing test summary"
  OBSERVED_TEST_COUNT="${OBSERVED_TEST_SUMMARIES[1]%% *}"
  OBSERVED_SUITE_COUNT="${OBSERVED_TEST_SUMMARIES[1]##* }"
  [[ "$TEST_COUNT" == "$OBSERVED_TEST_COUNT" \
      && "$SUITE_COUNT" == "$OBSERVED_SUITE_COUNT" ]] \
    || fail "release facts do not match observed test result: $OBSERVED_TEST_COUNT tests / $OBSERVED_SUITE_COUNT suites"
fi

CURRENT_TEST_FACT="$TEST_COUNT tests / $SUITE_COUNT suites"
/usr/bin/grep -Fq -- "$CURRENT_TEST_FACT" "$FACT_DOCUMENT" \
  || fail "current release evidence does not contain the current test inventory: $CURRENT_TEST_FACT"

for relative_path in \
  README.md \
  docs/index.md \
  docs/project-overview.md \
  docs/testing-and-release.md; do
  document="$REPO_DIR/$relative_path"
  [[ -f "$document" && ! -L "$document" ]] \
    || fail "current-state document is missing or linked: $relative_path"
  /usr/bin/grep -Fq -- "acceptance/current-release.md" "$document" \
    || fail "$relative_path does not link to the current release evidence"
done

if [[ "$AUTOMATED_GATE_STATUS" == passed ]] \
    && /usr/bin/grep -Eq -- '文档/lint[^。|]*失败' \
      "$FACT_DOCUMENT"; then
  fail "current-state docs contradict the passed release gate marker"
fi

if [[ "$OVERALL_STATUS" == passed && "$AUTOMATED_GATE_STATUS" != passed ]]; then
  fail "overall release state cannot pass while automated gates are not verified"
fi

/usr/bin/ruby - "$REPO_DIR" <<'RUBY'
require "pathname"
require "uri"

repo = File.realpath(ARGV.fetch(0))
failures = []
repo_prefix = repo + File::SEPARATOR
inside_repo = ->(path) { path == repo || path.start_with?(repo_prefix) }
markdown_files = []
Dir.glob(File.join(repo, "**", "*.md"))
  .reject { |path| path.include?("/.build/") || path.include?("/dist/") }
  .each do |path|
    relative_path = Pathname.new(path).relative_path_from(Pathname.new(repo))
    begin
      real_path = File.realpath(path)
    rescue SystemCallError
      failures << "unreadable documentation file: #{relative_path}"
      next
    end
    unless inside_repo.call(real_path)
      failures << "documentation file escapes the repository through symlink: #{relative_path}"
      next
    end
    markdown_files << real_path
  end
markdown_files.uniq!
graph = Hash.new { |hash, key| hash[key] = [] }
markdown_contents = {}

markdown_files.each do |source|
  content = File.read(source, encoding: "UTF-8")
  markdown_contents[source] = content
  content.scan(/!?\[[^\]]*\]\(([^)\n]+)\)/) do |match|
    raw_target = match.fetch(0).strip
    raw_target = raw_target[1...-1] if raw_target.start_with?("<") && raw_target.end_with?(">")
    next if raw_target.empty? || raw_target.start_with?("#")
    next if raw_target.match?(/\A(?:https?|mailto|app):/i)

    path_part = raw_target.split("#", 2).first
    begin
      path_part = URI::DEFAULT_PARSER.unescape(path_part)
    rescue ArgumentError
      failures << "invalid local Markdown link in #{Pathname.new(source).relative_path_from(Pathname.new(repo))}: #{raw_target}"
      next
    end
    resolved = File.expand_path(path_part, File.dirname(source))
    relative_source = Pathname.new(source).relative_path_from(Pathname.new(repo))
    unless resolved == repo || resolved.start_with?(repo + File::SEPARATOR)
      failures << "missing local Markdown link from #{relative_source}: #{raw_target} escapes the repository"
      next
    end
    unless File.exist?(resolved)
      failures << "missing local Markdown link from #{relative_source}: #{raw_target}"
      next
    end
    begin
      real_target = File.realpath(resolved)
    rescue SystemCallError
      failures << "unreadable local Markdown link from #{relative_source}: #{raw_target}"
      next
    end
    unless inside_repo.call(real_target)
      failures << "missing local Markdown link from #{relative_source}: #{raw_target} " \
        "escapes the repository through symlink"
      next
    end
    graph[source] << real_target if File.file?(real_target) && File.extname(real_target) == ".md"
  end
end

roots = %w[AGENTS.md README.md PRIVACY.md docs/index.md]
  .map { |path| File.realpath(File.join(repo, path)) }
reachable = {}
pending = roots.dup
pending_index = 0
while pending_index < pending.length
  current = pending.fetch(pending_index)
  pending_index += 1
  next if reachable[current]
  reachable[current] = true
  graph[current].each { |destination| pending << destination unless reachable[destination] }
end
Dir.glob(File.join(repo, "docs", "**", "*.md")).sort.each do |page|
  real_page = File.realpath(page)
  next if reachable[real_page]
  relative_page = Pathname.new(real_page).relative_path_from(Pathname.new(repo))
  failures << "unreachable documentation page from docs/index.md or public roots: #{relative_page}"
end

swift_files = Dir.glob(File.join(repo, "Sources", "**", "*.swift")).sort
unchecked = []
unsafe = []
swift_files.each do |source|
  recent_lines = []
  File.open(source, "r:UTF-8") do |file|
    file.each_line.with_index do |line, index|
      if line.include?("@unchecked Sendable") || line.include?("nonisolated(unsafe)")
        occurrence = [source, index + 1]
        unchecked << occurrence if line.include?("@unchecked Sendable")
        unsafe << occurrence if line.include?("nonisolated(unsafe)")
        unless recent_lines.any? { |context| context.include?("SAFETY:") }
          relative_source = Pathname.new(source).relative_path_from(Pathname.new(repo))
          failures << "missing nearby SAFETY: invariant for #{relative_source}:#{index + 1}"
        end
      end
      recent_lines << line
      recent_lines.shift if recent_lines.length > 8
    end
  end
end
unchecked_files = unchecked.map(&:first).uniq.length
dicom_unchecked = unchecked.count do |source, _line|
  source.start_with?(File.join(repo, "Sources", "KinloguePlatform", "DICOM") + File::SEPARATOR)
end
core_unchecked = unchecked.count do |source, _line|
  source.start_with?(File.join(repo, "Sources", "KinlogueCore") + File::SEPARATOR)
end
inventory = "<!-- concurrency-inventory: unchecked=#{unchecked.length} files=#{unchecked_files} " \
  "dicom=#{dicom_unchecked} core=#{core_unchecked} unsafe=#{unsafe.length} -->"
audit_path = File.join(repo, "docs", "concurrency-safety-audit.md")
unless markdown_contents.fetch(File.realpath(audit_path)).include?(inventory)
  failures << "concurrency audit inventory is stale; expected #{inventory}"
end

Dir.glob(File.join(repo, "docs", "plans", "*.md")).sort.each do |plan|
  lines = File.readlines(plan, encoding: "UTF-8")
  closing_index = lines[1..-1].index { |line| line.strip == "---" }
  frontmatter = closing_index ? lines[0..(closing_index + 1)] : []
  unless frontmatter.any? { |line| line.match?(/\Astatus:\s*\S+/) }
    relative_plan = Pathname.new(plan).relative_path_from(Pathname.new(repo))
    failures << "plan frontmatter is missing status: #{relative_plan}"
  end
end

architecture = markdown_contents.fetch(File.realpath(File.join(repo, "docs", "architecture.md")))
if architecture.include?("最后一个正常 reply 发送后 Helper 主动退出")
  failures << "architecture still claims that the DICOM Helper exits after a successful reply"
end
testing = markdown_contents.fetch(
  File.realpath(File.join(repo, "docs", "testing-and-release.md"))
)
if testing.include?("U4 尚未把 DICOM 导入接入 App")
  failures << "testing-and-release still describes the implemented DICOM App flow as pending"
end
unless failures.empty?
  warn failures.map { |failure| "Documentation verification failed: #{failure}" }.join("\n")
  exit 1
end
RUBY

echo "Documentation verification passed"
