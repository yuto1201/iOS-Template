#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby swift

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$repo_root"

workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-ui-direction.XXXXXX")
spec_fixture_dir="$workspace/spec-fixture"
trap 'rm -rf -- "$workspace"' EXIT

skill=.agents/skills/ui-direction/SKILL.md
claude_skill=.claude/skills/ui-direction
expected_claude_target=../../.agents/skills/ui-direction
feature_form=.github/ISSUE_TEMPLATE/feature.yml
spec_checker=.agents/skills/spec-workflow/scripts/check-spec-state.sh
development_policy=specs/development-stages.md
acceptance_policy=specs/acceptance.md
architecture_policy=specs/architecture.md
workflow_policy=docs/workflow.md
verification_policy=docs/verification.md
review_packet_policy=docs/agent-contracts/review-packet.md

for required in \
  "$skill" \
  "$feature_form" \
  "$spec_checker" \
  "$development_policy" \
  "$acceptance_policy" \
  "$architecture_policy" \
  "$workflow_policy" \
  "$verification_policy" \
  "$review_packet_policy"; do
  [[ -f "$required" ]] || {
    echo "missing UI direction policy file: $required" >&2
    exit 1
  }
done

ruby -ryaml - "$skill" <<'RUBY'
path = ARGV.fetch(0)
text = File.binread(path)
frontmatter = text.match(/\A---\n(.*?)\n---\n/m)&.captures&.first
abort "missing UI direction skill frontmatter" unless frontmatter
data = YAML.safe_load(frontmatter, permitted_classes: [], aliases: false)
abort "UI direction skill frontmatter keys changed" unless data.keys.sort == %w[description name]
abort "unexpected UI direction skill name" unless data["name"] == "ui-direction"
description = data["description"]
abort "UI direction skill description must start with Use when" unless description.is_a?(String) && description.start_with?("Use when")

required_contracts = [
  ".artifacts/ui-direction/<flow-slug>/<revision>/comparison.html",
  "SHA-256",
  %q{default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; connect-src 'none'; font-src 'none'; form-action 'none'; base-uri 'none'; frame-src 'none'; object-src 'none'},
]
missing = required_contracts.reject { |value| text.include?(value) }
abort "UI direction skill lacks stable artifact contracts: #{missing.inspect}" unless missing.empty?
abort "UI direction skill must route specification changes through spec-workflow" unless text.match?(/\]\(\.\.\/spec-workflow\/SKILL\.md\)/)

contracts = {
  "canonical route declaration is exact and prefix-bound" => /declaration candidate is any existing acceptance-criterion text that begins with the exact `UI-direction route:` prefix.*immediately after its `AC-\*:` ID.*valid only in the exact form `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`.*`comparison`.*`explicit-skip`.*`confirmed-direction reuse`.*`bounded direction-neutral`.*`not-applicable`.*Incidental route words outside that prefix.*do not create a candidate/im,
  "legacy cutoff uses only sealed fetchedAt and prefix candidates" => /cutover is `2026-09-06T00:31:41Z`.*sealed Issue contract.*`fetchedAt` earlier.*zero candidates.*pre-D-030 legacy.*Do not infer a route, require retroactive HTML or a route declaration, or modify\/reseal.*earlier contract has one or more candidates.*reject unless exactly one candidate is fully valid.*malformed, unknown-route, empty Scope\/Reason, and multiple-candidate cases are not legacy.*at or after the cutoff has the same exactly-one and validity requirements.*only from sealed `fetchedAt` and prefix candidates/im,
  "explicit HTML request has highest priority" => /explicit current (?:user )?request for an HTML comparison is the highest-priority trigger/i,
  "confirmed scoped direction has a reuse route" => /confirmed UI direction\/specification covers the exact planned hierarchy and flow.*confirmed-direction reuse route.*post-cutover Claim.*acceptance-criterion text with `UI-direction route: confirmed-direction reuse; Scope: <nonempty>; Reason: <nonempty>`.*covered hierarchy\/flow.*confirmed UI-direction anchor/im,
  "unconfirmed direction groups all three structural triggers" => /scoped UI direction is unconfirmed.*app's first user-facing UI.*root navigation or information architecture.*materially redesigns a primary flow's structure or interaction/im,
  "unconfirmed nonstructural work has a direction-neutral route" => /scoped direction is unconfirmed and none of those structural triggers applies.*bounded direction-neutral UI route.*acceptance criteria do not decide hierarchy, navigation, or primary-flow interaction.*post-cutover Claim.*acceptance-criterion text with `UI-direction route: bounded direction-neutral; Scope: <nonempty>; Reason: <nonempty>`.*product\/behavior specification anchor/im,
  "structural trigger beats the apparent Issue classification" => /required trigger still applies.*form, regression, localization, or accessibility change/im,
  "explicit skip override is sealed before Claim" => /explicitly skips the comparison.*override the normal gate only when its scope, current applicability, and authority are unambiguous.*post-cutover Claim.*acceptance-criterion text with `UI-direction route: explicit-skip; Scope: <nonempty>; Reason: <nonempty>`.*currentness, authority, and lack of conflict after Reason.*confirmed product\/specification or Decision anchor.*blocked:user/im,
  "ambiguous coverage trigger or neutrality fails closed" => /If direction coverage, trigger applicability, or neutrality is ambiguous, fail closed by running the comparison gate/im,
  "Identity and non-UI work use exact Not applicable" => /post-cutover Claim.*not-applicable route.*Set the UI verification body to exactly `Not applicable`.*exact non-UI scope and reason in Goal\/In scope.*acceptance-criterion text with `UI-direction route: not-applicable; Scope: <nonempty>; Reason: <nonempty>`.*confirmed product\/specification anchor/im,
  "live UI verification is only convenience guidance" => /UI verification is live, unsealed guidance.*those words never count as a declaration.*Pre-Claim review checks both the live field and exactly one valid declaration in the fields to be sealed/im,
  "formal route reconstruction uses packet-visible inputs" => /Final review identifies the route only from that sealed AC-text prefix.*validates its Scope, Reason, and route-specific facts from the sealed Issue-contract Goal, acceptance criteria, Spec anchors, Dependencies, linked confirmed specifications\/Decision, and current-Head diff\/evidence/im,
  "brief fixes every acceptance-relevant input" => /confirm the product goal, target user and job, primary flow, screens and relevant states, content\/data assumptions, constraints, non-goals, and exact specification anchors/im,
  "brief uncertainty blocks before concept creation" => /unresolved choice can change acceptance criteria.*blocked:user/im,
  "comparison contains two or three stable concepts" => /Present two or three concepts with stable concept IDs/im,
  "comparison holds inputs and fidelity constant" => /Hold the viewport, task, content, data, states, and fidelity constant/im,
  "comparison requires a material structural difference" => /information hierarchy, navigation, or interaction materially different.*Cosmetic-only.*not distinct concepts/im,
  "each concept carries hypothesis and translation context" => /For each concept, state its hypothesis, trade-offs, intended iOS translation, accessibility considerations, and the limitations of the static prototype/im,
  "artifact uses synthetic data with no remote or active content" => /use synthetic data and inline HTML\/CSS\/JavaScript only.*do not include secrets, personal or production data, analytics, remote scripts, fonts, images, stylesheets, CSS URLs\/imports, network requests, form actions, meta refresh, `iframe`, `object`, or `embed` content/im,
  "presented bytes are immutable and digest identified" => /Treat the exact presented bytes as immutable.*SHA-256 digest and revision.*Never overwrite a revision that a user has seen.*new revision and requires a new selection/im,
  "selection requires exact concept or exact sourced hybrid" => /select one stable concept ID.*exact hybrid mapping that names each adopted element and its source concept ID/im,
  "non-selection responses stay unapproved" => /Praise, ranking, silence, or an approximate response.*is not approval.*hybrid is ambiguous.*new revision/im,
  "selection handoff carries common fields" => /Every selection record includes scope, artifact revision\/path, exact SHA-256 of the presented bytes, adopted and rejected elements, affected screens\/states, and allowed native adaptation/im,
  "single selection records its concept ID" => /single-concept selection records its selected concept ID/im,
  "hybrid selection records exhaustive sourced elements" => /hybrid instead records an exhaustive adopted-element-to-source-concept-ID mapping/im,
  "hybrid base ID is conditional" => /records a selected\/base concept ID only when the user explicitly chose one/im,
  "selection record has a separate merged specification change" => /separate specification Issue, Branch, and PR.*Merge that specification change before approving or claiming any dependent native UI Issue/im,
  "only dependent UI is blocked" => /Independent non-UI lanes may continue/im,
  "no new Issue field or HTML evidence schema" => /Do not add a special Issue-contract field or present the HTML as a canonical verification artifact/im,
  "confirmed spec is truth and HTML is never shipped" => /confirmed specification is the product truth.*native SwiftUI components.*do not embed the comparison in `WKWebView` or copy CSS pixels mechanically/im,
  "native proof stays bound to current Head" => /Current-Head Build, Test, Simulator, and required visual evidence remain the proof of the native implementation/im,
}

