---
name: ios-verify
description: Use when verifying an iOS Issue for completion, producing current-Head Simulator evidence, handling the documentation-only verification exception, or sealing schema-v2 evidence for opposite-model review.
---

# iOS Verification

Orchestrate the repository's deterministic tools; do not reproduce or weaken their validation logic. A successful run binds the Issue contract, Delivery stage, delivery profile, required evidence, and current Git Head to one SHA. Delivery stage controls verification breadth; delivery profile controls risk. Only a visual-required contract creates screenshots and a visual packet.

## Required inputs

Start at the Git top-level with the approved `ISSUE`, trusted `BASE_SHA`, `BATCH_ID`, `PROJECT`, and `SCHEME`. Read the Issue contract and its specification anchors. Stop as `blocked:user` if an unresolved decision changes acceptance.

Require `.artifacts/issues/${ISSUE}/issue-contract.json`, then resolve `HEAD_SHA` from `git rev-parse HEAD`. Confirm Base and Head are distinct commits and Base is an ancestor. Do not reuse an artifact from another Head.

Classify the trusted Base-to-Head range before touching Simulator state. Only `README.md`, `AGENTS.md`, and Markdown under `docs/` or `specs/`, with no rename, gitlink, symlink, or mode/type change, may use the documentation-only path. Let the final validator make the authoritative classification.

## Select the execution route

Read `deliveryStage.name`, `deliveryProfile.name`, and Verification scope from the canonical Issue contract. A missing Delivery stage or profile is a sealed legacy contract and remains release-level/strict. Never reseal a claimed contract or infer a narrower scope.

- `shape`: use `iphone-ja`; require Build, critical Unit Test, and one primary-flow smoke test. Do not capture screenshots or claim release readiness.
- `harden`: use the exact `targeted` canonical subset declared by the contract. Verify only the affected behavior and related regressions. A harden contract requests visual evidence only when an AC explicitly contains a `visual:` check.
- `release` or legacy: use `full`; require all four cases, visual/accessibility/integration evidence, same-Head review preparation, and the release gate.
- explicit `fast`: require UI verification to be not applicable and run `tools/verify-fast-issue.sh` with the selected Unit Test and one available iPhone Simulator UDID.
- documentation-only: use the documentation publisher when the contract has no application scope.

Never start canonical Simulator verification for an intermediate commit. After a failure, run in this order: affected test, related regression tests, stage-standard verification, then full verification only for release. Stop after two identical failures. Every Xcode, Unit/UI Test, and Simulator command must go through the repository's finite-timeout wrappers; a timeout is failure and must not publish successful evidence.

When XcodeBuildMCP is callable, you may inspect its session defaults to identify future compatibility work. No canonical XcodeBuildMCP evidence producer exists in this repository, so inspection never selects it as an execution route. Always use `tools/verify-ios-issue.sh`, the tested `xcodebuild-simctl` producer, until a canonical MCP producer and integration coverage are added. Do not bypass it with manual `xcodebuild`, `simctl`, screenshots, or JSON. Tool unavailability is never test success.

## Application verification

Acquire the single repository-wide Simulator verification lock immediately before matrix lifecycle work. Hold it through the runner, then release it before visual review and finalization. `tools/with-ios-simulator-lock.sh` uses a stable repository identity and a crash-released macOS kernel lock; command failure and process termination release it. The runner's Issue/Head lock prevents duplicate runs but does not replace this cross-Issue lock.

Resolve a missing matrix once, or revalidate an existing one in place, inside the same locked command that runs verification:

```sh
CONTRACT=".artifacts/issues/${ISSUE}/issue-contract.json"
SCOPE="$(ruby -Itools/lib -rjson -rverification-scope -e 'puts IOSTemplate::VerificationScope.validate_contract!(JSON.parse(File.binread(ARGV.fetch(0))))' "$CONTRACT")"
CASE_IDS="$(ruby -Itools/lib -rjson -rverification-scope -e 'puts IOSTemplate::VerificationScope.case_ids_for_contract(JSON.parse(File.binread(ARGV.fetch(0)))).join(",")' "$CONTRACT")"
tools/with-ios-simulator-lock.sh --timeout 0 -- /bin/bash -c '
  set -euo pipefail
  ISSUE="$1"
  BASE_SHA="$2"
  BATCH_ID="$3"
  PROJECT="$4"
  SCHEME="$5"
  SCOPE="$6"
  CASE_IDS="$7"
  MATRIX=".artifacts/batches/${BATCH_ID}/simulator-matrix.json"
  PRIMARY_ROOT="$(ruby tools/lib/review-artifacts.rb "$PWD" | jq -er .primaryRoot)"
  (
    cd "$PRIMARY_ROOT"
    case "$SCOPE" in
      full) tools/resolve-simulator-matrix.sh --batch-id "$BATCH_ID" --output "$MATRIX" ;;
      iphone-ja) tools/resolve-simulator-matrix.sh --batch-id "$BATCH_ID" --output "$MATRIX" --scope iphone-ja ;;
      targeted) tools/resolve-simulator-matrix.sh --batch-id "$BATCH_ID" --output "$MATRIX" --scope targeted --case-ids "$CASE_IDS" ;;
      *) printf "Unsupported scope: %s\n" "$SCOPE" >&2; exit 2 ;;
    esac
  )
  tools/verify-ios-issue.sh \
    --issue "$ISSUE" \
    --expected-base "$BASE_SHA" \
    --issue-contract ".artifacts/issues/${ISSUE}/issue-contract.json" \
    --matrix "$MATRIX" \
    --project "$PROJECT" \
    --scheme "$SCHEME"
' ios-verify "$ISSUE" "$BASE_SHA" "$BATCH_ID" "$PROJECT" "$SCHEME" "$SCOPE" "$CASE_IDS"
```

