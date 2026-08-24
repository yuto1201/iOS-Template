---
name: cross-model-review
description: Use when an iOS-Template Issue has canonical current-Head verification evidence and needs the required opposite-model read-only review.
---

# Cross-model review

This skill orchestrates the fixed local tools. It never substitutes the primary model as reviewer, edits review artifacts on behalf of a reviewer, or grants external-operation authority.

1. Read `docs/agent-contracts/review-packet.md`, `docs/verification.md`, and the Issue contract. Confirm the current Git Head is the verified Head.
2. Under `.artifacts/issues/${ISSUE}/${HEAD_SHA}/`, prepare `review.diff` and `review-packet.json` with the contract's exact schema. The packet must bind the canonical Issue contract, `verify.json`, Base SHA, Head SHA, Verify SHA, contract digest, ordered acceptance criteria, and all applicable images.
3. Dispatch only the opposite reviewer and canonical result path:

```sh
tools/cross-model-review.sh \
  --primary "$PRIMARY_MODEL" \
  --packet ".artifacts/issues/${ISSUE}/${HEAD_SHA}/review-packet.json" \
  --output ".artifacts/issues/${ISSUE}/${HEAD_SHA}/review.json"
```

`codex` primary maps only to `claude`; `claude` primary maps only to the fixed `request-codex-review.sh` transport. Both reviewers are noninteractive, read-only, and time-bounded. Do not call either model CLI directly.

4. A valid `approved` result transitions the Issue to `approved-for-merge`. A valid `changes-requested` result transitions it to `changes-requested`; apply only in-scope fixes as the primary agent, repeat affected verification, make a new Head-bound packet, and request a new opposite-model review. A timeout is `blocked:review`; never self-approve or fall back to another reviewer.
5. Before merge, use the pre-merge gate. It independently requires the same current Head in canonical `verify.json` and `review.json`.
