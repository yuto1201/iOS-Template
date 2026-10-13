#!/bin/bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby /usr/bin/sips

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
tool="$repo_root/tools/appstore-creative-sheet.sh"
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-creative-sheet.XXXXXX")
trap 'rm -rf -- "$workspace"' EXIT
root="$workspace/store-creative"

fail() { echo "$*" >&2; exit 1; }
expect_failure() {
  local label=$1 message=$2; shift 2
  if "$@" >"$workspace/$label.out" 2>"$workspace/$label.err"; then
    fail "creative sheet accepted $label"
  fi
  grep -Fq -- "$message" "$workspace/$label.err" || { cat "$workspace/$label.err" >&2; fail "unexpected failure for $label"; }
}

# Small solid PNG tiles with the App Store aspect ratio, written without image tools.
ruby -rzlib -e '
  def png(path, width, height, rgb)
    row = "\x00".b + rgb.pack("C3") * width
    raw = row * height
    chunk = ->(type, data) { [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N") }
    File.binwrite(path, "\x89PNG\r\n\x1A\n".b + chunk.("IHDR", [width, height, 8, 2, 0, 0, 0].pack("N2C5")) +
      chunk.("IDAT", Zlib::Deflate.deflate(raw)) + chunk.("IEND", "".b))
  end
  dir = ARGV.fetch(0)
  { "device" => [40, 120, 200], "pair" => [60, 160, 90], "scene" => [200, 140, 60],
    "concept" => [150, 60, 170], "callout" => [220, 60, 60] }.each { |name, rgb| png(File.join(dir, "#{name}.png"), 132, 287, rgb) }
' "$workspace"
printf 'not an image\n' >"$workspace/broken.png"

write_spec() { # path kind patterns-json
  ruby -rjson -e 'File.write(ARGV[0], JSON.generate({"schemaVersion" => 1, "kind" => ARGV[1], "app" => "テストアプリ",
    "title" => "ストア画像の提案", "brief" => "雨と風の動きを主役にする。", "patterns" => JSON.parse(ARGV[2])}))' "$1" "$2" "$3"
}
tiles() { # kinds... -> Japanese iPhone tiles
  ruby -rjson -e 'puts JSON.generate(ARGV.each_with_index.map { |kind, index|
    {"slot" => index + 1, "kind" => kind, "device" => "iphone", "locale" => "ja", "image" => "#{kind}.png", "caption" => "面#{index + 1}"} })' "$@"
}
pattern() { # id tiles-json
  ruby -rjson -e 'puts JSON.generate({"id" => ARGV[0], "title" => "案#{ARGV[0]}", "hypothesis" => "動きで伝える。",
    "tradeoffs" => "生成画像の質に左右される。", "tiles" => JSON.parse(ARGV[1])})' "$1" "$2"
}

good=$(pattern A "$(tiles device pair scene device concept device)")
early=$(pattern B "$(tiles concept device pair device device device)")
many=$(pattern C "$(tiles device pair scene concept concept concept)")
write_spec "$workspace/proposal.json" proposal "[$good,$early,$many]"

built=$("$tool" build --spec "$workspace/proposal.json" --root "$root" --revision r1)
sheet="$root/r1/sheet.html"
record="$root/r1/sheet.json"
[[ -f "$sheet" && -f "$record" ]] || fail 'build did not write the sheet and its record'

