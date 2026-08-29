#!/bin/bash
set -euo pipefail

fail() {
  printf '%s\n' "audio validation failed: $1" >&2
  exit 1
}

[[ $# -eq 4 && $1 == --root && $3 == --manifest ]] || {
  echo 'usage: validate-audio.sh --root REPOSITORY --manifest RELATIVE_MANIFEST' >&2
  exit 2
}
repository_root=${2:-}
manifest_relative=${4:-}
[[ "$repository_root" == /* && -d "$repository_root" && ! -L "$repository_root" ]] || fail 'repository root is invalid'
repository_root=$(cd "$repository_root" && /bin/pwd -P)
[[ "$manifest_relative" != /* && "$manifest_relative" != *'..'* && "$manifest_relative" == *.yml ]] || fail 'manifest path is invalid'
manifest_file="$repository_root/$manifest_relative"
[[ -f "$manifest_file" && ! -L "$manifest_file" ]] || fail 'manifest is unavailable'

/usr/bin/ruby -rjson -ryaml -rdigest -rtime -ropen3 -rtmpdir -e '
  def refuse(message)
    warn message
    exit 1
  end

  root=ARGV.fetch(0)
  manifest_path=ARGV.fetch(1)
  value=YAML.safe_load(File.binread(manifest_path), permitted_classes: [], aliases: false)
  keys=%w[schemaVersion mode purpose requestSummary model sourceSha256 voiceId durationSeconds loop loopDiscontinuityThreshold format assetPath licenseNote sha256 processedAt]
  refuse("manifest schema differs") unless value.is_a?(Hash) && value.keys.sort == keys.sort && value["schemaVersion"] == 2
  modes=%w[text-to-speech speech-to-speech sound-effect audio-isolation music]
  mode=value["mode"]
  refuse("mode is invalid") unless modes.include?(mode)
  safe_text=/\A[^\u0000-\u001f\u007f]{1,1024}\z/
  %w[purpose requestSummary model licenseNote].each{|key| refuse("#{key} is invalid") unless value[key].is_a?(String) && value[key].match?(safe_text)}
  secret_pattern=/(xi-api-key|api[_ -]?key|secret[_ -]?key|service_role|-----begin [a-z ]*private key-----|password\s*=)/i
  refuse("manifest contains a credential pattern") if value.values.grep(String).any?{|entry| entry.match?(secret_pattern)}
  digest_pattern=/\Asha256:[0-9a-f]{64}\z/
  source=value["sourceSha256"]
  if %w[speech-to-speech audio-isolation].include?(mode)
    refuse("sourceSha256 is required") unless source.is_a?(String) && source.match?(digest_pattern)
  else
    refuse("sourceSha256 must be null") unless source.nil?
  end
  voice=value["voiceId"]
  if %w[text-to-speech speech-to-speech].include?(mode)
    refuse("voiceId is required") unless voice.is_a?(String) && voice.match?(/\A[A-Za-z0-9_-]{3,128}\z/)
  else
    refuse("voiceId must be null") unless voice.nil?
  end
  duration=value["durationSeconds"]
  refuse("durationSeconds is invalid") unless duration.is_a?(Numeric) && duration.finite? && duration.between?(0.1,3600.0)
  refuse("sound effect duration is invalid") if mode == "sound-effect" && !duration.between?(0.5,30.0)
  refuse("music duration is invalid") if mode == "music" && !duration.between?(3.0,600.0)
  looped=value["loop"]
  refuse("loop must be boolean") unless looped == true || looped == false
  refuse("mode cannot be looped") if looped && !%w[sound-effect music].include?(mode)
  threshold=value["loopDiscontinuityThreshold"]
  if looped
    refuse("loop threshold is invalid") unless threshold.is_a?(Numeric) && threshold.finite? && threshold > 0 && threshold <= 1
  else
    refuse("non-loop asset must have a null loop threshold") unless threshold.nil?
  end
  format=value["format"]
  refuse("format is unsupported") unless %w[wav mp3 m4a caf].include?(format)
  relative=value["assetPath"]
  refuse("assetPath is invalid") unless relative.is_a?(String) && !relative.start_with?("/") && relative.split("/",-1).all?{|part| !part.empty? && part != "." && part != ".."}
  refuse("asset extension differs") unless File.extname(relative).delete_prefix(".").downcase == format
  asset=File.join(root,relative)
  refuse("asset is unavailable") unless File.file?(asset) && !File.symlink?(asset) && File.stat(asset).nlink == 1
  refuse("asset escapes repository") unless File.realpath(asset).start_with?(root+File::SEPARATOR)
  expected_digest=value["sha256"]
  refuse("sha256 is invalid") unless expected_digest.is_a?(String) && expected_digest.match?(digest_pattern)
  refuse("audio hash differs") unless expected_digest == "sha256:#{Digest::SHA256.file(asset).hexdigest}"
  begin
    Time.iso8601(value["processedAt"])
  rescue ArgumentError, TypeError
    refuse("processedAt is invalid")
  end
  info,status=Open3.capture2e("/usr/bin/afinfo","-r",asset)
  refuse("afinfo could not read audio") unless status.success?
  measured=info[/estimated duration:\s*([0-9]+(?:[.][0-9]+)?)/i,1]&.to_f
  measured ||= info[/duration:\s*([0-9]+(?:[.][0-9]+)?)/i,1]&.to_f
  refuse("afinfo duration is unavailable") unless measured && measured.finite? && measured > 0
  tolerance=[0.05,duration.to_f*0.02].max
  refuse("measured duration differs") if (measured-duration.to_f).abs > tolerance

  discontinuity=nil
  if looped
    Dir.mktmpdir("ios-template-loop-analysis") do |directory|
      pcm=File.join(directory,"audio.wav")
      _,convert_status=Open3.capture2e("/usr/bin/afconvert","-f","WAVE","-d","LEI16@44100",asset,pcm)
      refuse("audio could not be converted for loop analysis") unless convert_status.success? && File.file?(pcm)
      bytes=File.binread(pcm)
      refuse("converted WAV is invalid") unless bytes.start_with?("RIFF") && bytes.byteslice(8,4) == "WAVE"
      offset=12; format_chunk=nil; audio_data=nil
      while offset+8 <= bytes.bytesize
        chunk=bytes.byteslice(offset,4); size=bytes.byteslice(offset+4,4).unpack1("V"); payload=bytes.byteslice(offset+8,size)
        format_chunk=payload if chunk == "fmt "
        audio_data=payload if chunk == "data"
        offset += 8 + size + (size.odd? ? 1 : 0)
      end
      refuse("converted WAV lacks PCM chunks") unless format_chunk && audio_data && format_chunk.bytesize >= 16
      encoding,channels,rate,_,_,bits=format_chunk.unpack("v v V V v v")
      refuse("converted WAV is not 16-bit PCM") unless encoding == 1 && channels >= 1 && rate > 0 && bits == 16
      samples=audio_data.unpack("s<*")
      frame_count=samples.length/channels
      window=[[rate/50,1].max,frame_count/2].min
      refuse("audio is too short for loop analysis") if window < 1
      first=(0...window).map{|index| samples[index*channels].to_f}
      last=((frame_count-window)...frame_count).map{|index| samples[index*channels].to_f}
      discontinuity=Math.sqrt(first.zip(last).sum{|a,b| (a-b)**2}/window)/32768.0
      refuse("loop boundary exceeds threshold") if discontinuity > threshold.to_f
    end
  end
  result={"durationSeconds"=>measured.round(6),"format"=>format,"loopDiscontinuity"=>discontinuity&.round(6),"mode"=>mode,"sha256"=>expected_digest,"status"=>"valid"}
  puts JSON.generate(result.keys.sort.to_h{|key| [key,result[key]]})
' "$repository_root" "$manifest_file" || fail 'manifest, media, duration, hash, or loop contract did not validate'
