#!/bin/bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby /usr/bin/sips ffmpeg ffprobe

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
# The default render record lists every tile image with no generated inputs.
ruby -rjson -rdigest -e 'dir = ARGV[0]; files = %w[device pair scene concept callout broken].map { |name| File.join(dir, "#{name}.png") }
  File.write(File.join(dir, "render.json"), JSON.generate({"schemaVersion" => 1, "inputInventory" => "complete-v1",
    "files" => files.map { |path| {"path" => path, "sha256" => "sha256:#{Digest::SHA256.file(path).hexdigest}"} }, "backgrounds" => []}))' "$workspace"

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
  # The capture inventory is the Goldie raw manifest of real captures; brand strengths name its scene IDs.
  manifest = {"device" => "iphone-6.3", "udid" => "", "capturedAt" => "", "screenshots" =>
    [["home-rain", "device.png"], ["forecast", "pair.png"], ["widget", "scene.png"]].map { |scene, file| {"sceneId" => scene, "file" => File.join(dir, file)} },
    "preview" => nil}
  File.write(File.join(dir, "captures.json"), JSON.generate(manifest))
' "$workspace"

write_spec() { # path kind patterns-json [extra-json]
  ruby -rjson -e 'value = {"schemaVersion" => 1, "kind" => ARGV[1], "app" => "テストアプリ",
    "title" => "ストア画像の提案", "brief" => "雨と風の動きを主役にする。", "patterns" => JSON.parse(ARGV[2])}
    value.merge!("brand" => "brand.json", "research" => "research.json", "captures" => "captures.json", "renders" => ["render.json"]) if ARGV[1] == "proposal"
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
    puts JSON.generate(value)' "$1" "$2" "${3:-}" "${4:-}"
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
"$tool" check --brand "$workspace/brand.json" --captures "$workspace/captures.json" --style "$workspace/style-A.json" >"$workspace/check.out"
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0]))
  abort "check output" unless value.fetch("status") == "valid" && value.fetch("strengths") == %w[sway forecast widget] && value.key?("styleSha256")' "$workspace/check.out"
brand_variant() { # name ruby-edit -> brand-<name>.json
  ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); eval(ARGV[2]); File.write(ARGV[1], JSON.generate(value))' \
    "$workspace/brand.json" "$workspace/brand-$1.json" "$2"
}
brand_variant no-avoid 'value.delete("avoid")'
expect_failure brand-missing 'brand.json is missing: avoid' "$tool" check --brand "$workspace/brand-no-avoid.json" --captures "$workspace/captures.json"
brand_variant no-world 'value.delete("world"); value.delete("story")'
expect_failure brand-missing-two 'brand.json is missing: world, story' "$tool" check --brand "$workspace/brand-no-world.json" --captures "$workspace/captures.json"
brand_variant no-license 'value["fonts"][0].delete("license")'
expect_failure font-license 'font Zen Maru Gothic has no license record' "$tool" check --brand "$workspace/brand-no-license.json" --captures "$workspace/captures.json"
brand_variant paid 'value["fonts"][0]["paid"] = true'
expect_failure paid-font 'font Zen Maru Gothic is paid; ask the user before using it' "$tool" check --brand "$workspace/brand-paid.json" --captures "$workspace/captures.json"
brand_variant paid-approved 'value["fonts"][0]["paid"] = true; value["fonts"][0]["approval"] = "2026-10-21 ユーザーが承認"'
"$tool" check --brand "$workspace/brand-paid-approved.json" --captures "$workspace/captures.json" >/dev/null
expect_failure no-captures 'missing option: --captures' "$tool" check --brand "$workspace/brand.json"
brand_variant no-screen 'value["strengths"][1]["screens"] = []'
expect_failure strength-screen 'strength forecast is not tied to a real screen' "$tool" check --brand "$workspace/brand-no-screen.json" --captures "$workspace/captures.json"
# A screen name with no real capture behind it is refused, even next to a real one.
brand_variant invented-screen 'value["strengths"][1]["screens"] = ["forecast", "teleport"]'
expect_failure invented-screen 'strength forecast names the screen teleport, which has no real capture' \
  "$tool" check --brand "$workspace/brand-invented-screen.json" --captures "$workspace/captures.json"
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); value["screenshots"][1]["file"] = File.join(File.dirname(ARGV[0]), "missing.png")
  File.write(ARGV[1], JSON.generate(value))' "$workspace/captures.json" "$workspace/captures-missing.json"
