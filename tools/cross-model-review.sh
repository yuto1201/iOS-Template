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
topology=$(ruby "$repo_root/tools/lib/review-artifacts.rb" "$repo_root") || exit 1
artifacts_root=$(jq -er '.artifactsRoot' <<<"$topology")
artifact_issue_root="$artifacts_root/issues/$issue"
repository=$(jq -er '.issueContractRepository' <<<"$packet_json")
expected_output=".artifacts/issues/$issue/$head_sha/review.json"
[[ "$output" == "$expected_output" ]] || { echo 'review output must be canonical Issue/Head review.json' >&2; exit 1; }
output_absolute="$artifact_issue_root/$head_sha/review.json"
packet_absolute="$artifact_issue_root/$head_sha/review-packet.json"
git -C "$repo_root" cat-file -e "$head_sha^{commit}" && git -C "$repo_root" merge-base --is-ancestor "$base_sha" "$head_sha" || { echo 'packet Base/Head is not a valid commit range' >&2; exit 1; }
[[ "$(git -C "$repo_root" rev-parse HEAD)" == "$head_sha" ]] || { echo 'current Head does not match the review packet' >&2; exit 1; }

review_workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-cross-review.XXXXXX")
review_workspace=$(cd "$review_workspace" && pwd -P)
chmod 700 "$review_workspace"
snapshot_before="$review_workspace/snapshot-before"
snapshot_after="$review_workspace/snapshot-after"
raw_output="$review_workspace/raw-output"
normalized_output="$review_workspace/normalized-output"
validated="$review_workspace/validated"
trap 'rm -rf "$review_workspace"' EXIT

complete_existing_review() {
  [[ -f "$output_absolute" && ! -L "$output_absolute" ]] || { echo 'existing review output is not a regular file' >&2; exit 1; }
  [[ -f "$artifact_issue_root/$head_sha/review-receipt.json" && ! -L "$artifact_issue_root/$head_sha/review-receipt.json" ]] || { echo 'existing review lacks an exact opposite-model execution receipt' >&2; exit 1; }
  "$repo_root/tools/validate-review-result.sh" --primary "$primary" --packet "$packet" --result "$output_absolute" > "$validated"
  ruby "$repo_root/tools/lib/validate-review-receipt.rb" "$repo_root" "$primary" "$issue" "$head_sha" >/dev/null
  local verdict next_state state_json current_state
  verdict=$(jq -er '.verdict' "$validated")
  next_state=$([[ "$verdict" == approved ]] && echo approved-for-merge || echo changes-requested)
  state_json=$("$repo_root/tools/issue-state.sh" get --repo "$repository" --issue "$issue")
  current_state=$(jq -er '.state' <<<"$state_json")
  case "$current_state" in
    review-requested)
      "$repo_root/tools/issue-state.sh" transition --repo "$repository" --issue "$issue" --from review-requested --to "$next_state" >/dev/null
      ;;
    "$next_state")
      ;;
    *)
      echo "existing valid review cannot transition Issue from state:$current_state" >&2
      exit 1
      ;;
  esac
  cat "$validated"
  printf '\n'
  exit 0
}

if [[ -e "$output_absolute" || -L "$output_absolute" || -e "$artifact_issue_root/$head_sha/review-receipt.json" || -L "$artifact_issue_root/$head_sha/review-receipt.json" ]]; then
  complete_existing_review
fi

snapshot_repository() {
  ruby -rdigest -rfind - "$repo_root" "$artifact_issue_root" <<'RUBY'
repository = File.realpath(ARGV.fetch(0))
artifact_issue = File.realpath(ARGV.fetch(1))
[[repository, "repository"], [artifact_issue, "artifacts"]].each do |root, label|
  Find.find(root) do |path|
    relative = path.delete_prefix(root + "/")
    if label == "repository" && (relative == ".git" || relative.start_with?(".git/") || relative == ".artifacts" || relative.start_with?(".artifacts/"))
      Find.prune if File.directory?(path)
      next
    end
    next if path == root
    stat = File.lstat(path)
    if stat.directory?
      puts "#{label}:d\t#{relative}\t#{stat.mode & 0o7777}"
    elsif stat.file?
      puts "#{label}:f\t#{relative}\t#{stat.mode & 0o7777}\t#{stat.size}\t#{Digest::SHA256.file(path).hexdigest}"
    elsif stat.symlink?
      puts "#{label}:l\t#{relative}\t#{File.readlink(path)}"
    else
      puts "#{label}:o\t#{relative}\t#{stat.ftype}"
    end
  end
end
RUBY
}