# One self-contained page: a strict CSP, every image inline, and nothing that can reach the network.
grep -Fq "http-equiv=\"Content-Security-Policy\" content=\"default-src 'none';" "$sheet" || fail 'sheet lacks the restrictive CSP'
grep -Fq "img-src data:" "$sheet" || fail 'sheet CSP does not limit images to data URIs'
! grep -Eiq 'https?://|url\(|@import|<script|<iframe|<object|<embed|<link|<form' "$sheet" || fail 'sheet can reach the network or run script'
[[ "$(grep -o '<img ' "$sheet" | wc -l | tr -d ' ')" == 18 ]] || fail 'sheet does not show every tile'
[[ "$(grep -o '<img src="data:image/png;base64,' "$sheet" | wc -l | tr -d ' ')" == 18 ]] || fail 'sheet image is not embedded'
ruby -rjson -rdigest -e '
  record = JSON.parse(File.read(ARGV[0])); html = File.binread(ARGV[1])
  abort "sheet digest differs" unless record.fetch("sheetSha256") == "sha256:#{Digest::SHA256.hexdigest(html)}"
  checks = record.fetch("patterns").to_h { |pattern| [pattern.fetch("id"), pattern.fetch("ruleCheck")] }
  abort "valid pattern failed the rules: #{checks["A"]}" unless checks.fetch("A").fetch("passed")
  abort "early concept passed" if checks.fetch("B").fetch("passed")
  abort "early concept reason" unless checks.fetch("B").fetch("violations").any? { |message| message.include?("first 3 tiles") }
  abort "too many concepts passed" if checks.fetch("C").fetch("passed")
  abort "concept count reason" unless checks.fetch("C").fetch("violations").any? { |message| message.include?("at most 2") }
  abort "concept ratio reason" unless checks.fetch("C").fetch("violations").any? { |message| message.include?("at most a third") }
  abort "proposal parity" unless checks.fetch("A").fetch("localeParity") == "not-applicable"
  tile = record.fetch("patterns").first.fetch("tiles").first
  abort "tile source digest" unless tile.fetch("sourceSha256").match?(/\Asha256:[0-9a-f]{64}\z/)
' "$record" "$sheet"
ruby -rjson -e 'abort "build did not report the violating patterns" unless JSON.parse(ARGV[0]).fetch("violations").sort == %w[B C]' "$built"
grep -Fq 'ルール違反があります' "$sheet" || fail 'sheet does not show the rule violations'

# A revision the user may have seen is never replaced.
before=$(shasum -a 256 "$sheet")
expect_failure rebuild 'revision already exists and is never replaced' "$tool" build --spec "$workspace/proposal.json" --root "$root" --revision r1
[[ "$(shasum -a 256 "$sheet")" == "$before" ]] || fail 'rebuild changed the existing sheet'

# Definitions that could leak a URL or markup into the page, or point at a non-image, are refused.
six=(device pair device device device device)
write_spec "$workspace/url.json" proposal "[$good,$early,$(pattern U "$(tiles "${six[@]}")" | sed 's/動きで伝える。/https:\/\/example.com を見る/')]"
expect_failure url-text 'must not contain URLs, markup, or style imports' "$tool" build --spec "$workspace/url.json" --root "$root" --revision r2
write_spec "$workspace/markup.json" proposal "[$good,$early,$(pattern M "$(tiles "${six[@]}")" | sed 's/動きで伝える。/<img src=x>/')]"
expect_failure markup-text 'must not contain URLs, markup, or style imports' "$tool" build --spec "$workspace/markup.json" --root "$root" --revision r2
write_spec "$workspace/broken.json" proposal "[$good,$early,$(pattern X "$(tiles "${six[@]}")" | sed 's/pair.png/broken.png/')]"
expect_failure broken-image 'tile image must be PNG or JPEG' "$tool" build --spec "$workspace/broken.json" --root "$root" --revision r2
[[ ! -e "$root/r2" ]] || fail 'a refused build left a revision behind'
expect_failure bad-revision 'revision must be lowercase letters' "$tool" build --spec "$workspace/proposal.json" --root "$root" --revision 'R 3'
write_spec "$workspace/two.json" proposal "[$good,$early]"
expect_failure two-patterns 'a proposal compares three or four patterns' "$tool" build --spec "$workspace/two.json" --root "$root" --revision r2
write_spec "$workspace/uneven.json" proposal "[$good,$early,$(pattern E "$(tiles device pair device)")]"
expect_failure uneven-patterns 'proposal patterns must all have the same number of tiles; found 3, 6' "$tool" build --spec "$workspace/uneven.json" --root "$root" --revision r2

# The second-stage sample shows Japanese and English for each device and checks they match.
preview_tiles=$(ruby -rjson -e '
  kinds = %w[device pair scene]
  tiles = %w[ja en-US].flat_map { |locale| kinds.each_with_index.map { |kind, index|
    {"slot" => index + 1, "kind" => (locale == "en-US" && index == 2 ? "device" : kind), "device" => "iphone", "locale" => locale, "image" => "#{kind}.png"} } }
  puts JSON.generate(tiles)')
write_spec "$workspace/preview.json" preview "[$(pattern A "$preview_tiles")]"
"$tool" build --spec "$workspace/preview.json" --root "$root" --revision p1 >/dev/null
ruby -rjson -e '
  check = JSON.parse(File.read(ARGV[0])).fetch("patterns").first.fetch("ruleCheck")
  abort "locale parity mismatch passed" if check.fetch("passed") || check.fetch("localeParity") != "failed"
' "$root/p1/sheet.json"

# Selection: one listed pattern that meets the rules, or a complete combination; recorded once.
expect_failure unknown-pattern 'unknown pattern id: Z' "$tool" select --sheet "$root/r1" --pattern Z
expect_failure violating-pattern 'pattern B breaks the tile rules' "$tool" select --sheet "$root/r1" --pattern B
expect_failure both-choices 'give exactly one of --pattern or --tiles' "$tool" select --sheet "$root/r1" --pattern A --tiles 1=A:1
expect_failure missing-slot 'must name every slot from 1 to 6 exactly once' "$tool" select --sheet "$root/r1" --tiles 1=A:1,2=C:2,4=A:4,5=A:5,6=A:6
expect_failure trailing-slots 'must name every slot from 1 to 6 exactly once' "$tool" select --sheet "$root/r1" --tiles 1=A:1,2=A:2,3=A:3
expect_failure unknown-tile 'pattern A has no Japanese iPhone tile 9' "$tool" select --sheet "$root/r1" --tiles 1=A:1,2=A:9,3=A:3,4=A:4,5=A:5,6=A:6
expect_failure combo-rules 'the combination breaks the tile rules' "$tool" select --sheet "$root/r1" --tiles 1=B:1,2=A:2,3=A:3,4=A:4,5=A:5,6=A:6
[[ ! -e "$root/r1/selection.json" ]] || fail 'a refused selection was recorded'
"$tool" select --sheet "$root/r1" --tiles 1=A:1,2=C:2,3=C:3,4=A:4,5=A:5,6=A:6 >/dev/null
ruby -rjson -e '
  value = JSON.parse(File.read(ARGV[0]))
  abort "selection fields" unless value.keys.sort == %w[decision recordedAt revision schemaVersion selection sheetSha256]
  abort "selection decision" unless value.fetch("decision") == "user-explicit" && value.fetch("revision") == "r1"
  tiles = value.fetch("selection").fetch("tiles")
  abort "combination record" unless value.fetch("selection").fetch("type") == "combination" && tiles.map { |tile| tile.fetch("patternId") } == %w[A C C A A A]
' "$root/r1/selection.json"
expect_failure reselect 'a selection is already recorded for this sheet and is never replaced' "$tool" select --sheet "$root/r1" --pattern A
# A listed pattern that meets the rules is recorded by its ID on a fresh sheet.
"$tool" build --spec "$workspace/proposal.json" --root "$root" --revision r3 >/dev/null
"$tool" select --sheet "$root/r3" --pattern A >/dev/null
ruby -rjson -e '
  value = JSON.parse(File.read(ARGV[0])); record = JSON.parse(File.read(ARGV[1]))
  abort "pattern selection type" unless value.fetch("selection") == {"type" => "pattern", "patternId" => "A"}
  abort "pattern selection revision" unless value.fetch("revision") == "r3" && value.fetch("decision") == "user-explicit"
  abort "pattern selection digest" unless value.fetch("sheetSha256") == record.fetch("sheetSha256")
' "$root/r3/selection.json" "$root/r3/sheet.json"

# A sheet changed after it was built cannot take a selection.
cp -R "$root/r1" "$workspace/tampered"
rm "$workspace/tampered/selection.json"
printf '<!-- edited -->\n' >>"$workspace/tampered/sheet.html"
expect_failure tampered 'sheet.html differs from the sheet record' "$tool" select --sheet "$workspace/tampered" --pattern A
# The choice is checked against the record inside the displayed page, never against an edited sheet.json.
grep -Fq '<meta name="appstore-creative-sheet" content="' "$sheet" || fail 'sheet does not carry its displayed record'
cp -R "$root/r1" "$workspace/added-pattern"
rm "$workspace/added-pattern/selection.json"
ruby -rjson -e 'path = ARGV[0]; record = JSON.parse(File.read(path)); extra = Marshal.load(Marshal.dump(record["patterns"][0]))
  extra["id"] = "Z"; record["patterns"] << extra; File.write(path, JSON.generate(record))' "$workspace/added-pattern/sheet.json"
expect_failure added-pattern 'sheet.json differs from the displayed sheet' "$tool" select --sheet "$workspace/added-pattern" --pattern Z
cp -R "$root/r1" "$workspace/forged-check"
rm "$workspace/forged-check/selection.json"
ruby -rjson -e 'path = ARGV[0]; record = JSON.parse(File.read(path))
  record["patterns"].find { |pattern| pattern["id"] == "B" }["ruleCheck"] = {"passed" => true, "localeParity" => "not-applicable", "violations" => []}
  File.write(path, JSON.generate(record))' "$workspace/forged-check/sheet.json"
expect_failure forged-check 'pattern B breaks the tile rules' "$tool" select --sheet "$workspace/forged-check" --pattern B
cp -R "$root/r1" "$workspace/forged-kind"
rm "$workspace/forged-kind/selection.json"
ruby -rjson -e 'path = ARGV[0]; record = JSON.parse(File.read(path))
  record["patterns"].find { |pattern| pattern["id"] == "B" }["tiles"][0]["kind"] = "device"; File.write(path, JSON.generate(record))' "$workspace/forged-kind/sheet.json"
expect_failure forged-kind 'sheet.json differs from the displayed sheet' "$tool" select --sheet "$workspace/forged-kind" --pattern B
expect_failure preview-combination 'a combination applies only to a proposal sheet' "$tool" select --sheet "$root/p1" --tiles 1=A:1

# A storyboard sheet compares exactly two preview storyboards of one device and locale. Each frame is a
# still of one segment with its state, seconds and motion; a storyboard must run 15 to 30 seconds, and
# the user chooses one listed storyboard whole. The page has the same CSP, digest and no-overwrite rules.
frames() { # seconds... -> Japanese iPhone storyboard frames
  ruby -rjson -e 'puts JSON.generate(ARGV.each_with_index.map { |seconds, index|
    {"slot" => index + 1, "device" => "iphone", "locale" => "ja", "image" => "device.png", "state" => "primary",
     "seconds" => Integer(seconds), "motion" => "花が揺れる", "caption" => "場面#{index + 1}"} })' "$@"
}
s1=$(pattern S1 "$(frames 6 6 6)")
s2=$(pattern S2 "$(frames 5 5)")
write_spec "$workspace/storyboard.json" storyboard "[$s1,$s2]"
"$tool" build --spec "$workspace/storyboard.json" --root "$root" --revision s1 >/dev/null
storyboard_sheet="$root/s1/sheet.html"
grep -Fq "http-equiv=\"Content-Security-Policy\" content=\"default-src 'none';" "$storyboard_sheet" || fail 'storyboard sheet lacks the restrictive CSP'
! grep -Eiq 'https?://|url\(|@import|<script|<iframe|<object|<embed|<link|<form' "$storyboard_sheet" || fail 'storyboard sheet can reach the network or run script'
[[ "$(grep -o '<img src="data:image/png;base64,' "$storyboard_sheet" | wc -l | tr -d ' ')" == 5 ]] || fail 'storyboard sheet does not embed every frame'
ruby -rjson -rdigest -e '
  record = JSON.parse(File.read(ARGV[0])); html = File.binread(ARGV[1])
  abort "storyboard digest differs" unless record.fetch("sheetSha256") == "sha256:#{Digest::SHA256.hexdigest(html)}"
  abort "storyboard kind" unless record.fetch("kind") == "storyboard" && record.fetch("patterns").map { |pattern| pattern.fetch("id") } == %w[S1 S2]
  checks = record.fetch("patterns").to_h { |pattern| [pattern.fetch("id"), pattern.fetch("ruleCheck")] }
  abort "valid storyboard failed" unless checks.fetch("S1").fetch("passed") && checks.fetch("S1").fetch("totalSeconds") == 18
  abort "short storyboard passed" if checks.fetch("S2").fetch("passed")
  abort "short storyboard reason" unless checks.fetch("S2").fetch("violations") == ["storyboard runs 10s; a preview must run 15 to 30 seconds"]
  frame = record.dig("patterns", 0, "tiles", 0)
  abort "storyboard frame fields" unless frame.values_at("slot", "kind", "device", "locale", "state", "seconds") == [1, "frame", "iphone", "ja", "primary", 6] &&
    frame.fetch("sourceSha256").match?(/\Asha256:[0-9a-f]{64}\z/)
' "$root/s1/sheet.json" "$storyboard_sheet"
grep -Fq 'プレビュー動画の絵コンテ' "$storyboard_sheet" && grep -Fq 'primary ・ 6秒' "$storyboard_sheet" && grep -Fq '花が揺れる' "$storyboard_sheet" &&
  grep -Fq '（合計18秒）' "$storyboard_sheet" || fail 'storyboard sheet does not show the state, seconds, motion and length'
before=$(shasum -a 256 "$storyboard_sheet")
expect_failure storyboard-rebuild 'revision already exists and is never replaced' "$tool" build --spec "$workspace/storyboard.json" --root "$root" --revision s1
[[ "$(shasum -a 256 "$storyboard_sheet")" == "$before" ]] || fail 'rebuild changed the existing storyboard sheet'
write_spec "$workspace/storyboard-one.json" storyboard "[$s1]"
expect_failure one-storyboard 'a storyboard sheet compares exactly 2 storyboards; found 1' "$tool" build --spec "$workspace/storyboard-one.json" --root "$root" --revision s2
write_spec "$workspace/storyboard-three.json" storyboard "[$s1,$s2,$(pattern S3 "$(frames 8 8)")]"
expect_failure three-storyboards 'a storyboard sheet compares exactly 2 storyboards; found 3' "$tool" build --spec "$workspace/storyboard-three.json" --root "$root" --revision s2
write_spec "$workspace/storyboard-kind.json" storyboard "[$s1,$(pattern S2 "$(tiles device pair device)")]"
expect_failure storyboard-tile-kind 'unknown tile field in S2: kind' "$tool" build --spec "$workspace/storyboard-kind.json" --root "$root" --revision s2
write_spec "$workspace/storyboard-devices.json" storyboard "[$s1,$(pattern S2 "$(frames 8 8 | sed 's/"iphone"/"ipad"/g')")]"
expect_failure storyboard-devices 'both storyboards must use the same device and locale' "$tool" build --spec "$workspace/storyboard-devices.json" --root "$root" --revision s2
write_spec "$workspace/storyboard-seconds.json" storyboard "[$s1,$(pattern S2 "$(frames 31 2)")]"
expect_failure storyboard-seconds 'storyboard frame seconds of S2 must be an integer from 1 to 30' "$tool" build --spec "$workspace/storyboard-seconds.json" --root "$root" --revision s2
write_spec "$workspace/storyboard-state.json" storyboard "[$s1,$(pattern S2 "$(frames 8 8 | sed 's/"primary"/"Primary State"/')")]"
expect_failure storyboard-state 'storyboard frame state of S2 is invalid' "$tool" build --spec "$workspace/storyboard-state.json" --root "$root" --revision s2
write_spec "$workspace/storyboard-url.json" storyboard "[$s1,$(pattern S2 "$(frames 8 8 | sed 's/花が揺れる/https:\/\/example.com/')")]"
expect_failure storyboard-url 'S2.motion must not contain URLs, markup, or style imports' "$tool" build --spec "$workspace/storyboard-url.json" --root "$root" --revision s2
[[ ! -e "$root/s2" ]] || fail 'a refused storyboard build left a revision behind'
# Only a listed storyboard that runs 15 to 30 seconds can be chosen, and only whole.
expect_failure storyboard-unknown 'unknown pattern id: S9' "$tool" select --sheet "$root/s1" --pattern S9
expect_failure short-storyboard 'pattern S2 breaks the tile rules' "$tool" select --sheet "$root/s1" --pattern S2
expect_failure storyboard-combination 'a combination applies only to a proposal sheet' "$tool" select --sheet "$root/s1" --tiles 1=S1:1
cp -R "$root/s1" "$workspace/forged-seconds"
ruby -rjson -e 'path = ARGV[0]; record = JSON.parse(File.read(path))
  record["patterns"].find { |pattern| pattern["id"] == "S2" }["tiles"].each { |tile| tile["seconds"] = 10 }; File.write(path, JSON.generate(record))' \
  "$workspace/forged-seconds/sheet.json"
expect_failure forged-seconds 'sheet.json differs from the displayed sheet' "$tool" select --sheet "$workspace/forged-seconds" --pattern S2
[[ ! -e "$root/s1/selection.json" ]] || fail 'a refused storyboard selection was recorded'
"$tool" select --sheet "$root/s1" --pattern S1 >/dev/null
ruby -rjson -e '
  value = JSON.parse(File.read(ARGV[0])); record = JSON.parse(File.read(ARGV[1]))
  abort "storyboard selection" unless value.fetch("selection") == {"type" => "pattern", "patternId" => "S1"} &&
    value.fetch("decision") == "user-explicit" && value.fetch("revision") == "s1" && value.fetch("sheetSha256") == record.fetch("sheetSha256")
' "$root/s1/selection.json" "$root/s1/sheet.json"
expect_failure storyboard-reselect 'a selection is already recorded for this sheet and is never replaced' "$tool" select --sheet "$root/s1" --pattern S1

echo 'appstore-creative sheet tests passed'
