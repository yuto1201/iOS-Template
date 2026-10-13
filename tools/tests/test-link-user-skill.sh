#!/bin/bash
set -euo pipefail

# D-078: tools/link-user-skill.sh links a user skill of the template into ~/.claude/skills and
# ~/.codex/skills. Every case runs with a fake HOME in a temporary folder; the real HOME is never used.
# A new link is made for both tools, a second run changes nothing, and a folder, a file or a symlink to
# another place stops the tool with nothing changed, as does an invalid name or a skill without SKILL.md.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby readlink shasum

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
tool="$repo_root/tools/link-user-skill.sh"
skill=ios-template-sync
source_dir="$repo_root/.agents/user-skills/$skill"
work=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-link-user-skill.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT

fail() { printf 'link-user-skill regression: %s\n' "$1" >&2; exit 1; }

[[ -x "$tool" ]] || fail 'the tool must be executable'
[[ -f "$source_dir/SKILL.md" ]] || fail "the $skill user skill is missing"

# Every entry under a folder, with each symlink's target and each file's digest.
snapshot() {
  ruby -rdigest -e '
    root = ARGV.fetch(0)
    entries = Dir.glob("**/*", File::FNM_DOTMATCH, base: root).reject { |path| File.basename(path) == "." }.sort
    puts(entries.map do |path|
      full = File.join(root, path)
      if File.symlink?(full) then "#{path} -> #{File.readlink(full)}"
      elsif File.directory?(full) then "#{path}/"
      else "#{path} #{Digest::SHA256.file(full).hexdigest}"
      end
    end)
  ' "$1" | shasum -a 256
}

# run_link HOME OUTPUT ARGS...: the tool with this fake HOME; returns its status.
run_link() {
  local home=$1 output=$2 status=0
  shift 2
  HOME="$home" "$tool" "$@" >"$output" 2>&1 || status=$?
  return "$status"
}

# expect_refused LABEL HOME MESSAGE ARGS...: the tool fails, says MESSAGE and leaves HOME unchanged.
expect_refused() {
  local label=$1 home=$2 message=$3 before
  shift 3
  before=$(snapshot "$home")
  if run_link "$home" "$work/$label.out" "$@"; then
    fail "$label was accepted"
  fi
  grep -Fq -- "$message" "$work/$label.out" || { cat "$work/$label.out" >&2; fail "$label: unexpected message"; }
  [[ "$(snapshot "$home")" == "$before" ]] || fail "$label changed the fake HOME"
}

expect_linked() {
  local home=$1 tool_dir
  for tool_dir in .claude .codex; do
    [[ -L "$home/$tool_dir/skills/$skill" ]] || fail "$tool_dir/skills/$skill is not a symlink"
    [[ "$(readlink "$home/$tool_dir/skills/$skill")" == "$source_dir" ]] || fail "$tool_dir/skills/$skill points elsewhere"
    [[ -f "$home/$tool_dir/skills/$skill/SKILL.md" ]] || fail "$tool_dir/skills/$skill does not reach SKILL.md"
  done
}

# A new link for both tools; the missing skills folders are created.
home="$work/new-home"
mkdir "$home"
run_link "$home" "$work/new.out" "$skill" || { cat "$work/new.out" >&2; fail 'a new link failed'; }
expect_linked "$home"
for tool_dir in .claude .codex; do
  grep -Fxq "linked: $home/$tool_dir/skills/$skill -> $source_dir" "$work/new.out" || fail "new link not reported for $tool_dir"
done

# A second run finds the same links and changes nothing.
before=$(snapshot "$home")
run_link "$home" "$work/again.out" "$skill" || { cat "$work/again.out" >&2; fail 'a second run failed'; }
[[ "$(snapshot "$home")" == "$before" ]] || fail 'a second run changed the fake HOME'
for tool_dir in .claude .codex; do
  grep -Fxq "already linked: $home/$tool_dir/skills/$skill -> $source_dir" "$work/again.out" || fail "already linked not reported for $tool_dir"
done

# One tool already linked: only the other link is made.
home="$work/half-home"
mkdir -p "$home/.claude/skills" "$home/.codex"
ln -s "$source_dir" "$home/.claude/skills/$skill"
run_link "$home" "$work/half.out" "$skill" || { cat "$work/half.out" >&2; fail 'linking the missing tool failed'; }
expect_linked "$home"
grep -Fxq "already linked: $home/.claude/skills/$skill -> $source_dir" "$work/half.out" || fail 'the existing link was not reported'
grep -Fxq "linked: $home/.codex/skills/$skill -> $source_dir" "$work/half.out" || fail 'the new link was not reported'

