#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
json_tool="$repo_root/tools/lib/workflow-json.rb"
usage() { echo 'usage: premerge-gate.sh --issue NUMBER --head-sha SHA' >&2; exit 2; }

issue='' head_sha=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) issue=${2:-}; shift 2 ;;
    --head-sha) head_sha=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$issue" =~ ^[1-9][0-9]*$ && "$head_sha" =~ ^[0-9a-f]{40}$ ]] || usage

fail() { echo "pre-merge gate failed: $*" >&2; exit 1; }
[[ -L "$repo_root/.artifacts" ]] || fail 'Issue worktree lacks the canonical .artifacts link'
primary_root=$(cd "$repo_root/../.." && pwd -P)
artifacts_root=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$repo_root/.artifacts") || fail 'canonical .artifacts link is broken'
[[ "$artifacts_root" == "$primary_root/.artifacts" && -d "$artifacts_root" ]] || fail 'canonical .artifacts link does not resolve to the primary checkout'
safe_file() {
  local path=$1
  [[ -f "$path" && ! -L "$path" ]] || fail "required canonical file is missing or unsafe: ${path#$repo_root/}"
  local resolved
  resolved=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$path") || fail 'cannot resolve canonical file'
  [[ "$resolved" == "$artifacts_root/"* ]] || fail 'canonical artifact escapes .artifacts'
}

contract="$repo_root/.artifacts/issues/$issue/issue-contract.json"
verify="$repo_root/.artifacts/issues/$issue/$head_sha/verify.json"
review="$repo_root/.artifacts/issues/$issue/$head_sha/review.json"
preflight="$repo_root/.artifacts/issues/$issue/github-preflight.json"
safe_file "$contract"
safe_file "$verify"
safe_file "$review"
safe_file "$preflight"

# The issue worktree is the authoritative local Head when durable state exists.
state="$repo_root/.artifacts/issues/$issue/state.json"
safe_file "$state"
worktree_relative=$(jq -er '.worktree | strings' "$state") || fail 'state worktree is invalid'
[[ "$worktree_relative" =~ ^\.worktrees/[0-9]+-[a-z0-9][a-z0-9-]*$ ]] || fail 'state worktree is noncanonical'
[[ "$repo_root" == "$primary_root/$worktree_relative" ]] || fail 'gate must run in the exact recorded Issue worktree'
[[ "$(git -C "$repo_root" rev-parse HEAD)" == "$head_sha" ]] || fail 'current Issue Head does not match --head-sha'

