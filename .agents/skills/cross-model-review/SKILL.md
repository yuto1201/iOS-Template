---
name: cross-model-review
description: Use when an iOS-Template Issue has canonical current-Head verification evidence and needs the required opposite-model review sealed to schema v2.
---

# Cross-model review

Review the exact sealed scope only when the contract requires it: `strict`, `release`, or a stage-less legacy contract. A strict shape/harden review evaluates its exact `iphone-ja`/`targeted` evidence without inventing release coverage; release and legacy contracts require `full`. Safety, account and current-Head approval gates remain unchanged.

This skill orchestrates the fixed local tools only when `IOSTemplate::DeliveryProfile.review_required?` is true. Non-release standard shape/harden and explicit fast Issues do not call this blocking review skill. It never substitutes the primary model as reviewer, edits review artifacts on behalf of a reviewer, or grants external-operation authority.

1. Read `docs/agent-contracts/review-packet.md`, `docs/verification.md`, and the Issue contract. Start at the Git top-level with the approved `ISSUE`, trusted `BASE_SHA`, verified current `HEAD_SHA`, and `PRIMARY_MODEL`. Do not dispatch review until `ios-verify` has produced complete canonical evidence for that exact Head.
2. Invoke the single canonical producer. Consume its returned path directly; do not run `git diff`, hand-write a packet, translate its schema, or select another packet.

```sh
REVIEW_PREPARATION="$(tools/prepare-review-packet.sh --primary "$PRIMARY_MODEL" --issue "$ISSUE" --base-sha "$BASE_SHA" --head-sha "$HEAD_SHA")"
REVIEW_PACKET="$(jq -er '.path' <<<"$REVIEW_PREPARATION")"

tools/cross-model-review.sh \
  --primary "$PRIMARY_MODEL" \
  --packet "$REVIEW_PACKET" \
  --output ".artifacts/issues/${ISSUE}/${HEAD_SHA}/review.json"
```

The producer and review orchestrator own schema-v2 closure, `reviewPacketDigest` validation, and paired publication of `review.json` plus `review-receipt.json`. The receipt binds the fixed launcher bytes, actual opposite reviewer launcher, packet, validated result, published review, timestamps, and successful child exit. The defaults remain `codex` primary to `claude` and `claude` primary to the fixed Codex transport. Only a Codex-primary contract with exactly one complete, user-explicit `Opposite-review route: grok-fallback` AC declaration may select exact `cursor-grok-4.6-xhigh`; the orchestrator invokes its fixed Cursor `ask` launcher. That launcher gives Grok a 480-second bounded inspection order and deterministic identity/evidence scaffold inside the outer 600-second watchdog; the scaffold cannot decide verdict or findings, and uncertainty must become a valid changes-requested result instead of an unbounded search. Never add a runtime fallback flag, infer approval, select another Grok alias, use Grok for a Claude primary, or call a model CLI/transport directly.

For a plan-required repository-test contract, require the packet's canonical `repositoryTestsFile` and `repositoryTestPlanFile` path/digests before dispatch. The reviewer checks requested/resolved scope, manifest/diff identity, exact selected tests, and ordered AC mappings; each supported AC cites its own zero-based `repository-tests.json#acceptanceEvidence/INDEX`. For `base-and-head`, also require both revision suites and distinguish Base baseline/regression evidence from new Head implementation evidence. Missing or changed plan/record bytes, another AC's mapping, or an unjustified reduced set cannot satisfy this route. Keep old Head-only and schema v2 contracts unchanged; see [the review contract](../../../docs/agent-contracts/review-packet.md#plan-required-contract).

3. A valid `approved` result with its exact receipt transitions the Issue to `approved-for-merge`. A valid `changes-requested` result transitions it to `changes-requested`; apply only in-scope fixes as the primary agent, repeat affected verification, produce a new Head-bound packet, and request a new opposite-model review. Reviewer launch failure, nonzero exit, timeout, empty/malformed output, invalid schema/evidence, or a write attempt is `blocked:review`; never self-approve or fall back to another reviewer. A preseeded review, missing/forged receipt, or mismatched route/packet/result/review must fail closed. Only an exact receipt/review pair may resume after publication succeeded but the state transition failed.
4. Before merge, use the pre-merge gate. It independently requires the same current Head and exact packet-bound evidence in canonical `verify.json`, `review.json`, and `review-receipt.json`.
