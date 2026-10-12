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
module AppStoreCreativeSheet
  SCHEMA_VERSION = 1
  SHEET_KINDS = %w[proposal preview storyboard].freeze
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
    command = argv.shift or fail!("command is required: build or select")
    options = parse_options(argv)
    value = case command
            when "build" then build(options)
            when "select" then select(options)
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
      html = render_html(spec, revision, images, checks, display_record(spec, revision))
      File.binwrite(File.join(staging, "sheet.html"), html)
      record = {
        "schemaVersion" => SCHEMA_VERSION,
        "revision" => revision,
        "kind" => spec.fetch("kind"),
        "sheetSha256" => "sha256:#{Digest::SHA256.hexdigest(html)}",
        "definitionSha256" => "sha256:#{Digest::SHA256.hexdigest(spec_bytes)}",
        "builtAt" => Time.now.utc.iso8601,
        "patterns" => spec.fetch("patterns").map do |pattern|
          {
            "id" => pattern.fetch("id"),
            "tiles" => pattern.fetch("tiles").map do |tile|
              display_tile(tile, spec.fetch("kind")).merge("sourceSha256" => images.fetch(tile.fetch("source")).fetch("sha256"))
            end,
            "ruleCheck" => checks.fetch(pattern.fetch("id"))
          }
        end
      }
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
    extra = spec.keys - allowed
    fail!("unknown pattern definition field: #{extra.first}") unless extra.empty?
    fail!("pattern definition schemaVersion must be #{SCHEMA_VERSION}") unless spec["schemaVersion"] == SCHEMA_VERSION
    fail!("kind must be one of #{SHEET_KINDS.join(', ')}") unless SHEET_KINDS.include?(spec["kind"])
    %w[app title].each { |key| text!(spec[key], key, required: true) }
    text!(spec["brief"], "brief", required: false)
    patterns = spec["patterns"]
    fail!("patterns must be a non-empty array") unless patterns.is_a?(Array) && !patterns.empty?
    fail!("a proposal compares three or four patterns") if spec["kind"] == "proposal" && !(3..4).cover?(patterns.length)
    if spec["kind"] == "storyboard" && patterns.length != STORYBOARD_COUNT
      fail!("a storyboard sheet compares exactly #{STORYBOARD_COUNT} storyboards; found #{patterns.length}")
    end
    ids = patterns.map { |pattern| pattern.is_a?(Hash) ? pattern["id"] : nil }
    fail!("pattern ids must be unique") unless ids.uniq.length == ids.length
    validated = patterns.map { |pattern| validate_pattern(pattern, base, spec["kind"]) }
    if spec["kind"] == "proposal"
      # Every pattern fills the same number of store slots, the tile count fixed in the brief, so a
      # combination can be checked for completeness against it.
      counts = validated.map { |pattern| pattern.fetch("tiles").length }.uniq
      fail!("proposal patterns must all have the same number of tiles; found #{counts.sort.join(', ')}") unless counts.length == 1
    end
    if spec["kind"] == "storyboard"
      # Both storyboards plan the same preview: one device and locale.
      targets = validated.map { |pattern| pattern.fetch("tiles").map { |tile| tile.values_at("device", "locale") }.uniq }.uniq
      fail!("both storyboards must use the same device and locale") unless targets.length == 1
    end
    spec.merge("patterns" => validated)
  end

  def validate_pattern(pattern, base, kind)
    fail!("each pattern must be an object") unless pattern.is_a?(Hash)
    extra = pattern.keys - %w[id title hypothesis tradeoffs tiles]
    fail!("unknown pattern field: #{extra.first}") unless extra.empty?
    id = pattern["id"]
    fail!("pattern id is invalid: #{id.inspect}") unless id.is_a?(String) && id.match?(ID_PATTERN)
    %w[title hypothesis tradeoffs].each { |key| text!(pattern[key], "#{id}.#{key}", required: true) }
    tiles = pattern["tiles"]
    fail!("pattern #{id} needs tiles") unless tiles.is_a?(Array) && !tiles.empty?
    validated = tiles.map { |tile| validate_tile(tile, base, id, kind) }
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

  def validate_tile(tile, base, id, kind)
    fail!("each tile of #{id} must be an object") unless tile.is_a?(Hash)
    allowed = kind == "storyboard" ? %w[slot device locale image caption state seconds motion] : %w[slot kind device locale image caption]
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
    tile.merge("source" => source)
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

  def render_html(spec, revision, images, checks, record)
    h = ->(text) { CGI.escapeHTML(text.to_s) }
    stage = {"proposal" => "第1段階：パターンの比較", "preview" => "第2段階：選んだパターンの見本",
             "storyboard" => "プレビュー動画の絵コンテ"}.fetch(spec.fetch("kind"))
    instruction = if spec.fetch("kind") == "storyboard"
                    "絵コンテのIDを1つ選んでください。"
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
      groups = pattern.fetch("tiles").group_by { |tile| [tile.fetch("device"), tile.fetch("locale")] }
      strips = groups.map do |(device, locale), tiles|
        figures = tiles.sort_by { |tile| tile.fetch("slot") }.map do |tile|
          caption = tile["caption"] ? "<span>#{h.(tile['caption'])}</span>" : ""
          if tile.fetch("kind") == "frame"
            caption += "<span>#{h.(tile.fetch('state'))} ・ #{tile.fetch('seconds')}秒</span>"
            caption += "<span>#{h.(tile['motion'])}</span>" if tile["motion"]
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
        <dl><dt>狙い</dt><dd>#{h.(pattern.fetch('hypothesis'))}</dd><dt>弱点</dt><dd>#{h.(pattern.fetch('tradeoffs'))}</dd></dl>
        #{status}
        #{strips}
        </section>
      SECTION
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
