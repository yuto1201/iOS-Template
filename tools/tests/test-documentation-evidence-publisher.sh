#!/usr/bin/env bash
set -euo pipefail

source_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
publisher="$source_repo/tools/publish-documentation-verify.sh"
validator="$source_repo/tools/validate-verify-json.swift"
scratch="$(mktemp -d -t ios-documentation-evidence.XXXXXX)"
scratch="$(cd "$scratch" && pwd -P)"
trap '/bin/rm -rf "$scratch"' EXIT

if [[ ! -x "$publisher" ]]; then
  echo "documentation evidence publisher RED: production publisher is absent" >&2
  exit 1
fi

repo=""
base_sha=""
head_sha=""
input=""
evidence=""

prepare_fixture() {
  local label="$1"
  repo="$scratch/$label/repository"
  /bin/mkdir -p "$repo/docs"
  repo="$(cd "$repo" && pwd -P)"
  /usr/bin/git -C "$repo" init -q
  /usr/bin/git -C "$repo" config user.name 'Documentation Publisher Test'
  /usr/bin/git -C "$repo" config user.email 'documentation-publisher@example.invalid'
  printf '%s\n' '.artifacts/' >"$repo/.gitignore"
  printf '%s\n' '# Base' >"$repo/docs/base.md"
  /usr/bin/git -C "$repo" add -- .gitignore docs/base.md
  /usr/bin/git -C "$repo" commit -q -m base
  base_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
  printf '%s\n' '# Head' >"$repo/docs/head.md"
  /usr/bin/git -C "$repo" add -- docs/head.md
  /usr/bin/git -C "$repo" commit -q -m head
  head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"

  local issue_root="$repo/.artifacts/issues/42"
  /bin/mkdir -p "$issue_root"
  /usr/bin/ruby --disable-gems -rjson -rtime - "$issue_root/issue-contract.json" <<'RUBY'
path = ARGV.fetch(0)
document = {
  "schemaVersion" => 1,
  "issue" => 42,
  "repository" => "yuto1201/iOS-Template",
  "goal" => "Publish deterministic documentation verification evidence",
  "specAnchors" => ["docs/verification.md#4-verification-evidence-schema"],
  "acceptanceCriteria" => [
    {"id" => "AC-1", "text" => "Documentation remains internally consistent"},
    {"id" => "AC-2", "text" => "Canonical links remain discoverable"}
  ],
  "dependencies" => [],
  "externalOperations" => [],
  "externalOperationDetailsDigest" => "sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945",
  "fetchedAt" => Time.now.iso8601
}
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY
  input="$issue_root/documentation-evidence-input.json"
  evidence="$issue_root/$head_sha/verify.json"
  write_input
}

write_input() {
  /usr/bin/ruby --disable-gems -rjson - "$input" <<'RUBY'
path = ARGV.fetch(0)
document = {
  "schemaVersion" => 1,
  "reason" => "Only allowlisted Markdown documentation changed",
  "acceptanceEvidence" => [
    {"id" => "AC-1", "evidence" => ["documents:docs/head.md"]},
    {"id" => "AC-2", "evidence" => ["links:docs/verification.md"]}
  ]
}
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY
}

mutate_input() {
  local expression="$1"
  MUTATION="$expression" /usr/bin/ruby --disable-gems -rjson - "$input" <<'RUBY'
path = ARGV.fetch(0)
document = JSON.parse(File.read(path))
eval(ENV.fetch("MUTATION"), binding, "mutation")
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY
}

run_publisher() {
  (
    cd "$repo"
    "$publisher" --issue 42 --expected-base "$base_sha" --expected-head "$head_sha" \
      --input .artifacts/issues/42/documentation-evidence-input.json
  )
}

expect_failure() {
  local label="$1" diagnostic="$2"
  if run_publisher >"$scratch/$label.stdout" 2>"$scratch/$label.stderr"; then
    echo "documentation publisher unexpectedly accepted $label" >&2
    exit 1
  fi
  if ! /usr/bin/grep -Fq -- "$diagnostic" "$scratch/$label.stderr"; then
    echo "documentation publisher rejected $label for the wrong reason" >&2
    echo "expected diagnostic: $diagnostic" >&2
    /bin/cat "$scratch/$label.stderr" >&2
    exit 1
  fi
  [[ ! -e "$evidence" ]] || {
    echo "documentation publisher exposed verify.json after rejecting $label" >&2
    exit 1
  }
}

