#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"

# Exit statuses that do not collide with timeout (124), start failure (126), INT (130) or TERM (143).
RESIDUAL_MEMBERS_STATUS = 122
UNRECLAIMED_MEMBERS_STATUS = 123
# How long members may take to exit on their own after the leader exits normally.
SETTLE_SECONDS = 2.0
# How long the group may take to disappear after the final signal.
FINAL_SIGNAL_WAIT_SECONDS = 2.0
# Test-only hook: "0" weakens the final signal so a survivor can be simulated. It can only make the
# wrapper fail, because emptiness is always checked with kill(0) against the owned group.
FINAL_SIGNAL_HOOK = "IOS_TEMPLATE_BOUNDED_COMMAND_TEST_FINAL_SIGNAL"

options = {grace_seconds: 5}
parser = OptionParser.new do |cli|
  cli.banner = "usage: bounded-command.rb --stage NAME --timeout-seconds N [--grace-seconds N] [--elapsed-file PATH] -- COMMAND [ARG ...]"
  cli.on("--stage NAME") { |value| options[:stage] = value }
  cli.on("--timeout-seconds N", Integer) { |value| options[:timeout_seconds] = value }
  cli.on("--grace-seconds N", Integer) { |value| options[:grace_seconds] = value }
  cli.on("--elapsed-file PATH") { |value| options[:elapsed_file] = value }
end

begin
  separator = ARGV.index("--")
  raise OptionParser::MissingArgument, "--" unless separator
  option_arguments = ARGV.take(separator)
  command = ARGV.drop(separator + 1)
  parser.parse!(option_arguments)
  raise OptionParser::InvalidArgument, "unexpected arguments" unless option_arguments.empty?
  stage = options[:stage]
  timeout_seconds = options[:timeout_seconds]
  grace_seconds = options[:grace_seconds]
  elapsed_file = options[:elapsed_file]
  unless stage&.match?(/\A[A-Za-z0-9_.-]{1,80}\z/) && timeout_seconds&.positive? &&
         grace_seconds.is_a?(Integer) && grace_seconds.between?(1, 30) && !command.empty? &&
         (elapsed_file.nil? || elapsed_file.start_with?("/"))
    raise OptionParser::InvalidArgument, "invalid stage, timeout, grace period, elapsed file, or command"
  end
  final_signal = ENV.fetch(FINAL_SIGNAL_HOOK, "KILL")
  raise OptionParser::InvalidArgument, "invalid #{FINAL_SIGNAL_HOOK}" unless %w[KILL 0].include?(final_signal)
  final_signal = final_signal == "0" ? 0 : "KILL"
rescue OptionParser::ParseError => error
  warn error.message
  warn parser
  exit 2
end

def monotonic_now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

started = monotonic_now
child = nil
forwarded_signal = nil

signal_group = lambda do |signal|
  Process.kill(signal, -child)
rescue Errno::ESRCH
  nil
end

group_alive = lambda do
  Process.kill(0, -child)
  true
rescue Errno::ESRCH
  false
rescue Errno::EPERM
  true
end

wait_group_empty = lambda do |seconds|
  deadline = monotonic_now + seconds
  loop do
    return true unless group_alive.call
    return false if monotonic_now >= deadline
    sleep 0.05
  end
end

# Counts the remaining members of the owned group. Returns at least 1 while the group exists.
group_member_count = lambda do
  return 0 unless group_alive.call
  output = IO.popen(["/bin/ps", "-A", "-o", "pgid=", "-o", "stat="], err: File::NULL, &:read)
  count = output.each_line.count do |line|
    group, state = line.split
    group.to_i == child && !state.to_s.start_with?("Z")
  end
  [count, 1].max
rescue SystemCallError, IOError
  1
end

# Sends TERM, waits for grace, then the final signal. Returns the members still present afterwards.
reclaim_group = lambda do
  signal_group.call("TERM")
  unless wait_group_empty.call(grace_seconds)
    signal_group.call(final_signal)
    wait_group_empty.call(FINAL_SIGNAL_WAIT_SECONDS)
  end
  group_member_count.call
end

finish = lambda do |status_code|
  if elapsed_file
    begin
      File.write(elapsed_file, format("%.3f\n", monotonic_now - started))
    rescue SystemCallError
      warn "bounded command could not record the elapsed time: stage=#{stage}"
    end
  end
  exit status_code
end

%w[INT TERM].each do |signal|
  Signal.trap(signal) do
    forwarded_signal = signal
    begin
      Process.kill(signal, -child) if child
    rescue Errno::ESRCH
      nil
    end
  end
end

begin
  child = Process.spawn(*command, pgroup: true)
rescue SystemCallError => error
  warn "bounded command could not start: stage=#{stage} error=#{error.class}"
  finish.call(126)
end

deadline = started + timeout_seconds
status = nil
loop do
  waited = Process.waitpid2(child, Process::WNOHANG)
  if waited
    status = waited.last
    break
  end
  break if monotonic_now >= deadline || forwarded_signal
  sleep 0.05
end

if status && forwarded_signal.nil?
  leader_status = status.exitstatus || 128 + status.termsig
  finish.call(leader_status) if wait_group_empty.call(SETTLE_SECONDS)
  residual = group_member_count.call
  remaining = reclaim_group.call
  elapsed = monotonic_now - started
  if remaining.positive?
    warn format(
      "bounded command could not reclaim process-group members: stage=%s elapsedSeconds=%.3f residualMembers=%d leaderStatus=%d",
      stage, elapsed, remaining, leader_status
    )
    finish.call(UNRECLAIMED_MEMBERS_STATUS)
  end
  warn format(
    "bounded command reclaimed residual process-group members: stage=%s elapsedSeconds=%.3f residualMembers=%d leaderStatus=%d",
    stage, elapsed, residual, leader_status
  )
  finish.call(RESIDUAL_MEMBERS_STATUS)
end

timed_out = forwarded_signal.nil?
signal = forwarded_signal || "TERM"
signal_group.call(signal)
grace_deadline = monotonic_now + grace_seconds
until status
  waited = Process.waitpid2(child, Process::WNOHANG)
  if waited
    status = waited.last
    break
  end
  break if monotonic_now >= grace_deadline
  sleep 0.05
end
unless status
  signal_group.call(final_signal)
  # The leader may not terminate promptly even after KILL; never wait for it without a deadline.
  final_deadline = monotonic_now + FINAL_SIGNAL_WAIT_SECONDS
  until status || monotonic_now >= final_deadline
    waited = Process.waitpid2(child, Process::WNOHANG)
    status = waited.last if waited
    sleep 0.05 unless status
  end
end
# The leader may be gone while members that ignore the delivered signal remain; reclaim them
# with TERM, grace, and the final signal before reporting.
remaining = wait_group_empty.call(0) ? 0 : reclaim_group.call
elapsed = monotonic_now - started
if remaining.positive?
  warn format(
    "bounded command could not reclaim process-group members: stage=%s elapsedSeconds=%.3f residualMembers=%d timeoutSeconds=%d",
    stage, elapsed, remaining, timeout_seconds
  )
  finish.call(UNRECLAIMED_MEMBERS_STATUS)
end
if timed_out
  warn format(
    "bounded command timed out: stage=%s elapsedSeconds=%.3f timeoutSeconds=%d",
    stage, elapsed, timeout_seconds
  )
  finish.call(124)
end
finish.call(forwarded_signal == "INT" ? 130 : 143)
