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

# D-085: a proposal starts from the app's identity (brand.json), a research record of reference apps,
# and one style spec per pattern. The fixtures are written here; none is committed.
ruby -rjson -e '
  dir = ARGV.fetch(0)
  brand = {"schemaVersion" => 1, "app" => "テストアプリ",
    "strengths" => [
      {"id" => "sway", "claim" => "天気で花が揺れる", "feature" => "天気に合わせた花の動き", "screens" => ["home-rain"]},
      {"id" => "forecast", "claim" => "明日の空が一目で分かる", "feature" => "予報の表示", "screens" => ["forecast"]},
      {"id" => "widget", "claim" => "ホーム画面で見られる", "feature" => "ウィジェット", "screens" => ["widget"]}],
    "audience" => [{"who" => "通勤する人", "scene" => "朝、家を出る前"}],
    "world" => "雨上がりの窓辺に咲く小さな庭",
    "story" => ["天気は気になる", "花が教えてくれる", "毎朝のたのしみになる"],
    "colors" => {"accent" => "#3A7BD5", "icon" => ["#F2C94C"], "palette" => [
      {"name" => "paper", "hex" => "#F6F2EA", "use" => "背景"}, {"name" => "ink", "hex" => "#1E1D1B", "use" => "見出し"}]},
    "fonts" => [{"role" => "headline", "family" => "Zen Maru Gothic", "source" => "Google Fonts", "license" => "SIL Open Font License 1.1", "paid" => false},
                {"role" => "body", "family" => "Noto Sans JP", "source" => "Google Fonts", "license" => "SIL Open Font License 1.1", "paid" => false}],
    "voice" => ["やさしい", "具体的", "静か"], "motifs" => ["雨粒", "花びら"], "avoid" => ["意味のない光の玉"]}
  File.write(File.join(dir, "brand.json"), JSON.generate(brand))
  research = {"schemaVersion" => 1, "category" => "天気", "checkedOn" => "2026-10-21", "references" => [
    {"id" => "lazy", "app" => "Lazy Weather", "site" => "before.click", "url" => "https://before.click/explore?app=lazyweather",
     "techniques" => ["story-across"], "notes" => "文が次の面へ続く"},
    {"id" => "sky", "app" => "Sky Guide", "site" => "before.click", "url" => "https://before.click/explore?app=skyguide",
     "techniques" => ["off-screen-world", "cross-tile-art"]},
    {"id" => "gentler", "app" => "Gentler Streak", "site" => "before.click", "url" => "https://before.click/explore?app=gentler",
     "techniques" => ["popout", "mascot"]}]}
  File.write(File.join(dir, "research.json"), JSON.generate(research))
' "$workspace"

write_spec() { # path kind patterns-json [extra-json]
  ruby -rjson -e 'value = {"schemaVersion" => 1, "kind" => ARGV[1], "app" => "テストアプリ",
    "title" => "ストア画像の提案", "brief" => "雨と風の動きを主役にする。", "patterns" => JSON.parse(ARGV[2])}
    value.merge!("brand" => "brand.json", "research" => "research.json") if ARGV[1] == "proposal"
    value.merge!(JSON.parse(ARGV[3])) if ARGV[3]
    File.write(ARGV[0], JSON.generate(value.compact))' "$@"
}
tiles() { # background kinds... -> Japanese iPhone tiles; the layout is the kind, strengths cycle
  ruby -rjson -e 'background = ARGV.shift; strengths = %w[sway forecast widget]
    puts JSON.generate(ARGV.each_with_index.map { |kind, index|
    {"slot" => index + 1, "kind" => kind, "device" => "iphone", "locale" => "ja", "image" => "#{kind}.png", "caption" => "面#{index + 1}",
     "highlight" => strengths[index % 3], "layout" => kind, "background" => background,
     "headlines" => {"ja" => ["面#{index + 1}の見出し", "面#{index + 1}の二つ目の見出し"],
                     "en-US" => ["Tile #{index + 1} headline", "Another headline #{index + 1}"]}} })' "$@"
}
style() { # id [signature] -> writes style-<id>.json
  ruby -rjson -e 'id = ARGV[0]; File.write(File.join(ARGV[2], "style-#{id}.json"), JSON.generate({"schemaVersion" => 1, "id" => id,
    "name" => "スタイル#{id}", "signature" => ARGV[1], "tokens" => [{"name" => "bg", "hex" => "#F6F2EA", "use" => "背景"},
    {"name" => "text", "hex" => "#1E1D1B", "use" => "見出し"}], "fonts" => {"headline" => "Zen Maru Gothic", "body" => "Noto Sans JP"},
    "typesetting" => "左寄せ、2行まで", "decorationLimit" => 2, "crossScreen" => "背景の雨だけが面をまたぐ",
    "voice" => ["やさしい"], "failures" => ["見出しが3行になったら失敗"]}))' "$1" "$2" "$workspace"
}
pattern() { # id tiles-json [recommended]
  style "$1" "決め手の要素$1"
  ruby -rjson -e 'value = {"id" => ARGV[0], "title" => "案#{ARGV[0]}", "hypothesis" => "動きで伝える。",
    "tradeoffs" => "生成画像の質に左右される。", "recommended" => ARGV[2] == "recommended", "style" => "style-#{ARGV[0]}.json",
    "techniques" => ["story-across", "off-screen-world"], "tiles" => JSON.parse(ARGV[1])}
    value["recommendation"] = "検索結果の3枚で動きが伝わる。" if value["recommended"]
    puts JSON.generate(value)' "$1" "$2" "${3:-}"
}

