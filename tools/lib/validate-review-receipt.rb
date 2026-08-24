#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require_relative "descriptor-files"
require_relative "review-receipt"

def reject(message)
  warn "review receipt validation failed: #{message}"
  exit 1
end

begin
repo, primary, issue_text, head_sha = ARGV
reject("invalid review receipt validator arguments") unless repo&.start_with?("/") && %w[codex claude].include?(primary) && issue_text&.match?(/\A[1-9][0-9]*\z/) && head_sha&.match?(/\A[0-9a-f]{40}\z/)
topology_output, topology_status = Open3.capture2e(
  {"GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil},
  "/usr/bin/ruby", File.join(repo, "tools/lib/review-artifacts.rb"), repo
)
reject("review artifact topology is invalid: #{topology_output.strip}") unless topology_status.success?
topology = JSON.parse(topology_output)
root = DescriptorFiles.open_directory(topology.fetch("artifactsRoot"))
handles = [root]
current = root
%W[issues #{issue_text} #{head_sha}].each do |component|
  current = DescriptorFiles.open_directory_at(current, component)
  handles << current
end

read = lambda do |name|
  io, stat = DescriptorFiles.open_regular_at(current, name)
  handles << io
  bytes = DescriptorFiles.read_opened(io, stat)
  [bytes, stat]
end
packet_bytes, = read.call("review-packet.json")
review_bytes, = read.call("review.json")
receipt_bytes, = read.call("review-receipt.json")
receipt = IOSTemplate::ReviewReceipt.validate!(
  receipt_bytes: receipt_bytes, packet_bytes: packet_bytes, review_bytes: review_bytes,
  repo: repo, primary: primary, issue: Integer(issue_text), head_sha: head_sha
)
puts JSON.generate(receipt)
rescue IOSTemplate::ReviewReceipt::ValidationError, JSON::ParserError, SystemCallError, IOError, KeyError => error
  reject(error.message)
ensure
  handles&.reverse_each { |handle| handle.close unless handle.closed? }
end