prepare_fixture valid-publication
published="$(run_publisher)"
[[ "$published" == ".artifacts/issues/42/$head_sha/verify.json" ]] || {
  echo "documentation publisher returned the wrong canonical path" >&2
  exit 1
}
(
  cd "$repo"
  /usr/bin/swift "$validator" --file "$published" --expected-issue 42 \
    --expected-base "$base_sha" --expected-head "$head_sha"
) >/dev/null
/usr/bin/ruby --disable-gems -rjson -rdigest - "$evidence" "$repo/.artifacts/issues/42/issue-contract.json" "$base_sha" "$head_sha" <<'RUBY'
evidence_path, contract_path, base, head = ARGV
document = JSON.parse(File.read(evidence_path))
raise "wrong classification" unless document.fetch("changeClassification") == "documentation-only"
raise "wrong identity" unless document.fetch("issue") == 42 && document.fetch("baseSha") == base && document.fetch("headSha") == head
raise "wrong contract digest" unless document.dig("issueContract", "digest") == "sha256:#{Digest::SHA256.file(contract_path).hexdigest}"
raise "wrong acceptance evidence" unless document.fetch("acceptanceEvidence") == [
  {"id" => "AC-1", "status" => "passed", "evidence" => ["documents:docs/head.md"]},
  {"id" => "AC-2", "status" => "passed", "evidence" => ["links:docs/verification.md"]}
]
RUBY

prepare_fixture missing-acceptance
mutate_input 'document.fetch("acceptanceEvidence").pop'
expect_failure missing-acceptance "acceptanceEvidence must contain every Issue contract AC exactly once and no extras"

prepare_fixture unsafe-acceptance
mutate_input 'document.fetch("acceptanceEvidence").fetch(0)["evidence"] = ["tests:not-documentation"]'
expect_failure unsafe-acceptance "documentation-only acceptance evidence must cite document or link checks"

prepare_fixture unsafe-diff
/bin/mkdir -p "$repo/scripts"
printf '%s\n' '#!/bin/sh' >"$repo/scripts/changed.sh"
/usr/bin/git -C "$repo" add -- scripts/changed.sh
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
evidence="$repo/.artifacts/issues/42/$head_sha/verify.json"
expect_failure unsafe-diff "documentation-only path is not allowlisted: scripts/changed.sh"

prepare_fixture misordered-acceptance
mutate_input 'document.fetch("acceptanceEvidence").reverse!'
expect_failure misordered-acceptance "acceptanceEvidence must follow the exact Issue contract AC order"

prepare_fixture duplicate-acceptance
mutate_input 'document.fetch("acceptanceEvidence")[1] = document.fetch("acceptanceEvidence").first'
expect_failure duplicate-acceptance "acceptanceEvidence contains duplicate ID AC-1"

prepare_fixture symlink-input
/bin/mv "$input" "$input.real"
/bin/ln -s "$(basename "$input").real" "$input"
expect_failure symlink-input "documentation evidence input is unavailable or contains a symbolic link"

prepare_fixture no-overwrite
run_publisher >/dev/null
original_digest="$(/usr/bin/shasum -a 256 "$evidence" | /usr/bin/awk '{print $1}')"
mutate_input 'document["reason"] = "A different reason must not overwrite canonical evidence"'
if run_publisher >"$scratch/no-overwrite.stdout" 2>"$scratch/no-overwrite.stderr"; then
  echo "documentation publisher overwrote existing canonical evidence" >&2
  exit 1
fi
current_digest="$(/usr/bin/shasum -a 256 "$evidence" | /usr/bin/awk '{print $1}')"
[[ "$current_digest" == "$original_digest" ]] || {
  echo "documentation publisher changed canonical evidence after collision" >&2
  exit 1
}

echo "documentation evidence publisher tests passed"
