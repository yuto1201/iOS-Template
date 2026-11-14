# encoding: UTF-8
# frozen_string_literal: true

# D-105 (#534): takes in a delivery from the App Store creative workspace. It checks delivery.json
# (schema 1) and every delivered file, binds each composed face to the app's own raw capture manifest,
# to the render record that drew it and to adopted materials only, checks that the user's choice is
# recorded in the workspace commit with the delivered SHA-256, runs the store-copy check on delivered
# copy, and then writes the folder that tools/build-appstore-screenshot-set.sh --composition reads:
# `<locale>/<family>/NN-<state>.png`, byte copies of the render records and provenance.json under
# `records/`, composition.json (the keys of D-101) and intake.json. It writes nothing else, never
# writes into `App Store/` or the app's source, and opens no network. Any failed check stops it before
# composition.json is written.
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "tmpdir"

module AppStoreIntake
  class Refused < StandardError; end

  DIGEST = /\Asha256:[0-9a-f]{64}\z/
  SHA = /\A[0-9a-f]{40}\z/
  BATCH = /\A[A-Za-z0-9][A-Za-z0-9-]{0,63}\z/
  CONCEPT = /\A[A-Za-z0-9][A-Za-z0-9-]{0,31}\z/
  APPROVAL = %r{\A(?:https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/(?:issues|pull)/[0-9]+(?:#issuecomment-[0-9]+)?|(?:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?#[0-9]+)\z}
  RELATIVE = %r{\A(?!/)(?!.*(?:\A|/)\.\.?(?:/|\z))[A-Za-z0-9._@+/ -]+\z}
  FACE_PATH = %r{\Ascreenshots/faces/(en-US|ja)/([a-z0-9.-]+)/([0-9]{2})-([a-z0-9-]+)\.png\z}
  DEVICES = {"iphone-6.3" => [1206, 2622], "ipad-13" => [2064, 2752]}.freeze
  LOCALES = %w[en-US ja].freeze
  KINDS = %w[screenshots copy].freeze
  ROLES = %w[face declaration render-record provenance brand copy decision-summary].freeze

  DELIVERY_KEYS = %w[schemaVersion workspace app kinds inputs renderer adoption faces files checks].freeze
  WORKSPACE_KEYS = %w[repository commit caseId].freeze
  INPUT_KEYS = %w[captureBatch rawManifestSha256 sourceSha buildDigest runtime requirementsSha256 brandSha256 appCommit].freeze
  RENDERER_KEYS = %w[path sha256].freeze
  ADOPTION_KEYS = %w[decision at where approvalReference choice sheetKind sheetSha256 record].freeze
  RECORD_KEYS = %w[path sha256].freeze
  FACE_KEYS = %w[locale family order state rawDigest sha256 renderRecord declaration path].freeze
  FILE_KEYS = %w[path sha256 bytes role].freeze
  RAW_KEYS = %w[schemaVersion sourceSha buildDigest runtime requirementsDigest cases].freeze
  RAW_CASE_KEYS = %w[locale family state order path sourceSha buildDigest runtime deviceType width height digest].freeze
  MAX_FILE_BYTES = 64 * 1024 * 1024

  module_function

  def refuse!(message)
    raise Refused, message
  end

  def sha256(path)
    "sha256:#{Digest::SHA256.file(path).hexdigest}"
  end

  def exact!(value, keys, label)
    refuse!("#{label} must be an object with exactly #{keys.join(', ')}") unless value.is_a?(Hash) && value.keys.sort == keys.sort
    value
  end

  def regular!(path, label)
    stat = File.lstat(path)
    refuse!("#{label} must be a regular file, not a link") unless stat.file? && !stat.symlink?
    refuse!("#{label} is too large") if stat.size > MAX_FILE_BYTES
    path
  rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES
    refuse!("#{label} is missing")
  end

  def folder!(path, label)
    stat = File.lstat(path)
    refuse!("#{label} must be a folder, not a link") unless stat.directory? && !stat.symlink?
    File.realpath(path)
  rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES
    refuse!("#{label} is missing")
  end

  def json!(path, label)
    JSON.parse(File.binread(regular!(path, label)))
  rescue JSON::ParserError
    refuse!("#{label} is not JSON")
  end

  # Width, height and whether the PNG has an alpha channel, from its header.
  def png_info(path)
    bytes = File.binread(path, 33)
    refuse!("#{path} is not a PNG") unless bytes && bytes.bytesize == 33 && bytes.byteslice(0, 8) == "\x89PNG\r\n\x1A\n".b && bytes.byteslice(12, 4) == "IHDR"
    width, height = bytes.byteslice(16, 8).unpack("NN")
    color_type = bytes.getbyte(25)
    [width, height, [4, 6].include?(color_type)]
  end

  def run(arguments)
    options = parse(arguments)
    delivery_root = folder!(options.fetch(:delivery), "--delivery")
    files_root = folder!(File.join(delivery_root, "files"), "delivery files")
    raw_root = folder!(options.fetch(:raw_root), "--raw-root")
    requirements = regular!(options.fetch(:requirements), "--requirements")
    out = options.fetch(:out)
    refuse!("--out must be a new folder: #{out} exists") if File.exist?(out) || File.symlink?(out)
    parent = folder!(File.dirname(File.expand_path(out)), "the parent of --out")

    delivery_path = File.join(delivery_root, "delivery.json")
    delivery = exact!(json!(delivery_path, "delivery.json"), DELIVERY_KEYS, "delivery.json")
    refuse!("delivery.json schemaVersion must be 1") unless delivery["schemaVersion"] == 1
    workspace = exact!(delivery["workspace"], WORKSPACE_KEYS, "delivery.json workspace")
    refuse!("workspace.commit must be a full Git SHA") unless workspace["commit"].is_a?(String) && workspace["commit"].match?(SHA)
    exact!(delivery["app"], %w[bundleId], "delivery.json app")
    refuse!("the delivery is for #{delivery.dig('app', 'bundleId')}, not #{options.fetch(:bundle_id)}") unless delivery.dig("app", "bundleId") == options.fetch(:bundle_id)
    kinds = delivery["kinds"]
    refuse!("kinds must be a non-empty subset of #{KINDS.join(', ')}") unless kinds.is_a?(Array) && !kinds.empty? && kinds == kinds.uniq && (kinds - KINDS).empty?
    refuse!("this intake takes screenshots; kinds must include screenshots") unless kinds.include?("screenshots")
    refuse!("checks must be an array") unless delivery["checks"].is_a?(Array)

    listed = files!(delivery, files_root)
    raw, manifest_path = raw!(delivery, raw_root, requirements)
    adopted, provenance_file = provenance!(listed, files_root)
    records = records!(listed, files_root)
    cases = faces!(delivery, listed, files_root, raw, raw_root, records, adopted)
    adoption = adoption!(delivery, options.fetch(:workspace_repo), workspace["commit"])
    copy = kinds.include?("copy") ? copy!(listed, files_root, options) : nil
    refuse!("copy is delivered but kinds does not list copy") if copy.nil? && listed.values.any? { |file| file["role"] == "copy" }

    renderer = exact!(delivery["renderer"], RENDERER_KEYS, "delivery.json renderer")
    refuse!("renderer.sha256 is invalid") unless renderer["sha256"].is_a?(String) && renderer["sha256"].match?(DIGEST)
    composition = {
      "schemaVersion" => 1,
      "rawManifestDigest" => sha256(manifest_path),
      "captureBatchId" => delivery.dig("inputs", "captureBatch"),
      "sourceSha" => raw["sourceSha"],
      "buildDigest" => raw["buildDigest"],
      "runtime" => raw["runtime"],
      "requirementsDigest" => raw["requirementsDigest"],
      "rendererDigest" => renderer["sha256"],
      "adoption" => adoption.merge("provenanceDigest" => provenance_file["sha256"]),
      "cases" => cases.sort_by { |entry| entry.values_at("locale", "family", "order") }.map { |entry| entry.reject { |key, _| key == "source" } }
    }

    staging = Dir.mktmpdir(".appstore-intake-", parent)
    begin
      cases.each do |entry|
        target = File.join(staging, entry["path"])
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.copy_file(entry["source"], target)
        File.chmod(0o644, target)
      end
      FileUtils.mkdir_p(File.join(staging, "records"))
      (records.values.map { |record| record[:file] } + [provenance_file]).each do |file|
        target = File.join(staging, "records", "#{file['sha256'].sub(':', '-')}.json")
        FileUtils.copy_file(File.join(files_root, file["path"]), target) unless File.exist?(target)
        File.chmod(0o644, target)
      end
      File.binwrite(File.join(staging, "composition.json"), JSON.pretty_generate(composition) + "\n")
      intake = {
        "schemaVersion" => 1,
        "workspace" => workspace,
        "app" => delivery["app"],
        "deliverySha256" => sha256(delivery_path),
        "rawManifestSha256" => sha256(manifest_path),
        "rendererSha256" => renderer["sha256"],
        "adoptionRecordSha256" => delivery.dig("adoption", "record", "sha256"),
        "compositionSha256" => sha256(File.join(staging, "composition.json")),
        "copy" => copy,
        "status" => "accepted"
      }.compact
      File.binwrite(File.join(staging, "intake.json"), JSON.pretty_generate(intake) + "\n")
      File.rename(staging, out)
    rescue StandardError
      FileUtils.rm_rf(staging)
      raise
    end
    {"status" => "accepted", "composedRoot" => out, "composition" => File.join(out, "composition.json"),
     "intake" => File.join(out, "intake.json"), "cases" => cases.size, "compositionDigest" => sha256(File.join(out, "composition.json"))}
  end

  def parse(arguments)
    options = {}
    parser = OptionParser.new do |cli|
      cli.banner = "usage: intake-appstore-delivery.sh --delivery DIR --raw-root DIR --requirements FILE --bundle-id ID --workspace-repo DIR --project-root DIR --out DIR"
      cli.on("--delivery DIR") { |value| options[:delivery] = value }
      cli.on("--raw-root DIR") { |value| options[:raw_root] = value }
      cli.on("--requirements FILE") { |value| options[:requirements] = value }
      cli.on("--bundle-id ID") { |value| options[:bundle_id] = value }
      cli.on("--workspace-repo DIR") { |value| options[:workspace_repo] = value }
      cli.on("--project-root DIR") { |value| options[:project_root] = value }
      cli.on("--out DIR") { |value| options[:out] = value }
    end
    rest = parser.parse(arguments)
    refuse!("unexpected arguments: #{rest.join(' ')}") unless rest.empty?
    missing = %i[delivery raw_root requirements bundle_id workspace_repo project_root out].reject { |key| options[key] }
    refuse!("#{parser.banner}\nmissing: #{missing.map { |key| "--#{key.to_s.tr('_', '-')}" }.join(', ')}") unless missing.empty?
    options
  rescue OptionParser::ParseError => error
    refuse!(error.message)
  end

  # Every listed file exists at its path with its SHA-256 and size, and nothing else is delivered.
  def files!(delivery, files_root)
    refuse!("files must be a non-empty array") unless delivery["files"].is_a?(Array) && !delivery["files"].empty?
    listed = {}
    delivery["files"].each_with_index do |file, index|
      exact!(file, FILE_KEYS, "files[#{index}]")
      path = file["path"]
      refuse!("files[#{index}].path is unsafe: #{path.inspect}") unless path.is_a?(String) && path.match?(RELATIVE)
      refuse!("#{path} is listed twice") if listed.key?(path)
      refuse!("#{path} has an unknown role #{file['role'].inspect}") unless ROLES.include?(file["role"])
      refuse!("#{path} has an invalid SHA-256") unless file["sha256"].is_a?(String) && file["sha256"].match?(DIGEST)
      absolute = regular!(File.join(files_root, path), path)
      refuse!("#{path} is outside the delivery") unless File.realpath(absolute).start_with?(files_root + "/")
      refuse!("#{path} does not have its listed SHA-256") unless sha256(absolute) == file["sha256"]
      refuse!("#{path} does not have its listed size") unless File.size(absolute) == file["bytes"]
      listed[path] = file
    end
    present = Dir.glob("**/*", File::FNM_DOTMATCH, base: files_root).reject { |path| File.basename(path).match?(/\A\.\.?\z/) }
    present.each do |path|
      absolute = File.join(files_root, path)
      next if File.directory?(absolute) && !File.symlink?(absolute)
      refuse!("#{path} is delivered but not listed") unless listed.key?(path)
    end
    listed
  end

  # The raw captures are the app's own: the manifest in --raw-root matches the delivery's inputs, the
  # current requirements, and still has the bytes it records.
  def raw!(delivery, raw_root, requirements)
    inputs = exact!(delivery["inputs"], INPUT_KEYS, "delivery.json inputs")
    refuse!("inputs.captureBatch is invalid") unless inputs["captureBatch"].is_a?(String) && inputs["captureBatch"].match?(BATCH)
    manifest_path = File.join(raw_root, "manifest.json")
    raw = exact!(json!(manifest_path, "raw capture manifest"), RAW_KEYS, "raw capture manifest")
    refuse!("raw capture manifest schemaVersion must be 1") unless raw["schemaVersion"] == 1 && raw["cases"].is_a?(Array)
    refuse!("the raw capture manifest is not the one the delivery was made from") unless sha256(manifest_path) == inputs["rawManifestSha256"]
    %w[sourceSha buildDigest runtime].each do |key|
      refuse!("inputs.#{key} differs from the raw capture manifest") unless inputs[key] == raw[key]
    end
    refuse!("the delivery was made for other submission requirements") unless inputs["requirementsSha256"] == sha256(requirements)
    refuse!("the raw captures were taken for other submission requirements") unless raw["requirementsDigest"] == sha256(requirements)
    raw["cases"].each_with_index do |entry, index|
      exact!(entry, RAW_CASE_KEYS, "raw capture manifest cases[#{index}]")
      path = entry["path"]
      refuse!("raw capture path is unsafe: #{path.inspect}") unless path.is_a?(String) && path.match?(RELATIVE)
      absolute = regular!(File.join(raw_root, path), "raw capture #{path}")
      refuse!("raw capture #{path} changed after capture") unless File.realpath(absolute).start_with?(raw_root + "/") && sha256(absolute) == entry["digest"]
    end
    [raw, manifest_path]
  end

  def by_role(listed, role)
    listed.values.select { |file| file["role"] == role }
  end

  def provenance!(listed, files_root)
    files = by_role(listed, "provenance")
    refuse!("exactly one provenance.json must be delivered") unless files.size == 1
    provenance = json!(File.join(files_root, files.first["path"]), "provenance.json")
    refuse!("provenance.json must be schema 1 with images") unless provenance.is_a?(Hash) && provenance["schemaVersion"] == 1 && provenance["images"].is_a?(Array)
    adopted = provenance["images"].select { |image| image.is_a?(Hash) && image.dig("materialReview", "decision") == "adopted" }.map { |image| image["sha256"] }
    [adopted, files.first]
  end

  def records!(listed, files_root)
    files = by_role(listed, "render-record")
    refuse!("no render record is delivered") if files.empty?
    files.each_with_object({}) do |file, records|
      record = json!(File.join(files_root, file["path"]), file["path"])
      unless record.is_a?(Hash) && record["schemaVersion"] == 1 && record["renderer"] == "appstore-creative-compose" &&
             record["inputInventory"] == "complete-v1" && DEVICES.key?(record["device"]) && LOCALES.include?(record["locale"]) &&
             record["files"].is_a?(Array) && record["tiles"].is_a?(Array) && record["files"].size == record["tiles"].size
        refuse!("#{file['path']} is not a complete render record of the compose renderer")
      end
      records[file["sha256"]] = {file: file, value: record}
    end
  end

  # Each face is the tile its render record names at its order, shows the raw capture of its locale,
  # family and state, uses adopted materials only, and comes with the declaration the record names.
  def faces!(delivery, listed, files_root, raw, raw_root, records, adopted)
    faces = delivery["faces"]
    refuse!("faces must be a non-empty array") unless faces.is_a?(Array) && !faces.empty?
    declarations = by_role(listed, "declaration").map { |file| file["sha256"] }
    delivered_faces = by_role(listed, "face").map { |file| file["path"] }
    seen = {}
    cases = faces.each_with_index.map do |face, index|
      label = "faces[#{index}]"
      exact!(face, FACE_KEYS, label)
      locale, family, order, state = face.values_at("locale", "family", "order", "state")
      refuse!("#{label} has an unknown locale or family") unless LOCALES.include?(locale) && DEVICES.key?(family)
      refuse!("#{label}.order is invalid") unless order.is_a?(Integer) && order.between?(1, 10)
      refuse!("#{label}.state is invalid") unless state.is_a?(String) && state.match?(/\A[a-z0-9-]+\z/)
      expected = format("screenshots/faces/%s/%s/%02d-%s.png", locale, family, order, state)
      refuse!("#{label}.path must be #{expected}") unless face["path"] == expected
      file = listed[expected]
      refuse!("#{expected} is not delivered as a face") unless file && file["role"] == "face" && file["sha256"] == face["sha256"]
      refuse!("#{label} shows the #{state} capture of #{locale} #{family} twice") if seen[[locale, family, state]]
      refuse!("#{label} repeats order #{order} of #{locale} #{family}") if seen[[locale, family, order]]
      seen[[locale, family, state]] = seen[[locale, family, order]] = true
      raw_case = raw["cases"].find { |entry| entry.values_at("locale", "family", "state") == [locale, family, state] }
      refuse!("#{label} has no #{locale} #{family} #{state} raw capture") unless raw_case && raw_case["digest"] == face["rawDigest"]
      entry = records[face["renderRecord"]]
      refuse!("#{label} names a render record that is not delivered") unless entry
      record = entry[:value]
      refuse!("#{label} is drawn by a record of another locale or family") unless record["locale"] == locale && record["device"] == family
      refuse!("#{label} names another declaration than its record") unless record["specSha256"] == face["declaration"]
      refuse!("#{label}: its declaration is not delivered") unless declarations.include?(face["declaration"])
      tile_file = record["files"][order - 1]
      tile = record["tiles"][order - 1]
      refuse!("#{label} is not the tile its record drew at order #{order}") unless tile_file.is_a?(Hash) && tile_file["sha256"] == face["sha256"]
      capture = tile.is_a?(Hash) ? tile["capture"] : nil
      listed_capture = record["captures"].is_a?(Array) && record["captures"].any? { |item| item.is_a?(Hash) && item["sha256"] == face["rawDigest"] }
      refuse!("#{label} does not show its raw capture in the render record") unless capture.is_a?(Hash) && capture["sha256"] == face["rawDigest"] && listed_capture
      backgrounds = (record["backgrounds"] || []).select { |item| item.is_a?(Hash) && item["file"] == tile_file["path"] }.map { |item| item["sourceSha256"] }
      layers = ((record["layers"] || []) + (record["decorations"] || [])).select { |item| item.is_a?(Hash) && item["tiles"].is_a?(Array) && item["tiles"].include?(order) }.map { |item| item["sha256"] }
      assets = (backgrounds + layers).uniq.sort
      refuse!("#{label} lists an input without a SHA-256") unless assets.all? { |asset| asset.is_a?(String) && asset.match?(DIGEST) }
      assets.each { |asset| refuse!("#{label} uses a material that provenance.json does not record as adopted: #{asset}") unless adopted.include?(asset) }
      source = File.join(files_root, expected)
      width, height, alpha = png_info(source)
      refuse!("#{label} is #{width}x#{height}, expected #{DEVICES.fetch(family).join('x')}") unless [width, height] == DEVICES.fetch(family)
      refuse!("#{label} has an alpha channel") if alpha
      {"locale" => locale, "family" => family, "state" => state, "order" => order,
       "path" => format("%s/%s/%02d-%s.png", locale, family, order, state), "rawPath" => raw_case["path"], "rawDigest" => raw_case["digest"],
       "declarationDigest" => face["declaration"], "renderRecordDigest" => face["renderRecord"], "assetDigests" => assets,
       "width" => width, "height" => height, "digest" => face["sha256"], "source" => source}
    end
    unshown = delivered_faces - faces.map { |face| face["path"] }
    refuse!("faces are delivered but not listed in faces: #{unshown.join(', ')}") unless unshown.empty?
    records.each_value do |entry|
      record = entry[:value]
      drawn = cases.select { |item| item["renderRecordDigest"] == entry[:file]["sha256"] }.map { |item| item["order"] }.sort
      refuse!("#{entry[:file]['path']} drew tiles that are not delivered") unless drawn == (1..record["files"].size).to_a
    end
    cases
  end

  # The user's choice: a selection record written by the workspace's sheet tool, committed in the
  # workspace repository at the delivered commit with the delivered SHA-256.
  def adoption!(delivery, workspace_repo, commit)
    adoption = exact!(delivery["adoption"], ADOPTION_KEYS, "delivery.json adoption")
    record = exact!(adoption["record"], RECORD_KEYS, "delivery.json adoption.record")
    refuse!("adoption.decision must be user-explicit") unless adoption["decision"] == "user-explicit"
    refuse!("adoption.approvalReference must be an Issue or pull request reference or comment URL") unless adoption["approvalReference"].is_a?(String) && adoption["approvalReference"].match?(APPROVAL)
    refuse!("adoption.choice is invalid") unless adoption["choice"].is_a?(String) && adoption["choice"].match?(CONCEPT)
    refuse!("adoption.sheetSha256 is invalid") unless adoption["sheetSha256"].is_a?(String) && adoption["sheetSha256"].match?(DIGEST)
    refuse!("adoption.record.path is unsafe") unless record["path"].is_a?(String) && record["path"].match?(RELATIVE)
    refuse!("adoption.record.sha256 is invalid") unless record["sha256"].is_a?(String) && record["sha256"].match?(DIGEST)
    repository = folder!(workspace_repo, "--workspace-repo")
    environment = {"PATH" => "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_TERMINAL_PROMPT" => "0"}
    git = ["/usr/bin/git", "-C", repository, "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]
    _, status = Open3.capture2e(environment, *git, "cat-file", "-e", "#{commit}^{commit}")
    refuse!("the workspace repository has no commit #{commit}") unless status.success?
    blob, status = Open3.capture2(environment, *git, "show", "#{commit}:#{record['path']}", binmode: true)
    refuse!("the choice #{record['path']} is not in the workspace commit #{commit}") unless status.success?
    refuse!("the choice in the workspace commit does not have the delivered SHA-256") unless "sha256:#{Digest::SHA256.hexdigest(blob)}" == record["sha256"]
    selection = begin
      JSON.parse(blob)
    rescue JSON::ParserError
      refuse!("the choice in the workspace commit is not JSON")
    end
    unless selection.is_a?(Hash) && selection["schemaVersion"] == 1 && selection["decision"] == "user-explicit" &&
           selection["selection"].is_a?(Hash) && selection["recordedAt"].is_a?(String)
      refuse!("the choice in the workspace commit is not an explicit choice recorded by the sheet tool")
    end
    refuse!("the choice was made on another sheet") unless selection["sheetSha256"] == adoption["sheetSha256"]
    refuse!("adoption.at differs from the recorded choice") unless selection["recordedAt"] == adoption["at"]
    chosen = selection.dig("selection", "type") == "pattern" ? selection.dig("selection", "patternId") : "combination"
    refuse!("adoption.choice differs from the recorded choice") unless chosen == adoption["choice"]
    {"proposalSheetDigest" => adoption["sheetSha256"], "selectionDigest" => record["sha256"], "conceptId" => adoption["choice"],
     "decision" => "user-explicit", "approvalReference" => adoption["approvalReference"], "recordedAt" => adoption["at"]}
  end

  # Delivered copy passes the app's own read-only store-copy check; it is not written into the app.
  def copy!(listed, files_root, options)
    copies = by_role(listed, "copy")
    refuse!("kinds lists copy but no copy is delivered") if copies.empty?
    copies.each do |file|
      refuse!("#{file['path']} must be copy/localizations/<locale>.yml") unless file["path"].match?(%r{\Acopy/localizations/(en-US|ja)\.yml\z})
    end
    tool = File.expand_path("../check-store-copy.sh", __dir__)
    output, status = Open3.capture2("/bin/bash", tool, "--project-root", options.fetch(:project_root),
                                    "--localizations", File.join(files_root, "copy", "localizations"),
                                    "--requirements", File.expand_path(options.fetch(:requirements)))
    result = begin
      JSON.parse(output)
    rescue JSON::ParserError
      {}
    end
    refuse!("the store-copy check refused the delivered copy: #{output.strip[0, 400]}") unless status.success? && result["status"] == "passed"
    {"locales" => result["locales"], "errors" => result["errors"].size, "warnings" => result["warnings"].size}
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    puts JSON.generate(AppStoreIntake.run(ARGV))
  rescue AppStoreIntake::Refused => error
    warn "appstore-intake: #{error.message}"
    exit 1
  end
end
