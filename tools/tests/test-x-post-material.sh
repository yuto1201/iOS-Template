#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby readlink ffmpeg ffprobe

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$repo_root"

skill_dir=.agents/skills/x-post-material
claude_skill=.claude/skills/x-post-material
fixture=tools/tests/fixtures/x-post-material/XPosts
check=tools/check-x-posts.sh

fail() {
  echo "x-post-material: $*" >&2
  exit 1
}

for path in "$skill_dir/SKILL.md" "$skill_dir/templates/README.md" "$skill_dir/templates/post.md" "$check" tools/lib/x-posts-check.rb; do
  [[ -f "$path" ]] || fail "missing resource: $path"
done
[[ -x "$check" ]] || fail "$check must be executable"
[[ -L "$claude_skill" ]] || fail 'Claude route must be a symlink'
[[ "$(readlink "$claude_skill")" == ../../.agents/skills/x-post-material ]] || fail 'Claude route is not portable'
[[ -f "$claude_skill/SKILL.md" ]] || fail 'Claude route is broken'

ruby -rjson <<'RUBY'
# encoding: UTF-8
def fail!(message)
  abort "x-post-material: #{message}"
end

def require_all(label, text, values)
  missing = values.reject { |value| text.include?(value) }
  fail!("#{label} lacks #{missing.inspect}") unless missing.empty?
end

skill = File.read('.agents/skills/x-post-material/SKILL.md', encoding: 'UTF-8')
fail!('SKILL.md front matter name differs') unless skill.start_with?("---\nname: x-post-material\n")
require_all('SKILL.md', skill, [
  'D-096', '`XPosts/<YYYY-MM-DD>-<サブタイトル>/`', '英小文字、数字、ハイフン', '日本語だけで書く',
  '1本5秒以上30秒以下', 'アニメーションを録画する作業を必ず行う', '専用Simulator（D-063、D-070、D-079）だけ',
  '既存の`XPosts/`のすべての`post.json`と`post.md`を読む', '`related`', 'フォルダを2つ作り',
  '投稿の材料のためだけのIssueは立てない', 'tools/check-x-posts.sh XPosts', '## 報告',
  '秘密、認証情報、個人情報'
])

readme = File.read('.agents/skills/x-post-material/templates/README.md', encoding: 'UTF-8')
guide = readme.lines.grep(/\A\d+\. /)
fail!("Grok Bot guide must have 7 numbered items, found #{guide.length}") unless guide.length == 7
fail!('Grok Bot guide items are out of order') unless guide.map { |line| line.to_i } == (1..7).to_a
require_all('Grok Bot guide', readme, [
  'GitHubのこのリポジトリの`main`の`XPosts/`', '「事実」に書いてあることだけ', '画像は4枚まで、または動画1本',
  '`related`に書いてあるフォルダは、内容が近い', '投稿済みの記録は、Grok Bot自身の側に残す', '投稿は1日1つ程度'
])

post = File.read('.agents/skills/x-post-material/templates/post.md', encoding: 'UTF-8')
require_all('post.md template', post, ['## 事実', '## 推しどころ', '## 画像と動画'])

ship = File.read('.agents/skills/ship-issue/SKILL.md', encoding: 'UTF-8')
fail!('ship-issue does not route to x-post-material') unless ship.include?('[`x-post-material`](../x-post-material/SKILL.md)')

manifest = JSON.parse(File.read('Config/repository-tests.json'))
rule = manifest['domainRules'].find { |entry| entry['domain'] == 'x-post-material' }
fail!('repository-tests lacks the x-post-material domain') unless rule
fail!('x-post-material domain does not own XPosts/') unless rule['prefixes'].include?('XPosts/')
test = manifest['tests'].find { |entry| entry['path'] == 'tools/tests/test-x-post-material.sh' }
fail!('repository-tests lacks the x-post-material test') unless test && test['domains'] == ['x-post-material']

# Template sync plans only the template's tracked files and requires every ownership prefix to match one, so
# an app's XPosts/ stays app-only and untouched as long as the template itself tracks nothing there.
ownership = JSON.parse(File.read('tools/template-sync/ownership.json'))
listed = ownership['rules'].flat_map { |entry| entry['paths'] + entry['prefixes'] }
fail!('template sync ownership must not list XPosts/') if listed.any? { |path| path.start_with?('XPosts') }
RUBY

# Config/development-device.json is template-only (D-086), so it marks the template repository itself.
if [[ -f Config/development-device.json ]]; then
  [[ -z "$(git ls-files -- XPosts)" ]] || fail 'the template itself must not track XPosts/ material'