missing_contracts = contracts.reject { |_, pattern| text.match?(pattern) }.keys
abort "UI direction skill lacks behavioral contracts: #{missing_contracts.inspect}" unless missing_contracts.empty?
RUBY

ruby -E UTF-8 - "$development_policy" "$acceptance_policy" "$architecture_policy" "$workflow_policy" "$verification_policy" "$review_packet_policy" <<'RUBY'
# encoding: UTF-8
development_path, acceptance_path, architecture_path, workflow_path, verification_path, review_packet_path = ARGV
development = File.read(development_path, encoding: "UTF-8")
acceptance = File.read(acceptance_path, encoding: "UTF-8")
architecture = File.read(architecture_path, encoding: "UTF-8")
workflow = File.read(workflow_path, encoding: "UTF-8")
verification = File.read(verification_path, encoding: "UTF-8")
review_packet = File.read(review_packet_path, encoding: "UTF-8")

checks = {
  "canonical trigger priority" => [development, /ユーザー指示.*HTML比較.*確定済み方向の有無にかかわらず最優先/im],
  "canonical confirmed direction reuse route" => [development, /確定済みUI方向.*exact hierarchyとflowを覆う.*confirmed-direction reuse route.*Acceptance criterion本文を`UI-direction route: confirmed-direction reuse; Scope: <nonempty>; Reason: <nonempty>`で開始.*UI方向anchor.*Spec anchors/im],
  "canonical unconfirmed direction groups all three triggers" => [development, /exact scopeを覆う確定方向がなく.*対象範囲のUI方向が確定しておらず.*最初のユーザー向けUI.*navigation.*information hierarchy.*主要flow.*大幅に再設計/im],
  "canonical bounded direction-neutral route" => [development, /対象方向が未確定.*構造triggerを一つも満たさない.*Acceptance criteriaがhierarchy、navigation、primary-flow interactionを決めない.*bounded direction-neutral UI route.*Acceptance criterion本文を`UI-direction route: bounded direction-neutral; Scope: <nonempty>; Reason: <nonempty>`で開始.*非決定境界.*product.*behavior spec anchor.*Spec anchors/im],
  "canonical explicit skip override" => [development, /比較省略を明示.*対象scope、現行性、権限.*通常判定を上書き.*Acceptance criterion本文の先頭.*`UI-direction route: explicit-skip; Scope: <nonempty>; Reason: <nonempty>`で開始.*現行性、権限、比較指示との非矛盾.*Spec anchors.*blocked:user/im],
  "canonical Identity and non-UI route is exact Not applicable" => [development, /Identity bootstrapと純粋な非UI作業はnot-applicable route.*UI verification.*exact `Not applicable`.*対象scope.*非UIである理由.*Goal.*In scope.*Acceptance criterion.*product.*spec anchor.*Spec anchors/im],
  "canonical UI verification remains unsealed convenience" => [development, /UI verification.*Claim前.*live guidance.*Issue contractへ封印されない.*補助的.*最終レビューの根拠をこの節だけに置かない/im],
  "canonical route is reconstructable from packet fields" => [development, /Acceptance criteria全体でexactly oneの有効なroute宣言.*exact `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`.*`comparison`.*`explicit-skip`.*`confirmed-direction reuse`.*`bounded direction-neutral`.*`not-applicable`.*prefixに一致しない偶発的な語は宣言として数えない.*Spec anchors.*Dependencies.*review packetだけから宣言と根拠を復元可能/im],
  "canonical brief" => [development, /プロダクトの目的.*対象ユーザー.*task.*primary flow.*screen.*state.*content.*合成data.*制約.*non-goal.*spec anchor/im],
  "canonical comparable concepts" => [development, /同じtask、viewport、content、合成data、state集合.*2–3案.*同じfidelity.*安定したconcept ID.*information hierarchy、navigationまたはinteraction hypothesis.*実質的に異/im],
  "canonical safe immutable artifact" => [development, /credential.*秘密.*個人情報.*本番data.*tracking.*network依存.*revision path.*exact SHA-256.*上書きしない/im],
  "canonical exact selection alternatives" => [development, /一つのconcept ID.*採用する全要素.*source concept ID.*exhaustiveなhybrid/im],
  "canonical hybrid base is optional" => [development, /hybridにselected／base concept IDを要求するのは.*明示選択した場合だけ/im],
  "canonical common selection handoff" => [development, /対象scope、comparison path／revision、提示bytesのexact SHA-256、採用・不採用の要素、影響するscreen／state、native実装で許容する適応.*確定specと追記型Decision/im],
  "canonical single selection handoff" => [development, /単一案なら選択したconcept IDを記録/im],
  "canonical hybrid selection handoff" => [development, /hybridなら採用する全要素からsource concept IDへのexhaustive mappingを記録/im],
  "canonical hybrid base handoff" => [development, /ユーザーがbaseを明示選択した場合だけselected／base concept IDも記録/im],
  "canonical dependency ordering" => [development, /専用Issue、Branch、PRでマージ.*blocked:dependency.*approved.*Claim.*in-progress/im],
  "canonical D-030 cutoff is fetchedAt based" => [development, /D-030のcutoverは`2026-09-06T00:31:41Z`.*Issue contractの`fetchedAt`をUTC instantとして比較/im],
  "canonical pre-D-030 route-free contract is grandfathered" => [development, /cutoverより前かつAcceptance criterion本文がexact `UI-direction route:` prefixで始まる宣言候補がゼロの場合だけpre-D-030 legacy.*routeを推測・追記・再封印せず.*遡及的なHTML比較も要求せず.*元の封印済みAcceptance criteria、spec anchors、Dependenciesと証拠をそのまま検証/im],
  "canonical earlier candidates and at-cutoff contracts validate normally" => [development, /cutoverより前でも候補が一つ以上あれば通常のroute規則へ進み.*候補がexactly oneで完全な`UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`宣言.*候補の複数、許可外route、空のScope／Reasonはreject.*`fetchedAt`がcutoverと同時刻または後にも同じexactly-one／完全性を要求.*候補ゼロもreject/im],
  "definition of ready rejects incomplete selection" => [acceptance, /immutable revision.*exact SHA-256.*concept ID.*exhaustive hybrid.*確定spec.*追記型Decision.*曖昧または非網羅なhybrid.*Definition of Ready/im],
  "definition of ready preserves the D-030 legacy boundary" => [acceptance, /D-030 cutoverは`2026-09-06T00:31:41Z`.*`fetchedAt`がcutoverより前で、Acceptance criterion本文がexact `UI-direction route:` prefixで始まる宣言候補がゼロの場合はpre-D-030 legacy.*routeを推測せず.*遡及的なHTML比較やroute宣言を要求せず.*cutoverより前でも候補が一つ以上あれば通常規則.*候補がexactly oneで許可routeと非空Scope／Reasonを持つ完全な宣言でなければreject.*cutoverと同時刻または後.*同じexactly-one／完全性.*prefix外のroute語は候補として数えない/im],
  "architecture requires self-contained HTML" => [architecture, /self-contained HTML/im],
  "architecture requires network-denying CSP" => [architecture, /networkを拒否する制限的なContent Security Policy/im],
  "architecture excludes unsafe comparison data" => [architecture, /remote dependency、tracking、credential、秘密、個人情報、本番dataを含めない/im],
  "architecture separates decision input from native evidence" => [architecture, /decision input.*canonical iOS verification evidenceでもない.*確定specと追記型Decision/im],
  "architecture adds no Issue or evidence field" => [architecture, /新しいIssue-contract field.*mutableな未封印heading.*HTML用canonical evidence schemaを追加しない/im],
  "workflow records common handoff fields before merge" => [workflow, /scope、artifact path／revision ID、提示bytesのexact SHA-256、採用・不採用要素、対象画面／状態、native adaptation範囲.*確定仕様と追記型Decision.*独立Issue／Branch／PRでmerge.*approved.*Claim/im],
  "workflow preserves single versus hybrid alternatives" => [workflow, /単一案ではselected concept ID、hybridでは全採用要素からsource concept IDへのexhaustive mapping/im],
  "workflow preserves legacy without retroactive resealing" => [workflow, /D-030 cutover.*Issue #47.*`2026-09-06T00:31:41Z`.*`fetchedAt`をUTC instant.*cutoverより前でAcceptance criterion本文がexact `UI-direction route:` prefixで始まる宣言候補がゼロの場合だけpre-D-030 legacy.*routeを推測・追記・再封印せず.*HTML比較を遡及要求せず.*cutoverより前でも候補が一つ以上あれば通常検証.*候補がexactly oneかつ許可routeと非空Scope／Reasonを持つ完全な宣言でなければreject.*cutoverと同時刻以降.*同じexactly-one／完全性/im],
  "verification keeps native evidence current" => [verification, /decision-support artifact.*canonical evidenceにはなりません.*current-Head Build／Test／Simulator/im],
  "verification checks native intent rather than DOM" => [verification, /HTMLのDOMやCSSではなく.*情報階層.*主要task.*navigation.*代表state.*native画面.*digestが一致することだけではcase成功にしません/im],
  "verification applies the deterministic legacy cutoff" => [verification, /宣言候補はAcceptance criterion本文がexact `UI-direction route:` prefixで始まる場合だけ.*候補がexactly one.*exact `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`.*prefix外のroute語は候補として数えません.*D-030 cutover `2026-09-06T00:31:41Z`.*`fetchedAt`が前で候補がゼロの場合だけpre-D-030 legacy.*routeを推測せず.*HTMLやroute宣言を遡及要求せず.*cutover前でも候補が一つ以上あれば通常のroute検証.*malformed、unknown、multipleをreject.*cutoverと同時刻以降.*候補ゼロもreject/im],
  "review packet excludes live UI verification" => [review_packet, /liveな`UI verification`本文はIssue contractにもreview packetにも含めません/im],
  "review packet preserves the D-030 legacy boundary" => [review_packet, /declaration candidate is any existing acceptance-criterion text that begins with the exact `UI-direction route:` prefix.*valid only in the exact form `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`.*Incidental route words outside that prefix.*do not create a candidate.*`fetchedAt`.*`2026-09-06T00:31:41Z`.*earlier contract is pre-D-030 legacy only when it has zero candidates.*must not infer a route, demand retroactive HTML or a route declaration, or modify\/reseal.*earlier contract has one or more candidates.*reject unless exactly one candidate is fully valid.*malformed, unknown-route, empty Scope\/Reason, and multiple-candidate cases are not legacy.*at or after the cutoff has the same exactly-one and validity requirements/im],
  "review packet cutoff identity is deterministic" => [review_packet, /preserves the Issue-contract path and digest needed for that classification.*never substitutes Issue number, update time, file mtime, or live UI verification/im],
  "review packet exposes only sealed route inputs" => [review_packet, /For non-legacy contracts.*packet-bound Issue contract's Goal, Acceptance criteria, Spec anchors, Dependencies, linked confirmed spec\/Decision, current-Head diff, and evidence/im],
}

missing = checks.reject { |_, (text, pattern)| text.match?(pattern) }.keys
abort "UI direction repository policy lacks canonical contracts: #{missing.inspect}" unless missing.empty?
RUBY

[[ -L "$claude_skill" ]] || {
  echo "Claude UI direction skill must be a symbolic link" >&2
  exit 1
}
[[ $(readlink "$claude_skill") == "$expected_claude_target" ]] || {
  echo "Claude UI direction skill must use the portable shared target" >&2
  exit 1
}
[[ -f "$claude_skill/SKILL.md" ]] || {
  echo "Claude UI direction skill link does not resolve" >&2
  exit 1
}

relocated="$workspace/relocated"
mkdir -p "$relocated/.agents/skills" "$relocated/.claude/skills"
cp -R .agents/skills/ui-direction "$relocated/.agents/skills/ui-direction"
ln -s "$expected_claude_target" "$relocated/.claude/skills/ui-direction"
[[ $(readlink "$relocated/.claude/skills/ui-direction") == "$expected_claude_target" && -f "$relocated/.claude/skills/ui-direction/SKILL.md" ]] || {
  echo "Claude UI direction skill did not survive repository relocation" >&2
  exit 1
}

ruby -ryaml - "$feature_form" <<'RUBY'
path = ARGV.fetch(0)
form = YAML.safe_load(File.binread(path), permitted_classes: [], aliases: false)
body = form.fetch("body")
banner = body.find { |entry| entry["type"] == "markdown" }&.dig("attributes", "value")
banner_contracts = [
  /current user request for an HTML comparison takes priority regardless of an existing direction/i,
  /explicit skip overrides only with clear currentness, exact scope, authority, reason, and no conflicting comparison request/i,
  /confirmed-direction reuse when a confirmed specification covers the exact hierarchy\/flow/i,
  /gate an unconfirmed direction.*first user-facing UI.*root navigation\/information architecture.*materially redesigns a primary flow/im,
  /bounded direction-neutral UI.*none of those triggers applies.*acceptance decides no hierarchy, navigation, or primary-flow interaction/im,
  /Ambiguity gates.*Identity\/bootstrap and pure non-UI work use not-applicable/im,
]
unless banner.is_a?(String) && banner_contracts.all? { |pattern| banner.match?(pattern) }
  abort "Feature form banner lacks the conditional pre-Claim UI direction gate"
end

fields = body.select { |entry| entry.key?("id") }
expected_ids = %w[
  goal
  in-scope
  out-of-scope
  acceptance-criteria
  spec-anchors
  dependencies
  ui-verification
  delivery-stage
  delivery-profile
  verification-scope
  verification
  external-operations
  user-approvals
]
actual_ids = fields.map { |entry| entry.fetch("id") }
abort "Feature form field IDs or ordering changed: #{actual_ids.inspect}" unless actual_ids == expected_ids

required_ids = %w[
  goal
  in-scope
  out-of-scope
  acceptance-criteria
  spec-anchors
  dependencies
  ui-verification
  delivery-stage
  delivery-profile
  external-operations
  user-approvals
]
actual_required_ids = fields.each_with_object([]) do |entry, result|
  result << entry.fetch("id") if entry.dig("validations", "required") == true
end
unless actual_required_ids == required_ids
  abort "Feature form required fields changed: #{actual_required_ids.inspect}"
end

descriptions = fields.to_h do |entry|
  [entry.fetch("id"), entry.dig("attributes", "description").to_s]
end
description_contracts = {
  "acceptance-criteria" => [
    /at or after the `2026-09-06T00:31:41Z` cutover.*exactly one valid declaration across existing ACs/i,
    /start one AC text immediately after its ID with `AC-1: UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`/i,
    /`comparison`.*`explicit-skip`.*`confirmed-direction reuse`.*`bounded direction-neutral`.*`not-applicable`/i,
    /Incidental route words elsewhere do not count/i,
  ],
  "spec-anchors" => [
    /\.agents\/skills\/ui-direction\/SKILL\.md/,
    /`comparison` links the merged selection specification and Decision.*exact presented-bytes SHA-256.*element decisions/i,
    /`confirmed-direction reuse` links the exact reusable UI-direction anchor/i,
    /`bounded direction-neutral` links the relevant confirmed product\/behavior requirement/i,
    /`explicit-skip` links its confirmed product\/specification or Decision basis/i,
    /`not-applicable` links the relevant product\/specification requirement without requiring a UI-direction anchor/i,
    /comparison HTML.*alone are not spec anchors/i,
  ],
  "dependencies" => [
    /prerequisite Issues and blockers/i,
    /gated native UI Issue depends on the merged direction-selection specification Issue/i,
  ],
  "ui-verification" => [
    /every UI Issue.*exactly three ordered lines.*Target screens\/states.*English expectations.*Japanese expectations/i,
    /live guidance.*not part of the sealed Issue contract or review packet/i,
    /authoritative `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>` declaration at the start of one existing AC.*route-specific facts after Reason.*anchors in Spec anchors.*prerequisite Issues in Dependencies/i,
    /Identity\/bootstrap or pure non-UI work.*exactly `Not applicable` and nothing else.*scope\/non-UI reason in Goal\/In scope.*start one AC with `UI-direction route: not-applicable; Scope: <nonempty>; Reason: <nonempty>`.*product\/specification anchor in Spec anchors/i,
  ],
}

description_contracts.each do |id, patterns|
  missing = patterns.reject { |pattern| descriptions.fetch(id).match?(pattern) }
  abort "Feature form #{id} lacks UI direction contracts: #{missing.inspect}" unless missing.empty?
end
RUBY

workflow_routes=(
  .agents/skills/app-bootstrap/SKILL.md
  .agents/skills/plan-issue-batch/SKILL.md
  .agents/skills/ship-issue/SKILL.md
  .agents/skills/ship-issue-batch/SKILL.md
)
reviewer_routes=(
  docs/agent-contracts/spec-reviewer.md
  docs/agent-contracts/ios-reviewer.md
  docs/agent-contracts/visual-reviewer.md
  docs/agent-contracts/acceptance-auditor.md
)

ruby - "${workflow_routes[@]}" -- "${reviewer_routes[@]}" <<'RUBY'
separator = ARGV.index("--")
abort "missing route separator" unless separator
workflow_routes = ARGV[0...separator]
reviewer_routes = ARGV[(separator + 1)..]

workflow_contracts = {
  ".agents/skills/app-bootstrap/SKILL.md" => [
    /\]\(\.\.\/ui-direction\/SKILL\.md\)/,
    /resuming an already sealed bootstrap contract.*`fetchedAt`.*`2026-09-06T00:31:41Z`.*declaration candidate is any AC text beginning with exact `UI-direction route:`.*fully valid only in form `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`.*Incidental route words outside the prefix do not create a candidate.*earlier contract with zero candidates is pre-D-030 legacy.*do not add a not-applicable declaration, require retroactive HTML, or modify\/reseal.*earlier contract has one or more candidates.*reject unless exactly one is fully valid.*malformed, unknown-route, empty Scope\/Reason, and multiple-candidate cases are not legacy.*at or after the cutoff has the same exactly-one and validity requirements/im,
    /Identity bootstrap itself as non-UI work.*exactly `Not applicable`.*scope and non-UI reason in Goal\/In scope.*acceptance-criterion text immediately after its `AC-\*:` ID with `UI-direction route: not-applicable; Scope: <nonempty>; Reason: <nonempty>`.*product\/specification anchor in Spec anchors.*no confirmed UI-direction anchor/im,
    /explicit user request for HTML comparison takes priority.*explicit skip overrides.*current applicability, scope, authority, reason.*no conflicting comparison request/im,
    /confirmed-direction reuse.*confirmed spec covers the exact hierarchy\/flow.*gate.*direction is unconfirmed.*first-UI.*root-navigation\/information-architecture.*material primary-flow.*bounded direction-neutral.*unconfirmed.*no structural trigger.*acceptance does not decide hierarchy, navigation, or primary-flow interaction.*Ambiguity fails closed/im,
    /exactly one valid declaration across the existing acceptance criteria.*begin an AC text with exact `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`.*prefix-external route words do not count.*confirmed anchors in Spec anchors.*selection prerequisite in Dependencies/im,
    /UI Issues retain the exact ordered `Target screens\/states`, `English expectations`, and `Japanese expectations` UI verification fields as live guidance.*pre-Claim review checks both them and the authoritative declaration to be sealed/im,
    /single selection adds selected concept ID.*hybrid adds an exhaustive adopted-element-to-source-concept-ID mapping.*only adds a selected\/base ID when the user chose one/im,
  ],
  ".agents/skills/plan-issue-batch/SKILL.md" => [
    /\]\(\.\.\/ui-direction\/SKILL\.md\)/,
    /planned for Claim after the `2026-09-06T00:31:41Z` cutover requires exactly one fully valid declaration across its existing acceptance criteria.*one AC text, immediately after its `AC-\*:` ID, starts with exact `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`.*five values allowed by `ui-direction`.*Any AC text beginning exact `UI-direction route:` is a candidate.*incidental route words outside that prefix do not create one/im,
    /explicit comparison request always gates.*explicit skip overrides.*currentness, scope, authority, reason.*lack of conflict/im,
    /confirmed-direction reuse.*confirmed spec covers the exact hierarchy\/flow.*unconfirmed direction.*first-UI.*root-navigation\/information-architecture.*material primary-flow trigger.*bounded direction-neutral.*unconfirmed direction with no structural trigger.*acceptance does not decide hierarchy, navigation, or primary-flow interaction.*Ambiguity gates/im,
    /valid declaration.*route-specific facts may follow Reason.*confirmed anchors in Spec anchors.*selection prerequisites in Dependencies/im,
    /UI Issues retain the exact ordered `Target screens\/states`, `English expectations`, and `Japanese expectations` UI verification fields as live guidance.*pre-Claim review checks both them and the declaration to be sealed/im,
    /Identity\/bootstrap and pure non-UI nodes.*exact `Not applicable`.*scope\/non-UI reason in Goal\/In scope.*one AC text with `UI-direction route: not-applicable; Scope: <nonempty>; Reason: <nonempty>`.*product\/specification anchor in Spec anchors.*may continue independently/im,
    /separate specification\/Decision Issue.*single selection adds selected concept ID.*hybrid adds an exhaustive adopted-element-to-source-concept-ID mapping.*selected\/base ID only if explicitly chosen/im,
    /Do not invent a new Issue field/im,
    /Do not rewrite an already sealed contract.*fetched before the cutoff with zero candidates is pre-D-030 legacy.*earlier contract has any candidate.*validate normally and reject malformed, unknown-route, empty Scope\/Reason, or multiple candidates rather than treating it as legacy/im,
  ],
  ".agents/skills/ship-issue/SKILL.md" => [
    /\]\(\.\.\/ui-direction\/SKILL\.md\)/,
    /sealed Issue contract `fetchedAt`.*Any AC text beginning exact `UI-direction route:` is a declaration candidate.*fully valid only in form `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`.*Incidental route words outside the prefix do not create a candidate.*earlier than `2026-09-06T00:31:41Z`.*zero candidates.*pre-D-030 legacy without inferring a route, demanding retroactive HTML\/route declaration, or modifying\/resealing.*earlier contract has one or more candidates.*reject unless exactly one is fully valid.*malformed, unknown-route, empty Scope\/Reason, and multiple-candidate cases are not legacy.*at or after the cutoff has the same exactly-one and validity requirements/im,
    /explicit user request for HTML comparison takes priority.*explicit user skip overrides.*currentness, exact scope, authority, reason.*lack of conflict/im,
    /confirmed-direction reuse.*exact planned hierarchy and flow.*direction is unconfirmed.*first user-facing UI.*root navigation\/information architecture.*materially redesigns a primary flow.*direction is unconfirmed.*no structural trigger.*bounded direction-neutral.*acceptance does not decide hierarchy, navigation, or primary-flow interaction.*coverage, trigger applicability, or neutrality is ambiguous.*gate/im,
    /not-applicable route.*exactly `Not applicable`.*scope\/non-UI reason in Goal\/In scope.*product\/specification anchor in Spec anchors.*no UI-direction anchor/im,
    /exactly one valid declaration across the sealed acceptance criteria.*allowed route, nonempty Scope\/Reason.*never identify a route from bare words outside the AC-text prefix.*confirmed anchors in Spec anchors.*selection prerequisite in Dependencies/im,
    /single selection adds selected concept ID.*hybrid adds an exhaustive adopted-element-to-source-concept-ID mapping.*selected\/base ID only when.*explicitly chose one/im,
    /UI verification for a UI Issue remains the exact ordered `Target screens\/states`, `English expectations`, and `Japanese expectations` live guidance.*not sealed into the Issue contract.*Pre-Claim checks both that live guidance and the authoritative declaration to be sealed.*final review identifies the route only from that packet-sealed AC-text prefix.*Goal, acceptance criteria, Spec anchors, Dependencies, linked confirmed specifications\/Decision, and current-Head evidence/im,
    /Do not Claim or implement until `spec-workflow`/im,
    /native SwiftUI.*never ship the comparison HTML.*acceptance evidence/im,
  ],
  ".agents/skills/ship-issue-batch/SKILL.md" => [
    /\]\(\.\.\/ui-direction\/SKILL\.md\)/,
    /For each sealed node, compare `fetchedAt` with `2026-09-06T00:31:41Z`.*Any AC text beginning exact `UI-direction route:` is a declaration candidate.*fully valid only in form `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`.*Incidental route words outside the prefix do not create a candidate.*earlier with zero candidates is pre-D-030 legacy.*do not infer a route, demand retroactive HTML\/route declaration, or modify\/reseal.*earlier node has one or more candidates.*reject unless exactly one is fully valid.*malformed, unknown-route, empty Scope\/Reason, and multiple-candidate cases are not legacy.*at or after the cutoff has the same exactly-one and validity requirements/im,
    /explicit comparison always gates.*explicit skip overrides.*exact confirmed hierarchy\/flow coverage uses confirmed-direction reuse.*direction is unconfirmed.*first user-facing UI.*root navigation\/information architecture.*materially redesigning a primary flow.*gates.*without any of those three triggers.*bounded direction-neutral UI.*Ambiguity gates/im,
    /at or after the cutoff has the same exactly-one and validity requirements.*confirmed anchors in Spec anchors.*selection prerequisite in Dependencies.*dependency is `done`/im,
    /single selection adds selected concept ID.*hybrid adds an exhaustive adopted-element-to-source-concept-ID mapping.*selected\/base ID if explicitly chosen/im,
    /UI Issues keep the exact ordered `Target screens\/states`, `English expectations`, and `Japanese expectations` UI verification fields as live guidance.*post-cutover pre-Claim checks them plus the declaration to be sealed/im,
    /Identity\/bootstrap and pure non-UI nodes.*exact `Not applicable`.*scope\/non-UI reason in Goal\/In scope.*one AC text with `UI-direction route: not-applicable; Scope: <nonempty>; Reason: <nonempty>`.*product\/specification anchor in Spec anchors.*independent non-UI lanes may continue/im,
    /fast lane never weakens an individual Issue gate/im,
  ],
}