plain_pattern() { # id tiles-json -> a preview or storyboard pattern, without proposal fields
  ruby -rjson -e 'puts JSON.generate({"id" => ARGV[0], "title" => "案#{ARGV[0]}", "hypothesis" => "動きで伝える。",
    "tradeoffs" => "生成画像の質に左右される。", "tiles" => JSON.parse(ARGV[1])})' "$1" "$2"
}

good=$(pattern A "$(tiles gradient device pair scene device concept device)" recommended)
early=$(pattern B "$(tiles solid concept device pair device device device)")
many=$(pattern C "$(tiles illustration device pair scene concept concept concept)")
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

# The sheet shows the identity, the research (without its URLs), each pattern's style spec, the one
# recommended pattern with its reason, and marks for repeated layouts and strengths.
for text in '個性の正本（brand.json）' '天気で花が揺れる' '雨上がりの窓辺に咲く小さな庭' 'SIL Open Font License 1.1' \
  '意味のない光の玉' 'Lazy Weather' 'story-across' 'スタイル仕様：スタイルA' '決め手の要素A' '見出しが3行になったら失敗' \
  'おすすめ' '検索結果の3枚で動きが伝わる。' '強み：明日の空が一目で分かる' '面2の二つ目の見出し' 'Another headline 2' \
  '仮の文言' 'class="swatch" style="background:#3A7BD5"'; do
  grep -Fq -- "$text" "$sheet" || fail "proposal sheet does not show: $text"
done
! grep -Fq 'before.click/explore' "$sheet" || fail 'proposal sheet shows a research URL'
ruby -rjson -e '
  record = JSON.parse(File.read(ARGV[0]))
  abort "brand digest" unless record.fetch("brandSha256").match?(/\Asha256:[0-9a-f]{64}\z/) && record.fetch("researchSha256").match?(/\Asha256:[0-9a-f]{64}\z/)
  patterns = record.fetch("patterns").to_h { |pattern| [pattern.fetch("id"), pattern] }
  abort "recommended" unless patterns.transform_values { |pattern| pattern.fetch("recommended") } == {"A" => true, "B" => false, "C" => false}
  abort "style digest" unless patterns.fetch("A").fetch("styleSha256").match?(/\Asha256:[0-9a-f]{64}\z/)
  abort "techniques" unless patterns.fetch("A").fetch("techniques") == %w[story-across off-screen-world]
  marks = patterns.transform_values { |pattern| pattern.fetch("marks") }
  abort "layout run mark: #{marks}" unless marks.fetch("B").include?("tiles 4-6 repeat the layout device") && marks.fetch("A").none? { |m| m.include?("repeat the layout") }
  abort "strength mark: #{marks}" unless marks.fetch("A").include?("tiles 1, 4 show the same strength sway")
  abort "long headline marked by default: #{marks}" if marks.values.flatten.any? { |m| m.include?("characters; the guide is") }
' "$record"
grep -Fq '注意（選ぶことはできます）' "$sheet" || fail 'proposal sheet does not show the marks'

