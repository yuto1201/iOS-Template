#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fiddle/import"
require "json"
require "open3"
require "time"
require_relative "review-receipt"

class PublishError < StandardError; end

module NativePublish
  extend Fiddle::Importer
  dlload Fiddle.dlopen(nil)
  extern "int openat(int, const char*, int, int)"
  extern "int fchmod(int, unsigned int)"
  extern "int unlinkat(int, const char*, int)"
end

def reject(message)
  raise PublishError, message
end

def open_child(parent, name, flags, mode = 0)
  fd = NativePublish.openat(parent.fileno, name, flags, mode)
  return IO.for_fd(fd, autoclose: true) unless fd.negative?
  raise SystemCallError.new("openat", Fiddle.last_error)
end

HeldSource = Struct.new(:path, :parent, :file, :stat, :bytes, keyword_init: true)

def physical_source(path)
  reject("source must use an absolute path") unless path.start_with?("/")
  parent = File.dirname(path)
  reject("source parent must be a physical directory") unless File.realpath(parent) == parent
  name = File.basename(path)
  reject("source filename is unsafe") if name.empty? || name == "." || name == ".."
  flags = File::RDONLY | File::NOFOLLOW
  parent_file = File.open(parent, flags)
  reject("source parent must be a directory") unless parent_file.stat.directory?
  source = open_child(parent_file, name, flags)
  stat = source.stat
  reject("source must be a regular single-link file") unless stat.file? && stat.nlink == 1
  bytes = source.read
  current = File.lstat(path)
  reject("source changed while it was read") unless current.file? && current.nlink == 1 && current.dev == stat.dev && current.ino == stat.ino
  HeldSource.new(path: path, parent: parent_file, file: source, stat: stat, bytes: bytes)
rescue StandardError
  source&.close unless source&.closed?
  parent_file&.close unless parent_file&.closed?
  raise
end

def verify_source!(held, at)
  held.file.rewind
  descriptor_bytes = held.file.read
  descriptor_stat = held.file.stat
  current = File.lstat(held.path)
  reject("#{at} descriptor changed") unless descriptor_stat.file? && descriptor_stat.nlink == 1 && descriptor_stat.dev == held.stat.dev && descriptor_stat.ino == held.stat.ino && descriptor_bytes == held.bytes
  reject("#{at} path changed") unless current.file? && !current.symlink? && current.nlink == 1 && current.dev == held.stat.dev && current.ino == held.stat.ino
end

begin
repo, issue_text, head_sha, source_path, packet_path, primary, started_at, completed_at = ARGV
reject("usage: publish-review-result.rb REPOSITORY_ROOT ISSUE HEAD_SHA SOURCE [PACKET PRIMARY STARTED_AT COMPLETED_AT]") unless source_path
reject("repository root must be a physical absolute path") unless repo.start_with?("/") && File.realpath(repo) == repo
reject("issue must be a positive integer") unless issue_text.match?(/\A[1-9][0-9]*\z/)
reject("Head SHA must be a 40-character lowercase Git SHA") unless head_sha.match?(/\A[0-9a-f]{40}\z/)

