#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
usage() { echo 'usage: cross-model-review.sh --primary codex|claude --packet .artifacts/issues/ISSUE/HEAD/PACKET.json --output .artifacts/issues/ISSUE/HEAD/review.json' >&2; exit 2; }
primary='' packet='' output=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --primary) [[ -z "$primary" && $# -ge 2 ]] || usage; primary=$2; shift 2 ;;
    --packet) [[ -z "$packet" && $# -ge 2 ]] || usage; packet=$2; shift 2 ;;
    --output) [[ -z "$output" && $# -ge 2 ]] || usage; output=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ ( "$primary" == codex || "$primary" == claude ) && -n "$packet" && -n "$output" ]] || usage

packet_json=$("$repo_root/tools/validate-review-result.sh" --primary "$primary" --packet "$packet")
issue=$(jq -er '.issue' <<<"$packet_json")
head_sha=$(jq -er '.headSha' <<<"$packet_json")
base_sha=$(jq -er '.baseSha' <<<"$packet_json")
repository=$(jq -er '.issueContractRepository // empty' <<<"$packet_json" 2>/dev/null || true)
if [[ -z "$repository" ]]; then
  contract_path=$(jq -er '.issueContract.path' <<<"$packet_json")
  repository=$(jq -er '.repository' "$repo_root/$contract_path")
fi
expected_output=".artifacts/issues/$issue/$head_sha/review.json"
[[ "$output" == "$expected_output" ]] || { echo 'review output must be canonical Issue/Head review.json' >&2; exit 1; }
output_absolute="$repo_root/$output"
[[ ! -e "$output_absolute" && ! -L "$output_absolute" ]] || { echo 'review output already exists' >&2; exit 1; }
git -C "$repo_root" cat-file -e "$head_sha^{commit}" && git -C "$repo_root" merge-base --is-ancestor "$base_sha" "$head_sha" || { echo 'packet Base/Head is not a valid commit range' >&2; exit 1; }
[[ "$(git -C "$repo_root" rev-parse HEAD)" == "$head_sha" ]] || { echo 'current Head does not match the review packet' >&2; exit 1; }

snapshot_before=$(mktemp "${TMPDIR:-/tmp}/ios-template-review-before.XXXXXX")
snapshot_after=$(mktemp "${TMPDIR:-/tmp}/ios-template-review-after.XXXXXX")
raw_output=$(mktemp "${TMPDIR:-/tmp}/ios-template-review-output.XXXXXX")
normalized_output=$(mktemp "${TMPDIR:-/tmp}/ios-template-review-normalized.XXXXXX")
validated=$(mktemp "${TMPDIR:-/tmp}/ios-template-review-validated.XXXXXX")
trap 'rm -f "$snapshot_before" "$snapshot_after" "$raw_output" "$normalized_output" "$validated"' EXIT

snapshot_repository() {
  ruby -rdigest -rfind - "$repo_root" <<'RUBY'
root = File.realpath(ARGV.fetch(0))
Find.find(root) do |path|
  relative = path.delete_prefix(root + "/")
  if relative == ".git" || relative.start_with?(".git/")
    Find.prune if File.directory?(path)
    next
  end
  next if path == root
  stat = File.lstat(path)
  if stat.directory?
    puts "d\t#{relative}\t#{stat.mode & 0o7777}"
  elsif stat.file?
    puts "f\t#{relative}\t#{stat.mode & 0o7777}\t#{stat.size}\t#{Digest::SHA256.file(path).hexdigest}"
  elsif stat.symlink?
    puts "l\t#{relative}\t#{File.readlink(path)}"
  else
    puts "o\t#{relative}\t#{stat.ftype}"
  end
end
RUBY
}

snapshot_repository > "$snapshot_before"
review_status=0
if [[ "$primary" == codex ]]; then
  instruction='You are the opposite-model acceptance auditor. Read only the supplied local review packet and files it references. Do not edit files, run tests, operate simulators, commit, push, use network services, authentication, or external tools. Return only one JSON object conforming exactly to docs/agent-contracts/review-packet.md Result schema.'
  packet_absolute="$repo_root/$packet"
  if ruby -rtimeout -e '
    command = ARGV
    pid = Process.spawn(*command, in: File::NULL)
    begin
      Timeout.timeout(600) { Process.wait(pid) }
    rescue Timeout::Error
      Process.kill("TERM", pid) rescue nil
      begin; Timeout.timeout(5) { Process.wait(pid) }; rescue Timeout::Error; Process.kill("KILL", pid) rescue nil; Process.wait(pid) rescue nil; end
      exit 124
    end
    exit($?.exitstatus || 1)
  ' claude --print --output-format json --no-session-persistence --allowedTools Read --allowedTools Glob --allowedTools Grep "$instruction
Validated review packet: $packet_absolute" </dev/null > "$raw_output"; then
    :
  else
    review_status=$?
  fi
else
  if "$repo_root/tools/request-codex-review.sh" --packet "$packet" --output "$output" > "$raw_output"; then
    :
  else
    review_status=$?
  fi
fi
snapshot_repository > "$snapshot_after"
if ! cmp -s "$snapshot_before" "$snapshot_after"; then
  echo 'reviewer attempted to write inside the repository; review was rejected' >&2
  rm -f "$output_absolute"
  exit 1
fi
if [[ "$review_status" -ne 0 ]]; then
  if [[ "$review_status" -eq 124 ]]; then
    "$repo_root/tools/issue-state.sh" transition --repo "$repository" --issue "$issue" --from review-requested --to blocked:review >/dev/null
    echo 'opposite-model review timed out; moved to blocked:review' >&2
  else
    echo 'opposite-model reviewer failed; no review was published' >&2
  fi
  exit "$review_status"
fi
[[ "$(git -C "$repo_root" rev-parse HEAD)" == "$head_sha" ]] || { echo 'Head changed during review; no review was published' >&2; exit 1; }
ruby -rjson - "$raw_output" "$normalized_output" <<'RUBY'
raw, normalized = ARGV
value = JSON.parse(File.binread(raw))
if value.is_a?(Hash) && value["result"].is_a?(String) && !value.key?("schemaVersion")
  value = JSON.parse(value.fetch("result"))
end
File.binwrite(normalized, JSON.generate(value))
RUBY
"$repo_root/tools/validate-review-result.sh" --primary "$primary" --packet "$packet" --result "$normalized_output" > "$validated"

mkdir -p "$(dirname "$output_absolute")"
ruby - "$output_absolute" "$validated" <<'RUBY'
output, source = ARGV
data = File.binread(source)
begin
  file = File.open(output, File::WRONLY | File::CREAT | File::EXCL, 0o600)
  file.write(data)
  file.flush
  file.fsync
  file.close
rescue Errno::EEXIST
  warn "review output already exists"
  exit 1
end
RUBY
verdict=$(jq -er '.verdict' "$validated")
next_state=$([[ "$verdict" == approved ]] && echo approved-for-merge || echo changes-requested)
"$repo_root/tools/issue-state.sh" transition --repo "$repository" --issue "$issue" --from review-requested --to "$next_state" >/dev/null
cat "$validated"
printf '\n'