# Six patterns are allowed, seven are not, and exactly one pattern is recommended.
six_patterns="$good,$early,$many,$(pattern D "$(tiles photo device scene pair device device pair)"),$(pattern E "$(tiles texture pair device scene device pair device)"),$(pattern F "$(tiles continuous scene device pair device scene device)")"
write_spec "$workspace/six.json" proposal "[$six_patterns]"
"$tool" build --spec "$workspace/six.json" --root "$root" --revision six >/dev/null
write_spec "$workspace/seven.json" proposal "[$six_patterns,$(pattern G "$(tiles image device device scene pair device pair)")]"
expect_failure seven-patterns 'a proposal compares three to six patterns; found 7' "$tool" build --spec "$workspace/seven.json" --root "$root" --revision r9
write_spec "$workspace/none-recommended.json" proposal "[$(pattern A "$(tiles gradient device pair scene device concept device)"),$early,$many]"
expect_failure no-recommendation 'a proposal recommends exactly one pattern; found 0' "$tool" build --spec "$workspace/none-recommended.json" --root "$root" --revision r9
write_spec "$workspace/two-recommended.json" proposal "[$good,$(pattern B "$(tiles solid concept device pair device device device)" recommended),$many]"
expect_failure two-recommendations 'a proposal recommends exactly one pattern; found 2' "$tool" build --spec "$workspace/two-recommended.json" --root "$root" --revision r9
write_spec "$workspace/reason.json" proposal "[$(pattern A "$(tiles gradient device pair scene device concept device)" recommended | sed 's/,"recommendation":"[^"]*"//'),$early,$many]"
expect_failure no-reason 'A.recommendation must be text' "$tool" build --spec "$workspace/reason.json" --root "$root" --revision r9

# Diversity: two patterns that share a signature element, or the same layouts and backgrounds in the
# same order, are refused.
twin=$(pattern T "$(tiles gradient device pair scene device concept device)")
write_spec "$workspace/twin.json" proposal "[$good,$early,$twin]"
expect_failure same-layouts 'patterns A and T use the same layouts and backgrounds in the same order' "$tool" build --spec "$workspace/twin.json" --root "$root" --revision r9
same_signature=$(pattern S "$(tiles photo device scene pair device device pair)")
style S '決め手の要素A。'
write_spec "$workspace/signature.json" proposal "[$good,$early,$same_signature]"
expect_failure same-signature 'patterns A and S share the signature element' "$tool" build --spec "$workspace/signature.json" --root "$root" --revision r9

# Every pattern has a style spec and uses only techniques the research record lists; every tile shows
# one brand strength and offers at least two headline candidates in each locale.
write_spec "$workspace/no-style.json" proposal "[$good,$early,$(pattern N "$(tiles photo device scene pair device device pair)" | sed 's/"style":"style-N.json",//')]"
expect_failure no-style 'pattern N needs style' "$tool" build --spec "$workspace/no-style.json" --root "$root" --revision r9
write_spec "$workspace/technique.json" proposal "[$good,$early,$(pattern K "$(tiles photo device scene pair device device pair)" | sed 's/"off-screen-world"/"invented-trick"/')]"
expect_failure unknown-technique 'pattern K uses technique invented-trick that the research record does not list' "$tool" build --spec "$workspace/technique.json" --root "$root" --revision r9
write_spec "$workspace/highlight.json" proposal "[$good,$early,$(pattern H "$(tiles photo device scene pair device device pair)" | sed 's/"highlight":"widget"/"highlight":"teleport"/')]"
expect_failure unknown-strength 'highlights teleport, which is not a brand.json strength' "$tool" build --spec "$workspace/highlight.json" --root "$root" --revision r9
write_spec "$workspace/one-headline.json" proposal "[$good,$early,$(pattern O "$(tiles photo device scene pair device device pair)" | sed 's/"面1の見出し",//')]"
expect_failure one-headline 'tile 1 ja headlines of O must be a list of 2 to 6 entries' "$tool" build --spec "$workspace/one-headline.json" --root "$root" --revision r9
# Headline candidates over the guide are marked; the guide is a setting of the definition.
write_spec "$workspace/short-guide.json" proposal "[$good,$early,$many]" '{"headlineLimits":{"ja":8,"en-US":36}}'
"$tool" build --spec "$workspace/short-guide.json" --root "$root" --revision guide >/dev/null
ruby -rjson -e 'marks = JSON.parse(File.read(ARGV[0])).fetch("patterns").first.fetch("marks")
  abort "long headline not marked: #{marks}" unless marks.include?("tile 1 ja headline 2 is 10 characters; the guide is 8")' "$root/guide/sheet.json"
grep -Fq '<li class="long">面1の二つ目の見出し</li>' "$root/guide/sheet.html" || fail 'sheet does not show the long headline'
# The research record lists three to five reference apps with https URLs.
cp "$workspace/research.json" "$workspace/research.good.json"
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); value["references"].pop; File.write(ARGV[0], JSON.generate(value))' "$workspace/research.json"
expect_failure few-references 'research references must be a list of 3 to 5 entries' "$tool" build --spec "$workspace/proposal.json" --root "$root" --revision r9
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[1])); value["references"][0]["url"] = "http://before.click/"; File.write(ARGV[0], JSON.generate(value))' \
  "$workspace/research.json" "$workspace/research.good.json"
