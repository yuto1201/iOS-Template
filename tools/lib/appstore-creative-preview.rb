#!/usr/bin/env ruby
# frozen_string_literal: true

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

  class Failure < StandardError; end

  module_function

  def run(argv)
    command = argv.shift or fail!("command is required: encode or decide")
    options = parse_options(argv)
    value = case command
            when "encode" then encode(options)
            when "decide" then decide(options)
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