expect_failure missing-capture 'capture forecast is not a real image' "$tool" check --brand "$workspace/brand.json" --captures "$workspace/captures-missing.json"
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); value["screenshots"][1]["file"] = File.join(File.dirname(ARGV[0]), "broken.png")
  File.write(ARGV[1], JSON.generate(value))' "$workspace/captures.json" "$workspace/captures-broken.json"
expect_failure broken-capture 'capture forecast is not a real image' "$tool" check --brand "$workspace/brand.json" --captures "$workspace/captures-broken.json"
cp "$workspace/brand.json" "$workspace/brand.good.json"
cp "$workspace/brand-invented-screen.json" "$workspace/brand.json"
expect_failure proposal-invented-screen 'strength forecast names the screen teleport, which has no real capture' \
  "$tool" build --spec "$workspace/proposal.json" --root "$root" --revision r9
cp "$workspace/brand.good.json" "$workspace/brand.json"
[[ ! -e "$root/r9" ]] || fail 'a proposal with an invented screen left a revision behind'
brand_variant bad-color 'value["colors"]["accent"] = "blue"'
expect_failure brand-color 'brand.json colors.accent must be a #RRGGBB color' "$tool" check --brand "$workspace/brand-bad-color.json" --captures "$workspace/captures.json"
style_variant() { # name ruby-edit -> style-<name>.json from style-A.json
  ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); eval(ARGV[2]); File.write(ARGV[1], JSON.generate(value))' \
    "$workspace/style-A.json" "$workspace/style-$1.json" "$2"
}
style_variant no-signature 'value.delete("signature")'
expect_failure style-missing 'style spec is missing: signature' "$tool" check --brand "$workspace/brand.json" --captures "$workspace/captures.json" --style "$workspace/style-no-signature.json"
style_variant off-color 'value["tokens"] << {"name" => "neon", "hex" => "#FF00AA", "use" => "飾り"}'
expect_failure style-color 'style spec uses #FF00AA outside brand.json without a reason' "$tool" check --brand "$workspace/brand.json" --captures "$workspace/captures.json" --style "$workspace/style-off-color.json"
style_variant off-color-reason 'value["tokens"] << {"name" => "neon", "hex" => "#FF00AA", "use" => "飾り"}; value["deviations"] = [{"item" => "#ff00aa", "reason" => "夜の場面だけに使う"}]'
"$tool" check --brand "$workspace/brand.json" --captures "$workspace/captures.json" --style "$workspace/style-off-color-reason.json" >/dev/null
style_variant off-font 'value["fonts"]["headline"] = "Shippori Mincho"'
expect_failure style-font 'style spec uses the font Shippori Mincho outside brand.json without a reason' "$tool" check --brand "$workspace/brand.json" --captures "$workspace/captures.json" --style "$workspace/style-off-font.json"

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

# D-085 (#393): generated material is shown on a material sheet and used only after the user adopts it.
# Cut-outs are RGBA PNGs: "cloud" is clean, "fringe" keeps a ring of the green key color, "edge" touches
# the border, "opaque" has no alpha; "sky" and "dusk" are full backgrounds.
mat="$workspace/materials"; mkdir -p "$mat"
ruby -rzlib -e '
  def png(path, width, height, type)
    rows = (0...height).map { |y| "\x00".b + (0...width).map { |x| yield(x, y) }.join }
    chunk = ->(kind, data) { [data.bytesize].pack("N") + kind + data + [Zlib.crc32(kind + data)].pack("N") }
    File.binwrite(path, "\x89PNG\r\n\x1A\n".b + chunk.("IHDR", [width, height, 8, type, 0, 0, 0].pack("N2C5")) +
      chunk.("IDAT", Zlib::Deflate.deflate(rows.join)) + chunk.("IEND", "".b))
  end
  dir = ARGV[0]; clear = [0, 0, 0, 0].pack("C4"); white = [240, 240, 235, 255].pack("C4"); green = [0, 255, 0, 255].pack("C4")
  inside = ->(x, y, a, b) { (a...b).cover?(x) && (a...b).cover?(y) }
  png(File.join(dir, "cloud.png"), 120, 120, 6) { |x, y| inside.(x, y, 30, 90) ? white : clear }
  png(File.join(dir, "fringe.png"), 120, 120, 6) { |x, y| inside.(x, y, 36, 84) ? white : inside.(x, y, 30, 90) ? green : clear }
  png(File.join(dir, "edge.png"), 120, 120, 6) { |x, y| x < 60 ? white : clear }
  png(File.join(dir, "opaque.png"), 120, 120, 2) { |x, y| [200, 120, 80].pack("C3") }
  png(File.join(dir, "sky.png"), 120, 260, 2) { |x, y| [40, 90, 200].pack("C3") }
  png(File.join(dir, "dusk.png"), 120, 260, 2) { |x, y| [200, 90, 40].pack("C3") }
  png(File.join(dir, "unseen.png"), 120, 260, 2) { |x, y| [90, 200, 40].pack("C3") }
