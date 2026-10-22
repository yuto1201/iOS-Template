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
  # D-085 (#393): generated materials are shown on a `material` sheet and used only after the user
  # adopts each one; a cut-out material must have a transparent background and no key-color residue.
  MATERIAL_KIND = "material"
  # D-085 (#391): a header sheet compares product page header options (a 3840x1646 still, with its loop
  # video when there is one); "none" (no header) is always a valid choice.
  HEADER_KIND = "header"
  HEADER_OPTIONS = (2..6).freeze
  HEADER_SIZE = [3840, 1646].freeze
  NO_HEADER = "none"
  # D-085 (#392): a poster sheet shows candidate poster frames of one App Preview (Apple shows the frame
  # at 5 seconds unless another is chosen); the user picks one, whose time is recorded with the video.
  POSTER_KIND = "poster"
  POSTER_CANDIDATES = (1..6).freeze
  MATERIAL_COUNT = (1..60).freeze
  MATERIAL_DECISIONS = %w[adopted rejected].freeze
  CUTOUT_EDGE = 2
  CUTOUT_MIN_TRANSPARENT = 0.10
  CUTOUT_MAX_RESIDUE = 0.005
  CUTOUT_KEY_DISTANCE = 60
  # The render extension marks a record that lists every image input of every tile (D-085, #401).
  RENDER_INVENTORY = "complete-v1"
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
    command = argv.shift or fail!("command is required: build, select, review, check, cutout or provenance")
    options = parse_options(argv)
    value = case command
            when "build" then build(options)
            when "select" then select(options)
            when "check" then check(options)
            when "review" then review(options)
            when "cutout" then cutout(options)
            when "provenance" then provenance(options)
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
    parsed = JSON.parse(spec_bytes)
    root = File.expand_path(options.fetch("root"))
    if parsed.is_a?(Hash) && parsed["kind"] == MATERIAL_KIND
      return build_material(validate_material_spec(parsed, File.dirname(spec_path)), spec_bytes, root, revision, max_dimension)
    end
    if parsed.is_a?(Hash) && parsed["kind"] == HEADER_KIND
      return build_header(validate_header_spec(parsed, File.dirname(spec_path)), spec_bytes, root, revision, max_dimension)
    end
    if parsed.is_a?(Hash) && parsed["kind"] == POSTER_KIND
      return build_poster(validate_poster_spec(parsed, File.dirname(spec_path)), spec_bytes, root, revision, max_dimension)
    end
    spec = validate_spec(parsed, File.dirname(spec_path))

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
                         "techniques" => pattern.fetch("techniques"), "marks" => marks.fetch(pattern.fetch("id")),
                         "materials" => pattern.fetch("materialRecords").map { |material| material.fetch("sha256") })
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
    allowed += %w[brand research captures headlineLimits materialReviews renders] if spec["kind"] == "proposal"
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
      reviews = spec.fetch("materialReviews", [])
      fail!("materialReviews must be a list of material sheet directories") unless reviews.is_a?(Array) && reviews.all? { |item| item.is_a?(String) && !item.empty? }
      spec = spec.merge("materialReviewRecords" => reviews.map { |item| load_review(File.expand_path(item, base)) },
                        "renderIndex" => render_index(spec["renders"], base))
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
    pattern = pattern.merge("materialRecords" => verify_tile_materials!(id, validated, spec)) if kind == "proposal"
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
      if proposal
        count = pattern.fetch("materialRecords").length
        style += %(<p class="meta">使う生成素材：#{count}点#{count.positive? ? '（すべて素材の確認で採用済み）' : ''}</p>)
      end
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

  # --- material sheets (D-085, #393) ---------------------------------------------------------------

  # A material sheet shows generated material (backgrounds, objects, mascots, settings, strips) before
  # any pattern uses it. Each material names the pattern it was made for, its role and its prompt; a
  # cut-out material names the key color it was generated on.
  def validate_material_spec(spec, base)
    object!(spec, "material definition", %w[schemaVersion kind app title materials], %w[brief])
    fail!("material definition schemaVersion must be #{SCHEMA_VERSION}") unless spec["schemaVersion"] == SCHEMA_VERSION
    %w[app title].each { |key| text!(spec[key], key, required: true) }
    text!(spec["brief"], "brief", required: false)
    materials = list!(spec["materials"], "materials", MATERIAL_COUNT).map do |material|
      object!(material, "material", %w[id pattern role image prompt], %w[cutout note])
      id = token!(material["id"], "material id")
      fail!("material #{id} pattern is invalid") unless material["pattern"].is_a?(String) && material["pattern"].match?(ID_PATTERN)
      token!(material["role"], "material #{id} role")
      %w[prompt].each { |key| text!(material[key], "material #{id} #{key}", required: true) }
      text!(material["note"], "material #{id} note", required: false)
      image = material["image"]
      fail!("material #{id} image must be a path") unless image.is_a?(String) && !image.empty?
      cut = material["cutout"]
      unless cut.nil?
        object!(cut, "material #{id} cutout", %w[key])
        hex!(cut["key"], "material #{id} cutout key")
      end
      material.merge("source" => File.expand_path(image, base))
    end
    ids = materials.map { |material| material.fetch("id") }
    fail!("material ids must be unique") unless ids.uniq.length == ids.length
    spec.merge("materials" => materials)
  end

  def material_display(spec, revision, images)
    {"schemaVersion" => SCHEMA_VERSION, "revision" => revision, "kind" => MATERIAL_KIND,
     "materials" => spec.fetch("materials").map do |material|
       {"id" => material.fetch("id"), "pattern" => material.fetch("pattern"), "role" => material.fetch("role"),
        "sha256" => images.fetch(material.fetch("source")).fetch("sha256")}
     end}
  end

  def build_material(spec, spec_bytes, root, revision, max_dimension)
    FileUtils.mkdir_p(root, mode: 0o700)
    destination = File.join(root, revision)
    fail!("revision already exists and is never replaced: #{revision}") if File.exist?(destination) || File.symlink?(destination)
    # A cut-out that keeps its background or key-color fringe is refused before the user sees it.
    cutouts = spec.fetch("materials").select { |material| material["cutout"] }.to_h do |material|
      [material.fetch("id"), cutout_check(material.fetch("source"), material.fetch("cutout").fetch("key"), "material #{material.fetch('id')}")]
    end
    staging = Dir.mktmpdir(".#{revision}.", root)
    begin
      images = {}
      spec.fetch("materials").each { |material| images[material.fetch("source")] ||= embed_image(material.fetch("source"), max_dimension, staging) }
      display = material_display(spec, revision, images)
      html = render_material_html(spec, revision, images, display)
      File.binwrite(File.join(staging, "sheet.html"), html)
      record = {
        "schemaVersion" => SCHEMA_VERSION, "revision" => revision, "kind" => MATERIAL_KIND,
        "sheetSha256" => "sha256:#{Digest::SHA256.hexdigest(html)}",
        "definitionSha256" => "sha256:#{Digest::SHA256.hexdigest(spec_bytes)}",
        "builtAt" => Time.now.utc.iso8601,
        "materials" => display.fetch("materials").zip(spec.fetch("materials")).map do |shown, material|
          entry = shown.merge("source" => material.fetch("source"))
          entry["cutout"] = cutouts.fetch(material.fetch("id")) if cutouts.key?(material.fetch("id"))
          entry
        end
      }
      File.binwrite(File.join(staging, "sheet.json"), "#{JSON.pretty_generate(record)}\n")
      Dir.children(staging).each { |name| File.unlink(File.join(staging, name)) if name.start_with?(".thumb-") }
      File.rename(staging, destination)
      staging = nil
      {"status" => "built", "revision" => revision, "sheet" => File.join(destination, "sheet.html"),
       "sheetSha256" => record.fetch("sheetSha256"), "materials" => record.fetch("materials").length}
    ensure
      FileUtils.rm_rf(staging) if staging
    end
  end

  def render_material_html(spec, revision, images, record)
    h = ->(text) { CGI.escapeHTML(text.to_s) }
    groups = spec.fetch("materials").group_by { |material| material.fetch("pattern") }
    sections = groups.map do |pattern, materials|
      figures = materials.map do |material|
        note = material["note"] ? "<span>#{h.(material['note'])}</span>" : ""
        cut = material["cutout"] ? "<span>切り抜き（キー色 #{h.(material['cutout']['key'])}）：確認済み</span>" : ""
        %(<figure class="material"><img src="#{images.fetch(material.fetch('source')).fetch('dataUri')}" alt="#{h.(material.fetch('id'))}">) +
          %(<figcaption><b>#{h.(material.fetch('id'))}</b> <code>#{h.(material.fetch('role'))}</code>#{cut}#{note}) +
          %(<span class="prompt">#{h.(material.fetch('prompt'))}</span></figcaption></figure>)
      end.join
      %(<section class="pattern"><h2><span class="badge">#{h.(pattern)}</span> の素材</h2><div class="grid">#{figures}</div></section>)
    end.join
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
      :root { color-scheme: light dark; --bg: #f6f5f2; --fg: #1d1d1f; --muted: #5b5b60; --card: #ffffff; --line: #d9d7d2; --check: #e4e2dd; }
      @media (prefers-color-scheme: dark) { :root { --bg: #161618; --fg: #f2f2f4; --muted: #a8a8ae; --card: #212124; --line: #3a3a3e; --check: #2c2c30; } }
      body { margin: 0; padding: 24px 16px 48px; background: var(--bg); color: var(--fg); font: 15px/1.6 -apple-system, "Hiragino Sans", sans-serif; }
      header, section { max-width: 1200px; margin: 0 auto 24px; }
      .meta { color: var(--muted); font-size: 13px; }
      .brief, .pattern { background: var(--card); border: 1px solid var(--line); border-radius: 16px; padding: 16px; }
      .badge { display: inline-block; min-width: 2em; text-align: center; border-radius: 8px; background: var(--fg); color: var(--bg); padding: 0 8px; }
      .grid { display: flex; flex-wrap: wrap; gap: 16px; }
      .material { margin: 0; width: 240px; }
      .material img { display: block; width: 240px; height: auto; border-radius: 10px; border: 1px solid var(--line);
        background-color: var(--card); background-image: linear-gradient(45deg, var(--check) 25%, transparent 25%, transparent 75%, var(--check) 75%),
        linear-gradient(45deg, var(--check) 25%, transparent 25%, transparent 75%, var(--check) 75%); background-size: 16px 16px; background-position: 0 0, 8px 8px; }
      figcaption { font-size: 12px; color: var(--muted); } figcaption span { display: block; } .prompt { margin-top: 4px; }
      </style>
      </head>
      <body>
      <header>
      <h1>#{h.(spec.fetch('title'))}</h1>
      <p class="meta">#{h.(spec.fetch('app'))} ・ 素材の確認 ・ revision #{h.(revision)}</p>
      #{brief}
      <p class="meta">素材ごとに「採用」か「不採用」を決めてください。採用した素材だけがパターンに使われます。AIっぽくありきたりなもの、買いたくならないものは不採用にしてください。</p>
      </header>
      #{sections}
      </body>
      </html>
    HTML
  end

  # Verifies a sheet directory: sheet.html matches its record and the record matches the page's
  # displayed record (the source paths are local and never shown).
  def verified_sheet(directory)
    record = JSON.parse(read_regular(File.join(directory, "sheet.json"), "sheet record"))
    html = read_regular(File.join(directory, "sheet.html"), "sheet")
    actual = "sha256:#{Digest::SHA256.hexdigest(html)}"
    fail!("sheet.html differs from the sheet record") unless record["sheetSha256"].is_a?(String) &&
      record["sheetSha256"].match?(DIGEST_PATTERN) && record["sheetSha256"] == actual
    matches = html.scan(DISPLAY_RECORD_PATTERN)
    fail!("the sheet does not carry exactly one displayed record") unless matches.length == 1
    displayed = JSON.parse(Base64.strict_decode64(matches.first.first))
    [record, displayed, actual]
  end

  def review(options)
    require_options(options, "sheet")
    unknown = options.keys - %w[sheet adopt reject]
    fail!("unknown option: --#{unknown.first}") unless unknown.empty?
    directory = File.expand_path(options.fetch("sheet"))
    record, displayed, actual = verified_sheet(directory)
    fail!("review applies only to a material sheet; use select for patterns") unless record["kind"] == MATERIAL_KIND && displayed["kind"] == MATERIAL_KIND
    listed = {"schemaVersion" => record["schemaVersion"], "revision" => record["revision"], "kind" => record["kind"],
              "materials" => (record["materials"] || []).map { |material| material.slice("id", "pattern", "role", "sha256") }}
    fail!("sheet.json differs from the displayed sheet") unless listed == displayed
    target = File.join(directory, "material-review.json")
    fail!("a review is already recorded for this sheet and is never replaced") if File.exist?(target) || File.symlink?(target)
    split = ->(name) { options.key?(name) ? options.fetch(name).split(",", -1).map(&:strip) : [] }
    adopt = split.("adopt")
    reject = split.("reject")
    known = displayed.fetch("materials").map { |material| material.fetch("id") }
    (adopt + reject).each { |id| fail!("unknown material id: #{id}") unless known.include?(id) }
    both = adopt & reject
    fail!("material #{both.first} is both adopted and rejected") unless both.empty?
    duplicate = (adopt + reject).group_by(&:itself).find { |_, names| names.length > 1 }
    fail!("material #{duplicate.first} is named twice") if duplicate
    # Only a decision on every material counts; praise or "the blue ones" is not one.
    missing = known - adopt - reject
    fail!("every material needs --adopt or --reject; missing: #{missing.join(', ')}") unless missing.empty?
    value = {
      "schemaVersion" => SCHEMA_VERSION, "revision" => record.fetch("revision"), "sheetSha256" => actual,
      "decisions" => displayed.fetch("materials").map do |material|
        material.slice("id", "pattern", "sha256").merge("decision" => adopt.include?(material.fetch("id")) ? "adopted" : "rejected")
      end,
      "decision" => "user-explicit", "recordedAt" => Time.now.utc.iso8601
    }
    File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write("#{JSON.pretty_generate(value)}\n") }
    {"status" => "reviewed", "review" => target, "adopted" => adopt.length, "rejected" => reject.length}
  end

  # Loads a material review together with its sheet, so a review whose sheet changed is never trusted.
  def load_review(directory)
    record, displayed, actual = verified_sheet(directory)
    fail!("#{directory} is not a material sheet") unless record["kind"] == MATERIAL_KIND
    review = JSON.parse(read_regular(File.join(directory, "material-review.json"), "material review"))
    unless review["sheetSha256"] == actual && review["revision"] == record["revision"] && review["decision"] == "user-explicit" &&
           review["decisions"].is_a?(Array)
      fail!("material review of #{record['revision']} does not match its sheet")
    end
    shown = displayed.fetch("materials").to_h { |material| [material.fetch("id"), material.fetch("sha256")] }
    review.fetch("decisions").each do |entry|
      unless shown[entry["id"]] == entry["sha256"] && MATERIAL_DECISIONS.include?(entry["decision"])
        fail!("material review of #{record['revision']} does not match its sheet")
      end
    end
    sources = (record["materials"] || []).to_h { |material| [material["source"], material["sha256"]] }
    {"revision" => record.fetch("revision"), "decisions" => review.fetch("decisions"), "sources" => sources,
     "reviewSha256" => "sha256:#{Digest::SHA256.file(File.join(directory, 'material-review.json')).hexdigest}"}
  end

  # The render records of tools/appstore-creative-render.sh (creative-render-<device>-<locale>.json) say,
  # for each output tile, which generated images it was drawn from: its background slice and every
  # layer that touches it. The index maps each tile's SHA-256 to those inputs.
  def render_index(paths, base)
    fail!("a proposal needs renders: the creative-render records of its tiles") unless paths.is_a?(Array) && !paths.empty? &&
      paths.all? { |item| item.is_a?(String) && !item.empty? }
    paths.each_with_object({}) do |item, index|
      path = File.expand_path(item, base)
      record = JSON.parse(read_regular(path, "render record"))
      unless record.is_a?(Hash) && record["schemaVersion"] == SCHEMA_VERSION && record["files"].is_a?(Array) && !record["files"].empty?
        fail!("render record #{File.basename(path)} must have schemaVersion 1 and files")
      end
      # Only a record that lists every image input of every tile can show that a tile is clean.
      unless record["inputInventory"] == RENDER_INVENTORY
        fail!("render record #{File.basename(path)} has no complete input inventory; render the tiles again with tools/appstore-creative-render.sh")
      end
      backgrounds = record.fetch("backgrounds", [])
      layers = record.fetch("layers", [])
      decorations = record.fetch("decorations", [])
      unless backgrounds.is_a?(Array) && layers.is_a?(Array) && decorations.is_a?(Array)
        fail!("render record #{File.basename(path)} backgrounds, layers and decorations must be lists")
      end
      layers += decorations
      record.fetch("files").each_with_index do |file, position|
        unless file.is_a?(Hash) && file["path"].is_a?(String) && file["sha256"].is_a?(String) && file["sha256"].match?(DIGEST_PATTERN)
          fail!("render record #{File.basename(path)} lists a file without path and sha256")
        end
        inputs = backgrounds.select { |entry| entry.is_a?(Hash) && entry["file"] == file["path"] }
                            .map { |entry| {"sha256" => entry["sourceSha256"], "path" => entry["source"]} }
        inputs += layers.select { |entry| entry.is_a?(Hash) && entry["tiles"].is_a?(Array) && entry["tiles"].include?(position + 1) }
                        .map { |entry| {"sha256" => entry["sha256"], "path" => entry["src"]} }
        inputs.each do |input|
          next if input["sha256"].is_a?(String) && input["sha256"].match?(DIGEST_PATTERN) && input["path"].is_a?(String)
          fail!("render record #{File.basename(path)} lists an input without source and sha256")
        end
        (index[file["sha256"]] ||= []).concat(inputs)
      end
    end
  end

  # A tile may draw only on generated material the user adopted, byte for byte: every input its render
  # record names, and the tile image itself when it is a reviewed material.
  def verify_tile_materials!(id, tiles, spec)
    reviews = spec.fetch("materialReviewRecords")
    index = spec.fetch("renderIndex")
    decisions_for = ->(digest) { reviews.flat_map { |review| review.fetch("decisions").select { |entry| entry.fetch("sha256") == digest } } }
    adopted = []
    tiles.each do |tile|
      label = "tile #{tile.fetch('slot')} of #{id}"
      source = tile.fetch("source")
      digest = "sha256:#{Digest::SHA256.hexdigest(read_regular(source, "#{label} image"))}"
      inputs = index[digest] or
        fail!("#{label} is in no render record; render it with tools/appstore-creative-render.sh and list the record in renders")
      direct = decisions_for.(digest)
      if direct.any? && direct.none? { |entry| entry.fetch("decision") == "adopted" }
        fail!("#{label} uses #{File.basename(source)}, which the user rejected")
      end
      inputs.each do |input|
        decisions = decisions_for.(input.fetch("sha256"))
        name = File.basename(input.fetch("path"))
        if decisions.any? { |entry| entry.fetch("decision") == "adopted" }
          adopted << input.fetch("sha256")
        elsif decisions.any?
          fail!("#{label} uses #{name}, which the user rejected")
        elsif reviews.any? { |review| review.fetch("sources").key?(File.expand_path(input.fetch("path"))) }
          fail!("#{label} uses #{name}, which changed after the user reviewed it")
        else
          fail!("#{label} uses #{name}, which the user has not adopted on a material sheet")
        end
      end
    end
    adopted.uniq.map { |digest| {"sha256" => digest} }
  end

  # --- cutout --------------------------------------------------------------------------------------

  def png_header(path)
    bytes = File.binread(path, 33)
    fail!("#{path} is not a PNG") unless bytes&.start_with?("\x89PNG\r\n\x1A\n".b) && bytes.length >= 26
    {"width" => bytes[16, 4].unpack1("N"), "height" => bytes[20, 4].unpack1("N"), "colorType" => bytes.getbyte(25)}
  end

  # A cut-out (an object or mascot generated on a solid key color and then separated) must be a PNG
  # with alpha, fully transparent along its edges and over a real share of the image, and must not keep
  # visible pixels close to the key color.
  def cutout_check(path, key, label)
    read_regular(path, "#{label} image")
    header = png_header(path)
    fail!("#{label} has no transparent background: the PNG has no alpha channel") unless [4, 6].include?(header.fetch("colorType"))
    width = header.fetch("width")
    height = header.fetch("height")
    data, status = Open3.capture2("ffmpeg", "-loglevel", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "rgba", "-", binmode: true)
    fail!("could not read #{label}") unless status.success? && data.bytesize == width * height * 4
    target = key.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) }
    transparent = 0
    visible = 0
    residue = 0
    edge = 0
    limit = CUTOUT_KEY_DISTANCE**2
    height.times do |y|
      row = y * width * 4
      width.times do |x|
        offset = row + x * 4
        alpha = data.getbyte(offset + 3)
        if alpha <= 8
          transparent += 1
          next
        end
        visible += 1
        edge += 1 if x < CUTOUT_EDGE || y < CUTOUT_EDGE || x >= width - CUTOUT_EDGE || y >= height - CUTOUT_EDGE
        dr = data.getbyte(offset) - target[0]
        dg = data.getbyte(offset + 1) - target[1]
        db = data.getbyte(offset + 2) - target[2]
        residue += 1 if dr * dr + dg * dg + db * db <= limit
      end
    end
    total = width * height
    fail!("#{label} background is not transparent at its edges") if edge.positive?
    if transparent < total * CUTOUT_MIN_TRANSPARENT
      fail!("#{label} background is not transparent: only #{(100.0 * transparent / total).round(1)}% of it is clear")
    end
    share = visible.zero? ? 0.0 : residue.to_f / visible
    if share > CUTOUT_MAX_RESIDUE
      fail!("#{label} keeps #{(100 * share).round(1)}% of the key color #{key.upcase} at its edges; separate it again")
    end
    {"key" => key.upcase, "transparent" => (transparent.to_f / total).round(4), "keyResidue" => share.round(4)}
  end

  def cutout(options)
    require_options(options, "image", "key")
    unknown = options.keys - %w[image key]
    fail!("unknown option: --#{unknown.first}") unless unknown.empty?
    hex!(options.fetch("key"), "--key")
    path = File.expand_path(options.fetch("image"))
    {"status" => "clean", "image" => path}.merge(cutout_check(path, options.fetch("key"), File.basename(path)))
  end

  # --- provenance ----------------------------------------------------------------------------------

  # goldie/assets/provenance.json lists every adopted generated image with how it was made and the
  # material review that adopted it; the review is read from its sheet under --root.
  def provenance(options)
    require_options(options, "file", "root")
    unknown = options.keys - %w[file root]
    fail!("unknown option: --#{unknown.first}") unless unknown.empty?
    path = File.expand_path(options.fetch("file"))
    value = JSON.parse(read_regular(path, "provenance record"))
    object!(value, "provenance record", %w[schemaVersion images])
    fail!("provenance schemaVersion must be #{SCHEMA_VERSION}") unless value["schemaVersion"] == SCHEMA_VERSION
    root = File.expand_path(options.fetch("root"))
    reviews = {}
    images = list!(value["images"], "provenance images", (1..200)).map do |image|
      fail!("each provenance image must be an object") unless image.is_a?(Hash)
      file = image["file"]
      fail!("provenance image file must be a relative path") unless file.is_a?(String) && !file.empty? && !file.start_with?("/") && !file.split("/").include?("..")
      review_ref = image["materialReview"]
      fail!("image #{file} has no material review record") unless review_ref.is_a?(Hash)
      object!(image, "provenance image #{file}", %w[file sha256 prompt mode generator generatedAt revision materialReview], %w[referenceSha256])
      %w[prompt generator generatedAt].each { |key| text!(image[key], "image #{file} #{key}", required: true) }
      fail!("image #{file} mode must be generate or edit") unless %w[generate edit].include?(image["mode"])
      source = File.join(File.dirname(path), file)
      fail!("image #{file} is missing") unless File.file?(source) && !File.symlink?(source)
      digest = "sha256:#{Digest::SHA256.file(source).hexdigest}"
      fail!("image #{file} does not match its recorded sha256") unless image["sha256"] == digest
      object!(review_ref, "image #{file} materialReview", %w[revision reviewSha256 decision])
      revision = review_ref["revision"]
      fail!("image #{file} materialReview revision is invalid") unless revision.is_a?(String) && revision.match?(REVISION_PATTERN)
      review = reviews[revision] ||= load_review(File.join(root, revision))
      fail!("image #{file} names a material review that differs from #{revision}") unless review_ref["reviewSha256"] == review.fetch("reviewSha256")
      entry = review.fetch("decisions").find { |decision| decision.fetch("sha256") == digest }
      fail!("image #{file} is not on the material review #{revision}") unless entry
      fail!("image #{file} was rejected on the material review #{revision}") unless entry.fetch("decision") == "adopted" && review_ref["decision"] == "adopted"
      {"file" => file, "sha256" => digest, "materialReview" => revision}
    end
    {"status" => "valid", "images" => images.length}
  end

  # --- header sheets (D-085, #391) -----------------------------------------------------------------

  def validate_header_spec(spec, base)
    object!(spec, "header definition", %w[schemaVersion kind app title options], %w[brief])
    fail!("header definition schemaVersion must be #{SCHEMA_VERSION}") unless spec["schemaVersion"] == SCHEMA_VERSION
    %w[app title].each { |key| text!(spec[key], key, required: true) }
    text!(spec["brief"], "brief", required: false)
    options = spec["options"]
    unless options.is_a?(Array) && HEADER_OPTIONS.cover?(options.length)
      fail!("a header sheet compares two to six header options; found #{options.is_a?(Array) ? options.length : 0}")
    end
    validated = options.map do |option|
      object!(option, "header option", %w[id title hypothesis tradeoffs image], %w[video])
      id = option["id"]
      fail!("header option id is invalid: #{id.inspect}") unless id.is_a?(String) && id.match?(ID_PATTERN)
      fail!("header option id #{NO_HEADER} is reserved for no header") if id.downcase == NO_HEADER
      %w[title hypothesis tradeoffs].each { |key| text!(option[key], "#{id}.#{key}", required: true) }
      image = File.expand_path(option["image"].to_s, base)
      fail!("header option #{id} image must be a regular file: #{image}") unless File.file?(image) && !File.symlink?(image)
      header = File.binread(image, 33).to_s
      unless header.start_with?("\x89PNG\r\n\x1A\n".b) && [header[16, 4].unpack1("N"), header[20, 4].unpack1("N")] == HEADER_SIZE
        fail!("header option #{id} image is not a 3840x1646 PNG header")
      end
      video = nil
      if option["video"]
        video = File.expand_path(option["video"], base)
        read_regular(video, "header option #{id} video")
        fail!("header option #{id} video must be .mp4, .mov or .m4v") unless %w[.mp4 .mov .m4v].include?(File.extname(video).downcase)
      end
      option.merge("source" => image, "videoSource" => video)
    end
    ids = validated.map { |option| option.fetch("id") }
    fail!("header option ids must be unique") unless ids.uniq.length == ids.length
    spec.merge("options" => validated)
  end

  def header_display(spec, revision, images)
    {"schemaVersion" => SCHEMA_VERSION, "revision" => revision, "kind" => HEADER_KIND,
     "options" => spec.fetch("options").map do |option|
       {"id" => option.fetch("id"), "sha256" => images.fetch(option.fetch("source")).fetch("sha256"),
        "videoSha256" => option["videoSource"] ? "sha256:#{Digest::SHA256.file(option['videoSource']).hexdigest}" : nil}
     end}
  end

  def build_header(spec, spec_bytes, root, revision, max_dimension)
    FileUtils.mkdir_p(root, mode: 0o700)
    destination = File.join(root, revision)
    fail!("revision already exists and is never replaced: #{revision}") if File.exist?(destination) || File.symlink?(destination)
    staging = Dir.mktmpdir(".#{revision}.", root)
    begin
      images = {}
      spec.fetch("options").each { |option| images[option.fetch("source")] ||= embed_image(option.fetch("source"), max_dimension, staging) }
      display = header_display(spec, revision, images)
      h = ->(text) { CGI.escapeHTML(text.to_s) }
      sections = spec.fetch("options").zip(display.fetch("options")).map do |option, shown|
        video = shown["videoSha256"] ? %(<p class="meta">ループ動画あり（#{h.(File.basename(option['videoSource']))}、#{h.(shown['videoSha256'][0, 19])}…）。動画は手元のファイルで再生して確かめてください。</p>) : %(<p class="meta">静止画のみ</p>)
        <<~SECTION
          <section class="pattern"><h2><span class="badge">#{h.(option.fetch('id'))}</span> #{h.(option.fetch('title'))}</h2>
          <dl><dt>狙い</dt><dd>#{h.(option.fetch('hypothesis'))}</dd><dt>弱点</dt><dd>#{h.(option.fetch('tradeoffs'))}</dd></dl>
          <figure class="header"><img src="#{images.fetch(option.fetch('source')).fetch('dataUri')}" alt="#{h.(option.fetch('id'))}"></figure>
          #{video}
          </section>
        SECTION
      end.join
      brief = spec["brief"] ? %(<p class="brief">#{h.(spec['brief'])}</p>) : ""
      html = <<~HTML
        <!doctype html>
        <html lang="ja">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="#{CONTENT_SECURITY_POLICY}">
        <meta name="#{DISPLAY_RECORD_META}" content="#{Base64.strict_encode64(JSON.generate(display))}">
        <title>#{h.(spec.fetch('title'))}</title>
        <style>
        :root { color-scheme: light dark; --bg: #f6f5f2; --fg: #1d1d1f; --muted: #5b5b60; --card: #ffffff; --line: #d9d7d2; }
        @media (prefers-color-scheme: dark) { :root { --bg: #161618; --fg: #f2f2f4; --muted: #a8a8ae; --card: #212124; --line: #3a3a3e; } }
        body { margin: 0; padding: 24px 16px 48px; background: var(--bg); color: var(--fg); font: 15px/1.6 -apple-system, "Hiragino Sans", sans-serif; }
        header, section { max-width: 1200px; margin: 0 auto 24px; }
        .meta { color: var(--muted); font-size: 13px; }
        .brief, .pattern { background: var(--card); border: 1px solid var(--line); border-radius: 16px; padding: 16px; }
        .badge { display: inline-block; min-width: 2em; text-align: center; border-radius: 8px; background: var(--fg); color: var(--bg); padding: 0 8px; }
        dl { display: grid; grid-template-columns: max-content 1fr; gap: 4px 12px; } dt { color: var(--muted); }
        .header { margin: 0; } .header img { display: block; width: 100%; height: auto; border-radius: 10px; border: 1px solid var(--line); }
        </style>
        </head>
        <body>
        <header>
        <h1>#{h.(spec.fetch('title'))}</h1>
        <p class="meta">#{h.(spec.fetch('app'))} ・ プロダクトページヘッダー ・ revision #{h.(revision)}</p>
        #{brief}
        <p class="meta">ヘッダーの案IDを1つ選ぶか、「ヘッダーなし」（none）を選んでください。ヘッダーはiOS 27とiPadOS 27で表示され、機種と向きで切り取られ方が変わります。公開前にApp Store ConnectのPreview toolで確かめます。</p>
        </header>
        #{sections}
        <section class="pattern"><h2><span class="badge">none</span> ヘッダーなし</h2><p class="meta">プロダクトページヘッダーを使いません。</p></section>
        </body>
        </html>
      HTML
      File.binwrite(File.join(staging, "sheet.html"), html)
      record = {
        "schemaVersion" => SCHEMA_VERSION, "revision" => revision, "kind" => HEADER_KIND,
        "sheetSha256" => "sha256:#{Digest::SHA256.hexdigest(html)}",
        "definitionSha256" => "sha256:#{Digest::SHA256.hexdigest(spec_bytes)}", "builtAt" => Time.now.utc.iso8601,
        "options" => display.fetch("options").zip(spec.fetch("options")).map { |shown, option| shown.merge("source" => option.fetch("source"), "videoSource" => option["videoSource"]) }
      }
      File.binwrite(File.join(staging, "sheet.json"), "#{JSON.pretty_generate(record)}\n")
      Dir.children(staging).each { |name| File.unlink(File.join(staging, name)) if name.start_with?(".thumb-") }
      File.rename(staging, destination)
      staging = nil
      {"status" => "built", "revision" => revision, "sheet" => File.join(destination, "sheet.html"), "sheetSha256" => record.fetch("sheetSha256")}
    ensure
      FileUtils.rm_rf(staging) if staging
    end
  end

  # The user chooses one header option or no header; the choice is checked against the displayed page and
  # recorded once.
  def select_header(directory, options)
    fail!("a header sheet takes --pattern <option ID> or --pattern none") if options.key?("tiles")
    record, displayed, actual = verified_sheet(directory)
    listed = {"schemaVersion" => record["schemaVersion"], "revision" => record["revision"], "kind" => record["kind"],
              "options" => (record["options"] || []).map { |option| option.slice("id", "sha256", "videoSha256") }}
    fail!("sheet.json differs from the displayed sheet") unless listed == displayed
    target = File.join(directory, "selection.json")
    fail!("a selection is already recorded for this sheet and is never replaced") if File.exist?(target) || File.symlink?(target)
    choice = options.fetch("pattern")
    selection = if choice == NO_HEADER
                  {"type" => "no-header"}
                else
                  option = displayed.fetch("options").find { |item| item.fetch("id") == choice } or fail!("unknown header option id: #{choice}")
                  {"type" => "header", "optionId" => choice, "sha256" => option.fetch("sha256"), "videoSha256" => option["videoSha256"]}
                end
    value = {"schemaVersion" => SCHEMA_VERSION, "revision" => record.fetch("revision"), "sheetSha256" => actual,
             "selection" => selection, "decision" => "user-explicit", "recordedAt" => Time.now.utc.iso8601}
    File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write("#{JSON.pretty_generate(value)}\n") }
    {"status" => "selected", "selection" => target, "type" => selection.fetch("type")}
  end

  # --- poster sheets (D-085, #392) -----------------------------------------------------------------

  def video_seconds(path)
    output, status = Open3.capture2("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", path)
    fail!("could not read the length of #{File.basename(path)}") unless status.success? && output.strip.match?(/\A[0-9.]+\z/)
    Float(output.strip)
  end

  def validate_poster_spec(spec, base)
    object!(spec, "poster definition", %w[schemaVersion kind app title video candidates], %w[brief])
    fail!("poster definition schemaVersion must be #{SCHEMA_VERSION}") unless spec["schemaVersion"] == SCHEMA_VERSION
    %w[app title].each { |key| text!(spec[key], key, required: true) }
    text!(spec["brief"], "brief", required: false)
    video = File.expand_path(spec["video"].to_s, base)
    read_regular(video, "preview video")
    fail!("the preview video must be .mp4, .mov or .m4v") unless %w[.mp4 .mov .m4v].include?(File.extname(video).downcase)
    duration = video_seconds(video)
    candidates = spec["candidates"]
    unless candidates.is_a?(Array) && POSTER_CANDIDATES.cover?(candidates.length)
      fail!("a poster sheet shows one to six candidate frames; found #{candidates.is_a?(Array) ? candidates.length : 0}")
    end
    validated = candidates.map do |candidate|
      object!(candidate, "poster candidate", %w[id seconds image], %w[note])
      id = candidate["id"]
      fail!("poster candidate id is invalid: #{id.inspect}") unless id.is_a?(String) && id.match?(ID_PATTERN)
      seconds = candidate["seconds"]
      fail!("poster candidate #{id} seconds must be a number") unless seconds.is_a?(Numeric)
      # A poster frame is a frame of the video: a time outside it is refused.
      unless seconds >= 0 && seconds < duration
        fail!(format("poster candidate %s at %.2f seconds is outside the %.2f-second preview", id, seconds, duration))
      end
      text!(candidate["note"], "#{id}.note", required: false)
      candidate.merge("source" => File.expand_path(candidate["image"].to_s, base))
    end
    ids = validated.map { |candidate| candidate.fetch("id") }
    fail!("poster candidate ids must be unique") unless ids.uniq.length == ids.length
    spec.merge("candidates" => validated, "videoSource" => video, "durationSeconds" => duration.round(3),
               "videoSha256" => "sha256:#{Digest::SHA256.file(video).hexdigest}")
  end

  def build_poster(spec, spec_bytes, root, revision, max_dimension)
    FileUtils.mkdir_p(root, mode: 0o700)
    destination = File.join(root, revision)
    fail!("revision already exists and is never replaced: #{revision}") if File.exist?(destination) || File.symlink?(destination)
    staging = Dir.mktmpdir(".#{revision}.", root)
    begin
      images = {}
      spec.fetch("candidates").each { |candidate| images[candidate.fetch("source")] ||= embed_image(candidate.fetch("source"), max_dimension, staging) }
      display = {"schemaVersion" => SCHEMA_VERSION, "revision" => revision, "kind" => POSTER_KIND, "videoSha256" => spec.fetch("videoSha256"),
                 "durationSeconds" => spec.fetch("durationSeconds"),
                 "candidates" => spec.fetch("candidates").map { |candidate| {"id" => candidate.fetch("id"), "seconds" => candidate.fetch("seconds"),
                                                                            "sha256" => images.fetch(candidate.fetch("source")).fetch("sha256")} }}
      h = ->(text) { CGI.escapeHTML(text.to_s) }
      figures = spec.fetch("candidates").map do |candidate|
        note = candidate["note"] ? "<span>#{h.(candidate['note'])}</span>" : ""
        %(<figure class="tile"><img src="#{images.fetch(candidate.fetch('source')).fetch('dataUri')}" alt="#{h.(candidate.fetch('id'))}">) +
          %(<figcaption><b>#{h.(candidate.fetch('id'))}</b> #{format('%.2f', candidate.fetch('seconds'))}秒#{note}</figcaption></figure>)
      end.join
      brief = spec["brief"] ? %(<p class="brief">#{h.(spec['brief'])}</p>) : ""
      html = <<~HTML
        <!doctype html>
        <html lang="ja">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="#{CONTENT_SECURITY_POLICY}">
        <meta name="#{DISPLAY_RECORD_META}" content="#{Base64.strict_encode64(JSON.generate(display))}">
        <title>#{h.(spec.fetch('title'))}</title>
        <style>
        :root { color-scheme: light dark; --bg: #f6f5f2; --fg: #1d1d1f; --muted: #5b5b60; --card: #ffffff; --line: #d9d7d2; }
        @media (prefers-color-scheme: dark) { :root { --bg: #161618; --fg: #f2f2f4; --muted: #a8a8ae; --card: #212124; --line: #3a3a3e; } }
        body { margin: 0; padding: 24px 16px 48px; background: var(--bg); color: var(--fg); font: 15px/1.6 -apple-system, "Hiragino Sans", sans-serif; }
        header, section { max-width: 1200px; margin: 0 auto 24px; }
        .meta { color: var(--muted); font-size: 13px; } .brief, .pattern { background: var(--card); border: 1px solid var(--line); border-radius: 16px; padding: 16px; }
        .strip { display: flex; flex-wrap: wrap; gap: 12px; } .tile { margin: 0; } .tile img { display: block; width: 180px; height: auto; border-radius: 10px; border: 1px solid var(--line); }
        figcaption { font-size: 12px; color: var(--muted); } figcaption span { display: block; }
        </style>
        </head>
        <body>
        <header>
        <h1>#{h.(spec.fetch('title'))}</h1>
        <p class="meta">#{h.(spec.fetch('app'))} ・ App Previewのポスターフレーム ・ revision #{h.(revision)} ・ 動画 #{format('%.2f', spec.fetch('durationSeconds'))}秒</p>
        #{brief}
        <p class="meta">候補のIDを1つ選んでください。選ばなければ、Appleは5秒の位置の画面をポスターフレームにします。自動再生を切った人と、再生が始まる前の人には、この1枚だけが見えます。</p>
        </header>
        <section class="pattern"><div class="strip">#{figures}</div></section>
        </body>
        </html>
      HTML
      File.binwrite(File.join(staging, "sheet.html"), html)
      record = display.merge("sheetSha256" => "sha256:#{Digest::SHA256.hexdigest(html)}",
                             "definitionSha256" => "sha256:#{Digest::SHA256.hexdigest(spec_bytes)}", "builtAt" => Time.now.utc.iso8601,
                             "video" => spec.fetch("videoSource"))
      File.binwrite(File.join(staging, "sheet.json"), "#{JSON.pretty_generate(record)}\n")
      Dir.children(staging).each { |name| File.unlink(File.join(staging, name)) if name.start_with?(".thumb-") }
      File.rename(staging, destination)
      staging = nil
      {"status" => "built", "revision" => revision, "sheet" => File.join(destination, "sheet.html"), "sheetSha256" => record.fetch("sheetSha256")}
    ensure
      FileUtils.rm_rf(staging) if staging
    end
  end

  def select_poster(directory, options)
    fail!("a poster sheet takes --pattern <candidate ID>") if options.key?("tiles")
    record, displayed, actual = verified_sheet(directory)
    listed = record.slice("schemaVersion", "revision", "kind", "videoSha256", "durationSeconds", "candidates")
    fail!("sheet.json differs from the displayed sheet") unless listed == displayed
    target = File.join(directory, "selection.json")
    fail!("a selection is already recorded for this sheet and is never replaced") if File.exist?(target) || File.symlink?(target)
    choice = options.fetch("pattern")
    candidate = displayed.fetch("candidates").find { |item| item.fetch("id") == choice } or fail!("unknown poster candidate id: #{choice}")
    # The time is checked again against the displayed video length, never read from sheet.json alone.
    unless candidate.fetch("seconds") >= 0 && candidate.fetch("seconds") < displayed.fetch("durationSeconds")
      fail!("poster candidate #{choice} lies outside the preview")
    end
    value = {"schemaVersion" => SCHEMA_VERSION, "revision" => record.fetch("revision"), "sheetSha256" => actual,
             "selection" => {"type" => "poster", "candidateId" => choice, "seconds" => candidate.fetch("seconds"),
                             "frameSha256" => candidate.fetch("sha256"), "videoSha256" => displayed.fetch("videoSha256")},
             "decision" => "user-explicit", "recordedAt" => Time.now.utc.iso8601}
    File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write("#{JSON.pretty_generate(value)}\n") }
    {"status" => "selected", "selection" => target, "type" => "poster", "seconds" => candidate.fetch("seconds")}
  end

  # --- select --------------------------------------------------------------------------------------

  def select(options)
    require_options(options, "sheet")
    unknown = options.keys - %w[sheet pattern tiles]
    fail!("unknown option: --#{unknown.first}") unless unknown.empty?
    fail!("give exactly one of --pattern or --tiles") unless options.key?("pattern") ^ options.key?("tiles")
    directory = File.expand_path(options.fetch("sheet"))
    record = JSON.parse(read_regular(File.join(directory, "sheet.json"), "sheet record"))
    fail!("a material sheet takes review --adopt/--reject, not select") if record["kind"] == MATERIAL_KIND
    return select_header(directory, options) if record["kind"] == HEADER_KIND
    return select_poster(directory, options) if record["kind"] == POSTER_KIND
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
