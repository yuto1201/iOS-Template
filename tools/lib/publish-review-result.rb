#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fiddle/import"
require "json"
require "open3"

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
  bytes
ensure
  source&.close unless source&.closed?
  parent_file&.close unless parent_file&.closed?
end

begin
repo, issue_text, head_sha, source_path = ARGV
reject("usage: publish-review-result.rb REPOSITORY_ROOT ISSUE HEAD_SHA SOURCE") unless source_path
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
bytes = physical_source(source_path)

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
publish_flags = File::RDWR | File::CREAT | File::EXCL | File::NOFOLLOW
published = open_child(head_directory, "review.json", publish_flags, 0o600)
descriptors << published
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
created = false
puts JSON.generate({"path" => target, "sha256" => "sha256:#{Digest::SHA256.hexdigest(written)}", "size" => written.bytesize})
rescue PublishError, SystemCallError, JSON::ParserError, KeyError, Errno::ENOENT, Errno::EACCES => error
  warn "review publication failed: #{error.message}"
  exit 1
ensure
  if created && head_directory
    NativePublish.unlinkat(head_directory.fileno, "review.json", 0)
  end
  descriptors&.reverse_each { |descriptor| descriptor.close unless descriptor.closed? }
end
