#!/bin/bash
set -euo pipefail

fail() {
  printf '%s\n' "transcript validation failed: $1" >&2
  exit 1
}

[[ $# -eq 4 && $1 == --root && $3 == --manifest ]] || {
  echo 'usage: validate-transcript.sh --root REPOSITORY --manifest RELATIVE_MANIFEST' >&2
  exit 2
}
repository_root=${2:-}
manifest_relative=${4:-}
[[ "$repository_root" == /* && -d "$repository_root" && ! -L "$repository_root" ]] || fail 'repository root is invalid'
repository_root=$(cd "$repository_root" && /bin/pwd -P)
[[ "$manifest_relative" != /* && "$manifest_relative" != *'..'* && "$manifest_relative" == *.yml ]] || fail 'manifest path is invalid'
manifest_file="$repository_root/$manifest_relative"
[[ -f "$manifest_file" && ! -L "$manifest_file" ]] || fail 'manifest is unavailable'

/usr/bin/ruby -rjson -ryaml -rdigest -rtime -e '
  def refuse(message); warn message; exit 1; end
  root=ARGV.fetch(0)
  value=YAML.safe_load(File.binread(ARGV.fetch(1)), permitted_classes: [], aliases: false)
  keys=%w[schemaVersion mode purpose model languageCode sourceSha256 format transcriptPath sha256 licenseNote processedAt]
  refuse("manifest schema differs") unless value.is_a?(Hash) && value.keys.sort == keys.sort && value["schemaVersion"] == 1 && value["mode"] == "speech-to-text"
  safe_text=/\A[^\u0000-\u001f\u007f]{1,1024}\z/
  %w[purpose model licenseNote].each{|key| refuse("#{key} is invalid") unless value[key].is_a?(String) && value[key].match?(safe_text)}
  language=value["languageCode"]
  refuse("languageCode is invalid") unless language.nil? || (language.is_a?(String) && language.match?(/\A[a-z]{2,3}(?:-[A-Z]{2})?\z/))
  digest_pattern=/\Asha256:[0-9a-f]{64}\z/
  refuse("sourceSha256 is invalid") unless value["sourceSha256"].is_a?(String) && value["sourceSha256"].match?(digest_pattern)
  format=value["format"]
  refuse("format is unsupported") unless %w[json txt srt vtt].include?(format)
  relative=value["transcriptPath"]
  refuse("transcriptPath is invalid") unless relative.is_a?(String) && !relative.start_with?("/") && relative.split("/",-1).all?{|part| !part.empty? && part != "." && part != ".."}
  refuse("transcript extension differs") unless File.extname(relative).delete_prefix(".").downcase == format
  output=File.join(root,relative)
  refuse("transcript is unavailable") unless File.file?(output) && !File.symlink?(output) && File.stat(output).nlink == 1
  refuse("transcript escapes repository") unless File.realpath(output).start_with?(root+File::SEPARATOR)
  bytes=File.binread(output)
  refuse("transcript is empty or binary") if bytes.empty? || bytes.include?("\0")
  text=bytes.force_encoding(Encoding::UTF_8)
  refuse("transcript is not UTF-8") unless text.valid_encoding?
  secret_pattern=/(xi-api-key|api[_ -]?key|secret[_ -]?key|service_role|-----begin [a-z ]*private key-----|password\s*=)/i
  refuse("manifest or transcript contains a credential pattern") if value.values.grep(String).any?{|entry| entry.match?(secret_pattern)} || text.match?(secret_pattern)
  if format == "json"
    begin
      parsed=JSON.parse(text)
    rescue JSON::ParserError
      refuse("transcript JSON is invalid")
    end
    refuse("transcript JSON lacks text") unless parsed.is_a?(Hash) && parsed["text"].is_a?(String) && !parsed["text"].empty?
  end
  expected=value["sha256"]
  refuse("sha256 is invalid") unless expected.is_a?(String) && expected.match?(digest_pattern)
  refuse("transcript hash differs") unless expected == "sha256:#{Digest::SHA256.hexdigest(bytes)}"
  begin; Time.iso8601(value["processedAt"]); rescue ArgumentError, TypeError; refuse("processedAt is invalid"); end
  puts JSON.generate({"format"=>format,"mode"=>"speech-to-text","sha256"=>expected,"status"=>"valid"})
' "$repository_root" "$manifest_file" || fail 'manifest, transcript, encoding, schema, or hash did not validate'
