#!/bin/bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg ruby jq shasum

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
entrypoint="$repo_root/tools/prepare-appstore-legal-handoff.sh"
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-legal-handoff.XXXXXX")
trap 'rm -rf -- "$workspace"' EXIT

# D-105 (updates D-072): https://yutodev.com/apps/<appSlug>/<kind>/, with Japanese and English on the same page.
web_base='https://yutodev.com/apps/pay-cycle'
legacy_fixture="$repo_root/tools/tests/fixtures/appstore/legal-handoff-legacy"

expect_failure() {
  local label=$1 message=$2
  shift 2
  if "$@" >"$workspace/$label.stdout" 2>"$workspace/$label.stderr"; then
    echo "legal handoff accepted $label" >&2
    exit 1
  fi
  rg -Fq -- "$message" "$workspace/$label.stderr" || {
    echo "legal handoff rejection differed for $label" >&2
    cat "$workspace/$label.stderr" >&2
    exit 1
  }
}

mkdir -p "$workspace/App Store/legal/en-US" "$workspace/App Store/legal/ja" "$workspace/Config"
identity='{"appSlug":"pay-cycle","bundleId":"com.yuto1201.paycycle","displayName":"PayCycle","moduleName":"PayCycle","schemaVersion":1,"sourceIdentityVersion":1}'
printf '%s\n' "$identity" > "$workspace/Config/app-identity.json"

write_document() {
  local locale=$1 kind=$2 title=$3 sentence=$4
  cat > "$workspace/App Store/legal/$locale/$kind.md" <<EOF
# $title

Status: Confirmed

$sentence
EOF
}

write_document en-US support 'Support' 'Contact the PayCycle support team from the approved support channel.'
write_document en-US privacy 'Privacy Policy' 'PayCycle does not collect personal data in this approved fixture.'
write_document en-US terms 'Terms of Use' 'Use PayCycle lawfully and verify each scheduled payday before relying on it.'
write_document ja support 'サポート' '承認済みのサポート窓口からPayCycleのサポートチームへ連絡できます。'
write_document ja privacy 'プライバシーポリシー' 'この承認済みフィクスチャではPayCycleは個人データを収集しません。'
write_document ja terms '利用規約' 'PayCycleを適法に利用し、予定給料日を利用前に確認してください。'

request="$workspace/App Store/legal/handoff-request.json"
REQUEST="$request" ROOT="$workspace" ruby -rjson -rdigest -e '
  root = ENV.fetch("ROOT")
  documents = []
  %w[en-US ja].each do |locale|
    %w[support privacy terms].each do |kind|
      relative = "App Store/legal/#{locale}/#{kind}.md"
      documents << {
        "kind" => kind, "locale" => locale, "path" => relative,
        "digest" => "sha256:#{Digest::SHA256.file(File.join(root, relative)).hexdigest}",
        "approvalReference" => "https://github.com/yuto1201/iOS-PayCycle/issues/54#issuecomment-1"
      }
    end
  end
  routes = %w[support privacy terms].map { |kind| {"kind" => kind, "path" => "/apps/pay-cycle/#{kind}/"} }
  value = {
    "schemaVersion" => 2,
    "handoffId" => "pay-cycle-v1",
    "source" => {"repository" => "yuto1201/iOS-PayCycle", "issue" => 54, "headSha" => "a" * 40},
    "app" => {"name" => "PayCycle", "bundleId" => "com.yuto1201.paycycle", "platforms" => ["iOS", "iPadOS"]},
    "webHost" => "yutodev.com",
    "locales" => ["en-US", "ja"],
    "facts" => {
      "features" => ["Shows the next scheduled payday."],
      "dataUse" => ["No personal data is collected."],
      "advertising" => {"status" => "not-used", "summary" => "No advertising SDK is included."},
      "purchases" => {"status" => "not-used", "summary" => "No in-app purchase is included."}
    },
    "documents" => documents,
    "routes" => routes,
    "expectedReturn" => ["deployment-reference", "public-urls", "source-digests"]
  }
  File.binwrite(ENV.fetch("REQUEST"), JSON.generate(value))