expect_failure http-reference 'research lazy url must be an https URL' "$tool" build --spec "$workspace/proposal.json" --root "$root" --revision r9
cp "$workspace/research.good.json" "$workspace/research.json"
[[ ! -e "$root/r9" ]] || fail 'a refused proposal left a revision behind'

# brand.json and style specs are also checked on their own.
"$tool" check --brand "$workspace/brand.json" --style "$workspace/style-A.json" >"$workspace/check.out"
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0]))
  abort "check output" unless value.fetch("status") == "valid" && value.fetch("strengths") == %w[sway forecast widget] && value.key?("styleSha256")' "$workspace/check.out"
brand_variant() { # name ruby-edit -> brand-<name>.json
  ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); eval(ARGV[2]); File.write(ARGV[1], JSON.generate(value))' \
    "$workspace/brand.json" "$workspace/brand-$1.json" "$2"
}
brand_variant no-avoid 'value.delete("avoid")'
expect_failure brand-missing 'brand.json is missing: avoid' "$tool" check --brand "$workspace/brand-no-avoid.json"
brand_variant no-world 'value.delete("world"); value.delete("story")'
expect_failure brand-missing-two 'brand.json is missing: world, story' "$tool" check --brand "$workspace/brand-no-world.json"
brand_variant no-license 'value["fonts"][0].delete("license")'
expect_failure font-license 'font Zen Maru Gothic has no license record' "$tool" check --brand "$workspace/brand-no-license.json"
brand_variant paid 'value["fonts"][0]["paid"] = true'
expect_failure paid-font 'font Zen Maru Gothic is paid; ask the user before using it' "$tool" check --brand "$workspace/brand-paid.json"
brand_variant paid-approved 'value["fonts"][0]["paid"] = true; value["fonts"][0]["approval"] = "2026-10-21 ユーザーが承認"'
"$tool" check --brand "$workspace/brand-paid-approved.json" >/dev/null
brand_variant no-screen 'value["strengths"][1]["screens"] = []'
expect_failure strength-screen 'strength forecast is not tied to a real screen' "$tool" check --brand "$workspace/brand-no-screen.json"
brand_variant bad-color 'value["colors"]["accent"] = "blue"'
expect_failure brand-color 'brand.json colors.accent must be a #RRGGBB color' "$tool" check --brand "$workspace/brand-bad-color.json"
style_variant() { # name ruby-edit -> style-<name>.json from style-A.json
  ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); eval(ARGV[2]); File.write(ARGV[1], JSON.generate(value))' \
    "$workspace/style-A.json" "$workspace/style-$1.json" "$2"
}
style_variant no-signature 'value.delete("signature")'
expect_failure style-missing 'style spec is missing: signature' "$tool" check --brand "$workspace/brand.json" --style "$workspace/style-no-signature.json"
style_variant off-color 'value["tokens"] << {"name" => "neon", "hex" => "#FF00AA", "use" => "飾り"}'
expect_failure style-color 'style spec uses #FF00AA outside brand.json without a reason' "$tool" check --brand "$workspace/brand.json" --style "$workspace/style-off-color.json"
style_variant off-color-reason 'value["tokens"] << {"name" => "neon", "hex" => "#FF00AA", "use" => "飾り"}; value["deviations"] = [{"item" => "#ff00aa", "reason" => "夜の場面だけに使う"}]'
"$tool" check --brand "$workspace/brand.json" --style "$workspace/style-off-color-reason.json" >/dev/null
style_variant off-font 'value["fonts"]["headline"] = "Shippori Mincho"'
expect_failure style-font 'style spec uses the font Shippori Mincho outside brand.json without a reason' "$tool" check --brand "$workspace/brand.json" --style "$workspace/style-off-font.json"

# A revision the user may have seen is never replaced.
before=$(shasum -a 256 "$sheet")
expect_failure rebuild 'revision already exists and is never replaced' "$tool" build --spec "$workspace/proposal.json" --root "$root" --revision r1
[[ "$(shasum -a 256 "$sheet")" == "$before" ]] || fail 'rebuild changed the existing sheet'

