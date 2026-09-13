#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" jq git ruby

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
  "$source_repo/tools/lib/verification-scope.rb" \
  "$source_repo/tools/lib/delivery-stage.rb" \
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
cat > "$repo/tools/tests/test-unmapped.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo 'an unmapped repository test must not run' >&2
exit 9
EOF
chmod +x "$repo/tools/tests/test-alpha.sh" "$repo/tools/tests/test-beta.sh" "$repo/tools/tests/test-unmapped.sh"
git -C "$repo" add tools
git -C "$repo" commit -q -m head
head_sha=$(git -C "$repo" rev-parse HEAD)

contract="$repo/.artifacts/issues/42/issue-contract.json"
head_dir="$repo/.artifacts/issues/42/$head_sha"
mkdir -p "$head_dir"
cat > "$contract" <<JSON
{"schemaVersion":1,"issue":42,"repository":"example/repo","goal":"Evidence","specAnchors":["specs/test.md#evidence"],"acceptanceCriteria":[{"id":"AC-1","text":"Alpha passes"},{"id":"AC-2","text":"Beta passes"}],"dependencies":[],"externalOperations":[],"externalOperationDetailsDigest":"sha256:$(printf '0%.0s' {1..64})","fetchedAt":"2026-08-25T00:00:00Z","deliveryStage":{"name":"harden","timeBudgetMinutes":60,"reason":"Workflow-only fixture."},"deliveryProfile":{"name":"strict","reason":"Canonical workflow evidence."}}
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

# A non-workflow Head-only contract retains the legacy full tracked inventory;
# an AC mapping is not a general-purpose exclusion list.
cat > "$repo/tools/tests/test-beta.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'beta restored'
EOF
git -C "$repo" add tools/tests/test-beta.sh
git -C "$repo" commit -q -m legacy-head
legacy_head=$(git -C "$repo" rev-parse HEAD)
mkdir -p "$repo/.artifacts/issues/45/$legacy_head"
CONTRACT="$contract" OUTPUT="$repo/.artifacts/issues/45/issue-contract.json" ruby -rjson -e '
  value=JSON.parse(File.binread(ENV.fetch("CONTRACT")))
  value["issue"]=45
  value.delete("deliveryStage")
  value.delete("deliveryProfile")
  File.binwrite(ENV.fetch("OUTPUT"),JSON.generate(value))
'
if (cd "$repo" && tools/run-repository-tests.sh --issue 45 --expected-base "$base_sha" --map AC-1=tools/tests/test-alpha.sh --map AC-2=tools/tests/test-beta.sh) >"$scratch/legacy.out" 2>"$scratch/legacy.err"; then
  echo 'legacy Head-only contract silently excluded an unmapped test' >&2
  exit 1
fi
grep -Fq 'repository test failed: tools/tests/test-unmapped.sh' "$scratch/legacy.err"

ruby -I"$source_repo/tools/lib" -rrun-repository-tests -e '
  unrelated = Process.spawn("/bin/sleep", "30", pgroup: true)
  begin
    _, _, status, timed_out, elapsed = IOSTemplate::RepositoryTests.capture3_bounded(
      {}, "/bin/bash", "-c", "/bin/sleep 30 & wait", chdir: Dir.pwd, timeout_seconds: 1
    )
    abort "repository child was not timed out" unless timed_out && elapsed < 8 && !status.success?
    Process.kill(0, unrelated)
  ensure
    begin Process.kill("TERM", -unrelated); rescue Errno::ESRCH; end
    begin Process.wait(unrelated); rescue Errno::ECHILD; end
  end
'

echo 'PASS: current-Head repository tests are isolated, sanitized, AC-mapped, and sealed into the review packet'

