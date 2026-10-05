#!/usr/bin/env ruby
# frozen_string_literal: true

# Template sync (D-074), first half: classify every template file, then compare a derived or
# non-template repository with the template and write a report and an apply plan. Nothing here
# writes to the target repository; the apply step and its approval belong to a later tool.

require "digest"
require "fileutils"
require "json"
require "open3"
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
  SHA_PATTERN = /\A[0-9a-f]{40}\z/
  DECISION_HEADING = /^## (D-\d{3,}): (.+)$/

  class Failure < StandardError; end

  module_function

  def run(argv)
    command = argv.shift or fail!("usage: template-sync.sh check|report [options]")
    options = parse_options(argv)
    case command
    when "check" then puts JSON.generate(check(options))
    when "report" then puts JSON.generate(report(options))
    else fail!("unknown command: #{command}")
    end
  rescue Failure, JSON::ParserError, ArgumentError => error
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
    stdout, stderr, status = Open3.capture3({"GIT_OPTIONAL_LOCKS" => "0"}, "git", "-C", root, *args, stdin_data: input, binmode: true)
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

    work_option = options["--work-dir"]
    if work_option
      FileUtils.mkdir_p(work_option)
      fail!("--work-dir must not be inside the app repository") if inside?(app_root, File.realpath(work_option))
    end
    work = work_option ? File.realpath(work_option) : Dir.mktmpdir("template-sync")
    begin
      result = build_report(root, commit, ownership, app_root, work, now)
    ensure
      FileUtils.rm_rf(work) unless work_option
    end
    FileUtils.mkdir(output)
    json = canonical_json(result)
    File.write(File.join(output, "plan.json"), json)
    File.write(File.join(output, "plan.md"), render_markdown(result))
    {
      "status" => "reported", "output" => output, "planDigest" => "sha256:#{Digest::SHA256.hexdigest(json)}",
      "base" => result["base"]["status"], "summary" => result["summary"]
    }
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
    real = File.join(File.realpath(parent), File.basename(path))
    fail!("--output-dir must not be inside the app repository; the report never writes there") if inside?(app_root, real)
    real
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
    base_paths = base_raw ? tracked_paths(root, base["commit"]) : []
    missing_base_paths = base_paths - paths
    app.merge!(read_app_files(app_root, app_head, missing_base_paths)) unless missing_base_paths.empty?
    files = (paths | base_paths).sort.map do |path|
      entry = classify(ownership, path)
      fail!("unclassified template file: #{path}") unless entry
      compare_file(path, entry, new_raw: new_raw, new_xf: new_xf, base_raw: base_raw, base_xf: base_xf,
                   app_files: app, base_known: base["status"] == "known", tokens: tokens,
                   identity: identity, transform_status: transform_status)
    end

    summary = Hash.new(0)
    files.each { |file| summary[file["status"]] += 1 }
    {
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
    wanted = paths.uniq.select { |path| entries.key?(path) && entries[path][:type] == "blob" }
    return {} if wanted.empty?
    output = git(app_root, "cat-file", "--batch", input: wanted.map { |path| entries[path][:sha] }.join("\n") + "\n")
    contents = {}
    offset = 0
    wanted.each do |path|
      header_end = output.index("\n", offset)
      sha, type, size = output[offset...header_end].split(" ")
      fail!("could not read #{path} from the target") unless type == "blob" && sha == entries[path][:sha]
      body = output.byteslice(header_end + 1, size.to_i)
      offset = header_end + 1 + size.to_i + 1
      contents[path] = entries[path][:mode] == "120000" ? "symlink:#{body}" : body
    end
    contents
  end

  # Re-apply Identity bootstrap with the app's identity, using that template commit's own tool.
  def transform_tree(raw, commit, identity, work)
    key = Digest::SHA256.hexdigest(JSON.generate([commit, identity.values_at("displayName", "moduleName", "appSlug", "bundleId")]))[0, 16]
    destination = File.join(work, "transformed-#{commit}-#{key}")
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
    text = app[APP_IDENTITY_PATH]
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
    text = app[BASE_RECORD_PATH]
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
    File.file?(full) && !File.symlink?(full) ? File.binread(full) : (File.symlink?(full) ? "symlink:#{File.readlink(full)}" : nil)
  end

  def digest(bytes)
    bytes && "sha256:#{Digest::SHA256.hexdigest(bytes)}"
  end

  def compare_file(path, entry, new_raw:, new_xf:, base_raw:, base_xf:, app_files:, base_known:, tokens:, identity:, transform_status:)
    record = {"path" => path, "category" => entry[:category]}
    record["rule"] = entry[:rule] if entry[:rule]
    if entry[:category] == "app"
      return record.merge("status" => "app-owned", "action" => "skip", "reason" => "アプリが持つファイルなので取り込みません。")
    end
    if entry[:category] == "template-only"
      return record.merge("status" => "template-only", "action" => "skip", "reason" => "テンプレート専用なのでアプリへ持ち込みません。")
    end
    transformed = entry[:transform]
    if transformed && transform_status != "applied"
      reason = transform_status == "identity-unavailable" ? "アプリのIdentityが読めないため、Identity変換できません。" : "Identity変換に失敗しました。"
      current = app_files[path]
      return record.merge("status" => current.nil? ? "missing" : "conflict", "action" => "manual", "reason" => reason,
                          "appDigest" => digest(current))
    end
    new = read(transformed ? new_xf : new_raw, path)
    base = base_known ? read(transformed ? base_xf : base_raw, path) : nil
    app = app_files[path]
    record.merge!("newDigest" => digest(new), "baseDigest" => digest(base), "appDigest" => digest(app))

    status, action, reason =
      if new.nil?
        if app.nil? then ["up-to-date", "none", "テンプレートでもアプリでも削除済みです。"]
        elsif app == base then ["deleted-in-template", "delete", "テンプレートで削除され、アプリ側は基準のままです。"]
        else ["deleted-in-template", "manual", "テンプレートで削除されましたが、アプリ側に変更があります。"]
        end
      elsif app.nil? then ["missing", "add", "アプリにありません。"]
      elsif app == new then ["up-to-date", "none", "テンプレートと一致しています。"]
      elsif !base_known then ["conflict", "manual", "基準commitが不明なため、アプリ側の変更かテンプレート側の更新かを判定できません。"]
      elsif base.nil? then ["conflict", "manual", "テンプレートが新しく追加したパスに、アプリが別の内容を置いています。"]
      elsif app == base then ["safe-update", "update", "アプリ側は基準のままで、テンプレート側だけが変わりました。"]
      elsif new == base then ["app-only-change", "keep", "アプリ側だけの変更なので残します。"]
      else ["conflict", "manual", "テンプレート側とアプリ側の両方が変わっています。"]
      end

    if transformed && new && %w[add update].include?(action)
      before = (app || base || "").scan(Regexp.union(tokens)).length
      if new.scan(Regexp.union(tokens)).length > before
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

  def decision_entries(text)
    return {} if text.nil?
    text.dup.force_encoding(Encoding::UTF_8).scan(DECISION_HEADING).to_h { |id, title| [id, title.strip] }
  end

  def decision_report(new_raw, base_raw, app_files)
    template = decision_entries(read(new_raw, DECISIONS_PATH))
    base = base_raw ? decision_entries(read(base_raw, DECISIONS_PATH)) : nil
    app = decision_entries(app_files[DECISIONS_PATH])
    added = base ? template.keys - base.keys : template.keys - app.keys
    collisions = template.keys.select { |id| app.key?(id) && app[id] != template[id] }.sort.map do |id|
      {"id" => id, "template" => template[id], "app" => app[id]}
    end
    {
      "templateNew" => added.sort,
      "collisions" => collisions,
      "appendable" => collisions.empty?,
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
    app_names = names.call(app_files[SIMULATORS_PATH])
    planned = names.call(read(new_xf, SIMULATORS_PATH))
    prefix = identity && "#{identity["displayName"]} "
    problems = []
    problems << "アプリの#{SIMULATORS_PATH}がありません。" if app_names.empty?
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
             else "- 基準commit: 不明。#{base["reason"]} ファイルごとのhashだけで比べたため、違いはすべて手で確認します。"
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
    lines << "2. 下の「必要な承認」を得ます。承認は、このレポートの`plan.json`のdigestに結び付けます。"
    lines << "3. 「適用する変更」だけを適用します。Identity変換されるファイルは、取り込み先のIdentityで変換した内容を使います。"
    lines << "4. 「上書きしないファイル」はアプリ側の内容を残し、「手で確認するファイル」は個別に判断します。"
    lines << "5. 適用後に検証し、基準commitの記録（`#{BASE_RECORD_PATH}`）をこのテンプレートのcommitへ更新します。"
    lines << ""
    lines << "## 適用する変更"
    lines << ""
    applied = pick.call("add", "update", "delete")
    applied.empty? ? lines << "なし" : applied.each { |file| lines << "- #{{"add" => "追加", "update" => "更新", "delete" => "削除"}.fetch(file["action"])}: `#{file["path"]}`" }
    lines << ""
    lines << "## 上書きしないファイル"
    lines << ""
    kept = pick.call("keep")
    kept.empty? ? lines << "なし" : kept.each { |file| lines << "- `#{file["path"]}`: #{file["reason"]}" }
    lines << ""
    lines << "## 手で確認するファイル"
    lines << ""
    manual = pick.call("manual")
    manual.empty? ? lines << "なし" : manual.each { |file| lines << "- `#{file["path"]}`（#{STATUS_LABELS.fetch(file["status"], file["status"])}）: #{file["reason"]}" }
    lines << ""
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

TemplateSync.run(ARGV) if $PROGRAM_NAME == __FILE__
