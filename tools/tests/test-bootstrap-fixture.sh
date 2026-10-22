#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby bash python3 swift /usr/bin/xcrun

# #327: each group runs in its own temporary tree and stays well inside the targeted per-test limit. With no
# argument this test checks the frozen fixture and its compatibility with the template; each derived-* group
# rebuilds the same derived repository and runs one app-bootstrap group there through its own
# tools/tests/test-bootstrap-fixture-derived-*.sh entrypoint.
group="${1:-fixture}"
case "$group" in
  fixture|derived-core|derived-transform|derived-safety-rejection|derived-safety-rerun) ;;
  *)
    echo "usage: $0 [fixture|derived-core|derived-transform|derived-safety-rejection|derived-safety-rerun]" >&2
    exit 64
    ;;
esac

# Git 2.54 runs `git maintenance run --auto --detach` after a commit, and its default geometric strategy
# repacks in the background (objects/bitmap-ref-tips_*, packs, multi-pack-index) while this test removes its
# temporary repositories. Every git this test and its children run keeps the caller's settings, skips
# automatic maintenance, and would run any that still starts in the foreground.
disable_git_auto_maintenance() {
  local count=${GIT_CONFIG_COUNT:-0} setting
  [[ "$count" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "GIT_CONFIG_COUNT is not a count: $count" >&2; return 1; }
  for setting in maintenance.auto=false maintenance.autoDetach=false gc.auto=0 gc.autoDetach=false; do
    export "GIT_CONFIG_KEY_$count=${setting%%=*}" "GIT_CONFIG_VALUE_$count=${setting#*=}"
    count=$((count + 1))
  done
  export GIT_CONFIG_COUNT=$count
}
# #325: in both tests, the setting keeps the caller's entries, turns automatic maintenance off for every
# child git, and refuses a GIT_CONFIG_COUNT that is not a count.
if [[ "$group" == fixture ]]; then
  for test_file in test-bootstrap-fixture.sh test-app-bootstrap.sh; do
    definition=$(sed -n '/^disable_git_auto_maintenance() {$/,/^}$/p' "${BASH_SOURCE[0]%/*}/$test_file")
    [[ -n "$definition" ]] || { echo "$test_file does not turn off Git's automatic maintenance" >&2; exit 1; }
    probe=$(env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0='Caller Name' bash -c "$definition"'
      disable_git_auto_maintenance
      printf "%s|%s|%s|%s|%s\n" "$(git config --get user.name)" "$(git config --get maintenance.auto)" \
        "$(git config --get maintenance.autoDetach)" "$(git config --get gc.auto)" "$(git config --get gc.autoDetach)"')
    [[ "$probe" == 'Caller Name|false|false|0|false' ]] || { echo "$test_file Git settings for children: $probe" >&2; exit 1; }
    if env GIT_CONFIG_COUNT=one bash -c "$definition"'
      disable_git_auto_maintenance' 2>/dev/null; then
      echo "$test_file accepted a GIT_CONFIG_COUNT that is not a count" >&2; exit 1
    fi
  done
fi
disable_git_auto_maintenance

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
# #333: -E UTF-8 reads Git output and files as UTF-8 even when LANG/LC_ALL are unset or C (US-ASCII in Ruby).
ruby -E UTF-8 - "$root" "$group" <<'RUBY'
require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

root = ARGV.fetch(0)
group = ARGV.fetch(1)
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

# #333: only a missing transformation anchor means the frozen fixture is out of date. Any other transform
# failure, such as one caused by the caller's locale, shows the transform output alone.
def check_compatibility(seed, instruction)
  ok, output = command("bash", "tools/tests/test-app-bootstrap.sh", "transform", chdir: seed)
  return if ok
  advice = output.include?("required transformation anchor is missing") ? "\n#{instruction}" : ""
  raise "bootstrap template fixture compatibility check failed\n#{output}#{advice}"
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

# Removes a temporary tree. A process that adds or deletes entries during the walk makes one pass fail with
# ENOENT or ENOTEMPTY, so retry a few times and fail only when the tree remains. While the test body is
# already failing, report a leftover tree without hiding that failure.
def remove_temporary_tree(path, failing:)
  5.times do |attempt|
    begin
      FileUtils.remove_entry(path)
    rescue Errno::ENOENT, Errno::ENOTEMPTY
      sleep(0.2 * (attempt + 1))
    end
    return unless File.exist?(path) || File.symlink?(path)
  end
  message = "temporary tree could not be removed: #{path}"
  failing ? warn(message) : raise(message)
end

# AC-4: the cleanup, deterministically and without Git. FileUtils.remove_entry raises the queued errors
# without removing anything, then removes for real.
def with_failing_removals(errors)
  calls = 0
  original = FileUtils.method(:remove_entry)
  FileUtils.define_singleton_method(:remove_entry) do |path, *rest|
    calls += 1
    raise errors[calls - 1] if calls <= errors.length
    original.call(path, *rest)
  end
  yield
  calls
ensure
  FileUtils.define_singleton_method(:remove_entry, original) if original
end
def cleanup_case_tree
  tree = Dir.mktmpdir("bootstrap-cleanup-case.")
  File.write(File.join(tree, "pack"), "x")
  tree
end
def captured_stderr
  original, $stderr = $stderr, StringIO.new
  yield
  $stderr.string
ensure
  $stderr = original
end

# The template-shaped repository with a prose-only change that every derived group starts from.
def prose_repository(root, temp)
  prose = File.join(temp, "prose")
  BootstrapFixture.create(root, prose)
  File.open(File.join(prose, "docs/verification.md"), "ab") { |file| file.write("\nProse-only fixture regression check.\n") }
  commit(prose, "test: change verification prose")
  prose
end

# A clone of the prose repository converted to GardenNotes and left uncommitted.
def derived_repository(temp, prose)
  derived = File.join(temp, "derived")
  git(temp, "clone", "--quiet", "--no-local", prose, derived)
  git(derived, "checkout", "-q", "-b", "codex/bootstrap-fixture-test")
  succeed("bash", "tools/bootstrap-app.sh", "--display-name", "Garden Notes",
    "--module-name", "GardenNotes", "--app-slug", "garden-notes",
    "--bundle-id", "com.yuto.GardenNotes", chdir: derived)
  derived
end

require "stringio"
if group == "fixture"
  tree = cleanup_case_tree
  calls = with_failing_removals([Errno::ENOENT, Errno::ENOTEMPTY]) { remove_temporary_tree(tree, failing: false) }
  assert(calls == 3 && !File.exist?(tree), "cleanup did not retry ENOENT and ENOTEMPTY until the tree was gone")
  exhausted = Array.new(5, Errno::ENOTEMPTY)
  tree = cleanup_case_tree
  raised = begin
    with_failing_removals(exhausted) { remove_temporary_tree(tree, failing: false) }
    nil
  rescue RuntimeError => error
    error.message
  end
  assert(raised == "temporary tree could not be removed: #{tree}" && File.exist?(tree), "a remaining tree did not fail the test: #{raised.inspect}")
  FileUtils.remove_entry(tree)
  tree = cleanup_case_tree
  warning = captured_stderr { with_failing_removals(exhausted) { remove_temporary_tree(tree, failing: true) } }
  assert(warning.include?("temporary tree could not be removed: #{tree}"), "a remaining tree was not reported while the body was failing")
  FileUtils.remove_entry(tree)
  tree = cleanup_case_tree
  body_error = begin
    captured_stderr do
      with_failing_removals(exhausted) do
        begin
          raise "body failed first"
        ensure
          remove_temporary_tree(tree, failing: !$!.nil?)
        end
      end
    end
    nil
  rescue RuntimeError => error
    error.message
  end
  assert(body_error == "body failed first", "the cleanup hid the earlier body failure: #{body_error.inspect}")
  FileUtils.remove_entry(tree)
end

instruction = BootstrapFixture::UPDATE_INSTRUCTION
before = snapshot(root)
temp = File.realpath(Dir.mktmpdir("bootstrap-fixture-test."))
begin
  helper = File.join(root, "tools/tests/lib/bootstrap-fixture.rb")
  if group == "fixture"
    ok, output = command("ruby", helper, "check", root)
    assert(ok, "current source file set differs: #{output}")

    seed = File.join(temp, "seed")
    assert(succeed("ruby", helper, "create", root, seed).strip == seed, "create returned wrong destination")
    assert(File.file?(File.join(seed, "TemplateApp.xcodeproj/project.pbxproj")), "template project missing")
    assert(!File.exist?(File.join(seed, "Config/app-identity.json")), "derived identity leaked into seed")
    assert(File.binread(File.join(seed, "Config/template-identity.json")) ==
      File.binread(File.join(root, "Config/template-identity.json")), "current manifest was replaced")
    assert(git(seed, "status", "--porcelain=v1").empty?, "seed is dirty")
    assert(git(seed, "config", "--get", "maintenance.auto").strip == "false" && git(seed, "config", "--get", "gc.auto").strip == "0",
      "Git's automatic maintenance is still on in the temporary repositories")

    # #333: with LANG and LC_ALL set to C, Ruby reads Git output and files as US-ASCII. The helper's check and
    # create give the same results as under a UTF-8 locale, and a tracked path whose bytes are not UTF-8 is
    # refused under both as an encoding problem, not as an unsafe path.
    c_locale = {"LANG" => "C", "LC_ALL" => "C", "RUBYOPT" => nil}
    utf8_locale = {"LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8", "RUBYOPT" => nil}
    encodings = [c_locale, utf8_locale].map { |env| succeed(env, "ruby", "-e", "print Encoding.default_external") }
    assert(encodings == %w[US-ASCII UTF-8], "the locales did not set Ruby's external encoding: #{encodings.inspect}")
    checks = [c_locale, utf8_locale].map { |env| command(env, "ruby", helper, "check", root) }
    assert(checks.first.first && checks.first == checks.last, "helper check differs between the C and UTF-8 locales: #{checks.inspect}")
    seed_tree = git(seed, "rev-parse", "HEAD^{tree}")
    {"c" => c_locale, "utf8" => utf8_locale}.each do |label, env|
      destination = File.join(temp, "seed-#{label}-locale")
      ok, output = command(env, "ruby", helper, "create", root, destination)
      assert(ok && output.strip == destination && git(destination, "rev-parse", "HEAD^{tree}") == seed_tree,
        "helper create under the #{label} locale differs from the seed: #{output}")
    end
    non_utf8 = BootstrapFixture.create(root, File.join(temp, "non-utf8-source"))
    blob = git(non_utf8, "rev-parse", "HEAD:AGENTS.md").strip
    git(non_utf8, "update-index", "--add", "--cacheinfo", "100644,#{blob},not-utf8-\xFF.md")
    {"c" => c_locale, "utf8" => utf8_locale}.each do |label, env|
      destination = File.join(temp, "non-utf8-#{label}-locale")
      ok, output = command(env, "ruby", File.join(non_utf8, "tools/tests/lib/bootstrap-fixture.rb"), "create", non_utf8, destination)
      assert(!ok && !File.exist?(destination) && output.include?("fixture path is not valid UTF-8: \"not-utf8-\\xFF.md\"") &&
        !output.include?("unsafe fixture path"), "a tracked path that is not UTF-8 was not refused as an encoding problem (#{label}): #{output}")
    end
    {
      "absolute" => "/AGENTS.md", "parent" => "docs/../AGENTS.md", "git" => ".git/config", "empty segment" => "docs//README.md",
      "control" => "docs/\nREADME.md", "backslash" => "docs\\README.md", "empty" => ""
    }.each do |label, path|
      [path, path.dup.force_encoding(Encoding::US_ASCII)].each do |candidate|
        message = begin
          BootstrapFixture.safe_relative!(candidate)
          nil
        rescue ArgumentError => error
          error.message
        end
        assert(message == "unsafe fixture path", "the #{label} path check changed (#{candidate.encoding}): #{message.inspect}")
      end
    end
    assert(BootstrapFixture.safe_relative!("docs/README.md".encode(Encoding::US_ASCII)) == "docs/README.md",
      "a safe path read under the C locale was refused")

    # #333: a transform failure without a missing anchor shows the transform output and no refresh instruction.
    failing = File.join(temp, "failing-transform")
    FileUtils.mkdir_p(File.join(failing, "tools/tests"))
    File.binwrite(File.join(failing, "tools/tests/test-app-bootstrap.sh"),
      "echo 'Foundation failed after disposable bootstrap: invalid byte sequence in US-ASCII' >&2\nexit 1\n")
    failure = begin
      check_compatibility(failing, instruction)
      nil
    rescue RuntimeError => error
      error.message
    end
    assert(!failure.nil? && failure.include?("invalid byte sequence in US-ASCII") && !failure.include?(instruction),
      "a transform failure without a missing anchor was not shown alone: #{failure.inspect}")

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

    prose = prose_repository(root, temp)
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
  else
    # Each derived group runs one app-bootstrap group in the derived repository: core (validation,
    # transaction, trunk-default, cleanup-failure), transform, safety-rejection, or safety-rerun.
    derived = derived_repository(temp, prose_repository(root, temp))
    if group == "derived-core"
      ok, = command("ruby", File.join(derived, "tools/tests/lib/bootstrap-fixture.rb"), "refresh", derived)
      assert(!ok, "derived repository accepted fixture refresh")
      previous = snapshot(derived)
      succeed("bash", "tools/tests/test-app-bootstrap.sh", "trunk-default", chdir: derived)
      assert(snapshot(derived) == previous, "uncommitted derived suite mutated repository")
    end
    commit(derived, "test: commit GardenNotes bootstrap")
    previous = snapshot(derived)
    succeed("bash", "tools/tests/test-app-bootstrap.sh", group.delete_prefix("derived-"), chdir: derived)
    assert(snapshot(derived) == previous, "committed derived suite mutated repository")

    if group == "derived-core"
      # A shared seed with local changes or another Head is refused before any suite uses it.
      shared = BootstrapFixture.create(derived, File.join(temp, "shared-seed"))
      shared_head = git(shared, "rev-parse", "HEAD").strip
      File.write(File.join(shared, "AGENTS.md"), "local change\n", mode: "a")
      ok, output = command({"IOS_TEMPLATE_BOOTSTRAP_SEED" => shared, "IOS_TEMPLATE_BOOTSTRAP_SEED_HEAD" => shared_head},
        "bash", "tools/tests/test-app-bootstrap.sh", "validation", chdir: derived)
      assert(!ok && output.include?("shared bootstrap seed has local changes"), "a dirty shared seed was used: #{output}")
      git(shared, "checkout", "-q", "--", "AGENTS.md")
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
  end
ensure
  remove_temporary_tree(temp, failing: !$!.nil?)
end

# A template-only change under any frozen source directory selects every group of this fixture regression.
if group == "fixture"
  require File.join(root, "tools/lib/repository-test-plan")
  manifest = JSON.parse(File.read(File.join(root, "Config/repository-tests.json")))
  identity = JSON.parse(File.read(File.join(root, "Config/template-identity.json")))
  fixture_tests = %w[tools/tests/test-bootstrap-fixture.sh tools/tests/test-bootstrap-fixture-derived-core.sh
    tools/tests/test-bootstrap-fixture-derived-safety-rejection.sh tools/tests/test-bootstrap-fixture-derived-safety-rerun.sh
    tools/tests/test-bootstrap-fixture-derived-transform.sh]
  identity.fetch("renamePaths").map { |path| path.split("/").first }.uniq.each do |directory|
    _, _, tests = IOSTemplate::RepositoryTestPlan.resolve(manifest, "targeted", ["#{directory}/fixture-change.txt"])
    assert((fixture_tests - tests).empty?, "a change under #{directory}/ did not select every fixture regression group")
  end
end
assert(snapshot(root) == before, "fixture regression mutated source HEAD, status, tracked files, or identity")
puts group == "fixture" ? "bootstrap fixture tests passed" : "bootstrap fixture #{group} tests passed"
RUBY
