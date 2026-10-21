#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "cgi"
require "digest"
require "fileutils"
require "json"
require "open3"
require "time"
require "tmpdir"

# D-077: the appstore-creative proposal sheet. `build` turns a pattern definition and already rendered
# tile images into one self-contained HTML page that makes no network request, checks every pattern
# against the D-077 tile rules, and never replaces a revision the user may have seen. `select` records
# the user's explicit choice of one pattern, or of a complete tile-by-tile combination, for that exact
# sheet. A `storyboard` sheet compares exactly two preview video storyboards for one device and locale:
# each frame is a still of one segment with its states.json state, seconds and motion, a storyboard
# runs 15 to 30 seconds, and the user chooses one storyboard whole.
#
# D-085: a proposal is built from the app's identity (`goldie/brand.json`), one style spec per pattern
# and a research record of the reference apps the patterns drew techniques from. It compares three to
# six patterns, recommends exactly one, refuses two patterns that share a signature element or the same
# layouts and backgrounds, and marks repeated layouts, repeated strengths and long headline candidates.
# `check` validates a brand record against the real-capture inventory, and optionally a style spec
# against the brand record, on its own.
module AppStoreCreativeSheet
  SCHEMA_VERSION = 1
  SHEET_KINDS = %w[proposal preview storyboard].freeze
  PROPOSAL_PATTERNS = (3..6).freeze
  RESEARCH_REFERENCES = (3..5).freeze
  BRAND_STRENGTHS = (1..5).freeze
  BRAND_VOICE = (1..5).freeze
  MIN_HEADLINES = 2
  # A layout repeated on this many adjacent tiles makes the set read as one screen repeated.
  LAYOUT_RUN_MARK = 3
  # Headline guides in characters (Japanese without spaces, English with single spaces); a definition
  # may set its own with `headlineLimits`.
  DEFAULT_HEADLINE_LIMITS = {"ja" => 16, "en-US" => 36}.freeze
  TOKEN_PATTERN = /\A[a-z0-9][a-z0-9-]{0,31}\z/
  HEX_PATTERN = /\A#[0-9A-Fa-f]{6}\z/
  DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/
  STORYBOARD_COUNT = 2
  PREVIEW_SECONDS = (15..30).freeze
  STATE_PATTERN = /\A[a-z0-9][a-z0-9-]{0,31}\z/
  TILE_KINDS = %w[device pair panorama continuous callout scene concept].freeze
  DEVICES = %w[iphone ipad].freeze
  LOCALES = %w[ja en-US].freeze
  ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9-]{0,31}\z/
  REVISION_PATTERN = /\A[a-z0-9][a-z0-9-]{0,63}\z/
  DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/
  # The patterns, tiles and tile kinds the page shows travel inside the page itself, so a selection is
  # checked against the displayed bytes rather than against the separate, editable sheet.json.
  DISPLAY_RECORD_META = "appstore-creative-sheet"
  DISPLAY_RECORD_PATTERN = /<meta name="#{DISPLAY_RECORD_META}" content="([A-Za-z0-9+\/=]+)">/
  # The first three tiles show in search results, so they must show the app in use (App Review 2.3.3).
  FIRST_TILES_WITH_APP = 3
  MAX_CONCEPT_TILES = 2
  DEFAULT_MAX_DIMENSION = 960
  CONTENT_SECURITY_POLICY = "default-src 'none'; style-src 'unsafe-inline'; img-src data:; script-src 'none'; " \
    "connect-src 'none'; font-src 'none'; form-action 'none'; base-uri 'none'; frame-src 'none'; object-src 'none'"
  # Text that could make the page reach the network, or carry markup through, is refused in the definition.
  FORBIDDEN_TEXT = %r{(?:[a-z][a-z0-9+.-]*://|//[^\s]|url\s*\(|@import|<|>|javascript:)}i
  TEXT_LIMIT = 2000

  class Failure < StandardError; end

  module_function

  def run(argv)
    command = argv.shift or fail!("command is required: build, select or check")
    options = parse_options(argv)
    value = case command
            when "build" then build(options)
            when "select" then select(options)
            when "check" then check(options)
            else fail!("unknown command: #{command}")
            end
    puts JSON.generate(value)
  rescue Failure, JSON::ParserError, KeyError, ArgumentError, SystemCallError => error
    warn error.message
    exit 1
  end

  def parse_options(argv)
    options = {}
    until argv.empty?
      key = argv.shift
      fail!("unexpected argument: #{key}") unless key&.start_with?("--")
      value = argv.shift
      fail!("missing value for #{key}") if value.nil? || value.start_with?("--")
      name = key.delete_prefix("--")
      fail!("duplicate option: #{key}") if options.key?(name)
      options[name] = value
    end
    options
  end

  def fail!(message)
    raise Failure, message
  end

  def require_options(options, *names)
    missing = names.reject { |name| options.key?(name) }
    fail!("missing option: #{missing.map { |name| "--#{name}" }.join(', ')}") unless missing.empty?
  end

  # --- build ---------------------------------------------------------------------------------------

  def build(options)
    require_options(options, "spec", "root", "revision")
    unknown = options.keys - %w[spec root revision max-dimension]
    fail!("unknown option: --#{unknown.first}") unless unknown.empty?
    revision = options.fetch("revision")
    fail!("revision must be lowercase letters, digits, and hyphens") unless revision.match?(REVISION_PATTERN)
    max_dimension = Integer(options.fetch("max-dimension", DEFAULT_MAX_DIMENSION.to_s), 10)
    fail!("max dimension must be between 200 and 2000") unless (200..2000).cover?(max_dimension)

    spec_path = File.expand_path(options.fetch("spec"))
    spec_bytes = read_regular(spec_path, "pattern definition")
    spec = validate_spec(JSON.parse(spec_bytes), File.dirname(spec_path))

    root = File.expand_path(options.fetch("root"))
    FileUtils.mkdir_p(root, mode: 0o700)
    destination = File.join(root, revision)
    fail!("revision already exists and is never replaced: #{revision}") if File.exist?(destination) || File.symlink?(destination)

    staging = Dir.mktmpdir(".#{revision}.", root)
    begin
      images = {}
      spec.fetch("patterns").each do |pattern|
        pattern.fetch("tiles").each do |tile|
          source = tile.fetch("source")
          images[source] ||= embed_image(source, max_dimension, staging)
        end
      end
      checks = spec.fetch("patterns").to_h { |pattern| [pattern.fetch("id"), rule_check(pattern.fetch("tiles"), spec.fetch("kind"))] }
      marks = spec.fetch("patterns").to_h { |pattern| [pattern.fetch("id"), proposal_marks(pattern, spec)] }
      html = render_html(spec, revision, images, checks, display_record(spec, revision), marks)
      File.binwrite(File.join(staging, "sheet.html"), html)
      record = {
        "schemaVersion" => SCHEMA_VERSION,
        "revision" => revision,
        "kind" => spec.fetch("kind"),
        "sheetSha256" => "sha256:#{Digest::SHA256.hexdigest(html)}",
        "definitionSha256" => "sha256:#{Digest::SHA256.hexdigest(spec_bytes)}",
        "builtAt" => Time.now.utc.iso8601,
        "patterns" => spec.fetch("patterns").map do |pattern|
          entry = {
            "id" => pattern.fetch("id"),
            "tiles" => pattern.fetch("tiles").map do |tile|
              display_tile(tile, spec.fetch("kind")).merge("sourceSha256" => images.fetch(tile.fetch("source")).fetch("sha256"))
            end,
            "ruleCheck" => checks.fetch(pattern.fetch("id"))
          }
          if spec.fetch("kind") == "proposal"
            entry.merge!("recommended" => pattern.fetch("recommended"), "styleSha256" => pattern.fetch("styleRecord").fetch("sha256"),
                         "techniques" => pattern.fetch("techniques"), "marks" => marks.fetch(pattern.fetch("id")))
          end
          entry
        end
      }
      if spec.fetch("kind") == "proposal"
        record.merge!("brandSha256" => spec.fetch("brandRecord").fetch("sha256"),
                      "capturesSha256" => spec.fetch("capturesRecord").fetch("sha256"),
                      "researchSha256" => spec.fetch("researchRecord").fetch("sha256"))
      end
      File.binwrite(File.join(staging, "sheet.json"), "#{JSON.pretty_generate(record)}\n")
      Dir.children(staging).each { |name| File.unlink(File.join(staging, name)) if name.start_with?(".thumb-") }
      File.rename(staging, destination)
      staging = nil
      {"status" => "built", "revision" => revision, "sheet" => File.join(destination, "sheet.html"),
       "sheetSha256" => record.fetch("sheetSha256"),
       "violations" => checks.select { |_, check| !check.fetch("passed") }.keys}
    ensure
      FileUtils.rm_rf(staging) if staging
    end
  end

  def read_regular(path, label)
    fail!("#{label} must be a regular file: #{path}") unless File.file?(path) && !File.symlink?(path)
    File.binread(path)
  end

  def validate_spec(spec, base)
    fail!("pattern definition must be an object") unless spec.is_a?(Hash)
    allowed = %w[schemaVersion kind app title brief patterns]
    allowed += %w[brand research captures headlineLimits] if spec["kind"] == "proposal"
    extra = spec.keys - allowed
    fail!("unknown pattern definition field: #{extra.first}") unless extra.empty?
    fail!("pattern definition schemaVersion must be #{SCHEMA_VERSION}") unless spec["schemaVersion"] == SCHEMA_VERSION
    fail!("kind must be one of #{SHEET_KINDS.join(', ')}") unless SHEET_KINDS.include?(spec["kind"])
    %w[app title].each { |key| text!(spec[key], key, required: true) }
    text!(spec["brief"], "brief", required: false)
    patterns = spec["patterns"]
    fail!("patterns must be a non-empty array") unless patterns.is_a?(Array) && !patterns.empty?
    if spec["kind"] == "proposal" && !PROPOSAL_PATTERNS.cover?(patterns.length)
      fail!("a proposal compares three to six patterns; found #{patterns.length}")
    end
    if spec["kind"] == "storyboard" && patterns.length != STORYBOARD_COUNT
      fail!("a storyboard sheet compares exactly #{STORYBOARD_COUNT} storyboards; found #{patterns.length}")
    end
    ids = patterns.map { |pattern| pattern.is_a?(Hash) ? pattern["id"] : nil }
    fail!("pattern ids must be unique") unless ids.uniq.length == ids.length
    if spec["kind"] == "proposal"
      # The identity and the research come first: every pattern is checked against them.
      fail!("a proposal needs brand: the path of goldie/brand.json") unless spec["brand"].is_a?(String) && !spec["brand"].empty?
      fail!("a proposal needs research: the path of its research record") unless spec["research"].is_a?(String) && !spec["research"].empty?
      unless spec["captures"].is_a?(String) && !spec["captures"].empty?
        fail!("a proposal needs captures: the path of the Goldie raw manifest of the real captures")
      end
      brand_record = load_json(File.expand_path(spec["brand"], base), "brand record")
      brand = validate_brand(brand_record.fetch("value"))
      captures_record = load_json(File.expand_path(spec["captures"], base), "capture manifest")
      verify_screens!(brand, capture_inventory(captures_record))
      research_record = load_json(File.expand_path(spec["research"], base), "research record")
      research = validate_research(research_record.fetch("value"))
      spec = spec.merge("brandRecord" => brand_record.merge("value" => brand), "capturesRecord" => captures_record,
                        "researchRecord" => research_record.merge("value" => research),
                        "headlineLimits" => headline_limits(spec["headlineLimits"]))
    end
    validated = patterns.map { |pattern| validate_pattern(pattern, base, spec["kind"], spec) }
    if spec["kind"] == "proposal"
      # Every pattern fills the same number of store slots, the tile count fixed in the brief, so a
      # combination can be checked for completeness against it.
      counts = validated.map { |pattern| pattern.fetch("tiles").length }.uniq
      fail!("proposal patterns must all have the same number of tiles; found #{counts.sort.join(', ')}") unless counts.length == 1
      recommended = validated.select { |pattern| pattern.fetch("recommended") }
      fail!("a proposal recommends exactly one pattern; found #{recommended.length}") unless recommended.length == 1
      diversity!(validated)
    end
    if spec["kind"] == "storyboard"
      # Both storyboards plan the same preview: one device and locale.
      targets = validated.map { |pattern| pattern.fetch("tiles").map { |tile| tile.values_at("device", "locale") }.uniq }.uniq
      fail!("both storyboards must use the same device and locale") unless targets.length == 1
    end
    spec.merge("patterns" => validated)
  end

  def validate_pattern(pattern, base, kind, spec)
    fail!("each pattern must be an object") unless pattern.is_a?(Hash)
    allowed = %w[id title hypothesis tradeoffs tiles]
    allowed += %w[recommended recommendation style techniques] if kind == "proposal"
    extra = pattern.keys - allowed
    fail!("unknown pattern field: #{extra.first}") unless extra.empty?
    id = pattern["id"]
    fail!("pattern id is invalid: #{id.inspect}") unless id.is_a?(String) && id.match?(ID_PATTERN)
    %w[title hypothesis tradeoffs].each { |key| text!(pattern[key], "#{id}.#{key}", required: true) }
    if kind == "proposal"
      pattern = validate_proposal_pattern(pattern, base, spec)
    end
    tiles = pattern["tiles"]
    fail!("pattern #{id} needs tiles") unless tiles.is_a?(Array) && !tiles.empty?
    validated = tiles.map { |tile| validate_tile(tile, base, id, kind, spec) }
    groups = validated.group_by { |tile| [tile.fetch("device"), tile.fetch("locale")] }
    groups.each do |(device, locale), group|
      slots = group.map { |tile| tile.fetch("slot") }
      unless slots == (1..group.length).to_a
        fail!("pattern #{id} #{device} #{locale} slots must run 1..#{group.length} in order")
      end
    end
    if kind == "proposal" && groups.keys != [%w[iphone ja]]
      fail!("a proposal shows only Japanese iPhone tiles; pattern #{id} has #{groups.keys.map { |key| key.join('/') }.join(', ')}")
    end
    fail!("storyboard #{id} must use one device and locale") if kind == "storyboard" && groups.length != 1
    pattern.merge("tiles" => validated)
  end

  def validate_tile(tile, base, id, kind, spec)
    fail!("each tile of #{id} must be an object") unless tile.is_a?(Hash)
    allowed = kind == "storyboard" ? %w[slot device locale image caption state seconds motion] : %w[slot kind device locale image caption]
    allowed += %w[highlight layout background headlines decorations] if kind == "proposal"
    extra = tile.keys - allowed
    fail!("unknown tile field in #{id}: #{extra.first}") unless extra.empty?
    fail!("tile slot of #{id} must be a positive integer") unless tile["slot"].is_a?(Integer) && tile["slot"].positive?
    if kind == "storyboard"
      # A storyboard frame is a still of one recorded segment: its states.json state, seconds and motion.
      fail!("storyboard frame state of #{id} is invalid") unless tile["state"].is_a?(String) && tile["state"].match?(STATE_PATTERN)
      fail!("storyboard frame seconds of #{id} must be an integer from 1 to 30") unless tile["seconds"].is_a?(Integer) && (1..30).cover?(tile["seconds"])
      text!(tile["motion"], "#{id}.motion", required: false)
      tile = tile.merge("kind" => "frame")
    else
      fail!("tile kind of #{id} must be one of #{TILE_KINDS.join(', ')}") unless TILE_KINDS.include?(tile["kind"])
    end
    fail!("tile device of #{id} must be iphone or ipad") unless DEVICES.include?(tile["device"])
    fail!("tile locale of #{id} must be ja or en-US") unless LOCALES.include?(tile["locale"])
    text!(tile["caption"], "#{id}.caption", required: false)
    image = tile["image"]
    fail!("tile image of #{id} must be a path") unless image.is_a?(String) && !image.empty?
    source = File.expand_path(image, base)
    validate_proposal_tile(tile, id, spec) if kind == "proposal"
    tile.merge("source" => source)
  end

  # --- D-085 identity, style and research ------------------------------------------------------------

  def load_json(path, label)
    bytes = read_regular(path, label)
    {"path" => path, "sha256" => "sha256:#{Digest::SHA256.hexdigest(bytes)}", "value" => JSON.parse(bytes)}
  end

  def object!(value, label, required, optional = [])
    fail!("#{label} must be an object") unless value.is_a?(Hash)
    missing = required.reject { |key| value.key?(key) }
    fail!("#{label} is missing: #{missing.join(', ')}") unless missing.empty?
    extra = value.keys - required - optional
    fail!("unknown #{label} field: #{extra.first}") unless extra.empty?
    value
  end

  def list!(value, label, range = (1..50))
    fail!("#{label} must be a list of #{range.min} to #{range.max} entries") unless value.is_a?(Array) && range.cover?(value.length)
    value
  end

  def texts!(value, label, range = (1..50))
    list!(value, label, range).each_with_index { |text, index| text!(text, "#{label}[#{index}]", required: true) }
  end

  def token!(value, label)
    fail!("#{label} must be lowercase letters, digits and hyphens") unless value.is_a?(String) && value.match?(TOKEN_PATTERN)
    value
  end

  def hex!(value, label)
    fail!("#{label} must be a #RRGGBB color") unless value.is_a?(String) && value.match?(HEX_PATTERN)
    value.upcase
  end

  # goldie/brand.json: what the app is good at, for whom and where, the world and story the set tells,
  # and the colors, fonts, voice and motifs every pattern starts from.
  def validate_brand(brand)
    object!(brand, "brand.json", %w[schemaVersion app strengths audience world story colors fonts voice motifs avoid])
    fail!("brand.json schemaVersion must be #{SCHEMA_VERSION}") unless brand["schemaVersion"] == SCHEMA_VERSION
    text!(brand["app"], "brand.json app", required: true)
    strengths = list!(brand["strengths"], "brand.json strengths", BRAND_STRENGTHS).map do |strength|
      object!(strength, "brand.json strength", %w[id claim feature screens])
      id = token!(strength["id"], "brand.json strength id")
      %w[claim feature].each { |key| text!(strength[key], "strength #{id} #{key}", required: true) }
      # A strength the set cannot show on a real screen would be an invented claim (D-077).
      unless strength["screens"].is_a?(Array) && !strength["screens"].empty? &&
             strength["screens"].all? { |screen| screen.is_a?(String) && screen.match?(STATE_PATTERN) }
        fail!("strength #{id} is not tied to a real screen: list the capture states that show it in screens")
      end
      strength
    end
    ids = strengths.map { |strength| strength.fetch("id") }
    fail!("brand.json strength ids must be unique") unless ids.uniq.length == ids.length
    list!(brand["audience"], "brand.json audience").each do |entry|
      object!(entry, "brand.json audience entry", %w[who scene])
      %w[who scene].each { |key| text!(entry[key], "audience #{key}", required: true) }
    end
    text!(brand["world"], "brand.json world", required: true)
    texts!(brand["story"], "brand.json story")
    colors = object!(brand["colors"], "brand.json colors", %w[accent icon palette])
    hex!(colors["accent"], "brand.json colors.accent")
    list!(colors["icon"], "brand.json colors.icon").each_with_index { |hex, index| hex!(hex, "brand.json colors.icon[#{index}]") }
    list!(colors["palette"], "brand.json colors.palette").each do |entry|
      object!(entry, "brand.json palette entry", %w[name hex use])
      token!(entry["name"], "brand.json palette name")
      hex!(entry["hex"], "brand.json palette #{entry['name']}")
      text!(entry["use"], "palette #{entry['name']} use", required: true)
    end
    list!(brand["fonts"], "brand.json fonts").each do |font|
      fail!("each brand.json font must be an object") unless font.is_a?(Hash)
      family = font["family"]
      text!(family, "brand.json font family", required: true)
      %w[source license].each do |key|
        unless font[key].is_a?(String) && !font[key].strip.empty?
          fail!("font #{family} has no #{key} record; write where it comes from and its license")
        end
      end
      object!(font, "brand.json font #{family}", %w[role family source license paid], %w[approval])
      text!(font["role"], "font #{family} role", required: true)
      %w[source license].each { |key| text!(font[key], "font #{family} #{key}", required: true) }
      fail!("font #{family} paid must be true or false") unless [true, false].include?(font["paid"])
      # A paid font is used only after the user has said so (D-085); stop and ask before using one.
      if font["paid"] && !(font["approval"].is_a?(String) && !font["approval"].strip.empty?)
        fail!("font #{family} is paid; ask the user before using it and record the approval")
      end
      text!(font["approval"], "font #{family} approval", required: false)
    end
    texts!(brand["voice"], "brand.json voice", BRAND_VOICE)
    texts!(brand["motifs"], "brand.json motifs")
    texts!(brand["avoid"], "brand.json avoid")
    brand
  end

  # The capture inventory is the Goldie raw manifest (`goldie/<locale>/out/raw/<device>/manifest.json`)
  # of the real captures: every scene ID names one PNG or JPEG. A relative file resolves against the
  # manifest.
  def capture_inventory(record)
    manifest = record.fetch("value")
    unless manifest.is_a?(Hash) && manifest["screenshots"].is_a?(Array) && !manifest["screenshots"].empty?
      fail!("capture manifest must be an object with screenshots")
    end
    base = File.dirname(record.fetch("path"))
    manifest["screenshots"].each_with_object({}) do |entry, inventory|
      scene = entry.is_a?(Hash) ? entry["sceneId"] : nil
      fail!("capture manifest scene IDs must be lowercase letters, digits and hyphens") unless scene.is_a?(String) && scene.match?(STATE_PATTERN)
      fail!("capture manifest lists #{scene} twice") if inventory.key?(scene)
      file = entry["file"]
      fail!("capture #{scene} has no file") unless file.is_a?(String) && !file.empty?
      inventory[scene] = File.expand_path(file, base)
    end
  end

  # A strength is tied to a real screen only when every screen it names is a scene of the capture
  # inventory whose file is a real image; an invented name is refused even next to a real one.
  def verify_screens!(brand, inventory)
    brand.fetch("strengths").each do |strength|
      strength.fetch("screens").each do |screen|
        path = inventory[screen]
        unless path
          fail!("strength #{strength.fetch('id')} names the screen #{screen}, which has no real capture in the capture manifest")
        end
        bytes = File.file?(path) && !File.symlink?(path) ? File.binread(path, 8) : nil
        unless bytes && (bytes.start_with?("\x89PNG\r\n\x1A\n".b) || bytes.start_with?("\xFF\xD8\xFF".b))
          fail!("capture #{screen} is not a real image: #{path}")
        end
      end
    end
  end

  def brand_colors(brand)
    colors = brand.fetch("colors")
    ([colors.fetch("accent")] + colors.fetch("icon") + colors.fetch("palette").map { |entry| entry.fetch("hex") }).map(&:upcase).uniq
  end

  # A style spec fixes one pattern's look: color tokens, fonts, typesetting, its signature element, the
  # decoration limit, how anything crosses tiles, the voice and the conditions that make it a failure.
  # Colors and fonts come from brand.json; any other one needs a deviation with its reason.
  def validate_style(style, brand, label)
    object!(style, label, %w[schemaVersion id name signature tokens fonts typesetting decorationLimit crossScreen voice failures],
            %w[deviations])
    fail!("#{label} schemaVersion must be #{SCHEMA_VERSION}") unless style["schemaVersion"] == SCHEMA_VERSION
    fail!("#{label} id is invalid") unless style["id"].is_a?(String) && style["id"].match?(ID_PATTERN)
    %w[name signature typesetting crossScreen].each { |key| text!(style[key], "#{label} #{key}", required: true) }
    tokens = list!(style["tokens"], "#{label} tokens", (2..12)).map do |entry|
      object!(entry, "#{label} token", %w[name hex use])
      token!(entry["name"], "#{label} token name")
      text!(entry["use"], "#{label} token #{entry['name']} use", required: true)
      hex!(entry["hex"], "#{label} token #{entry['name']}")
    end
    fonts = object!(style["fonts"], "#{label} fonts", %w[headline], %w[body])
    fonts.each { |role, family| text!(family, "#{label} #{role} font", required: true) }
    limit = style["decorationLimit"]
    fail!("#{label} decorationLimit must be an integer from 0 to 10") unless limit.is_a?(Integer) && (0..10).cover?(limit)
    texts!(style["voice"], "#{label} voice")
    texts!(style["failures"], "#{label} failures")
    deviations = style.fetch("deviations", [])
    fail!("#{label} deviations must be a list") unless deviations.is_a?(Array)
    deviations.each do |entry|
      object!(entry, "#{label} deviation", %w[item reason])
      %w[item reason].each { |key| text!(entry[key], "#{label} deviation #{key}", required: true) }
    end
    explained = deviations.map { |entry| entry.fetch("item").strip.upcase }
    palette = brand_colors(brand)
    tokens.uniq.each do |hex|
      next if palette.include?(hex) || explained.include?(hex)
      fail!("#{label} uses #{hex} outside brand.json without a reason; add a deviation for it")
    end
    families = brand.fetch("fonts").map { |font| font.fetch("family").strip.upcase }
    fonts.values.uniq.each do |family|
      next if families.include?(family.strip.upcase) || explained.include?(family.strip.upcase)
      fail!("#{label} uses the font #{family} outside brand.json without a reason; add a deviation for it")
    end
    style
  end

  # The research record lists the reference apps looked at for this proposal and the techniques taken
  # from each. Only techniques are taken; designs, illustrations, copy and logos are never copied.
  def validate_research(research)
    object!(research, "research record", %w[schemaVersion category checkedOn references])
    fail!("research record schemaVersion must be #{SCHEMA_VERSION}") unless research["schemaVersion"] == SCHEMA_VERSION
    text!(research["category"], "research category", required: true)
    unless research["checkedOn"].is_a?(String) && research["checkedOn"].match?(DATE_PATTERN)
      fail!("research checkedOn must be a YYYY-MM-DD date")
    end
    references = list!(research["references"], "research references", RESEARCH_REFERENCES)
    references.each do |entry|
      object!(entry, "research reference", %w[id app site url techniques], %w[notes])
      token!(entry["id"], "research reference id")
      %w[app site].each { |key| text!(entry[key], "research #{entry['id']} #{key}", required: true) }
      # The URL stays in the record for the user; the sheet never shows it, so the page cannot link out.
      unless entry["url"].is_a?(String) && entry["url"].match?(%r{\Ahttps://[^\s<>"']+\z}) && entry["url"].length <= 500
        fail!("research #{entry['id']} url must be an https URL")
      end
      list!(entry["techniques"], "research #{entry['id']} techniques").each { |technique| token!(technique, "research technique") }
      text!(entry["notes"], "research #{entry['id']} notes", required: false)
    end
    ids = references.map { |entry| entry.fetch("id") }
    fail!("research reference ids must be unique") unless ids.uniq.length == ids.length
    research
  end

  def headline_limits(value)
    return DEFAULT_HEADLINE_LIMITS if value.nil?
    object!(value, "headlineLimits", LOCALES)
    LOCALES.to_h do |locale|
      limit = value[locale]
      fail!("headlineLimits #{locale} must be an integer from 4 to 80") unless limit.is_a?(Integer) && (4..80).cover?(limit)
      [locale, limit]
    end
  end

  def validate_proposal_pattern(pattern, base, spec)
    id = pattern.fetch("id")
    fail!("pattern #{id} recommended must be true or false") unless [true, false].include?(pattern["recommended"])
    if pattern["recommended"]
      text!(pattern["recommendation"], "#{id}.recommendation", required: true)
    elsif pattern.key?("recommendation")
      fail!("pattern #{id} is not recommended but carries a recommendation")
    end
    fail!("pattern #{id} needs style: the path of its style spec") unless pattern["style"].is_a?(String) && !pattern["style"].empty?
    style_record = load_json(File.expand_path(pattern["style"], base), "style spec of #{id}")
    style = validate_style(style_record.fetch("value"), spec.fetch("brandRecord").fetch("value"), "style spec of #{id}")
    known = spec.fetch("researchRecord").fetch("value").fetch("references").flat_map { |entry| entry.fetch("techniques") }
    techniques = pattern["techniques"]
    unless techniques.is_a?(Array) && !techniques.empty?
      fail!("pattern #{id} needs techniques taken from the research record")
    end
    techniques.each do |technique|
      token!(technique, "pattern #{id} technique")
      fail!("pattern #{id} uses technique #{technique} that the research record does not list") unless known.include?(technique)
    end
    pattern.merge("styleRecord" => style_record.merge("value" => style))
  end

  def validate_proposal_tile(tile, id, spec)
    strengths = spec.fetch("brandRecord").fetch("value").fetch("strengths").map { |strength| strength.fetch("id") }
    highlight = token!(tile["highlight"], "tile #{tile['slot']} highlight of #{id}")
    fail!("tile #{tile['slot']} of #{id} highlights #{highlight}, which is not a brand.json strength") unless strengths.include?(highlight)
    token!(tile["layout"], "tile #{tile['slot']} layout of #{id}")
    token!(tile["background"], "tile #{tile['slot']} background of #{id}")
    headlines = object!(tile["headlines"], "tile #{tile['slot']} headlines of #{id}", LOCALES)
    LOCALES.each do |locale|
      texts!(headlines[locale], "tile #{tile['slot']} #{locale} headlines of #{id}", (MIN_HEADLINES..6))
    end
    decorations = tile["decorations"]
    unless decorations.nil? || (decorations.is_a?(Integer) && (0..20).cover?(decorations))
      fail!("tile #{tile['slot']} decorations of #{id} must be an integer from 0 to 20")
    end
  end

  # Two patterns that share a signature element, or that use the same layouts and backgrounds in the
  # same order, are one pattern shown twice; the proposal is refused rather than marked.
  def diversity!(patterns)
    normalize = ->(text) { text.downcase.gsub(/[[:space:][:punct:]、。・「」]/, "") }
    patterns.combination(2).each do |left, right|
      a = left.fetch("id")
      b = right.fetch("id")
      if normalize.(left.fetch("styleRecord").fetch("value").fetch("signature")) ==
         normalize.(right.fetch("styleRecord").fetch("value").fetch("signature"))
        fail!("patterns #{a} and #{b} share the signature element; give each pattern its own")
      end
      sequence = ->(pattern) { pattern.fetch("tiles").sort_by { |tile| tile.fetch("slot") }.map { |tile| tile.values_at("layout", "background") } }
      if sequence.(left) == sequence.(right)
        fail!("patterns #{a} and #{b} use the same layouts and backgrounds in the same order")
      end
    end
  end

  # Marks are shown on the sheet but do not stop a choice: a layout repeated on three or more adjacent
  # tiles, one strength shown on two tiles, a headline candidate longer than the guide, and more
  # decorations than the pattern's style spec allows.
  def proposal_marks(pattern, spec)
    return [] unless spec.fetch("kind") == "proposal"
    tiles = pattern.fetch("tiles").sort_by { |tile| tile.fetch("slot") }
    marks = []
    tiles.chunk_while { |left, right| left.fetch("layout") == right.fetch("layout") }.each do |run|
      next if run.length < LAYOUT_RUN_MARK
      marks << "tiles #{run.first.fetch('slot')}-#{run.last.fetch('slot')} repeat the layout #{run.first.fetch('layout')}"
    end
    tiles.group_by { |tile| tile.fetch("highlight") }.each do |highlight, group|
      next if group.length < 2
      marks << "tiles #{group.map { |tile| tile.fetch('slot') }.join(', ')} show the same strength #{highlight}"
    end
    limits = spec.fetch("headlineLimits")
    tiles.each do |tile|
      LOCALES.each do |locale|
        tile.fetch("headlines").fetch(locale).each_with_index do |headline, index|
          length = headline_length(headline, locale)
          next if length <= limits.fetch(locale)
          marks << "tile #{tile.fetch('slot')} #{locale} headline #{index + 1} is #{length} characters; the guide is #{limits.fetch(locale)}"
        end
      end
      limit = pattern.fetch("styleRecord").fetch("value").fetch("decorationLimit")
      if tile["decorations"] && tile["decorations"] > limit
        marks << "tile #{tile.fetch('slot')} has #{tile['decorations']} decorations; the style spec allows #{limit}"
      end
    end
    marks
  end

  def headline_length(text, locale)
    locale == "ja" ? text.gsub(/\s/, "").length : text.gsub(/\s+/, " ").strip.length
  end

  # --- check ---------------------------------------------------------------------------------------

  def check(options)
    require_options(options, "brand", "captures")
    unknown = options.keys - %w[brand captures style]
    fail!("unknown option: --#{unknown.first}") unless unknown.empty?
    brand_record = load_json(File.expand_path(options.fetch("brand")), "brand record")
    brand = validate_brand(brand_record.fetch("value"))
    captures_record = load_json(File.expand_path(options.fetch("captures")), "capture manifest")
    verify_screens!(brand, capture_inventory(captures_record))
    value = {"status" => "valid", "brandSha256" => brand_record.fetch("sha256"), "capturesSha256" => captures_record.fetch("sha256"),
             "strengths" => brand.fetch("strengths").map { |strength| strength.fetch("id") }}
    if options.key?("style")
      style_record = load_json(File.expand_path(options.fetch("style")), "style spec")
      validate_style(style_record.fetch("value"), brand, "style spec")
      value["styleSha256"] = style_record.fetch("sha256")
    end
    value
  end

  def text!(value, label, required:)
    return if value.nil? && !required
    fail!("#{label} must be text") unless value.is_a?(String) && !value.strip.empty?
    fail!("#{label} is longer than #{TEXT_LIMIT} characters") if value.length > TEXT_LIMIT
    fail!("#{label} must not contain URLs, markup, or style imports") if value.match?(FORBIDDEN_TEXT)
    fail!("#{label} contains a control character") if value.match?(/[\u0000-\u0008\u000b-\u001f\u007f]/)
  end

  # D-077 tile rules, per device and locale sequence: the first three tiles show the app in use, a set
  # has at most two concept tiles and no more than a third of its tiles, and Japanese and English use
  # the same tile kinds in the same order.
  def rule_check(tiles, kind)
    return storyboard_check(tiles) if kind == "storyboard"
    violations = []
    sequences = tiles.group_by { |tile| [tile.fetch("device"), tile.fetch("locale")] }
    sequences.each do |(device, locale), group|
      kinds = group.sort_by { |tile| tile.fetch("slot") }.map { |tile| tile.fetch("kind") }
      label = "#{device}/#{locale}"
      early = kinds.first(FIRST_TILES_WITH_APP).each_index.select { |index| kinds[index] == "concept" }
      unless early.empty?
        violations << "#{label}: tile #{early.map { |index| index + 1 }.join(', ')} is concept; the first #{FIRST_TILES_WITH_APP} tiles must show the app"
      end
      concept = kinds.count("concept")
      violations << "#{label}: #{concept} concept tiles; at most #{MAX_CONCEPT_TILES} are allowed" if concept > MAX_CONCEPT_TILES
      violations << "#{label}: #{concept} of #{kinds.length} tiles are concept; at most a third is allowed" if concept * 3 > kinds.length
    end
    parity = "not-applicable"
    if kind == "preview"
      DEVICES.each do |device|
        ja = sequences[[device, "ja"]]&.sort_by { |tile| tile.fetch("slot") }&.map { |tile| tile.fetch("kind") }
        en = sequences[[device, "en-US"]]&.sort_by { |tile| tile.fetch("slot") }&.map { |tile| tile.fetch("kind") }
        next if ja.nil? && en.nil?
        if ja.nil? || en.nil?
          violations << "#{device}: Japanese and English tiles must both be present"
        elsif ja != en
          violations << "#{device}: Japanese and English tiles must use the same kinds in the same order"
        end
      end
      parity = violations.any? { |message| message.include?("Japanese and English") } ? "failed" : "passed"
    end
    {"passed" => violations.empty?, "localeParity" => parity, "violations" => violations}
  end

  # A storyboard becomes one App Store preview, which runs 15 to 30 seconds.
  def storyboard_check(tiles)
    total = tiles.sum { |tile| tile.fetch("seconds") }
    violations = []
    unless PREVIEW_SECONDS.cover?(total)
      violations << "storyboard runs #{total}s; a preview must run #{PREVIEW_SECONDS.min} to #{PREVIEW_SECONDS.max} seconds"
    end
    {"passed" => violations.empty?, "localeParity" => "not-applicable", "totalSeconds" => total, "violations" => violations}
  end

  # What the page shows of a tile and a selection is checked against: a storyboard frame also carries
  # its state and seconds, so the 15-to-30-second rule is checked again from the displayed page.
  def display_tile(tile, kind)
    tile.slice(*(kind == "storyboard" ? %w[slot kind device locale state seconds] : %w[slot kind device locale]))
  end

  def embed_image(source, max_dimension, staging)
    bytes = read_regular(source, "tile image")
    type = if bytes.start_with?("\x89PNG\r\n\x1A\n".b) then "png"
           elsif bytes.start_with?("\xFF\xD8\xFF".b) then "jpeg"
           else fail!("tile image must be PNG or JPEG: #{source}")
           end
    thumbnail = File.join(staging, ".thumb-#{Digest::SHA256.hexdigest(source)}.#{type == 'png' ? 'png' : 'jpg'}")
    output, status = Open3.capture2e("/usr/bin/sips", "-Z", max_dimension.to_s, source, "--out", thumbnail)
    fail!("could not make a sheet thumbnail for #{source}: #{output.lines.last&.strip}") unless status.success? && File.file?(thumbnail)
    data = File.binread(thumbnail)
    {"sha256" => "sha256:#{Digest::SHA256.hexdigest(bytes)}",
     "dataUri" => "data:image/#{type};base64,#{Base64.strict_encode64(data)}"}
  end

  def display_record(spec, revision)
    {"schemaVersion" => SCHEMA_VERSION, "revision" => revision, "kind" => spec.fetch("kind"),
     "patterns" => spec.fetch("patterns").map do |pattern|
       {"id" => pattern.fetch("id"),
        "tiles" => pattern.fetch("tiles").map { |tile| display_tile(tile, spec.fetch("kind")) }}
     end}
  end

  def swatches(hexes)
    hexes.map { |hex| %(<span class="swatch" style="background:#{hex}" title="#{hex}"></span>) }.join
  end

  def brand_section(spec, h)
    brand = spec.fetch("brandRecord").fetch("value")
    list = ->(items) { "<ul>#{items.map { |item| "<li>#{h.(item)}</li>" }.join}</ul>" }
    strengths = brand.fetch("strengths").map do |strength|
      "<li><code>#{h.(strength.fetch('id'))}</code> #{h.(strength.fetch('claim'))}（#{h.(strength.fetch('feature'))}・" \
        "#{h.(strength.fetch('screens').join(', '))}）</li>"
    end.join
    fonts = brand.fetch("fonts").map do |font|
      "<li>#{h.(font.fetch('role'))}: #{h.(font.fetch('family'))}（#{h.(font.fetch('source'))}・#{h.(font.fetch('license'))}" \
        "#{font.fetch('paid') ? '・有料、承認済み' : ''}）</li>"
    end.join
    audience = brand.fetch("audience").map { |entry| "#{entry.fetch('who')}：#{entry.fetch('scene')}" }
    research = spec.fetch("researchRecord").fetch("value")
    references = research.fetch("references").map do |entry|
      "<li>#{h.(entry.fetch('app'))}（#{h.(entry.fetch('site'))}）：#{entry.fetch('techniques').map { |technique| "<code>#{h.(technique)}</code>" }.join(' ')}" \
        "#{entry['notes'] ? " #{h.(entry['notes'])}" : ''}</li>"
    end.join
    <<~SECTION
      <section class="brand">
      <h2>個性の正本（brand.json）</h2>
      <dl>
      <dt>強み</dt><dd><ul>#{strengths}</ul></dd>
      <dt>使う人と場面</dt><dd>#{list.(audience)}</dd>
      <dt>世界観</dt><dd>#{h.(brand.fetch('world'))}</dd>
      <dt>物語の筋</dt><dd><ol>#{brand.fetch('story').map { |item| "<li>#{h.(item)}</li>" }.join}</ol></dd>
      <dt>色</dt><dd>#{swatches(brand_colors(brand))}</dd>
      <dt>字体</dt><dd><ul>#{fonts}</ul></dd>
      <dt>言葉の調子</dt><dd>#{h.(brand.fetch('voice').join('・'))}</dd>
      <dt>モチーフ</dt><dd>#{h.(brand.fetch('motifs').join('・'))}</dd>
      <dt>避けるもの</dt><dd>#{h.(brand.fetch('avoid').join('・'))}</dd>
      </dl>
      <h2>参考の調査（#{h.(research.fetch('category'))}、#{h.(research.fetch('checkedOn'))}）</h2>
      <p class="meta">見たアプリから抜き出した手法だけを使い、デザイン、イラスト、文言、ロゴは写していません。</p>
      <ul>#{references}</ul>
      </section>
    SECTION
  end

  def style_block(pattern, h)
    style = pattern.fetch("styleRecord").fetch("value")
    deviations = style.fetch("deviations", []).map { |entry| "<li>#{h.(entry.fetch('item'))}：#{h.(entry.fetch('reason'))}</li>" }.join
    fonts = style.fetch("fonts").map { |role, family| "#{role}: #{family}" }.join("、")
    <<~BLOCK
      <details class="style" open><summary>スタイル仕様：#{h.(style.fetch('name'))}</summary>
      <dl>
      <dt>決め手</dt><dd>#{h.(style.fetch('signature'))}</dd>
      <dt>色</dt><dd>#{swatches(style.fetch('tokens').map { |entry| entry.fetch('hex').upcase })}</dd>
      <dt>字体</dt><dd>#{h.(fonts)}</dd>
      <dt>組み方</dt><dd>#{h.(style.fetch('typesetting'))}</dd>
      <dt>装飾</dt><dd>1面に#{style.fetch('decorationLimit')}個まで</dd>
      <dt>面をまたぐ</dt><dd>#{h.(style.fetch('crossScreen'))}</dd>
      <dt>調子</dt><dd>#{h.(style.fetch('voice').join('・'))}</dd>
      <dt>失敗条件</dt><dd><ul>#{style.fetch('failures').map { |item| "<li>#{h.(item)}</li>" }.join}</ul></dd>
      #{deviations.empty? ? '' : "<dt>正本から外れる点</dt><dd><ul>#{deviations}</ul></dd>"}
      <dt>使う手法</dt><dd>#{pattern.fetch('techniques').map { |technique| "<code>#{h.(technique)}</code>" }.join(' ')}</dd>
      </dl>
      </details>
    BLOCK
  end

  def render_html(spec, revision, images, checks, record, marks = {})
    h = ->(text) { CGI.escapeHTML(text.to_s) }
    proposal = spec.fetch("kind") == "proposal"
    strengths = proposal ? spec.fetch("brandRecord").fetch("value").fetch("strengths").to_h { |strength| [strength.fetch("id"), strength.fetch("claim")] } : {}
    limits = proposal ? spec.fetch("headlineLimits") : {}
    stage = {"proposal" => "第1段階：パターンの比較", "preview" => "第2段階：選んだパターンの見本",
             "storyboard" => "プレビュー動画の絵コンテ"}.fetch(spec.fetch("kind"))
    instruction = if spec.fetch("kind") == "storyboard"
                    "絵コンテのIDを1つ選んでください。"
                  elsif proposal
                    "パターンIDを1つ選ぶか、面ごとにどのパターンの何枚目を使うかを指定してください。「おすすめ」はClaudeまたはCodexがいちばん良いと考えた案です。" \
                      "見出しは仮の文言で、ASOガイドの方針に合わせて直します。"
                  else
                    "パターンIDを1つ選ぶか、面ごとにどのパターンの何枚目を使うかを指定してください。"
                  end
    sections = spec.fetch("patterns").map do |pattern|
      check = checks.fetch(pattern.fetch("id"))
      total = check["totalSeconds"] ? "（合計#{check.fetch('totalSeconds')}秒）" : ""
      status = if check.fetch("passed")
                 %(<p class="check ok">ルール：すべて満たしています#{total}</p>)
               else
                 items = check.fetch("violations").map { |message| "<li>#{h.(message)}</li>" }.join
                 %(<div class="check ng"><p>ルール違反があります（このパターンは選べません）#{total}</p><ul>#{items}</ul></div>)
               end
      pattern_marks = marks.fetch(pattern.fetch("id"), [])
      unless pattern_marks.empty?
        status += %(<div class="check mark"><p>注意（選ぶことはできます）</p><ul>#{pattern_marks.map { |message| "<li>#{h.(message)}</li>" }.join}</ul></div>)
      end
      recommendation = ""
      if proposal && pattern.fetch("recommended")
        recommendation = %(<p class="recommend"><span class="badge rec">おすすめ</span> #{h.(pattern.fetch('recommendation'))}</p>)
      end
      style = proposal ? style_block(pattern, h) : ""
      groups = pattern.fetch("tiles").group_by { |tile| [tile.fetch("device"), tile.fetch("locale")] }
      strips = groups.map do |(device, locale), tiles|
        figures = tiles.sort_by { |tile| tile.fetch("slot") }.map do |tile|
          caption = tile["caption"] ? "<span>#{h.(tile['caption'])}</span>" : ""
          if tile.fetch("kind") == "frame"
            caption += "<span>#{h.(tile.fetch('state'))} ・ #{tile.fetch('seconds')}秒</span>"
            caption += "<span>#{h.(tile['motion'])}</span>" if tile["motion"]
          end
          if proposal
            caption += "<span>強み：#{h.(strengths.fetch(tile.fetch('highlight')))}</span>"
            caption += "<span>#{h.(tile.fetch('layout'))} ・ #{h.(tile.fetch('background'))}</span>"
            LOCALES.each do |headline_locale|
              items = tile.fetch("headlines").fetch(headline_locale).map do |headline|
                over = headline_length(headline, headline_locale) > limits.fetch(headline_locale) ? %( class="long") : ""
                "<li#{over}>#{h.(headline)}</li>"
              end.join
              caption += %(<span class="headlines">#{h.(headline_locale)}<ul>#{items}</ul></span>)
            end
          end
          %(<figure class="tile #{h.(device)}"><img src="#{images.fetch(tile.fetch('source')).fetch('dataUri')}" ) +
            %(alt="#{h.(pattern.fetch('id'))} #{tile.fetch('slot')}"><figcaption><b>#{tile.fetch('slot')}</b> ) +
            %(<code>#{h.(tile.fetch('kind'))}</code>#{caption}</figcaption></figure>)
        end.join
        %(<h3>#{h.(device == 'iphone' ? 'iPhone' : 'iPad')} / #{h.(locale)}</h3><div class="strip">#{figures}</div>)
      end.join
      <<~SECTION
        <section class="pattern" id="pattern-#{h.(pattern.fetch('id'))}">
        <h2><span class="badge">#{h.(pattern.fetch('id'))}</span> #{h.(pattern.fetch('title'))}</h2>
        #{recommendation}
        <dl><dt>狙い</dt><dd>#{h.(pattern.fetch('hypothesis'))}</dd><dt>弱点</dt><dd>#{h.(pattern.fetch('tradeoffs'))}</dd></dl>
        #{status}
        #{style}
        #{strips}
        </section>
      SECTION
    end.join
    sections = brand_section(spec, h) + sections if proposal
    brief = spec["brief"] ? %(<p class="brief">#{h.(spec['brief'])}</p>) : ""
    <<~HTML
      <!doctype html>
      <html lang="ja">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="#{CONTENT_SECURITY_POLICY}">
      <meta name="#{DISPLAY_RECORD_META}" content="#{Base64.strict_encode64(JSON.generate(record))}">
      <title>#{h.(spec.fetch('title'))}</title>
      <style>
      :root { color-scheme: light dark; --bg: #f6f5f2; --fg: #1d1d1f; --muted: #5b5b60; --card: #ffffff; --line: #d9d7d2; --ok: #1f7a3d; --ng: #b3261e; }
      @media (prefers-color-scheme: dark) { :root { --bg: #161618; --fg: #f2f2f4; --muted: #a8a8ae; --card: #212124; --line: #3a3a3e; --ok: #6fd18d; --ng: #ff8a80; } }
      body { margin: 0; padding: 24px 16px 48px; background: var(--bg); color: var(--fg); font: 15px/1.6 -apple-system, "Hiragino Sans", sans-serif; }
      header, section { max-width: 1200px; margin: 0 auto 24px; }
      .meta { color: var(--muted); font-size: 13px; }
      .brief { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 12px 16px; }
      .pattern { background: var(--card); border: 1px solid var(--line); border-radius: 16px; padding: 16px; }
      .badge { display: inline-block; min-width: 2em; text-align: center; border-radius: 8px; background: var(--fg); color: var(--bg); padding: 0 8px; }
      dl { display: grid; grid-template-columns: max-content 1fr; gap: 4px 12px; } dt { color: var(--muted); }
      .check.ok { color: var(--ok); } .check.ng { color: var(--ng); }
      .strip { display: flex; gap: 12px; overflow-x: auto; padding-bottom: 8px; }
      .tile { margin: 0; flex: 0 0 auto; } .tile.iphone img { width: 180px; } .tile.ipad img { width: 260px; }
      .tile img { display: block; height: auto; border-radius: 10px; border: 1px solid var(--line); }
      figcaption { font-size: 12px; color: var(--muted); max-width: 260px; } figcaption span { display: block; }
      .brand { background: var(--card); border: 1px solid var(--line); border-radius: 16px; padding: 16px; }
      .check.mark { color: var(--muted); } .recommend { font-weight: 600; } .badge.rec { background: var(--ok); }
      .swatch { display: inline-block; width: 20px; height: 20px; border-radius: 4px; border: 1px solid var(--line); margin-right: 4px; vertical-align: middle; }
      .headlines ul { margin: 2px 0 4px; padding-left: 16px; } .headlines li.long { color: var(--ng); }
      .style dl { margin-top: 8px; } .style summary { cursor: pointer; font-weight: 600; }
      </style>
      </head>
      <body>
      <header>
      <h1>#{h.(spec.fetch('title'))}</h1>
      <p class="meta">#{h.(spec.fetch('app'))} ・ #{h.(stage)} ・ revision #{h.(revision)}</p>
      #{brief}
      <p class="meta">#{h.(instruction)}</p>
      </header>
      #{sections}
      </body>
      </html>
    HTML
  end

  # --- select --------------------------------------------------------------------------------------

  def select(options)
    require_options(options, "sheet")
    unknown = options.keys - %w[sheet pattern tiles]
    fail!("unknown option: --#{unknown.first}") unless unknown.empty?
    fail!("give exactly one of --pattern or --tiles") unless options.key?("pattern") ^ options.key?("tiles")
    directory = File.expand_path(options.fetch("sheet"))
    record = JSON.parse(read_regular(File.join(directory, "sheet.json"), "sheet record"))
    html = read_regular(File.join(directory, "sheet.html"), "sheet")
    actual = "sha256:#{Digest::SHA256.hexdigest(html)}"
    fail!("sheet.html differs from the sheet record") unless record["sheetSha256"].is_a?(String) &&
      record["sheetSha256"].match?(DIGEST_PATTERN) && record["sheetSha256"] == actual
    target = File.join(directory, "selection.json")
    fail!("a selection is already recorded for this sheet and is never replaced") if File.exist?(target) || File.symlink?(target)
    displayed = displayed_record(html)
    listed = {"schemaVersion" => record["schemaVersion"], "revision" => record["revision"], "kind" => record["kind"],
              "patterns" => (record["patterns"] || []).map do |pattern|
                {"id" => pattern["id"], "tiles" => (pattern["tiles"] || []).map { |tile| display_tile(tile, record["kind"]) }}
              end}
    fail!("sheet.json differs from the displayed sheet") unless listed == displayed
    kind = displayed.fetch("kind")
    patterns = displayed.fetch("patterns").to_h { |pattern| [pattern.fetch("id"), pattern] }

    selection = if options.key?("pattern")
                  id = options.fetch("pattern")
                  pattern = patterns[id] or fail!("unknown pattern id: #{id}")
                  # The rules are checked again here from the displayed tiles, never read from sheet.json.
                  check = rule_check(pattern.fetch("tiles"), kind)
                  fail!("pattern #{id} breaks the tile rules: #{check.fetch('violations').join('; ')}") unless check.fetch("passed")
                  {"type" => "pattern", "patternId" => id}
                else
                  {"type" => "combination", "tiles" => combination(options.fetch("tiles"), patterns, kind)}
                end
    value = {
      "schemaVersion" => SCHEMA_VERSION,
      "revision" => record.fetch("revision"),
      "sheetSha256" => actual,
      "selection" => selection,
      "decision" => "user-explicit",
      "recordedAt" => Time.now.utc.iso8601
    }
    File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write("#{JSON.pretty_generate(value)}\n") }
    {"status" => "selected", "selection" => File.join(directory, "selection.json"), "type" => selection.fetch("type")}
  end

  def displayed_record(html)
    matches = html.scan(DISPLAY_RECORD_PATTERN)
    fail!("the sheet does not carry exactly one displayed record") unless matches.length == 1
    record = JSON.parse(Base64.strict_decode64(matches.first.first))
    fail!("the displayed record is invalid") unless record.is_a?(Hash) && record["schemaVersion"] == SCHEMA_VERSION &&
      SHEET_KINDS.include?(record["kind"]) && record["patterns"].is_a?(Array)
    if record["kind"] == "storyboard" && record["patterns"].length != STORYBOARD_COUNT
      fail!("a storyboard sheet must show exactly #{STORYBOARD_COUNT} storyboards")
    end
    record
  end

  # A combination names, for every slot of the set, the pattern and its tile slot that fills it, for
  # example "1=A:1,2=C:2,3=A:3". It must cover every slot of the set once and still meet the tile rules.
  def combination(text, patterns, kind)
    fail!("a combination applies only to a proposal sheet") unless kind == "proposal"
    entries = text.split(",").map(&:strip)
    fail!("a combination needs at least one slot") if entries.empty?
    parsed = entries.map do |entry|
      match = entry.match(/\A(\d+)=([A-Za-z0-9][A-Za-z0-9-]{0,31}):(\d+)\z/) or
        fail!("combination entry must look like 1=A:1: #{entry}")
      [Integer(match[1], 10), match[2], Integer(match[3], 10)]
    end
    slots = parsed.map(&:first)
    size = patterns.values.map { |pattern| pattern.fetch("tiles").length }.max
    unless slots.sort == (1..size).to_a
      fail!("a combination must name every slot from 1 to #{size} exactly once")
    end
    tiles = parsed.sort_by(&:first).map do |slot, id, source_slot|
      pattern = patterns[id] or fail!("unknown pattern id in combination: #{id}")
      source = pattern.fetch("tiles").find { |tile| tile.fetch("slot") == source_slot && tile.fetch("locale") == "ja" && tile.fetch("device") == "iphone" } or
        fail!("pattern #{id} has no Japanese iPhone tile #{source_slot}")
      {"slot" => slot, "patternId" => id, "sourceSlot" => source_slot, "kind" => source.fetch("kind"),
       "device" => "iphone", "locale" => "ja"}
    end
    check = rule_check(tiles, kind)
    fail!("the combination breaks the tile rules: #{check.fetch('violations').join('; ')}") unless check.fetch("passed")
    tiles.map { |tile| tile.slice("slot", "patternId", "sourceSlot", "kind") }
  end
end

AppStoreCreativeSheet.run(ARGV) if $PROGRAM_NAME == __FILE__