snapshot_repository > "$snapshot_before"
review_status=0
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ "$primary" == codex ]]; then
  instruction='You are the opposite-model acceptance auditor. Read only the supplied local review packet and files it references. Do not edit files, run tests, operate simulators, commit, push, use network services, authentication, or external tools. Return only one JSON object conforming exactly to docs/agent-contracts/review-packet.md Result schema, including the exact reviewPacketDigest from the schema v2 packet bytes.'
  if ruby -rtimeout -e '
    command = ARGV
    timeout_seconds = Integer(ENV.fetch("IOS_TEMPLATE_REVIEW_TIMEOUT_SECONDS", "600"), 10)
    term_grace = Integer(ENV.fetch("IOS_TEMPLATE_REVIEW_TERM_GRACE_SECONDS", "5"), 10)
    exit 2 unless (1..600).cover?(timeout_seconds) && (1..5).cover?(term_grace)
    pid = nil
    child_reaped = false
    signal_group = lambda do |signal|
      next if pid.nil?
      begin
        Process.kill(signal, -pid)
      rescue Errno::ESRCH
        nil
      end
    end
    group_alive = lambda do
      next false if pid.nil?
      begin
        Process.kill(0, -pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        # macOS may report EPERM for kill(0, -pgid) after the process-group
        # leader has been reaped and no signalable member remains.
        false
      end
    end
    reap_child = lambda do
      next if pid.nil? || child_reaped
      begin
        child_reaped = !Process.waitpid(pid, Process::WNOHANG).nil?
      rescue Errno::ECHILD
        child_reaped = true
      end
    end
    terminate_group = lambda do |signal|
      next if pid.nil?
      signal_group.call(signal)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + term_grace
      while group_alive.call && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        reap_child.call
        sleep 0.05
      end
      if group_alive.call
        signal_group.call("KILL")
        kill_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
        while group_alive.call && Process.clock_gettime(Process::CLOCK_MONOTONIC) < kill_deadline
          reap_child.call
          sleep 0.05
        end
      end
      unless child_reaped
        begin
          Process.wait(pid)
        rescue Errno::ECHILD
          nil
        ensure
          child_reaped = true
        end
      end
    end
    %w[INT TERM HUP].each do |signal|
      Signal.trap(signal) do
        terminate_group.call(signal)
        exit(128 + Signal.list.fetch(signal))
      end
    end
    # A dedicated process group lets timeout and interrupt cleanup reach all
    # reviewer descendants. Traps are installed before this publication point.
    pid = Process.spawn(*command, in: File::NULL, pgroup: true)
    begin
      Timeout.timeout(timeout_seconds) { Process.wait(pid) }
    rescue Timeout::Error
      terminate_group.call("TERM")
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
completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
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
    echo "opposite-model reviewer failed with status:$review_status; no review was published" >&2
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

publication_packet=$("$repo_root/tools/validate-review-result.sh" --primary "$primary" --packet "$packet")
[[ $(jq -er '.issue' <<<"$publication_packet") == "$issue" && $(jq -er '.headSha' <<<"$publication_packet") == "$head_sha" ]] || { echo 'review packet identity changed before publication' >&2; exit 1; }
publication=$("$repo_root/tools/lib/publish-review-result.rb" "$repo_root" "$issue" "$head_sha" "$validated" "$packet_absolute" "$primary" "$started_at" "$completed_at")
[[ $(jq -er '.path' <<<"$publication") == "$output_absolute" ]] || { echo 'review publication returned an unexpected path' >&2; exit 1; }
[[ $(jq -er '.receiptPath' <<<"$publication") == "$artifact_issue_root/$head_sha/review-receipt.json" ]] || { echo 'review publication returned an unexpected receipt path' >&2; exit 1; }
"$repo_root/tools/validate-review-result.sh" --primary "$primary" --packet "$packet" --result "$output_absolute" > "$validated"
ruby "$repo_root/tools/lib/validate-review-receipt.rb" "$repo_root" "$primary" "$issue" "$head_sha" >/dev/null
verdict=$(jq -er '.verdict' "$validated")
next_state=$([[ "$verdict" == approved ]] && echo approved-for-merge || echo changes-requested)
"$repo_root/tools/issue-state.sh" transition --repo "$repository" --issue "$issue" --from review-requested --to "$next_state" >/dev/null
cat "$validated"
printf '\n'