'

prompt="$workspace/App Store/legal/handoff-prompt.md"
rendered=$(
  "$entrypoint" render --repo-root "$workspace" --request "$request" --output "$prompt"
)
[[ "$(jq -r .title <<<"$rendered")" == '[Legal pages]: PayCycle privacy, terms, and support' ]]
[[ "$(jq -r .promptDigest <<<"$rendered")" =~ ^sha256:[0-9a-f]{64}$ ]]
rg -q 'yuto1201/Web-yutodev' "$prompt"
! rg -q 'Web-AppLibrary|app\.yutodev\.com' "$prompt"
rg -q '1 Issue = 1 Branch = 1 PR' "$prompt"
rg -Fq 'App slug: `pay-cycle`' "$prompt"
for kind in support privacy terms; do
  rg -Fq "URL: \`$web_base/$kind/\`" "$prompt"
done
[[ "$(rg -c 'Languages on this page: en-US, ja' "$prompt")" == 3 ]]
rg -Fq 'Japanese and English text on the same page' "$prompt"
rg -Fq 'do not create a separate URL per language' "$prompt"
rg -q 'PayCycle does not collect personal data' "$prompt"
rg -q 'PayCycleは個人データを収集しません' "$prompt"
rg -q 'User-controlled handoff and approval' "$prompt"
rg -Fq 'the three exact public URLs with the source digests of both languages' "$prompt"
! rg -q 'yutodev\.com/apps/pay-cycle/(en-US|ja)/' "$prompt"

expect_failure existing-output 'already exists' \
  "$entrypoint" render --repo-root "$workspace" --request "$request" --output "$prompt"

# Every other host, a per-language route, another slug, or the superseded schema is rejected before rendering.
reject_request() {
  local label=$1 message=$2 filter=$3
  jq -c "$filter" "$request" > "$workspace/$label-request.json"
  expect_failure "$label" "$message" \
    "$entrypoint" render --repo-root "$workspace" --request "$workspace/$label-request.json" --output "$workspace/$label.md"
  [[ ! -e "$workspace/$label.md" ]] || { echo "rejected request rendered output: $label" >&2; exit 1; }
}
reject_request other-host 'request.webHost must be yutodev.com' '.webHost="app.example.com"'
# A request written for the pre-2026-11-14 host is not silently accepted: it points at the migration.
reject_request legacy-host 'migrate-legacy-handoff' '.webHost="app.yutodev.com"'
reject_request locale-route 'request.routes[1].path must be /apps/pay-cycle/privacy/' '.routes[1].path="/apps/pay-cycle/ja/privacy/"'
reject_request other-slug 'request.routes[2].path must be /apps/pay-cycle/terms/' '.routes[2].path="/apps/other-app/terms/"'
reject_request missing-trailing-slash 'request.routes[0].path must be /apps/pay-cycle/support/' '.routes[0].path="/apps/pay-cycle/support"'
reject_request duplicate-kind 'request.routes contains duplicate kinds' '.routes += [{"kind":"privacy","path":"/apps/pay-cycle/privacy/"}]'
reject_request missing-kind 'request.routes must contain every page kind exactly once' '.routes |= map(select(.kind != "terms"))'
reject_request per-locale-route-keys 'request.routes[0] keys differ' '.routes[0].locale="ja"'
reject_request superseded-schema 'request schemaVersion must be 2' '.schemaVersion=1'
reject_request other-bundle 'request.app.bundleId differs from Config/app-identity.json' '.app.bundleId="com.example.other"'

reject_identity() {
  local label=$1 message=$2 value=$3
  if [[ -n "$value" ]]; then printf '%s\n' "$value" > "$workspace/Config/app-identity.json"; else rm "$workspace/Config/app-identity.json"; fi
  expect_failure "$label" "$message" \
    "$entrypoint" render --repo-root "$workspace" --request "$request" --output "$workspace/$label.md"
  printf '%s\n' "$identity" > "$workspace/Config/app-identity.json"
}
reject_identity missing-identity 'Config/app-identity.json does not exist' ''
reject_identity template-slug 'Config/app-identity.json.appSlug is still the template slug' \
  '{"appSlug":"template-app","bundleId":"com.yuto1201.paycycle","displayName":"PayCycle","moduleName":"PayCycle","schemaVersion":1,"sourceIdentityVersion":1}'
