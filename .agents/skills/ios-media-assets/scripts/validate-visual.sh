#!/bin/bash
set -euo pipefail

script_directory=$(cd "$(dirname "$0")" && pwd -P)

fail() {
  printf '%s\n' "visual validation failed: $1" >&2
  exit 1
}

[[ $# -eq 4 && $1 == --root && $3 == --manifest ]] || {
  echo 'usage: validate-visual.sh --root REPOSITORY --manifest RELATIVE_MANIFEST' >&2
  exit 2
}
repository_root=${2:-}
manifest_relative=${4:-}
[[ "$repository_root" == /* && -d "$repository_root" && ! -L "$repository_root" ]] || fail 'repository root is invalid'
repository_root=$(cd "$repository_root" && /bin/pwd -P)
[[ "$manifest_relative" != /* && "$manifest_relative" != *'..'* && "$manifest_relative" == *.yml ]] || fail 'manifest path is invalid'
manifest_file="$repository_root/$manifest_relative"
[[ -f "$manifest_file" && ! -L "$manifest_file" ]] || fail 'manifest is unavailable'

MANIFEST="$manifest_file" ROOT="$repository_root" INSPECTOR="$script_directory/inspect-visual.swift" /usr/bin/ruby -rjson -ryaml -rdigest -rtime -ropen3 -rtmpdir -e '
  def refuse(message); warn message; exit 1; end
  value=YAML.safe_load(File.binread(ENV.fetch("MANIFEST")), permitted_classes: [], aliases: false)
  keys=%w[schemaVersion mode purpose prompt model sourceDigests widthPixels heightPixels durationSeconds format assetPath licenseNote sha256 processedAt]
  refuse("manifest schema differs") unless value.is_a?(Hash) && value.keys.sort == keys.sort && value["schemaVersion"] == 1
  mode=value["mode"]
  refuse("mode is invalid") unless %w[image video].include?(mode)
  safe_text=/\A[^\u0000-\u001f\u007f]{1,2048}\z/
  %w[purpose prompt model licenseNote].each{|key| refuse("#{key} is invalid") unless value[key].is_a?(String) && value[key].match?(safe_text)}
  secret_pattern=/(xi-api-key|api[_ -]?key|secret[_ -]?key|service_role|-----begin [a-z ]*private key-----|password\s*=)/i
  refuse("manifest contains a credential pattern") if value.values.grep(String).any?{|entry| entry.match?(secret_pattern)}
  digest_pattern=/\Asha256:[0-9a-f]{64}\z/
  sources=value["sourceDigests"]
  refuse("sourceDigests is invalid") unless sources.is_a?(Array) && sources.uniq == sources && sources.all?{|entry| entry.is_a?(String) && entry.match?(digest_pattern)}
  width=value["widthPixels"]; height=value["heightPixels"]
  refuse("dimensions are invalid") unless width.is_a?(Integer) && height.is_a?(Integer) && width.between?(1,16384) && height.between?(1,16384)
  format=value["format"]
  refuse("format differs from mode") unless (mode == "image" && format == "png") || (mode == "video" && format == "mp4")
  duration=value["durationSeconds"]
  if mode == "image"
    refuse("image duration must be null") unless duration.nil?
  else
    refuse("video duration is invalid") unless duration.is_a?(Numeric) && duration.finite? && duration.between?(0.1,600.0)
  end
  relative=value["assetPath"]
  refuse("assetPath is invalid") unless relative.is_a?(String) && !relative.start_with?("/") && relative.split("/",-1).all?{|part| !part.empty? && part != "." && part != ".."}
  refuse("asset extension differs") unless File.extname(relative).delete_prefix(".").downcase == format
  asset=File.join(ENV.fetch("ROOT"),relative)
  refuse("asset is unavailable") unless File.file?(asset) && !File.symlink?(asset) && File.stat(asset).nlink == 1
  refuse("asset escapes repository") unless File.realpath(asset).start_with?(ENV.fetch("ROOT")+File::SEPARATOR)
  bytes=File.binread(asset)
  refuse("PNG signature is invalid") if mode == "image" && !bytes.start_with?("\x89PNG\r\n\x1A\n".b)
  refuse("MP4 signature is invalid") if mode == "video" && !(bytes.bytesize >= 12 && bytes.byteslice(4,4) == "ftyp")
  expected=value["sha256"]
  refuse("sha256 is invalid") unless expected.is_a?(String) && expected.match?(digest_pattern)
  refuse("visual hash differs") unless expected == "sha256:#{Digest::SHA256.hexdigest(bytes)}"
  begin; Time.iso8601(value["processedAt"]); rescue ArgumentError, TypeError; refuse("processedAt is invalid"); end
  output=nil
  Dir.mktmpdir("ios-template-visual-inspector") do |directory|
    binary=File.join(directory,"inspect-visual")
    _,compile_status=Open3.capture2e("/usr/bin/xcrun","swiftc","-parse-as-library",ENV.fetch("INSPECTOR"),"-o",binary)
    refuse("visual inspector could not compile") unless compile_status.success? && File.executable?(binary)
    output,status=Open3.capture2e(binary,mode,asset)
    refuse("visual inspector failed") unless status.success?
  end
  begin
    measured=JSON.parse(output)
  rescue JSON::ParserError
    refuse("visual inspection output is invalid")
  end
  refuse("visual dimensions differ") unless measured["widthPixels"] == width && measured["heightPixels"] == height
  if mode == "video"
    actual=measured["durationSeconds"]
    refuse("video duration differs") unless actual.is_a?(Numeric) && (actual-duration.to_f).abs <= [0.05,duration.to_f*0.02].max
  end
  puts JSON.generate({"durationSeconds"=>measured["durationSeconds"],"format"=>format,"heightPixels"=>height,"mode"=>mode,"sha256"=>expected,"status"=>"valid","widthPixels"=>width})
' || fail 'manifest, media, dimensions, duration, or hash did not validate'
