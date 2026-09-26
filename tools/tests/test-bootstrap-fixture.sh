#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby bash python3 swift /usr/bin/xcrun

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
ruby - "$root" <<'RUBY'
require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

root = ARGV.fetch(0)
require File.join(root, "tools/tests/lib/bootstrap-fixture")

def assert(condition, message)
  raise message unless condition
end

def command(*argv, chdir: nil)
  options = chdir ? {chdir: chdir} : {}
  output, error, status = Open3.capture3(*argv, **options)
  [status.success?, output + error]
end

def succeed(*argv, chdir: nil)
  ok, output = command(*argv, chdir: chdir)
  raise "command failed: #{argv.join(' ')}\n#{output}" unless ok
  output
end

def git(root, *args)
  succeed("git", "-C", root, *args)
end

def commit(root, message)
  git(root, "add", "--all")
  git(root, "-c", "user.name=Bootstrap Test", "-c", "user.email=bootstrap-test@example.invalid",
    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", message)
end

def snapshot(root)
  tracked = git(root, "ls-files", "-z").split("\0").map do |relative|
    path = File.join(root, relative)
    value = if File.symlink?(path)
      "link:#{File.readlink(path)}"
    elsif File.file?(path)
      "file:#{Digest::SHA256.file(path).hexdigest}"
    else
      "missing"
    end
    "#{relative}\0#{value}\0"
  end.join
  [git(root, "rev-parse", "HEAD"), git(root, "status", "--porcelain=v1"),
    Digest::SHA256.hexdigest(tracked),
    File.file?(File.join(root, "Config/app-identity.json")) ?
      Digest::SHA256.file(File.join(root, "Config/app-identity.json")).hexdigest : nil]
end

instruction = BootstrapFixture::UPDATE_INSTRUCTION
before = snapshot(root)
Dir.mktmpdir("bootstrap-fixture-test.") do |temp|
  temp = File.realpath(temp)
  helper = File.join(root, "tools/tests/lib/bootstrap-fixture.rb")
  ok, output = command("ruby", helper, "check", root)
  assert(ok, "current source file set differs: #{output}")

  seed = File.join(temp, "seed")
  assert(succeed("ruby", helper, "create", root, seed).strip == seed, "create returned wrong destination")
  assert(File.file?(File.join(seed, "TemplateApp.xcodeproj/project.pbxproj")), "template project missing")
  assert(!File.exist?(File.join(seed, "Config/app-identity.json")), "derived identity leaked into seed")
  assert(File.binread(File.join(seed, "Config/template-identity.json")) ==
    File.binread(File.join(root, "Config/template-identity.json")), "current manifest was replaced")
  assert(git(seed, "status", "--porcelain=v1").empty?, "seed is dirty")

  ok, = command("ruby", helper, "create", root, seed)
  assert(!ok && File.file?(File.join(seed, "TemplateApp/TemplateAppApp.swift")),
    "existing destination was accepted or damaged")
  outside = File.join(root, ".bootstrap-fixture-outside-#{Process.pid}")
  ok, = command("ruby", helper, "create", root, outside)
  assert(!ok && !File.exist?(outside), "non-temporary destination was accepted")

  frozen_path = File.join(seed, "tools/tests/fixtures/bootstrap-template/source-identity.json")
  original = File.binread(frozen_path)
  {
    "digest" => lambda { |entry| entry["lines"] << "changed" },
    "traversal" => lambda { |entry| entry["path"] = "../escape" },
    "tools" => lambda { |entry| entry["path"] = "tools/bootstrap-app.swift" },
    "manifest" => lambda { |entry| entry["path"] = "Config/template-identity.json" }
  }.each do |label, mutation|
    data = JSON.parse(original)
    mutation.call(data.fetch("files").first)
    File.binwrite(frozen_path, JSON.pretty_generate(data))
    target = File.join(temp, "rejected-#{label}")
    ok, = command("ruby", File.join(seed, "tools/tests/lib/bootstrap-fixture.rb"), "create", seed, target)
    assert(!ok && !File.exist?(target), "invalid fixture accepted or destination retained: #{label}")
  end
  File.binwrite(frozen_path, original)

  extra = File.join(seed, "TemplateApp/Unexpected.swift")
  File.binwrite(extra, "// new source identity file\n")
  commit(seed, "test: expand source identity set")
  ok, output = command("ruby", File.join(seed, "tools/tests/lib/bootstrap-fixture.rb"), "check", seed)
  assert(!ok && output.include?("TemplateApp/Unexpected.swift") && output.include?(instruction),
    "file-set drift was not explained: #{output}")

  prose = File.join(temp, "prose")
  BootstrapFixture.create(root, prose)
  File.open(File.join(prose, "docs/verification.md"), "ab") { |file| file.write("\nProse-only fixture regression check.\n") }
  commit(prose, "test: change verification prose")
  ok, output = command("ruby", File.join(prose, "tools/tests/lib/bootstrap-fixture.rb"), "check", prose)
  assert(ok, "prose edit incorrectly required refresh: #{output}")

  ok, output = command("bash", "tools/tests/test-app-bootstrap.sh", "transform", chdir: prose)
  assert(ok, "current fixture is not bootstrap compatible: #{output}")

  stale = File.join(temp, "stale")
  BootstrapFixture.create(root, stale)
  stale_path = File.join(stale, "tools/tests/fixtures/bootstrap-template/source-identity.json")
  stale_data = JSON.parse(File.binread(stale_path))
  entry = stale_data.fetch("files").find { |file| file.fetch("path") == "docs/verification.md" }
  assert(!entry.nil?, "verification document absent from fixture")
  entry.fetch("lines") << "TemplateApp"
  entry["sha256"] = Digest::SHA256.hexdigest(entry.fetch("lines").join("\n"))
  File.binwrite(stale_path, JSON.pretty_generate(stale_data))
  broken = File.join(temp, "broken")
  BootstrapFixture.create(stale, broken)
  ok, output = command("bash", "tools/tests/test-app-bootstrap.sh", "transform", chdir: broken)
  assert(!ok, "bootstrap-incompatible fixture passed transform")
  diagnostic = "bootstrap fixture compatibility failed: #{output}\n#{instruction}"
  assert(diagnostic.include?(instruction), "compatibility failure omitted update instruction")
  puts instruction

  derived = File.join(temp, "derived")
  git(temp, "clone", "--quiet", "--no-local", prose, derived)
  git(derived, "checkout", "-q", "-b", "codex/bootstrap-fixture-test")
  succeed("bash", "tools/bootstrap-app.sh", "--display-name", "Garden Notes",
    "--module-name", "GardenNotes", "--app-slug", "garden-notes",
    "--bundle-id", "com.yuto.GardenNotes", chdir: derived)
  ok, = command("ruby", File.join(derived, "tools/tests/lib/bootstrap-fixture.rb"), "refresh", derived)
  assert(!ok, "derived repository accepted fixture refresh")
  previous = snapshot(derived)
  succeed("bash", "tools/tests/test-app-bootstrap.sh", "trunk-default", chdir: derived)
  assert(snapshot(derived) == previous, "uncommitted derived suite mutated repository")
  commit(derived, "test: commit GardenNotes bootstrap")
  previous = snapshot(derived)
  succeed("bash", "tools/tests/test-app-bootstrap.sh", "all", chdir: derived)
  assert(snapshot(derived) == previous, "committed derived suite mutated repository")
end
assert(snapshot(root) == before, "fixture regression mutated source HEAD, status, tracked files, or identity")
puts "bootstrap fixture tests passed"
RUBY