reviewer_contracts = {
  "docs/agent-contracts/spec-reviewer.md" => [
    /\]\(\.\.\/\.\.\/\.agents\/skills\/ui-direction\/SKILL\.md\)/,
    /All pre-Claim reviews performed after `2026-09-06T00:31:41Z` require exactly one valid route declaration before Claim.*declaration candidate is any existing acceptance-criterion text that begins with the exact `UI-direction route:` prefix.*valid only in the exact form `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`.*Incidental route words outside that prefix do not create a candidate/im,
    /later packet review.*sealed Issue contract `fetchedAt`.*earlier contract is pre-D-030 legacy only when it has zero candidates.*without inferring a route, requiring retroactive HTML, or modifying\/resealing it.*earlier contract has one or more candidates.*reject a malformed declaration, unknown route, empty Scope\/Reason, or multiple candidates.*at or after the cutoff has the same exactly-one and validity requirements/im,
    /Explicit comparison always gates.*explicit skip overrides.*currentness, scope, authority, reason.*lack of conflict/im,
    /confirmed hierarchy\/flow coverage uses confirmed-direction reuse.*unconfirmed direction plus any first-UI\/root-navigation-or-information-architecture\/material-primary-flow trigger gates.*unconfirmed direction without a structural trigger permits bounded direction-neutral UI.*Ambiguity gates/im,
    /Before Claim after the cutoff, validate both the live UI verification format and the authoritative route declaration in the contract fields that will be sealed/im,
    /UI work uses exactly the three ordered fields.*Identity\/bootstrap or pure non-UI uses exactly `Not applicable`/im,
    /Across all acceptance criteria, require exactly one valid declaration with an allowed route and nonempty Scope\/Reason.*route-specific facts after Reason.*Do not identify a route from incidental words or a declaration outside the AC-text prefix.*Spec anchors.*confirmed anchors.*Dependencies.*selection prerequisite/im,
    /Never treat live UI verification as sealed evidence or add a field/im,
    /merged confirmed selection record.*common fields.*artifact path\/revision.*exact presented-bytes SHA-256.*adopted\/rejected elements.*screens\/states.*native adaptation/im,
    /single selection records selected concept ID.*hybrid records an exhaustive adopted-element-to-source-concept-ID mapping.*selected\/base ID only if explicitly chosen/im,
    /Comparison HTML alone is not approval or a specification anchor/im,
    /direction-selection Issue precedes every dependent native UI Issue/im,
    /For a post-cutover pre-Claim review, approve only.*fields to be sealed contain exactly one valid route declaration at an AC-text prefix.*For any later packet review, disregard the live body and use only packet-sealed contract data and authorized references.*exactly one valid declaration for a non-legacy contract.*qualifying pre-D-030 legacy contract.*must not be rejected for lacking a declaration/im,
  ],
  "docs/agent-contracts/ios-reviewer.md" => [
    /\]\(\.\.\/\.\.\/\.agents\/skills\/ui-direction\/SKILL\.md\)/,
    /sealed Issue contract `fetchedAt`.*declaration candidate is any acceptance-criterion text that begins with exact `UI-direction route:`.*valid only in form `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`.*Incidental route words outside that prefix do not create a candidate.*earlier than `2026-09-06T00:31:41Z`.*zero candidates.*pre-D-030 legacy.*do not infer a route, demand retroactive HTML\/route declaration, or modify\/reseal.*earlier contract has one or more candidates.*reject unless exactly one candidate is fully valid.*malformed, unknown-route, empty Scope\/Reason, and multiple-candidate cases are not legacy.*at or after the cutoff has the same exactly-one and validity requirements/im,
    /identify the route only from the valid declaration and validate it from packet-sealed Goal, acceptance criteria, Spec anchors, Dependencies, linked confirmed specifications\/Decision, and current-Head diff\/evidence/im,
    /Never rely on live UI verification, which is absent from the packet/im,
    /explicit comparison always gates.*explicit skip overrides.*confirmed hierarchy\/flow coverage uses confirmed-direction reuse.*direction is unconfirmed.*first user-facing UI.*root navigation\/information architecture.*materially redesigning a primary flow.*gates.*without any of those three triggers.*bounded direction-neutral UI.*Ambiguity is gated/im,
    /exactly one valid declaration across the sealed acceptance criteria.*nonempty Scope\/Reason.*route-specific.*confirmed anchors.*completed selection dependency/im,
    /common selection record: scope, artifact path\/revision, exact presented-bytes SHA-256, adopted\/rejected elements, affected screens\/states, and allowed native adaptation/im,
    /single selection adds selected concept ID.*hybrid adds an exhaustive adopted-element-to-source-concept-ID mapping.*selected\/base ID only if explicitly chosen/im,
    /SwiftUI hierarchy, flow, and relevant states.*linked confirmed specification\/Decision/im,
    /native adaptation.*HTML\/WKWebView.*CSS-pixel/im,
    /current-Head native Build\/Test\/Simulator evidence/im,
    /not-applicable Identity\/bootstrap or pure non-UI work.*scope\/reason from sealed Goal\/AC and the diff.*product\/specification anchor.*never require a UI-direction anchor/im,
    /Approve only when.*non-legacy contract additionally requires packet-visible sealed evidence for exactly one valid UI-direction declaration.*qualifying pre-D-030 legacy contract.*must not be rejected only for lacking a declaration/im,
  ],
  "docs/agent-contracts/visual-reviewer.md" => [
    /\]\(\.\.\/\.\.\/\.agents\/skills\/ui-direction\/SKILL\.md\)/,
    /"acceptanceCriteria":\s*\[\s*\{"id": "AC-1", "text": "UI-direction route: confirmed-direction reuse; Scope: [^";]+; Reason: [^"]+"\}/m,
    /sealed Issue contract `fetchedAt`.*declaration candidate is any acceptance-criterion text that begins with exact `UI-direction route:`.*valid only in form `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`.*Incidental route words outside that prefix do not create a candidate.*earlier than `2026-09-06T00:31:41Z`.*zero candidates.*pre-D-030 legacy.*do not infer a route, demand retroactive HTML\/route declaration, or modify\/reseal.*earlier contract has one or more candidates.*reject unless exactly one candidate is fully valid.*malformed, unknown-route, empty Scope\/Reason, and multiple-candidate cases are not legacy.*at or after the cutoff has the same exactly-one and validity requirements/im,
    /identify the route only from that valid AC-text prefix, never from bare route words, then validate it using packet-sealed Goal, acceptance criteria, Spec anchors, Dependencies, linked confirmed specifications\/Decision, and current-Head diff\/evidence/im,
    /Live UI verification is absent from the packet and is never review evidence/im,
    /explicit comparison always gates.*explicit skip overrides.*confirmed hierarchy\/flow coverage uses confirmed-direction reuse.*direction is unconfirmed.*first user-facing UI.*root navigation\/information architecture.*materially redesigning a primary flow.*gates.*without any of those three triggers.*bounded direction-neutral UI.*Ambiguity is gated/im,
    /exactly one valid declaration across the sealed acceptance criteria.*nonempty Scope\/Reason.*confirmed-direction reuse.*UI-direction anchor.*bounded direction-neutral UI.*product\/behavior anchor/im,
    /not-applicable Identity\/bootstrap or pure non-UI work.*scope\/reason from sealed Goal\/AC and diff.*product\/specification anchor.*never require a UI-direction anchor/im,
    /common scope, artifact path\/revision, exact presented-bytes SHA-256, adopted\/rejected elements, screens\/states, and allowed native adaptation/im,
    /single selection adds selected concept ID.*hybrid adds an exhaustive adopted-element-to-source-concept-ID mapping.*selected\/base ID only if explicitly chosen/im,
    /selected hierarchy, flow, and states.*confirmed specification\/Decision.*documented native adaptation/im,
    /do not demand CSS-pixel parity or treat the HTML comparison as native evidence/im,
    /For another route identified by a valid declaration, do not invent comparison requirements/im,
    /For approval, a non-legacy contract's packet-visible sealed evidence must support exactly one valid UI-direction declaration.*qualifying pre-D-030 legacy contract.*must not be rejected only for lacking a declaration/im,
  ],
  "docs/agent-contracts/acceptance-auditor.md" => [
    /\]\(\.\.\/\.\.\/\.agents\/skills\/ui-direction\/SKILL\.md\)/,
    /sealed Issue contract `fetchedAt`.*declaration candidate is any acceptance-criterion text that begins with exact `UI-direction route:`.*valid only in form `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`.*Incidental route words outside that prefix do not create a candidate.*earlier than `2026-09-06T00:31:41Z`.*zero candidates.*pre-D-030 legacy.*do not infer a route, demand retroactive HTML\/route declaration, or modify\/reseal.*earlier contract has one or more candidates.*reject unless exactly one candidate is fully valid.*malformed, unknown-route, empty Scope\/Reason, and multiple-candidate cases are not legacy.*at or after the cutoff has the same exactly-one and validity requirements/im,
    /identify the route only from the valid AC-text declaration, then validate.*from packet-sealed Goal, acceptance criteria, Spec anchors, Dependencies, linked confirmed specifications\/Decision, and the current-Head diff\/evidence/im,
    /review packet does not contain live UI verification; never infer or require it here/im,
    /packet-supported current explicit comparison always gates.*packet-supported explicit skip overrides.*confirmed hierarchy\/flow coverage uses confirmed-direction reuse.*direction is unconfirmed.*first user-facing UI.*root navigation\/information architecture.*materially redesigning a primary flow.*gates.*without any of those three triggers.*bounded direction-neutral UI.*Ambiguity is a blocking gated classification/im,
    /exactly one valid declaration across the sealed acceptance criteria.*AC-text prefix.*never bare route words elsewhere.*nonempty Scope\/Reason.*confirmed anchors in Spec anchors.*selection prerequisite in Dependencies/im,
    /common scope, artifact path\/revision, exact presented-bytes SHA-256, adopted\/rejected elements, screens\/states, and native adaptation.*single selection adds selected concept ID.*hybrid adds an exhaustive adopted-element-to-source-concept-ID mapping.*selected\/base ID only if explicitly chosen/im,
    /not-applicable Identity\/bootstrap or pure non-UI work.*scope\/reason from sealed Goal\/AC and the diff.*product\/specification anchor.*without requiring a UI-direction anchor/im,
    /HTML bytes or CSS fidelity.*current-Head native implementation evidence/im,
    /Approve only if.*non-legacy contract must have packet-visible sealed evidence for exactly one valid UI-direction declaration.*qualifying pre-D-030 legacy contract.*must not be rejected only for lacking a declaration/im,
  ],
}

