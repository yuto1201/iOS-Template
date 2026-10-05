# frozen_string_literal: true

# Template sync (D-074), second half: record an approval bound to one apply plan's digest, let Codex
# review a plan through the fixed read-only launcher when the user chose that route, and apply an
# approved plan to a clean working branch of the target. Every check runs before the first write.

module TemplateSync
  APPROVAL_SCOPE = "template-sync-plan"
  APPROVERS = %w[user codex].freeze
  VERDICTS = %w[approved changes-requested].freeze
  CODEX_LAUNCHER = "tools/template-sync-codex-review.sh"
  CODEX_MODEL = "gpt-6-sol"
  REFERENCE_PATTERN = %r{\Ahttps://github\.com/[\w.-]+/[\w.-]+/(?:issues|pull)/\d+#issuecomment-\d+\z}
  TIMESTAMP_PATTERN = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/
  APPROVAL_KEYS = %w[approvedAt approver decision planDigest reference schemaVersion scope].freeze
  REVIEW_KEYS = %w[findings launcherDigest model planDigest reviewedAt reviewer schemaVersion scope summary userRequest verdict].freeze
  PROTECTED_BRANCHES = %w[main master].freeze

  module_function

  # --- approval -------------------------------------------------------------------------------

  def approve(options)
    allow_options!(options, ["--plan", "--approver", "--output"], ["--reference", "--review", "--now"])
    plan_path, _plan, plan_digest = read_plan(options.fetch("--plan"))
    output = new_file!(options.fetch("--output"), "--output")
    now = timestamp!(options)
    record = {"schemaVersion" => 1, "scope" => APPROVAL_SCOPE, "planDigest" => plan_digest, "decision" => "approved", "approvedAt" => now}
    case options.fetch("--approver")
    when "user"
      fail!("--review is only for the codex approver") if options.key?("--review")
      reference = options["--reference"] or fail!("a user approval needs --reference with the Issue comment URL of the approval")
      fail!("--reference must be a GitHub Issue or pull request comment URL") unless reference.match?(REFERENCE_PATTERN)
      record.merge!("approver" => "user", "reference" => reference)
    when "codex"
      fail!("a Codex approval takes the user's request from its review; do not pass --reference") if options.key?("--reference")
      review_path = options["--review"] or fail!("a Codex approval needs --review with the Codex review of this plan")
      review = JSON.parse(File.binread(review_path))
      validate_codex_review!(review, plan_digest)
      fail!("Codex asked for changes, so the plan is not approved") unless review["verdict"] == "approved"
      record.merge!("approver" => "codex", "reference" => review["userRequest"], "codexReview" => review)
    else
      fail!("--approver must be user or codex")
    end
    File.write(output, canonical_json(record))
    {"status" => "approved", "approver" => record["approver"], "plan" => plan_path, "planDigest" => plan_digest, "output" => output}
  end

  def validate_approval!(approval, plan_digest)
    fail!("approval must be a JSON object") unless approval.is_a?(Hash)
    keys = APPROVAL_KEYS + (approval["approver"] == "codex" ? ["codexReview"] : [])
    exact_keys!(approval, keys, "approval")
    fail!("approval schemaVersion must be 1") unless approval["schemaVersion"] == 1
    fail!("approval scope must be #{APPROVAL_SCOPE}") unless approval["scope"] == APPROVAL_SCOPE
    fail!("approval decision must be approved") unless approval["decision"] == "approved"
    fail!("approval approver must be user or codex") unless APPROVERS.include?(approval["approver"])
    fail!("approval approvedAt must be a UTC timestamp") unless approval["approvedAt"].to_s.match?(TIMESTAMP_PATTERN)
    fail!("approval reference must be a GitHub Issue or pull request comment URL") unless approval["reference"].to_s.match?(REFERENCE_PATTERN)
    fail!("the plan changed after it was approved: approval is for #{approval["planDigest"]}, the plan is #{plan_digest}") unless approval["planDigest"] == plan_digest
    return unless approval["approver"] == "codex"
    review = approval["codexReview"]
    validate_codex_review!(review, plan_digest)
    fail!("the Codex review did not approve the plan") unless review["verdict"] == "approved"
    fail!("the Codex review answers a different user request") unless review["userRequest"] == approval["reference"]
  end

  # --- Codex review ---------------------------------------------------------------------------

  def codex_review(options)
    allow_options!(options, ["--plan", "--user-request", "--output"], ["--now"])
    plan_path, _plan, plan_digest = read_plan(options.fetch("--plan"))
    user_request = options.fetch("--user-request")
    fail!("--user-request must be the GitHub comment URL where the user chose the Codex route") unless user_request.match?(REFERENCE_PATTERN)
    output = new_file!(options.fetch("--output"), "--output")
    now = timestamp!(options)
    launcher = File.join(template_root, CODEX_LAUNCHER)
    launcher_digest = "sha256:#{Digest::SHA256.file(launcher).hexdigest}"

    result = Dir.mktmpdir("template-sync-codex") do |work|
      # Codex may read only this copy of the two plan files, nothing else on the Mac.
      plan_dir = File.join(File.realpath(work), "plan")
      Dir.mkdir(plan_dir, 0o700)
      FileUtils.cp(plan_path, File.join(plan_dir, "plan.json"))
      File.write(File.join(plan_dir, "plan.md"), render_markdown(JSON.parse(File.binread(File.join(plan_dir, "plan.json")))))
      fail!("the plan changed while it was copied for review") unless "sha256:#{Digest::SHA256.file(File.join(plan_dir, "plan.json")).hexdigest}" == plan_digest
      answer = File.join(File.realpath(work), "answer.json")
      _out, err, status = Open3.capture3("/bin/bash", launcher, "--plan-dir", plan_dir, "--output", answer)
      fail!("the Codex review did not finish: #{err.strip.lines.last(3).join.strip}") unless status.success? && File.file?(answer)
      JSON.parse(File.read(answer))
    end
    fail!("the Codex answer must be an object with verdict, summary and findings") unless result.is_a?(Hash)
    exact_keys!(result, %w[findings summary verdict], "Codex answer")
    review = {
      "schemaVersion" => 1, "scope" => APPROVAL_SCOPE, "reviewer" => "codex", "model" => CODEX_MODEL,
      "planDigest" => plan_digest, "userRequest" => user_request, "launcherDigest" => launcher_digest,
      "verdict" => result["verdict"], "summary" => result["summary"], "findings" => result["findings"], "reviewedAt" => now
    }
    validate_codex_review!(review, plan_digest)
    File.write(output, canonical_json(review))
    {"status" => "reviewed", "verdict" => review["verdict"], "findings" => review["findings"].length, "planDigest" => plan_digest, "output" => output}
  end

  def validate_codex_review!(review, plan_digest)
    fail!("the Codex review must be a JSON object") unless review.is_a?(Hash)
    exact_keys!(review, REVIEW_KEYS, "Codex review")
    fail!("the Codex review schemaVersion must be 1") unless review["schemaVersion"] == 1
    fail!("the Codex review is not a template sync plan review") unless review["scope"] == APPROVAL_SCOPE && review["reviewer"] == "codex" && review["model"] == CODEX_MODEL
    fail!("the Codex review is for another plan") unless review["planDigest"] == plan_digest
    fail!("the Codex review has no user request for the Codex route") unless review["userRequest"].to_s.match?(REFERENCE_PATTERN)
    current = "sha256:#{Digest::SHA256.file(File.join(template_root, CODEX_LAUNCHER)).hexdigest}"
    fail!("the Codex review did not come from this template's fixed launcher") unless review["launcherDigest"] == current
    fail!("the Codex review verdict must be approved or changes-requested") unless VERDICTS.include?(review["verdict"])
    fail!("the Codex review summary must be a non-empty string") unless review["summary"].is_a?(String) && !review["summary"].strip.empty?
    fail!("the Codex review reviewedAt must be a UTC timestamp") unless review["reviewedAt"].to_s.match?(TIMESTAMP_PATTERN)
    findings = review["findings"]
    valid = findings.is_a?(Array) && findings.all? do |finding|
      finding.is_a?(Hash) && finding.keys.sort == %w[path problem] && finding.values.all? { |value| value.is_a?(String) && !value.strip.empty? }
    end
    fail!("each Codex finding must have a path and a problem") unless valid
    fail!("an approved Codex review must have no findings") if review["verdict"] == "approved" && !findings.empty?
    fail!("a changes-requested Codex review must name at least one finding") if review["verdict"] == "changes-requested" && findings.empty?
  end

  # --- apply ----------------------------------------------------------------------------------

  def apply(options)
    allow_options!(options, ["--plan", "--approval", "--app-root"], ["--work-dir", "--now"])
    plan_path, plan, plan_digest = read_plan(options.fetch("--plan"))
    approval = JSON.parse(File.binread(options.fetch("--approval")))
    validate_approval!(approval, plan_digest)
    app_root = app_root!(options.fetch("--app-root"))
    [plan_path, File.realpath(options.fetch("--approval"))].each do |path|
      fail!("the plan and the approval must be outside the app repository") if inside?(app_root, path)
    end
    now = timestamp!(options)

    root = template_root
    commit = commit!(root, plan.dig("template", "commit").to_s)
    fail!("the plan names another template commit") unless commit == plan.dig("template", "commit")
    ownership = load_ownership(blob(root, commit, OWNERSHIP_PATH))
    fail!("the plan names another template repository") unless plan.dig("template", "repository") == ownership[:repository]

    head = git(app_root, "rev-parse", "--verify", "HEAD^{commit}").strip
    fail!("the target moved since the plan was made: HEAD is #{head}, the plan is for #{plan.dig("app", "head")}") unless head == plan.dig("app", "head")
    branch = git_optional(app_root, "symbolic-ref", "--quiet", "--short", "HEAD")
    fail!("the target is not on a branch; apply on a working branch of a template sync Issue") if branch.nil?
    default = git_optional(app_root, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")&.sub(%r{\Aorigin/}, "")
    fail!("the target is on #{branch}; apply only on a working branch, never on main") if PROTECTED_BRANCHES.include?(branch) || branch == default
    pending = git(app_root, "status", "--porcelain", "--untracked-files=all").force_encoding(Encoding::UTF_8)
    fail!("the target has uncommitted changes; commit or remove them first:\n#{pending.lines.first(10).join}") unless pending.empty?

    work_option = options["--work-dir"]
    if work_option
      fail!("--work-dir must not be inside the app repository") if inside?(app_root, resolved_location(work_option))
      FileUtils.mkdir_p(work_option)
    end
    work = work_option ? File.realpath(work_option) : Dir.mktmpdir("template-sync")
    begin
      # The approved plan must be exactly what the template and the target produce now.
      fresh = canonical_json(build_report(root, commit, ownership, app_root, work, plan["generatedAt"]))
      fail!("the plan no longer matches the template and the target; make a new report and get it approved") unless fresh.b == File.binread(plan_path)
      unless plan.dig("app", "transform") == "applied"
        fail!("the target has no usable Identity in #{APP_IDENTITY_PATH}, so Identity files cannot be transformed. Nothing was written.")
      end
      raw = File.join(work, "template-#{commit}")
      transformed = transform_tree(raw, commit, plan.dig("app", "identity"), work)
      tokens = template_tokens(raw)
      changes = prepare_changes(app_root, plan, ownership, raw, transformed, tokens)
      result = write_changes(app_root, plan, changes, tokens, now)
    ensure
      FileUtils.rm_rf(work) unless work_option
    end
    result.merge("plan" => plan_path, "planDigest" => plan_digest, "approver" => approval["approver"])
  end

  def git_optional(root, *args)
    stdout, _stderr, status = Open3.capture3({"GIT_OPTIONAL_LOCKS" => "0"}, "git", "-c", "core.fsmonitor=false", "-C", root, *args)
    status.success? ? stdout.strip : nil
  end

  # Everything that will be written, checked against the plan and the working tree first.
  def prepare_changes(app_root, plan, ownership, raw, transformed, tokens)
    decisions = plan.fetch("decisions")
    unless decisions["appendable"]
      ids = decisions["collisions"].map { |item| item["id"] }.join("、")
      fail!("specs/decisions.md has decision numbers that collide with the template (#{ids}). Nothing was written. " \
            "Move the app's own decisions to A-### in specs/app-decisions.md, then make a new report.")
    end
    problems = plan.dig("simulators", "problems")
    fail!("the dedicated Simulator declaration needs attention first: #{problems.join(" ")} Nothing was written.") unless problems.empty?

    files = plan.fetch("files").select { |file| %w[add update delete].include?(file["action"]) }
    changes = files.map do |file|
      path = file.fetch("path")
      entry = classify(ownership, path)
      fail!("#{path} is not a template or identity file, so it is never applied") unless entry && %w[template identity].include?(entry[:category]) && file["category"] == entry[:category]
      safe_parents!(app_root, path)
      current = read_working(app_root, path)
      if file["action"] == "add"
        fail!("#{path} already exists in the working tree (an ignored or untracked file), so it is not overwritten") unless current.nil?
      else
        fail!("#{path} differs from the plan in the working tree") unless current && [current.mode, digest(current)] == [file["appMode"], file["appDigest"]]
      end
      next {path: path, action: "delete"} if file["action"] == "delete"
      source = read(entry[:transform] ? transformed : raw, path)
      fail!("#{path} is missing from the template commit") if source.nil?
      fail!("#{path} differs from the planned template content") unless [source.mode, digest(source)] == [file["newMode"], file["newDigest"]]
      allowed = entry[:transform] ? residual_count(current&.bytes, tokens) : nil
      {path: path, action: file["action"], entry: source, transform: entry[:transform], allowed: allowed}
    end
    changes + decision_changes(app_root, plan, raw)
  end

  def decision_changes(app_root, plan, raw)
    ids = plan.dig("decisions", "append")
    return [] if ids.empty?
    current = read_working(app_root, DECISIONS_PATH)
    fail!("#{DECISIONS_PATH} is not a regular file in the target") unless current&.mode == "100644"
    sections = decision_sections(read(raw, DECISIONS_PATH).bytes)
    text = current.bytes.dup.force_encoding(Encoding::UTF_8)
    present = decision_entries(text).keys
    fail!("#{DECISIONS_PATH} already has #{(ids & present).join("、")}") unless (ids & present).empty?
    appended = ids.map { |id| sections.fetch(id) { fail!("#{id} is missing from the template decisions") } }
    text = text.end_with?("\n") ? text : "#{text}\n"
    bytes = appended.reduce(text) { |all, section| "#{all}\n#{section}" }
    [{path: DECISIONS_PATH, action: "append", entry: Entry.new("100644", bytes.b), ids: ids, before: current.bytes}]
  end

  # Each "## D-###:" section, from its heading to the next "## " heading, without trailing blank lines.
  def decision_sections(bytes)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    sections = {}
    current = nil
    text.each_line do |line|
      if line.start_with?("## ")
        id = line[/\A## (D-\d{3,}):/, 1]
        current = id && (sections[id] = +"")
      end
      current << line if current
    end
    sections.transform_values { |section| "#{section.sub(/\s+\z/, "")}\n" }
  end

  def write_changes(app_root, plan, changes, tokens, now)
    written = []
    deleted = []
    changes.each do |change|
      path = File.join(app_root, change[:path])
      case change[:action]
      when "delete"
        File.delete(path)
        remove_empty_parents(app_root, File.dirname(path))
        deleted << change[:path]
      else
        write_entry(path, change[:entry])
        written << change[:path]
      end
    end

    # After writing, the target must hold exactly the approved bytes, without new source names.
    changes.each do |change|
      next if change[:action] == "delete"
      actual = read_working(app_root, change[:path])
      fail!("#{change[:path]} was not written as planned; review the working tree with git status") unless actual == change[:entry]
      if change[:transform] && residual_count(actual.bytes, tokens) > change[:allowed]
        fail!("#{change[:path]} still has the template's names after the Identity transform; review the working tree with git status")
      end
      if change[:action] == "append" && !actual.bytes.start_with?(change[:before])
        fail!("#{DECISIONS_PATH} lost earlier decisions; review the working tree with git status")
      end
    end
    deleted.each { |path| fail!("#{path} was not deleted") if File.exist?(File.join(app_root, path)) || File.symlink?(File.join(app_root, path)) }
    simulators = check_simulators!(app_root, plan)
    base = write_base_record(app_root, plan, now)
    {
      "status" => "applied", "written" => written.sort, "deleted" => deleted.sort,
      "decisionsAppended" => changes.select { |change| change[:action] == "append" }.flat_map { |change| change[:ids] },
      "manual" => plan["files"].select { |file| file["action"] == "manual" }.map { |file| file["path"] },
      "simulators" => simulators, "baseRecord" => base
    }
  end

  def check_simulators!(app_root, plan)
    entry = read_working(app_root, SIMULATORS_PATH)
    fail!("#{SIMULATORS_PATH} is missing after the apply") if entry.nil?
    names = JSON.parse(entry.bytes.dup.force_encoding(Encoding::UTF_8)).fetch("devices").map { |device| device["name"] }
    prefix = "#{plan.dig("app", "identity", "displayName")} "
    unless names.length == 2 && names.all? { |name| name.start_with?(prefix) } && names.none? { |name| name.start_with?(TEMPLATE_DEVICE_PREFIX) }
      fail!("#{SIMULATORS_PATH} no longer declares the app's two dedicated Simulators")
    end
    names
  end

  def write_base_record(app_root, plan, now)
    base = plan.fetch("base")
    record = {
      "baseCommit" => plan.dig("template", "commit"), "method" => base["status"] == "known" ? base["method"] : "adopted",
      "recordedAt" => now, "schemaVersion" => 1, "templateRepository" => plan.dig("template", "repository")
    }
    path = File.join(app_root, BASE_RECORD_PATH)
    safe_parents!(app_root, BASE_RECORD_PATH)
    FileUtils.mkdir_p(File.dirname(path))
    write_entry(path, Entry.new("100644", JSON.pretty_generate(record) + "\n"))
    record
  end

  # --- helpers --------------------------------------------------------------------------------

  def read_plan(value)
    path = File.realpath(value)
    fail!("--plan must be a plan.json file") unless File.basename(path) == "plan.json" && File.file?(path)
    fail!("plan.md must sit next to plan.json") unless File.file?(File.join(File.dirname(path), "plan.md"))
    bytes = File.binread(path)
    plan = JSON.parse(bytes)
    fail!("the plan must be a template sync plan (schemaVersion 1)") unless plan.is_a?(Hash) && plan["schemaVersion"] == 1 && plan["files"].is_a?(Array)
    # plan.md is what the user and Codex read, so it must be exactly the rendering of plan.json.
    fail!("plan.md does not match plan.json; make a new report") unless render_markdown(plan).b == File.binread(File.join(File.dirname(path), "plan.md"))
    [path, plan, "sha256:#{Digest::SHA256.hexdigest(bytes)}"]
  rescue Errno::ENOENT
    fail!("--plan does not exist")
  end

  def new_file!(value, label)
    path = File.expand_path(value)
    fail!("#{label} already exists") if File.exist?(path) || File.symlink?(path)
    fail!("#{label} parent does not exist") unless File.directory?(File.dirname(path))
    path
  end

  def timestamp!(options)
    now = options.fetch("--now", Time.now.utc.iso8601)
    fail!("--now must be a UTC timestamp") unless now.match?(TIMESTAMP_PATTERN)
    now
  end

  # The template's own names, which the Identity transform replaces (the same tokens as the report).
  def template_tokens(raw)
    source = JSON.parse(File.read(File.join(raw, IDENTITY_MANIFEST_PATH))).fetch("source")
    [source.fetch("module"), source.fetch("bundleId")].uniq
  end

  def residual_count(bytes, tokens)
    (bytes || "").scan(Regexp.union(tokens)).length
  end

  # Every existing parent must be a real folder, so a write cannot leave the repository through a link.
  def safe_parents!(app_root, path)
    parts = path.split("/")
    fail!("unsafe path in the plan: #{path}") if parts.empty? || parts.any? { |part| part.empty? || part == "." || part == ".." || part == ".git" }
    (1...parts.length).each do |count|
      parent = File.join(app_root, *parts.first(count))
      next unless File.exist?(parent) || File.symlink?(parent)
      fail!("#{parts.first(count).join("/")} is not a folder in the target") if File.symlink?(parent) || !File.directory?(parent)
    end
  end

  def read_working(app_root, path)
    full = File.join(app_root, path)
    return Entry.new("120000", File.readlink(full)) if File.symlink?(full)
    return nil unless File.exist?(full)
    fail!("#{path} is not a file in the target") unless File.file?(full)
    Entry.new(File.executable?(full) ? "100755" : "100644", File.binread(full))
  end

  def write_entry(path, entry)
    FileUtils.mkdir_p(File.dirname(path))
    staging = File.join(File.dirname(path), ".#{File.basename(path)}.template-sync-#{Process.pid}")
    FileUtils.rm_f(staging)
    if entry.mode == "120000"
      File.symlink(entry.bytes, staging)
    else
      File.binwrite(staging, entry.bytes)
      File.chmod(entry.mode == "100755" ? 0o755 : 0o644, staging)
    end
    # rename replaces the entry itself, whether it was a file or a symlink.
    File.rename(staging, path)
  end

  def remove_empty_parents(app_root, directory)
    while directory != app_root && directory.start_with?(app_root + File::SEPARATOR) && Dir.empty?(directory)
      Dir.rmdir(directory)
      directory = File.dirname(directory)
    end
  end
end
