#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
usage() { echo 'usage: render-pr-body.sh --issue NUMBER --head-sha SHA' >&2; exit 2; }
issue='' head_sha=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) issue=${2:-}; shift 2 ;;
    --head-sha) head_sha=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$issue" =~ ^[1-9][0-9]*$ && "$head_sha" =~ ^[0-9a-f]{40}$ ]] || usage
[[ -L "$repo_root/.artifacts" ]] || { echo 'Issue worktree lacks the canonical .artifacts link' >&2; exit 1; }
primary_root=$(cd "$repo_root/../.." && pwd -P)
artifacts_root=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$repo_root/.artifacts") || { echo 'canonical .artifacts link is broken' >&2; exit 1; }
[[ "$artifacts_root" == "$primary_root/.artifacts" ]] || { echo 'canonical .artifacts link does not resolve to the primary checkout' >&2; exit 1; }

contract="$repo_root/.artifacts/issues/$issue/issue-contract.json"
verify="$repo_root/.artifacts/issues/$issue/$head_sha/verify.json"
review="$repo_root/.artifacts/issues/$issue/$head_sha/review.json"
for file in "$contract" "$verify" "$review"; do [[ -f "$file" && ! -L "$file" ]] || { echo "missing canonical artifact: $file" >&2; exit 1; }; done

CONTRACT="$contract" VERIFY="$verify" REVIEW="$review" ISSUE="$issue" HEAD="$head_sha" ruby -rjson -rdigest -e '
  contract = JSON.parse(File.binread(ENV.fetch("CONTRACT"))); verify = JSON.parse(File.binread(ENV.fetch("VERIFY"))); review = JSON.parse(File.binread(ENV.fetch("REVIEW")))
  issue = Integer(ENV.fetch("ISSUE")); head = ENV.fetch("HEAD"); digest = "sha256:#{Digest::SHA256.hexdigest(File.binread(ENV.fetch("CONTRACT")))}"
  abort "artifact identity mismatch" unless contract["issue"] == issue && verify["headSha"] == head && review["headSha"] == head && review["verifySha"] == head && verify.dig("issueContract", "digest") == digest && review["issueContractDigest"] == digest
  puts "## Summary\n\nCloses ##{issue}.\n\n## Specification\n\n- Issue contract digest: `#{digest}`\n- Head SHA: `#{head}`\n\n## Verification\n\n- verify.json status: `#{verify["status"]}`\n- Matrix: `#{verify["matrixFile"] || "not-applicable"}`\n- Matrix digest: `#{verify["matrixDigest"] || "not-applicable"}`\n"
  contract.fetch("acceptanceCriteria").each do |criterion|
    evidence = verify.fetch("acceptanceEvidence").find { |entry| entry["id"] == criterion["id"] }
    abort "missing acceptance evidence" unless evidence
    puts "- #{criterion["id"]}: #{evidence.fetch("status")} — #{evidence.fetch("evidence").join(", ")}"
  end
  blocking = review.fetch("findings").count { |finding| %w[critical high medium].include?(finding["severity"]) }
  puts "\n## Opposite-model review\n\n- Verdict: `#{review["verdict"]}`\n- Review Head SHA: `#{review["headSha"]}`\n- Blocking findings: #{blocking}\n\n## Remaining work\n"
  if %w[passed not-applicable].include?(verify["status"]) && review["verdict"] == "approved" && blocking.zero?
    puts "\n- Pre-merge gate is pending.\n"
  else
    puts "\n- Verification or opposite-model review is not merge-ready.\n"
  end
'