unless workflow_routes == workflow_contracts.keys
  abort "workflow route inventory changed: #{workflow_routes.inspect}"
end
unless reviewer_routes == reviewer_contracts.keys
  abort "reviewer route inventory changed: #{reviewer_routes.inspect}"
end

(workflow_contracts.merge(reviewer_contracts)).each do |path, patterns|
  text = File.binread(path)
  missing = patterns.reject { |pattern| text.match?(pattern) }
  abort "UI direction route lacks minimum contracts: #{path}: #{missing.inspect}" unless missing.empty?
end

formal_reviewers = %w[
  docs/agent-contracts/ios-reviewer.md
  docs/agent-contracts/visual-reviewer.md
  docs/agent-contracts/acceptance-auditor.md
]
formal_reviewers.each do |path|
  text = File.binread(path)
  if text.match?(/classif(?:y|ication).*from (?:the )?sealed UI verification/im) ||
      text.match?(/(?:may|can|must|should)\s+(?:inspect|read|use|validate|check|consult|require|rely on)[^.\n]{0,160}live UI verification/i) ||
      text.match?(/live UI verification[^.\n]{0,160}(?:is available|is present|packet-visible|sealed evidence)/i) ||
      text.match?(/require.*`UI verification: Not applicable`/im)
    abort "formal reviewer falsely claims packet access to live/sealed UI verification: #{path}"
  end