fi

"$check" "$fixture" >/dev/null || fail 'valid fixture was rejected'
if [[ -d XPosts ]]; then
  "$check" XPosts >/dev/null || fail 'this repository XPosts/ was rejected'
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/x-post-material.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
post=2026-10-25-icon-list

expect_reject() {
  local label=$1 root=$2
  if "$check" "$root" >/dev/null 2>"$tmp/stderr"; then
    fail "accepted invalid material: $label"
  fi
}

case_root() {
  local root="$tmp/$1"
  rm -rf "$root"
  cp -R "$fixture" "$root"
  printf '%s\n' "$root"
}

edit_json() {
  ruby -rjson -e 'path = ARGV.shift; data = JSON.parse(File.read(path)); eval(ARGV.shift); File.write(path, JSON.pretty_generate(data))' "$@"
}

root=$(case_root japanese-name); mv "$root/$post" "$root/2026-10-25-アイコン一覧"; expect_reject 'Japanese subtitle' "$root"
root=$(case_root no-date); mv "$root/$post" "$root/icon-list"; expect_reject 'missing date' "$root"
root=$(case_root bad-date); mv "$root/$post" "$root/2026-02-30-icon-list"; expect_reject 'impossible date' "$root"
root=$(case_root upper-name); mv "$root/$post" "$root/2026-10-25-Icon-List"; expect_reject 'uppercase subtitle' "$root"
root=$(case_root no-post-md); rm "$root/$post/post.md"; expect_reject 'missing post.md' "$root"
root=$(case_root no-section); ruby -i -pe 'sub(/\A## 推しどころ\n\z/, "## その他\n")' "$root/$post/post.md"; expect_reject 'missing section' "$root"
root=$(case_root placeholder); printf -- '- <ここに書く>\n' >>"$root/$post/post.md"; expect_reject 'template placeholder' "$root"
root=$(case_root undescribed); ruby -i -ne 'print unless $_.include?("`02-scroll.mp4`")' "$root/$post/post.md"; expect_reject 'media not described in post.md' "$root"
root=$(case_root unlisted); cp "$root/$post/01-icon-grid.png" "$root/$post/03-extra.png"; printf -- '- `03-extra.png`：追加の画像。\n' >>"$root/$post/post.md"; expect_reject 'media missing from post.json' "$root"
root=$(case_root stray-file); printf 'x' >"$root/$post/notes.txt"; expect_reject 'unexpected file' "$root"
root=$(case_root wrong-kind); edit_json "$root/$post/post.json" 'data["media"][0]["kind"] = "video"'; expect_reject 'wrong media kind' "$root"
root=$(case_root date-mismatch); edit_json "$root/$post/post.json" 'data["createdAt"] = "2026-10-24"'; expect_reject 'createdAt mismatch' "$root"
root=$(case_root extra-key); edit_json "$root/$post/post.json" 'data["posted"] = true'; expect_reject 'extra post.json key' "$root"
root=$(case_root missing-related); edit_json "$root/$post/post.json" 'data["related"] = ["2026-10-01-other"]'; expect_reject 'related folder missing' "$root"
root=$(case_root no-image); edit_json "$root/$post/post.json" 'data["media"].shift'; rm "$root/$post/01-icon-grid.png"; expect_reject 'no image' "$root"
root=$(case_root readme); printf '\n' >>"$root/README.md"; expect_reject 'edited README.md' "$root"
root=$(case_root short-video); ffmpeg -v error -y -f lavfi -i 'testsrc=size=96x96:rate=10:duration=3' -c:v libx264 -pix_fmt yuv420p -an "$root/$post/02-scroll.mp4"
expect_reject 'video shorter than 5 seconds' "$root"
root=$(case_root long-video); ffmpeg -v error -y -f lavfi -i 'testsrc=size=96x96:rate=10:duration=31' -c:v libx264 -pix_fmt yuv420p -an "$root/$post/02-scroll.mp4"
expect_reject 'video longer than 30 seconds' "$root"

root=$(case_root related-ok)
cp -R "$root/$post" "$root/2026-10-26-icon-detail"
edit_json "$root/2026-10-26-icon-detail/post.json" 'data["createdAt"] = "2026-10-26"; data["related"] = ["2026-10-25-icon-list"]'
"$check" "$root" >/dev/null || fail 'valid related folders were rejected'

echo 'x-post-material: passed'