base_sha=$(jq -er '.baseSha | strings' "$verify") || fail 'verify.json baseSha is invalid'
[[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] || fail 'verify.json baseSha is invalid'
(cd "$repo_root" && swift tools/validate-verify-json.swift --file ".artifacts/issues/$issue/$head_sha/verify.json" --expected-issue "$issue" --expected-base "$base_sha" --expected-head "$head_sha") >/dev/null || fail 'verify.json does not satisfy the canonical verification contract'

contract_digest="sha256:$(shasum -a 256 "$contract" | awk '{print $1}')"
issue_json=$(gh issue view "$issue" --repo "$(jq -er '.repository | strings' "$contract")" --json body) || fail 'live Issue body could not be fetched'

# Reconstruct only the immutable contract fields from the live body. fetchedAt is
# deliberately excluded: it records the snapshot time, not Issue semantics.
CONTRACT="$contract" ISSUE_JSON="$issue_json" EXPECTED_ISSUE="$issue" ruby -rjson -e '
  def fail(message)
    abort("live Issue contract mismatch: #{message}")
  end
  snapshot = JSON.parse(File.binread(ENV.fetch("CONTRACT")))
  live = JSON.parse(ENV.fetch("ISSUE_JSON")).fetch("body")
  headings = []
  live.each_line.with_index(1) { |line, number| match = line.match(/\A#+\s+(.+?)\s*\z/); headings << [match[1], number] if match }
  section = lambda do |name|
    index = headings.index { |heading, _| heading == name } or fail("missing #{name}")
    start = headings[index][1]; stop = headings[(index + 1)..]&.first&.last || live.lines.length + 1
    live.lines[start...stop - 1].join.strip
  end
  criteria = section.call("Acceptance criteria").each_line.map { |line| match = line.match(/^\s*[-*]\s+(AC-(\d+))\s*:\s*(\S.*?)\s*$/); match && {"id" => match[1], "text" => match[3]} }.compact
  fail("criteria are not sequential") unless criteria.each_with_index.all? { |value, index| value["id"] == "AC-#{index + 1}" }
  anchors = section.call("Spec anchors").scan(/\[[^\]]+\]\(([^)]+)\)/).flatten.map { |value| value.strip.sub(/\A<|>\z/, "") }.uniq
  dependencies = section.call("Dependencies").match?(/\A\s*(?:[-*]\s*)?None\.?\s*\z/i) ? [] : section.call("Dependencies").scan(/#([1-9][0-9]*)/).flatten.map(&:to_i).uniq
  external = section.call("External operations").match?(/\A\s*(?:[-*]\s*)?None\.?\s*\z/i) ? [] : section.call("External operations").each_line.map { |line| line.strip.sub(/\A[-*]\s*/, "") }.reject(&:empty?).uniq
  expected = snapshot.slice("schemaVersion", "issue", "repository", "goal", "specAnchors", "acceptanceCriteria", "dependencies", "externalOperations")
  actual = {"schemaVersion" => 1, "issue" => Integer(ENV.fetch("EXPECTED_ISSUE")), "repository" => snapshot.fetch("repository"), "goal" => section.call("Goal"), "specAnchors" => anchors, "acceptanceCriteria" => criteria, "dependencies" => dependencies, "externalOperations" => external}
  fail("immutable fields changed") unless actual == expected
' || fail 'live Issue body differs from the canonical Issue contract'

# Consume the sealed Issue #8 provider-preflight schema exactly.  The contract
# permits at most one operation per provider because its canonical artifact is
# one provider.json, rather than a mutable collection.
CONTRACT="$contract" ARTIFACTS="$artifacts_root" ISSUE="$issue" ruby -rjson -rdigest -rtime -e '
  def die(message)
    abort("provider preflight validation failed: #{message}")
  end
  def canonical(value); value.is_a?(Hash) ? value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] } : value.is_a?(Array) ? value.map { |entry| canonical(entry) } : value; end
  contract = JSON.parse(File.binread(ENV.fetch("CONTRACT"))); issue = Integer(ENV.fetch("ISSUE")); root = ENV.fetch("ARTIFACTS")
  allowed = %w[github.read_issue github.create_issue github.update_issue github.push_branch github.create_pr github.merge_pr github.delete_branch github.sync_labels supabase.inspect_project supabase.apply_migrations cloudflare.inspect_account cloudflare.deploy elevenlabs.generate_audio appstore.inspect_app appstore.upload_build appstore.update_metadata appstore.submit_review]
  operations = contract.fetch("externalOperations")
  die("external operations") unless operations.is_a?(Array) && operations.uniq == operations && operations.all? { |value| allowed.include?(value) }
  map = {"supabase" => "supabase", "cloudflare" => "cloudflare", "elevenlabs" => "elevenlabs", "app-store" => "appstore"}
  map.each do |provider, prefix|
    matching = operations.select { |operation| operation.start_with?(prefix + ".") }
    next if matching.empty?
    die("multiple operations for #{provider}") unless matching.length == 1
    path = File.join(root, "issues", issue.to_s, "provider-preflights", "#{provider}.json")
    die("missing #{provider} preflight") unless File.file?(path) && !File.symlink?(path)
    value = JSON.parse(File.binread(path)); keys = %w[schemaVersion issue provider account target environment operation health checkedAt digest]
    die("#{provider} schema") unless value.is_a?(Hash) && value.keys.sort == keys.sort && value["schemaVersion"] == 1 && value["issue"] == issue && value["provider"] == provider && value["operation"] == matching.fetch(0) && value["health"] == "healthy"
    %w[account target environment operation].each { |key| die("#{provider} #{key}") unless value[key].is_a?(String) && value[key].match?(/\A[^\x00-\x1f\x7f]+\z/) }
    checked = Time.iso8601(value.fetch("checkedAt")); fetched = Time.iso8601(contract.fetch("fetchedAt")); die("#{provider} freshness") if checked < fetched || checked > Time.now.utc + 300
    unsigned = value.reject { |key, _| key == "digest" }; die("#{provider} digest") unless value["digest"] == "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(unsigned)))}"
  end