reject_identity invalid-slug 'Config/app-identity.json.appSlug is invalid' \
  '{"appSlug":"Pay_Cycle","bundleId":"com.yuto1201.paycycle","displayName":"PayCycle","moduleName":"PayCycle","schemaVersion":1,"sourceIdentityVersion":1}'

prompt_digest=$(jq -r .promptDigest <<<"$rendered")
readback="$workspace/web-issue-readback.json"
PROMPT="$prompt" READBACK="$readback" ruby -rjson -rdigest -e '
  body = File.binread(ENV.fetch("PROMPT")).force_encoding(Encoding::UTF_8)
  value = {
    "number" => 34,
    "url" => "https://github.com/yuto1201/Web-yutodev/issues/34",
    "title" => "[Legal pages]: PayCycle privacy, terms, and support",
    "body" => body,
    "state" => "OPEN"
  }
  File.binwrite(ENV.fetch("READBACK"), JSON.generate(value))
'

issue_record="$workspace/App Store/legal/web-issue.json"
recorded=$(
  "$entrypoint" record-issue --repo-root "$workspace" --request "$request" --prompt "$prompt" \
    --readback "$readback" --output "$issue_record" --now 2026-09-16T00:00:00Z
)
[[ "$(jq -r .status <<<"$recorded")" == awaiting-user-handoff ]]
[[ "$(jq -r .webIssue.url <<<"$recorded")" == https://github.com/yuto1201/Web-yutodev/issues/34 ]]
[[ "$(jq -r .webIssue.repository <<<"$recorded")" == yuto1201/Web-yutodev ]]
[[ "$(jq -r .prompt.digest <<<"$recorded")" == "$prompt_digest" ]]

jq '.url="https://github.com/yuto1201/Other/issues/34"' "$readback" > "$workspace/bad-readback.json"
expect_failure bad-readback 'Web-yutodev' \
  "$entrypoint" record-issue --repo-root "$workspace" --request "$request" --prompt "$prompt" \
    --readback "$workspace/bad-readback.json" --output "$workspace/bad-issue.json" --now 2026-09-16T00:00:00Z
jq '.url="https://github.com/yuto1201/Web-AppLibrary/issues/34"' "$readback" > "$workspace/legacy-readback.json"
expect_failure legacy-readback 'issue readback must target yuto1201/Web-yutodev' \
  "$entrypoint" record-issue --repo-root "$workspace" --request "$request" --prompt "$prompt" \
    --readback "$workspace/legacy-readback.json" --output "$workspace/legacy-issue.json" --now 2026-09-16T00:00:00Z

tampered_prompt="$workspace/tampered-prompt.md"
cp "$prompt" "$tampered_prompt"
printf '\nUnapproved addition.\n' >> "$tampered_prompt"
jq --rawfile body "$tampered_prompt" '.body=$body' "$readback" > "$workspace/tampered-readback.json"
expect_failure tampered-prompt 'deterministic request rendering' \
  "$entrypoint" record-issue --repo-root "$workspace" --request "$request" --prompt "$tampered_prompt" \
    --readback "$workspace/tampered-readback.json" --output "$workspace/tampered-issue.json" --now 2026-09-16T00:00:00Z

publication="$workspace/publication.json"
responses="$workspace/responses.json"
REQUEST="$request" ROOT="$workspace" PUBLICATION="$publication" RESPONSES="$responses" PROMPT_DIGEST="$prompt_digest" ruby -rjson -rdigest -e '
  request = JSON.parse(File.binread(ENV.fetch("REQUEST")))
  documents = request.fetch("documents")
  pages = request.fetch("routes").map do |route|
    kind = route.fetch("kind")
    digests = %w[en-US ja].to_h { |locale| [locale, documents.find { |item| item.values_at("locale", "kind") == [locale, kind] }.fetch("digest")] }
    {"kind" => kind, "url" => "https://yutodev.com#{route.fetch("path")}", "sourceDigests" => digests}
  end
  publication = {
    "schemaVersion" => 2, "handoffId" => request.fetch("handoffId"),
    "requestDigest" => "sha256:#{Digest::SHA256.file(ENV.fetch("REQUEST")).hexdigest}",
    "promptDigest" => ENV.fetch("PROMPT_DIGEST"),
    "webIssueURL" => "https://github.com/yuto1201/Web-yutodev/issues/34",
    "deploymentReference" => "https://github.com/yuto1201/Web-yutodev/pull/35",
    "userActions" => {
      "promptForwarded" => {"actor" => "user", "reference" => "https://github.com/yuto1201/iOS-PayCycle/issues/54#issuecomment-3", "at" => "2026-09-16T00:01:00Z"},
      "publicationApproved" => {"actor" => "user", "reference" => "https://github.com/yuto1201/iOS-PayCycle/issues/54#issuecomment-4", "at" => "2026-09-16T00:02:00Z"}
    },
    "pages" => pages
  }
  # One bilingual page per kind: both languages behind an in-page switch, and links to every page.
  responses = pages.map do |page|
    sections = %w[en-US ja].map do |locale|
      document = documents.find { |item| item.values_at("locale", "kind") == [locale, page.fetch("kind")] }
      text = File.binread(File.join(ENV.fetch("ROOT"), document.fetch("path"))).force_encoding(Encoding::UTF_8)
      %(<section lang="#{locale}"><pre>#{text}</pre></section>)
    end.join
    links = pages.map { |candidate| %(<a href="#{candidate.fetch("url")}">#{candidate.fetch("kind")}</a>) }.join
    {"url" => page.fetch("url"), "finalURL" => page.fetch("url"), "status" => 200,
     "body" => "<html><body><main>#{sections}#{links}</main></body></html>"}
  end
  File.binwrite(ENV.fetch("PUBLICATION"), JSON.generate(publication))
  File.binwrite(ENV.fetch("RESPONSES"), JSON.generate({"schemaVersion" => 1, "responses" => responses}))
'

verify() {
  local output=$1 publication_file=$2 responses_file=$3
  "$entrypoint" verify-publication --repo-root "$workspace" --request "$request" --prompt "$prompt" \
    --issue-record "$issue_record" --publication "$publication_file" --response-fixture "$responses_file" \
    --output "$output" --now 2026-09-16T00:03:00Z
}

verification="$workspace/App Store/legal/publication-verification.json"
verified=$(verify "$verification" "$publication" "$responses")
[[ "$(jq -r .schemaVersion <<<"$verified")" == 2 ]]
[[ "$(jq -r .status <<<"$verified")" == fixture-validated ]]
[[ "$(jq -r .appStoreEligible <<<"$verified")" == false ]]
[[ "$(jq -c '[.pages[].url]' <<<"$verified")" == "[\"$web_base/support/\",\"$web_base/privacy/\",\"$web_base/terms/\"]" ]]
jq -e '.pages | all(.httpStatus == 200 and .contentMatched == true and .locales == ["en-US","ja"]
  and (.sourceDigests | keys) == ["en-US","ja"] and (.interlinks | length) == 2)' <<<"$verified" >/dev/null

# #317: a link and emphasis inside a Japanese sentence add no space, so the published page still matches.
inline_filter='.responses[0].body |= sub("サポート窓口"; "<a href=\"mailto:support@example.com\">サポート窓口</a>") | .responses[0].body |= sub("サポートチーム"; "<strong>サポートチーム</strong>")'
jq "$inline_filter" "$responses" > "$workspace/inline-responses.json"
grep -Fq '<strong>サポートチーム</strong>' "$workspace/inline-responses.json" || { echo 'inline fixture was not applied' >&2; exit 1; }
inline_verified=$(verify "$workspace/inline-verification.json" "$publication" "$workspace/inline-responses.json")
jq -e '.pages | all(.contentMatched == true)' <<<"$inline_verified" >/dev/null

reject_response() {
  local label=$1 message=$2 filter=$3
  jq "$filter" "$responses" > "$workspace/$label-responses.json"
  expect_failure "$label" "$message" verify "$workspace/$label.json" "$publication" "$workspace/$label-responses.json"
  [[ ! -e "$workspace/$label.json" ]] || { echo "rejected publication wrote output: $label" >&2; exit 1; }
}
reject_response unauthorized 'HTTP 200' '.responses[0].status=401'
reject_response missing-link 'interlink' ".responses[0].body |= sub(\"<a href=\\\"$web_base/terms/\\\">terms</a>\"; \"\")"
reject_response missing-japanese "approved source text: $web_base/privacy/ (ja)" '.responses[1].body |= sub("<section lang=\"ja\">.*?</section>"; ""; "p")'
reject_response missing-english "approved source text: $web_base/terms/ (en-US)" '.responses[2].body |= sub("<section lang=\"en-US\">.*?</section>"; ""; "p")'
reject_response inline-text-differs "approved source text: $web_base/support/ (ja)" "$inline_filter"' | .responses[0].body |= sub("連絡できます"; "連結できます")'
reject_response redirected-host 'public URL must use HTTPS and the approved host' '.responses[0].finalURL="https://app.example.com/apps/pay-cycle/support/"'
reject_response legacy-host-response 'public URL must use HTTPS and the approved host' '.responses[0].finalURL="https://app.yutodev.com/apps/pay-cycle/support/"'

reject_publication() {
  local label=$1 message=$2 filter=$3
  jq "$filter" "$publication" > "$workspace/$label-publication.json"
  expect_failure "$label" "$message" verify "$workspace/$label.json" "$workspace/$label-publication.json" "$responses"
}
reject_publication per-locale-url 'publication return.pages[0].url differs from the D-105 route' \
  ".pages[0].url=\"https://yutodev.com/apps/pay-cycle/ja/support/\""
reject_publication one-language-digest 'publication return.pages[1].sourceDigests keys differ' '.pages[1].sourceDigests |= del(.ja)'
reject_publication superseded-publication 'publication return schemaVersion must be 2' '.schemaVersion=1'
reject_publication legacy-page-url 'publication return.pages[0].url differs from the D-105 route' \
  ".pages[0].url=\"https://app.yutodev.com/apps/pay-cycle/support/\""

# A record made before 2026-11-14 is never accepted as is: verify-publication points at the migration.
legacy_record="$workspace/App Store/legal/legacy-web-issue-in-place.json"
jq '.webIssue.repository="yuto1201/Web-AppLibrary" | .webIssue.url="https://github.com/yuto1201/Web-AppLibrary/issues/34"' "$issue_record" > "$legacy_record"
expect_failure legacy-record 'migrate-legacy-handoff' \
  "$entrypoint" verify-publication --repo-root "$workspace" --request "$request" --prompt "$prompt" \
    --issue-record "$legacy_record" --publication "$publication" --response-fixture "$responses" \
    --output "$workspace/legacy-record.json" --now 2026-09-16T00:03:00Z

# Migration of a handoff recorded before 2026-11-14 (D-105). The fixtures are the exact bytes the unchanged
# tool wrote for the same app and sources: request with webHost app.yutodev.com, its prompt, and its record.
legacy_dir="$workspace/App Store/legal/legacy"
mkdir -p "$legacy_dir"
cp "$legacy_fixture/handoff-request.json" "$legacy_fixture/handoff-prompt.md" "$legacy_fixture/web-issue.json" "$legacy_dir/"
legacy_readback="$workspace/legacy-web-issue-readback.json"
# The existing Web Issue, read back under the renamed repository: same number, body is the legacy prompt.
LEGACY_PROMPT="$legacy_dir/handoff-prompt.md" READBACK="$legacy_readback" ruby -rjson -e '
  body = File.binread(ENV.fetch("LEGACY_PROMPT")).force_encoding(Encoding::UTF_8)
  File.binwrite(ENV.fetch("READBACK"), JSON.generate({"number" => 34, "url" => "https://github.com/yuto1201/Web-yutodev/issues/34",
    "title" => "[Legal pages]: PayCycle privacy, terms, and support", "body" => body, "state" => "CLOSED"}))
'
migrate() {
  local label=$1 readback_file=$2 prompt_file=${3:-"$legacy_dir/handoff-prompt.md"} record_file=${4:-"$legacy_dir/web-issue.json"}
  "$entrypoint" migrate-legacy-handoff --repo-root "$workspace" --request "$legacy_dir/handoff-request.json" \
    --prompt "$prompt_file" --issue-record "$record_file" --readback "$readback_file" \
    --request-output "$workspace/App Store/legal/$label-request.json" --prompt-output "$workspace/App Store/legal/$label-prompt.md" \
    --issue-record-output "$workspace/App Store/legal/$label-web-issue.json" --now 2026-11-15T00:00:00Z
}
reject_migration() {
  local label=$1 message=$2
  shift 2
  expect_failure "$label" "$message" migrate "$label" "$@"
  for suffix in request.json prompt.md web-issue.json; do
    [[ ! -e "$workspace/App Store/legal/$label-$suffix" ]] || { echo "rejected migration wrote output: $label-$suffix" >&2; exit 1; }
  done
}
jq '.body += "changed"' "$legacy_readback" > "$workspace/m-body.json"
reject_migration migration-body-differs 'legacy prompt' "$workspace/m-body.json"
jq '.url="https://github.com/yuto1201/Web-AppLibrary/issues/34"' "$legacy_readback" > "$workspace/m-url.json"
reject_migration migration-old-url 'issue readback must target yuto1201/Web-yutodev' "$workspace/m-url.json"
jq '.number=35 | .url="https://github.com/yuto1201/Web-yutodev/issues/35"' "$legacy_readback" > "$workspace/m-number.json"
reject_migration migration-other-issue 'issue number differs' "$workspace/m-number.json"
cp "$legacy_dir/handoff-prompt.md" "$workspace/m-tampered-prompt.md"
printf '\nUnapproved addition.\n' >> "$workspace/m-tampered-prompt.md"
reject_migration migration-tampered-prompt 'legacy rendering' "$legacy_readback" "$workspace/m-tampered-prompt.md"
jq '.request.digest="sha256:0000000000000000000000000000000000000000000000000000000000000000"' "$legacy_dir/web-issue.json" > "$workspace/m-record.json"
reject_migration migration-record-digest 'issue record request digest differs' "$legacy_readback" "$legacy_dir/handoff-prompt.md" "$workspace/m-record.json"

migrated=$(migrate migrated "$legacy_readback")
migrated_request="$workspace/App Store/legal/migrated-request.json"
migrated_prompt="$workspace/App Store/legal/migrated-prompt.md"
migrated_record="$workspace/App Store/legal/migrated-web-issue.json"
[[ "$(jq -r .status <<<"$migrated")" == migrated ]]
[[ "$(jq -r .webHost "$migrated_request")" == yutodev.com ]]
[[ "$(jq -c 'del(.webHost)' "$migrated_request")" == "$(jq -c 'del(.webHost)' "$legacy_dir/handoff-request.json")" ]]
rg -q 'yuto1201/Web-yutodev' "$migrated_prompt"
! rg -q 'Web-AppLibrary|app\.yutodev\.com' "$migrated_prompt"
for kind in support privacy terms; do rg -Fq "URL: \`$web_base/$kind/\`" "$migrated_prompt"; done
jq -e '.webIssue == {"number":34,"repository":"yuto1201/Web-yutodev","state":"OPEN","url":"https://github.com/yuto1201/Web-yutodev/issues/34"}
  and .migratedFrom.webIssueURL == "https://github.com/yuto1201/Web-AppLibrary/issues/34"
  and .migratedFrom.readbackState == "CLOSED"
  and (.migratedFrom.requestDigest | startswith("sha256:"))
  and (.migratedFrom.promptDigest | startswith("sha256:"))
  and (.migratedFrom.issueRecordDigest | startswith("sha256:"))' "$migrated_record" >/dev/null
expect_failure migration-existing-output 'already exists' migrate migrated "$legacy_readback"
# A request that already uses the current host is not a legacy handoff.
cp "$request" "$legacy_dir/current-request.json"
expect_failure migration-current-request 'already uses yutodev.com' \
  "$entrypoint" migrate-legacy-handoff --repo-root "$workspace" --request "$legacy_dir/current-request.json" \
    --prompt "$prompt" --issue-record "$issue_record" --readback "$legacy_readback" \
    --request-output "$workspace/App Store/legal/cur-request.json" --prompt-output "$workspace/App Store/legal/cur-prompt.md" \
    --issue-record-output "$workspace/App Store/legal/cur-web-issue.json" --now 2026-11-15T00:00:00Z

# The migrated handoff verifies against the current host without a new Web Issue.
jq --arg request_digest "sha256:$(shasum -a 256 "$migrated_request" | cut -c1-64)" \
   --arg prompt_digest "sha256:$(shasum -a 256 "$migrated_prompt" | cut -c1-64)" \
   '.requestDigest=$request_digest | .promptDigest=$prompt_digest' "$publication" > "$workspace/migrated-publication.json"
migrated_verified=$("$entrypoint" verify-publication --repo-root "$workspace" --request "$migrated_request" --prompt "$migrated_prompt" \
  --issue-record "$migrated_record" --publication "$workspace/migrated-publication.json" --response-fixture "$responses" \
  --output "$workspace/migrated-verification.json" --now 2026-11-15T00:01:00Z)
[[ "$(jq -r .webIssueURL <<<"$migrated_verified")" == https://github.com/yuto1201/Web-yutodev/issues/34 ]]
jq -e '.pages | all(.contentMatched == true and (.url | startswith("https://yutodev.com/apps/pay-cycle/")))' <<<"$migrated_verified" >/dev/null

for path in \
  "$repo_root/.agents/skills/prepare-appstore-assets/templates/legal-page-handoff.md" \
  "$repo_root/App Store/legal/README.md"; do
  [[ -f "$path" ]] || { echo "legal handoff guidance is missing: $path" >&2; exit 1; }
  rg -Fq 'https://yutodev.com/apps/<appSlug>/' "$path" || { echo "legal handoff guidance lacks the D-105 URL: $path" >&2; exit 1; }
  ! rg -q 'https://app\.yutodev\.com/apps/<appSlug>/' "$path" || { echo "legal handoff guidance still names the pre-D-105 URL: $path" >&2; exit 1; }
done
rg -q 'prepare-appstore-legal-handoff\.sh' "$repo_root/.agents/skills/prepare-appstore-assets/SKILL.md"
rg -Fq 'https://yutodev.com/apps/<appSlug>/' "$repo_root/.agents/skills/prepare-appstore-assets/SKILL.md"
rg -Fq 'https://yutodev.com/apps/<appSlug>/' "$repo_root/docs/agent-contracts/appstore-submission.md"
rg -q 'fixture-validated.*not.*App Store|fixture-validated.*App Store.*not' "$repo_root/.agents/skills/prepare-appstore-assets/SKILL.md"
rg -q 'publication-verification' "$repo_root/.agents/skills/submit-appstore-release/SKILL.md"
rg -q 'yuto1201/Web-yutodev' "$repo_root/.agents/skills/prepare-appstore-assets/templates/legal-page-handoff.md"
rg -q 'migrate-legacy-handoff' "$repo_root/App Store/legal/README.md"
! rg -q 'user-approved public routes|user-approved route' \
  "$repo_root/.agents/skills/prepare-appstore-assets/templates/legal-page-handoff.md" "$repo_root/App Store/legal/README.md"

echo 'App Store legal-page handoff tests passed'
