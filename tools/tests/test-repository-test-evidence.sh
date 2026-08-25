#!/usr/bin/env bash
set -euo pipefail

source_repo=$(cd "$(dirname "$0")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-repository-evidence.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
repo="$scratch/repo"

git init -q -b main "$repo"
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
mkdir -p "$repo/tools/lib" "$repo/tools/tests" "$repo/.artifacts/issues/42"
cp "$source_repo/tools/run-repository-tests.sh" "$repo/tools/"
cp "$source_repo/tools/lib/run-repository-tests.rb" \
  "$source_repo/tools/lib/review-artifacts.rb" \
  "$source_repo/tools/lib/review-contract.rb" \
  "$source_repo/tools/lib/review-sealing.rb" \
  "$source_repo/tools/lib/prepare-review-packet.rb" \
  "$repo/tools/lib/"
cp "$source_repo/tools/prepare-review-packet.sh" "$repo/tools/"
cp "$source_repo/tools/validate-review-result.sh" "$repo/tools/"
chmod +x "$repo/tools/run-repository-tests.sh" "$repo/tools/prepare-review-packet.sh" "$repo/tools/validate-review-result.sh"

cat > "$repo/.gitignore" <<'EOF'
/.artifacts
EOF
cat > "$repo/README.md" <<'EOF'
base
EOF
git -C "$repo" add .gitignore README.md
git -C "$repo" commit -q -m base
base_sha=$(git -C "$repo" rev-parse HEAD)

cat > "$repo/tools/tests/test-alpha.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'sensitive-test-output-must-not-be-published'
EOF
cat > "$repo/tools/tests/test-beta.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${FAIL_BETA:-0}" == 0 ]]
printf '%s\n' 'beta passed'
EOF
chmod +x "$repo/tools/tests/test-alpha.sh" "$repo/tools/tests/test-beta.sh"
git -C "$repo" add tools
git -C "$repo" commit -q -m head
head_sha=$(git -C "$repo" rev-parse HEAD)

contract="$repo/.artifacts/issues/42/issue-contract.json"
head_dir="$repo/.artifacts/issues/42/$head_sha"
mkdir -p "$head_dir"
cat > "$contract" <<JSON
{"schemaVersion":1,"issue":42,"repository":"example/repo","goal":"Evidence","specAnchors":["specs/test.md#evidence"],"acceptanceCriteria":[{"id":"AC-1","text":"Alpha passes"},{"id":"AC-2","text":"Beta passes"}],"dependencies":[],"externalOperations":[],"externalOperationDetailsDigest":"sha256:$(printf '0%.0s' {1..64})","fetchedAt":"2026-08-25T00:00:00Z"}
JSON

output=$(cd "$repo" && tools/run-repository-tests.sh \
  --issue 42 --expected-base "$base_sha" \
  --map AC-1=tools/tests/test-alpha.sh \
  --map AC-2=tools/tests/test-beta.sh)
evidence="$head_dir/repository-tests.json"
[[ -f "$evidence" && ! -L "$evidence" ]] || { echo 'repository test evidence was not published' >&2; exit 1; }
[[ $(stat -f '%Lp' "$evidence") == 600 ]] || { echo 'repository test evidence permissions differ' >&2; exit 1; }
grep -Fq 'sensitive-test-output-must-not-be-published' "$evidence" && { echo 'test output leaked into evidence' >&2; exit 1; }

EVIDENCE="$evidence" BASE="$base_sha" HEAD="$head_sha" OUTPUT="$output" ruby -rjson -e '
  value = JSON.parse(File.binread(ENV.fetch("EVIDENCE")))
  abort "wrong evidence keys" unless value.keys.sort == %w[acceptanceEvidence baseSha completedAt headSha issue issueContract runnerFiles schemaVersion startedAt status suite tests].sort
  abort "wrong identity" unless value.values_at("schemaVersion", "status", "issue", "baseSha", "headSha") == [1, "passed", 42, ENV.fetch("BASE"), ENV.fetch("HEAD")]
  abort "wrong suite totals" unless value.fetch("suite") == {"path"=>"tools/tests","pattern"=>"test-*.sh","total"=>2,"passed"=>2,"failed"=>0}
  abort "wrong test order" unless value.fetch("tests").map { |item| item.fetch("path") } == %w[tools/tests/test-alpha.sh tools/tests/test-beta.sh]
  abort "test arguments differ" unless value.fetch("tests").all? { |item| item.fetch("arguments") == [] }
  abort "test did not pass" unless value.fetch("tests").all? { |item| item.fetch("status") == "passed" && item.fetch("exitStatus") == 0 && item.fetch("outputDigest").match?(/\Asha256:[0-9a-f]{64}\z/) }
  abort "wrong AC map" unless value.fetch("acceptanceEvidence") == [
    {"id"=>"AC-1","status"=>"passed","tests"=>["tools/tests/test-alpha.sh"]},
    {"id"=>"AC-2","status"=>"passed","tests"=>["tools/tests/test-beta.sh"]}
  ]
  receipt = JSON.parse(ENV.fetch("OUTPUT"))
  abort "wrong receipt" unless receipt.fetch("path") == ".artifacts/issues/42/#{ENV.fetch("HEAD")}/repository-tests.json" && receipt.fetch("digest").match?(/\Asha256:[0-9a-f]{64}\z/) && receipt.values_at("total", "passed", "failed") == [2, 2, 0]
