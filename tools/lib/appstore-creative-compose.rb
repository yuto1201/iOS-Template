# frozen_string_literal: true

# #434 (D-093): the App Store tile renderer of the appstore-creative skill. Each tile is declared in
# JSON, laid out in HTML and CSS, and drawn by headless Chromium at the store size (iPhone 6.3-inch
# 1206x2622, iPad 13-inch 2064x2752). It reads only the declared real captures, generated materials the
# user adopted (goldie/assets/provenance.json), and font files of brand.json families in allowed folders,
# and never reaches the network: the page allows file and data URLs only and Chromium resolves no host.
# It writes the tiles, one HTML page per tile, a render record that the proposal sheet reads as
# `renders`, the measured quality marks, and a 220 px thumbnail sheet. `research-sheet` lays reference
# images (one row per app, its first five) beside the proposal's own tiles, outside Git.

require "digest"
require "fileutils"
require "json"
require "open3"
require "shellwords"
require "tmpdir"
require "timeout"

# Declarations, pages and Chromium's output are UTF-8 whatever the caller's locale says.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = nil

module AppStoreCreativeCompose
  module_function

  SCHEMA_VERSION = 1
  DEVICES = {
    "iphone-6.3" => {"width" => 1206, "height" => 2622, "bezel" => 0.034, "radius" => 0.165, "island" => true},
    "ipad-13" => {"width" => 2064, "height" => 2752, "bezel" => 0.03, "radius" => 0.06, "island" => false}
  }.freeze
  # Decoration limits by style class (after ParthJadhav/app-store-screenshots' quality bar).
  STYLE_LIMITS = {"minimal" => (0..0), "editorial" => (2..5), "maximal" => (8..14)}.freeze
  # The quality bar measured on each tile (references/patterns.md#quality-bar).
  QUALITY = {"deviceHeightMin" => 0.68, "deviceHeightMax" => 0.82, "emptyBandMax" => 0.22, "headlineWidthMin" => 0.6,
             "contrastMin" => 4.5}.freeze
  THUMBNAIL_WIDTH = 220
  ID_PATTERN = /\A[a-z0-9][a-z0-9-]{0,39}\z/
  HEX_PATTERN = /\A#[0-9A-Fa-f]{6}\z/
  IMAGE_PATTERN = /\.(?:png|jpe?g|webp)\z/i
  FONT_PATTERN = /\.(?:ttf|otf|ttc|woff2?)\z/i
  FONT_ROOTS = ["/System/Library/Fonts", "/Library/Fonts", File.join(Dir.home, "Library/Fonts")].freeze
  CHROME_DEFAULT = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  CHROME_TIMEOUT = 120

  class Error < StandardError; end

  def fail!(message)
    raise Error, message
  end

  def run(argv)
    command = argv.shift or fail!("command is required: compose or research-sheet")
    options = parse_options(argv)
    result = case command
             when "compose" then compose(options)
             when "research-sheet" then research_sheet(options)
             else fail!("unknown command #{command}; use compose or research-sheet")
             end
    puts JSON.generate(result)
  rescue Error => error
    warn "appstore-creative-compose: #{error.message}"
    exit 1
  end

  def parse_options(argv)
    options = {}
    until argv.empty?
      key = argv.shift
      fail!("unexpected argument #{key}") unless key.start_with?("--") && !options.key?(key)
      value = argv.shift
      fail!("#{key} needs a value") if value.nil? || value.start_with?("--")
      options[key] = value
    end
    options
  end

  # --- compose ---------------------------------------------------------------------------------------

  def compose(options)
    spec_path = existing_file(options.fetch("--spec") { fail!("--spec is required") }, "spec")
    out = new_folder(options.fetch("--out") { fail!("--out is required") })
    brand = JSON.parse(File.read(existing_file(options.fetch("--brand") { fail!("--brand is required") }, "brand.json")))
    provenance_path = options["--provenance"] && existing_file(options["--provenance"], "provenance record")
    spec = JSON.parse(File.read(spec_path))
    base = File.dirname(spec_path)
    plan = validate_spec(spec, base, brand, provenance_path)
    chrome = chrome_path
    FileUtils.mkdir_p(File.join(out, "html"))
    tiles = plan.fetch("tiles").each_with_index.map do |tile, index|
      number = index + 1
      html = tile_html(plan, tile, number)
      html_path = File.join(out, "html", "tile-#{number}.html")
      File.write(html_path, html)
      metrics = measure(chrome, html_path, plan)
      png = File.join(out, "tile-#{number}.png")
      screenshot(chrome, html_path, png, plan["width"], plan["height"])
      {"tile" => tile, "number" => number, "png" => png, "html" => html_path, "metrics" => metrics,
       "marks" => marks_for(plan, tile, metrics)}
    end
    thumbnails = thumbnail_sheet(chrome, out, tiles.map { |entry| entry["png"] })
    record = render_record(plan, spec_path, tiles, thumbnails)
    record_path = File.join(out, "creative-render-#{plan['device']}-#{plan['locale']}.json")
    File.write(record_path, JSON.pretty_generate(record) + "\n")
    {"status" => "rendered", "record" => record_path, "tiles" => tiles.size, "thumbnails" => thumbnails["path"],
     "marks" => record.fetch("marks")}
  end

  def validate_spec(spec, base, brand, provenance_path)
    exact!(spec, "spec", %w[schemaVersion device locale style decorationLimit tiles], %w[fonts])
    fail!("spec schemaVersion must be #{SCHEMA_VERSION}") unless spec["schemaVersion"] == SCHEMA_VERSION
    device = DEVICES[spec["device"]] or fail!("spec device must be #{DEVICES.keys.join(' or ')}")
    fail!("spec locale must be ja or en-US") unless %w[ja en-US].include?(spec["locale"])
    range = STYLE_LIMITS[spec["style"]] or fail!("spec style must be #{STYLE_LIMITS.keys.join(', ')}")
    limit = spec["decorationLimit"]
    unless limit.is_a?(Integer) && range.cover?(limit)
      fail!("decorationLimit of a #{spec['style']} style must be #{range.min}..#{range.max}")
    end
    fonts = (spec["fonts"] || []).map { |font| validate_font(font, base, brand) }
    adopted = adopted_materials(provenance_path)
    tiles = spec["tiles"]
    fail!("spec tiles must be a list of 1 to 10 tiles") unless tiles.is_a?(Array) && (1..10).cover?(tiles.size)
    ids = []
    tiles = tiles.map do |tile|
      exact!(tile, "tile", %w[id background headline], %w[subhead badge device popouts layers])
      fail!("tile id is invalid") unless tile["id"].is_a?(String) && tile["id"].match?(ID_PATTERN)
      fail!("tile id #{tile['id']} is repeated") if ids.include?(tile["id"])
      ids << tile["id"]
      validate_tile(tile, base, adopted, device)
    end
    {"device" => spec["device"], "locale" => spec["locale"], "style" => spec["style"], "decorationLimit" => limit,
     "width" => device["width"], "height" => device["height"], "frame" => device, "fonts" => fonts, "tiles" => tiles}
  end

  # A font file is read only for a brand.json family (with its source and license) and from an allowed folder.
  def validate_font(font, base, brand)
    exact!(font, "font", %w[family], %w[file])
    families = (brand["fonts"] || []).map { |entry| entry.is_a?(Hash) ? entry["family"].to_s.strip.upcase : "" }
    fail!("font #{font['family']} is not a brand.json font") unless families.include?(font["family"].to_s.strip.upcase)
    return {"family" => font["family"]} unless font["file"]
    path = local_path(font["file"], base, "font #{font['family']}")
    fail!("font file #{path} is not a font") unless path.match?(FONT_PATTERN)
    roots = FONT_ROOTS + [File.join(base, "fonts"), File.join(File.dirname(base), "fonts")]
    real = File.realpath(path)
    unless roots.any? { |root| File.directory?(root) && real.start_with?(File.realpath(root) + "/") }
      fail!("font file #{path} is outside the allowed font folders")
    end
    {"family" => font["family"], "file" => real, "sha256" => digest(real)}
  end

  # Generated images may be read only when provenance.json records the user's adoption of these bytes.
  def adopted_materials(provenance_path)
    return {} unless provenance_path
    value = JSON.parse(File.read(provenance_path))
    fail!("provenance schemaVersion must be #{SCHEMA_VERSION}") unless value.is_a?(Hash) && value["schemaVersion"] == SCHEMA_VERSION
    folder = File.dirname(File.realpath(provenance_path))
    (value["images"] || []).each_with_object({}) do |image, adopted|
      next unless image.is_a?(Hash) && image.dig("materialReview", "decision") == "adopted"
      adopted[File.join(folder, image["file"].to_s)] = image["sha256"]
    end
  end

  def material!(value, base, adopted, label)
    path = File.realpath(local_path(value, base, label))
    fail!("#{label} #{path} is not a PNG, JPEG or WebP image") unless path.match?(IMAGE_PATTERN)
    recorded = adopted[path]
    fail!("#{label} #{path} is not an adopted material in provenance.json") unless recorded
    actual = digest(path)
    fail!("#{label} #{path} changed after it was adopted") unless recorded == actual
    {"path" => path, "sha256" => actual}
  end

  def capture!(value, base, label)
    path = File.realpath(local_path(value, base, label))
    fail!("#{label} #{path} is not a PNG") unless path.end_with?(".png")
    size = png_size(path)
    {"path" => path, "sha256" => digest(path), "width" => size[0], "height" => size[1]}
  end

  def validate_tile(tile, base, adopted, device)
    label = "tile #{tile['id']}"
    background = tile["background"]
    exact!(background, "#{label} background", [], %w[color gradient image grain])
    sources = %w[color gradient image].count { |key| background.key?(key) }
    fail!("#{label} background needs exactly one of color, gradient or image") unless sources == 1
    hex!(background["color"], "#{label} background color") if background.key?("color")
    if background.key?("gradient")
      gradient = background["gradient"]
      exact!(gradient, "#{label} gradient", %w[from to angle])
      hex!(gradient["from"], "#{label} gradient from")
      hex!(gradient["to"], "#{label} gradient to")
      number!(gradient["angle"], "#{label} gradient angle", -360, 360)
    end
    image = background["image"] && material!(background["image"], base, adopted, "#{label} background image")
    number!(background["grain"], "#{label} grain", 0, 0.2) if background.key?("grain")

    headline = tile["headline"]
    exact!(headline, "#{label} headline", %w[lines size color top], %w[weight lineHeight letterSpacing highlight])
    lines = headline["lines"]
    unless lines.is_a?(Array) && (1..3).cover?(lines.size) && lines.all? { |line| line.is_a?(String) && !line.strip.empty? && line.length <= 40 }
      fail!("#{label} headline needs one to three lines of at most 40 characters")
    end
    number!(headline["size"], "#{label} headline size", 40, 220)
    hex!(headline["color"], "#{label} headline color")
    number!(headline["top"], "#{label} headline top", 0, device["height"])
    number!(headline["weight"], "#{label} headline weight", 100, 900) if headline.key?("weight")
    number!(headline["lineHeight"], "#{label} line height", 0.9, 1.6) if headline.key?("lineHeight")
    number!(headline["letterSpacing"], "#{label} letter spacing", -0.1, 0.2) if headline.key?("letterSpacing")
    if headline.key?("highlight")
      highlight = headline["highlight"]
      exact!(highlight, "#{label} highlight", %w[text], %w[color band])
      fail!("#{label} highlight text is not in the headline") unless lines.any? { |line| line.include?(highlight["text"].to_s) } && !highlight["text"].to_s.empty?
      hex!(highlight["color"], "#{label} highlight color") if highlight.key?("color")
      hex!(highlight["band"], "#{label} highlight band") if highlight.key?("band")
    end
    if tile.key?("subhead")
      exact!(tile["subhead"], "#{label} subhead", %w[text size color top])
      text!(tile["subhead"]["text"], "#{label} subhead text")
      number!(tile["subhead"]["size"], "#{label} subhead size", 20, 120)
      hex!(tile["subhead"]["color"], "#{label} subhead color")
      number!(tile["subhead"]["top"], "#{label} subhead top", 0, device["height"])
    end
    if tile.key?("badge")
      exact!(tile["badge"], "#{label} badge", %w[text color background top])
      text!(tile["badge"]["text"], "#{label} badge text")
      hex!(tile["badge"]["color"], "#{label} badge color")
      hex!(tile["badge"]["background"], "#{label} badge background")
      number!(tile["badge"]["top"], "#{label} badge top", 0, device["height"])
    end
    shown = nil
    if tile.key?("device")
      shown = tile["device"]
      exact!(shown, "#{label} device", %w[capture width centerX top], %w[rotate frame])
      shown = shown.merge("capture" => capture!(shown["capture"], base, "#{label} capture"))
      number!(shown["width"], "#{label} device width", device["width"] * 0.3, device["width"] * 1.2)
      number!(shown["centerX"], "#{label} device centerX", 0, device["width"])
      number!(shown["top"], "#{label} device top", 0, device["height"])
      number!(shown["rotate"], "#{label} device rotate", -15, 15) if shown.key?("rotate")
      hex!(shown["frame"], "#{label} device frame") if shown.key?("frame")
    end
    popouts = (tile["popouts"] || []).each_with_index.map do |popout, index|
      fail!("#{label} popouts need a device") unless shown
      exact!(popout, "#{label} popout #{index + 1}", %w[region scale], %w[rotate border])
      region = popout["region"]
      capture = shown["capture"]
      unless region.is_a?(Array) && region.size == 4 && region.all? { |value| value.is_a?(Numeric) && value >= 0 } &&
             region[2] > 0 && region[3] > 0 && region[0] + region[2] <= capture["width"] && region[1] + region[3] <= capture["height"]
        fail!("#{label} popout #{index + 1} region must lie inside the capture (x, y, width, height)")
      end
      number!(popout["scale"], "#{label} popout scale", 1.0, 2.0)
      number!(popout["rotate"], "#{label} popout rotate", -15, 15) if popout.key?("rotate")
      hex!(popout["border"], "#{label} popout border") if popout.key?("border")
      popout
    end
    layers = (tile["layers"] || []).each_with_index.map do |layer, index|
      exact!(layer, "#{label} layer #{index + 1}", %w[src x y width z], %w[rotate shadow])
      fail!("#{label} layer z must be front or back") unless %w[front back].include?(layer["z"])
      number!(layer["width"], "#{label} layer width", 10, device["width"] * 2)
      number!(layer["x"], "#{label} layer x", -device["width"], device["width"] * 2)
      number!(layer["y"], "#{label} layer y", -device["height"], device["height"] * 2)
      number!(layer["rotate"], "#{label} layer rotate", -180, 180) if layer.key?("rotate")
      fail!("#{label} layer shadow must be true or false") if layer.key?("shadow") && ![true, false].include?(layer["shadow"])
      layer.merge("src" => material!(layer["src"], base, adopted, "#{label} layer #{index + 1}"))
    end
    tile.merge("background" => background.merge("image" => image).compact, "device" => shown, "popouts" => popouts,
               "layers" => layers).compact
  end

  # --- layout --------------------------------------------------------------------------------------

  # The device frame's geometry: the screen keeps the capture's aspect ratio inside a bezel drawn at
  # the tile's resolution, and the frame turns about its own center.
  def device_geometry(plan, shown)
    frame = plan["frame"]
    width = shown["width"].to_f
    bezel = width * frame["bezel"]
    screen_width = width - 2 * bezel
    capture = shown["capture"]
    screen_height = screen_width * capture["height"] / capture["width"]
    height = screen_height + 2 * bezel
    left = shown["centerX"] - width / 2.0
    {"left" => left, "top" => shown["top"].to_f, "width" => width, "height" => height, "bezel" => bezel,
     "screenWidth" => screen_width, "screenHeight" => screen_height, "rotate" => (shown["rotate"] || 0).to_f,
     "centerX" => left + width / 2.0, "centerY" => shown["top"] + height / 2.0, "radius" => width * frame["radius"]}
  end

  # A popout sits right over its region on the turned screen: the region's center is carried through the
  # device's rotation, and the card is the region magnified by `scale`.
  def popout_geometry(plan, shown, popout)
    geometry = device_geometry(plan, shown)
    capture = shown["capture"]
    factor = geometry["screenWidth"] / capture["width"]
    x, y, w, h = popout["region"]
    local_x = geometry["left"] + geometry["bezel"] + (x + w / 2.0) * factor
    local_y = geometry["top"] + geometry["bezel"] + (y + h / 2.0) * factor
    angle = geometry["rotate"] * Math::PI / 180
    dx = local_x - geometry["centerX"]
    dy = local_y - geometry["centerY"]
    center_x = geometry["centerX"] + dx * Math.cos(angle) - dy * Math.sin(angle)
    center_y = geometry["centerY"] + dx * Math.sin(angle) + dy * Math.cos(angle)
    scale = popout["scale"].to_f
    {"centerX" => center_x, "centerY" => center_y, "width" => w * factor * scale, "height" => h * factor * scale,
     "zoom" => factor * scale, "region" => popout["region"], "rotate" => (popout["rotate"] || 0).to_f}
  end

  def tile_html(plan, tile, number)
    width = plan["width"]
    height = plan["height"]
    background = tile["background"]
    fill = if background["color"]
             background["color"]
           elsif background["gradient"]
             g = background["gradient"]
             "linear-gradient(#{g['angle']}deg, #{g['from']}, #{g['to']})"
           else
             "#000 url(#{file_url(background.dig('image', 'path'))}) center / cover no-repeat"
           end
    grain = background["grain"].to_f
    noise = "data:image/svg+xml;utf8," + ERB_ESCAPE.call("<svg xmlns='http://www.w3.org/2000/svg' width='256' height='256'>" \
            "<filter id='n'><feTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2' stitchTiles='stitch'/></filter>" \
            "<rect width='100%' height='100%' filter='url(#n)'/></svg>")
    fonts = plan["fonts"].select { |font| font["file"] }.map do |font|
      "@font-face{font-family:#{css_string(font['family'])};src:url(#{file_url(font['file'])});}"
    end.join
    families = (plan["fonts"].map { |font| css_string(font["family"]) } + ["-apple-system", "'Hiragino Sans'", "sans-serif"]).join(",")
    headline = tile["headline"]
    highlight = headline["highlight"]
    lines = headline["lines"].each_with_index.map do |line, index|
      text = escape(line)
      if highlight && line.include?(highlight["text"])
        style = []
        style << "color:#{highlight['color']}" if highlight["color"]
        style << "background:#{highlight['band']};padding:0 0.12em;border-radius:0.12em" if highlight["band"]
        text = text.sub(escape(highlight["text"]), "<span class=\"hl\" style=\"#{style.join(';')}\">#{escape(highlight['text'])}</span>")
      end
      "<span class=\"line\" data-line=\"#{index}\">#{text}</span>"
    end.join("<br>")
    parts = []
    parts << "<div class=\"grain\" style=\"opacity:#{grain}\"></div>" if grain.positive?
    tile["layers"].select { |layer| layer["z"] == "back" }.each { |layer| parts << layer_html(layer) }
    if tile["device"]
      parts << device_html(plan, tile["device"])
      tile["popouts"].each { |popout| parts << popout_html(plan, tile["device"], popout) }
    end
    tile["layers"].select { |layer| layer["z"] == "front" }.each { |layer| parts << layer_html(layer) }
    parts << "<div id=\"headline\" style=\"top:#{headline['top']}px;font-size:#{headline['size']}px;color:#{headline['color']};" \
             "font-weight:#{headline['weight'] || 700};line-height:#{headline['lineHeight'] || 1.2};" \
             "letter-spacing:#{headline['letterSpacing'] || -0.02}em\">#{lines}</div>"
    if (subhead = tile["subhead"])
      parts << "<div id=\"subhead\" style=\"top:#{subhead['top']}px;font-size:#{subhead['size']}px;color:#{subhead['color']}\">#{escape(subhead['text'])}</div>"
    end
    if (badge = tile["badge"])
      parts << "<div id=\"badge\" style=\"top:#{badge['top']}px;color:#{badge['color']};background:#{badge['background']}\">#{escape(badge['text'])}</div>"
    end
    <<~HTML
      <!doctype html>
      <html lang="#{plan['locale'] == 'ja' ? 'ja' : 'en'}"><head><meta charset="utf-8">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: data:; font-src file:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
      <title>tile #{number}</title>
      <style>
      #{fonts}
      html,body{margin:0;width:#{width}px;height:#{height}px;overflow:hidden}
      body{position:relative;background:#{fill};font-family:#{families};-webkit-font-smoothing:antialiased}
      .grain{position:absolute;inset:0;background:url("#{noise}");mix-blend-mode:overlay;pointer-events:none}
      #headline{position:absolute;left:0;right:0;text-align:center;white-space:nowrap;z-index:5}
      #subhead{position:absolute;left:0;right:0;text-align:center;font-weight:500;z-index:5}
      #badge{position:absolute;left:50%;transform:translateX(-50%);padding:14px 34px;border-radius:999px;font-size:40px;font-weight:700;z-index:5}
      .line{display:inline-block}
      .device{position:absolute;box-sizing:border-box;z-index:2}
      .screen{position:absolute;overflow:hidden;background-size:100% 100%}
      .island{position:absolute;left:50%;transform:translateX(-50%);background:#000;border-radius:999px}
      .popout{position:absolute;overflow:hidden;z-index:3;box-sizing:content-box;box-shadow:0 30px 60px rgba(0,0,0,.35)}
      .layer{position:absolute}
      .back{z-index:1}.front{z-index:4}
      </style></head>
      <body>
      #{parts.join("\n")}
      <script>
      (function () {
        var box = function (node) { if (!node) return null; var r = node.getBoundingClientRect(); return {left:r.left,top:r.top,width:r.width,height:r.height}; };
        var lines = Array.prototype.map.call(document.querySelectorAll('#headline .line'), box);
        var layers = Array.prototype.map.call(document.querySelectorAll('.layer'), box);
        var out = document.createElement('pre'); out.id = 'metrics'; out.style.display = 'none';
        out.textContent = JSON.stringify({headline: box(document.getElementById('headline')), lines: lines,
          subhead: box(document.getElementById('subhead')), badge: box(document.getElementById('badge')), layers: layers});
        document.body.appendChild(out);
      })();
      </script>
      </body></html>
    HTML
  end

  ERB_ESCAPE = lambda { |text| text.gsub("%", "%25").gsub("#", "%23").gsub("<", "%3C").gsub(">", "%3E").gsub('"', "%22") }

  def device_html(plan, shown)
    g = device_geometry(plan, shown)
    frame = shown["frame"] || "#1C1C1E"
    island = ""
    if plan.dig("frame", "island")
      island_width = g["screenWidth"] * 0.3
      island_height = g["screenWidth"] * 0.085
      island = "<div class=\"island\" style=\"top:#{format_px(g['screenWidth'] * 0.03)};width:#{format_px(island_width)};height:#{format_px(island_height)}\"></div>"
    end
    screen_radius = [g["radius"] - g["bezel"], 0].max
    shadow = "0 #{format_px(g['width'] * 0.04)} #{format_px(g['width'] * 0.1)} rgba(0,0,0,.28), 0 #{format_px(g['width'] * 0.01)} #{format_px(g['width'] * 0.02)} rgba(0,0,0,.2)"
    "<div class=\"device\" style=\"left:#{format_px(g['left'])};top:#{format_px(g['top'])};width:#{format_px(g['width'])};" \
      "height:#{format_px(g['height'])};background:#{frame};border-radius:#{format_px(g['radius'])};" \
      "transform:rotate(#{g['rotate']}deg);box-shadow:#{shadow}\">" \
      "<div class=\"screen\" style=\"left:#{format_px(g['bezel'])};top:#{format_px(g['bezel'])};width:#{format_px(g['screenWidth'])};" \
      "height:#{format_px(g['screenHeight'])};border-radius:#{format_px(screen_radius)};" \
      "background-image:url(#{file_url(shown.dig('capture', 'path'))})\">#{island}</div></div>"
  end

  def popout_html(plan, shown, popout)
    g = popout_geometry(plan, shown, popout)
    x, y = g["region"]
    capture = shown["capture"]
    border = popout["border"] ? "border:#{format_px([g['width'] * 0.02, 6].max)} solid #{popout['border']};" : ""
    "<div class=\"popout\" data-center=\"#{g['centerX'].round(2)},#{g['centerY'].round(2)}\" style=\"left:#{format_px(g['centerX'] - g['width'] / 2)};" \
      "top:#{format_px(g['centerY'] - g['height'] / 2)};width:#{format_px(g['width'])};height:#{format_px(g['height'])};" \
      "#{border}margin:-#{popout['border'] ? format_px([g['width'] * 0.02, 6].max) : '0px'};border-radius:#{format_px(g['width'] * 0.06)};" \
      "transform:rotate(#{g['rotate']}deg);background-image:url(#{file_url(capture['path'])});" \
      "background-size:#{format_px(capture['width'] * g['zoom'])} #{format_px(capture['height'] * g['zoom'])};" \
      "background-position:-#{format_px(x * g['zoom'])} -#{format_px(y * g['zoom'])}\"></div>"
  end

  def layer_html(layer)
    shadow = layer["shadow"] ? "filter:drop-shadow(0 24px 40px rgba(0,0,0,.3));" : ""
    "<img class=\"layer #{layer['z']}\" alt=\"\" src=\"#{file_url(layer.dig('src', 'path'))}\" style=\"left:#{format_px(layer['x'] - layer['width'] / 2.0)};" \
      "top:#{layer['y']}px;width:#{layer['width']}px;transform:translateY(-50%) rotate(#{layer['rotate'] || 0}deg);#{shadow}\">"
  end

  # --- Chromium ------------------------------------------------------------------------------------

  def chrome_path
    path = ENV.fetch("APPSTORE_CREATIVE_CHROME", CHROME_DEFAULT)
    fail!("headless Chromium was not found at #{path}; set APPSTORE_CREATIVE_CHROME") unless File.file?(path) && File.executable?(path)
    path
  end

  # Every run uses its own profile, no extensions and no host resolution, so a page cannot reach the network.
  def chrome(chrome, html_path, *arguments)
    Dir.mktmpdir("appstore-creative-chrome") do |profile|
      command = [chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run", "--no-default-browser-check",
                 "--disable-extensions", "--disable-background-networking", "--disable-component-update", "--disable-sync",
                 "--metrics-recording-only", "--allow-file-access-from-files", "--host-resolver-rules=MAP * ~NOTFOUND",
                 "--force-device-scale-factor=1", "--user-data-dir=#{profile}", *arguments, file_url(html_path)]
      output = +""
      status = nil
      Open3.popen3(*command, pgroup: true) do |stdin, stdout, stderr, wait|
        stdin.close
        reader = Thread.new { stdout.read }
        drain = Thread.new { stderr.read }
        unless wait.join(CHROME_TIMEOUT)
          Process.kill("KILL", -wait.pid) rescue nil
          fail!("headless Chromium did not finish within #{CHROME_TIMEOUT} seconds")
        end
        status = wait.value
        output = reader.value.force_encoding(Encoding::UTF_8)
        drain.join
      end
      fail!("headless Chromium failed (#{status.exitstatus})") unless status.success?
      output
    end
  end

  def measure(chrome, html_path, plan)
    dom = chrome(chrome, html_path, "--window-size=#{plan['width']},#{plan['height']}", "--virtual-time-budget=3000", "--dump-dom")
    json = dom[%r{<pre id="metrics"[^>]*>(.*?)</pre>}m, 1] or fail!("the tile page did not report its layout")
    JSON.parse(json.gsub("&quot;", '"').gsub("&lt;", "<").gsub("&gt;", ">").gsub("&amp;", "&"))
  end

  # Chromium writes RGBA; the store takes RGB without alpha, so ffmpeg converts the shot.
  def screenshot(chrome, html_path, png, width, height)
    raw = "#{png}.raw.png"
    chrome(chrome, html_path, "--window-size=#{width},#{height}", "--virtual-time-budget=3000", "--screenshot=#{raw}")
    fail!("headless Chromium wrote no image for #{File.basename(html_path)}") unless File.file?(raw)
    _, error, status = Open3.capture3("ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", raw, "-pix_fmt", "rgb24", png)
    fail!("ffmpeg could not convert the tile: #{error.strip}") unless status.success?
    File.delete(raw)
    size = png_size(png)
    fail!("#{File.basename(png)} is #{size.join('x')}, expected #{width}x#{height}") unless size == [width, height]
  end

  def thumbnail_sheet(chrome, out, pngs)
    width = pngs.size * (THUMBNAIL_WIDTH + 24) + 24
    first = png_size(pngs.first)
    height = (THUMBNAIL_WIDTH * first[1].to_f / first[0]).ceil + 48
    images = pngs.map { |png| "<img src=\"#{file_url(png)}\" alt=\"\">" }.join
    html = <<~HTML
      <!doctype html><html><head><meta charset="utf-8">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file:; style-src 'unsafe-inline'">
      <style>html,body{margin:0;background:#f2f2f7}body{display:flex;gap:24px;padding:24px;box-sizing:border-box;width:#{width}px}
      img{width:#{THUMBNAIL_WIDTH}px;display:block;border-radius:8px;box-shadow:0 2px 8px rgba(0,0,0,.2)}</style></head>
      <body>#{images}</body></html>
    HTML
    html_path = File.join(out, "html", "thumbnails.html")
    File.write(html_path, html)
    png = File.join(out, "thumbnails.png")
    screenshot(chrome, html_path, png, width, height)
    {"path" => png, "sha256" => digest(png), "width" => width, "thumbnailWidth" => THUMBNAIL_WIDTH}
  end

  # --- quality -------------------------------------------------------------------------------------

  def marks_for(plan, tile, metrics)
    width = plan["width"].to_f
    height = plan["height"].to_f
    marks = []
    occupied = []
    if (shown = tile["device"])
      g = device_geometry(plan, shown)
      visible = [g["top"] + g["height"], height].min - [g["top"], 0].max
      ratio = visible / height
      unless (QUALITY["deviceHeightMin"]..QUALITY["deviceHeightMax"]).cover?(ratio)
        marks << "the device fills #{(ratio * 100).round}% of the height; the bar is " \
                 "#{(QUALITY['deviceHeightMin'] * 100).round}-#{(QUALITY['deviceHeightMax'] * 100).round}%"
      end
      occupied << [g["top"], g["top"] + g["height"]]
    end
    lines = metrics["lines"] || []
    widest = lines.map { |box| box["width"] }.max.to_f
    if widest / width < QUALITY["headlineWidthMin"]
      marks << "the headline spans #{(widest / width * 100).round}% of the width; the bar is #{(QUALITY['headlineWidthMin'] * 100).round}%"
    end
    marks << "a headline line is wider than the tile" if lines.any? { |box| box["left"] < 0 || box["left"] + box["width"] > width }
    %w[headline subhead badge].each do |key|
      box = metrics[key]
      occupied << [box["top"], box["top"] + box["height"]] if box
    end
    (metrics["layers"] || []).each { |box| occupied << [box["top"], box["top"] + box["height"]] }
    gap = largest_gap(occupied, height)
    marks << "an empty band of #{(gap / height * 100).round}% of the height; the bar is #{(QUALITY['emptyBandMax'] * 100).round}%" if gap / height > QUALITY["emptyBandMax"]
    background = tile["background"]
    behind = background["color"] ? [background["color"]] : background["gradient"] ? background["gradient"].values_at("from", "to") : []
    if behind.empty?
      marks << "headline contrast over an image is not measured; check it by eye"
    else
      ratio = behind.map { |color| contrast(tile.dig("headline", "color"), color) }.min
      marks << "headline contrast is #{ratio.round(2)}:1; the bar is #{QUALITY['contrastMin']}:1" if ratio < QUALITY["contrastMin"]
    end
    decorations = tile["layers"].size + tile["popouts"].size
    if decorations > plan["decorationLimit"]
      marks << "#{decorations} decorations; the #{plan['style']} style allows #{plan['decorationLimit']}"
    end
    marks
  end

  def largest_gap(intervals, height)
    clipped = intervals.map { |top, bottom| [[top, 0].max, [bottom, height].min] }.select { |top, bottom| bottom > top }.sort
    cursor = 0.0
    gap = 0.0
    clipped.each do |top, bottom|
      gap = [gap, top - cursor].max
      cursor = [cursor, bottom].max
    end
    [gap, height - cursor].max
  end

  def contrast(foreground, background)
    lighter, darker = [luminance(foreground), luminance(background)].sort.reverse
    (lighter + 0.05) / (darker + 0.05)
  end

  def luminance(hex)
    channels = hex.delete("#").scan(/../).map { |pair| pair.to_i(16) / 255.0 }
    linear = channels.map { |c| c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
    0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
  end

  # --- record --------------------------------------------------------------------------------------

  # The same shape as tools/appstore-creative-render.sh records, so the proposal sheet reads it as
  # `renders`: every generated input of every tile (backgrounds and layers) with its SHA-256.
  def render_record(plan, spec_path, tiles, thumbnails)
    files = tiles.map do |entry|
      size = png_size(entry["png"])
      {"path" => entry["png"], "sha256" => digest(entry["png"]), "width" => size[0], "height" => size[1]}
    end
    backgrounds = tiles.map do |entry|
      image = entry.dig("tile", "background", "image") or next
      {"file" => entry["png"], "source" => image["path"], "sourceSha256" => image["sha256"]}
    end.compact
    layers = tiles.flat_map do |entry|
      entry.dig("tile", "layers").map do |layer|
        {"scene" => entry.dig("tile", "id"), "src" => layer.dig("src", "path"), "sha256" => layer.dig("src", "sha256"),
         "z" => layer["z"], "tiles" => [entry["number"]]}
      end
    end
    popouts = tiles.flat_map do |entry|
      entry.dig("tile", "popouts").map do |popout|
        g = popout_geometry(plan, entry.dig("tile", "device"), popout)
        {"tile" => entry["number"], "capture" => entry.dig("tile", "device", "capture", "path"),
         "captureSha256" => entry.dig("tile", "device", "capture", "sha256"), "region" => popout["region"],
         "center" => [g["centerX"].round(2), g["centerY"].round(2)], "scale" => popout["scale"], "rotate" => g["rotate"]}
      end
    end
    {
      "schemaVersion" => SCHEMA_VERSION,
      "renderer" => "appstore-creative-compose",
      "device" => plan["device"],
      "locale" => plan["locale"],
      "spec" => spec_path,
      "specSha256" => digest(spec_path),
      "style" => plan["style"],
      "decorationLimit" => plan["decorationLimit"],
      "inputInventory" => "complete-v1",
      "fonts" => plan["fonts"],
      "captures" => tiles.map { |entry| entry.dig("tile", "device", "capture")&.slice("path", "sha256") }.compact.uniq,
      "backgrounds" => backgrounds,
      "decorations" => [],
      "layers" => layers,
      "popouts" => popouts,
      "tiles" => tiles.map do |entry|
        {"tile" => entry["number"], "id" => entry.dig("tile", "id"), "html" => entry["html"], "htmlSha256" => digest(entry["html"]),
         "metrics" => entry["metrics"], "marks" => entry["marks"]}
      end,
      "marks" => tiles.flat_map { |entry| entry["marks"].map { |mark| "tile #{entry['number']}: #{mark}" } },
      "thumbnails" => thumbnails,
      "files" => files
    }
  end

  # --- research sheet ------------------------------------------------------------------------------

  # One row per reference app with its first five images, then the proposal's own tiles at the same
  # height. Reference images are other developers' work: the sheet stays outside Git.
  def research_sheet(options)
    refs = options.fetch("--refs") { fail!("--refs is required") }
    fail!("--refs #{refs} is not a folder") unless File.directory?(refs)
    out = new_folder(options.fetch("--out") { fail!("--out is required") }, outside_git: true)
    rows = Dir.children(refs).sort.select { |name| File.directory?(File.join(refs, name)) }.map do |app|
      images = Dir.children(File.join(refs, app)).select { |name| name.match?(IMAGE_PATTERN) }.sort_by { |name| [name.to_i, name] }.first(5)
      {"label" => app, "images" => images.map { |name| File.realpath(File.join(refs, app, name)) }}
    end.reject { |row| row["images"].empty? }
    fail!("--refs has no app folders with images") if rows.empty?
    if (mine = options["--mine"])
      fail!("--mine #{mine} is not a folder") unless File.directory?(mine)
      own = Dir.children(mine).select { |name| name.match?(/\Atile-\d+\.png\z/) }.sort_by { |name| name[/\d+/].to_i }
      fail!("--mine has no tile-N.png images") if own.empty?
      rows << {"label" => "proposal", "images" => own.map { |name| File.realpath(File.join(mine, name)) }}
    end
    row_height = 440
    width = 24 + 220 + rows.map { |row| row["images"].size }.max * 224 + 24
    height = 24 + rows.size * (row_height + 24)
    body = rows.map do |row|
      "<div class=\"row\"><div class=\"label\">#{escape(row['label'])}</div>" +
        row["images"].map { |image| "<img src=\"#{file_url(image)}\" alt=\"\">" }.join + "</div>"
    end.join
    html = <<~HTML
      <!doctype html><html><head><meta charset="utf-8">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file:; style-src 'unsafe-inline'">
      <style>html,body{margin:0;background:#fff;font-family:-apple-system,sans-serif}body{padding:24px;width:#{width}px;box-sizing:border-box}
      .row{display:flex;gap:24px;align-items:center;height:#{row_height}px;margin-bottom:24px}.label{width:196px;font-size:24px;font-weight:600}
      img{height:#{row_height}px;width:auto;max-width:200px;object-fit:contain;border-radius:8px;box-shadow:0 1px 4px rgba(0,0,0,.2)}</style></head>
      <body>#{body}</body></html>
    HTML
    html_path = File.join(out, "research-sheet.html")
    File.write(html_path, html)
    png = File.join(out, "research-sheet.png")
    screenshot(chrome_path, html_path, png, width, height)
    record = {"schemaVersion" => SCHEMA_VERSION, "kind" => "research-sheet", "rows" => rows.map do |row|
      {"label" => row["label"], "images" => row["images"].map { |image| {"path" => image, "sha256" => digest(image)} }}
    end, "rowHeight" => row_height, "image" => png, "imageSha256" => digest(png)}
    File.write(File.join(out, "research-sheet.json"), JSON.pretty_generate(record) + "\n")
    {"status" => "built", "image" => png, "rows" => rows.size}
  end

  # --- helpers -------------------------------------------------------------------------------------

  def new_folder(path, outside_git: false)
    fail!("--out must be a new folder: #{path} exists") if File.exist?(path) || File.symlink?(path)
    parent = File.dirname(File.expand_path(path))
    fail!("the parent of --out does not exist: #{parent}") unless File.directory?(parent)
    if outside_git
      top, _, status = Open3.capture3("git", "-C", parent, "rev-parse", "--show-toplevel")
      if status.success? && !top.strip.empty?
        # A folder pattern (`refs/`) matches only what is inside it, so the check asks about a file in the folder.
        _, _, ignored = Open3.capture3("git", "-C", parent, "check-ignore", "-q", File.join(File.expand_path(path), "research-sheet.png"))
        fail!("--out #{path} is inside the Git working tree #{top.strip}; put reference images outside Git") unless ignored.success?
      end
    end
    FileUtils.mkdir(path)
    File.realpath(path)
  end

  def existing_file(path, label)
    fail!("#{label} #{path} does not exist") unless File.file?(path)
    path
  end

  # Only local files: a URL (http, https, data or file) is refused, so a declaration cannot reach the network.
  def local_path(value, base, label)
    fail!("#{label} must be a file path") unless value.is_a?(String) && !value.empty?
    fail!("#{label} must be a local file, not a URL: #{value}") if value.match?(%r{\A[a-z][a-z0-9+.-]*:}i)
    path = File.expand_path(value, base)
    fail!("#{label} #{path} does not exist") unless File.file?(path)
    path
  end

  def exact!(value, label, required, optional = [])
    fail!("#{label} must be an object") unless value.is_a?(Hash)
    missing = required - value.keys
    extra = value.keys - required - optional
    fail!("#{label} lacks #{missing.join(', ')}") unless missing.empty?
    fail!("#{label} has unknown #{extra.join(', ')}") unless extra.empty?
  end

  def hex!(value, label)
    fail!("#{label} must be a #RRGGBB color") unless value.is_a?(String) && value.match?(HEX_PATTERN)
  end

  def number!(value, label, min, max)
    fail!("#{label} must be a number from #{min} to #{max}") unless value.is_a?(Numeric) && value >= min && value <= max
  end

  def text!(value, label)
    fail!("#{label} must be text") unless value.is_a?(String) && !value.strip.empty?
  end

  def png_size(path)
    bytes = File.binread(path, 24)
    fail!("#{path} is not a PNG") unless bytes&.start_with?("\x89PNG\r\n\x1A\n".b) && bytes.length >= 24
    [bytes[16, 4].unpack1("N"), bytes[20, 4].unpack1("N")]
  end

  def digest(path)
    "sha256:#{Digest::SHA256.file(path).hexdigest}"
  end

  def file_url(path)
    "file://" + File.expand_path(path).split("/").map { |part| part.gsub(/[^A-Za-z0-9._~-]/) { |c| c.bytes.map { |b| format("%%%02X", b) }.join } }.join("/")
  end

  def format_px(value)
    "#{value.round(2)}px"
  end

  def css_string(text)
    "'#{text.gsub(/['\\]/) { |c| "\\#{c}" }}'"
  end

  def escape(text)
    text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
  end
end

AppStoreCreativeCompose.run(ARGV.dup) if $PROGRAM_NAME == __FILE__
