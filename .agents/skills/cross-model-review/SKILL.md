---
name: cross-model-review
description: Use when an iOS-Template Issue has canonical current-Head verification evidence and needs the required opposite-model review sealed to schema v2.
---

# Cross-model review

This skill orchestrates the fixed local tools. It never substitutes the primary model as reviewer, edits review artifacts on behalf of a reviewer, or grants external-operation authority.

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

The producer and review orchestrator own schema-v2 closure, `reviewPacketDigest` validation, and paired publication of `review.json` plus `review-receipt.json`. The receipt binds the fixed launcher bytes, actual opposite reviewer launcher, packet, validated result, published review, timestamps, and successful child exit. `codex` primary maps only to `claude`; `claude` primary maps only to the fixed Codex transport. Both reviewers are noninteractive, read-only, and time-bounded. Do not call either model CLI or transport directly.

3. A valid `approved` result with its exact receipt transitions the Issue to `approved-for-merge`. A valid `changes-requested` result transitions it to `changes-requested`; apply only in-scope fixes as the primary agent, repeat affected verification, produce a new Head-bound packet, and request a new opposite-model review. A timeout is `blocked:review`; never self-approve or fall back to another reviewer. A preseeded review, missing/forged receipt, or mismatched packet/result/review must fail closed. Only an exact receipt/review pair may resume after publication succeeded but the state transition failed.
4. Before merge, use the pre-merge gate. It independently requires the same current Head and exact packet-bound evidence in canonical `verify.json`, `review.json`, and `review-receipt.json`.