' "$mat"
material_spec() { # path materials-json
  ruby -rjson -e 'File.write(ARGV[0], JSON.generate({"schemaVersion" => 1, "kind" => "material", "app" => "テストアプリ",
    "title" => "素材の確認", "brief" => "雨上がりの庭の素材。", "materials" => JSON.parse(ARGV[1])}))' "$1" "$2"
}
m() { # id pattern role image [key]
  ruby -rjson -e 'value = {"id" => ARGV[0], "pattern" => ARGV[1], "role" => ARGV[2], "image" => "materials/#{ARGV[3]}", "prompt" => "雨上がりの#{ARGV[0]}、文字なし"}
    value["cutout"] = {"key" => ARGV[4]} unless ARGV[4].to_s.empty?
    puts JSON.generate(value)' "$@"
}
material_spec "$workspace/materials.json" "[$(m cloud A object cloud.png '#00FF00'),$(m sky A background sky.png),$(m dusk B background dusk.png)]"
"$tool" build --spec "$workspace/materials.json" --root "$root" --revision m1 >/dev/null
msheet="$root/m1/sheet.html"
grep -Fq "http-equiv=\"Content-Security-Policy\" content=\"default-src 'none';" "$msheet" || fail 'material sheet lacks the restrictive CSP'
! grep -Eiq 'https?://|url\(|@import|<script|<iframe|<object|<embed|<link|<form' "$msheet" || fail 'material sheet can reach the network or run script'
[[ "$(grep -o '<img src="data:image/png;base64,' "$msheet" | wc -l | tr -d ' ')" == 3 ]] || fail 'material sheet does not embed every material'
for text in '素材の確認' '「採用」か「不採用」' 'AIっぽくありきたり' '雨上がりのcloud、文字なし' '切り抜き（キー色 #00FF00）'; do
  grep -Fq -- "$text" "$msheet" || fail "material sheet does not show: $text"
done
ruby -rjson -rdigest -e 'record = JSON.parse(File.read(ARGV[0]))
  abort "material record" unless record.fetch("kind") == "material" && record.fetch("sheetSha256") == "sha256:#{Digest::SHA256.file(ARGV[1]).hexdigest}" &&
    record.fetch("materials").map { |item| item.fetch("id") } == %w[cloud sky dusk] && record.dig("materials", 0, "cutout", "keyResidue") == 0.0' "$root/m1/sheet.json" "$msheet"
expect_failure material-rebuild 'revision already exists and is never replaced' "$tool" build --spec "$workspace/materials.json" --root "$root" --revision m1
material_spec "$workspace/materials-fringe.json" "[$(m fringe A object fringe.png '#00FF00')]"
expect_failure material-fringe 'material fringe keeps' "$tool" build --spec "$workspace/materials-fringe.json" --root "$root" --revision m9
grep -Fq 'of the key color #00FF00 at its edges; separate it again' "$workspace/material-fringe.err" || fail 'fringe failure does not name the key color'
material_spec "$workspace/materials-url.json" "[$(m cloud A object cloud.png | sed 's/文字なし/https:\/\/example.com/')]"
expect_failure material-url 'must not contain URLs, markup, or style imports' "$tool" build --spec "$workspace/materials-url.json" --root "$root" --revision m9
material_spec "$workspace/materials-none.json" "[]"
expect_failure material-none 'materials must be a list of 1 to 60 entries' "$tool" build --spec "$workspace/materials-none.json" --root "$root" --revision m9
[[ ! -e "$root/m9" ]] || fail 'a refused material sheet left a revision behind'

# The cut-out check on its own: a clean cut-out passes; an opaque image, a cut-out that touches its edge
# and one that keeps the key color are refused.
"$tool" cutout --image "$mat/cloud.png" --key '#00FF00' >"$workspace/cutout.out"
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); abort "cutout result" unless value.fetch("status") == "clean" && value.fetch("keyResidue") == 0.0 && value.fetch("transparent") > 0.5' "$workspace/cutout.out"
expect_failure cutout-opaque 'has no transparent background: the PNG has no alpha channel' "$tool" cutout --image "$mat/opaque.png" --key '#00FF00'
expect_failure cutout-edge 'background is not transparent at its edges' "$tool" cutout --image "$mat/edge.png" --key '#00FF00'
expect_failure cutout-fringe 'of the key color #00FF00 at its edges' "$tool" cutout --image "$mat/fringe.png" --key '#00FF00'

# The user adopts or rejects every material by ID; anything less is not a decision. Recorded once.
expect_failure material-select 'a material sheet takes review --adopt/--reject, not select' "$tool" select --sheet "$root/m1" --pattern A
expect_failure review-missing 'every material needs --adopt or --reject; missing: dusk' "$tool" review --sheet "$root/m1" --adopt cloud,sky
expect_failure review-unknown 'unknown material id: rain' "$tool" review --sheet "$root/m1" --adopt cloud,sky,rain --reject dusk
expect_failure review-both 'material sky is both adopted and rejected' "$tool" review --sheet "$root/m1" --adopt cloud,sky --reject sky,dusk
expect_failure review-pattern-sheet 'review applies only to a material sheet' "$tool" review --sheet "$root/r1" --adopt A
[[ ! -e "$root/m1/material-review.json" ]] || fail 'a refused review was recorded'
cp -R "$root/m1" "$workspace/tampered-m1"
printf '<!-- edited -->\n' >>"$workspace/tampered-m1/sheet.html"
expect_failure review-tampered 'sheet.html differs from the sheet record' "$tool" review --sheet "$workspace/tampered-m1" --adopt cloud,sky --reject dusk
"$tool" review --sheet "$root/m1" --adopt cloud,sky --reject dusk >/dev/null
ruby -rjson -rdigest -e 'value = JSON.parse(File.read(ARGV[0])); sheet = JSON.parse(File.read(ARGV[1]))
  abort "review fields" unless value.keys.sort == %w[decision decisions recordedAt revision schemaVersion sheetSha256] && value.fetch("decision") == "user-explicit"
  abort "review digest" unless value.fetch("sheetSha256") == sheet.fetch("sheetSha256") && value.fetch("revision") == "m1"
  abort "review decisions" unless value.fetch("decisions").map { |d| d.values_at("id", "decision") } == [%w[cloud adopted], %w[sky adopted], %w[dusk rejected]] &&
    value.fetch("decisions").first.fetch("sha256") == "sha256:#{Digest::SHA256.file(ARGV[2]).hexdigest}"' "$root/m1/material-review.json" "$root/m1/sheet.json" "$mat/cloud.png"
expect_failure review-again 'a review is already recorded for this sheet and is never replaced' "$tool" review --sheet "$root/m1" --adopt cloud,sky,dusk

# A proposal tile may draw only on adopted material, byte for byte: the render record of each tile
# names its generated inputs (background slice and layers), and the tile image itself counts when it
# is a reviewed material. A tile in no render record is refused.
render_record() { # name concept-inputs-json  (each input: {"via": "background"|"layer", "path": ...})
  ruby -rjson -rdigest -e 'dir = ARGV[0]; inputs = JSON.parse(ARGV[2])
    digest = ->(path) { "sha256:#{Digest::SHA256.file(path).hexdigest}" }
    files = %w[device pair scene concept callout].map { |name| File.join(dir, "#{name}.png") } + [File.join(dir, "broken.png")]
    index = files.index(File.join(dir, "concept.png")) + 1
    record = {"schemaVersion" => 1, "inputInventory" => "complete-v1", "files" => files.map { |path| {"path" => path, "sha256" => digest.(path)} },
      "backgrounds" => inputs.select { |input| input["via"] == "background" }.map { |input| path = File.join(dir, input["path"])
        {"file" => File.join(dir, "concept.png"), "source" => path, "sourceSha256" => digest.(path)} },
      "layers" => inputs.select { |input| input["via"] == "layer" }.map { |input| path = File.join(dir, input["path"])
        {"src" => path, "sha256" => digest.(path), "tiles" => [index]} }}
    File.write(File.join(dir, "render-#{ARGV[1]}.json"), JSON.generate(record))' "$workspace" "$1" "$2"
}
with_inputs() { # name concept-inputs-json
  render_record "$1" "$2"
  write_spec "$workspace/$1.json" proposal "[$good,$early,$many]" "{\"materialReviews\":[\"store-creative/m1\"],\"renders\":[\"render-$1.json\"]}"
}
with_inputs adopted '[{"via":"background","path":"materials/cloud.png"},{"via":"layer","path":"materials/sky.png"}]'
"$tool" build --spec "$workspace/adopted.json" --root "$root" --revision mat-ok >/dev/null
ruby -rjson -rdigest -e 'pattern = JSON.parse(File.read(ARGV[0])).fetch("patterns").find { |item| item.fetch("id") == "C" }
  abort "pattern materials: #{pattern["materials"]}" unless pattern.fetch("materials") == ARGV[1, 2].map { |path| "sha256:#{Digest::SHA256.file(path).hexdigest}" }' \
  "$root/mat-ok/sheet.json" "$mat/cloud.png" "$mat/sky.png"
grep -Fq '使う生成素材：2点（すべて素材の確認で採用済み）' "$root/mat-ok/sheet.html" || fail 'proposal sheet does not show the adopted materials'
with_inputs rejected '[{"via":"background","path":"materials/dusk.png"}]'
expect_failure material-rejected 'tile 5 of A uses dusk.png, which the user rejected' "$tool" build --spec "$workspace/rejected.json" --root "$root" --revision m9
with_inputs rejected-layer '[{"via":"background","path":"materials/cloud.png"},{"via":"layer","path":"materials/dusk.png"}]'
expect_failure material-rejected-layer 'tile 5 of A uses dusk.png, which the user rejected' "$tool" build --spec "$workspace/rejected-layer.json" --root "$root" --revision m9
with_inputs unseen '[{"via":"layer","path":"materials/unseen.png"}]'
expect_failure material-unseen 'tile 5 of A uses unseen.png, which the user has not adopted on a material sheet' "$tool" build --spec "$workspace/unseen.json" --root "$root" --revision m9
cp "$mat/sky.png" "$workspace/sky.original.png"
printf 'x' >>"$mat/sky.png"
with_inputs changed '[{"via":"background","path":"materials/sky.png"}]'
expect_failure material-changed 'tile 5 of A uses sky.png, which changed after the user reviewed it' "$tool" build --spec "$workspace/changed.json" --root "$root" --revision m9
cp "$workspace/sky.original.png" "$mat/sky.png"
# A rejected material placed directly as a tile is refused even when its render record names no inputs.
render_record direct '[]'
ruby -rjson -rdigest -e 'path = ARGV[0]; record = JSON.parse(File.read(path)); image = ARGV[1]
  record["files"] << {"path" => image, "sha256" => "sha256:#{Digest::SHA256.file(image).hexdigest}"}; File.write(path, JSON.generate(record))' \
  "$workspace/render-direct.json" "$mat/dusk.png"
write_spec "$workspace/direct.json" proposal "[$good,$early,$(pattern D "$(tiles photo device scene pair device device pair | sed 's/"image":"scene.png"/"image":"materials\/dusk.png"/')")]" \
  '{"materialReviews":["store-creative/m1"],"renders":["render-direct.json"]}'
expect_failure material-direct 'tile 2 of D uses dusk.png, which the user rejected' "$tool" build --spec "$workspace/direct.json" --root "$root" --revision m9
write_spec "$workspace/unrendered.json" proposal "[$good,$early,$(pattern E "$(tiles photo device scene pair device device pair | sed 's/"image":"scene.png"/"image":"materials\/unseen.png"/')")]" \
  '{"materialReviews":["store-creative/m1"]}'
expect_failure material-unrendered 'tile 2 of E is in no render record' "$tool" build --spec "$workspace/unrendered.json" --root "$root" --revision m9
# A render record that does not say it lists every input (an old render) is refused.
ruby -rjson -e 'path = ARGV[0]; record = JSON.parse(File.read(path)); record.delete("inputInventory"); File.write(ARGV[1], JSON.generate(record))' \
  "$workspace/render-adopted.json" "$workspace/render-old.json"
write_spec "$workspace/old-render.json" proposal "[$good,$early,$many]" '{"materialReviews":["store-creative/m1"],"renders":["render-old.json"]}'
expect_failure old-render 'render record render-old.json has no complete input inventory' "$tool" build --spec "$workspace/old-render.json" --root "$root" --revision m9
write_spec "$workspace/no-renders.json" proposal "[$good,$early,$many]" '{"renders":[]}'
expect_failure no-renders 'a proposal needs renders' "$tool" build --spec "$workspace/no-renders.json" --root "$root" --revision m9
# A review that no longer matches its sheet is never trusted.
cp -R "$root/m1" "$root/m1-forged"
ruby -rjson -e 'path = ARGV[0]; value = JSON.parse(File.read(path)); value["sheetSha256"] = "sha256:" + "0" * 64; File.write(path, JSON.generate(value))' \
  "$root/m1-forged/material-review.json"
write_spec "$workspace/forged-review.json" proposal "[$good,$early,$many]" '{"materialReviews":["store-creative/m1-forged"],"renders":["render-adopted.json"]}'
expect_failure material-forged-review 'material review of m1 does not match its sheet' "$tool" build --spec "$workspace/forged-review.json" --root "$root" --revision m9
[[ ! -e "$root/m9" ]] || fail 'a refused proposal left a revision behind'

# goldie/assets/provenance.json: every adopted image carries the material review that adopted it.
assets="$workspace/goldie-assets"; mkdir -p "$assets"
cp "$mat/cloud.png" "$mat/dusk.png" "$assets/"
provenance() { # name ruby-edit
  ruby -rjson -rdigest -e 'review = "sha256:#{Digest::SHA256.file(ARGV[2]).hexdigest}"
    image = ->(file) { {"file" => file, "sha256" => "sha256:#{Digest::SHA256.file(File.join(ARGV[1], file)).hexdigest}", "prompt" => "雨上がりの雲",
      "mode" => "generate", "generator" => "codex-builtin-imagegen", "generatedAt" => "2026-10-22T00:00:00Z", "revision" => "mat-ok",
      "materialReview" => {"revision" => "m1", "reviewSha256" => review, "decision" => "adopted"}} }
    value = {"schemaVersion" => 1, "images" => [image.("cloud.png")]}
    eval(ARGV[3])
    File.write(File.join(ARGV[1], "provenance-#{ARGV[0]}.json"), JSON.generate(value))' "$1" "$assets" "$root/m1/material-review.json" "$2"
}
provenance good ''
"$tool" provenance --file "$assets/provenance-good.json" --root "$root" >"$workspace/provenance.out"
ruby -rjson -e 'abort "provenance result" unless JSON.parse(File.read(ARGV[0])) == {"status" => "valid", "images" => 1}' "$workspace/provenance.out"
provenance no-review 'value["images"][0].delete("materialReview")'
expect_failure provenance-no-review 'image cloud.png has no material review record' "$tool" provenance --file "$assets/provenance-no-review.json" --root "$root"
provenance rejected 'value["images"] << image.("dusk.png")'
expect_failure provenance-rejected 'image dusk.png was rejected on the material review m1' "$tool" provenance --file "$assets/provenance-rejected.json" --root "$root"
provenance digest 'value["images"][0]["sha256"] = "sha256:" + "0" * 64'
expect_failure provenance-digest 'image cloud.png does not match its recorded sha256' "$tool" provenance --file "$assets/provenance-digest.json" --root "$root"
provenance other-review 'value["images"][0]["materialReview"]["reviewSha256"] = "sha256:" + "1" * 64'
expect_failure provenance-other-review 'image cloud.png names a material review that differs from m1' "$tool" provenance --file "$assets/provenance-other-review.json" --root "$root"

# D-085 (#391): a header sheet compares two to six product page header options; "none" (no header) is
# always a choice. Same CSP, digest and no-replace rules as the other sheets.
hs="$workspace/headers"; mkdir -p "$hs"
ffmpeg -y -loglevel error -f lavfi -i "color=c=0x2A5599:s=3840x1646,format=rgb24" -frames:v 1 "$hs/a.png"
ffmpeg -y -loglevel error -f lavfi -i "color=c=0xE9C46A:s=3840x1646,format=rgb24" -frames:v 1 "$hs/b.png"
ffmpeg -y -loglevel error -f lavfi -i "color=c=0xE9C46A:s=1920x1080,format=rgb24" -frames:v 1 "$hs/wide.png"
printf 'video bytes' >"$hs/a.mp4"
header_sheet() { # path options-json
  ruby -rjson -e 'File.write(ARGV[0], JSON.generate({"schemaVersion" => 1, "kind" => "header", "app" => "テストアプリ", "title" => "ヘッダーの提案",
    "brief" => "雨上がりの庭を広く見せる。", "options" => JSON.parse(ARGV[1])}))' "$1" "$2"
}
hopt() { # id image [video]
  ruby -rjson -e 'value = {"id" => ARGV[0], "title" => "案#{ARGV[0]}", "hypothesis" => "世界観を一目で伝える。", "tradeoffs" => "画面が小さく見える。",
    "image" => "headers/#{ARGV[1]}"}; value["video"] = "headers/#{ARGV[2]}" unless ARGV[2].to_s.empty?; puts JSON.generate(value)' "$1" "$2" "${3:-}"
}
header_sheet "$workspace/header.json" "[$(hopt A a.png a.mp4),$(hopt B b.png)]"
"$tool" build --spec "$workspace/header.json" --root "$root" --revision h1 >/dev/null
hsheet="$root/h1/sheet.html"
grep -Fq "http-equiv=\"Content-Security-Policy\" content=\"default-src 'none';" "$hsheet" || fail 'header sheet lacks the restrictive CSP'
! grep -Eiq 'https?://|url\(|@import|<script|<iframe|<object|<embed|<link|<form|<video' "$hsheet" || fail 'header sheet can reach the network or run script'
[[ "$(grep -o '<img src="data:image/png;base64,' "$hsheet" | wc -l | tr -d ' ')" == 2 ]] || fail 'header sheet does not embed every option'
for text in 'プロダクトページヘッダー' 'ヘッダーなし' 'Preview tool' 'ループ動画あり（a.mp4' '静止画のみ'; do
  grep -Fq -- "$text" "$hsheet" || fail "header sheet does not show: $text"
done
ruby -rjson -rdigest -e 'record = JSON.parse(File.read(ARGV[0]))
  abort "header record" unless record.fetch("kind") == "header" && record.fetch("sheetSha256") == "sha256:#{Digest::SHA256.file(ARGV[1]).hexdigest}" &&
    record.fetch("options").map { |item| item.fetch("id") } == %w[A B] && record.dig("options", 0, "videoSha256") == "sha256:#{Digest::SHA256.file(ARGV[2]).hexdigest}" &&
    record.dig("options", 1, "videoSha256").nil?' "$root/h1/sheet.json" "$hsheet" "$hs/a.mp4"
header_sheet "$workspace/header-one.json" "[$(hopt A a.png)]"
expect_failure header-one 'a header sheet compares two to six header options; found 1' "$tool" build --spec "$workspace/header-one.json" --root "$root" --revision h9
header_sheet "$workspace/header-none-id.json" "[$(hopt none a.png),$(hopt B b.png)]"
expect_failure header-none-id 'header option id none is reserved for no header' "$tool" build --spec "$workspace/header-none-id.json" --root "$root" --revision h9
header_sheet "$workspace/header-size.json" "[$(hopt A a.png),$(hopt B wide.png)]"
expect_failure header-size 'header option B image is not a 3840x1646 PNG header' "$tool" build --spec "$workspace/header-size.json" --root "$root" --revision h9
[[ ! -e "$root/h9" ]] || fail 'a refused header sheet left a revision behind'
expect_failure header-rebuild 'revision already exists and is never replaced' "$tool" build --spec "$workspace/header.json" --root "$root" --revision h1
# The user chooses one listed option or no header, once.
expect_failure header-unknown 'unknown header option id: C' "$tool" select --sheet "$root/h1" --pattern C
expect_failure header-tiles 'a header sheet takes --pattern <option ID> or --pattern none' "$tool" select --sheet "$root/h1" --tiles 1=A:1
cp -R "$root/h1" "$workspace/tampered-h1"
printf '<!-- edited -->\n' >>"$workspace/tampered-h1/sheet.html"
expect_failure header-tampered 'sheet.html differs from the sheet record' "$tool" select --sheet "$workspace/tampered-h1" --pattern A
"$tool" select --sheet "$root/h1" --pattern none >/dev/null
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); record = JSON.parse(File.read(ARGV[1]))
  abort "no-header selection" unless value.fetch("selection") == {"type" => "no-header"} && value.fetch("decision") == "user-explicit" &&
    value.fetch("sheetSha256") == record.fetch("sheetSha256") && value.fetch("revision") == "h1"' "$root/h1/selection.json" "$root/h1/sheet.json"
expect_failure header-reselect 'a selection is already recorded for this sheet and is never replaced' "$tool" select --sheet "$root/h1" --pattern A
"$tool" build --spec "$workspace/header.json" --root "$root" --revision h2 >/dev/null
"$tool" select --sheet "$root/h2" --pattern A >/dev/null
ruby -rjson -rdigest -e 'selection = JSON.parse(File.read(ARGV[0])).fetch("selection")
  abort "header selection: #{selection}" unless selection.values_at("type", "optionId") == %w[header A] &&
    selection.fetch("sha256") == "sha256:#{Digest::SHA256.file(ARGV[1]).hexdigest}" && selection.fetch("videoSha256") == "sha256:#{Digest::SHA256.file(ARGV[2]).hexdigest}"' \
  "$root/h2/selection.json" "$hs/a.png" "$hs/a.mp4"

# D-085 (#392): a poster sheet shows candidate poster frames of one App Preview; the user picks one,
# whose time is recorded with the video's SHA-256, once. A time outside the video is refused.
ps="$workspace/poster"; mkdir -p "$ps"
ffmpeg -y -loglevel error -f lavfi -i "testsrc2=s=320x240:r=30:d=10" -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$ps/preview.mp4"
for t in 1 5 9; do ffmpeg -y -loglevel error -ss "$t" -i "$ps/preview.mp4" -frames:v 1 -vf format=rgb24 "$ps/t$t.png"; done
poster_sheet() { # path candidates-json
  ruby -rjson -e 'File.write(ARGV[0], JSON.generate({"schemaVersion" => 1, "kind" => "poster", "app" => "テストアプリ", "title" => "ポスターフレーム",
    "video" => "poster/preview.mp4", "candidates" => JSON.parse(ARGV[1])}))' "$1" "$2"
}
pc() { ruby -rjson -e 'puts JSON.generate({"id" => ARGV[0], "seconds" => Float(ARGV[1]), "image" => "poster/#{ARGV[2]}", "note" => "花が開く瞬間"})' "$@"; }
poster_sheet "$workspace/poster.json" "[$(pc t1 1 t1.png),$(pc t5 5 t5.png),$(pc t9 9 t9.png)]"
"$tool" build --spec "$workspace/poster.json" --root "$root" --revision pf1 >/dev/null
psheet="$root/pf1/sheet.html"
grep -Fq "http-equiv=\"Content-Security-Policy\" content=\"default-src 'none';" "$psheet" || fail 'poster sheet lacks the restrictive CSP'
! grep -Eiq 'https?://|url\(|@import|<script|<iframe|<object|<embed|<link|<form|<video' "$psheet" || fail 'poster sheet can reach the network or run script'
[[ "$(grep -o '<img src="data:image/png;base64,' "$psheet" | wc -l | tr -d ' ')" == 3 ]] || fail 'poster sheet does not embed every candidate'
for text in 'App Previewのポスターフレーム' '5秒の位置' '5.00秒' '花が開く瞬間'; do grep -Fq -- "$text" "$psheet" || fail "poster sheet does not show: $text"; done
poster_sheet "$workspace/poster-outside.json" "[$(pc t1 1 t1.png),$(pc t12 12 t9.png)]"
expect_failure poster-outside 'poster candidate t12 at 12.00 seconds is outside the 10.00-second preview' "$tool" build --spec "$workspace/poster-outside.json" --root "$root" --revision pf9
poster_sheet "$workspace/poster-negative.json" "[$(pc tm -1 t1.png)]"
expect_failure poster-negative 'poster candidate tm at -1.00 seconds is outside the 10.00-second preview' "$tool" build --spec "$workspace/poster-negative.json" --root "$root" --revision pf9
poster_sheet "$workspace/poster-none.json" "[]"
expect_failure poster-none 'a poster sheet shows one to six candidate frames; found 0' "$tool" build --spec "$workspace/poster-none.json" --root "$root" --revision pf9
[[ ! -e "$root/pf9" ]] || fail 'a refused poster sheet left a revision behind'
expect_failure poster-rebuild 'revision already exists and is never replaced' "$tool" build --spec "$workspace/poster.json" --root "$root" --revision pf1
expect_failure poster-unknown 'unknown poster candidate id: t3' "$tool" select --sheet "$root/pf1" --pattern t3
expect_failure poster-tiles 'a poster sheet takes --pattern <candidate ID>' "$tool" select --sheet "$root/pf1" --tiles 1=t1:1
cp -R "$root/pf1" "$workspace/tampered-pf1"
printf '<!-- edited -->\n' >>"$workspace/tampered-pf1/sheet.html"
expect_failure poster-tampered 'sheet.html differs from the sheet record' "$tool" select --sheet "$workspace/tampered-pf1" --pattern t5
cp -R "$root/pf1" "$workspace/forged-pf1"
ruby -rjson -e 'path = ARGV[0]; record = JSON.parse(File.read(path)); record["candidates"][1]["seconds"] = 3.0; File.write(path, JSON.generate(record))' "$workspace/forged-pf1/sheet.json"
expect_failure poster-forged 'sheet.json differs from the displayed sheet' "$tool" select --sheet "$workspace/forged-pf1" --pattern t5
"$tool" select --sheet "$root/pf1" --pattern t5 >/dev/null
ruby -rjson -rdigest -e 'value = JSON.parse(File.read(ARGV[0])); record = JSON.parse(File.read(ARGV[1]))
  selection = value.fetch("selection")
  abort "poster selection: #{value}" unless selection.values_at("type", "candidateId", "seconds") == ["poster", "t5", 5.0] &&
    selection.fetch("videoSha256") == "sha256:#{Digest::SHA256.file(ARGV[2]).hexdigest}" && value.fetch("decision") == "user-explicit" &&
    value.fetch("sheetSha256") == record.fetch("sheetSha256")' "$root/pf1/selection.json" "$root/pf1/sheet.json" "$ps/preview.mp4"
expect_failure poster-reselect 'a selection is already recorded for this sheet and is never replaced' "$tool" select --sheet "$root/pf1" --pattern t1

echo 'appstore-creative sheet tests passed'
