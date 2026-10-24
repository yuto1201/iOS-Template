#!/usr/bin/env ruby
# frozen_string_literal: true

# Template sync (D-074): classify every template file, then compare a derived or non-template
# repository with the template and write a report and an apply plan. Without a recorded base, each
# file is judged by its own provenance in the template's history (D-078). Before an import, preflight
# judges from reads alone whether the target is busy with other work and how large the plan is, and the
# analysis explains a plan before the user approves it: what is missing or outdated, what was renamed or
# may be duplicated, what the app changed, and what must be cleared first (D-078). None of them writes to
# the target repository; approving and applying a plan live in template-sync-apply.rb.

require "digest"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "set"
require "time"
require "tmpdir"

module TemplateSync
  OWNERSHIP_PATH = "tools/template-sync/ownership.json"
  BASE_RECORD_PATH = "Config/template-base.json"
  APP_IDENTITY_PATH = "Config/app-identity.json"
  IDENTITY_MANIFEST_PATH = "Config/template-identity.json"
  DECISIONS_PATH = "specs/decisions.md"
  SIMULATORS_PATH = "Config/dedicated-simulators.json"
  CATEGORIES = %w[template identity app mixed template-only].freeze
  MIXED_RULES = %w[agents-md agents-md-approvals decisions dedicated-simulators ownership repository-tests].freeze
  BASE_KEYS = %w[baseCommit method recordedAt schemaVersion templateRepository].freeze
  BASE_METHODS = %w[created adopted].freeze
  IDENTITY_KEYS = %w[appSlug bundleId displayName moduleName schemaVersion sourceIdentityVersion].freeze
  TEMPLATE_DEVICE_PREFIX = "iOS-Template "
  # A commit that changes these can change every Identity-transformed file without touching it.
  TRANSFORM_TOOL_PATHS = ["tools/bootstrap-app.swift", IDENTITY_MANIFEST_PATH].freeze
  SHA_PATTERN = /\A[0-9a-f]{40}\z/
  DECISION_HEADING = /^## (D-\d{3,}): (.+)$/

  class Failure < StandardError; end

  # A file as Git stores it: its mode (100644, 100755 or 120000) and its bytes (a symlink's target).
  # Comparisons use both, so an executable-bit change is a change.
  Entry = Struct.new(:mode, :bytes)

  module_function

  def run(argv)
    command = argv.shift or fail!("usage: template-sync.sh check|report|preflight|analyze|codex-review|approve|apply [options]")
    options = parse_options(argv)
    case command
    when "check" then puts JSON.generate(check(options))
    when "report" then puts JSON.generate(report(options))
    when "preflight" then puts JSON.generate(preflight(options))
    when "analyze" then puts JSON.generate(analyze(options))
    when "codex-review" then puts JSON.generate(codex_review(options))
    when "approve" then puts JSON.generate(approve(options))
    when "apply" then puts JSON.generate(apply(options))
    else fail!("unknown command: #{command}")
    end
  rescue Failure, JSON::ParserError, ArgumentError, SystemCallError => error
    warn "template-sync: #{error.message}"
    exit 1
  end

  def parse_options(argv)
    options = {}
    until argv.empty?
      key = argv.shift
      fail!("unexpected argument: #{key}") unless key.start_with?("--")
      value = argv.shift
      fail!("missing value for #{key}") if value.nil? || value.start_with?("--")
      fail!("duplicate option: #{key}") if options.key?(key)
      options[key] = value
    end
    options
  end

  def allow_options!(options, required, optional = [])
    missing = required - options.keys
    unknown = options.keys - required - optional
    fail!("missing options: #{missing.join(", ")}") unless missing.empty?
    fail!("unknown options: #{unknown.join(", ")}") unless unknown.empty?
  end

  # --- template side --------------------------------------------------------------------------

  def template_root
    File.realpath(File.expand_path("../..", __dir__))
  end

  def git(root, *args, input: nil)
    # No optional index refresh and no fsmonitor hook: reading a repository must not write to it.
    stdout, stderr, status = Open3.capture3({"GIT_OPTIONAL_LOCKS" => "0"}, "git", "-c", "core.fsmonitor=false", "-C", root, *args,
                                            stdin_data: input, binmode: true)
    fail!("git #{args.first} failed in #{root}: #{stderr.strip}") unless status.success?
    stdout
  end

  def commit!(root, ref)
    git(root, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}").strip
  rescue Failure
    fail!("#{ref} is not a commit in #{root}")
  end

  def commit_exists?(root, sha)
    _out, _err, status = Open3.capture3({"GIT_OPTIONAL_LOCKS" => "0"}, "git", "-C", root, "cat-file", "-e", "#{sha}^{commit}")
    status.success?
  end

  def tracked_paths(root, commit)
    git(root, "ls-tree", "-r", "-z", "--name-only", "--full-tree", commit).force_encoding(Encoding::UTF_8).split("\0").reject(&:empty?)
  end

  def blob(root, commit, path)
    git(root, "show", "#{commit}:#{path}").force_encoding(Encoding::UTF_8)
  end

  # --- ownership manifest -------------------------------------------------------------------

  def load_ownership(text)
    manifest = JSON.parse(text)
    fail!("ownership manifest must be an object") unless manifest.is_a?(Hash)
    exact_keys!(manifest, %w[rules schemaVersion templateRepository], "ownership manifest")
    fail!("ownership schemaVersion must be 1") unless manifest["schemaVersion"] == 1
    fail!("ownership templateRepository is invalid") unless manifest["templateRepository"].to_s.match?(%r{\A[\w.-]+/[\w.-]+\z})
    exact = {}
    prefixes = {}
    manifest.fetch("rules").each_with_index do |rule, index|
      label = "ownership rules[#{index}]"
      fail!("#{label} must be an object") unless rule.is_a?(Hash)
      allowed = %w[category paths prefixes transform] + (rule["category"] == "mixed" ? ["rule"] : [])
      exact_keys!(rule, allowed, label)
      fail!("#{label}.category is unknown") unless CATEGORIES.include?(rule["category"])
      fail!("#{label}.rule is unknown") if rule["category"] == "mixed" && !MIXED_RULES.include?(rule["rule"])
      fail!("#{label}.transform must be a boolean") unless [true, false].include?(rule["transform"])
      fail!("#{label}.transform is only for identity or mixed rules") if rule["transform"] && !%w[identity mixed].include?(rule["category"])
      fail!("#{label}.paths and prefixes must be string arrays") unless [rule["paths"], rule["prefixes"]].all? { |list| list.is_a?(Array) && list.all? { |item| item.is_a?(String) && !item.empty? } }
      entry = {category: rule["category"], rule: rule["rule"], transform: rule["transform"]}
      rule["paths"].each do |path|
        fail!("ownership path is listed twice: #{path}") if exact.key?(path)
        exact[path] = entry
      end
      rule["prefixes"].each do |prefix|
        fail!("ownership prefix must end with /: #{prefix}") unless prefix.end_with?("/")
        fail!("ownership prefix is listed twice: #{prefix}") if prefixes.key?(prefix)
        prefixes[prefix] = entry
      end
    end
    {repository: manifest["templateRepository"], exact: exact, prefixes: prefixes}
  end

  # An exact path wins; otherwise the longest matching prefix decides. Each path gets one category.
  def classify(ownership, path)
    return ownership[:exact][path] if ownership[:exact].key?(path)
    prefix = ownership[:prefixes].keys.select { |candidate| path.start_with?(candidate) }.max_by(&:length)
    prefix && ownership[:prefixes][prefix]
  end

  def check(options)
    allow_options!(options, [], ["--template-root", "--ref"])
    root = File.realpath(options.fetch("--template-root", template_root))
    commit = commit!(root, options.fetch("--ref", "HEAD"))
    ownership = load_ownership(blob(root, commit, OWNERSHIP_PATH))
    paths = tracked_paths(root, commit)
    unclassified = paths.reject { |path| classify(ownership, path) }
    fail!("unclassified template files: #{unclassified.first(20).join(", ")}") unless unclassified.empty?
    stale = ownership[:exact].keys - paths
    fail!("ownership lists untracked paths: #{stale.join(", ")}") unless stale.empty?
    unused = ownership[:prefixes].keys.reject { |prefix| paths.any? { |path| path.start_with?(prefix) } }
    fail!("ownership prefixes match no tracked file: #{unused.join(", ")}") unless unused.empty?

    # The identity manifest and the ownership manifest must agree on which files bootstrap rewrites.
    identity = JSON.parse(blob(root, commit, IDENTITY_MANIFEST_PATH))
    live = identity.fetch("liveContentPaths")
    renamed = identity.fetch("renamePaths")
    renamed_files = paths.select { |path| renamed.any? { |rename| path == rename || path.start_with?("#{rename}/") } }
    (live + renamed_files).uniq.each do |path|
      entry = classify(ownership, path)
      next if entry[:category] == "app" || entry[:transform]
      fail!("bootstrap rewrites #{path}, so ownership must mark it app-owned or transformed")
    end
    paths.each do |path|
      entry = classify(ownership, path)
      next unless entry[:transform]
      fail!("ownership transforms #{path}, which bootstrap does not rewrite") unless live.include?(path)
    end
    counts = CATEGORIES.to_h { |category| [category, paths.count { |path| classify(ownership, path)[:category] == category }] }
    {"status" => "classified", "commit" => commit, "files" => paths.length, "categories" => counts}
  end

  # --- report ---------------------------------------------------------------------------------

  def report(options)
    allow_options!(options, ["--app-root", "--output-dir"], ["--template-ref", "--work-dir", "--now"])
    root = template_root
    commit = commit!(root, options.fetch("--template-ref", "HEAD"))
    ownership = load_ownership(blob(root, commit, OWNERSHIP_PATH))
    app_root = app_root!(options.fetch("--app-root"))
    output = output_dir!(options.fetch("--output-dir"), app_root)
    now = options.fetch("--now", Time.now.utc.iso8601)
    fail!("--now must be a UTC timestamp") unless now.match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/)

    result = with_work_dir(options["--work-dir"], app_root) { |work| build_report(root, commit, ownership, app_root, work, now) }
    FileUtils.mkdir(output)
    json = canonical_json(result)
    File.write(File.join(output, "plan.json"), json)
    File.write(File.join(output, "plan.md"), render_markdown(result))
    {
      "status" => "reported", "output" => output, "planDigest" => "sha256:#{Digest::SHA256.hexdigest(json)}",
      "base" => result["base"]["status"], "summary" => result["summary"]
    }
  end

  # Run the block with a work dir outside the target: --work-dir, kept for reuse, or a temporary folder
  # removed afterwards.
  def with_work_dir(work_option, app_root)
    if work_option
      # Resolve through the nearest existing ancestor (and its symlinks) before creating anything.
      fail!("--work-dir must not be inside the app repository") if inside?(app_root, resolved_location(work_option))
      FileUtils.mkdir_p(work_option)
    end
    work = work_option ? File.realpath(work_option) : Dir.mktmpdir("template-sync")
    begin
      yield work
    ensure
      FileUtils.rm_rf(work) unless work_option
    end
  end

  def app_root!(value)
    root = File.realpath(value)
    fail!("--app-root must be a directory") unless File.directory?(root)
    top = git(root, "rev-parse", "--show-toplevel").strip
    fail!("--app-root must be the top of a Git repository") unless File.realpath(top) == root
    fail!("--app-root is the template repository itself") if root == template_root
    root
  rescue Errno::ENOENT
    fail!("--app-root does not exist")
  end

  def output_dir!(value, app_root)
    path = File.expand_path(value)
    fail!("--output-dir already exists") if File.exist?(path) || File.symlink?(path)
    parent = File.dirname(path)
    fail!("--output-dir parent does not exist") unless File.directory?(parent)
    real = resolved_location(path)
    fail!("--output-dir must not be inside the app repository; the report never writes there") if inside?(app_root, real)
    real
  end

  # The real location a path would have, even if its trailing components do not exist yet.
  def resolved_location(value)
    path = File.expand_path(value)
    missing = []
    until File.exist?(path) || File.symlink?(path)
      missing.unshift(File.basename(path))
      parent = File.dirname(path)
      fail!("cannot resolve #{value}") if parent == path
      path = parent
    end
    File.join(File.realpath(path), *missing)
  end

  def inside?(root, path)
    path == root || path.start_with?(root + File::SEPARATOR)
  end

  def build_report(root, commit, ownership, app_root, work, now)
    app_head = git(app_root, "rev-parse", "--verify", "HEAD^{commit}").strip
    dirty = !git(app_root, "status", "--porcelain", "--untracked-files=no").empty?

    new_raw = export_tree(root, commit, File.join(work, "template-#{commit}"))
    paths = tracked_paths(root, commit)
    app = read_app_files(app_root, app_head, paths + [APP_IDENTITY_PATH, BASE_RECORD_PATH])
    identity, identity_issues = read_identity(app)
    base = read_base(root, ownership, app)

    new_xf = identity && transform_tree(new_raw, commit, identity, work)
    base_raw = base["status"] == "known" ? export_tree(root, base["commit"], File.join(work, "template-#{base["commit"]}")) : nil
    base_xf = base_raw && identity && transform_tree(base_raw, base["commit"], identity, work)
    transform_status = if identity.nil? then "identity-unavailable"
                       elsif new_xf.nil? || (base_raw && base_xf.nil?) then "transform-failed"
                       else "applied"
                       end

    source = JSON.parse(File.read(File.join(new_raw, IDENTITY_MANIFEST_PATH))).fetch("source")
    tokens = [source.fetch("module"), source.fetch("bundleId")].uniq
    # Without a known base, each file is judged by its own provenance in the template's history (D-078).
    history = base["status"] == "known" ? nil : file_history(root, commit, ownership, paths, app, identity, new_raw, new_xf, transform_status, work)
    base_paths = base_raw ? tracked_paths(root, base["commit"]) : []
    missing_base_paths = base_paths - paths
    app.merge!(read_app_files(app_root, app_head, missing_base_paths)) unless missing_base_paths.empty?
    current = paths.to_set
    app_paths = git(app_root, "ls-tree", "-r", "-z", "--name-only", "--full-tree", app_head).force_encoding(Encoding::UTF_8).split("\0").reject(&:empty?).to_set
    # A file the template deleted keeps the ownership it had at the base; the current manifest may
    # no longer list it, or may now place it under a different rule.
    base_ownership = base_raw && historical_ownership(base_raw)
    app_case_index = case_index(app_paths)
    files = (paths | base_paths).sort.map do |path|
      entry = current.include?(path) ? classify(ownership, path) : base_ownership && classify(base_ownership, path)
      unless entry
        fail!("unclassified template file: #{path}") if current.include?(path)
        next unknown_deleted_file(path, app[path])
      end
      twin = current.include?(path) && app[path].nil? ? case_twin(app_case_index, path) : nil
      next case_collision_file(path, entry, twin) if twin
      blocked = path_blocked?(app_paths, path)
      next blocked_file(path, entry, blocked) if blocked && app[path].nil?
      compare_file(path, entry, new_raw: new_raw, new_xf: new_xf, base_raw: base_raw, base_xf: base_xf,
                   app_files: app, base_known: base["status"] == "known", tokens: tokens,
                   identity: identity, transform_status: transform_status, provenance: history && history[:files])
    end

    summary = Hash.new(0)
    files.each { |file| summary[file["status"]] += 1 }
    result = {
      "schemaVersion" => 1,
      "generatedAt" => now,
      "template" => {"repository" => ownership[:repository], "commit" => commit},
      "app" => {"head" => app_head, "uncommittedChanges" => dirty, "identity" => identity,
                "identityFormatIssues" => identity_issues, "transform" => transform_status},
      "base" => base,
      "files" => files,
      "summary" => summary.sort.to_h,
      "decisions" => decision_report(new_raw, base_raw, app),
      "simulators" => simulator_report(app, new_xf, identity),
      "approvals" => approvals(files)
    }
    # Shown to the user only; no decision above uses it. A known base keeps the D-074 plan unchanged.
    result["inferredBase"] = history[:inferred] if history
    result
  end

  def historical_ownership(tree)
    path = File.join(tree, OWNERSHIP_PATH)
    File.file?(path) ? load_ownership(File.read(path)) : nil
  rescue Failure, JSON::ParserError
    nil
  end

  # A template file cannot be added where the app has a folder of that name, or a file at a parent path.
  def path_blocked?(app_paths, path)
    parts = path.split("/")
    parent_file = (1...parts.length).map { |count| parts.first(count).join("/") }.find { |prefix| app_paths.include?(prefix) }
    return "アプリでは親のパス#{parent_file}がファイルです。" if parent_file
    prefix = "#{path}/"
    app_paths.any? { |candidate| candidate.start_with?(prefix) } ? "アプリでは同じ名前のフォルダがあります。" : nil
  end

  # Every tracked path and each of its parent folders, by the lowercase spelling, to the spellings in use.
  def case_index(paths)
    paths.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |path, index|
      parts = path.split("/")
      (1..parts.length).each { |count| prefix = parts.first(count).join("/"); index[prefix.downcase] << prefix }
    end
  end

  # A tracked path (or a parent folder) that differs from the template path only in case. On a case-insensitive
  # file system, such as the default APFS on macOS, writing the template path would write over it.
  def case_twin(index, path)
    parts = path.split("/")
    (1..parts.length).each do |count|
      prefix = parts.first(count).join("/")
      twin = index.fetch(prefix.downcase, nil)&.reject { |spelling| spelling == prefix }&.min
      return twin if twin
    end
    nil
  end

  def case_collision_file(path, entry, twin)
    record = blocked_file(path, entry, "アプリには、大文字と小文字だけが違う#{twin}があります。大文字と小文字を区別しないファイルシステムでは、書き込むとそれを上書きします。")
    record["status"] == "conflict" ? record.merge("caseCollision" => twin) : record
  end

  def blocked_file(path, entry, reason)
    record = {"path" => path, "category" => entry[:category]}
    record["rule"] = entry[:rule] if entry[:rule]
    return record.merge("status" => "app-owned", "action" => "skip", "reason" => "アプリが持つファイルなので取り込みません。") if entry[:category] == "app"
    return record.merge("status" => "template-only", "action" => "skip", "reason" => "テンプレート専用なのでアプリへ持ち込みません。") if entry[:category] == "template-only"
    record.merge("status" => "conflict", "action" => "manual", "reason" => "テンプレートのファイルを置けません。#{reason}")
  end

  # Without the base's ownership rule, a deleted file is never deleted automatically.
  def unknown_deleted_file(path, app_content)
    {
      "path" => path, "category" => "unknown", "status" => app_content.nil? ? "up-to-date" : "deleted-in-template",
      "action" => app_content.nil? ? "none" : "manual", "appDigest" => digest(app_content), "appMode" => app_content&.mode,
      "reason" => "テンプレートで削除されましたが、基準の版の所有区分が分からないため、削除せずに手で確認します。"
    }
  end

  def export_tree(root, commit, destination)
    return destination if File.directory?(destination)
    staging = "#{destination}.partial"
    FileUtils.rm_rf(staging)
    FileUtils.mkdir_p(staging)
    archive = git(root, "archive", "--format=tar", commit)
    _out, err, status = Open3.capture3("tar", "-x", "-C", staging, stdin_data: archive, binmode: true)
    fail!("could not export #{commit}: #{err.strip}") unless status.success?
    File.rename(staging, destination)
    destination
  end

  # Read only the paths the comparison needs from the target's HEAD, through git's object store.
  # Nothing in the target's working tree or index is touched.
  def read_app_files(app_root, head, paths)
    entries = {}
    git(app_root, "ls-tree", "-r", "-z", "--full-tree", head).force_encoding(Encoding::UTF_8).split("\0").each do |line|
      meta, path = line.split("\t", 2)
      next if path.nil?
      mode, type, sha = meta.split(" ")
      entries[path] = {mode: mode, type: type, sha: sha}
    end
    contents = {}
    # A submodule is compared as its own kind of entry, never read as file content.
    paths.uniq.each do |path|
      entry = entries[path]
      contents[path] = Entry.new(entry[:mode], "gitlink:#{entry[:sha]}") if entry && entry[:type] == "commit"
    end
    wanted = paths.uniq.select { |path| entries.key?(path) && entries[path][:type] == "blob" }
    return contents if wanted.empty?
    output = git(app_root, "cat-file", "--batch", input: wanted.map { |path| entries[path][:sha] }.join("\n") + "\n")
    offset = 0
    wanted.each do |path|
      header_end = output.index("\n", offset)
      sha, type, size = output[offset...header_end].split(" ")
      fail!("could not read #{path} from the target") unless type == "blob" && sha == entries[path][:sha]
      body = output.byteslice(header_end + 1, size.to_i)
      offset = header_end + 1 + size.to_i + 1
      contents[path] = Entry.new(entries[path][:mode], body)
    end
    contents
  end

  # Re-apply Identity bootstrap with the app's identity, using that template commit's own tool. The tool
  # is compiled once per version into work; the transformed tree goes into `into`.
  def transform_tree(raw, commit, identity, work, into: work)
    key = Digest::SHA256.hexdigest(JSON.generate([commit, identity.values_at("displayName", "moduleName", "appSlug", "bundleId")]))[0, 16]
    destination = File.join(into, "transformed-#{commit}-#{key}")
    return destination if File.directory?(destination)
    source = File.join(raw, "tools/bootstrap-app.swift")
    return nil unless File.file?(source)
    binary = File.join(work, "bootstrap-#{Digest::SHA256.file(source).hexdigest[0, 16]}")
    unless File.executable?(binary)
      _out, _err, status = Open3.capture3("swiftc", "-o", binary, source)
      return nil unless status.success?
    end
    staging = "#{destination}.partial"
    FileUtils.rm_rf(staging)
    FileUtils.cp_r(raw, staging)
    _out, _err, status = Open3.capture3(binary, "apply", "--root", staging, "--manifest", File.join(staging, IDENTITY_MANIFEST_PATH),
                                        "--display-name", identity["displayName"], "--module-name", identity["moduleName"],
                                        "--app-slug", identity["appSlug"], "--bundle-id", identity["bundleId"])
    unless status.success?
      FileUtils.rm_rf(staging)
      return nil
    end
    File.rename(staging, destination)
    destination
  end

  def read_identity(app)
    text = app[APP_IDENTITY_PATH]&.bytes
    return [nil, ["#{APP_IDENTITY_PATH}がありません。Identity bootstrapが未適用です。"]] if text.nil?
    value = JSON.parse(text.dup.force_encoding(Encoding::UTF_8))
    return [nil, ["#{APP_IDENTITY_PATH}がJSON objectではありません。"]] unless value.is_a?(Hash)
    issues = []
    missing = IDENTITY_KEYS - value.keys
    unknown = value.keys - IDENTITY_KEYS
    issues << "#{APP_IDENTITY_PATH}に#{missing.join("、")}がありません。" unless missing.empty?
    issues << "#{APP_IDENTITY_PATH}に未知のkey（#{unknown.join("、")}）があります。" unless unknown.empty?
    issues << "#{APP_IDENTITY_PATH}のschemaVersionが1ではありません。" if value.key?("schemaVersion") && value["schemaVersion"] != 1
    if value.key?("sourceIdentityVersion") && value["sourceIdentityVersion"] != 1
      issues << "#{APP_IDENTITY_PATH}のsourceIdentityVersionが1ではありません。"
    end
    usable = %w[displayName moduleName appSlug bundleId].all? { |key| value[key].is_a?(String) && !value[key].empty? }
    [usable ? value.slice(*IDENTITY_KEYS) : nil, issues]
  rescue JSON::ParserError
    [nil, ["#{APP_IDENTITY_PATH}を読めません。"]]
  end

  def read_base(root, ownership, app)
    text = app[BASE_RECORD_PATH]&.bytes
    return {"status" => "unknown", "reason" => "#{BASE_RECORD_PATH}がありません。"} if text.nil?
    value = JSON.parse(text.dup.force_encoding(Encoding::UTF_8))
    problem = if !value.is_a?(Hash) || value.keys.sort != BASE_KEYS then "keyが#{BASE_KEYS.join("、")}と一致しません。"
              elsif value["schemaVersion"] != 1 then "schemaVersionが1ではありません。"
              elsif value["templateRepository"] != ownership[:repository] then "templateRepositoryが#{ownership[:repository]}ではありません。"
              elsif !value["baseCommit"].to_s.match?(SHA_PATTERN) then "baseCommitが40桁のcommit SHAではありません。"
              elsif !BASE_METHODS.include?(value["method"]) then "methodがcreatedまたはadoptedではありません。"
              elsif !value["recordedAt"].to_s.match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/) then "recordedAtがUTC時刻ではありません。"
              elsif !commit_exists?(root, value["baseCommit"]) then "baseCommitがテンプレートの履歴にありません。"
              end
    return {"status" => "invalid", "reason" => "#{BASE_RECORD_PATH}の#{problem}"} if problem
    {"status" => "known", "commit" => value["baseCommit"], "method" => value["method"], "recordedAt" => value["recordedAt"]}
  rescue JSON::ParserError
    {"status" => "invalid", "reason" => "#{BASE_RECORD_PATH}を読めません。"}
  end

  def read(tree, path)
    return nil if tree.nil?
    full = File.join(tree, path)
    return Entry.new("120000", File.readlink(full)) if File.symlink?(full)
    return nil unless File.file?(full)
    Entry.new(File.executable?(full) ? "100755" : "100644", File.binread(full))
  end

  def digest(entry)
    entry && "sha256:#{Digest::SHA256.hexdigest(entry.bytes)}"
  end

  def compare_file(path, entry, new_raw:, new_xf:, base_raw:, base_xf:, app_files:, base_known:, tokens:, identity:, transform_status:, provenance: nil)
    record = {"path" => path, "category" => entry[:category]}
    record["rule"] = entry[:rule] if entry[:rule]
    if entry[:category] == "app"
      return record.merge("status" => "app-owned", "action" => "skip", "reason" => "アプリが持つファイルなので取り込みません。")
    end
    if entry[:category] == "template-only"
      # #433: a template-only file that the app already has (a copy of the template, or an earlier sync) is
      # left as it is, and the plan lists it so the sync Issue can decide whether the app keeps it.
      if app_files[path]
        return record.merge("status" => "template-only", "action" => "skip", "appPresent" => true,
                            "reason" => "テンプレート専用のファイルが、アプリに残っています。取り込みでは変えません。")
      end
      return record.merge("status" => "template-only", "action" => "skip", "reason" => "テンプレート専用なのでアプリへ持ち込みません。")
    end
    transformed = entry[:transform]
    if transformed && transform_status != "applied"
      reason = transform_status == "identity-unavailable" ? "アプリのIdentityが読めないため、Identity変換できません。" : "Identity変換に失敗しました。"
      current = app_files[path]
      return record.merge("status" => current.nil? ? "missing" : "conflict", "action" => "manual", "reason" => reason,
                          "appDigest" => digest(current), "appMode" => current&.mode)
    end
    new = read(transformed ? new_xf : new_raw, path)
    base = base_known ? read(transformed ? base_xf : base_raw, path) : nil
    app = app_files[path]
    # Without a known base (D-078), a file that is exactly one of the template's earlier versions takes
    # that version as its base; a file that matches none of them records the nearest version.
    origin = provenance && provenance[path]
    if origin && origin[:entry]
      base = origin[:entry]
      record["provenance"] = {"commit" => origin[:commit], "method" => "exact"}
    elsif origin
      record["nearest"] = origin[:nearest]
    end
    record.merge!("newDigest" => digest(new), "baseDigest" => digest(base), "appDigest" => digest(app),
                  "newMode" => new&.mode, "baseMode" => base&.mode, "appMode" => app&.mode)

    status, action, reason =
      if new.nil?
        if app.nil? then ["up-to-date", "none", "テンプレートでもアプリでも削除済みです。"]
        elsif app == base then ["deleted-in-template", "delete", "テンプレートで削除され、アプリ側は基準のままです。"]
        else ["deleted-in-template", "manual", "テンプレートで削除されましたが、アプリ側に変更があります。"]
        end
      elsif app.nil? && base_known && !base.nil?
        # The file existed at the base, so its absence is an app-side deletion, not a missing file.
        if new == base then ["app-only-change", "keep", "アプリ側で削除したファイルなので、戻しません。"]
        else ["conflict", "manual", "アプリ側で削除されましたが、テンプレート側は変わっています。"]
        end
      elsif app.nil? then ["missing", "add", "アプリにありません。"]
      elsif app == new then ["up-to-date", "none", "テンプレートと一致しています。"]
      elsif !base_known
        fail!("no provenance was found for #{path}") if origin.nil?
        if origin[:entry]
          ["safe-update", "update", "基準commitは不明ですが、アプリ側はテンプレートの`#{origin[:commit][0, 7]}`の版と1バイトも違わないため、最新の版へ更新できます。"]
        else
          ["conflict", "manual", "基準commitが不明で、アプリ側の内容はテンプレートのどの版とも一致しません。アプリ側で変更したものとして手で確認します。"]
        end
      elsif base.nil? then ["conflict", "manual", "テンプレートが新しく追加したパスに、アプリが別の内容を置いています。"]
      elsif app == base then ["safe-update", "update", "アプリ側は基準のままで、テンプレート側だけが変わりました。"]
      elsif new == base then ["app-only-change", "keep", "アプリ側だけの変更なので残します。"]
      else ["conflict", "manual", "テンプレート側とアプリ側の両方が変わっています。"]
      end

    if transformed && new && %w[add update].include?(action)
      before = ((app || base)&.bytes || "").scan(Regexp.union(tokens)).length
      if new.bytes.scan(Regexp.union(tokens)).length > before
        action = "manual"
        reason = "Identity変換後も元の名前（#{tokens.join("、")}）が増えるため、上書きしません。"
        record["identityRegression"] = true
      end
    end
    if entry[:category] == "mixed" && action != "none"
      action = "manual"
      reason = "#{reason} #{mixed_note(entry[:rule])}"
    end
    record.merge("status" => status, "action" => action, "reason" => reason)
  end

  def mixed_note(rule)
    {
      "agents-md" => "AGENTS.mdはテンプレートとアプリの規則が混ざるため手で確認し、変更する文面はD-075に従ってユーザーの承認を得ます。",
      "agents-md-approvals" => "承認記録はテンプレートとアプリの記録が混ざるため、テンプレートの記録を追記する形で手で確認します。",
      "decisions" => "決定事項はテンプレートのD-###を末尾へ追記する形で手で確認し、番号の衝突があれば追記しません。",
      "dedicated-simulators" => "専用Simulatorはアプリの表示名を前置した2台を保ち、テンプレート用の端末を指す変更を入れません。",
      "ownership" => "アカウントと提出先の設定はアプリの値を保ち、テンプレートの構造の変更だけを手で取り込みます。",
      "repository-tests" => "test manifestはアプリが追加したtestを保ち、テンプレートの変更を手で取り込みます。"
    }.fetch(rule)
  end

  # --- provenance without a known base (D-078) ------------------------------------------------

  # Every template, Identity and mixed file the app has that differs from the newest template version
  # is compared with each version of the same path in the template's history up to the compared
  # commit. A file that is one of them byte for byte and mode for mode is that version, unmodified, so
  # the newest version can replace it; any other file is the app's own change and gets the nearest
  # version for review. Identity-transformed files are compared with each version transformed by the
  # app's Identity with that commit's own tool. Returns {files: {path => origin}, inferred: ...}.
  def file_history(root, commit, ownership, paths, app, identity, new_raw, new_xf, transform_status, work)
    examined = {}
    paths.each do |path|
      entry = classify(ownership, path)
      next unless entry && %w[template identity mixed].include?(entry[:category]) && app[path]
      next if entry[:transform] && transform_status != "applied"
      examined[path] = entry[:transform]
    end
    differing = examined.select do |path, transformed|
      newest = read(transformed ? new_xf : new_raw, path)
      newest && newest != app[path]
    end
    # A transformed file that already matches the newest version gets no provenance, but its raw bytes can
    # differ between commits that transform to the same content, so the inferred base needs its history too.
    compared = examined.select { |path, transformed| transformed || differing.key?(path) }
    log = template_log(root, commit, (examined.keys + TRANSFORM_TOOL_PATHS).to_set)
    states = compared.to_h { |path, transformed| [path, history_states(log, commit, path, transformed)] }

    # Untransformed versions are read straight from the object store; transformed ones come from the
    # commits that changed the path or the transform tool, each transformed once and kept in work.
    untransformed = states.reject { |path, _| compared[path] }.values.flatten(1).map(&:last).compact
    blobs = read_blobs(root, untransformed.reject { |mode, _| mode == "160000" }.map(&:last))
    transformed_paths = paths.select { |path| classify(ownership, path)&.dig(:transform) }.sort
    trees = {commit => new_xf}
    files = {}
    matches = {}
    compared.each do |path, transformed|
      versions = states.fetch(path).map do |sha, raw|
        entry = if raw.nil? then nil
                elsif transformed
                  trees[sha] = transformed_history(root, sha, identity, transformed_paths, work) unless trees.key?(sha)
                  # This commit's tool could not transform it, so the version cannot be compared.
                  trees[sha].nil? ? :untransformable : read(trees[sha], path)
                elsif raw[0] == "160000" then Entry.new(raw[0], "gitlink:#{raw[1]}")
                else Entry.new(raw[0], blobs.fetch(raw[1]))
                end
        {commit: sha, entry: entry}
      end
      # Whether the transformed content equals the app's from each of these commits until the next one.
      # The same raw bytes can transform differently once the tool changes, so the content decides.
      matches[path] = versions.to_h { |version| [version[:commit], version[:entry] == app[path]] } if transformed
      next unless differing.key?(path)
      versions = versions.reject { |version| version[:entry] == :untransformable }
      # A state equal to the one before it introduced nothing. Identical bytes can come back later (a
      # revert, for example); the newest commit that introduced them is the one recorded.
      introduced = []
      versions.each { |version| introduced << version if introduced.empty? || introduced.last[:entry] != version[:entry] }
      introduced = introduced.select { |version| version[:entry] }.reverse
      found = introduced.find { |version| version[:entry] == app[path] }
      files[path] = found ? {commit: found[:commit], entry: found[:entry]} : {nearest: nearest_version(introduced, app[path])}
    end
    {files: files, inferred: inferred_base(root, log, examined, app, matches)}
  end

  # Each commit up to commit, newest first (no parent before its children), with the paths it changed
  # among wanted: [mode, object name], or nil where it deleted the path. A merge is compared with its
  # first parent, so what it brings into the history counts as changed there.
  def template_log(root, commit, wanted)
    output = git(root, "log", "--format=%H", "-z", "--raw", "--root", "--no-renames", "--no-abbrev", "--diff-merges=first-parent",
                 "--ignore-submodules=none", "--date-order", "--no-color", "--no-show-signature", commit, "--")
    tokens = output.force_encoding(Encoding::UTF_8).split("\0")
    log = []
    index = 0
    while index < tokens.length
      token = tokens[index]
      index += 1
      if (change = token.match(/\A\n?:\d{6} (\d{6}) \h+ (\h+) [A-Z]\d*\z/))
        path = tokens[index]
        index += 1
        fail!("could not read the template history") if log.empty? || path.nil?
        log.last[1][path] = change[1] == "000000" ? nil : [change[1], change[2]] if wanted.include?(path)
      elsif token.match?(/\A\h{40}(?:\h{24})?\z/)
        log << [token, {}]
      else
        fail!("could not read the template history")
      end
    end
    log
  end

  # The states of one path in history order: [commit, raw entry or nil]. An Identity-transformed path
  # also gets a state at each commit that changed the transform tool, and at the compared commit.
  def history_states(log, commit, path, transformed)
    states = []
    current = nil
    log.reverse_each do |sha, changes|
      changed = changes.key?(path)
      next unless changed || (transformed && TRANSFORM_TOOL_PATHS.any? { |tool| changes.key?(tool) })
      current = changes[path] if changed
      states << [sha, current]
    end
    states << [commit, current] if transformed && states.last&.first != commit
    states
  end

  # Blobs by object name, through one cat-file process.
  def read_blobs(root, names)
    names = names.uniq
    return {} if names.empty?
    output = git(root, "cat-file", "--batch", input: names.join("\n") + "\n")
    blobs = {}
    offset = 0
    names.each do |name|
      header_end = output.index("\n", offset)
      sha, type, size = header_end && output[offset...header_end].split(" ")
      fail!("could not read #{name} from the template history") unless type == "blob" && sha == name
      blobs[name] = output.byteslice(header_end + 1, size.to_i)
      offset = header_end + 1 + size.to_i + 1
    end
    blobs
  end

  # An earlier commit with the app's Identity applied by that commit's own tool. Only the transformed
  # paths are kept, so a long history leaves one small folder per commit in the work dir instead of two
  # copies of the template. nil when that commit's tool cannot transform it.
  def transformed_history(root, sha, identity, transformed_paths, work)
    key = Digest::SHA256.hexdigest(JSON.generate([sha, identity.values_at("displayName", "moduleName", "appSlug", "bundleId"), transformed_paths]))[0, 16]
    destination = File.join(work, "history-#{sha}-#{key}")
    return destination if File.directory?(destination)
    scratch = "#{destination}.partial"
    FileUtils.rm_rf(scratch)
    FileUtils.mkdir_p(scratch)
    transformed = transform_tree(export_tree(root, sha, File.join(scratch, "raw")), sha, identity, work, into: scratch)
    return nil if transformed.nil?
    kept = File.join(scratch, "kept")
    FileUtils.mkdir_p(kept)
    transformed_paths.each do |path|
      entry = read(transformed, path)
      next if entry.nil?
      target = File.join(kept, path)
      FileUtils.mkdir_p(File.dirname(target))
      if entry.mode == "120000"
        File.symlink(entry.bytes, target)
      else
        File.binwrite(target, entry.bytes)
        File.chmod(entry.mode == "100755" ? 0o755 : 0o644, target)
      end
    end
    File.rename(kept, destination)
    destination
  ensure
    FileUtils.rm_rf(scratch) if scratch
  end

  # The version with the fewest changed lines; among equals, the newest. A version that differs only in
  # file mode has no changed lines, but it is still not a match.
  def nearest_version(versions, app_entry)
    best = nil
    versions.each do |version|
      lines = changed_lines(version[:entry].bytes, app_entry.bytes, best && best["changedLines"] - 1)
      best = {"commit" => version[:commit], "changedLines" => lines} if lines
    end
    best
  end

  # Lines removed plus lines added between two versions, by Myers' O(ND) diff after the common start and
  # end are set aside. nil once the count would exceed limit.
  def changed_lines(before, after, limit = nil)
    a = before.b.lines
    b = after.b.lines
    start = 0
    start += 1 while start < a.length && start < b.length && a[start] == b[start]
    finish = 0
    finish += 1 while finish < a.length - start && finish < b.length - start && a[-1 - finish] == b[-1 - finish]
    ids = {}
    a = a[start...(a.length - finish)].map { |line| ids[line] ||= ids.length }
    b = b[start...(b.length - finish)].map { |line| ids[line] ||= ids.length }
    n = a.length
    m = b.length
    max = limit ? [n + m, limit].min : n + m
    return nil if (n - m).abs > max
    offset = max + 1
    furthest = Array.new(2 * max + 3, 0)
    (0..max).each do |edits|
      (-edits..edits).step(2) do |diagonal|
        x = if diagonal == -edits || (diagonal != edits && furthest[offset + diagonal - 1] < furthest[offset + diagonal + 1])
              furthest[offset + diagonal + 1]
            else
              furthest[offset + diagonal - 1] + 1
            end
        y = x - diagonal
        while x < n && y < m && a[x] == b[y]
          x += 1
          y += 1
        end
        furthest[offset + diagonal] = x
        return edits if x >= n && y >= m
      end
    end
    nil
  end

  # The commit at which the most of the app's files are exactly the template's (D-078). It is only shown
  # to the user; every decision comes from each file's own provenance. Walking the history from the
  # oldest commit, an untransformed file matches while its mode and object name equal the app's; an
  # Identity-transformed one matches while the content its latest state transformed to, with that
  # state's own tool, equals the app's. Only a commit that turns a file into a match can be the inferred
  # base, so a later commit that changes none of them never wins a tie; among those, ties go to the newest.
  def inferred_base(root, log, examined, app, matches)
    format = git(root, "rev-parse", "--show-object-format").strip
    wanted = examined.reject { |_, transformed| transformed }.to_h { |path, _| [path, [app[path].mode, object_name(app[path], format)]] }
    current = Hash.new(false)
    count = 0
    best = nil
    log.reverse_each do |sha, changes|
      updates = changes.select { |path, _| wanted.key?(path) }.map { |path, name| [path, name == wanted[path]] }
      updates += matches.select { |_, by_commit| by_commit.key?(sha) }.map { |path, by_commit| [path, by_commit[sha]] }
      raised = updates.any? { |path, matched| matched && !current[path] }
      updates.each do |path, matched|
        count += (matched ? 1 : 0) - (current[path] ? 1 : 0)
        current[path] = matched
      end
      best = {"commit" => sha, "matchedFiles" => count} if raised && (best.nil? || count >= best["matchedFiles"])
    end
    best
  end

  # The object name Git gives these bytes, so an app file can be found in the template's trees.
  def object_name(entry, format)
    return entry.bytes.delete_prefix("gitlink:") if entry.mode == "160000"
    data = "blob #{entry.bytes.bytesize}\0".b + entry.bytes.b
    format == "sha256" ? Digest::SHA256.hexdigest(data) : Digest::SHA1.hexdigest(data)
  end

  def decision_entries(text)
    return {} if text.nil?
    text.dup.force_encoding(Encoding::UTF_8).scan(DECISION_HEADING).to_h { |id, title| [id, title.strip] }
  end

  def decision_report(new_raw, base_raw, app_files)
    template = decision_entries(read(new_raw, DECISIONS_PATH)&.bytes)
    base = base_raw ? decision_entries(read(base_raw, DECISIONS_PATH)&.bytes) : nil
    app = decision_entries(app_files[DECISIONS_PATH]&.bytes)
    added = base ? template.keys - base.keys : template.keys - app.keys
    collisions = template.keys.select { |id| app.key?(id) && app[id] != template[id] }.sort.map do |id|
      {"id" => id, "template" => template[id], "app" => app[id]}
    end
    # Appended only when nothing collides and the target has the file; a decision it already has stays.
    append = collisions.empty? && app_files[DECISIONS_PATH] ? (added - app.keys).sort : []
    {
      "templateNew" => added.sort,
      "collisions" => collisions,
      "appendable" => collisions.empty?,
      "append" => append,
      "note" => collisions.empty? ? "テンプレートの新しいD-###を末尾へ追記できます。" :
        "番号が衝突しています。アプリ固有の決定事項を`specs/app-decisions.md`の`A-###`へ移すまで、テンプレートのD-###を追記しません。"
    }
  end

  def simulator_report(app_files, new_xf, identity)
    names = lambda do |text|
      next [] if text.nil?
      JSON.parse(text.dup.force_encoding(Encoding::UTF_8)).fetch("devices", []).map { |device| device["name"] }
    rescue JSON::ParserError
      []
    end
    app_names = names.call(app_files[SIMULATORS_PATH]&.bytes)
    planned = names.call(read(new_xf, SIMULATORS_PATH)&.bytes)
    prefix = identity && "#{identity["displayName"]} "
    problems = []
    problems << "アプリの#{SIMULATORS_PATH}がありません。" if app_names.empty?
    problems << "アプリの専用Simulatorが2台ではありません。" unless app_names.empty? || app_names.length == 2
    if prefix
      problems << "アプリの専用Simulatorが表示名「#{identity["displayName"]}」で始まっていません。" unless app_names.all? { |name| name.start_with?(prefix) }
      problems << "テンプレートを変換した宣言が表示名で始まっていません。" unless planned.all? { |name| name.start_with?(prefix) }
    end
    problems << "アプリの専用Simulatorがテンプレート用の端末を指しています。" if app_names.any? { |name| name.start_with?(TEMPLATE_DEVICE_PREFIX) }
    problems << "変換後の宣言がテンプレート用の端末を指しています。" if planned.any? { |name| name.start_with?(TEMPLATE_DEVICE_PREFIX) }
    {"app" => app_names, "planned" => planned, "problems" => problems}
  end

  def approvals(files)
    list = ["適用計画の承認（原則ユーザー。ユーザーが指定したときだけCodexが計画を確認して承認します。D-074）"]
    if files.any? { |file| file["rule"] == "agents-md" && file["action"] != "none" }
      list << "AGENTS.mdの変更文面のユーザー承認と、Issueコメントおよびdocs/agents-md-approvals.mdへの記録（D-075）"
    end
    list
  end

  # --- preflight (D-078) ----------------------------------------------------------------------

  # The labels of an Issue someone is working on: claimed, in progress, verified, in review, sent back,
  # waiting for merge, or paused. Any blocked:* label counts too.
  WORKING_LABELS = %w[state:claimed state:in-progress state:verify-passed state:review-requested
                      state:changes-requested state:approved-for-merge state:paused].freeze
  BLOCKED_LABEL_PREFIX = "blocked:"
  # One gh query lists at most this many open Issues or PRs; a full page may hide the rest.
  GH_LIST_LIMIT = 1000
  # Each gh query runs under bounded-command.rb and stops after this many seconds; tests may shorten it.
  GH_TIMEOUT_SECONDS = 60
  # A plan is large above these counts (D-078). D-078 lets a later Decision adjust them after real imports.
  LARGE_WRITE_FILES = 30
  LARGE_MANUAL_FILES = 10
  WRITE_ACTIONS = %w[add update delete].freeze
  UNTOUCHED_ACTIONS = %w[none skip].freeze
  REPOSITORY_PATTERN = %r{\A[\w.-]+/[\w.-]+\z}

  # Before an import starts, judge from reads alone whether the target is busy with other work and how
  # large the planned change is. Nothing is written to the target and nothing changes on GitHub. The
  # result only advises: whether to work in parallel is decided by the user's explicit instruction.
  def preflight(options)
    allow_options!(options, ["--app-root", "--repo", "--plan", "--output-dir"], ["--now"])
    app_root = app_root!(options.fetch("--app-root"))
    repository = options.fetch("--repo")
    fail!("--repo must be owner/name") unless repository.match?(REPOSITORY_PATTERN)
    output = output_dir!(options.fetch("--output-dir"), app_root)
    now = timestamp!(options)
    _plan_path, plan, plan_digest = read_plan(options.fetch("--plan"))
    size = size_estimate(plan)

    # Every check runs before anything is written, so a check that cannot run leaves no result at all.
    head = git(app_root, "rev-parse", "--verify", "HEAD^{commit}").strip
    checkout = checkout_findings(app_root)
    findings = issue_findings(repository) + pull_request_findings(repository) + checkout[:findings]
    result = {
      "schemaVersion" => 1,
      "generatedAt" => now,
      "repository" => repository,
      "app" => {"head" => head},
      "plan" => {"digest" => plan_digest, "appHead" => plan.dig("app", "head"), "templateCommit" => plan.dig("template", "commit")},
      "status" => findings.empty? ? "idle" : "busy",
      "findings" => findings,
      "size" => size
    }
    FileUtils.mkdir(output)
    json = canonical_json(result)
    File.write(File.join(output, "preflight.json"), json)
    File.write(File.join(output, "preflight.md"), render_preflight(result))
    {
      "status" => result["status"], "size" => size["estimate"], "output" => output,
      "preflightDigest" => "sha256:#{Digest::SHA256.hexdigest(json)}", "planDigest" => plan_digest
    }
  end

  # Large when any D-078 reason applies, with every reason that applies. Of the work that must come
  # first, only what the plan itself shows counts here (a decision-number collision and an unusable
  # Identity); the analysis finds the rest.
  def size_estimate(plan)
    files = plan["files"]
    valid = files.all? { |file| file.is_a?(Hash) && %w[path category action].all? { |key| file[key].is_a?(String) } } &&
            plan["base"].is_a?(Hash) && plan["app"].is_a?(Hash) && plan["app"].key?("identity") &&
            plan["decisions"].is_a?(Hash) && plan["decisions"]["append"].is_a?(Array) &&
            plan["decisions"]["collisions"].is_a?(Array) && plan["decisions"]["collisions"].all? { |item| item.is_a?(Hash) && item["id"].is_a?(String) }
    fail!("the plan lacks what the size estimate reads; make a new report") unless valid
    writes = files.count { |file| WRITE_ACTIONS.include?(file["action"]) }
    manual = files.count { |file| file["action"] == "manual" }
    reasons = []
    unless plan["base"]["status"] == "known"
      reasons << {"kind" => "base-unknown", "message" => "基準commitが分かりません。#{plan["base"]["reason"]}"}
    end
    if writes > LARGE_WRITE_FILES
      reasons << {"kind" => "many-writes", "count" => writes, "message" => "書き込むファイルが#{writes}個で、#{LARGE_WRITE_FILES}個を超えています。"}
    end
    if manual > LARGE_MANUAL_FILES
      reasons << {"kind" => "many-manual", "count" => manual, "message" => "手で確認するファイルが#{manual}個で、#{LARGE_MANUAL_FILES}個を超えています。"}
    end
    # The shared settings are the mixed files (AGENTS.md, Config/repository-tests.json, specs/decisions.md
    # and the other mixed rules). Appending decisions writes specs/decisions.md as well.
    shared = files.select { |file| file["category"] == "mixed" && !UNTOUCHED_ACTIONS.include?(file["action"]) }.map { |file| file["path"] }
    shared |= [DECISIONS_PATH] unless plan["decisions"]["append"].empty?
    unless shared.empty?
      shared.sort!
      reasons << {"kind" => "shared-settings", "paths" => shared, "message" => "共有の設定（#{shared.map { |path| "`#{path}`" }.join("、")}）に触れます。"}
    end
    collisions = plan["decisions"]["collisions"].map { |item| item["id"] }
    unless collisions.empty?
      reasons << {"kind" => "decision-collision", "ids" => collisions,
                  "message" => "決定事項の番号が衝突しています（#{collisions.join("、")}）。先にアプリ固有の決定事項を`specs/app-decisions.md`の`A-###`へ移します。"}
    end
    if plan["app"]["identity"].nil?
      reasons << {"kind" => "identity-unavailable", "message" => "取り込み先のIdentityが設定されていないか、読めません。先にIdentity bootstrapを済ませます。"}
    end
    {
      "estimate" => reasons.empty? ? "normal" : "large", "writeFiles" => writes, "manualFiles" => manual, "reasons" => reasons,
      "limits" => {"writeFiles" => LARGE_WRITE_FILES, "manualFiles" => LARGE_MANUAL_FILES}
    }
  end

  # Open Issues with a working-state label, through the gh on PATH.
  def issue_findings(repository)
    gh_list(repository, "issue", "number,title,labels").map do |issue|
      labels = issue["labels"]
      fail!("gh issue list returned an unexpected answer; cannot tell whether #{repository} is busy") unless labels.is_a?(Array) && labels.all? { |label| label.is_a?(Hash) && label["name"].is_a?(String) }
      working = labels.map { |label| label["name"] }.select { |name| WORKING_LABELS.include?(name) || name.start_with?(BLOCKED_LABEL_PREFIX) }.sort
      working.empty? ? nil : {"kind" => "issue", "number" => issue["number"], "title" => issue["title"], "labels" => working}
    end.compact.sort_by { |finding| finding["number"] }
  end

  # Every open PR, whatever its state, is work in progress.
  def pull_request_findings(repository)
    gh_list(repository, "pr", "number,title,headRefName").map do |pull|
      fail!("gh pr list returned an unexpected answer; cannot tell whether #{repository} is busy") unless pull["headRefName"].is_a?(String)
      {"kind" => "pull-request", "number" => pull["number"], "title" => pull["title"], "branch" => pull["headRefName"]}
    end.sort_by { |finding| finding["number"] }
  end

  # One read-only list query. If gh fails or its answer cannot be read, the preflight stops: a target
  # whose state could not be checked is never reported as idle.
  def gh_list(repository, kind, fields)
    args = [kind, "list", "--repo", repository, "--state", "open", "--limit", GH_LIST_LIMIT.to_s, "--json", fields]
    timeout = ENV.fetch("IOS_TEMPLATE_SYNC_GH_TIMEOUT_SECONDS", GH_TIMEOUT_SECONDS.to_s)
    fail!("IOS_TEMPLATE_SYNC_GH_TIMEOUT_SECONDS must be an integer from 1 to 300") unless timeout.match?(/\A[1-9]\d{0,2}\z/) && timeout.to_i <= 300
    bounded = ["/usr/bin/ruby", File.join(__dir__, "bounded-command.rb"), "--stage", "template-sync-gh-#{kind}",
               "--timeout-seconds", timeout, "--grace-seconds", "2", "--", "gh", *args]
    stdout, stderr, status = Open3.capture3({"GH_PROMPT_DISABLED" => "1"}, *bounded)
    fail!("gh #{kind} list did not answer within #{timeout} seconds; cannot tell whether #{repository} is busy") if status.exitstatus == 124
    fail!("gh could not be started (#{stderr.strip}); cannot tell whether #{repository} is busy") if status.exitstatus == 126
    fail!("gh #{kind} list failed (#{stderr.strip}); cannot tell whether #{repository} is busy") unless status.success?
    entries = JSON.parse(stdout.force_encoding(Encoding::UTF_8))
    valid = entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Hash) && entry["number"].is_a?(Integer) && entry["title"].is_a?(String) }
    fail!("gh #{kind} list returned an unexpected answer; cannot tell whether #{repository} is busy") unless valid
    fail!("gh #{kind} list returned #{GH_LIST_LIMIT} entries and may have left some out; cannot tell whether #{repository} is busy") if entries.length >= GH_LIST_LIMIT
    entries
  rescue JSON::ParserError
    fail!("gh #{kind} list returned output that is not JSON; cannot tell whether #{repository} is busy")
  rescue Errno::ENOENT
    fail!("gh is not on PATH; cannot tell whether #{repository} is busy")
  end

  # The target's own checkout: every worktree besides the main one, the main checkout on a branch other
  # than main (or on none), and uncommitted changes there: tracked changes, staged or not, and files not
  # yet tracked that .gitignore does not exclude.
  def checkout_findings(app_root)
    worktrees = worktree_records(app_root)
    main = worktrees.first
    main_path = main && !main.key?("bare") && File.directory?(main["worktree"]) ? File.realpath(main["worktree"]) : nil
    fail!("--app-root must be the main checkout of the target, not a linked worktree") unless main_path == app_root
    findings = worktrees.drop(1).map do |record|
      {"kind" => "worktree", "path" => record["worktree"], "branch" => record["branch"]&.delete_prefix("refs/heads/"), "head" => record["HEAD"]}
    end
    branch = main["branch"]&.delete_prefix("refs/heads/")
    findings << {"kind" => "branch", "branch" => branch} unless branch == "main"
    # D-078 counts every uncommitted change as other work in progress: a new file that is not yet tracked
    # (outside .gitignore) is as much in progress as an edited one.
    tracked, untracked = working_changes(app_root)
    findings << {"kind" => "uncommitted-changes", "paths" => tracked} unless tracked.empty?
    findings << {"kind" => "untracked-files", "paths" => untracked} unless untracked.empty?
    {findings: findings}
  end

  # The records of `git worktree list --porcelain -z`; the first one is the main worktree.
  def worktree_records(root)
    records = []
    current = nil
    git(root, "worktree", "list", "--porcelain", "-z").force_encoding(Encoding::UTF_8).split("\0").each do |line|
      if line.empty?
        current = nil
        next
      end
      key, value = line.split(" ", 2)
      if key == "worktree"
        current = {"worktree" => value}
        records << current
      elsif current
        current[key] = value || true
      else
        fail!("could not read the worktrees of #{root}")
      end
    end
    records
  end

  # Tracked changes and untracked files of a checkout, from its porcelain status.
  def working_changes(root)
    tokens = git(root, "status", "--porcelain=v1", "-z", "--untracked-files=normal").force_encoding(Encoding::UTF_8).split("\0")
    tracked = []
    untracked = []
    until tokens.empty?
      line = tokens.shift
      code = line[0, 2]
      path = line[3..-1]
      if code == "??"
        untracked << path
      else
        tracked << path
        # A rename or a copy is followed by the path it came from.
        tokens.shift if code.include?("R") || code.include?("C")
      end
    end
    [tracked.sort, untracked.sort]
  end

  def render_preflight(result)
    size = result["size"]
    busy = result["status"] == "busy"
    large = size["estimate"] == "large"
    limits = size["limits"]
    lines = []
    lines << "# テンプレートの取り込みの事前の判定"
    lines << ""
    lines << "- 取り込み先: `#{result["repository"]}`（HEAD `#{result.dig("app", "head")}`）"
    lines << "- 計画: `plan.json`（#{result.dig("plan", "digest")}）"
    unless result.dig("plan", "appHead") == result.dig("app", "head")
      lines << "- 計画は取り込み先の別のHEAD（`#{result.dig("plan", "appHead")}`）で作られています。取り込む前に、新しいレポートを作ってください。"
    end
    lines << "- この判定は読み取りだけで行い、取り込み先とGitHubへ何も書き込んでいません。"
    lines << ""
    lines << "## ほかの作業中か: #{busy ? "作業中" : "作業中ではない"}"
    lines << ""
    if busy
      result["findings"].each { |finding| lines << "- #{finding_line(finding)}" }
    else
      lines << "作業中の状態のIssue、開いているPR、本体以外のworktree、`main`以外のブランチや未commitの変更がある本体のcheckoutは、どれもありません。"
    end
    lines << ""
    lines << "## 変更の大きさ: #{large ? "大きい" : "通常"}"
    lines << ""
    lines << "- 書き込むファイル: #{size["writeFiles"]}個（#{limits["writeFiles"]}個を超えると大きい変更）"
    lines << "- 手で確認するファイル: #{size["manualFiles"]}個（#{limits["manualFiles"]}個を超えると大きい変更）"
    size["reasons"].each { |reason| lines << "- 理由: #{reason["message"]}" }
    lines << ""
    lines << "## 進め方"
    lines << ""
    lines << if busy
               "- ほかの作業中なので、取り込みを始めません。上の作業が終わるまで待ってから取り込むことをおすすめします。"
             elsif large
               "- ほかの作業中ではありません。大きい変更なので、取り込みが終わるまでほかの作業を始めずに待つことをおすすめします。"
             else
               "- ほかの作業中ではありません。取り込み先の単独の作業として、テンプレート同期Issueで進められます。"
             end
    lines << "- 並行して進めるなら、worktreeを分けて行えます。ただし、大きい変更では並行をおすすめしません。#{large ? "今回は大きい変更です。" : ""}"
    lines << "- 並行して進めるかは、ユーザーの明示の指示だけで決めます。この判定は並行するかを決めません。"
    lines << ""
    lines.join("\n")
  end

  def finding_line(finding)
    case finding["kind"]
    when "issue" then "Issue ##{finding["number"]}「#{finding["title"]}」（#{finding["labels"].join("、")}）"
    when "pull-request" then "開いているPR ##{finding["number"]}「#{finding["title"]}」（ブランチ`#{finding["branch"]}`）"
    when "worktree" then "本体以外のworktree `#{finding["path"]}`（#{finding["branch"] ? "ブランチ`#{finding["branch"]}`" : "ブランチなし"}）"
    when "branch"
      finding["branch"] ? "本体のcheckoutが`main`ではなく`#{finding["branch"]}`にいます。" : "本体のcheckoutがどのブランチにもいません（detached HEAD）。"
    when "uncommitted-changes" then "本体のcheckoutに未commitの変更があります: #{finding["paths"].map { |path| "`#{path}`" }.join("、")}"
    when "untracked-files" then "本体のcheckoutに未commitの新しいファイルがあります: #{finding["paths"].map { |path| "`#{path}`" }.join("、")}"
    end
  end

  # --- analysis (D-078) -----------------------------------------------------------------------

  # A target-only file may duplicate a template file when it has the same file name at another path, or
  # when its content is similar: the Jaccard index of the two files' sets of distinct lines (each line
  # stripped of surrounding whitespace, blank lines left out), shared lines divided by the lines either
  # file has, is at least SIMILARITY_THRESHOLD. Only text files (no NUL byte) up to SIMILARITY_MAX_BYTES
  # with at least SIMILARITY_MIN_LINES such lines are compared, the template's before the Identity transform.
  SIMILARITY_THRESHOLD = Rational(3, 5)
  SIMILARITY_MAX_BYTES = 1_048_576
  SIMILARITY_MIN_LINES = 3
  # At most this many similar template files are listed for one target file, the most similar first.
  SIMILAR_LISTED = 3
  # A file name the template uses at more than one path (SKILL.md, for example) names a role many folders
  # share, so a target file with that name is compared by content only. These conventional names count as
  # shared even where the template uses them once.
  SHARED_FILE_NAMES = %w[.gitignore .gitkeep LICENSE README.md].freeze
  # The app's own records, which the template never has: they are never possible duplicates.
  APP_RECORD_PATHS = [APP_IDENTITY_PATH, BASE_RECORD_PATH, "specs/app-decisions.md"].freeze
  # The categories an import brings into the target.
  RECEIVED_CATEGORIES = %w[template identity mixed].freeze
  CHANGE_OPTIONS = {"keep-app" => "アプリの変更を残す", "take-template" => "テンプレートに合わせる", "merge" => "両方を合わせる"}.freeze
  APP_CHANGE_STATUSES = %w[conflict app-only-change].freeze
  REPORT_HINTS = {"candidate" => "ありそう", "app-specific" => "なさそう", "unclear" => "分からない"}.freeze
  UPDATE_ACTIONS = {"add" => "追加", "update" => "更新", "manual" => "手で確認"}.freeze
  # A difference is summarized by counts and at most EXCERPT_LINES changed lines of EXCERPT_WIDTH
  # characters, never the whole file. Long commit subjects and tool lists are cut in analysis.md only.
  EXCERPT_LINES = 5
  EXCERPT_WIDTH = 120
  SUBJECT_WIDTH = 80
  LISTED_TOOLS = 20
  DECISION_MENTION = /(?<![A-Za-z0-9_-])D-\d{3,}(?!\d)/
  # What must be cleared first, in the order it is cleared. The Identity comes first: without it the
  # Identity files cannot be compared and the dedicated Simulators have no name prefix. Moving the app's
  # decisions and fixing the Simulator declaration change the target, so the plan is made again after
  # them. The base record and the target's tools are handled by the import itself.
  PREREQUISITES = {
    "identity-unavailable" => "Identityの未設定", "identity-format" => "Identityの形式の違い",
    "decision-collision" => "決定事項の番号の衝突", "simulators" => "専用Simulatorの宣言",
    "case-collision" => "大文字と小文字だけが違うパス", "base-record" => "基準commitの記録",
    "outdated-tools" => "取り込み先のtoolの更新"
  }.freeze
  # The size estimate counts the others itself (D-078); these only the analysis finds.
  UNCOUNTED_PREREQUISITES = %w[identity-format simulators outdated-tools].freeze

  # Before the user approves a plan, explain it from reads alone: the template's history up to the plan's
  # commit, the plan, the target's HEAD through Git's objects and, if given, the preflight. Nothing is
  # written to the target; analysis.json and analysis.md go to a new folder outside it.
  def analyze(options)
    allow_options!(options, ["--plan", "--app-root", "--output-dir"], ["--preflight", "--work-dir", "--now"])
    app_root = app_root!(options.fetch("--app-root"))
    output = output_dir!(options.fetch("--output-dir"), app_root)
    now = timestamp!(options)
    _plan_path, plan, plan_digest = read_plan(options.fetch("--plan"))
    size = size_estimate(plan)
    analysis_plan!(plan)
    root = template_root
    commit = plan["template"]["commit"]
    unless commit.match?(/\A\h{40}(?:\h{24})?\z/) && commit_exists?(root, commit)
      fail!("the plan names template commit #{commit}, which is not in the template's history")
    end
    ownership = load_ownership(blob(root, commit, OWNERSHIP_PATH))
    fail!("the plan names another template repository") unless plan["template"]["repository"] == ownership[:repository]
    head = git(app_root, "rev-parse", "--verify", "HEAD^{commit}").strip
    fail!("the target moved since the plan was made: HEAD is #{head}, the plan is for #{plan["app"]["head"]}") unless head == plan["app"]["head"]
    preflight = options.key?("--preflight") ? read_preflight(options["--preflight"], plan_digest, head) : nil

    parts = with_work_dir(options["--work-dir"], app_root) { |work| build_analysis(root, commit, ownership, app_root, plan, work) }
    final = analysis_size(preflight ? preflight[:size] : size, preflight ? "preflight" : "plan", parts[:prerequisites])
    result = {
      "schemaVersion" => 1,
      "generatedAt" => now,
      "planDigest" => plan_digest,
      "template" => {"repository" => plan["template"]["repository"], "commit" => commit},
      "app" => {"head" => head},
      "summary" => {
        "writeFiles" => final["writeFiles"], "manualFiles" => final["manualFiles"], "renamePairs" => parts[:renames].length,
        "possibleDuplicates" => parts[:duplicates].length, "prerequisites" => parts[:prerequisites].map { |item| item["kind"] },
        "size" => final["estimate"]
      },
      "size" => final,
      "updates" => parts[:updates],
      "renames" => parts[:renames],
      "duplicates" => parts[:duplicates],
      "similarity" => {
        "measure" => "line-set-jaccard", "threshold" => SIMILARITY_THRESHOLD.to_f, "maxBytes" => SIMILARITY_MAX_BYTES,
        "minLines" => SIMILARITY_MIN_LINES, "sharedNames" => SHARED_FILE_NAMES
      },
      "appChanges" => parts[:changes],
      "otherManual" => parts[:other],
      "prerequisites" => parts[:prerequisites]
    }
    result.merge!("preflightDigest" => preflight[:digest], "preflightStatus" => preflight[:status]) if preflight
    FileUtils.mkdir(output)
    json = canonical_json(result)
    File.write(File.join(output, "analysis.json"), json)
    File.write(File.join(output, "analysis.md"), render_analysis(result))
    answer = {"status" => "analyzed", "output" => output, "analysisDigest" => "sha256:#{Digest::SHA256.hexdigest(json)}",
              "planDigest" => plan_digest, "summary" => result["summary"]}
    answer["preflightDigest"] = preflight[:digest] if preflight
    answer
  end

  # What the analysis reads beyond what the size estimate already checked.
  def analysis_plan!(plan)
    inferred = plan["inferredBase"]
    valid = plan["template"].is_a?(Hash) && plan["template"]["commit"].is_a?(String) && plan["app"]["identityFormatIssues"].is_a?(Array) &&
            plan["app"]["transform"].is_a?(String) && plan["simulators"].is_a?(Hash) && plan["simulators"]["problems"].is_a?(Array) &&
            plan["base"]["status"].is_a?(String) && plan["files"].all? { |file| file["status"].is_a?(String) && nearest_valid?(file) } &&
            (inferred.nil? || (inferred.is_a?(Hash) && inferred["commit"].is_a?(String)))
    fail!("the plan lacks what the analysis reads; make a new report") unless valid
  end

  def nearest_valid?(file)
    nearest = file["nearest"]
    nearest.nil? || (nearest.is_a?(Hash) && nearest["commit"].to_s.match?(/\A\h{40}(?:\h{24})?\z/) && nearest["changedLines"].is_a?(Integer))
  end

  # A preflight of this very plan at the target's current HEAD.
  def read_preflight(value, plan_digest, head)
    bytes = File.binread(File.realpath(value))
    preflight = JSON.parse(bytes)
    size = preflight.is_a?(Hash) ? preflight["size"] : nil
    valid = size.is_a?(Hash) && preflight["schemaVersion"] == 1 && %w[idle busy].include?(preflight["status"]) &&
            preflight["plan"].is_a?(Hash) && preflight["app"].is_a?(Hash) && %w[normal large].include?(size["estimate"]) &&
            size["writeFiles"].is_a?(Integer) && size["manualFiles"].is_a?(Integer) && size["limits"].is_a?(Hash) && size["reasons"].is_a?(Array) &&
            size["reasons"].all? { |reason| reason.is_a?(Hash) && reason["kind"].is_a?(String) && reason["message"].is_a?(String) }
    fail!("--preflight must be the preflight.json of a template sync preflight") unless valid
    fail!("the preflight was made for another plan (#{preflight["plan"]["digest"]}); the plan is #{plan_digest}") unless preflight["plan"]["digest"] == plan_digest
    fail!("the preflight was made at another HEAD of the target (#{preflight["app"]["head"]}); HEAD is #{head}") unless preflight["app"]["head"] == head
    {digest: "sha256:#{Digest::SHA256.hexdigest(bytes)}", status: preflight["status"], size: size}
  rescue Errno::ENOENT
    fail!("--preflight does not exist")
  end

  def build_analysis(root, commit, ownership, app_root, plan, work)
    files = plan["files"]
    by_path = files.to_h { |file| [file["path"], file] }
    template_tree = tree_entries(root, commit)
    app_tree = tree_entries(app_root, plan["app"]["head"])
    renames = rename_pairs(root, commit, template_tree, app_tree, by_path)
    shown = %w[conflict missing safe-update]
    other = files.select { |file| file["action"] == "manual" && !shown.include?(file["status"]) }.sort_by { |file| file["path"] }
    {
      updates: update_entries(root, commit, files, template_tree),
      renames: renames,
      duplicates: duplicate_entries(root, commit, ownership, plan, template_tree, app_root, app_tree, by_path, renames.map { |pair| pair["oldPath"] }),
      changes: app_change_entries(root, commit, ownership, plan, app_root, work),
      other: other.map { |file| {"path" => file["path"], "status" => file["status"], "reason" => file["reason"]} },
      prerequisites: prerequisite_entries(plan)
    }
  end

  # Every entry of a commit's tree: path => {mode:, type:, sha:, size:}; a submodule's size is "-".
  def tree_entries(root, commit)
    git(root, "ls-tree", "-r", "-z", "-l", "--full-tree", commit).force_encoding(Encoding::UTF_8).split("\0").each_with_object({}) do |line, entries|
      meta, path = line.split("\t", 2)
      next if path.nil?
      mode, type, sha, size = meta.split(" ")
      entries[path] = {mode: mode, type: type, sha: sha, size: size}
    end
  end

  # 1. Missing and outdated files: the commit that brought each file's newest version, the Issue and PR
  # numbers in that commit's subject, and the template decisions that the commit message or the lines the
  # commit added to the file mention. An Identity-transformed file is traced by its content before the
  # transform.
  def update_entries(root, commit, files, template_tree)
    chosen = files.select { |file| %w[missing safe-update].include?(file["status"]) }.sort_by { |file| file["path"] }
    return [] if chosen.empty?
    known = template_tree.key?(DECISIONS_PATH) ? decision_entries(blob(root, commit, DECISIONS_PATH)).keys.to_set : Set.new
    newest = {}
    template_log(root, commit, chosen.map { |file| file["path"] }.to_set).each do |sha, changes|
      changes.each_key { |path| newest[path] ||= sha }
    end
    messages = commit_messages(root, newest.values)
    chosen.map do |file|
      path = file["path"]
      sha = newest[path]
      record = {"path" => path, "status" => file["status"], "action" => file["action"]}
      record["reason"] = file["reason"] if file["action"] == "manual"
      next record.merge("commit" => nil, "subject" => nil, "issue" => nil, "pullRequest" => nil, "decisions" => []) if sha.nil?
      message = messages.fetch(sha)
      mentioned = mentioned_decisions(message[:body]) | mentioned_decisions(added_lines(root, sha, path).join("\n"))
      record.merge(commit_reference(sha, message)).merge("decisions" => sort_decisions(mentioned.select { |id| known.include?(id) }))
    end
  end

  # Subject and message of each commit, through one git process.
  def commit_messages(root, shas)
    shas = shas.compact.uniq
    return {} if shas.empty?
    output = git(root, "log", "--no-walk=unsorted", "-z", "--no-color", "--format=%H%x1f%s%x1f%B", *shas, "--")
    output.force_encoding(Encoding::UTF_8).scrub.split("\0").each_with_object({}) do |record, messages|
      sha, subject, body = record.sub(/\A\n/, "").split("\x1f", 3)
      messages[sha] = {subject: subject.to_s, body: body.to_s}
    end
  end

  # A squash-merged subject ends with its pull request, "(#NNN)"; an Issue's subject may start "Issue #NNN:".
  def commit_reference(sha, message)
    subject = message[:subject]
    pull = subject[/\(#(\d+)\)\s*\z/, 1]
    issue = subject[/\AIssue #(\d+):/, 1]
    {"commit" => sha, "subject" => subject, "pullRequest" => pull && pull.to_i, "issue" => issue && issue.to_i}
  end

  # The lines one commit added to one path, compared with its first parent.
  def added_lines(root, sha, path)
    output = git(root, "--literal-pathspecs", "show", "--format=", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames",
                 "--unified=0", "--diff-merges=first-parent", sha, "--", path)
    diff_changes(output)[:added]
  end

  def mentioned_decisions(text)
    text.b.scan(DECISION_MENTION).map { |id| id.dup.force_encoding(Encoding::UTF_8) }.uniq
  end

  def sort_decisions(ids)
    ids.uniq.sort_by { |id| [id[2..-1].to_i, id] }
  end

  # The changed lines of a unified diff without context, in order, as [sign, line without the sign].
  def diff_changes(output)
    changes = []
    binary = false
    in_hunk = false
    output.b.each_line do |line|
      if line.start_with?("diff --git ")
        in_hunk = false
      elsif line.start_with?("@@")
        in_hunk = true
      elsif in_hunk && (line.start_with?("+") || line.start_with?("-"))
        changes << [line[0], line[1..-1].chomp]
      elsif !in_hunk && line.start_with?("Binary files ")
        binary = true
      end
    end
    {binary: binary, changes: changes, added: changes.select { |sign, _| sign == "+" }.map(&:last),
     removed: changes.select { |sign, _| sign == "-" }.map(&:last)}
  end

  # 2a. Renames in the template's history whose old name the target still has, each as one pair: delete
  # the old file, take the new one. A chain of renames ends at the name the template has now.
  def rename_pairs(root, commit, template_tree, app_tree, by_path)
    latest = {}
    template_renames(root, commit).each_with_index { |(sha, old, new), index| latest[old] = [index, sha, new] }
    pairs = []
    latest.each do |old, (index, sha, new)|
      next if template_tree.key?(old) || !app_tree.key?(old)
      path = new
      via = []
      position = index
      while (step = latest[path]) && step[0] > position
        via << path
        position = step[0]
        path = step[2]
      end
      file = by_path[path]
      next unless template_tree.key?(path) && file && RECEIVED_CATEGORIES.include?(file["category"])
      pairs << {"oldPath" => old, "newPath" => path, "via" => via, "commit" => sha, "newStatus" => file["status"],
                "newAction" => file["action"], "oldAction" => by_path[old] && by_path[old]["action"]}
    end
    messages = commit_messages(root, pairs.map { |pair| pair["commit"] })
    pairs.sort_by { |pair| pair["oldPath"] }.map { |pair| pair.merge(commit_reference(pair["commit"], messages.fetch(pair["commit"]))) }
  end

  # Each rename up to commit, oldest first, as [commit, old path, new path]. A merge is compared with its
  # first parent, as in template_log.
  def template_renames(root, commit)
    output = git(root, "log", "-z", "--format=%H", "--name-status", "-M", "--diff-filter=R", "--diff-merges=first-parent",
                 "--no-color", "--no-show-signature", commit, "--")
    tokens = output.force_encoding(Encoding::UTF_8).split("\0")
    renames = []
    sha = nil
    index = 0
    while index < tokens.length
      token = tokens[index]
      index += 1
      if token.match?(/\A\n?R\d*\z/)
        old, new = tokens[index, 2]
        index += 2
        fail!("could not read the renames in the template history") if sha.nil? || new.nil?
        renames << [sha, old, new]
      elsif (match = token.match(/\A\n?(\h{40}(?:\h{24})?)\z/))
        sha = match[1]
      elsif !token.strip.empty?
        fail!("could not read the renames in the template history")
      end
    end
    renames.reverse
  end

  # 2b. Files only the target has that may duplicate a template file. Left out are the template's own
  # paths, the plan's paths, the app's records, the old names of 2a, and the app's own files: a path that
  # Identity bootstrap renamed (the app's module folder, for example) is classified as the template path
  # it came from. Each file is compared with the files an import brings (template, identity, mixed).
  def duplicate_entries(root, commit, ownership, plan, template_tree, app_root, app_tree, by_path, renamed)
    mapping = identity_path_mapping(root, commit, plan["app"]["identity"])
    candidates = app_tree.select do |path, entry|
      next false unless entry[:type] == "blob"
      next false if template_tree.key?(path) || by_path.key?(path) || APP_RECORD_PATHS.include?(path) || renamed.include?(path)
      classify(ownership, template_path_for(path, mapping))&.dig(:category) != "app"
    end
    return [] if candidates.empty?
    received = template_tree.select do |path, entry|
      entry[:type] == "blob" && RECEIVED_CATEGORIES.include?(classify(ownership, path)&.dig(:category))
    end
    by_name = received.keys.group_by { |path| File.basename(path) }
    template_lines = line_sets(root, received)
    app_lines = line_sets(app_root, candidates)
    index = {}
    template_lines.each { |path, lines| lines.each { |line| (index[line] ||= []) << path } }
    candidates.keys.sort.map do |path|
      name = File.basename(path)
      same = SHARED_FILE_NAMES.include?(name) || by_name.fetch(name, []).length != 1 ? [] : by_name[name]
      similar = similar_files(app_lines[path], template_lines, index)
      same.empty? && similar.empty? ? nil : {"path" => path, "sameName" => same, "similar" => similar}
    end.compact
  end

  # The template paths Identity bootstrap renames, as [template path, the target's path]; TemplateApp/ is
  # the app's module folder in the target, for example. Without a usable Identity there is no mapping.
  def identity_path_mapping(root, commit, identity)
    return [] unless identity.is_a?(Hash) && identity["moduleName"].is_a?(String)
    manifest = JSON.parse(blob(root, commit, IDENTITY_MANIFEST_PATH))
    source = manifest.fetch("source").fetch("module")
    manifest.fetch("renamePaths").map { |path| [path, path.gsub(source) { identity["moduleName"] }] }
  rescue Failure, JSON::ParserError, KeyError
    []
  end

  def template_path_for(path, mapping)
    from, to = mapping.select { |_, app| path == app || path.start_with?("#{app}/") }.max_by { |_, app| app.length }
    from ? from + path[to.length..-1] : path
  end

  # The distinct non-blank lines of each file the similarity compares.
  def line_sets(root, entries)
    wanted = entries.select { |_, entry| entry[:mode] != "120000" && entry[:size].to_i <= SIMILARITY_MAX_BYTES }
    blobs = read_blobs(root, wanted.values.map { |entry| entry[:sha] })
    wanted.each_with_object({}) do |(path, entry), sets|
      bytes = blobs.fetch(entry[:sha]).b
      next if bytes.include?("\0")
      lines = bytes.each_line.map(&:strip).reject(&:empty?).uniq
      sets[path] = lines.to_set if lines.length >= SIMILARITY_MIN_LINES
    end
  end

  def similar_files(lines, template_lines, index)
    return [] if lines.nil?
    shared = Hash.new(0)
    lines.each { |line| (index[line] || []).each { |path| shared[path] += 1 } }
    scored = shared.map do |path, count|
      score = Rational(count, lines.length + template_lines[path].length - count)
      score >= SIMILARITY_THRESHOLD ? [path, score] : nil
    end
    scored.compact.sort_by { |path, score| [-score, path] }.first(SIMILAR_LISTED).map do |path, score|
      {"path" => path, "similarity" => score.to_f.round(3)}
    end
  end

  # 3. Files the app changed (the plan's conflicts): how each differs from the template's nearest version
  # (with a recorded base, the base version; otherwise the newest), three ways to settle it, and a
  # suggested finding on whether the change might be worth reporting back to the template.
  def app_change_entries(root, commit, ownership, plan, app_root, work)
    # Both kinds of app-side change (D-078): a conflict, and, with a recorded base, a change or deletion of
    # a file the template left as it was at the base, which the plan keeps.
    conflicts = plan["files"].select { |file| APP_CHANGE_STATUSES.include?(file["status"]) }.sort_by { |file| file["path"] }
    return [] if conflicts.empty?
    app = read_app_files(app_root, plan["app"]["head"], conflicts.map { |file| file["path"] })
    identity = plan["app"]["identity"]
    transformable = plan["app"]["transform"] == "applied"
    trees = {}
    conflicts.map do |file|
      path = file["path"]
      transform = if !classify(ownership, path)&.dig(:transform) then "none"
                  elsif transformable then "applied"
                  elsif plan["app"]["transform"] == "identity-unavailable" then "unavailable"
                  else "failed"
                  end
      reference = change_reference(file, plan, commit)
      source = reference && reference_entry(root, commit, ownership, reference, path, transform == "applied" ? identity : nil, work, trees)
      # That commit's own tool could not transform it, so there is nothing to compare with.
      transform = "untransformable" if transform == "applied" && reference && source.nil?
      difference, added = describe_difference(source, app[path], work)
      record = {"path" => path, "category" => file["category"], "status" => file["status"], "action" => file["action"], "reason" => file["reason"],
                "reference" => reference && reference.merge("transform" => transform), "difference" => difference,
                "options" => CHANGE_OPTIONS.keys, "reportHint" => report_hint(file, difference, added, identity)}
      record["rule"] = file["rule"] if file["rule"]
      record
    end
  end

  def change_reference(file, plan, commit)
    if file.key?("nearest")
      nearest = file["nearest"]
      nearest && {"kind" => "nearest", "commit" => nearest["commit"], "changedLines" => nearest["changedLines"]}
    elsif plan["base"]["status"] == "known" && file["baseDigest"]
      {"kind" => "base", "commit" => plan["base"]["commit"]}
    else
      {"kind" => "newest", "commit" => commit}
    end
  end

  # The template's version of path at the reference commit. With an Identity, it is transformed by that
  # commit's own tool, as the report compared it, so a work dir the report used is reused; nil if the
  # tool cannot transform it.
  def reference_entry(root, commit, ownership, reference, path, identity, work, trees)
    sha = reference["commit"]
    return template_entry(root, sha, path) unless identity
    tree = trees.fetch(sha) do
      trees[sha] = if sha == commit || reference["kind"] == "base"
                     transform_tree(export_tree(root, sha, File.join(work, "template-#{sha}")), sha, identity, work)
                   else
                     trees[:paths] ||= tracked_paths(root, commit).select { |candidate| classify(ownership, candidate)&.dig(:transform) }.sort
                     transformed_history(root, sha, identity, trees[:paths], work)
                   end
    end
    tree && read(tree, path)
  end

  # One path of a template commit as Git stores it, or nil.
  def template_entry(root, sha, path)
    line = git(root, "--literal-pathspecs", "ls-tree", "-z", "--full-tree", sha, "--", path).force_encoding(Encoding::UTF_8).split("\0").first
    return nil if line.nil?
    meta, found = line.split("\t", 2)
    mode, type, name = meta.split(" ")
    return nil unless found == path
    return Entry.new(mode, "gitlink:#{name}") if type == "commit"
    type == "blob" ? Entry.new(mode, read_blobs(root, [name]).fetch(name)) : nil
  end

  # How the app's file differs from the template's version: the counts of lines the app added and
  # removed (git's minimal diff) and the first few of them, never the whole file. Returns the summary and
  # every added line.
  def describe_difference(template, app, work)
    return [{"kind" => "app-missing"}, []] if app.nil?
    return [{"kind" => "no-reference"}, []] if template.nil?
    modes = {"templateMode" => template.mode, "appMode" => app.mode}
    return [modes.merge("kind" => "not-a-file"), []] if [template.mode, app.mode].include?("160000")
    return [modes.merge("kind" => "mode-only"), []] if template.bytes.b == app.bytes.b
    return [modes.merge("kind" => "binary"), []] if template.bytes.b.include?("\0") || app.bytes.b.include?("\0")
    diff = line_diff(template.bytes, app.bytes, work)
    return [modes.merge("kind" => "binary"), []] if diff[:binary]
    excerpt = diff[:changes].reject { |_, line| line.strip.empty? }.first(EXCERPT_LINES).map { |sign, line| "#{sign}#{excerpt_line(line)}" }
    [modes.merge("kind" => "lines", "added" => diff[:added].length, "removed" => diff[:removed].length, "excerpt" => excerpt), diff[:added]]
  end

  # git's minimal line diff of two contents, written to a folder in the work dir and run from there.
  def line_diff(before, after, work)
    dir = Dir.mktmpdir("difference", work)
    File.binwrite(File.join(dir, "template"), before)
    File.binwrite(File.join(dir, "app"), after)
    stdout, stderr, status = Open3.capture3({"GIT_OPTIONAL_LOCKS" => "0"}, "git", "-c", "core.fsmonitor=false", "-c", "core.autocrlf=false",
                                            "diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv", "--diff-algorithm=myers",
                                            "--minimal", "--unified=0", "--", "template", "app", chdir: dir, binmode: true)
    fail!("git diff failed: #{stderr.strip}") unless [0, 1].include?(status.exitstatus)
    diff_changes(stdout)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  def excerpt_line(line)
    text = line.dup.force_encoding(Encoding::UTF_8).scrub("?")
    text.length > EXCERPT_WIDTH ? "#{text[0, EXCERPT_WIDTH]}…" : text
  end

  # Only a suggestion, and marked as one: the user decides, and a report to the template is made only when
  # the user asks, through report-template-issue.
  def report_hint(file, difference, added, identity)
    names = identity ? identity.values_at("displayName", "moduleName", "appSlug", "bundleId").select { |name| name.is_a?(String) && !name.empty? } : []
    found = names.select { |name| added.any? { |line| line.b.include?(name.b) } }
    if file["category"] == "mixed"
      {"kind" => "app-specific", "note" => "テンプレートとアプリの内容が混ざるファイルなので、違いはアプリの値や規則と見られます。"}
    elsif !found.empty?
      {"kind" => "app-specific", "note" => "アプリの名前（#{found.join("、")}）を含む変更なので、アプリ固有の変更と見られます。"}
    elsif %w[lines mode-only].include?(difference["kind"])
      {"kind" => "candidate", "note" => "アプリの名前を含まない変更です。テンプレートの不具合の修正や改善であれば、テンプレートでも役に立ちます。"}
    else
      {"kind" => "unclear", "note" => "行で比べられないため、判断する材料がありません。"}
    end
  end

  # 4. What must be cleared first, in the order of PREREQUISITES.
  def prerequisite_entries(plan)
    items = []
    issues = plan["app"]["identityFormatIssues"]
    if plan["app"]["identity"].nil?
      items << {"kind" => "identity-unavailable", "issues" => issues,
                "message" => "取り込み先のIdentityが使えません。#{issues.join}Identity bootstrapを済ませる（または`#{APP_IDENTITY_PATH}`を直す）までは、Identity変換されるファイルを比べられず、適用toolも止まります。"}
    elsif !issues.empty?
      items << {"kind" => "identity-format", "issues" => issues,
                "message" => "`#{APP_IDENTITY_PATH}`の形式がテンプレートと違います。#{issues.join}形式を直します。"}
    end
    collisions = plan["decisions"]["collisions"]
    unless collisions.empty?
      items << {"kind" => "decision-collision", "collisions" => collisions,
                "message" => "決定事項の番号が衝突しています（#{collisions.map { |item| item["id"] }.join("、")}）。アプリ固有の決定事項を`specs/app-decisions.md`の`A-###`へ移します（D-069）。移すまで、適用toolはテンプレートの決定事項を追記せずに止まります。"}
    end
    problems = plan["simulators"]["problems"]
    unless problems.empty?
      items << {"kind" => "simulators", "problems" => problems,
                "message" => "専用Simulatorの宣言（`#{SIMULATORS_PATH}`）を、取り込み先の表示名を前置した2台に直します。#{problems.join}直すまで、適用toolは止まります。"}
    end
    collided = plan["files"].select { |file| file["caseCollision"] }
    unless collided.empty?
      pairs = collided.map { |file| {"template" => file["path"], "app" => file["caseCollision"]} }
      listed = pairs.map { |pair| "`#{pair["app"]}`（テンプレートは`#{pair["template"]}`）" }.join("、")
      items << {"kind" => "case-collision", "pairs" => pairs,
                "message" => "アプリには、テンプレートのパスと大文字と小文字だけが違うファイルかフォルダがあります: #{listed}。大文字と小文字を区別しないファイルシステムでは、書き込むとアプリのものを上書きするため、計画はこれらを書き込まずに手で確認します。取り込みの前に、アプリ側の名前を変えるか移して、計画を作り直します。"}
    end
    base = plan["base"]
    unless base["status"] == "known"
      inferred = plan["inferredBase"]
      note = inferred ? "推定の基準は`#{inferred["commit"][0, 7]}`です（参考）。" : ""
      message = if base["status"] == "invalid"
                  "基準commitの記録が不正です。#{base["reason"]}この計画は、記録がない場合と同じく、ファイルごとの出どころで判定しています（D-078）。#{note}なぜ不正になったかを確かめます。記録は、適用toolが取り込んだテンプレートのcommitで書き直します。"
                else
                  "基準commitが記録されていません。#{base["reason"]}この計画は、ファイルごとの出どころで判定しています（D-078）。#{note}記録は、適用toolが取り込んだテンプレートのcommitで作ります。"
                end
      items << {"kind" => "base-record", "status" => base["status"], "reason" => base["reason"], "message" => message}
    end
    tools = plan["files"].select { |file| file["path"].start_with?("tools/") && file["category"] == "template" && %w[safe-update conflict].include?(file["status"]) }
    unless tools.empty?
      update = tools.select { |file| file["status"] == "safe-update" }.map { |file| file["path"] }.sort
      manual = tools.select { |file| file["status"] == "conflict" }.map { |file| file["path"] }.sort
      parts = []
      parts << "安全に更新できる#{update.length}個は、この計画の適用で更新します。" unless update.empty?
      parts << "アプリ側で変えた#{manual.length}個は、取り込み先で検証する前に、「3. アプリ独自の改造」で扱いを決めます。" unless manual.empty?
      items << {"kind" => "outdated-tools", "update" => update, "manual" => manual,
                "message" => "検証に使う取り込み先のtoolのうち#{tools.length}個が、テンプレートの最新と違います。#{parts.join}"}
    end
    items.each_with_index.map { |item, index| item.merge("order" => index + 1) }
  end

  # The size of the change (D-078): the preflight's estimate, or the same rules applied to the plan, plus
  # the work that must come first that only the analysis finds.
  def analysis_size(size, source, prerequisites)
    extra = prerequisites.map { |item| item["kind"] } & UNCOUNTED_PREREQUISITES
    reasons = size["reasons"].dup
    unless extra.empty?
      reasons << {"kind" => "prerequisites", "items" => extra,
                  "message" => "先に必要な整理があります（#{extra.map { |kind| PREREQUISITES.fetch(kind) }.join("、")}）。"}
    end
    {
      "source" => source, "estimate" => (size["estimate"] == "large" || !extra.empty?) ? "large" : "normal",
      "writeFiles" => size["writeFiles"], "manualFiles" => size["manualFiles"], "limits" => size["limits"], "reasons" => reasons
    }
  end

  # analysis.md is made from analysis.json alone.
  def render_analysis(result)
    summary = result["summary"]
    size = result["size"]
    limits = size["limits"]
    lines = []
    lines << "# テンプレートの取り込みの事前の分析"
    lines << ""
    lines << "- テンプレート: `#{result.dig("template", "repository")}` の `#{result.dig("template", "commit")}`"
    lines << "- 取り込み先のHEAD: `#{result.dig("app", "head")}`"
    lines << "- 分析した計画: `plan.json`（#{result["planDigest"]}）"
    if result.key?("preflightDigest")
      lines << "- 事前の判定: `preflight.json`（#{result["preflightDigest"]}）。ほかの作業中か: #{result["preflightStatus"] == "busy" ? "作業中" : "作業中ではない"}"
    end
    lines << "- この分析は読み取りだけで行い、取り込み先へ何も書き込んでいません。計画を承認する前に、`plan.md`とあわせて読みます。"
    lines << ""
    lines << "## 要約"
    lines << ""
    lines << "- 書き込むファイル: #{summary["writeFiles"]}個（#{limits["writeFiles"]}個を超えると大きい変更）"
    lines << "- 手で確認するファイル: #{summary["manualFiles"]}個（#{limits["manualFiles"]}個を超えると大きい変更）"
    lines << "- 名前の変更で古い名前が残っているもの: #{summary["renamePairs"]}組"
    lines << "- 重複の可能性: #{summary["possibleDuplicates"]}個"
    kinds = summary["prerequisites"]
    lines << "- 先に必要な整理: #{kinds.empty? ? "なし" : "#{kinds.length}件（#{kinds.map { |kind| PREREQUISITES.fetch(kind) }.join("、")}）"}"
    source = size["source"] == "preflight" ? "`preflight.json`の判定" : "計画から求めた判定"
    source += "に、この分析で見つかった先に必要な整理を加えました" if size["reasons"].any? { |reason| reason["kind"] == "prerequisites" }
    lines << "- 変更の大きさ: #{size["estimate"] == "large" ? "大きい" : "通常"}（#{source}）"
    size["reasons"].each { |reason| lines << "  - 理由: #{reason["message"]}" }
    lines << ""
    lines << "## 1. 不足と更新"
    lines << ""
    lines << "テンプレートにあって取り込み先にないものと、取り込み先が古い版のままのものです。それぞれに、今の版を入れたテンプレートのcommit、その件名にあるIssueとPRの番号、関係する決定事項を添えます。関係する決定事項は、commitのメッセージと、そのcommitがこのファイルに加えた行に出てくる`D-###`のうち、テンプレートの`#{DECISIONS_PATH}`にあるものです。Identity変換されるファイルは、変換する前の内容を変えたcommitを示します。"
    [["missing", "足りないファイル"], ["safe-update", "古い版のままのファイル"]].each do |status, title|
      entries = result["updates"].select { |entry| entry["status"] == status }
      lines << ""
      lines << "### #{title}（#{entries.length}個）"
      lines << ""
      lines << "なし" if entries.empty?
      entries.each do |entry|
        reason = entry["reason"] ? "。手で確認する理由: #{entry["reason"]}" : ""
        lines << "- #{UPDATE_ACTIONS.fetch(entry["action"], entry["action"])}: `#{entry["path"]}` — #{commit_note(entry, true)}#{reason}"
      end
    end
    lines << ""
    lines << "## 2. 重複と名前の変更"
    lines << ""
    lines << "### 名前の変更（#{result["renames"].length}組）"
    lines << ""
    lines << "テンプレートの履歴で名前が変わったファイルのうち、古い名前が取り込み先に残っているものです。古い方の削除と新しい方の追加を1組として扱います。"
    lines << ""
    lines << "なし" if result["renames"].empty?
    result["renames"].each do |pair|
      via = pair["via"].empty? ? "" : "途中の名前は#{pair["via"].map { |path| "`#{path}`" }.join("、")}です。"
      lines << "- `#{pair["oldPath"]}` → `#{pair["newPath"]}`: #{commit_note(pair, false)}で名前が変わりました。#{via}#{rename_note(pair)}"
    end
    similarity = result["similarity"]
    lines << ""
    lines << "### 重複の可能性（#{result["duplicates"].length}個）"
    lines << ""
    lines << "取り込み先だけにあるファイル（テンプレートの今の版にも計画にもなく、アプリが持つファイルや記録でもないもの）のうち、次のどちらかに当たるものです。"
    lines << ""
    lines << "- 同じ名前: テンプレートが1か所だけで使うファイル名と同じ名前で、別の場所にあります。テンプレートが2か所以上で使う名前と、#{similarity["sharedNames"].join("、")}は、多くのフォルダで使う名前なので中身だけで比べます。"
    lines << "- 中身が似ている: 前後の空白を除いた行の集合のJaccard係数（両方にある行の数を、どちらかにある行の数で割った値。空白だけの行は数えません）が#{similarity["threshold"]}以上です。比べるのは、#{similarity["maxBytes"] / 1_048_576} MB以下で、NULを含まず、#{similarity["minLines"]}行以上あるファイルだけです。テンプレートのファイルは、Identity変換の前の内容で比べます。"
    lines << ""
    lines << "扱い（残す、削除する、テンプレートのファイルへまとめる）は、ユーザーが決めます。この分析はどれも変更しません。"
    lines << ""
    lines << "なし" if result["duplicates"].empty?
    result["duplicates"].each do |entry|
      found = []
      found << "同じ名前のテンプレートのファイル#{entry["sameName"].map { |path| "`#{path}`" }.join("、")}" unless entry["sameName"].empty?
      unless entry["similar"].empty?
        found << "中身が似ているテンプレートのファイル#{entry["similar"].map { |item| "`#{item["path"]}`（一致度#{item["similarity"]}）" }.join("、")}"
      end
      lines << "- `#{entry["path"]}`: #{found.join("。")}"
    end
    lines << ""
    lines << "## 3. アプリ独自の改造"
    lines << ""
    lines << "テンプレートのファイルをアプリ側で書き換えたり削除したりしたものです。計画の「衝突する」に加え、基準commitが記録されている取り込み先で、テンプレートが基準のまま変えていないファイルをアプリ側だけで変えた「アプリ側だけの変更」（計画はアプリの版を残します）も含めます。比べたテンプレートの版との違いを要約し、次の3つの候補を示します。どれにするかは、取り込みIssueの中でファイルごとに決めます。"
    lines << ""
    lines << "- #{CHANGE_OPTIONS["keep-app"]}: テンプレートの今回の変更は入りません。"
    lines << "- #{CHANGE_OPTIONS["take-template"]}: アプリの変更はなくなります。"
    lines << "- #{CHANGE_OPTIONS["merge"]}: テンプレートの最新の版に、アプリの変更を手で加えます。"
    lines << ""
    lines << "「テンプレートへ戻す価値」は、違いの中身から機械的に付けた所見の候補です。決めるのはユーザーです。テンプレートへの報告は、ユーザーが頼んだときだけ`report-template-issue`で行います。この分析は報告しません。"
    if result["appChanges"].empty?
      lines << ""
      lines << "なし"
    end
    result["appChanges"].each do |change|
      hint = change["reportHint"]
      lines << ""
      lines << "### `#{change["path"]}`"
      lines << ""
      lines << "- 計画の判定: #{STATUS_LABELS.fetch(change["status"], change["status"])}（#{change["reason"]}）"
      lines << "- 比べた版: #{reference_note(change["reference"])}"
      lines.concat(difference_lines(change["difference"]))
      lines << "- 候補: #{change["options"].map { |option| CHANGE_OPTIONS.fetch(option) }.join("／")}"
      lines << "- テンプレートへ戻す価値（所見の候補）: #{REPORT_HINTS.fetch(hint["kind"])}。#{hint["note"]}"
    end
    lines << ""
    lines << "### そのほかの手で確認するファイル（#{result["otherManual"].length}個）"
    lines << ""
    lines << "1と3に入らない、計画で手で確認するファイルです。"
    lines << ""
    lines << "なし" if result["otherManual"].empty?
    result["otherManual"].each { |file| lines << "- `#{file["path"]}`（#{STATUS_LABELS.fetch(file["status"], file["status"])}）: #{file["reason"]}" }
    lines << ""
    lines << "## 4. 先に必要な整理"
    lines << ""
    if result["prerequisites"].empty?
      lines << "なし"
    else
      lines << "取り込みIssueの最初の手順として、次の順に片付けます。取り込み先のファイルを変えたら、レポートと計画を作り直し、この分析をやり直します。"
      lines << ""
    end
    result["prerequisites"].each do |item|
      lines << "#{item["order"]}. #{PREREQUISITES.fetch(item["kind"])}: #{item["message"]}"
      case item["kind"]
      when "decision-collision"
        item["collisions"].each { |collision| lines << "   - #{collision["id"]}: テンプレート「#{collision["template"]}」／アプリ「#{collision["app"]}」" }
      when "outdated-tools"
        listed = item["update"].map { |path| "更新: `#{path}`" } + item["manual"].map { |path| "手で確認: `#{path}`" }
        listed.first(LISTED_TOOLS).each { |entry| lines << "   - #{entry}" }
        lines << "   - ほか#{listed.length - LISTED_TOOLS}個" if listed.length > LISTED_TOOLS
      end
    end
    lines << ""
    lines.join("\n")
  end

  def commit_note(entry, with_decisions)
    return "テンプレートの履歴に、このファイルを変えたcommitが見つかりません。" if entry["commit"].nil?
    subject = entry["subject"]
    subject = "#{subject[0, SUBJECT_WIDTH]}…" if subject.length > SUBJECT_WIDTH
    numbers = []
    numbers << "Issue ##{entry["issue"]}" if entry["issue"]
    numbers << "PR ##{entry["pullRequest"]}" if entry["pullRequest"]
    details = [numbers.empty? ? "件名にIssueとPRの番号はありません" : numbers.join("、")]
    details << "関係する決定事項: #{entry["decisions"].empty? ? "なし" : entry["decisions"].join("、")}" if with_decisions
    "`#{entry["commit"][0, 7]}`「#{subject}」（#{details.join("。")}）"
  end

  def rename_note(pair)
    new_note = case pair["newAction"]
               when "add" then "新しい方は計画で追加します。"
               when "update" then "新しい方は計画で更新します。"
               when "none" then "新しい方はすでに取り込み先にあり、テンプレートと一致しています。"
               when "manual" then "新しい方は計画で手で確認します。"
               else "新しい方は計画で「#{STATUS_LABELS.fetch(pair["newStatus"], pair["newStatus"])}」です。"
               end
    old_note = case pair["oldAction"]
               when nil then "古い方の削除は計画に含まれないため、取り込みIssueで中身を確かめてから手で削除します。"
               when "delete" then "古い方は計画で削除します。"
               when "manual" then "古い方は計画で手で確認します。"
               else "古い方は計画で「#{pair["oldAction"]}」です。"
               end
    new_note + old_note
  end

  def reference_note(reference)
    return "比べられるテンプレートの版がありません。" if reference.nil?
    commit = "`#{reference["commit"][0, 7]}`"
    note = case reference["kind"]
           when "nearest" then "最も近い版#{commit}（計画の判定では違いは#{reference["changedLines"]}行）"
           when "base" then "基準の版#{commit}"
           else "テンプレートの最新の版#{commit}"
           end
    case reference["transform"]
    when "applied" then "#{note}。取り込み先のIdentityで変換した内容と比べました。"
    when "unavailable" then "#{note}。取り込み先のIdentityがないため、Identity変換の前の内容と比べました。"
    when "failed" then "#{note}。取り込み先のIdentityで変換できなかったため、Identity変換の前の内容と比べました。"
    when "untransformable" then "#{note}。このcommitのtoolでは取り込み先のIdentityへ変換できないため、比べていません。"
    else "#{note}。"
    end
  end

  def difference_lines(difference)
    modes = "テンプレート`#{difference["templateMode"]}`、アプリ`#{difference["appMode"]}`"
    case difference["kind"]
    when "lines"
      mode = difference["templateMode"] == difference["appMode"] ? "" : "file modeも違います（#{modes}）。"
      excerpt = difference["excerpt"]
      counts = "- 違い: アプリ側で#{difference["added"]}行を加え、#{difference["removed"]}行を削っています。#{mode}"
      return ["#{counts}違いは空白だけの行です。"] if excerpt.empty?
      ["#{counts}空白だけの行を除いた最初の#{excerpt.length}行（`-`はテンプレートの版にだけある行、`+`はアプリにだけある行）:",
       "", "  ```diff", *excerpt.map { |line| "  #{line}" }, "  ```", ""]
    when "mode-only" then ["- 違い: 内容は同じで、file modeだけが違います（#{modes}）。"]
    when "binary" then ["- 違い: NULを含むファイルなので、行では比べていません。"]
    when "not-a-file" then ["- 違い: どちらかがsubmoduleなので、行では比べていません。"]
    when "app-missing" then ["- 違い: 取り込み先には、このパスのファイルがありません（アプリ側で削除したか、別の種類のものを置いています）。"]
    else ["- 違い: 比べられるテンプレートの版がないため、要約できません。"]
    end
  end

  # --- output ---------------------------------------------------------------------------------

  STATUS_LABELS = {
    "missing" => "足りない", "safe-update" => "安全に更新できる", "conflict" => "衝突する",
    "app-only-change" => "アプリ側だけの変更", "deleted-in-template" => "テンプレートで削除された",
    "up-to-date" => "一致", "app-owned" => "アプリが持つ", "template-only" => "テンプレート専用"
  }.freeze

  def render_markdown(result)
    files = result["files"]
    pick = ->(*actions) { files.select { |file| actions.include?(file["action"]) } }
    lines = []
    lines << "# テンプレート同期の差分レポートと適用計画"
    lines << ""
    lines << "- テンプレート: `#{result.dig("template", "repository")}` の `#{result.dig("template", "commit")}`"
    lines << "- 取り込み先のHEAD: `#{result.dig("app", "head")}`#{result.dig("app", "uncommittedChanges") ? "（作業中の変更があります。レポートはHEADの内容で作りました）" : ""}"
    base = result["base"]
    lines << case base["status"]
             when "known" then "- 基準commit: `#{base["commit"]}`（#{base["method"]}、#{base["recordedAt"]}）"
             else "- 基準commit: 不明。#{base["reason"]} テンプレートと違うファイルは、テンプレートの全履歴にある同じパスの全版と比べました。どれかの版と1バイトも違わなければ安全な更新、どの版とも一致しなければ手で確認します。"
             end
    if result.key?("inferredBase")
      inferred = result["inferredBase"]
      lines << if inferred
                 "- 推定の基準: `#{inferred["commit"]}`（アプリのファイルのうち#{inferred["matchedFiles"]}個がこのcommitと一致します。参考の情報で、判定には使っていません）"
               else
                 "- 推定の基準: なし（テンプレートのどの版とも一致するファイルがありません）"
               end
    end
    lines << "- Identity変換: #{{"applied" => "取り込み先のIdentityで再適用しました", "identity-unavailable" => "取り込み先のIdentityがないため行っていません", "transform-failed" => "失敗しました"}.fetch(result.dig("app", "transform"))}"
    lines << "- このレポートは取り込み先へ何も書き込んでいません。"
    lines << ""
    lines << "## 件数"
    lines << ""
    result["summary"].each { |status, count| lines << "- #{STATUS_LABELS.fetch(status, status)}: #{count}" }
    lines << ""
    lines << "## 手順"
    lines << ""
    lines << "1. 取り込み先で「テンプレート同期Issue」を作り、作業ブランチで進めます。`main`へ直接適用しません。"
    lines << "2. 下の「必要な承認」を得ます。承認は、このレポートの`plan.json`のdigestに結び付けます（`tools/template-sync.sh approve`）。"
    lines << "3. `tools/template-sync.sh apply`で「適用する変更」と「追記する決定事項」だけを適用します。Identity変換されるファイルは、取り込み先のIdentityで変換した内容を使います。"
    lines << "4. 「上書きしないファイル」はアプリ側の内容を残し、「手で確認するファイル」は同じIssueの中で個別に判断します。"
    lines << "5. 適用toolが基準commitの記録（`#{BASE_RECORD_PATH}`）をこのテンプレートのcommitへ更新します。検証してからmergeします。"
    lines << ""
    lines << "## 適用する変更"
    lines << ""
    applied = pick.call("add", "update", "delete")
    applied.empty? ? lines << "なし" : applied.each { |file| lines << "- #{{"add" => "追加", "update" => "更新", "delete" => "削除"}.fetch(file["action"])}: `#{file["path"]}`#{origin_note(file)}" }
    lines << ""
    lines << "## 追記する決定事項"
    lines << ""
    appended = result.dig("decisions", "append")
    appended.empty? ? lines << "なし" : appended.each { |id| lines << "- `#{DECISIONS_PATH}`の末尾へ#{id}を追記" }
    lines << ""
    lines << "## 上書きしないファイル"
    lines << ""
    kept = pick.call("keep")
    kept.empty? ? lines << "なし" : kept.each { |file| lines << "- `#{file["path"]}`: #{file["reason"]}" }
    lines << ""
    lines << "## 手で確認するファイル"
    lines << ""
    manual = pick.call("manual")
    manual.empty? ? lines << "なし" : manual.each { |file| lines << "- `#{file["path"]}`（#{STATUS_LABELS.fetch(file["status"], file["status"])}）: #{file["reason"]}#{nearest_note(file)}" }
    lines << ""
    # #433: template-only files that the app has; the sync leaves them, and the sync Issue decides whether to keep them.
    leftover = result["files"].select { |file| file["status"] == "template-only" && file["appPresent"] }.sort_by { |file| file["path"] }
    unless leftover.empty?
      lines << "## アプリに残っているテンプレート専用のファイル"
      lines << ""
      lines << "テンプレートだけで使うファイルが、アプリにあります（テンプレートの複製として作ったアプリや、以前の取り込みの残り）。取り込みでは変えません。アプリで使わないものは、同期Issueの中で消すか残すかを決めます。"
      lines << ""
      leftover.each { |file| lines << "- `#{file["path"]}`" }
      lines << ""
    end
    lines << "## 確認事項"
    lines << ""
    decisions = result["decisions"]
    lines << "- 決定事項: テンプレートの新しいD-###は#{decisions["templateNew"].empty? ? "ありません" : decisions["templateNew"].join("、")}。#{decisions["note"]}"
    decisions["collisions"].each { |item| lines << "  - #{item["id"]}: テンプレート「#{item["template"]}」／アプリ「#{item["app"]}」" }
    problems = result.dig("simulators", "problems")
    lines << "- 専用Simulator: #{problems.empty? ? "取り込み先の表示名を前置した宣言です。" : problems.join(" ")}"
    issues = result.dig("app", "identityFormatIssues")
    lines << "- `#{APP_IDENTITY_PATH}`: #{issues.empty? ? "形式の違いはありません。" : issues.join(" ")}"
    lines << ""
    lines << "## 必要な承認"
    lines << ""
    result["approvals"].each { |item| lines << "- #{item}" }
    lines << ""
    lines.join("\n")
  end

  # Only files judged without a known base (D-078) carry these, so a D-074 plan renders as before.
  def origin_note(file)
    file["provenance"] ? "（テンプレートの`#{file["provenance"]["commit"][0, 7]}`の版から）" : ""
  end

  def nearest_note(file)
    return "" unless file.key?("nearest")
    nearest = file["nearest"]
    return " 比べられるテンプレートの版がありません。" if nearest.nil?
    commit = nearest["commit"][0, 7]
    return " 最も近い版は`#{commit}`で、内容は同じですがfile modeが違います。" if nearest["changedLines"].zero?
    " 最も近い版は`#{commit}`で、違いは#{nearest["changedLines"]}行です。"
  end

  def canonical_json(value)
    JSON.pretty_generate(sort_json(value)) + "\n"
  end

  def sort_json(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, sort_json(value[key])] }
    when Array then value.map { |item| sort_json(item) }
    else value
    end
  end

  def exact_keys!(value, keys, label)
    missing = keys - value.keys
    unknown = value.keys - keys
    return if missing.empty? && unknown.empty?
    fail!("#{label} keys differ (missing: #{missing.join(", ")}; unknown: #{unknown.join(", ")})")
  end

  def fail!(message)
    raise Failure, message
  end
end

require_relative "template-sync-apply"

TemplateSync.run(ARGV) if $PROGRAM_NAME == __FILE__