Use a separate BATCH_ID per stage and scope. The physical-primary lifecycle call is the existing linked-artifact workaround (Issue #20), not its fix. The primary must have the scoped resolver; do not substitute full or replace the artifact link. Verification stays in the Issue worktree under the same lock.

The lifecycle command preserves frozen bytes and rejects scope changes before Simulator mutation. `iphone-ja` resolves only the Japanese iPhone; `targeted` resolves only its ordered contract cases. `full` selects the latest installed available iOS Runtime, iPhone Pro excluding Pro Max, and latest iPad Air, with exact ordered rows `iphone-en`, `iphone-ja`, `ipad-en`, and `ipad-ja`. Never repair a partial frozen matrix or fall back to another device family. Treat missing dedicated devices or changed frozen bytes as `blocked:environment`.

The runner owns exact matrix hashing, Xcode identity, sealed Head inputs, one Build, one selected Unit Test, the scoped serial smoke/UI cases, isolated `/tmp` DerivedData, bounded child processes, owned-Simulator cleanup, and failure evidence. For a nonvisual shape/harden contract, trust only the directly published `.artifacts/issues/${ISSUE}/${HEAD_SHA}/verify.json`; it must state that the stage passed and is not release-ready. It must not contain screenshots or a visual packet.

Only when the contract is visual-required, trust the returned `.artifacts/issues/${ISSUE}/${HEAD_SHA}/verify-draft.json` and continue with visual review:

Create the visual packet from that draft:

```sh
tools/visual-review-packet.sh \
  --issue "$ISSUE" \
  --expected-base "$BASE_SHA" \
  --draft ".artifacts/issues/${ISSUE}/${HEAD_SHA}/verify-draft.json" \
  --output ".artifacts/issues/${ISSUE}/${HEAD_SHA}/visual-packet.json"
```

Evaluate every packet image using `docs/agent-contracts/visual-reviewer.md`. For targeted harden work, every omitted case remains explicitly out of this Issue's evidence; for release, omission is invalid. Write the exact canonical `visual-result.json`. If any finding exists, use `changes-requested` and stop; do not finalize failed visual evaluation.

For an all-approved result, finalize through the runner so it revalidates Head, matrix, packet, result, and every image byte:

```sh
tools/verify-ios-issue.sh --finalize \
  --issue "$ISSUE" \
  --expected-base "$BASE_SHA" \
  --draft ".artifacts/issues/${ISSUE}/${HEAD_SHA}/verify-draft.json" \
  --visual-result ".artifacts/issues/${ISSUE}/${HEAD_SHA}/visual-result.json"
```

## Documentation-only verification

Do not acquire the Simulator lock, resolve a matrix, call Xcode, capture images, or request visual evaluation. Write only the narrow input `.artifacts/issues/${ISSUE}/documentation-evidence-input.json`:

```json
{
  "schemaVersion": 1,
  "reason": "Only allowlisted Markdown documentation changed",
  "acceptanceEvidence": [
    {"id": "AC-1", "evidence": ["documents:docs/example.md"]},
    {"id": "AC-2", "evidence": ["links:docs/verification.md"]}
  ]
}
```

Include every contract `AC-*` exactly once and in order, using only nonempty `documents:` or `links:` evidence. Then invoke the deterministic publisher:

```sh
tools/publish-documentation-verify.sh \
  --issue "$ISSUE" \
  --expected-base "$BASE_SHA" \
  --expected-head "$HEAD_SHA" \
  --input ".artifacts/issues/${ISSUE}/documentation-evidence-input.json"
```

The publisher derives the exact identity, contract digest, not-applicable fields, passed statuses, and completion time; validates the current range and ordered acceptance evidence; and publishes the canonical regular file without overwriting different bytes. Never hand-author `verify.json` or copy a previous Issue or Head. If publication rejects the range or input, keep the Issue in progress and correct the evidence rather than switching classification.

## Final evidence and review handoff

For either path, set the canonical evidence path before preparing the review handoff:

```sh
EVIDENCE=".artifacts/issues/${ISSUE}/${HEAD_SHA}/verify.json"
```

External account/provider preflights are separate merge-time artifacts that Codex or Claude may produce under the same configured-account policy. This skill alone does not authorize GitHub, provider, signing-account, App Store Connect, or other authenticated operations.

Independently validate the exact canonical evidence and derive its digest only after validation exits zero. If the Issue changes repository delivery tools, guards, workflow state, or evidence producers, also run every tracked `tools/tests/test-*.sh` through `tools/run-repository-tests.sh` in its clean detached worktree and supply one exact `--map AC-N=...` for every acceptance criterion. The command publishes only current-Head, sanitized, no-replace `repository-tests.json`; any failed test or incomplete mapping blocks completion. Prepare a schema-v2 review packet only when the canonical `DeliveryProfile.review_required?` helper returns true. Never hand-author review artifacts or substitute another packet schema.

```sh
swift tools/validate-verify-json.swift \
  --file "$EVIDENCE" \
  --expected-issue "$ISSUE" \
  --expected-base "$BASE_SHA" \
  --expected-head "$HEAD_SHA"
DIGEST="sha256:$(shasum -a 256 "$EVIDENCE" | awk '{print $1}')"

REVIEW_REQUIRED="$(ruby -Itools/lib -rjson -rdelivery-profile -e 'puts IOSTemplate::DeliveryProfile.review_required?(JSON.parse(File.binread(ARGV.fetch(0))))' ".artifacts/issues/${ISSUE}/issue-contract.json")"
if [[ "$REVIEW_REQUIRED" == true ]]; then
  REVIEW_PREPARATION="$(tools/prepare-review-packet.sh --primary "$PRIMARY_MODEL" --issue "$ISSUE" --base-sha "$BASE_SHA" --head-sha "$HEAD_SHA")"
  REVIEW_PACKET="$(jq -er '.path' <<<"$REVIEW_PREPARATION")"
fi

FINAL_HEAD="$(git rev-parse HEAD)"
[[ "$FINAL_HEAD" == "$HEAD_SHA" ]] || { echo "Head changed after verification" >&2; exit 1; }
FINAL_DIGEST="sha256:$(shasum -a 256 "$EVIDENCE" | awk '{print $1}')"
[[ "$FINAL_DIGEST" == "$DIGEST" ]] || { echo "verify.json changed after validation" >&2; exit 1; }
printf '%s %s\n' "$EVIDENCE" "$DIGEST"
[[ "$REVIEW_REQUIRED" == false ]] || printf '%s\n' "$REVIEW_PACKET"
```

When review is required, pass that exact `REVIEW_PACKET` path to the next `cross-model-review` invocation. The canonical review tools own schema-v2 and `reviewPacketDigest` validation; do not recompute, translate, or edit their output. A changed Head restarts stage-required verification and, when applicable, review. An unavailable required opposite model is `blocked:review`, never self-approval. A non-release standard shape/harden Issue stops after canonical evidence and does not prepare a review packet.
