#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"

def reject(message)
  warn "review artifact layout rejected: #{message}"
  exit 1
end

def git_path(repo, argument)
  environment = {
    "GIT_DIR" => nil,
    "GIT_WORK_TREE" => nil,
    "GIT_COMMON_DIR" => nil,
    "GIT_CONFIG_GLOBAL" => "/dev/null",
    "GIT_CONFIG_SYSTEM" => "/dev/null"
  }
  output, status = Open3.capture2e(environment, "/usr/bin/git", "-C", repo, "rev-parse", "--path-format=absolute", argument)
  reject("Git metadata cannot be resolved") unless status.success?
  value = output.strip
  reject("Git returned an unsafe path") unless value.start_with?("/") && !value.include?("\0") && !value.include?("\n")
  File.realpath(value)
rescue Errno::ENOENT, Errno::EACCES
  reject("Git metadata is not a physical path")
end

def physical_directory(path, at)
  stat = File.lstat(path)
  reject("#{at} must be a physical directory") unless stat.directory? && !stat.symlink?
  resolved = File.realpath(path)
  reject("#{at} must not be an alias") unless resolved == path
  resolved
rescue Errno::ENOENT, Errno::EACCES
  reject("#{at} does not exist")
end

repo_input = ARGV.fetch(0) { reject("usage: review-artifacts.rb REPOSITORY_ROOT") }
reject("repository root must be absolute") unless repo_input.start_with?("/")
repo = physical_directory(File.realpath(repo_input), "repository root")
git_dir = git_path(repo, "--absolute-git-dir")
git_common = git_path(repo, "--git-common-dir")
git_entry = File.join(repo, ".git")
artifacts_entry = File.join(repo, ".artifacts")

if File.directory?(git_entry) && !File.symlink?(git_entry)
  expected_git = physical_directory(git_entry, "primary Git directory")
  reject("direct checkout Git identity is inconsistent") unless git_dir == expected_git && git_common == expected_git
  primary = repo
  artifacts = physical_directory(artifacts_entry, "primary artifact store")
  layout = "direct"
elsif File.file?(git_entry) && !File.symlink?(git_entry)
  git_file = File.binread(git_entry)
  reject("linked-worktree .git metadata is not canonical") unless git_file == "gitdir: #{git_dir}\n"
  reject("common Git directory must be the primary .git directory") unless File.basename(git_common) == ".git"
  primary = physical_directory(File.dirname(git_common), "primary checkout")
  reject("primary Git directory does not match the common Git directory") unless physical_directory(File.join(primary, ".git"), "primary Git directory") == git_common
  primary_top, status = Open3.capture2e({"GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil}, "/usr/bin/git", "-C", primary, "rev-parse", "--show-toplevel")
  reject("primary checkout cannot be identified") unless status.success? && File.realpath(primary_top.strip) == primary
  worktree_metadata_root = File.join(git_common, "worktrees")
  reject("linked-worktree Git metadata escapes the common directory") unless File.dirname(git_dir) == worktree_metadata_root
  reject("linked worktree must be an exact primary .worktrees child") unless File.dirname(repo) == File.join(primary, ".worktrees")
  reject("linked worktree artifact entry must be a symlink") unless File.symlink?(artifacts_entry)
  reject("linked worktree artifact link must be the raw canonical target") unless File.readlink(artifacts_entry) == "../../.artifacts"
  artifacts = physical_directory(File.join(primary, ".artifacts"), "primary artifact store")
  reject("linked worktree artifact link does not resolve to the primary store") unless File.realpath(artifacts_entry) == artifacts
  layout = "linked"
else
  reject("checkout has unsupported Git metadata")
end

puts JSON.generate({
  "schemaVersion" => 1,
  "layout" => layout,
  "repositoryRoot" => repo,
  "primaryRoot" => primary,
  "artifactsRoot" => artifacts,
  "repositoryDevice" => File.lstat(repo).dev,
  "repositoryInode" => File.lstat(repo).ino,
  "artifactsDevice" => File.lstat(artifacts).dev,
  "artifactsInode" => File.lstat(artifacts).ino,
  "gitDir" => git_dir,
  "gitCommon" => git_common
})
