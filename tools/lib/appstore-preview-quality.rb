#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"

# D-077: the machine quality gate for App Store preview footage. A trial clip from a dedicated
# Simulator, or the user's own screen recording, passes only when its size matches the device,
# it plays at a full frame rate for the planned time, and it neither freezes, skips frames, nor
# shows black frames. A failed trial ends the preview work with a recorded "no video" decision.
module AppStorePreviewQuality
  # Simulator recordings keep the dedicated device's native portrait screen size: iPhone 17 Pro
  # (D-079) and iPad Pro 13-inch (M5).
  FAMILY_SIZES = {
    "iphone" => [1206, 2622],
    "ipad" => [2064, 2752]
  }.freeze
  # A user's own screen recording comes from whatever device they own; it needs only to be portrait
  # and at least as wide as the App Store preview it becomes.
  PREVIEW_WIDTHS = {"iphone" => 886, "ipad" => 1200}.freeze
  # At least 30 frames per second on average over the clip, as the App Store preview plays at 30 fps.
  MIN_AVERAGE_FPS = 30.0
  # A gap longer than this between two frames is a visible stutter (about three frames at 30 fps).
  MAX_FRAME_GAP_SECONDS = 0.1
  # More than this share of the clip spent in such gaps is a stuttering clip even if each gap is short.
  MAX_GAP_SHARE = 0.02
  DURATION_TOLERANCE_SECONDS = 0.5
  FREEZE_NOISE = "0.003"
  FREEZE_MIN_SECONDS = 0.5
  BLACK_MIN_SECONDS = 0.1
  BLACK_PIXEL_THRESHOLD = "0.10"

  class Failure < StandardError; end

  module_function

  def check(clip:, family:, seconds:, allow_still: false, minimum_size: false)
    raise Failure, "family must be iphone or ipad" unless FAMILY_SIZES.key?(family)
    raise Failure, "planned seconds must be positive" unless seconds.is_a?(Numeric) && seconds.positive?
    raise Failure, "clip must be a regular file: #{clip}" unless File.file?(clip) && !File.symlink?(clip)

    stream = probe_stream(clip)
    times = frame_times(clip)
    raise Failure, "clip has no video frames" if times.length < 2

    width, height = stream.values_at("width", "height")
    duration = times.last - times.first
    gaps = times.each_cons(2).map { |a, b| b - a }
    long_gaps = gaps.select { |gap| gap > MAX_FRAME_GAP_SECONDS }
    average_fps = duration.positive? ? (times.length - 1) / duration : 0.0
    frozen = filter_intervals(clip, "freezedetect=n=#{FREEZE_NOISE}:d=#{FREEZE_MIN_SECONDS}", "freeze", times.last)
    black = filter_intervals(clip, "blackdetect=d=#{BLACK_MIN_SECONDS}:pix_th=#{BLACK_PIXEL_THRESHOLD}", "black", times.last)

    reasons = []
    expected = FAMILY_SIZES.fetch(family)
    if minimum_size
      unless height > width && width >= PREVIEW_WIDTHS.fetch(family)
        reasons << "size #{width}x#{height} is not a portrait recording at least #{PREVIEW_WIDTHS.fetch(family)} wide"
      end
    elsif [width, height] != expected
      reasons << "size #{width}x#{height} is not the #{family} screen #{expected.join('x')}"
    end
    if (duration - seconds).abs > DURATION_TOLERANCE_SECONDS
      reasons << format("clip runs %.2fs; the plan is %.2fs", duration, seconds)
    end
    unless allow_still
      reasons << format("average frame rate %.1f fps is below %.0f fps", average_fps, MIN_AVERAGE_FPS) if average_fps.round(2) < MIN_AVERAGE_FPS
      unless long_gaps.empty?
        reasons << format("%d frame gaps longer than %.0f ms (longest %.0f ms)", long_gaps.length, MAX_FRAME_GAP_SECONDS * 1000, long_gaps.max * 1000)
      end
      if duration.positive? && long_gaps.sum / duration > MAX_GAP_SHARE
        reasons << format("%.1f%% of the clip is spent in frame gaps", 100 * long_gaps.sum / duration)
      end
      reasons << format("the picture freezes for %.2fs", frozen.sum) unless frozen.empty?
    end
    reasons << format("black frames for %.2fs", black.sum) unless black.empty?

    {
      "schemaVersion" => 1,
      "status" => reasons.empty? ? "passed" : "failed",
      "reasons" => reasons,
      "clipSha256" => "sha256:#{Digest::SHA256.file(clip).hexdigest}",
      "family" => family,
      "plannedSeconds" => seconds,
      "allowStill" => allow_still,
      "sizeRule" => minimum_size ? "minimum" : "native",
      "metrics" => {
        "width" => width, "height" => height, "codec" => stream["codec_name"],
        "durationSeconds" => duration.round(3), "frames" => times.length,
        "averageFps" => average_fps.round(2), "longestGapMs" => (gaps.max * 1000).round,
        "longGaps" => long_gaps.length, "frozenSeconds" => frozen.sum.round(3), "blackSeconds" => black.sum.round(3)
      },
      "thresholds" => {
        "minAverageFps" => MIN_AVERAGE_FPS, "maxFrameGapMs" => (MAX_FRAME_GAP_SECONDS * 1000).round,
        "maxGapShare" => MAX_GAP_SHARE, "durationToleranceSeconds" => DURATION_TOLERANCE_SECONDS,
        "freezeMinSeconds" => FREEZE_MIN_SECONDS, "blackMinSeconds" => BLACK_MIN_SECONDS
      }
    }
  end

  def run_tool(*argv)
    output, error, status = Open3.capture3(*argv)
    raise Failure, "#{argv.first} failed: #{error.lines.last&.strip}" unless status.success?
    [output, error]
  end

  def probe_stream(clip)
    output, = run_tool("ffprobe", "-v", "error", "-select_streams", "v:0",
      "-show_entries", "stream=width,height,codec_name", "-of", "json", clip)
    stream = JSON.parse(output).fetch("streams").first or raise Failure, "clip has no video stream"
    stream
  end

  def frame_times(clip)
    output, = run_tool("ffprobe", "-v", "error", "-select_streams", "v:0",
      "-show_entries", "frame=best_effort_timestamp_time", "-of", "csv=p=0", clip)
    output.lines.map(&:strip).reject(&:empty?).map { |line| Float(line.delete_suffix(",")) }.sort
  end

  # Durations of the intervals a detection filter reports. A freeze or black run that lasts until the
  # end of the clip is reported with a start but no end, so it runs to the last frame.
  def filter_intervals(clip, filter, prefix, last_time)
    _, error = run_tool("ffmpeg", "-hide_banner", "-nostats", "-i", clip, "-vf", filter, "-an", "-f", "null", "-")
    starts = error.scan(/#{prefix}_start:\s*([0-9.]+)/).flatten.map { |value| Float(value) }
    ends = error.scan(/#{prefix}_end:\s*([0-9.]+)/).flatten.map { |value| Float(value) }
    starts.each_with_index.map { |start, index| (ends[index] || last_time) - start }.select(&:positive?)
  end

  def main(argv)
    options = {}
    until argv.empty?
      key = argv.shift
      case key
      when "--clip", "--family", "--seconds", "--output"
        value = argv.shift or raise Failure, "missing value for #{key}"
        options[key.delete_prefix("--")] = value
      when "--allow-still" then options["allow-still"] = true
      when "--minimum-size" then options["minimum-size"] = true
      else raise Failure, "unexpected argument: #{key}"
      end
    end
    %w[clip family seconds].each { |name| raise Failure, "missing option: --#{name}" unless options.key?(name) }
    result = check(clip: options.fetch("clip"), family: options.fetch("family"),
      seconds: Float(options.fetch("seconds")), allow_still: options.fetch("allow-still", false),
      minimum_size: options.fetch("minimum-size", false))
    json = "#{JSON.pretty_generate(result)}\n"
    if options["output"]
      raise Failure, "quality record already exists: #{options['output']}" if File.exist?(options["output"])
      File.open(options["output"], File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(json) }
    end
    print json
    exit(result.fetch("status") == "passed" ? 0 : 3)
  rescue Failure, ArgumentError, KeyError, JSON::ParserError => error
    warn error.message
    exit 1
  end
end

AppStorePreviewQuality.main(ARGV) if $PROGRAM_NAME == __FILE__
