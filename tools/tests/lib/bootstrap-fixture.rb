#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "tempfile"
require "tmpdir"

module BootstrapFixture
  module_function

  FIXTURE_PATH = "tools/tests/fixtures/bootstrap-template/source-identity.json"
  MANIFEST_PATH = "Config/template-identity.json"
  UPDATE_INSTRUCTION = "bootstrap template fixture is out of date: run `ruby tools/tests/lib/bootstrap-fixture.rb refresh .` from the template repository root, review tools/tests/fixtures/bootstrap-template/source-identity.json, and commit it with the change."

  def git(root, *args)
    output, error, status = Open3.capture3("git", "-C", root, *args)
    raise "fixture git failed: #{error}" unless status.success?
    output
  end

  def read_text(path)
    content = File.binread(path).force_encoding(Encoding::UTF_8)
    raise "invalid UTF-8 or NUL in #{path}" unless content.valid_encoding? && !content.include?("\0")
    content
  end

  def read_json(path)
    JSON.parse(read_text(path))
  end

  def safe_relative!(relative)
    raise ArgumentError, "unsafe fixture path" unless relative.is_a?(String) &&
      relative.encoding == Encoding::UTF_8 && relative.valid_encoding? &&
      !relative.empty? && !relative.start_with?("/") &&
      !relative.match?(/[\x00-\x1f\\]/)
    parts = relative.split("/", -1)
    raise ArgumentError, "unsafe fixture path" if parts.any? { |part| part.empty? || %w[. .. .git].include?(part) }
    relative
  end

  def safe_path(root, relative)
    safe_relative!(relative)
    parent = root
    parts = relative.split("/")
    parts[0...-1].each do |part|
      parent = File.join(parent, part)
      raise ArgumentError, "symlink fixture parent: #{relative}" if File.symlink?(parent)
    end
    File.join(root, relative)
  end

  def tracked_paths(source)
    git(source, "ls-files", "-z").split("\0").reject(&:empty?).sort
  end

  def manifest(source)
    data = read_json(File.join(source, MANIFEST_PATH))
    raise "invalid template identity manifest" unless data.is_a?(Hash) &&
      data["renamePaths"].is_a?(Array) && data["liveContentPaths"].is_a?(Array)
    (data.fetch("renamePaths") + data.fetch("liveContentPaths")).each { |path| safe_relative!(path) }
    data
  end

  def identity_paths(source, tracked = tracked_paths(source))
    data = manifest(source)
    result = []
    data.fetch("renamePaths").each do |relative|
      absolute = safe_path(source, relative)
      if File.directory?(absolute)
        members = tracked.select { |path| path.start_with?(relative + "/") }
        raise "source identity directory has no tracked files: #{relative}" if members.empty?
        result.concat(members)
      else
        raise "source identity file is not tracked: #{relative}" unless tracked.include?(relative)
        result << relative
      end
    end
    data.fetch("liveContentPaths").each do |relative|
      raise "source identity file is not tracked: #{relative}" unless tracked.include?(relative)
      result << relative
    end
    result.uniq.sort
  end

  def fixture(source)
    data = read_json(File.join(source, FIXTURE_PATH))
    raise "invalid fixture schema" unless data.is_a?(Hash) && data.keys.sort == %w[files schemaVersion] &&
      data["schemaVersion"] == 1 && data["files"].is_a?(Array) && !data["files"].empty?
    paths = []
    data.fetch("files").each do |entry|
      raise "invalid fixture entry" unless entry.is_a?(Hash) && entry.keys.sort == %w[lines mode path sha256]
      relative = safe_relative!(entry.fetch("path"))
      raise "fixture may not replace current tools or manifest" if
        relative == MANIFEST_PATH || %w[tools .agents .claude].any? { |prefix| relative == prefix || relative.start_with?(prefix + "/") }
      raise "unsupported fixture mode" unless entry.fetch("mode") == "100644"
      digest = entry.fetch("sha256")
      raise "invalid fixture digest" unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
      lines = entry.fetch("lines")
      raise "invalid fixture lines" unless lines.is_a?(Array) && lines.all? { |line|
        line.is_a?(String) && line.encoding == Encoding::UTF_8 && line.valid_encoding? &&
          !line.include?("\0") && !line.include?("\n")
      }
      content = lines.join("\n")
      raise "invalid fixture line split" unless lines == content.split("\n", -1)
      raise "fixture content digest mismatch: #{relative}" unless Digest::SHA256.hexdigest(content) == digest
      paths << relative
    end
    raise "fixture paths must be sorted and unique" unless paths == paths.uniq.sort
    data
  end

  def derived?(source)
    path = File.join(source, "Config/app-identity.json")
    File.file?(path) && !File.symlink?(path)
  end

  def excluded_paths(source)
    excluded = ["Config/app-identity.json"]
    if derived?(source)
      name = read_json(File.join(source, "Config/app-identity.json")).fetch("moduleName")
      raise "invalid source module" unless name.is_a?(String) && name.match?(/\A[A-Za-z][A-Za-z0-9]*\z/)
      excluded.concat([name, "#{name}Tests", "#{name}UITests", "#{name}.xcodeproj"])
    end
    excluded
  end

  def excluded?(relative, excluded)
    excluded.any? { |path| relative == path || relative.start_with?(path + "/") }
  end

  def destination_path!(source, destination)
    source = File.realpath(source)
    destination = File.expand_path(destination)
    raise ArgumentError, "destination already exists" if File.exist?(destination) || File.symlink?(destination)
    parent = File.dirname(destination)
    raise ArgumentError, "symlink destination parent" if File.symlink?(parent)
    parent = File.realpath(parent)
    temporary_root = File.realpath(Dir.tmpdir)
    raise ArgumentError, "destination must be temporary" unless parent == temporary_root ||
      parent.start_with?(temporary_root + "/")
    destination = File.join(parent, File.basename(destination))
    raise ArgumentError, "destination overlaps source" if destination == source || destination.start_with?(source + "/")
    destination
  end

  def copy_tracked(source, destination, frozen_paths)
    excluded = excluded_paths(source)
    tracked_paths(source).each do |relative|
      next if excluded?(relative, excluded)
      original = safe_path(source, relative)
      target = safe_path(destination, relative)
      if !File.exist?(original) && !File.symlink?(original)
        raise "missing tracked source file: #{relative}" unless frozen_paths.include?(relative)
        next
      end
      FileUtils.mkdir_p(File.dirname(target))
      if File.symlink?(original)
        link = File.readlink(original)
        resolved = File.expand_path(link, File.dirname(target))
        raise "escaping source symlink: #{relative}" if link.start_with?("/") ||
          !(resolved == destination || resolved.start_with?(destination + "/"))
        File.symlink(link, target)
      else
        raise "source is not a regular file: #{relative}" unless File.file?(original)
        File.binwrite(target, File.binread(original))
        File.chmod(File.stat(original).mode & 0777, target)
      end
    end
  end

  def create(source, destination)
    source = File.realpath(source)
    destination = destination_path!(source, destination)
    data = fixture(source)
    frozen_paths = data.fetch("files").map { |entry| entry.fetch("path") }
    created = false
    begin
      Dir.mkdir(destination)
      created = true
      copy_tracked(source, destination, frozen_paths)
      data.fetch("files").each do |entry|
        relative = entry.fetch("path")
        target = safe_path(destination, relative)
        raise "frozen target is a symlink: #{relative}" if File.symlink?(target)
        FileUtils.mkdir_p(File.dirname(target))
        File.binwrite(target, entry.fetch("lines").join("\n"))
        File.chmod(0644, target)
      end
      data = manifest(destination)
      (data.fetch("renamePaths") + data.fetch("liveContentPaths")).each do |relative|
        raise "current manifest path missing from seed: #{relative}" unless File.exist?(safe_path(destination, relative))
      end
      git(destination, "init", "--quiet", "--initial-branch=main")
      git(destination, "add", "--all")
      git(destination, "-c", "user.name=Bootstrap Test", "-c", "user.email=bootstrap-test@example.invalid",
        "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
        "commit", "--quiet", "-m", "test: current tools with frozen template inputs")
      destination
    rescue StandardError
      FileUtils.rm_rf(destination) if created
      raise
    end
  end

  def check(source)
    source = File.realpath(source)
    return "skipped: derived repository" if derived?(source)
    frozen = fixture(source).fetch("files").map { |entry| entry.fetch("path") }
    current = identity_paths(source)
    missing = current - frozen
    extra = frozen - current
    unless missing.empty? && extra.empty?
      raise "source identity file set differs\nmissing from fixture: #{missing.join(', ')}\nextra in fixture: #{extra.join(', ')}\n#{UPDATE_INSTRUCTION}"
    end
    "bootstrap template fixture file set matches source"
  end

  def refresh(source)
    source = File.realpath(source)
    raise "cannot refresh fixture in derived repository" if derived?(source)
    files = identity_paths(source).map do |relative|
      path = safe_path(source, relative)
      raise "source identity is not a regular file: #{relative}" unless File.file?(path) && !File.symlink?(path)
      raise "unsupported source identity mode: #{relative}" unless (File.stat(path).mode & 0777) == 0644
      content = read_text(path)
      {"path" => relative, "mode" => "100644", "sha256" => Digest::SHA256.hexdigest(content),
        "lines" => content.split("\n", -1)}
    end
    path = File.join(source, FIXTURE_PATH)
    FileUtils.mkdir_p(File.dirname(path))
    temporary = Tempfile.new(".source-identity.", File.dirname(path))
    begin
      temporary.binmode
      temporary.write(JSON.pretty_generate({"schemaVersion" => 1, "files" => files}))
      temporary.flush
      temporary.fsync
      temporary.chmod(0644)
      File.rename(temporary.path, path)
    ensure
      temporary.close!
    end
    path
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    case ARGV.shift
    when "create"
      abort "usage: bootstrap-fixture.rb create SOURCE DESTINATION" unless ARGV.length == 2
      puts BootstrapFixture.create(*ARGV)
    when "check"
      abort "usage: bootstrap-fixture.rb check SOURCE" unless ARGV.length == 1
      puts BootstrapFixture.check(ARGV.fetch(0))
    when "refresh"
      abort "usage: bootstrap-fixture.rb refresh SOURCE" unless ARGV.length == 1
      puts BootstrapFixture.refresh(ARGV.fetch(0))
    else
      abort "usage: bootstrap-fixture.rb create SOURCE DESTINATION | check SOURCE | refresh SOURCE"
    end
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