'

contract_digest="sha256:$(shasum -a 256 "$contract" | awk '{print $1}')"
cat > "$head_dir/verify.json" <<JSON
{"schemaVersion":1,"status":"not-applicable","issue":42,"baseSha":"$base_sha","headSha":"$head_sha","issueContract":{"path":".artifacts/issues/42/issue-contract.json","digest":"$contract_digest"},"visualEvaluation":{"status":"not-applicable","findings":[]},"acceptanceEvidence":[{"id":"AC-1","status":"passed","evidence":["documents:alpha"]},{"id":"AC-2","status":"passed","evidence":["documents:beta"]}],"completedAt":"2026-08-25T00:02:00Z"}
JSON
(cd "$repo" && tools/prepare-review-packet.sh --primary codex --issue 42 --base-sha "$base_sha" --head-sha "$head_sha") >/dev/null
PACKET="$head_dir/review-packet.json" EVIDENCE="$evidence" ruby -rjson -e '
  packet = JSON.parse(File.binread(ENV.fetch("PACKET")))
  evidence = JSON.parse(File.binread(ENV.fetch("EVIDENCE")))
  abort "packet did not seal repository tests" unless packet.fetch("repositoryTests") == evidence
'
validated_packet=$(cd "$repo" && tools/validate-review-result.sh \
  --primary codex \
  --packet ".artifacts/issues/42/$head_sha/review-packet.json")
jq -e '.repositoryTests.status == "passed" and .repositoryTests.suite.total == 2' \
  <<<"$validated_packet" >/dev/null
if PACKET="$head_dir/review-packet.json" CONTRACT="$contract" ruby -I "$repo/tools/lib" -rjson -rreview-contract -e '
  packet = JSON.parse(File.binread(ENV.fetch("PACKET")))
  contract = JSON.parse(File.binread(ENV.fetch("CONTRACT")))
  packet.fetch("repositoryTests").fetch("suite")["total"] = 99
  IOSTemplate::ReviewContract.validate_repository_tests!(
    packet.fetch("repositoryTests"),
    issue: 42, base_sha: packet.fetch("baseSha"), head_sha: packet.fetch("headSha"),
    contract_digest: IOSTemplate::ReviewContract.digest(File.binread(ENV.fetch("CONTRACT"))),
    criteria: contract.fetch("acceptanceCriteria")
  )
' >"$scratch/tamper.out" 2>"$scratch/tamper.err"; then
  echo 'tampered repository suite totals were accepted' >&2
  exit 1
fi
grep -Fq 'repositoryTests suite totals differ' "$scratch/tamper.err"

if (cd "$repo" && tools/run-repository-tests.sh --issue 42 --expected-base "$base_sha" --map AC-1=tools/tests/test-alpha.sh --map AC-2=tools/tests/test-beta.sh) >"$scratch/collision.out" 2>"$scratch/collision.err"; then
  echo 'existing canonical evidence was overwritten' >&2
  exit 1
fi
grep -Fq 'canonical repository-tests.json already exists' "$scratch/collision.err"

cat > "$repo/tools/tests/test-beta.sh" <<'EOF'
#!/usr/bin/env bash
exit 3
EOF
git -C "$repo" add tools/tests/test-beta.sh
git -C "$repo" commit -q -m failing-head
failed_head=$(git -C "$repo" rev-parse HEAD)
mkdir -p "$repo/.artifacts/issues/43/$failed_head"
sed 's/"issue":42/"issue":43/; s/"AC-2","text":"Beta passes"/"AC-2","text":"Beta passes"/' "$contract" > "$repo/.artifacts/issues/43/issue-contract.json"
if (cd "$repo" && tools/run-repository-tests.sh --issue 43 --expected-base "$base_sha" --map AC-1=tools/tests/test-alpha.sh --map AC-2=tools/tests/test-beta.sh) >"$scratch/fail.out" 2>"$scratch/fail.err"; then
  echo 'failing repository suite was accepted' >&2
  exit 1
fi
[[ ! -e "$repo/.artifacts/issues/43/$failed_head/repository-tests.json" ]] || { echo 'failed suite published canonical evidence' >&2; exit 1; }
grep -Fq 'repository test failed: tools/tests/test-beta.sh' "$scratch/fail.err"

mkdir -p "$repo/.artifacts/issues/44/$failed_head"
sed 's/"issue":42/"issue":44/' "$contract" > "$repo/.artifacts/issues/44/issue-contract.json"
if (cd "$repo" && tools/run-repository-tests.sh --issue 44 --expected-base "$base_sha" --map AC-1=tools/tests/test-alpha.sh) >"$scratch/missing.out" 2>"$scratch/missing.err"; then
  echo 'incomplete acceptance map was accepted' >&2
  exit 1
fi
grep -Fq 'acceptance mappings must match every Issue contract AC exactly once' "$scratch/missing.err"

echo 'PASS: current-Head repository tests are isolated, sanitized, AC-mapped, and sealed into the review packet'
