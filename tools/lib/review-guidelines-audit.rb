#!/usr/bin/env ruby
# frozen_string_literal: true

# D-081: checks an app's pre-submission audit of the App Store Review Guidelines against the template's
# guideline map. It reads local files only: it never opens the network, App Store Connect, a credential
# store, or Apple's page. A passing check is not evidence that App Review will approve the app.

require "date"
require "digest"
require "json"
require "optparse"
require "pathname"
require "time"

module ReviewGuidelinesAudit
  AUDIT_RELATIVE = "App Store/review/guidelines-audit.json"
  MAP_RELATIVE = ".agents/skills/app-review-guidelines/guidelines.json"
  AUDIT_KEYS = %w[app auditedAt items map schemaVersion].freeze
  APP_KEYS = %w[build bundleId version].freeze
  MAP_KEYS = %w[digest lastUpdated].freeze
  STATUS_BY_CLASS = {
    "always" => %w[satisfied],
    "triggered" => %w[satisfied not-applicable],
    "user-judgment" => %w[user-confirmed]
  }.freeze
  ITEM_KEYS = {
    "satisfied" => [%w[evidence id status], %w[note]],
    "not-applicable" => [%w[id reason status], %w[note]],
    "user-confirmed" => [%w[confirmation id status], %w[note]]
  }.freeze
  CONFIRMATION_KEYS = %w[by confirmedAt reference].freeze
  COMMENT_URL = %r{\Ahttps://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*#issuecomment-[1-9][0-9]*\z}.freeze
  EVIDENCE_URL = %r{\Ahttps://[A-Za-z0-9.-]+(?:/[^\s]*)?\z}.freeze
  SECRET_LIKE = /(password|passcode|api[_ -]?key|token|secret|private[_ -]?key)\s*[:=]|-----BEGIN [A-Z ]*PRIVATE KEY-----/i.freeze
  MAX_TEXT = 2000

  class InputError < StandardError; end

  module_function

  def run(argv, out: $stdout, err: $stderr)
    options = parse(argv)
    root = Pathname.new(options[:project_root])
    raise InputError, "project root must be an absolute directory" unless root.absolute? && root.directory?

    map_path = options[:map] ? Pathname.new(options[:map]) : root.join(MAP_RELATIVE)
    audit_path = options[:audit] ? Pathname.new(options[:audit]) : root.join(AUDIT_RELATIVE)
    map_bytes = read_regular(map_path, "guideline map")
    audit_bytes = read_regular(audit_path, "audit")
    map = parse_json(map_bytes, "guideline map")
    audit = parse_json(audit_bytes, "audit")
    now = options[:now] ? Time.iso8601(options[:now]).utc : Time.now.utc

    errors = check(map, "sha256:#{Digest::SHA256.hexdigest(map_bytes)}", audit, root, options, now)
    summary = {
      "status" => errors.empty? ? "passed" : "failed",
      "auditDigest" => "sha256:#{Digest::SHA256.hexdigest(audit_bytes)}",
      "mapDigest" => "sha256:#{Digest::SHA256.hexdigest(map_bytes)}",
      "mapLastUpdated" => map.dig("source", "lastUpdated"),
      "errors" => errors
    }
    if errors.empty?
      counts = Hash.new(0)
      audit["items"].each { |item| counts[item["status"]] += 1 }
      summary["counts"] = counts.sort.to_h
    end
    out.puts JSON.generate(summary)
    errors.empty? ? 0 : 1
  rescue InputError, OptionParser::ParseError, ArgumentError => e
    err.puts "review guidelines audit refused: #{e.message}"
    2
  rescue SystemCallError, IOError
    err.puts "review guidelines audit refused: an input could not be read"
    2
  end

  def parse(argv)
    options = {}
    OptionParser.new do |cli|
      cli.banner = "usage: check-review-guidelines.sh --project-root DIR --bundle-id ID --version V --build B [--audit PATH] [--map PATH] [--now ISO8601]"
      cli.on("--project-root DIR") { |value| options[:project_root] = value }
      cli.on("--bundle-id ID") { |value| options[:bundle_id] = value }
      cli.on("--version V") { |value| options[:version] = value }
      cli.on("--build B") { |value| options[:build] = value }
      cli.on("--audit PATH") { |value| options[:audit] = value }
      cli.on("--map PATH") { |value| options[:map] = value }
      cli.on("--now ISO8601") { |value| options[:now] = value }
    end.parse!(argv)
    raise InputError, "unexpected arguments" unless argv.empty?
    %i[project_root bundle_id version build].each do |key|
      raise InputError, "--#{key.to_s.tr('_', '-')} is required" if options[key].to_s.empty?
    end
    options
  end

  def read_regular(path, label)
    raise InputError, "#{label} is missing" unless path.file?
    raise InputError, "#{label} must not be a symbolic link" if path.symlink?
    path.binread
  rescue SystemCallError, IOError
    raise InputError, "#{label} could not be read"
  end

  def parse_json(bytes, label)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    raise InputError, "#{label} is not UTF-8" unless text.valid_encoding?
    value = JSON.parse(text)
    raise InputError, "#{label} must be a JSON object" unless value.is_a?(Hash)
    value
  rescue JSON::ParserError
    raise InputError, "#{label} is not valid JSON"
  end

  def check(map, map_digest, audit, root, options, now)
    errors = []
    guidelines = map["guidelines"]
    source = map["source"]
    unless map["schemaVersion"] == 1 && guidelines.is_a?(Array) && source.is_a?(Hash) && map["maxAgeDays"].is_a?(Integer)
      raise InputError, "guideline map has an unknown format"
    end
    classes = {}
    guidelines.each { |entry| classes[entry["id"]] = entry["class"] }

    retrieved = Date.iso8601(source["retrievedAt"].to_s)
    age = (now.to_date - retrieved).to_i
    errors << "guideline map was retrieved #{age} days ago, beyond #{map['maxAgeDays']} days; recheck Apple's page first" if age > map["maxAgeDays"]
    errors << "guideline map retrievedAt is in the future" if age.negative?

    # Diagnostics never repeat submitted values, so a secret-like audit is refused before any other check.
    return errors + ["audit contains secret-like text; remove it before checking"] if secret_like?(audit)

    unless audit.keys.sort == AUDIT_KEYS
      errors << "audit keys must be exactly #{AUDIT_KEYS.join(', ')}"
      return errors
    end
    errors << "audit schemaVersion must be 1" unless audit["schemaVersion"] == 1

    audit_map = audit["map"]
    if audit_map.is_a?(Hash) && audit_map.keys.sort == MAP_KEYS
      errors << "audit map lastUpdated differs from the guideline map" unless audit_map["lastUpdated"] == source["lastUpdated"]
      errors << "audit map digest differs from the guideline map" unless audit_map["digest"] == map_digest
    else
      errors << "audit map must have exactly digest and lastUpdated"
    end

    app = audit["app"]
    if app.is_a?(Hash) && app.keys.sort == APP_KEYS
      { "bundleId" => :bundle_id, "version" => :version, "build" => :build }.each do |key, option|
        errors << "audit app #{key} differs from the candidate" unless app[key] == options[option]
      end
    else
      errors << "audit app must have exactly bundleId, version and build"
    end

    begin
      audited = Time.iso8601(audit["auditedAt"].to_s)
      errors << "auditedAt is in the future" if audited > now
    rescue ArgumentError
      errors << "auditedAt must be an ISO 8601 time"
    end

    items = audit["items"]
    unless items.is_a?(Array)
      errors << "audit items must be an array"
      return errors
    end
    seen = Hash.new(0)
    items.each_with_index do |item, index|
      unless item.is_a?(Hash) && item["id"].is_a?(String)
        errors << "audit item at index #{index} must be an object with an id"
        next
      end
      id = item["id"]
      klass = classes[id]
      if klass.nil?
        errors << "audit item at index #{index} is not in the guideline map"
        next
      end
      seen[id] += 1
      errors.concat(check_item(item, klass, root, now))
    end
    seen.each { |id, count| errors << "audit item #{id} appears #{count} times" if count > 1 }
    (classes.keys - seen.keys).each { |id| errors << "audit misses guideline #{id}" }
    errors
  end

  # Checks every decoded key and string, so escaping in a serialized form cannot hide a separator.
  def secret_like?(value)
    case value
    when Hash then value.any? { |key, child| secret_like?(key) || secret_like?(child) }
    when Array then value.any? { |child| secret_like?(child) }
    when String then value.match?(SECRET_LIKE)
    else false
    end
  end

  def check_item(item, klass, root, now)
    id = item["id"]
    status = item["status"]
    allowed = STATUS_BY_CLASS.fetch(klass)
    return ["audit item #{id} status is not allowed for #{klass}; use #{allowed.join(' or ')}"] unless allowed.include?(status)

    required, optional = ITEM_KEYS.fetch(status)
    keys = item.keys.sort
    unless (required - keys).empty? && (keys - required - optional).empty?
      return ["audit item #{id} keys must be #{required.join(', ')} with optional #{optional.join(', ')}"]
    end
    errors = []
    errors << "audit item #{id} note must be text" if item.key?("note") && !text?(item["note"])
    case status
    when "satisfied"
      evidence = item["evidence"]
      if evidence.is_a?(Array) && !evidence.empty? && evidence.all? { |value| text?(value) }
        evidence.each_with_index { |value, position| errors.concat(check_evidence("#{id} evidence #{position + 1}", value, root)) }
      else
        errors << "audit item #{id} needs at least one evidence location"
      end
    when "not-applicable"
      errors << "audit item #{id} needs a reason" unless text?(item["reason"])
    when "user-confirmed"
      errors.concat(check_confirmation(id, item["confirmation"], now))
    end
    errors
  end

  def text?(value)
    value.is_a?(String) && !value.strip.empty? && value.length <= MAX_TEXT
  end

  def check_evidence(label, value, root)
    return [] if value.match?(EVIDENCE_URL)

    relative = value.sub(/(?:#.*|:\d+(?:-\d+)?)\z/, "")
    path = Pathname.new(relative)
    if path.absolute? || relative.split("/").include?("..") || relative.empty?
      return ["audit item #{label} must be an https URL or a path inside the project"]
    end
    target = root.join(path)
    return ["audit item #{label} path does not exist"] unless target.exist? || target.symlink?
    return ["audit item #{label} path must not be a symbolic link"] if target.symlink?
    # A symbolic link in a parent directory must not lead the evidence outside the project.
    real_root = root.realpath.to_s
    real_target = target.realpath.to_s
    return ["audit item #{label} path must stay inside the project"] unless real_target == real_root || real_target.start_with?(real_root + "/")
    []
  end

  def check_confirmation(id, confirmation, now)
    unless confirmation.is_a?(Hash) && confirmation.keys.sort == CONFIRMATION_KEYS
      return ["audit item #{id} confirmation must have exactly by, confirmedAt and reference"]
    end
    errors = []
    errors << "audit item #{id} must be confirmed by the user, not decided by AI" unless confirmation["by"] == "user"
    reference = confirmation["reference"]
    errors << "audit item #{id} confirmation reference must be a GitHub Issue comment URL" unless reference.is_a?(String) && reference.match?(COMMENT_URL)
    begin
      errors << "audit item #{id} confirmation is in the future" if Time.iso8601(confirmation["confirmedAt"].to_s) > now
    rescue ArgumentError
      errors << "audit item #{id} confirmedAt must be an ISO 8601 time"
    end
    errors
  end
end

exit ReviewGuidelinesAudit.run(ARGV) if $PROGRAM_NAME == __FILE__
