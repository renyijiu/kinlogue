#!/bin/zsh
set -u
unsetopt BG_NICE

if [[ "$#" -lt 2 ]]; then
  print -u2 "usage: run-with-deadline.sh <seconds> <command> [arguments...]"
  exit 64
fi

TIMEOUT_SECONDS="$1"
shift

if [[ ! "$TIMEOUT_SECONDS" =~ '^[0-9]+$' ]] \
    || [[ "$TIMEOUT_SECONDS" -lt 1 || "$TIMEOUT_SECONDS" -gt 86400 ]]; then
  print -u2 "deadline must be an integer from 1 through 86400 seconds"
  exit 64
fi

[[ -x /usr/bin/ruby && ! -L /usr/bin/ruby ]] || {
  print -u2 "the system Ruby interpreter is unavailable"
  exit 69
}

signal_owned_process_group() {
  local signal_name="$1"
  /bin/kill "-$signal_name" "-$COMMAND_PGID" >/dev/null 2>&1 || true
}

owned_session_pids() {
  /usr/bin/ruby -e '
    session_id = Integer(ARGV.fetch(0))
    pids = IO.popen(["/bin/ps", "-axo", "pid="], &:read).split.map!(&:to_i)
    puts pids.select { |pid| Process.getsid(pid) == session_id rescue false }
  ' "$COMMAND_SESSION_ID"
}

signal_owned_session_members_outside_root_group() {
  local signal_name="$1"
  /usr/bin/ruby -e '
    signal_name = ARGV.fetch(0)
    session_id = Integer(ARGV.fetch(1))
    root_group = Integer(ARGV.fetch(2))
    pids = IO.popen(["/bin/ps", "-axo", "pid="], &:read).split.map!(&:to_i)
    pids.each do |pid|
      next unless Process.getsid(pid) == session_id
      next if Process.getpgid(pid) == root_group
      Process.kill(signal_name, pid) if Process.getsid(pid) == session_id
    rescue Errno::ESRCH, Errno::EPERM
      next
    end
  ' "$signal_name" "$COMMAND_SESSION_ID" "$COMMAND_PGID"
}

signal_owned_session() {
  local signal_name="$1"
  signal_owned_process_group "$signal_name"
  signal_owned_session_members_outside_root_group "$signal_name"
}

owned_session_is_alive() {
  /usr/bin/ruby -e '
    session_id = Integer(ARGV.fetch(0))
    pids = IO.popen(["/bin/ps", "-axo", "pid="], &:read).split.map!(&:to_i)
    exit(pids.any? { |pid| Process.getsid(pid) == session_id rescue false } ? 0 : 1)
  ' "$COMMAND_SESSION_ID"
}

owned_root_state() {
  local process_group
  process_group="$(/bin/ps -o pgid= -p "$COMMAND_PID" 2>/dev/null)" || return 1
  process_group="${process_group//[[:space:]]/}"
  [[ "$process_group" == "$COMMAND_PGID" ]] || return 1
  /bin/ps -o state= -p "$COMMAND_PID" 2>/dev/null
}

owned_root_is_running() {
  local state
  state="$(owned_root_state)" || return 1
  state="${state//[[:space:]]/}"
  [[ -n "$state" && "$state" != Z* ]]
}

reap_owned_root_if_exited() {
  [[ "$COMMAND_REAPED" == false ]] || return
  local state
  state="$(owned_root_state 2>/dev/null)" || state=""
  state="${state//[[:space:]]/}"
  if [[ -z "$state" || "$state" == Z* ]]; then
    wait "$COMMAND_PID" >/dev/null 2>&1 || true
    COMMAND_REAPED=true
  fi
}

print_process_diagnostics() {
  local parent_pid="$1"
  local owned_pid
  print -u2 "KLT_COMMAND_TIMEOUT seconds=$TIMEOUT_SECONDS root_pid=$parent_pid process_group=$COMMAND_PGID session=$COMMAND_SESSION_ID"
  for owned_pid in "${(@f)$(owned_session_pids)}"; do
    [[ "$owned_pid" =~ '^[1-9][0-9]*$' ]] || continue
    /bin/ps -o pid=,ppid=,pgid=,etime=,state=,ucomm= -p "$owned_pid" >&2 \
      || true
  done
}

terminate_owned_session_for_signal() {
  local exit_status="$1"
  trap - HUP INT TERM
  signal_owned_session TERM
  for _ in {1..10}; do
    reap_owned_root_if_exited
    owned_session_is_alive || exit "$exit_status"
    /bin/sleep 0.05
  done
  for _ in {1..20}; do
    signal_owned_session KILL
    reap_owned_root_if_exited
    owned_session_is_alive || exit "$exit_status"
    /bin/sleep 0.05
  done
  exit "$exit_status"
}

# A new session gives this invocation a stable ownership boundary. Descendants
# forked by a TERM handler inherit the process group and remain targetable.
/usr/bin/ruby -e 'Process.setsid; exec(*ARGV)' "$@" &
COMMAND_PID=$!
COMMAND_PGID=$COMMAND_PID
COMMAND_SESSION_ID=$COMMAND_PID
COMMAND_REAPED=false

# Wait for Ruby to establish the dedicated process group before starting the
# deadline. A short-lived command may already be a zombie, which is safe to
# reap because it still carries the owned group identity.
session_is_ready=false
for _ in {1..200}; do
  if owned_root_state >/dev/null 2>&1; then
    session_is_ready=true
    break
  fi
  if ! /bin/kill -0 "$COMMAND_PID" >/dev/null 2>&1; then
    wait "$COMMAND_PID"
    exit $?
  fi
  /bin/sleep 0.01
done
if [[ "$session_is_ready" != true ]]; then
  /bin/kill -TERM "$COMMAND_PID" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    /bin/kill -0 "$COMMAND_PID" >/dev/null 2>&1 || break
    /bin/sleep 0.1
  done
  /bin/kill -KILL "$COMMAND_PID" >/dev/null 2>&1 || true
  print -u2 "failed to establish an owned command process group"
  exit 70
fi

trap 'terminate_owned_session_for_signal 129' HUP
trap 'terminate_owned_session_for_signal 130' INT
trap 'terminate_owned_session_for_signal 143' TERM

integer elapsed_seconds=0

while owned_root_is_running; do
  if (( elapsed_seconds >= TIMEOUT_SECONDS )); then
    print_process_diagnostics "$COMMAND_PID"
    signal_owned_session TERM
    for _ in {1..10}; do
      reap_owned_root_if_exited
      owned_session_is_alive || break
      /bin/sleep 0.05
    done
    if owned_session_is_alive; then
      for _ in {1..10}; do
        signal_owned_session KILL
        reap_owned_root_if_exited
        owned_session_is_alive || break
        /bin/sleep 0.05
      done
    fi
    reap_owned_root_if_exited
    exit 124
  fi
  /bin/sleep 1
  (( elapsed_seconds += 1 ))
done

wait "$COMMAND_PID"