end
RUBY

swift tools/check-markdown-links.swift "$skill" "$review_packet_policy" "${workflow_routes[@]}" "${reviewer_routes[@]}"

fixture_spec_checker="$spec_fixture_dir/.agents/skills/spec-workflow/scripts/check-spec-state.sh"
selection_spec_relative=specs/features/onboarding-ui.md
selection_decision_relative=specs/decisions.md
selection_spec="$spec_fixture_dir/$selection_spec_relative"
selection_decision="$spec_fixture_dir/$selection_decision_relative"
comparison_relative=.artifacts/ui-direction/onboarding/rev-20260906-01/comparison.html
comparison_fixture="$spec_fixture_dir/$comparison_relative"
mkdir -p \
  "$(dirname "$fixture_spec_checker")" \
  "$(dirname "$selection_spec")" \
  "$(dirname "$comparison_fixture")"
cp "$spec_checker" "$fixture_spec_checker"

cat > "$comparison_fixture" <<'EOF'
<!doctype html>
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'none'; img-src data:; connect-src 'none'; font-src 'none'; form-action 'none'; base-uri 'none'; frame-src 'none'; object-src 'none'">
<title>Onboarding direction comparison</title>
<main><section id="concept-a">A</section><section id="concept-b">B</section><section id="concept-c">C</section></main>
EOF
comparison_digest=$(shasum -a 256 "$comparison_fixture" | awk '{print $1}')