# A folder of that name is never replaced, and the other tool is not linked either.
home="$work/folder-home"
mkdir -p "$home/.claude/skills/$skill"
printf '%s\n' 'own copy' >"$home/.claude/skills/$skill/SKILL.md"
expect_refused existing-folder "$home" "$home/.claude/skills/$skill already exists as a folder or file" "$skill"
grep -Fq 'nothing was changed' "$work/existing-folder.out" || fail 'the refusal does not say nothing was changed'
[[ ! -e "$home/.codex" ]] || fail 'the other tool was linked despite the refusal'

# A file of that name.
home="$work/file-home"
mkdir -p "$home/.codex/skills"
printf '%s\n' 'note' >"$home/.codex/skills/$skill"
expect_refused existing-file "$home" "$home/.codex/skills/$skill already exists as a folder or file" "$skill"
[[ ! -e "$home/.claude" ]] || fail 'the other tool was linked despite the refusal'

# A symlink to another place, existing or not.
home="$work/foreign-home"
mkdir -p "$home/.codex/skills" "$work/elsewhere/$skill"
printf '%s\n' 'other' >"$work/elsewhere/$skill/SKILL.md"
ln -s "$work/elsewhere/$skill" "$home/.codex/skills/$skill"
expect_refused foreign-symlink "$home" "$home/.codex/skills/$skill is a symlink to $work/elsewhere/$skill" "$skill"
[[ ! -e "$home/.claude" ]] || fail 'the other tool was linked despite the refusal'
home="$work/dangling-home"
mkdir -p "$home/.claude/skills"
ln -s "$work/missing/$skill" "$home/.claude/skills/$skill"
expect_refused dangling-symlink "$home" "$home/.claude/skills/$skill is a symlink to $work/missing/$skill" "$skill"
# A relative symlink names another path, even if it reaches the same folder.
home="$work/relative-home"
mkdir -p "$home/.claude/skills"
up=$(printf '../%.0s' {1..40})
relative="${up}${source_dir#/}"
ln -s "$relative" "$home/.claude/skills/$skill"
[[ -f "$home/.claude/skills/$skill/SKILL.md" ]] || fail 'the relative symlink does not reach the skill'
expect_refused relative-symlink "$home" "is a symlink to $relative, not to $source_dir" "$skill"

# A skills path that is not a folder.
home="$work/skills-file-home"
mkdir -p "$home/.claude"
printf '%s\n' 'not a folder' >"$home/.claude/skills"
expect_refused skills-file "$home" "$home/.claude/skills is not a folder" "$skill"

# Invalid names and arguments.
home="$work/name-home"
mkdir "$home"
for name in '../ios-template-sync' 'Ios-template-sync' '-ios' 'ios_template' 'a/b' 'ios template' '.hidden'; do
  expect_refused "invalid-name" "$home" 'invalid skill name' "$name"
done
expect_refused invalid-empty "$home" 'invalid skill name' ''
expect_refused no-argument "$home" 'usage: link-user-skill.sh <name>'
expect_refused two-arguments "$home" 'usage: link-user-skill.sh <name>' "$skill" extra

# A skill that does not exist, and one without SKILL.md, in a copy of the tool's layout.
expect_refused unknown-skill "$home" 'no user skill with a SKILL.md' no-such-skill
fake_template="$work/fake-template"
mkdir -p "$fake_template/tools" "$fake_template/.agents/user-skills/empty-skill" "$fake_template/.agents/user-skills/linked-file"
cp "$tool" "$fake_template/tools/link-user-skill.sh"
printf '%s\n' '# real' >"$work/real-skill.md"
ln -s "$work/real-skill.md" "$fake_template/.agents/user-skills/linked-file/SKILL.md"
for name in empty-skill linked-file; do
  before=$(snapshot "$home")
  if HOME="$home" "$fake_template/tools/link-user-skill.sh" "$name" >"$work/$name.out" 2>&1; then
    fail "$name was linked without its own SKILL.md"
  fi
  grep -Fq "no user skill with a SKILL.md at $fake_template/.agents/user-skills/$name" "$work/$name.out" || { cat "$work/$name.out" >&2; fail "$name: unexpected message"; }
  [[ "$(snapshot "$home")" == "$before" ]] || fail "$name changed the fake HOME"
done

# The fake layout's own skill links to that checkout, not to this one.
mkdir -p "$fake_template/.agents/user-skills/fake-skill"
printf '%s\n' '# fake' >"$fake_template/.agents/user-skills/fake-skill/SKILL.md"
home="$work/layout-home"
mkdir "$home"
HOME="$home" "$fake_template/tools/link-user-skill.sh" fake-skill >"$work/layout.out" 2>&1 || { cat "$work/layout.out" >&2; fail 'the copied tool failed'; }
[[ "$(readlink "$home/.claude/skills/fake-skill")" == "$fake_template/.agents/user-skills/fake-skill" ]] || fail 'the link does not name the checkout of the tool'

echo "link-user-skill tests passed"