' || fail 'provider preflight is invalid'

VERIFY="$verify" REVIEW="$review" PREFLIGHT="$preflight" DIGEST="$contract_digest" ISSUE="$issue" HEAD="$head_sha" ROOT="$repo_root" ruby -rjson -rdigest -rtime -e '
  def die(message)
    abort("pre-merge evidence mismatch: #{message}")
  end
  def canonical(value)
    value.is_a?(Hash) ? value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] } : value.is_a?(Array) ? value.map { |entry| canonical(entry) } : value
  end
  verify = JSON.parse(File.binread(ENV.fetch("VERIFY")))
  review = JSON.parse(File.binread(ENV.fetch("REVIEW")))
  preflight = JSON.parse(File.binread(ENV.fetch("PREFLIGHT")))
  issue = Integer(ENV.fetch("ISSUE")); head = ENV.fetch("HEAD"); digest = ENV.fetch("DIGEST")
  die("verify identity") unless verify["issue"] == issue && verify["headSha"] == head && verify.dig("issueContract", "digest") == digest && %w[passed not-applicable].include?(verify["status"])
  evidence = verify["acceptanceEvidence"]
  ids = JSON.parse(File.binread(ENV.fetch("VERIFY").sub(%r{/[^/]+/verify\.json\z}, "/issue-contract.json")))["acceptanceCriteria"].map { |entry| entry.fetch("id") }
  die("acceptance evidence") unless evidence.is_a?(Array) && evidence.map { |entry| entry["id"] } == ids && evidence.all? { |entry| entry["status"] == "passed" && entry["evidence"].is_a?(Array) && !entry["evidence"].empty? }
  required_review = %w[schemaVersion issue reviewerModel baseSha headSha verifySha issueContractDigest verdict findings acceptanceAssessment reviewedAt]
  die("review schema") unless review.keys.sort == required_review.sort
  die("review identity") unless review["schemaVersion"] == 1 && review["issue"] == issue && review["headSha"] == head && review["verifySha"] == head && review["issueContractDigest"] == digest && review["verdict"] == "approved"
  die("review findings") unless review["findings"].is_a?(Array) && review["findings"].none? { |finding| %w[critical high medium].include?(finding["severity"]) }
  assessment = review["acceptanceAssessment"]
  die("review acceptance") unless assessment.is_a?(Array) && assessment.map { |entry| entry["id"] } == ids && assessment.all? { |entry| entry["status"] == "supported" && entry["evidence"].is_a?(Array) && !entry["evidence"].empty? }
  expected_preflight = %w[account repository defaultBranch url intendedOperation issue headSha checkedAt digest]
  die("preflight schema") unless preflight.keys.sort == expected_preflight.sort
  unsigned = preflight.reject { |key, _| key == "digest" }
  die("preflight digest") unless preflight["digest"] == "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(unsigned)))}"
  die("preflight identity") unless preflight["intendedOperation"] == "github.merge_pr" && preflight["issue"] == issue && preflight["headSha"] == head
  checked = Time.iso8601(preflight.fetch("checkedAt")); completed = Time.iso8601(verify.fetch("completedAt")); reviewed = Time.iso8601(review.fetch("reviewedAt"))
  die("preflight freshness") unless checked > completed && checked > reviewed
' || fail 'verification, review, or merge preflight is invalid'

jq -cn --argjson issue "$issue" --arg headSha "$head_sha" --arg digest "$contract_digest" '{status:"passed",issue:$issue,headSha:$headSha,issueContractDigest:$digest}'
