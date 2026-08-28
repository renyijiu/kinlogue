#!/usr/bin/ruby
# frozen_string_literal: true

def fail_usage(message)
  warn("Test shard supervision failed: #{message}")
  exit(64)
end

fail_usage("expected counts and a command") if ARGV.length < 3

if Process.getsid(0) != Process.pid
  child_pid = fork do
    Process.setsid
    exec("/usr/bin/ruby", __FILE__, *ARGV)
  end
  _, child_status = Process.waitpid2(child_pid)
  exit(child_status.exitstatus || 128 + child_status.termsig)
end

begin
  expected_tests = Integer(ARGV.shift, 10)
  expected_suites = Integer(ARGV.shift, 10)
  grace_seconds = Integer(ENV.fetch("KINLOGUE_TEST_SUMMARY_GRACE_SECONDS", "5"), 10)
  maximum_seconds = Integer(ENV.fetch("KINLOGUE_TEST_SUMMARY_MAX_SECONDS", "0"), 10)
rescue ArgumentError
  fail_usage("counts and grace must be integers")
end
fail_usage("expected test count must be positive") unless expected_tests.positive?
fail_usage("expected suite count must be nonnegative") if expected_suites.negative?
fail_usage("grace must be from 1 through 30 seconds") unless (1..30).cover?(grace_seconds)
unless maximum_seconds.zero? || (1..86_400).cover?(maximum_seconds)
  fail_usage("maximum duration must be zero or from 1 through 86400 seconds")
end

# The production caller establishes a dedicated session. Direct regression
# invocations fork into one above so cleanup can never target the parent test.
session_id = Process.getsid(0)
fail_usage("could not establish an owned session") unless session_id == Process.pid

STDOUT.sync = true
summary_pattern = /Test\s+run\s+with\s+#{expected_tests}\s+tests?\s+in\s+#{expected_suites}\s+suites?\s+passed/n
ansi_pattern = /\x1B(?:\[[0-?]*[ -\/]*[@-~]|\][^\x07]*(?:\x07|\x1B\x5C))/n
puts("KLT_TEST_SHARD_EXPECTED tests=#{expected_tests} suites=#{expected_suites}")
reader, writer = IO.pipe
command_pid = Process.spawn(*ARGV, out: writer, err: writer)
writer.close

command_status = nil
reader_eof = false
summary_seen_at = nil
summary_announced = false
output_tail = +"".b
started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
last_inventory_at = started_at
owned_identities = {}

process_table = lambda do
  pipe = IO.popen(["/bin/ps", "-axo", "pid=,ppid=,lstart="])
  ps_pid = pipe.pid
  output = pipe.read
  pipe.close
  raise "process inventory failed" unless $?&.success?

  table = output.each_line.to_h do |line|
    pid_text, parent_text, identity = line.strip.split(/\s+/, 3)
    [Integer(pid_text, 10), [Integer(parent_text, 10), identity]]
  rescue ArgumentError
    [0, [0, ""]]
  end
  table.delete(0)
  [table, ps_pid]
end

refresh_owned_members = lambda do
  table, ps_pid = process_table.call
  live = {}

  table.each do |pid, (_, identity)|
    next if pid == Process.pid || pid == ps_pid

    if owned_identities[pid] == identity
      live[pid] = true
      next
    end
    live[pid] = true if Process.getsid(pid) == session_id
  rescue Errno::ESRCH, Errno::EPERM
    next
  end

  loop do
    added = false
    table.each do |pid, (parent_pid, _)|
      next if live.key?(pid) || pid == Process.pid || pid == ps_pid
      next unless live.key?(parent_pid)

      live[pid] = true
      added = true
    end
    break unless added
  end

  live.each_key do |pid|
    identity = table[pid]&.last
    owned_identities[pid] = identity if identity
  end
  live.keys
end

refresh_owned_members.call

poll_status = lambda do
  next command_status unless command_status.nil?

  waited = Process.waitpid2(command_pid, Process::WNOHANG)
  command_status = waited&.last
rescue Errno::ECHILD
  command_status
end

status_code = lambda do |status|
  next status.exitstatus unless status.exitstatus.nil?
  next 128 + status.termsig unless status.termsig.nil?

  70
end

terminate_owned_processes = lambda do
  10.times do
    members = refresh_owned_members.call
    break if members.empty?
    members.each do |pid|
      Process.kill("TERM", pid)
    rescue Errno::ESRCH, Errno::EPERM
      next
    end
    sleep(0.05)
    poll_status.call
  end
  20.times do
    members = refresh_owned_members.call
    break if members.empty?
    members.each do |pid|
      Process.kill("KILL", pid)
    rescue Errno::ESRCH, Errno::EPERM
      next
    end
    sleep(0.05)
    poll_status.call
  end
  refresh_owned_members.call.empty?
end

loop do
  now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  if now - last_inventory_at >= 0.1
    refresh_owned_members.call
    last_inventory_at = now
  end

  if IO.select([reader], nil, nil, 0.05)
    chunk = reader.read_nonblock(16_384, exception: false)
    if chunk.nil?
      reader_eof = true
    elsif chunk != :wait_readable
      STDOUT.write(chunk)
      output_tail << chunk.b
      output_tail = output_tail.byteslice(-65_536, 65_536) if output_tail.bytesize > 65_536
      normalized_tail = output_tail.gsub(ansi_pattern, "".b)
      if normalized_tail.match?(summary_pattern)
        summary_seen_at ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
        refresh_owned_members.call
        unless summary_announced
          puts("KLT_TEST_SUMMARY_OBSERVED tests=#{expected_tests} suites=#{expected_suites}")
          summary_announced = true
        end
      end
    end
  end

  poll_status.call
  if command_status && !command_status.success?
    terminate_owned_processes.call
    exit(status_code.call(command_status))
  end

  if command_status && reader_eof
    members = refresh_owned_members.call
    if members.empty?
      unless summary_seen_at
        warn("Test shard supervision failed: exact passing summary is missing")
        exit(70)
      end
      exit(0)
    end
  end

  if maximum_seconds.positive? \
      && Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at >= maximum_seconds
    terminate_owned_processes.call
    exit(124)
  end

  next unless summary_seen_at
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - summary_seen_at
  next if elapsed < grace_seconds

  unless terminate_owned_processes.call
    warn("Test shard supervision failed: owned processes did not terminate")
    exit(70)
  end
  warn("Test shard supervision failed: test process remained alive after its passing summary")
  exit(70)
end
