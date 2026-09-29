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

def check_compatibility(seed, instruction)
  ok, output = command("bash", "tools/tests/test-app-bootstrap.sh", "transform", chdir: seed)
  raise "bootstrap template fixture compatibility check failed\n#{output}\n#{instruction}" unless ok
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

  check_compatibility(prose, instruction)

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
  failure = begin
    check_compatibility(broken, instruction)
    nil
  rescue RuntimeError => error
    error.message
  end
  assert(!failure.nil?, "bootstrap-incompatible fixture passed transform")
  assert(failure.include?("required transformation anchor is missing") && failure.include?(instruction),
    "incompatible fixture failure was not explained: #{failure}")

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

  # A shared seed with local changes or another Head is refused before any suite uses it.
  shared = BootstrapFixture.create(derived, File.join(temp, "shared-seed"))
  shared_head = git(shared, "rev-parse", "HEAD").strip
  File.write(File.join(shared, "README.md"), "local change\n", mode: "a")
  ok, output = command({"IOS_TEMPLATE_BOOTSTRAP_SEED" => shared, "IOS_TEMPLATE_BOOTSTRAP_SEED_HEAD" => shared_head},
    "bash", "tools/tests/test-app-bootstrap.sh", "validation", chdir: derived)
  assert(!ok && output.include?("shared bootstrap seed has local changes"), "a dirty shared seed was used: #{output}")
  git(shared, "checkout", "-q", "--", "README.md")
  ok, output = command({"IOS_TEMPLATE_BOOTSTRAP_SEED" => shared, "IOS_TEMPLATE_BOOTSTRAP_SEED_HEAD" => "0" * 40},
    "bash", "tools/tests/test-app-bootstrap.sh", "validation", chdir: derived)
  assert(!ok && output.include?("shared bootstrap seed Head changed"), "a shared seed at another Head was used: #{output}")
  File.write(File.join(shared, "Config/app-identity.json"), File.read(File.join(derived, "Config/app-identity.json")))
  git(shared, "add", "Config/app-identity.json")
  git(shared, "-c", "user.name=Bootstrap Test", "-c", "user.email=bootstrap-test@example.invalid", "-c", "commit.gpgsign=false",
    "commit", "--quiet", "-m", "test: bootstrapped seed")
  ok, output = command({"IOS_TEMPLATE_BOOTSTRAP_SEED" => shared, "IOS_TEMPLATE_BOOTSTRAP_SEED_HEAD" => git(shared, "rev-parse", "HEAD").strip},
    "bash", "tools/tests/test-app-bootstrap.sh", "validation", chdir: derived)
  assert(!ok && output.include?("shared bootstrap seed no longer has the template identity"), "a bootstrapped shared seed was used: #{output}")
end

# A template-only change under any frozen source directory selects this fixture regression.
require File.join(root, "tools/lib/repository-test-plan")
manifest = JSON.parse(File.read(File.join(root, "Config/repository-tests.json")))
identity = JSON.parse(File.read(File.join(root, "Config/template-identity.json")))
identity.fetch("renamePaths").map { |path| path.split("/").first }.uniq.each do |directory|
  _, _, tests = IOSTemplate::RepositoryTestPlan.resolve(manifest, "targeted", ["#{directory}/fixture-change.txt"])
  assert(tests.include?("tools/tests/test-bootstrap-fixture.sh"), "a change under #{directory}/ did not select the fixture regression")
end
assert(snapshot(root) == before, "fixture regression mutated source HEAD, status, tracked files, or identity")
puts "bootstrap fixture tests passed"
RUBY