helper = File.join(repo, "tools", "lib", "review-artifacts.rb")
topology_output, topology_status = Open3.capture2e(
  {"GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil},
  "/usr/bin/ruby", helper, repo
)
reject("review artifact topology is invalid: #{topology_output.strip}") unless topology_status.success?
topology = JSON.parse(topology_output)
artifacts = topology.fetch("artifactsRoot")
expected_root = [topology.fetch("artifactsDevice"), topology.fetch("artifactsInode")]
source = physical_source(source_path)
source_value = JSON.parse(source.bytes)
packet = packet_path ? physical_source(packet_path) : nil
if source_value["schemaVersion"] == 2
  reject("schema v2 result publication requires the exact review packet") unless packet
  reject("schema v2 result publication requires fixed launcher execution identity") unless primary
  expected_packet = File.join(artifacts, "issues", issue_text, head_sha, "review-packet.json")
  reject("review packet publication path is not canonical") unless packet.path == expected_packet
  expected_digest = "sha256:#{Digest::SHA256.hexdigest(packet.bytes)}"
  reject("review result is not bound to the exact review packet bytes") unless source_value["reviewPacketDigest"] == expected_digest
elsif source_value["schemaVersion"] != 1
  reject("review result schema is unsupported")
end
bytes = source.bytes
if primary
  reject("receipt publication arguments are incomplete") unless %w[codex claude].include?(primary) && started_at && completed_at && packet
end

flags = File::RDONLY | File::NOFOLLOW
root = File.open(artifacts, flags)
descriptors = [root]
root_stat = root.stat
reject("artifact root identity changed") unless root_stat.directory? && [root_stat.dev, root_stat.ino] == expected_root
current = root
%W[issues #{issue_text} #{head_sha}].each do |component|
  opened = open_child(current, component, flags)
  descriptors << opened
  reject("artifact parent component is not a directory") unless opened.stat.directory?
  current = opened
end
head_directory = current
verify_source!(source, "review source")
verify_source!(packet, "review packet") if packet
publish_flags = File::RDWR | File::CREAT | File::EXCL | File::NOFOLLOW
published = open_child(head_directory, "review.json", publish_flags, 0o600)
descriptors << published
published_stat = published.stat
created = true
reject("published review permissions cannot be constrained") unless NativePublish.fchmod(published.fileno, 0o600).zero?
published.write(bytes)
published.flush
published.fsync
published.rewind
written = published.read
published_stat = published.stat
reject("published review bytes changed") unless written == bytes
reject("published review must be a regular single-link 0600 file") unless published_stat.file? && published_stat.nlink == 1 && (published_stat.mode & 0o777) == 0o600

target = File.join(artifacts, "issues", issue_text, head_sha, "review.json")
target_stat = File.lstat(target)
reject("published review path changed") unless target_stat.file? && !target_stat.symlink? && target_stat.nlink == 1 && target_stat.dev == published_stat.dev && target_stat.ino == published_stat.ino
verify_source!(source, "review source")
verify_source!(packet, "review packet") if packet
if primary
  receipt_value = IOSTemplate::ReviewReceipt.build(
    repo: repo, primary: primary, issue: Integer(issue_text), head_sha: head_sha,
    packet_bytes: packet.bytes, validated_result_bytes: source.bytes,
    published_review_bytes: written, started_at: started_at, completed_at: completed_at
  )
  receipt_bytes = JSON.generate(receipt_value)
  IOSTemplate::ReviewReceipt.validate!(
    receipt_bytes: receipt_bytes, packet_bytes: packet.bytes, review_bytes: written,
    repo: repo, primary: primary, issue: Integer(issue_text), head_sha: head_sha
  )
  receipt = open_child(head_directory, "review-receipt.json", publish_flags, 0o600)
  descriptors << receipt
  receipt_stat = receipt.stat
  receipt_created = true
  reject("published receipt permissions cannot be constrained") unless NativePublish.fchmod(receipt.fileno, 0o600).zero?
  receipt.write(receipt_bytes)
  receipt.flush
  receipt.fsync
  receipt.rewind
  reject("published receipt bytes changed") unless receipt.read == receipt_bytes
  receipt_stat = receipt.stat
  reject("published receipt must be a regular single-link 0600 file") unless receipt_stat.file? && receipt_stat.nlink == 1 && (receipt_stat.mode & 0o777) == 0o600
  receipt_target = File.join(artifacts, "issues", issue_text, head_sha, "review-receipt.json")
  receipt_target_stat = File.lstat(receipt_target)
  reject("published receipt path changed") unless receipt_target_stat.file? && !receipt_target_stat.symlink? && receipt_target_stat.nlink == 1 && receipt_target_stat.dev == receipt_stat.dev && receipt_target_stat.ino == receipt_stat.ino
  verify_source!(source, "review source")
  verify_source!(packet, "review packet")
  receipt.rewind
  final_receipt_stat = receipt.stat
  final_receipt_bytes = receipt.read
  final_receipt_target_stat = File.lstat(receipt_target)
  reject("published receipt descriptor changed") unless final_receipt_bytes == receipt_bytes && final_receipt_stat.file? && final_receipt_stat.nlink == 1 && final_receipt_stat.dev == receipt_stat.dev && final_receipt_stat.ino == receipt_stat.ino
  reject("published receipt path changed before completion") unless final_receipt_target_stat.file? && !final_receipt_target_stat.symlink? && final_receipt_target_stat.nlink == 1 && final_receipt_target_stat.dev == receipt_stat.dev && final_receipt_target_stat.ino == receipt_stat.ino
end
created = false
receipt_created = false
puts JSON.generate({"path" => target, "sha256" => "sha256:#{Digest::SHA256.hexdigest(written)}", "size" => written.bytesize, "receiptPath" => receipt_target})
rescue PublishError, IOSTemplate::ReviewReceipt::ValidationError, SystemCallError, JSON::ParserError, KeyError, Errno::ENOENT, Errno::EACCES => error
  warn "review publication failed: #{error.message}"
  exit 1
ensure
  if receipt_created && head_directory && receipt_stat
    begin
      current = open_child(head_directory, "review-receipt.json", File::RDONLY | File::NOFOLLOW)
      current_stat = current.stat
      current.close
      NativePublish.unlinkat(head_directory.fileno, "review-receipt.json", 0) if current_stat.dev == receipt_stat.dev && current_stat.ino == receipt_stat.ino
    rescue SystemCallError
      # Never unlink an unknown replacement during failed publication cleanup.
    end
  end
  if created && head_directory && published_stat
    begin
      current = open_child(head_directory, "review.json", File::RDONLY | File::NOFOLLOW)
      current_stat = current.stat
      current.close
      if current_stat.dev == published_stat.dev && current_stat.ino == published_stat.ino
        NativePublish.unlinkat(head_directory.fileno, "review.json", 0)
      end
    rescue SystemCallError
      # Never unlink an unknown replacement during failed publication cleanup.
    end
  end
  descriptors&.reverse_each { |descriptor| descriptor.close unless descriptor.closed? }
  [packet, source].compact.each do |held|
    held.file.close unless held.file.closed?
    held.parent.close unless held.parent.closed?
  end
end