# The older revision intentionally has neither the future runner nor the Head
# inventory. Only the current producer may orchestrate both clean revisions.
ruby -I"$source_repo/tools/lib" -rrun-repository-tests -rprepare-review-packet - "$source_repo" <<'RUBY'
# encoding: UTF-8
source = ARGV.fetch(0)
runner = IOSTemplate::RepositoryTests
review = IOSTemplate::ReviewContract
Dir.mktmpdir("repository-two-revisions-") do |scratch|
  scratch = File.realpath(scratch)
  repo = File.join(scratch, "repo")
  FileUtils.mkdir_p(File.join(repo, "tools/tests"))
  git = ->(*args) { runner.git!(repo, *args).strip }
  git.call("init", "-q", "-b", "main")
  git.call("config", "user.name", "Fixture")
  git.call("config", "user.email", "fixture@example.invalid")
  File.write(File.join(repo, ".gitignore"), "/.artifacts\n")
  File.write(File.join(repo, "tools/tests/test-alpha.sh"), "test -f tools/tests/test-baseline.sh || test -f tools/tests/test-beta.sh\n")
  File.write(File.join(repo, "tools/tests/test-baseline.sh"), "test ! -e tools/run-repository-tests.sh\ncase \"${BASE_CASE:-pass}\" in fail) exit 7;; timeout) sleep 10;; esac\n")
  git.call("add", ".")
  git.call("commit", "-qm", "older source and baseline-only inventory")
  base = git.call("rev-parse", "HEAD")
  FileUtils.mkdir_p(File.join(repo, "tools/lib"))
  %w[run-repository-tests.sh prepare-review-packet.sh validate-review-result.sh cross-model-review.sh].each do |name|
    FileUtils.cp(File.join(source, "tools", name), File.join(repo, "tools", name))
  end
  Dir[File.join(source, "tools/lib/*.rb")].each { |file| FileUtils.cp(file, File.join(repo, "tools/lib")) }
  File.unlink(File.join(repo, "tools/tests/test-baseline.sh"))
  File.write(File.join(repo, "tools/tests/test-beta.sh"), "test -f tools/run-repository-tests.sh\n")
  git.call("add", ".")
  git.call("commit", "-qm", "current producer and different Head inventory")
  head = git.call("rev-parse", "HEAD")
  directory = File.join(repo, ".artifacts/issues/42", head)
  FileUtils.mkdir_p(directory)
  criteria = [{"id" => "AC-1", "text" => "現在Headの機能"},
              {"id" => "AC-2", "text" => "Repository-test scope: base-and-head; Full baseline and Head regression"}]
  contract = {"schemaVersion"=>1, "issue"=>42, "repository"=>"example/repo", "goal"=>"Two revisions",
              "specAnchors"=>["specs/test.md#evidence"], "acceptanceCriteria"=>criteria,
              "dependencies"=>[], "externalOperations"=>[], "externalOperationDetailsDigest"=>"sha256:#{'0' * 64}",
              "fetchedAt"=>"2026-08-25T00:00:00Z"}
  contract_bytes = JSON.generate(contract)
  File.write(File.join(repo, ".artifacts/issues/42/issue-contract.json"), contract_bytes)
  mappings = {"AC-1"=>["tools/tests/test-beta.sh"], "AC-2"=>["tools/tests/test-alpha.sh", "tools/tests/test-beta.sh"]}
  base_mappings = {"AC-2"=>["tools/tests/test-alpha.sh", "tools/tests/test-baseline.sh"]}
  result = runner.run(repo: repo, issue: 42, expected_base: base, mappings: mappings, base_mappings: base_mappings)
  record_path = File.join(directory, "repository-tests.json")
  record_bytes = File.binread(record_path)
  record = JSON.parse(record_bytes.dup)
  abort "two-revision schema missing" unless record.values_at("schemaVersion", "scope") == [2, "base-and-head"]
  abort "wrong role/SHA order" unless record.fetch("revisions").map { |entry| entry.values_at("role", "testedSha") } == [["base", base], ["head", head]]
  abort "inventories were conflated" unless record.fetch("revisions").map { |entry| entry.fetch("tests").map { |test| test.fetch("path") } } == [base_mappings.fetch("AC-2"), mappings.fetch("AC-2")]
  abort "baseline falsely proves a Head feature" unless record.fetch("acceptanceEvidence").first.fetch("baseTests") == []
  abort "producer not bound to current Head" unless record.fetch("producer").fetch("headSha") == head
  abort "runner result totals differ" unless result.values_at("total", "passed", "failed") == [4, 4, 0]
  record.fetch("revisions").each do |revision|
    revision.fetch("tests").each do |test|
      abort "missing finite bound" unless test.fetch("timeoutSeconds") == 900 && test.fetch("elapsedSeconds") >= 0
      abort "wrong argv" unless test.fetch("command") == ["/bin/bash", "-p", test.fetch("path")]
    end
  end
  context = review.repository_revision_context(repo: repo, base_sha: base, head_sha: head)
  ["Repository-test scope: other; unsupported", "Repository-test scope: base-and-head;",
   "Repository-test scope: base-and-head; "].each do |declaration|
    begin
      review.repository_test_scope([{ "id"=>"AC-1", "text"=>declaration }])
      abort "malformed repository scope accepted"
    rescue IOSTemplate::ReviewContract::ValidationError
    end
  end
  begin
    review.repository_test_scope([criteria.last, criteria.last])
    abort "duplicate repository scope accepted"
  rescue IOSTemplate::ReviewContract::ValidationError
  end
  validate = ->(value) { review.validate_repository_tests!(value, issue: 42, base_sha: base, head_sha: head,
    contract_digest: review.digest(contract_bytes), criteria: criteria, revision_context: context) }
  validate.call(record)
  mutations = {
    "missing Base" => ->(v) { v["revisions"].shift },
    "duplicate revision" => ->(v) { v["revisions"][0] = v["revisions"][1] },
    "wrong Issue" => ->(v) { v["issue"] = 43 },
    "wrong contract" => ->(v) { v["issueContract"]["digest"] = "sha256:#{'1' * 64}" },
    "wrong tested SHA" => ->(v) { v["revisions"][0]["testedSha"] = head },
    "duplicate test" => ->(v) { v["revisions"][0]["tests"][0] = v["revisions"][0]["tests"][1] },
    "self-consistent subset" => ->(v) { r = v["revisions"][0]; r["tests"].pop; r["suite"]["total"] = r["suite"]["passed"] = 1; v["acceptanceEvidence"][1]["baseTests"].pop },
    "wrong producer" => ->(v) { v["producer"]["files"][0]["digest"] = "sha256:#{'2' * 64}" },
    "wrong source" => ->(v) { v["revisions"][0]["tests"][0]["sourceDigest"] = "sha256:#{'3' * 64}" },
    "escaping test path" => ->(v) { v["revisions"][0]["tests"][0]["path"] = "../tools/tests/test-alpha.sh" },
    "wrong argv" => ->(v) { v["revisions"][0]["tests"][0]["command"] = ["/bin/true"] },
    "failed test" => ->(v) { v["revisions"][0]["tests"][0]["status"] = "failed" },
    "timeout" => ->(v) { v["revisions"][0]["tests"][0]["status"] = "timed-out" },
    "unbounded test" => ->(v) { v["revisions"][0]["tests"][0]["timeoutSeconds"] = 0 }
  }
  mutations.each do |name, mutate|
    altered = JSON.parse(record_bytes.dup)
    mutate.call(altered)
    begin
      validate.call(altered)
      abort "accepted #{name}"
    rescue IOSTemplate::ReviewContract::ValidationError
      # Expected rejection, not evidence of real suite execution.
    end
  end
  abort "validation rewrote sealed bytes" unless File.binread(record_path) == record_bytes
  verify = {"schemaVersion"=>1, "status"=>"not-applicable", "issue"=>42, "baseSha"=>base, "headSha"=>head,
    "issueContract"=>record.fetch("issueContract"), "visualEvaluation"=>{"status"=>"not-applicable", "findings"=>[]},
    "completedAt"=>Time.now.utc.iso8601(6)}
  File.write(File.join(directory, "verify.json"), JSON.generate(verify))
  prepare = -> { IOSTemplate::PrepareReviewPacket.prepare(repo: repo, primary: "codex", issue: 42, base_sha: base, head_sha: head) }
  prepare.call
  packet_path = File.join(directory, "review-packet.json")
  packet_bytes = File.binread(packet_path)
  packet = JSON.parse(packet_bytes.dup)
  abort "record not bound by exact bytes" unless packet.fetch("repositoryTestsFile") == {"path"=>result.fetch("path"), "digest"=>review.digest(record_bytes)}
  packet_error = nil
  validate_packet = lambda do |result_file = nil|
    command = ["/bin/bash", File.join(repo, "tools/validate-review-result.sh"), "--primary", "codex", "--packet", ".artifacts/issues/42/#{head}/review-packet.json"]
    command += ["--result", result_file] if result_file
    _, packet_error, status = Open3.capture3(*command, chdir: repo)
    status.success?
  end
  abort "real packet preflight rejected Base and Head: #{packet_error}" unless validate_packet.call
  File.write(record_path, record_bytes + "\n")
  abort "packet preflight accepted changed record bytes" if validate_packet.call
  File.write(record_path, record_bytes)
  File.rename(record_path, record_path + ".link-target")
  File.symlink(File.basename(record_path) + ".link-target", record_path)
  abort "packet preflight accepted a symlink record" if validate_packet.call
  File.unlink(record_path)
  File.link(record_path + ".link-target", record_path)
  abort "packet preflight accepted a hardlinked record" if validate_packet.call
  File.unlink(record_path)
  File.rename(record_path + ".link-target", record_path)
  altered_packet = JSON.parse(packet_bytes.dup)
  altered_packet.delete("repositoryTests")
  altered_packet.delete("repositoryTestsFile")
  File.write(packet_path, JSON.generate(altered_packet))
  abort "packet preflight ignored a missing required Base record" if validate_packet.call
  File.write(packet_path, packet_bytes)
  result_value = {"schemaVersion"=>2, "issue"=>42, "reviewerModel"=>"claude", "baseSha"=>base, "headSha"=>head,
    "verifySha"=>head, "issueContractDigest"=>review.digest(contract_bytes), "reviewPacketDigest"=>review.digest(packet_bytes),
    "verdict"=>"approved", "findings"=>[], "reviewedAt"=>Time.now.utc.iso8601(6),
    "acceptanceAssessment"=>criteria.each_with_index.map { |c,i| {"id"=>c["id"], "status"=>"supported", "evidence"=>["repository-tests.json#acceptanceEvidence/#{i}"]} }}
  result_file = File.join(scratch, "review-result.json")
  File.write(result_file, JSON.generate(result_value))
  abort "real result validator rejected Base and Head" unless validate_packet.call(result_file)
  result_value["acceptanceAssessment"][0]["evidence"] = ["repository-tests.json#acceptanceEvidence/1"]
  File.write(result_file, JSON.generate(result_value))
  abort "result accepted another AC mapping as proof" if validate_packet.call(result_file)
  result_value["acceptanceAssessment"][0]["evidence"] = ["repository-tests.json#acceptanceEvidence/0"]
  File.write(result_file, JSON.generate(result_value))
  publish_args = [File.join(repo, "tools/lib/publish-review-result.rb"), repo, "42", head, result_file,
    packet_path, "codex", result_value["reviewedAt"], Time.now.utc.iso8601(6)]
  _, error, status = Open3.capture3("/usr/bin/ruby", *publish_args)
  abort "new result/receipt publication failed: #{error}" unless status.success?
  receipt = JSON.parse(File.binread(File.join(directory, "review-receipt.json")))
  abort "receipt does not bind exact two-revision packet" unless receipt.fetch("reviewPacketDigest") == review.digest(packet_bytes)
  %w[review.json review-receipt.json].each { |name| File.unlink(File.join(directory, name)) }
  # Interpose only in the isolated fixture process: alter the record after
  # result/receipt creation, just before the publisher's final held check.
  shim = File.join(scratch, "publication-race.rb")
  File.write(shim, <<~SHIM)
    require #{File.join(repo, "tools/lib/review-sealing.rb").inspect}
    module RecordRace
      def verify!
        @fixture_checks = (@fixture_checks || 0) + 1
        if @fixture_checks == 3
          path = #{record_path.inspect}
          bytes = File.binread(path)
          File.rename(path, path + ".before-race")
          File.binwrite(path, bytes)
        end
        super
      end
    end
    IOSTemplate::ReviewSealing::SnapshotSet.prepend(RecordRace)
  SHIM
  _, _, status = Open3.capture3("/usr/bin/ruby", "-r", shim, *publish_args)
  abort "result/receipt publication accepted a replaced record" if status.success?
  abort "publication race did not execute" unless File.exist?(record_path + ".before-race")
  abort "failed closure left a published result/receipt" if %w[review.json review-receipt.json].any? { |name| File.exist?(File.join(directory, name)) }
  File.unlink(record_path)
  File.rename(record_path + ".before-race", record_path)
  %w[fail timeout].each_with_index do |mode, index|
    fixture_issue = 43 + index
    failed_directory = File.join(repo, ".artifacts/issues/#{fixture_issue}", head)
    FileUtils.mkdir_p(failed_directory)
    File.write(File.join(File.dirname(failed_directory), "issue-contract.json"), JSON.generate(contract.merge("issue"=>fixture_issue)))
    environment = {"BASE_CASE"=>mode, "IOS_TEMPLATE_REPOSITORY_TEST_TIMEOUT_SECONDS"=>"1"}
    _, error, status = Open3.capture3(environment, "/bin/bash", File.join(repo, "tools/run-repository-tests.sh"),
      "--issue", fixture_issue.to_s, "--expected-base", base,
      "--map", "AC-1=tools/tests/test-beta.sh", "--map", "AC-2=#{mappings['AC-2'].join(',')}",
      "--base-map", "AC-2=#{base_mappings['AC-2'].join(',')}", chdir: repo)
    abort "#{mode} Base suite was accepted" if status.success?
    abort "wrong failure for #{mode}: #{error}" unless error.include?(mode == "timeout" ? "repository test timed out" : "base repository test failed")
    abort "failed Base suite published success" if File.exist?(File.join(failed_directory, "repository-tests.json"))
  end
  File.unlink(packet_path)
  File.unlink(File.join(directory, "review.diff"))
  begin
    IOSTemplate::PrepareReviewPacket.prepare(repo: repo, primary: "codex", issue: 42, base_sha: base, head_sha: head,
      before_publish: -> { File.rename(record_path, record_path + ".original"); File.write(record_path, record_bytes) })
    abort "publication accepted a same-byte record inode swap"
  rescue IOSTemplate::PrepareReviewPacket::PreparationError
    abort "raced packet was published" if File.exist?(packet_path)
  end
  abort "detached worktree leaked" unless git.call("worktree", "list", "--porcelain").scan(/^worktree /).length == 1
end
puts 'PASS: actual Base and Head inventories, producer identity, finite results, and rejection fixtures'
RUBY
