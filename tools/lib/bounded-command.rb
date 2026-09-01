#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"

options = {grace_seconds: 5}
parser = OptionParser.new do |cli|
  cli.banner = "usage: bounded-command.rb --stage NAME --timeout-seconds N [--grace-seconds N] -- COMMAND [ARG ...]"
  cli.on("--stage NAME") { |value| options[:stage] = value }
  cli.on("--timeout-seconds N", Integer) { |value| options[:timeout_seconds] = value }
  cli.on("--grace-seconds N", Integer) { |value| options[:grace_seconds] = value }
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
  unless stage&.match?(/\A[A-Za-z0-9_.-]{1,80}\z/) && timeout_seconds&.positive? &&
         grace_seconds.is_a?(Integer) && grace_seconds.between?(1, 30) && !command.empty?
    raise OptionParser::InvalidArgument, "invalid stage, timeout, grace period, or command"
  end
rescue OptionParser::ParseError => error
  warn error.message
  warn parser
  exit 2
end

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
child = nil
forwarded_signal = nil

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
  exit 126
end

deadline = started + timeout_seconds
status = nil
loop do
  waited = Process.waitpid2(child, Process::WNOHANG)
  if waited
    status = waited.last
    break
  end
  break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline || forwarded_signal
  sleep 0.05
end

unless status
  timed_out = forwarded_signal.nil?
  signal = forwarded_signal || "TERM"
  begin
    Process.kill(signal, -child)
  rescue Errno::ESRCH
    nil
  end
  grace_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + grace_seconds
  loop do
    waited = Process.waitpid2(child, Process::WNOHANG)
    if waited
      status = waited.last
      break
    end
    break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= grace_deadline
    sleep 0.05
  end
  unless status
    begin
      Process.kill("KILL", -child)
    rescue Errno::ESRCH
      nil
    end
    _, status = Process.waitpid2(child)
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  if timed_out
    warn format(
      "bounded command timed out: stage=%s elapsedSeconds=%.3f timeoutSeconds=%d",
      stage, elapsed, timeout_seconds
    )
    exit 124
  end
  exit(forwarded_signal == "INT" ? 130 : 143)
end

exit(status.exitstatus || 128 + status.termsig)