cat > "$selection_spec" <<EOF
# App UI Direction

Status: 確定

## Selected primary flow

Status: 確定

- Scope: Onboarding primary flow on iPhone.
- Comparison path: \`$comparison_relative\`
- Revision: \`rev-20260906-01\`
- SHA-256: \`sha256:$comparison_digest\`
- Selection mode: exact hybrid with no selected/base concept.
- Adopted elements (exhaustive hybrid mapping):
  - Task-first information hierarchy (source concept ID: \`concept-a\`).
  - Inline progress disclosure (source concept ID: \`concept-a\`).
  - Compact help affordance (borrowed; source concept ID: \`concept-b\`).
- Rejected elements:
  - Dashboard-first hierarchy from \`concept-c\`.
- Affected screens/states:
  - Welcome screen: initial and returning-user states.
  - Permission screen: allowed and denied states.
- Native adaptation:
  - Translate the selected hierarchy and states into SwiftUI navigation, Dynamic Type, VoiceOver, Safe Area, and system sheet semantics; do not copy CSS pixels.

## Candidate awaiting selection

Status: 未決

Implementation acceptance still depends on the user choice.
EOF

cat > "$selection_decision" <<'EOF'
# Decision log

Status: 確定

## D-030: Confirm onboarding hybrid

Status: 確定

- Record: Append-only selection Decision; any later change requires a later Decision entry.
- Decision: Adopt the exhaustive hybrid recorded by the confirmed onboarding UI specification.
- Prerequisite: Direction-selection Issue #44 is merged and done.
EOF

ruby -E UTF-8 - "$selection_spec" "$selection_decision" "$comparison_fixture" "$comparison_digest" <<'RUBY'
# encoding: UTF-8
require "digest"

spec_path, decision_path, comparison_path, expected_digest = ARGV
text = File.read(spec_path, encoding: "UTF-8")
decision = File.read(decision_path, encoding: "UTF-8")
actual_digest = Digest::SHA256.file(comparison_path).hexdigest
abort "confirmed selection fixture digest does not identify the exact HTML bytes" unless actual_digest == expected_digest

contracts = {
  "scope" => /Scope: Onboarding primary flow on iPhone/,
  "artifact path" => %r{Comparison path: `\.artifacts/ui-direction/onboarding/rev-20260906-01/comparison\.html`},
  "revision" => /Revision: `rev-20260906-01`/,
  "exact SHA-256" => /SHA-256: `sha256:#{Regexp.escape(expected_digest)}`/,
  "hybrid selection mode without a base concept" => /Selection mode: exact hybrid with no selected\/base concept/,
  "exhaustive adopted elements with source IDs" => /Adopted elements \(exhaustive hybrid mapping\):.*source concept ID: `concept-a`.*borrowed; source concept ID: `concept-b`/m,
  "rejected elements" => /Rejected elements:.*`concept-c`/m,
  "affected screens and states" => /Affected screens\/states:.*Welcome screen: initial and returning-user states.*Permission screen: allowed and denied states/m,
  "native adaptation" => /Native adaptation:.*SwiftUI navigation.*Dynamic Type.*VoiceOver.*Safe Area.*system sheet semantics.*do not copy CSS pixels/im,
}
missing = contracts.reject { |_, pattern| text.match?(pattern) }.keys
abort "confirmed selection fixture is incomplete: #{missing.inspect}" unless missing.empty?
abort "hybrid fixture must not invent a selected or base concept ID" if text.match?(/^- (?:Selected concept ID|Selected\/base concept ID):/im)
abort "selection Decision fixture must be confirmed and append-only" unless decision.match?(/Status: 確定.*Append-only selection Decision.*later Decision entry.*Issue #44 is merged and done/im)
RUBY

cat > "$workspace/direction-issue.md" <<'EOF'
## Goal

Use the comparison route for the primary-flow scope because its structural direction depended on an explicit selection.

## In scope

- Build one selected native SwiftUI shape.

## Out of scope

- Release-wide adaptation.

## Acceptance criteria

- AC-1: UI-direction route: comparison; Scope: Selected primary flow; Reason: The structural direction required the merged selection prerequisite; completed prerequisite #44 is done; the flow is operable on a Japanese iPhone.

## Spec anchors

- [Confirmed onboarding selection](specs/features/onboarding-ui.md#selected-primary-flow)
- [Append-only onboarding selection Decision](specs/decisions.md#d-030-confirm-onboarding-hybrid)

## Dependencies

- #44 done: merged direction-selection specification and append-only Decision.

## UI verification

- Target screens/states: Primary flow, loaded state.
- English expectations: Deferred to a focused harden Issue.
- Japanese expectations: The selected primary flow is complete in Japanese.

## Delivery stage

- Stage: shape
- Time budget: 120 minutes
- Reason: Produce the selected Japanese-iPhone primary flow.

## Delivery profile

- Profile: standard
- Reason: This is ordinary user-visible UI work.

## Verification scope

- Scope: iphone-ja
- Reason: Shape verifies one representative Japanese iPhone.

## Verification

{
  "bundleIdentifier": "com.example.Direction",
  "unitTestIdentifier": "DirectionTests/DirectionTests/testPrimaryFlow",
  "cases": [
    {"id": "iphone-ja", "testIdentifier": "DirectionUITests/DirectionSmokeTests/testPrimaryFlow"}
  ],
  "acceptanceMappings": [
    {"id": "AC-1", "checks": ["stage:build", "stage:unit-tests", "case:iphone-ja"]}
  ]
}

## External operations

- None.

## User approvals

- None.
EOF

ruby tools/lib/issue-contract.rb \
  --body "$workspace/direction-issue.md" \
  --type feature \
  --format contract \
  --issue 45 \
  --repo yuto1201/iOS-Template \
  --fetched-at 2026-09-06T00:31:41Z > "$workspace/direction-contract.json"

ruby -rjson - "$workspace/direction-contract.json" "$selection_spec" "$selection_decision" <<'RUBY'
contract = JSON.parse(File.binread(ARGV.fetch(0)))
selection_spec, selection_decision = ARGV.drop(1)
expected = [
  "specs/features/onboarding-ui.md#selected-primary-flow",
  "specs/decisions.md#d-030-confirm-onboarding-hybrid",
]
abort "confirmed selection specification and Decision are not sealed into the Issue contract" unless contract["specAnchors"] == expected
abort "sealed selection specification fixture disappeared" unless File.file?(selection_spec)
abort "sealed append-only Decision fixture disappeared" unless File.file?(selection_decision)
abort "sealed Goal must carry the UI route, scope, and reason" unless contract["goal"].match?(/comparison route.*primary-flow scope.*because.*explicit selection/i)
acceptance_text = contract.fetch("acceptanceCriteria").fetch(0).fetch("text")
abort "sealed AC must carry the canonical UI route declaration, scope, reason, and completed prerequisite" unless acceptance_text.match?(/\AUI-direction route: comparison; Scope: Selected primary flow; Reason: The structural direction required the merged selection prerequisite; completed prerequisite #44 is done/i)
abort "sealed Dependencies must carry the direction-selection prerequisite" unless contract["dependencies"] == [44]
abort "comparison contract must be at the D-030 cutoff" unless contract["fetchedAt"] == "2026-09-06T00:31:41Z"
abort "UI verification must remain live guidance, not a sealed Issue-contract field" if contract.key?("uiVerification")
RUBY

"$fixture_spec_checker" "$workspace/direction-issue.md" >/dev/null

cat > "$workspace/non-ui-fast-issue.md" <<'EOF'
## Goal

Audit the app Identity metadata within the repository configuration only because this is pure non-UI work.

## In scope

- Scope: Identity metadata in Config files and bootstrap documentation.
- Reason: The change validates repository Identity without creating or changing user-facing UI.

## Out of scope

- Any SwiftUI screen, navigation, interaction, or visual behavior.

## Acceptance criteria

- AC-1: UI-direction route: not-applicable; Scope: Identity metadata only; Reason: The work is pure non-UI; metadata remains internally consistent without changing application UI.

## Spec anchors

- [New app startup order](specs/product.md#31-新しいアプリの開始順序)

## Dependencies

- None.

## UI verification

Not applicable

## Delivery stage

- Stage: harden
- Time budget: 30 minutes
- Reason: Validate one narrow non-UI Identity concern.

## Delivery profile

- Profile: fast
- Reason: The work is local, low-risk, and purely non-UI.

## External operations

- None.

## User approvals

- None.
EOF

tools/validate-issue-body.sh --type feature "$workspace/non-ui-fast-issue.md" >/dev/null
ruby tools/lib/issue-contract.rb \
  --body "$workspace/non-ui-fast-issue.md" \
  --type feature \
  --format contract \
  --issue 46 \
  --repo yuto1201/iOS-Template \
  --fetched-at 2026-09-06T00:31:41Z > "$workspace/non-ui-fast-contract.json"

ruby -E UTF-8 -rjson - "$workspace/non-ui-fast-issue.md" "$workspace/non-ui-fast-contract.json" <<'RUBY'
# encoding: UTF-8
body = File.read(ARGV.fetch(0), encoding: "UTF-8")
contract = JSON.parse(File.binread(ARGV.fetch(1)))

ui_section = body[/^## UI verification\s*$\n(.*?)(?=^## |\z)/m, 1]&.strip
abort "non-UI fixture must use exact UI verification Not applicable" unless ui_section == "Not applicable"
abort "non-UI fixture Goal must carry exact scope and non-UI reason" unless body.match?(/^## Goal\s*$.*Identity metadata within the repository configuration only because this is pure non-UI work\./m)
abort "non-UI fixture In scope must carry scope and reason" unless body.match?(/^## In scope\s*$.*Scope: Identity metadata in Config files and bootstrap documentation\..*Reason: The change validates repository Identity without creating or changing user-facing UI\./m)

expected_anchor = ["specs/product.md#31-新しいアプリの開始順序"]
abort "non-UI fixture must seal its relevant product specification anchor" unless contract["specAnchors"] == expected_anchor
abort "non-UI fixture Goal was not sealed" unless contract["goal"] == "Audit the app Identity metadata within the repository configuration only because this is pure non-UI work."
acceptance_text = contract.fetch("acceptanceCriteria").fetch(0).fetch("text")
abort "non-UI fixture sealed AC must carry the canonical route declaration, scope, and reason" unless acceptance_text.match?(/\AUI-direction route: not-applicable; Scope: Identity metadata only; Reason: The work is pure non-UI/i)
abort "non-UI fixture has an unexpected prerequisite" unless contract["dependencies"] == []
abort "non-UI fixture must be an explicit fast profile" unless contract["deliveryProfile"] == {"name"=>"fast", "reason"=>"The work is local, low-risk, and purely non-UI."}
abort "non-UI fixture must use a non-shape stage" unless contract.dig("deliveryStage", "name") == "harden"
abort "fast non-UI contract must not seal application verification" if contract.key?("verification") || contract.key?("verificationScope")
abort "live UI verification must never enter the sealed contract" if contract.key?("uiVerification")
RUBY

cat > "$workspace/pre-d030-no-route-issue.md" <<'EOF'
## Goal

Preserve the original sealed primary-flow behavior for the existing application UI.

## In scope

- Keep the already accepted primary flow operable on its original Japanese iPhone scope.

## Out of scope

- Any new hierarchy, navigation, interaction, or visual direction.

## Acceptance criteria

- AC-1: The existing primary flow remains operable on a Japanese iPhone; incidental prose mentioning comparison, not-applicable, or another route is not a declaration.

## Spec anchors

- [Issue Definition of Done](specs/acceptance.md#3-issue-definition-of-done)

## Dependencies

- None.

## UI verification

- Target screens/states: Existing primary flow, loaded state.
- English expectations: Preserve the previously accepted behavior.
- Japanese expectations: Preserve the previously accepted behavior.

## Delivery stage

- Stage: shape
- Time budget: 120 minutes
- Reason: Preserve the originally accepted Japanese-iPhone flow.

## Delivery profile

- Profile: standard
- Reason: This is ordinary existing user-visible UI work.

## Verification scope

- Scope: iphone-ja
- Reason: The original sealed scope contains one Japanese iPhone case.

## Verification

{
  "bundleIdentifier": "com.example.LegacyDirection",
  "unitTestIdentifier": "LegacyDirectionTests/LegacyDirectionTests/testPrimaryFlow",
  "cases": [
    {"id": "iphone-ja", "testIdentifier": "LegacyDirectionUITests/LegacyDirectionSmokeTests/testPrimaryFlow"}
  ],
  "acceptanceMappings": [
    {"id": "AC-1", "checks": ["stage:build", "stage:unit-tests", "case:iphone-ja"]}
  ]
}

## External operations

- None.

## User approvals

- None.
EOF

ruby tools/lib/issue-contract.rb \
  --body "$workspace/pre-d030-no-route-issue.md" \
  --type feature \
  --format contract \
  --issue 43 \
  --repo yuto1201/iOS-Template \
  --fetched-at 2026-09-06T00:31:40Z > "$workspace/pre-d030-no-route-contract.json"
ruby tools/lib/issue-contract.rb \
  --body "$workspace/direction-issue.md" \
  --type feature \
  --format contract \
  --issue 45 \
  --repo yuto1201/iOS-Template \
  --fetched-at 2026-09-06T00:31:40Z > "$workspace/pre-d030-routed-contract.json"

awk '
  { print }
  /^- AC-1: UI-direction route: not-applicable;/ {
    print "- AC-2: UI-direction route: comparison; Scope: Identity metadata only; Reason: This conflicting declaration must be rejected."
  }
' "$workspace/non-ui-fast-issue.md" > "$workspace/multiple-route-issue.md"
sed 's/UI-direction route: not-applicable;/UI-direction route: sideways;/' \
  "$workspace/non-ui-fast-issue.md" > "$workspace/invalid-route-issue.md"

if ruby tools/lib/issue-contract.rb \
  --body "$workspace/pre-d030-no-route-issue.md" \
  --type feature \
  --format contract \
  --issue 43 \
  --repo yuto1201/iOS-Template \
  --fetched-at 2026-09-06T00:31:41Z \
  > "$workspace/at-cutoff-no-route.stdout" 2> "$workspace/at-cutoff-no-route.stderr"; then
  echo "contract at the D-030 cutoff accepted incidental route words without a declaration" >&2
  exit 1
fi
grep -Fq "UI-direction route declaration is required" "$workspace/at-cutoff-no-route.stderr" || {
  echo "missing-route rejection did not use the production route contract" >&2
  exit 1
}

if ruby tools/lib/issue-contract.rb \
  --body "$workspace/multiple-route-issue.md" \
  --type feature \
  --format contract \
  --issue 46 \
  --repo yuto1201/iOS-Template \
  --fetched-at 2026-09-06T00:31:41Z \
  > "$workspace/multiple-route.stdout" 2> "$workspace/multiple-route.stderr"; then
  echo "non-legacy contract accepted multiple canonical route declarations" >&2
  exit 1
fi
grep -Fq "exactly one UI-direction route declaration" "$workspace/multiple-route.stderr" || {
  echo "multiple-route rejection did not use the production route contract" >&2
  exit 1
}

if ruby tools/lib/issue-contract.rb \
  --body "$workspace/invalid-route-issue.md" \
  --type feature \
  --format contract \
  --issue 46 \
  --repo yuto1201/iOS-Template \
  --fetched-at 2026-09-06T00:31:41Z \
  > "$workspace/invalid-route.stdout" 2> "$workspace/invalid-route.stderr"; then
  echo "non-legacy contract accepted an invalid canonical route declaration" >&2
  exit 1
fi
grep -Fq "malformed UI-direction route declaration" "$workspace/invalid-route.stderr" || {
  echo "invalid-route rejection did not use the production route contract" >&2
  exit 1
}

if ruby tools/lib/issue-contract.rb \
  --body "$workspace/multiple-route-issue.md" \
  --type feature \
  --format contract \
  --issue 46 \
  --repo yuto1201/iOS-Template \
  --fetched-at 2026-09-06T00:31:40Z \
  > "$workspace/pre-cutoff-multiple-route.stdout" 2> "$workspace/pre-cutoff-multiple-route.stderr"; then
  echo "pre-cutoff contract treated multiple route-prefix candidates as legacy" >&2
  exit 1
fi
grep -Fq "exactly one UI-direction route declaration" "$workspace/pre-cutoff-multiple-route.stderr" || {
  echo "pre-cutoff multiple-route rejection did not use the production route contract" >&2
  exit 1
}

if ruby tools/lib/issue-contract.rb \
  --body "$workspace/invalid-route-issue.md" \
  --type feature \
  --format contract \
  --issue 46 \
  --repo yuto1201/iOS-Template \
  --fetched-at 2026-09-06T00:31:40Z \
  > "$workspace/pre-cutoff-invalid-route.stdout" 2> "$workspace/pre-cutoff-invalid-route.stderr"; then
  echo "pre-cutoff contract treated a malformed route-prefix candidate as legacy" >&2
  exit 1
fi
grep -Fq "malformed UI-direction route declaration" "$workspace/pre-cutoff-invalid-route.stderr" || {
  echo "pre-cutoff malformed-route rejection did not use the production route contract" >&2
  exit 1
}

ruby -Itools/lib -rissue-contract -rjson - \
  "$workspace/pre-d030-no-route-contract.json" \
  "$workspace/pre-d030-routed-contract.json" \
  "$workspace/direction-contract.json" \
  "$workspace/non-ui-fast-contract.json" <<'RUBY'
fixtures = [
  [ARGV.fetch(0), 43, "2026-09-06T00:31:40Z"],
  [ARGV.fetch(1), 45, "2026-09-06T00:31:40Z"],
  [ARGV.fetch(2), 45, "2026-09-06T00:31:41Z"],
  [ARGV.fetch(3), 46, "2026-09-06T00:31:41Z"],
]
contracts = fixtures.map do |path, issue, fetched_at|
  contract = JSON.parse(File.binread(path))
  IOSTemplate::IssueContract.validate_snapshot!(contract, issue: issue, repository: "yuto1201/iOS-Template")
  abort "fixture fetchedAt drifted from its route boundary" unless contract["fetchedAt"] == fetched_at
  abort "route validation added a forbidden Issue-contract field" if contract.key?("uiDirectionRoute")
  contract
end

legacy, pre_routed, at_cutoff_comparison, at_cutoff_not_applicable = contracts
legacy_text = legacy.fetch("acceptanceCriteria").fetch(0).fetch("text")
abort "legacy fixture lost its incidental route-word regression" unless legacy_text.include?("comparison") && legacy_text.include?("not-applicable")
abort "pre-cutoff route-free contract did not retain its original generic anchor" unless legacy["specAnchors"] == ["specs/acceptance.md#3-issue-definition-of-done"]
abort "pre-cutoff route-free contract gained a retroactive HTML prerequisite" unless legacy["dependencies"] == []

pre_routed_text = pre_routed.fetch("acceptanceCriteria").fetch(0).fetch("text")
abort "pre-cutoff routed contract did not validate its canonical declaration" unless pre_routed_text.start_with?("UI-direction route: comparison; Scope: Selected primary flow; Reason: ")
comparison_text = at_cutoff_comparison.fetch("acceptanceCriteria").fetch(0).fetch("text")
abort "at-cutoff comparison contract did not validate its canonical declaration" unless comparison_text.start_with?("UI-direction route: comparison; Scope: Selected primary flow; Reason: ")
not_applicable_text = at_cutoff_not_applicable.fetch("acceptanceCriteria").fetch(0).fetch("text")
abort "at-cutoff non-UI contract did not validate exact not-applicable syntax" unless not_applicable_text.start_with?("UI-direction route: not-applicable; Scope: Identity metadata only; Reason: ")
RUBY

sed \
  -e 's/Deferred to a focused harden Issue\./Deferred and explicitly unverified in this shape./' \
  -e 's/The selected primary flow is complete in Japanese\./The selected primary flow remains complete in Japanese./' \
  "$workspace/direction-issue.md" > "$workspace/direction-issue-ui-changed.md"
ruby tools/lib/issue-contract.rb \
  --body "$workspace/direction-issue-ui-changed.md" \
  --type feature \
  --format contract \
  --issue 45 \
  --repo yuto1201/iOS-Template \
  --fetched-at 2026-09-06T00:31:41Z > "$workspace/direction-contract-ui-changed.json"
cmp -s "$workspace/direction-contract.json" "$workspace/direction-contract-ui-changed.json" || {
  echo "UI verification unexpectedly changed the sealed Issue contract" >&2
  exit 1
}

sed 's|specs/features/onboarding-ui.md#selected-primary-flow|specs/features/onboarding-ui.md#candidate-awaiting-selection|' \
  "$workspace/direction-issue.md" > "$workspace/direction-issue-anchor-changed.md"
ruby tools/lib/issue-contract.rb \
  --body "$workspace/direction-issue-anchor-changed.md" \
  --type feature \
  --format contract \
  --issue 45 \
  --repo yuto1201/iOS-Template \
  --fetched-at 2026-09-06T00:31:41Z > "$workspace/direction-contract-anchor-changed.json"
if cmp -s "$workspace/direction-contract.json" "$workspace/direction-contract-anchor-changed.json"; then
  echo "A Spec anchors change did not change the sealed Issue contract" >&2
  exit 1
fi

absolute_spec_path="$selection_spec"
printf '[Selected direction](<%s#selected-primary-flow>)\n' "$absolute_spec_path" > "$spec_fixture_dir/confirmed-issue.md"
printf '[Pending direction](<%s#candidate-awaiting-selection>)\n' "$absolute_spec_path" > "$spec_fixture_dir/pending-issue.md"

"$spec_checker" "$spec_fixture_dir/confirmed-issue.md" >/dev/null
if "$spec_checker" "$spec_fixture_dir/pending-issue.md" >/dev/null 2>&1; then
  echo "Specification state checker accepted an unselected UI direction" >&2
  exit 1
fi

echo "UI direction skill and policy checks passed"
