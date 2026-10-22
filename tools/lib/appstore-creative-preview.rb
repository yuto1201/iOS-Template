#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "digest"
require "fileutils"
require "json"
require "open3"
require "time"
require "tmpdir"
require_relative "appstore-preview-quality"

# D-077: finish an App Store preview. `encode` takes recorded segments (from the dedicated-Simulator
# recorder, or the user's own screen recordings), passes each through the quality gate, feeds them to
# Goldie's preview encoder through the render extension, and checks the result against the preview
# format and the quality gate. `decide` records the user's explicit choice in preview-decision.json:
# adopt that exact video, or ship no video.
module AppStoreCreativePreview
  SCHEMA_VERSION = 1
  # The render extension's devices (D-079): iphone-6.3 takes the dedicated iPhone 17 Pro's 1206x2622
  # recordings to Goldie's 886x1920 iPhone preview, and ipad-13 takes 2064x2752 to 1200x1600.
  DEVICES = {
    "iphone-6.3" => {"family" => "iphone", "width" => 886, "height" => 1920},
    "ipad-13" => {"family" => "ipad", "width" => 1200, "height" => 1600}
  }.freeze
  DECISION_FILE = "preview-decision.json"
  LOCALES = %w[ja en-US].freeze
  SECONDS = (15.0..30.0).freeze
  FPS = 30
  MAX_BYTES = 500 * 1024 * 1024
  SEGMENT_PATTERN = /\A[a-z0-9][a-z0-9-]{0,31}\z/
  REVISION_PATTERN = /\A[a-z0-9][a-z0-9-]{0,63}\z/
  DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/
  REPO_ROOT = File.expand_path("../..", __dir__)
  # D-085 (#391): App Store product page header video (Creative assets specifications, checked
  # 2026-10-22): 21:9, 3840x1646, 30 or 60 fps, 5 to 30 seconds, .mov/.m4v/.mp4; it always loops and is
  # muted by default. The safe area is the one the render extension measured from Apple's template.
  HEADER = {"width" => 3840, "height" => 1646}.freeze
  HEADER_FPS = [30, 60].freeze
  HEADER_SECONDS = (5.0..30.0).freeze
  HEADER_SAFE_AREA = {"x" => 1097, "y" => 493, "width" => 1646, "height" => 661}.freeze
  HEADER_CROSSFADE = 0.5
  # Mean absolute difference (0-255) between the first and last frames, downscaled 10x, above which the
  # loop visibly jumps.
  HEADER_SEAM_THRESHOLD = 6.0
  # D-085 (#392): the specification table every exported App Store asset is checked against, with Apple's
  # pages and the day they were read. Screenshot sizes are those of D-079 (App Store/submission/
  # requirements.json); a table older than maxAgeDays stops the check until someone reads Apple's pages
  # again and updates it.
  ASSET_SPECS = {
    "checkedOn" => "2026-10-22",
    "maxAgeDays" => 90,
    "sources" => {
      "screenshot" => "https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/",
      "preview" => "https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications/",
      "creative" => "https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications/"
    },
    "kinds" => {
      "screenshot-iphone" => {"source" => "screenshot", "type" => "image", "formats" => %w[png jpg jpeg], "alpha" => false,
                              "sizes" => [[1206, 2622], [1179, 2556], [2622, 1206], [2556, 1179]]},
      "screenshot-ipad" => {"source" => "screenshot", "type" => "image", "formats" => %w[png jpg jpeg], "alpha" => false,
                            "sizes" => [[2064, 2752], [2048, 2732], [2752, 2064], [2732, 2048]]},
      "preview-iphone" => {"source" => "preview", "type" => "video", "formats" => %w[mov m4v mp4], "sizes" => [[886, 1920], [1920, 886]],
                           "seconds" => [15, 30], "fps" => [30], "codecs" => %w[h264 prores], "maxBytes" => MAX_BYTES},
      "preview-ipad" => {"source" => "preview", "type" => "video", "formats" => %w[mov m4v mp4], "sizes" => [[1200, 1600], [1600, 1200]],
                         "seconds" => [15, 30], "fps" => [30], "codecs" => %w[h264 prores], "maxBytes" => MAX_BYTES},
      "header-image" => {"source" => "creative", "type" => "image", "formats" => %w[png jpg jpeg], "alpha" => false, "sizes" => [[3840, 1646]]},
      "header-video" => {"source" => "creative", "type" => "video", "formats" => %w[mov m4v mp4], "sizes" => [[3840, 1646]],
                         "seconds" => [5, 30], "fps" => [30, 60]},
      "search-image" => {"source" => "creative", "type" => "image", "formats" => %w[png jpg jpeg], "alpha" => false,
                         "ratio" => [3, 2], "minSize" => [1920, 1280], "maxSize" => [3840, 2560]},
      "search-video" => {"source" => "creative", "type" => "video", "formats" => %w[mov m4v mp4], "ratio" => [3, 2],
                         "minSize" => [1920, 1280], "maxSize" => [3840, 2560], "seconds" => [5, 30], "fps" => [30, 60]},
      "universal-image" => {"source" => "creative", "type" => "image", "formats" => %w[png], "alpha" => false, "sizes" => [[5244, 2950]]}
    }
  }.freeze
  # Apple shows the frame at 5 seconds of an App Preview until another poster frame is chosen.
  DEFAULT_POSTER_SECONDS = 5.0

  class Failure < StandardError; end

  module_function

  def run(argv)
    command = argv.shift or fail!("command is required: encode, decide, encode-header or verify-header")
    options = parse_options(argv)
    value = case command
            when "encode" then encode(options)
            when "decide" then decide(options)
            when "encode-header" then encode_header(options)
            when "verify-header" then verify_header_command(options)
            when "describe-specs" then ASSET_SPECS
            when "check-assets" then check_assets(options)
            when "poster-frames" then poster_frames(options)
            else fail!("unknown command: #{command}")
            end
    puts JSON.generate(value)
  rescue Failure, AppStorePreviewQuality::Failure, JSON::ParserError, KeyError, ArgumentError, SystemCallError => error
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

  def regular!(path, label)
    fail!("#{label} must be a regular file: #{path}") unless File.file?(path) && !File.symlink?(path)
    path
  end

  def sha256(path)
    "sha256:#{Digest::SHA256.file(path).hexdigest}"
  end

  def capture!(*argv)
    output, error, status = Open3.capture3(*argv)
    fail!("#{File.basename(argv.first)} failed: #{error.lines.last(3).join.strip}") unless status.success?
    output
  end

  # --- encode --------------------------------------------------------------------------------------

  def encode(options)
    %w[config device locale output].each { |name| fail!("missing option: --#{name}") unless options.key?(name) }
    unknown = options.keys - %w[config device locale output record user-clips runtime]
    fail!("unknown option: --#{unknown.first}") unless unknown.empty?
    fail!("give exactly one of --record or --user-clips") unless options.key?("record") ^ options.key?("user-clips")
    device = options.fetch("device")
    target = DEVICES[device] or fail!("device must be iphone-6.3 or ipad-13")
    locale = options.fetch("locale")
    fail!("locale must be ja or en-US") unless LOCALES.include?(locale)
    config = regular!(File.expand_path(options.fetch("config")), "Goldie config")
    output = File.expand_path(options.fetch("output"))
    fail!("output already exists and is never replaced: #{output}") if File.exist?(output) || File.symlink?(output)

    clips = options.key?("record") ? recorded_clips(options.fetch("record"), device, locale) : user_clips(options.fetch("user-clips"))
    fail!("no clips to encode") if clips.empty?
    ids = clips.map { |clip| clip.fetch("segmentId") }
    fail!("clip segment ids must be unique") unless ids.uniq.length == ids.length

    clips.each do |clip|
      quality = AppStorePreviewQuality.check(clip: clip.fetch("file"), family: target.fetch("family"),
        seconds: clip.fetch("plannedSeconds"), allow_still: clip.fetch("allowStill"),
        minimum_size: clip.fetch("source") == "user-supplied")
      clip["quality"] = quality
      next if quality.fetch("status") == "passed"
      fail!("clip #{clip.fetch('segmentId')} failed the quality gate: #{quality.fetch('reasons').join('; ')}")
    end
    clips.each { |clip| clip["presentedSeconds"] = presented_seconds(clip) }
    total = clips.sum { |clip| clip.fetch("presentedSeconds") }
    fail!(format("the clips run %.2fs; a preview must run 15 to 30 seconds", total)) unless SECONDS.cover?(total.round(2))

    rendered = render_preview(config, device, locale, clips, options["runtime"])
    video = verify_video(rendered.fetch("path"), target)
    # The written preview passes the same gate: no black frames, no stutter, and its planned length.
    # Its exact size is checked above, so the gate's size rule here is only portrait and wide enough.
    output_quality = AppStorePreviewQuality.check(clip: rendered.fetch("path"), family: target.fetch("family"),
      seconds: clips.sum { |clip| clip.fetch("plannedSeconds") }, allow_still: clips.any? { |clip| clip.fetch("allowStill") },
      minimum_size: true)
    unless output_quality.fetch("status") == "passed"
      fail!("the encoded preview failed the quality gate: #{output_quality.fetch('reasons').join('; ')}")
    end

    parent = File.dirname(output)
    FileUtils.mkdir_p(parent)
    staging = Dir.mktmpdir(".preview.", parent)
    begin
      FileUtils.cp(rendered.fetch("path"), File.join(staging, "preview.mp4"))
      FileUtils.mkdir_p(File.join(staging, "quality"))
      clips.each do |clip|
        File.binwrite(File.join(staging, "quality", "#{clip.fetch('segmentId')}.json"), "#{JSON.pretty_generate(clip.fetch('quality'))}\n")
      end
      File.binwrite(File.join(staging, "quality", "preview.json"), "#{JSON.pretty_generate(output_quality)}\n")
      record = {
        "schemaVersion" => SCHEMA_VERSION,
        "status" => "encoded",
        "device" => device,
        "locale" => locale,
        "goldieVersion" => rendered.fetch("goldieVersion"),
        "source" => clips.first.fetch("source"),
        "clips" => clips.map do |clip|
          clip.slice("segmentId", "source", "sha256", "originalPath", "plannedSeconds", "allowStill")
            .merge("qualityStatus" => clip.dig("quality", "status"),
              "durationSeconds" => clip.fetch("presentedSeconds"))
        end,
        "video" => video.merge("path" => "preview.mp4", "sha256" => sha256(File.join(staging, "preview.mp4")),
          "qualityStatus" => output_quality.fetch("status"))
      }
      File.binwrite(File.join(staging, "encode.json"), "#{JSON.pretty_generate(record)}\n")
      File.rename(staging, output)
      staging = nil
      {"status" => "encoded", "output" => output, "video" => record.fetch("video")}
    ensure
      FileUtils.rm_rf(staging) if staging
    end
  end

  def recorded_clips(directory, device, locale)
    root = File.expand_path(directory)
    record = JSON.parse(File.binread(regular!(File.join(root, "record.json"), "recording record")))
    fail!("recording is for #{record['family']}/#{record['locale']}, not #{device}/#{locale}") unless
      record["family"] == device && record["locale"] == locale
    record.fetch("segments").map do |segment|
      fail!("recorded segment id is invalid") unless segment["id"].is_a?(String) && segment["id"].match?(SEGMENT_PATTERN)
      file = regular!(File.expand_path(segment.fetch("path"), root), "recorded clip")
      unless File.realpath(file).start_with?("#{File.realpath(root)}/")
        fail!("recorded clip #{segment['id']} lies outside its recording")
      end
      digest = sha256(file)
      fail!("recorded clip #{segment['id']} differs from its record") unless digest == segment["sha256"]
      {"segmentId" => segment["id"], "file" => file, "sha256" => digest, "source" => "simulator",
       "plannedSeconds" => Float(segment.fetch("seconds")), "allowStill" => segment.fetch("allowStill", false) == true}
    end
  end

  # The user's own screen recordings. The AI never drives the user's device; it only checks and
  # encodes what the user hands over, and records where each clip came from.
  def user_clips(path)
    list = JSON.parse(File.binread(regular!(File.expand_path(path), "user clip list")))
    fail!("user clip list must have schemaVersion 1 and clips") unless list.is_a?(Hash) && list.keys.sort == %w[clips schemaVersion] &&
      list["schemaVersion"] == 1 && list["clips"].is_a?(Array)
    base = File.dirname(File.expand_path(path))
    list.fetch("clips").map do |entry|
      fail!("user clip entry is invalid") unless entry.is_a?(Hash) && (entry.keys - %w[segmentId path allowStill]).empty? &&
        entry["segmentId"].is_a?(String) && entry["segmentId"].match?(SEGMENT_PATTERN) && entry["path"].is_a?(String)
      file = regular!(File.expand_path(entry["path"], base), "user clip")
      duration = Float(capture!("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", file).strip)
      {"segmentId" => entry["segmentId"], "file" => file, "sha256" => sha256(file), "source" => "user-supplied",
       "originalPath" => file, "plannedSeconds" => duration, "allowStill" => entry["allowStill"] == true}
    end
  end

  NODE_SCRIPT = <<~'JS'
    // The extension path is not the first argument, so the extension's own command-line entry stays idle.
    const [configPath, extension, device, locale, clipsJson, runtimeArg] = process.argv.slice(1);
    const { mkdirSync, readFileSync, writeFileSync, existsSync } = await import("node:fs");
    const { join } = await import("node:path");
    const { pathToFileURL } = await import("node:url");
    const ext = await import(pathToFileURL(extension).href);
    const runtime = runtimeArg || process.env.GOLDIE_RUNTIME || ext.defaultRuntime();
    const { goldie, version } = await ext.loadGoldie(runtime);
    ext.extend(goldie);
    const cfg = await goldie.loadConfig(configPath);
    const scene = cfg.scenes.find((entry) => entry.kind === "preview");
    if (!scene) throw new Error("the Goldie config has no preview scene");
    const clips = JSON.parse(clipsJson);
    const segments = scene.segments.map((segment) => segment.id);
    if (JSON.stringify(segments) !== JSON.stringify(clips.map((clip) => clip.segmentId))) {
      throw new Error(`preview scene segments ${segments.join(",")} differ from the clips ${clips.map((clip) => clip.segmentId).join(",")}`);
    }
    const rawDir = join(cfg.outDir, "raw", device);
    mkdirSync(rawDir, { recursive: true });
    const manifestPath = join(rawDir, "manifest.json");
    const manifest = existsSync(manifestPath)
      ? JSON.parse(readFileSync(manifestPath, "utf8"))
      : { device, udid: "", capturedAt: "", screenshots: [], preview: null };
    manifest.preview = { sceneId: scene.id, clips: clips.map((clip) => ({ segmentId: clip.segmentId, file: clip.file, durationSeconds: clip.durationSeconds })) };
    writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
    const log = console.log;
    console.log = (...args) => console.error(...args);
    let path;
    try {
      path = await goldie.renderPreview(cfg, device, locale);
    } finally {
      console.log = log;
    }
    if (!path) throw new Error("Goldie wrote no preview");
    process.stdout.write(`${JSON.stringify({ path, goldieVersion: version })}\n`);
  JS

  # The quality gate measures from the first frame to the last; a clip plays one more frame interval,
  # so a 15-second recording at 30 fps measures 14.967 seconds but is shown for 15.
  def presented_seconds(clip)
    metrics = clip.dig("quality", "metrics")
    frames = metrics.fetch("frames")
    (metrics.fetch("durationSeconds") * frames / (frames - 1)).round(3)
  end

  def render_preview(config, device, locale, clips, runtime)
    extension = File.join(REPO_ROOT, "tools", "lib", "appstore-creative-render.mjs")
    regular!(extension, "render extension")
    payload = clips.map do |clip|
      {"segmentId" => clip.fetch("segmentId"), "file" => clip.fetch("file"),
       "durationSeconds" => clip.fetch("presentedSeconds")}
    end
    output = capture!("node", "--input-type=module", "-e", NODE_SCRIPT, config, extension, device, locale,
      JSON.generate(payload), runtime.to_s)
    JSON.parse(output.lines.last)
  end

  def verify_video(path, target)
    regular!(path, "encoded preview")
    probe = JSON.parse(capture!("ffprobe", "-v", "error", "-show_entries",
      "stream=codec_type,codec_name,width,height,avg_frame_rate:format=duration", "-of", "json", path))
    video = probe.fetch("streams").find { |stream| stream["codec_type"] == "video" } or fail!("encoded preview has no video")
    audio = probe.fetch("streams").find { |stream| stream["codec_type"] == "audio" }
    duration = Float(probe.dig("format", "duration"))
    numerator, denominator = video.fetch("avg_frame_rate").split("/").map(&:to_f)
    fps = denominator.to_f.positive? ? numerator / denominator : 0.0
    problems = []
    problems << "size #{video['width']}x#{video['height']} is not #{target['width']}x#{target['height']}" unless
      [video["width"], video["height"]] == [target["width"], target["height"]]
    problems << "codec #{video['codec_name']} is not h264" unless video["codec_name"] == "h264"
    problems << format("frame rate %.2f is not %d", fps, FPS) unless (fps - FPS).abs < 0.01
    problems << format("duration %.2fs is outside 15 to 30 seconds", duration) unless SECONDS.cover?(duration.round(2))
    problems << "audio track is missing" unless audio
    problems << "file is larger than 500 MB" if File.size(path) > MAX_BYTES
    fail!("encoded preview breaks the preview format: #{problems.join('; ')}") unless problems.empty?
    {"width" => video["width"], "height" => video["height"], "codec" => "h264", "fps" => FPS,
     "durationSeconds" => duration.round(3), "audioCodec" => audio["codec_name"], "bytes" => File.size(path)}
  end

  # --- product page header video (D-085, #391) -----------------------------------------------------

  def probe(path)
    JSON.parse(capture!("ffprobe", "-v", "error", "-show_entries",
      "stream=codec_type,codec_name,width,height,avg_frame_rate:format=duration", "-of", "json", path))
  end

  def frame_rate(stream)
    numerator, denominator = stream.fetch("avg_frame_rate").split("/").map(&:to_f)
    denominator.to_f.positive? ? numerator / denominator : 0.0
  end

  # Places a recording (or nothing, for a still header) on a rendered header background and writes a
  # silent H.264 loop. By default the last half second crossfades into the start, so the loop has no jump.
  def encode_header(options)
    %w[background output].each { |name| fail!("missing option: --#{name}") unless options.key?(name) }
    unknown = options.keys - %w[background output clip screen seconds fps loop seam-threshold screen-role]
    fail!("unknown option: --#{unknown.first}") unless unknown.empty?
    background = regular!(File.expand_path(options.fetch("background")), "header background")
    output = File.expand_path(options.fetch("output"))
    fail!("output already exists and is never replaced: #{output}") if File.exist?(output) || File.symlink?(output)
    fail!("header output must be .mp4, .mov or .m4v") unless %w[.mp4 .mov .m4v].include?(File.extname(output).downcase)
    fps = Integer(options.fetch("fps", "30"), 10)
    fail!("header fps must be 30 or 60") unless HEADER_FPS.include?(fps)
    loop_mode = options.fetch("loop", "crossfade")
    fail!("--loop must be crossfade or none") unless %w[crossfade none].include?(loop_mode)
    still = probe(background).fetch("streams").find { |stream| stream["codec_type"] == "video" } or fail!("header background is not an image")
    unless [still["width"], still["height"]] == HEADER.values_at("width", "height")
      fail!("header background is #{still['width']}x#{still['height']}; a product page header is 3840x1646")
    end
    filter = nil
    inputs = ["-loop", "1", "-framerate", fps.to_s, "-i", background]
    if options.key?("clip")
      clip = regular!(File.expand_path(options.fetch("clip")), "header clip")
      info = probe(clip)
      video = info.fetch("streams").find { |stream| stream["codec_type"] == "video" } or fail!("header clip has no video")
      length = Float(info.dig("format", "duration"))
      fade = loop_mode == "crossfade" ? HEADER_CROSSFADE : 0.0
      seconds = (length - fade).round(3)
      unless HEADER_SECONDS.cover?(seconds)
        fail!(format("the header video would run %.2f seconds; a product page header runs 5 to 30 seconds", seconds))
      end
      screen = (options["screen"] or fail!("--clip needs --screen x,y,width as fractions of the header")).split(",").map { |part| Float(part) }
      fail!("--screen must be x,y,width") unless screen.length == 3 && screen[2].positive?
      width = (screen[2] * HEADER["width"] / 2).round * 2
      height = (width * video.fetch("height").to_f / video.fetch("width") / 2).round * 2
      x = (screen[0] * HEADER["width"]).round
      y = (screen[1] * HEADER["height"]).round
      role = options.fetch("screen-role", "focal")
      fail!("--screen-role must be focal or decoration") unless %w[focal decoration].include?(role)
      area = HEADER_SAFE_AREA
      if role == "focal" && !(x >= area["x"] && y >= area["y"] && x + width <= area["x"] + area["width"] && y + height <= area["y"] + area["height"])
        fail!("the clip on the header runs outside the safe area (#{area['x']},#{area['y']} #{area['width']}x#{area['height']}); move or shrink it")
      end
      inputs += ["-i", clip]
      scaled = "[1:v]fps=#{fps},scale=#{width}:#{height},setsar=1"
      filter = if fade.positive?
                 "#{scaled},split[s1][s2];[s1]trim=start=#{fade},setpts=PTS-STARTPTS[a];[s2]trim=end=#{fade},setpts=PTS-STARTPTS[b];" \
                   "[a][b]xfade=transition=fade:duration=#{fade}:offset=#{(length - 2 * fade).round(3)}[c];" \
                   "[0:v]fps=#{fps}[bg];[bg][c]overlay=#{x}:#{y}:shortest=1,format=yuv420p[v]"
               else
                 "#{scaled}[c];[0:v]fps=#{fps}[bg];[bg][c]overlay=#{x}:#{y}:shortest=1,format=yuv420p[v]"
               end
    else
      seconds = Float(options["seconds"] || fail!("a still header needs --seconds"))
      fail!(format("the header video would run %.2f seconds; a product page header runs 5 to 30 seconds", seconds)) unless HEADER_SECONDS.cover?(seconds)
      filter = "[0:v]fps=#{fps},format=yuv420p[v]"
    end
    FileUtils.mkdir_p(File.dirname(output))
    # The video is made in a directory this run creates, published with a hard link (which refuses an
    # existing destination), and only that directory is removed: nothing else beside the output is touched.
    work = Dir.mktmpdir(".encode-header-", File.dirname(output))
    begin
      staging = File.join(work, "header#{File.extname(output)}")
      capture!("ffmpeg", "-loglevel", "error", *inputs, "-filter_complex", filter, "-map", "[v]", "-t", seconds.to_s,
        "-an", "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p", "-r", fps.to_s,
        "-movflags", "+faststart", staging)
      result = verify_header(staging, fps, Float(options.fetch("seam-threshold", HEADER_SEAM_THRESHOLD.to_s)))
      begin
        File.link(staging, output)
      rescue Errno::EEXIST
        fail!("output already exists and is never replaced: #{output}")
      end
      result.merge("status" => "encoded", "output" => output, "sha256" => sha256(output), "loop" => loop_mode,
                   "backgroundSha256" => sha256(background), "clipSha256" => options.key?("clip") ? sha256(File.expand_path(options["clip"])) : nil)
    ensure
      FileUtils.rm_rf(work)
    end
  end

  def raw_frame(arguments)
    data = capture!("ffmpeg", "-loglevel", "error", *arguments, "-vf", "scale=384:164", "-f", "rawvideo", "-pix_fmt", "rgb24", "-")
    frame = 384 * 164 * 3
    fail!("could not read a frame of the header video") if data.bytesize < frame
    data.byteslice(data.bytesize - frame, frame)
  end

  # Checks a header video against the format and the loop seam: the first and last frames must match.
  def verify_header(path, fps = nil, threshold = HEADER_SEAM_THRESHOLD)
    regular!(path, "header video")
    info = probe(path)
    video = info.fetch("streams").find { |stream| stream["codec_type"] == "video" } or fail!("header video has no video")
    audio = info.fetch("streams").any? { |stream| stream["codec_type"] == "audio" }
    duration = Float(info.dig("format", "duration"))
    rate = frame_rate(video)
    problems = []
    problems << "size #{video['width']}x#{video['height']} is not 3840x1646" unless [video["width"], video["height"]] == HEADER.values_at("width", "height")
    problems << "codec #{video['codec_name']} is not h264" unless video["codec_name"] == "h264"
    actual_fps = HEADER_FPS.find { |value| (rate - value).abs < 0.01 }
    problems << format("frame rate %.2f is not 30 or 60", rate) unless actual_fps
    problems << format("frame rate %.2f is not the requested %d", rate, fps) if fps && actual_fps && actual_fps != fps
    problems << format("duration %.2fs is outside 5 to 30 seconds", duration) unless HEADER_SECONDS.cover?(duration.round(2))
    problems << "it has an audio track; a header is silent by default" if audio
    fail!("header video breaks the header format: #{problems.join('; ')}") unless problems.empty?
    first = raw_frame(["-i", path, "-frames:v", "1"])
    last = raw_frame(["-sseof", "-0.5", "-i", path])
    total = 0
    first.bytesize.times { |index| total += (first.getbyte(index) - last.getbyte(index)).abs }
    seam = (total.to_f / first.bytesize).round(2)
    if seam > threshold
      fail!(format("the loop seam differs by %.2f between the first and last frames; at most %.2f", seam, threshold))
    end
    {"width" => video["width"], "height" => video["height"], "codec" => "h264", "fps" => actual_fps,
     "durationSeconds" => duration.round(3), "audio" => false, "seam" => seam, "safeArea" => HEADER_SAFE_AREA}
  end

  def verify_header_command(options)
    fail!("missing option: --video") unless options.key?("video")
    unknown = options.keys - %w[video seam-threshold]
    fail!("unknown option: --#{unknown.first}") unless unknown.empty?
    path = File.expand_path(options.fetch("video"))
    verify_header(path, nil, Float(options.fetch("seam-threshold", HEADER_SEAM_THRESHOLD.to_s)))
      .merge("status" => "valid", "video" => path, "sha256" => sha256(path))
  end

  # --- specification table and asset check (D-085, #392) -------------------------------------------

  def spec_age_days(today)
    (Date.parse(today) - Date.parse(ASSET_SPECS.fetch("checkedOn"))).to_i
  end

  # Checks one exported asset against the table, after checking that the table itself is recent.
  def check_assets(options)
    %w[kind file].each { |name| fail!("missing option: --#{name}") unless options.key?(name) }
    unknown = options.keys - %w[kind file max-age-days today]
    fail!("unknown option: --#{unknown.first}") unless unknown.empty?
    today = options.fetch("today", Time.now.utc.strftime("%Y-%m-%d"))
    fail!("--today must be a YYYY-MM-DD date") unless today.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    max_age = Integer(options.fetch("max-age-days", ASSET_SPECS.fetch("maxAgeDays").to_s), 10)
    age = spec_age_days(today)
    if age > max_age
      fail!("the asset spec table was checked on #{ASSET_SPECS.fetch('checkedOn')}, #{age} days ago (more than #{max_age}); " \
            "read Apple's current specifications and update it before checking assets")
    end
    kind = options.fetch("kind")
    spec = ASSET_SPECS.fetch("kinds")[kind] or fail!("unknown asset kind: #{kind}; known kinds: #{ASSET_SPECS.fetch('kinds').keys.join(', ')}")
    path = regular!(File.expand_path(options.fetch("file")), "asset")
    problems = []
    extension = File.extname(path).delete_prefix(".").downcase
    problems << "format .#{extension} is not one of #{spec.fetch('formats').map { |item| ".#{item}" }.join(', ')}" unless spec.fetch("formats").include?(extension)
    info = probe(path)
    video = info.fetch("streams").find { |stream| stream["codec_type"] == "video" } or fail!("asset #{File.basename(path)} has no image or video stream")
    size = [video["width"], video["height"]]
    if spec["sizes"]
      problems << "size #{size.join('x')} is not one of #{spec['sizes'].map { |item| item.join('x') }.join(', ')}" unless spec["sizes"].include?(size)
    else
      ratio_ok = size[0] * spec["ratio"][1] == size[1] * spec["ratio"][0]
      range_ok = size[0].between?(spec["minSize"][0], spec["maxSize"][0]) && size[1].between?(spec["minSize"][1], spec["maxSize"][1])
      unless ratio_ok && range_ok
        problems << "size #{size.join('x')} is not #{spec['ratio'].join(':')} from #{spec['minSize'].join('x')} to #{spec['maxSize'].join('x')}"
      end
    end
    if spec.fetch("type") == "image"
      if extension == "png"
        color = File.binread(path, 26).getbyte(25)
        problems << "the PNG has an alpha channel" if [4, 6].include?(color) && spec["alpha"] == false
      end
    else
      duration = Float(info.dig("format", "duration"))
      low, high = spec.fetch("seconds")
      problems << format("duration %.2fs is outside %d to %d seconds", duration, low, high) unless duration.round(2).between?(low, high)
      rate = frame_rate(video)
      problems << format("frame rate %.2f is not %s", rate, spec.fetch("fps").join(" or ")) unless spec.fetch("fps").any? { |value| (rate - value).abs < 0.01 }
      problems << "codec #{video['codec_name']} is not #{spec['codecs'].join(' or ')}" if spec["codecs"] && !spec["codecs"].include?(video["codec_name"])
      problems << "file is larger than #{spec['maxBytes'] / 1024 / 1024} MB" if spec["maxBytes"] && File.size(path) > spec["maxBytes"]
    end
    fail!("#{File.basename(path)} does not meet the #{kind} specification: #{problems.join('; ')}") unless problems.empty?
    {"status" => "conforms", "kind" => kind, "file" => path, "sha256" => sha256(path), "width" => size[0], "height" => size[1],
     "specCheckedOn" => ASSET_SPECS.fetch("checkedOn"), "source" => ASSET_SPECS.fetch("sources").fetch(spec.fetch("source"))}
  end

  # --- poster frame candidates (D-085, #392) -------------------------------------------------------

  # Extracts one still per candidate time from an encoded App Preview for the poster sheet. Every time
  # must lie inside the video; the stills and their record go to a new directory.
  def poster_frames(options)
    %w[video times out].each { |name| fail!("missing option: --#{name}") unless options.key?(name) }
    unknown = options.keys - %w[video times out]
    fail!("unknown option: --#{unknown.first}") unless unknown.empty?
    video = regular!(File.expand_path(options.fetch("video")), "preview video")
    out = File.expand_path(options.fetch("out"))
    fail!("poster frame directory already exists and is never replaced: #{out}") if File.exist?(out) || File.symlink?(out)
    duration = Float(probe(video).dig("format", "duration"))
    times = options.fetch("times").split(",").map { |item| Float(item) }
    fail!("give one to six poster frame times") unless (1..6).cover?(times.length) && times.uniq.length == times.length
    times.each do |seconds|
      next if seconds >= 0 && seconds < duration
      fail!(format("poster frame time %.2f is outside the %.2f-second preview", seconds, duration))
    end
    work = Dir.mktmpdir(".poster-frames-", File.dirname(out))
    begin
      frames = times.map do |seconds|
        id = "t#{format('%.2f', seconds).sub(/\.?0+\z/, '').tr('.', '-')}"
        image = File.join(work, "#{id}.png")
        capture!("ffmpeg", "-loglevel", "error", "-ss", seconds.to_s, "-i", video, "-frames:v", "1", "-vf", "format=rgb24", image)
        {"id" => id, "seconds" => seconds, "image" => "#{id}.png", "sha256" => sha256(image)}
      end
      record = {"schemaVersion" => SCHEMA_VERSION, "video" => video, "videoSha256" => sha256(video), "durationSeconds" => duration.round(3),
                "defaultSeconds" => DEFAULT_POSTER_SECONDS, "frames" => frames}
      File.write(File.join(work, "poster-frames.json"), "#{JSON.pretty_generate(record)}\n")
      File.rename(work, out)
      work = nil
      record.merge("status" => "extracted", "directory" => out)
    ensure
      FileUtils.rm_rf(work) if work
    end
  end

  # --- decide --------------------------------------------------------------------------------------

  # preview-decision.json records the user's explicit answer once: adopt one encoded preview whose clips
  # and video all passed the quality gate, or ship no video, which can be chosen at any point.
  def decide(options)
    %w[output revision decision reason].each { |name| fail!("missing option: --#{name}") unless options.key?(name) }
    unknown = options.keys - %w[output revision decision reason encode trial]
    fail!("unknown option: --#{unknown.first}") unless unknown.empty?
    revision = options.fetch("revision")
    fail!("revision must be lowercase letters, digits, and hyphens") unless revision.match?(REVISION_PATTERN)
    reason = options.fetch("reason").strip
    fail!("a decision needs a reason") if reason.empty?
    output = File.expand_path(options.fetch("output"))
    fail!("the decision file must be named #{DECISION_FILE}") unless File.basename(output) == DECISION_FILE
    fail!("a preview decision is already recorded and is never replaced") if File.exist?(output) || File.symlink?(output)

    value = {"schemaVersion" => SCHEMA_VERSION, "revision" => revision, "decision" => nil, "reason" => reason}
    case options.fetch("decision")
    when "adopt"
      fail!("adopting a preview needs --encode") unless options.key?("encode")
      value["decision"] = "adopt"
      value.merge!(adopted_preview(File.expand_path(options.fetch("encode"))))
    when "no-video"
      fail!("no-video does not take --encode") if options.key?("encode")
      value["decision"] = "no-video"
    else
      fail!("decision must be adopt or no-video")
    end
    if options.key?("trial")
      trial = regular!(File.expand_path(options.fetch("trial")), "trial quality record")
      result = JSON.parse(File.binread(trial))
      fail!("trial quality record is invalid") unless result.is_a?(Hash) && %w[passed failed].include?(result["status"])
      value["trial"] = {"path" => trial, "sha256" => sha256(trial), "status" => result["status"]}
    end
    value["choice"] = "user-explicit"
    value["recordedAt"] = Time.now.utc.iso8601
    FileUtils.mkdir_p(File.dirname(output))
    File.open(output, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write("#{JSON.pretty_generate(value)}\n") }
    {"status" => "decided", "decision" => value["decision"], "output" => output}
  end

  # A saved quality result counts only as a regular file that passed for exactly the given file.
  def passed_result?(path, digest)
    return false unless File.file?(path) && !File.symlink?(path)
    result = JSON.parse(File.binread(path))
    result.is_a?(Hash) && result["status"] == "passed" && result["clipSha256"] == digest
  rescue JSON::ParserError
    false
  end

  def adopted_preview(directory)
    encode_record = regular!(File.join(directory, "encode.json"), "encode record")
    record = JSON.parse(File.binread(encode_record))
    fail!("the encode record is not a finished encode") unless record.is_a?(Hash) && record["status"] == "encoded"
    target = DEVICES[record["device"]] or fail!("the encode record names an unknown device")
    clips = record.fetch("clips")
    fail!("the encode record has no clips") unless clips.is_a?(Array) && !clips.empty?
    failed = clips.reject do |clip|
      clip["qualityStatus"] == "passed" && passed_result?(File.join(directory, "quality", "#{clip['segmentId']}.json"), clip["sha256"])
    end
    fail!("a clip did not pass the quality gate: #{failed.map { |clip| clip['segmentId'] }.join(', ')}") unless failed.empty?
    fail!("the encoded preview did not pass the quality gate") unless record.dig("video", "qualityStatus") == "passed"
    video = regular!(File.join(directory, "preview.mp4"), "encoded preview")
    fail!("the encoded preview differs from its record") unless record.dig("video", "path") == "preview.mp4" &&
      sha256(video) == record.dig("video", "sha256")
    # The format check below cannot see freezes, stutter or black frames, so the saved final result
    # must be a pass for this very file.
    unless passed_result?(File.join(directory, "quality", "preview.json"), sha256(video))
      fail!("the encoded preview has no passing quality result for this video")
    end
    # The adopted file is checked against the preview format once more at the moment of the choice.
    verify_video(video, target)
    {"video" => {"path" => video, "sha256" => record.dig("video", "sha256"), "device" => record["device"], "locale" => record["locale"],
                 "source" => record["source"]},
     "encode" => {"path" => encode_record, "sha256" => sha256(encode_record)}}
  end
end

AppStoreCreativePreview.run(ARGV) if $PROGRAM_NAME == __FILE__
