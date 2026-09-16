#!/bin/bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg ruby jq shasum

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
entrypoint="$repo_root/tools/prepare-appstore-legal-handoff.sh"
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-legal-handoff.XXXXXX")
trap 'rm -rf -- "$workspace"' EXIT

mkdir -p "$workspace/App Store/legal/en-US" "$workspace/App Store/legal/ja"

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
  routes = []
  {"en-US" => {"support" => "support", "privacy" => "privacy", "terms" => "terms"},
   "ja" => {"support" => "support", "privacy" => "privacy", "terms" => "terms"}}.each do |locale, kinds|
    kinds.each_key do |kind|
      relative = "App Store/legal/#{locale}/#{kind}.md"
      documents << {
        "kind" => kind, "locale" => locale, "path" => relative,
        "digest" => "sha256:#{Digest::SHA256.file(File.join(root, relative)).hexdigest}",
        "approvalReference" => "https://github.com/yuto1201/iOS-PayCycle/issues/54#issuecomment-1"
      }
      routes << {
        "kind" => kind, "locale" => locale,
        "path" => "/apps/pay-cycle/#{locale}/#{kind}/",
        "approvalReference" => "https://github.com/yuto1201/iOS-PayCycle/issues/54#issuecomment-2"
      }
    end
  end
  value = {
    "schemaVersion" => 1,
    "handoffId" => "pay-cycle-v1",
    "source" => {"repository" => "yuto1201/iOS-PayCycle", "issue" => 54, "headSha" => "a" * 40},
    "app" => {"name" => "PayCycle", "bundleId" => "com.yuto1201.paycycle", "platforms" => ["iOS", "iPadOS"]},
    "webHost" => "app.example.com",
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
rg -q 'yuto1201/Web-AppLibrary' "$prompt"
rg -q '1 Issue = 1 Branch = 1 PR' "$prompt"
rg -q 'PayCycle does not collect personal data' "$prompt"
rg -q 'PayCycleは個人データを収集しません' "$prompt"
rg -q 'User-controlled handoff and approval' "$prompt"
rg -q 'Expected return contract' "$prompt"

if "$entrypoint" render --repo-root "$workspace" --request "$request" --output "$prompt" 2>"$workspace/existing-output.stderr"; then
  echo 'existing prompt was overwritten' >&2
  exit 1
fi
rg -q 'already exists' "$workspace/existing-output.stderr"

prompt_digest=$(jq -r .promptDigest <<<"$rendered")
readback="$workspace/web-issue-readback.json"
PROMPT="$prompt" READBACK="$readback" ruby -rjson -rdigest -e '
  body = File.binread(ENV.fetch("PROMPT")).force_encoding(Encoding::UTF_8)
  value = {
    "number" => 34,
    "url" => "https://github.com/yuto1201/Web-AppLibrary/issues/34",
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
[[ "$(jq -r .webIssue.url <<<"$recorded")" == https://github.com/yuto1201/Web-AppLibrary/issues/34 ]]
[[ "$(jq -r .prompt.digest <<<"$recorded")" == "$prompt_digest" ]]

bad_readback="$workspace/bad-readback.json"
jq '.url="https://github.com/yuto1201/Other/issues/34"' "$readback" > "$bad_readback"
if "$entrypoint" record-issue --repo-root "$workspace" --request "$request" --prompt "$prompt" \
  --readback "$bad_readback" --output "$workspace/bad-issue.json" --now 2026-09-16T00:00:00Z 2>"$workspace/bad-readback.stderr"; then
  echo 'wrong Web repository was accepted' >&2
  exit 1
fi
rg -q 'Web-AppLibrary' "$workspace/bad-readback.stderr"

tampered_prompt="$workspace/tampered-prompt.md"
cp "$prompt" "$tampered_prompt"
printf '\nUnapproved addition.\n' >> "$tampered_prompt"
jq --rawfile body "$tampered_prompt" '.body=$body' "$readback" > "$workspace/tampered-readback.json"
if "$entrypoint" record-issue --repo-root "$workspace" --request "$request" --prompt "$tampered_prompt" \
  --readback "$workspace/tampered-readback.json" --output "$workspace/tampered-issue.json" \
  --now 2026-09-16T00:00:00Z 2>"$workspace/tampered-prompt.stderr"; then
  echo 'non-deterministic prompt was accepted' >&2
  exit 1
fi
rg -q 'deterministic request rendering' "$workspace/tampered-prompt.stderr"

publication="$workspace/publication.json"
responses="$workspace/responses.json"
REQUEST="$request" PUBLICATION="$publication" RESPONSES="$responses" PROMPT_DIGEST="$prompt_digest" ruby -rjson -rdigest -e '
  request = JSON.parse(File.binread(ENV.fetch("REQUEST")))
  pages = request.fetch("documents").map do |document|
    route = request.fetch("routes").find { |candidate| candidate.values_at("kind", "locale") == document.values_at("kind", "locale") }
    {
      "kind" => document.fetch("kind"), "locale" => document.fetch("locale"),
      "url" => "https://#{request.fetch("webHost")}#{route.fetch("path")}",
      "sourceDigest" => document.fetch("digest")
    }
  end
  publication = {
    "schemaVersion" => 1, "handoffId" => request.fetch("handoffId"),
    "requestDigest" => "sha256:#{Digest::SHA256.file(ENV.fetch("REQUEST")).hexdigest}",
    "promptDigest" => ENV.fetch("PROMPT_DIGEST"),
    "webIssueURL" => "https://github.com/yuto1201/Web-AppLibrary/issues/34",
    "deploymentReference" => "https://github.com/yuto1201/Web-AppLibrary/pull/35",
    "userActions" => {
      "promptForwarded" => {"actor" => "user", "reference" => "https://github.com/yuto1201/iOS-PayCycle/issues/54#issuecomment-3", "at" => "2026-09-16T00:01:00Z"},
      "publicationApproved" => {"actor" => "user", "reference" => "https://github.com/yuto1201/iOS-PayCycle/issues/54#issuecomment-4", "at" => "2026-09-16T00:02:00Z"}
    },
    "pages" => pages
  }
  responses = pages.map do |page|
    document = request.fetch("documents").find { |candidate| candidate.values_at("kind", "locale") == page.values_at("kind", "locale") }
    root = File.dirname(File.dirname(File.dirname(ENV.fetch("REQUEST"))))
    text = File.binread(File.join(root, document.fetch("path"))).force_encoding(Encoding::UTF_8)
    links = pages.select { |candidate| candidate.fetch("locale") == page.fetch("locale") }
      .map { |candidate| %(<a href="#{candidate.fetch("url")}">#{candidate.fetch("kind")}</a>) }.join
    {"url" => page.fetch("url"), "finalURL" => page.fetch("url"), "status" => 200,
     "body" => "<html><body><main><pre>#{text}</pre>#{links}</main></body></html>"}
  end
  File.binwrite(ENV.fetch("PUBLICATION"), JSON.generate(publication))
  File.binwrite(ENV.fetch("RESPONSES"), JSON.generate({"schemaVersion" => 1, "responses" => responses}))
'

verification="$workspace/App Store/legal/publication-verification.json"
verified=$(
  "$entrypoint" verify-publication --repo-root "$workspace" --request "$request" --prompt "$prompt" \
    --issue-record "$issue_record" --publication "$publication" --response-fixture "$responses" \
    --output "$verification" --now 2026-09-16T00:03:00Z
)
[[ "$(jq -r .status <<<"$verified")" == fixture-validated ]]
[[ "$(jq -r .appStoreEligible <<<"$verified")" == false ]]
[[ "$(jq '.pages | length' <<<"$verified")" == 6 ]]
jq -e '.pages | all(.httpStatus == 200 and .contentMatched == true and (.interlinks | length) == 2)' <<<"$verified" >/dev/null

unauthorized="$workspace/responses-unauthorized.json"
jq '.responses[0].status=401' "$responses" > "$unauthorized"
if "$entrypoint" verify-publication --repo-root "$workspace" --request "$request" --prompt "$prompt" \
  --issue-record "$issue_record" --publication "$publication" --response-fixture "$unauthorized" \
  --output "$workspace/unauthorized.json" --now 2026-09-16T00:03:00Z 2>"$workspace/unauthorized.stderr"; then
  echo 'authenticated page was accepted' >&2
  exit 1
fi
rg -q 'HTTP 200' "$workspace/unauthorized.stderr"

missing_link="$workspace/responses-missing-link.json"
jq '.responses[0].body |= sub("<a href=\\\"https://app.example.com/apps/pay-cycle/en-US/terms/\\\">terms</a>"; "")' "$responses" > "$missing_link"
if "$entrypoint" verify-publication --repo-root "$workspace" --request "$request" --prompt "$prompt" \
  --issue-record "$issue_record" --publication "$publication" --response-fixture "$missing_link" \
  --output "$workspace/missing-link.json" --now 2026-09-16T00:03:00Z 2>"$workspace/missing-link.stderr"; then
  echo 'missing inter-page link was accepted' >&2
  exit 1
fi
rg -q 'interlink' "$workspace/missing-link.stderr"

wrong_content="$workspace/responses-wrong-content.json"
jq '.responses[0].body="<html><body><a href=\\\"https://app.example.com/apps/pay-cycle/en-US/privacy/\\\">privacy</a><a href=\\\"https://app.example.com/apps/pay-cycle/en-US/terms/\\\">terms</a>wrong</body></html>"' "$responses" > "$wrong_content"
if "$entrypoint" verify-publication --repo-root "$workspace" --request "$request" --prompt "$prompt" \
  --issue-record "$issue_record" --publication "$publication" --response-fixture "$wrong_content" \
  --output "$workspace/wrong-content.json" --now 2026-09-16T00:03:00Z 2>"$workspace/wrong-content.stderr"; then
  echo 'published content mismatch was accepted' >&2
  exit 1
fi
rg -q 'approved source text' "$workspace/wrong-content.stderr"

for path in \
  "$repo_root/.agents/skills/prepare-appstore-assets/templates/legal-page-handoff.md" \
  "$repo_root/App Store/legal/README.md"; do
  [[ -f "$path" ]] || { echo "legal handoff guidance is missing: $path" >&2; exit 1; }
done
rg -q 'prepare-appstore-legal-handoff\.sh' "$repo_root/.agents/skills/prepare-appstore-assets/SKILL.md"
rg -q 'fixture-validated.*not.*App Store|fixture-validated.*App Store.*not' "$repo_root/.agents/skills/prepare-appstore-assets/SKILL.md"
rg -q 'publication-verification' "$repo_root/.agents/skills/submit-appstore-release/SKILL.md"
rg -q 'yuto1201/Web-AppLibrary' "$repo_root/.agents/skills/prepare-appstore-assets/templates/legal-page-handoff.md"

echo 'App Store legal-page handoff tests passed'