# Definitions that could leak a URL or markup into the page, or point at a non-image, are refused.
six=(solid device pair device device device device)
write_spec "$workspace/url.json" proposal "[$good,$early,$(pattern U "$(tiles "${six[@]}")" | sed 's/動きで伝える。/https:\/\/example.com を見る/')]"
expect_failure url-text 'must not contain URLs, markup, or style imports' "$tool" build --spec "$workspace/url.json" --root "$root" --revision r2
write_spec "$workspace/markup.json" proposal "[$good,$early,$(pattern M "$(tiles "${six[@]}")" | sed 's/動きで伝える。/<img src=x>/')]"
expect_failure markup-text 'must not contain URLs, markup, or style imports' "$tool" build --spec "$workspace/markup.json" --root "$root" --revision r2
write_spec "$workspace/broken.json" proposal "[$good,$early,$(pattern X "$(tiles "${six[@]}")" | sed 's/pair.png/broken.png/')]"
expect_failure broken-image 'tile image must be PNG or JPEG' "$tool" build --spec "$workspace/broken.json" --root "$root" --revision r2
[[ ! -e "$root/r2" ]] || fail 'a refused build left a revision behind'
expect_failure bad-revision 'revision must be lowercase letters' "$tool" build --spec "$workspace/proposal.json" --root "$root" --revision 'R 3'
write_spec "$workspace/two.json" proposal "[$good,$early]"
expect_failure two-patterns 'a proposal compares three to six patterns; found 2' "$tool" build --spec "$workspace/two.json" --root "$root" --revision r2
write_spec "$workspace/uneven.json" proposal "[$good,$early,$(pattern E "$(tiles solid device pair device)")]"
expect_failure uneven-patterns 'proposal patterns must all have the same number of tiles; found 3, 6' "$tool" build --spec "$workspace/uneven.json" --root "$root" --revision r2

# The second-stage sample shows Japanese and English for each device and checks they match.
preview_tiles=$(ruby -rjson -e '
  kinds = %w[device pair scene]
  tiles = %w[ja en-US].flat_map { |locale| kinds.each_with_index.map { |kind, index|
    {"slot" => index + 1, "kind" => (locale == "en-US" && index == 2 ? "device" : kind), "device" => "iphone", "locale" => locale, "image" => "#{kind}.png"} } }
  puts JSON.generate(tiles)')
write_spec "$workspace/preview.json" preview "[$(plain_pattern A "$preview_tiles")]"
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
s1=$(plain_pattern S1 "$(frames 6 6 6)")
s2=$(plain_pattern S2 "$(frames 5 5)")
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
write_spec "$workspace/storyboard-three.json" storyboard "[$s1,$s2,$(plain_pattern S3 "$(frames 8 8)")]"
expect_failure three-storyboards 'a storyboard sheet compares exactly 2 storyboards; found 3' "$tool" build --spec "$workspace/storyboard-three.json" --root "$root" --revision s2
write_spec "$workspace/storyboard-kind.json" storyboard "[$s1,$(plain_pattern S2 "$(tiles solid device pair device)")]"
expect_failure storyboard-tile-kind 'unknown tile field in S2: kind' "$tool" build --spec "$workspace/storyboard-kind.json" --root "$root" --revision s2
write_spec "$workspace/storyboard-devices.json" storyboard "[$s1,$(plain_pattern S2 "$(frames 8 8 | sed 's/"iphone"/"ipad"/g')")]"
expect_failure storyboard-devices 'both storyboards must use the same device and locale' "$tool" build --spec "$workspace/storyboard-devices.json" --root "$root" --revision s2
write_spec "$workspace/storyboard-seconds.json" storyboard "[$s1,$(plain_pattern S2 "$(frames 31 2)")]"
expect_failure storyboard-seconds 'storyboard frame seconds of S2 must be an integer from 1 to 30' "$tool" build --spec "$workspace/storyboard-seconds.json" --root "$root" --revision s2
write_spec "$workspace/storyboard-state.json" storyboard "[$s1,$(plain_pattern S2 "$(frames 8 8 | sed 's/"primary"/"Primary State"/')")]"
expect_failure storyboard-state 'storyboard frame state of S2 is invalid' "$tool" build --spec "$workspace/storyboard-state.json" --root "$root" --revision s2
write_spec "$workspace/storyboard-url.json" storyboard "[$s1,$(plain_pattern S2 "$(frames 8 8 | sed 's/花が揺れる/https:\/\/example.com/')")]"
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
