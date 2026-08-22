---
name: ios-verify
description: Use when verifying an iOS Issue for completion, producing current-Head Simulator evidence, handling the documentation-only verification exception, or preparing evidence for opposite-model review.
---

# iOS Verification

Orchestrate the repository's deterministic tools; do not reproduce or weaken their validation logic. A successful run binds the Issue contract, frozen Simulator matrix, visual approval, final evidence, review packet, and current Git Head to one SHA.

## Required inputs

Start at the Git top-level with the approved `ISSUE`, trusted `BASE_SHA`, `BATCH_ID`, `PROJECT`, and `SCHEME`. Read the Issue contract and its specification anchors. Stop as `blocked:user` if an unresolved decision changes acceptance.

Require `.artifacts/issues/${ISSUE}/issue-contract.json`, then resolve `HEAD_SHA` from `git rev-parse HEAD`. Confirm Base and Head are distinct commits and Base is an ancestor. Do not reuse an artifact from another Head.

Classify the trusted Base-to-Head range before touching Simulator state. Only `README.md`, `AGENTS.md`, and Markdown under `docs/` or `specs/`, with no rename, gitlink, symlink, or mode/type change, may use the documentation-only path. Let the final validator make the authoritative classification.

## Select the execution route

When XcodeBuildMCP is callable, you may inspect its session defaults to identify future compatibility work. No canonical XcodeBuildMCP evidence producer exists in this repository, so inspection never selects it as an execution route. Always use `tools/verify-ios-issue.sh`, the tested `xcodebuild-simctl` producer, until a canonical MCP producer and integration coverage are added. Do not bypass it with manual `xcodebuild`, `simctl`, screenshots, or JSON. Tool unavailability is never test success.

## Application verification

Acquire the single repository-wide Simulator verification lock immediately before matrix lifecycle work. Hold it through the runner, then release it before visual review and finalization. `tools/with-ios-simulator-lock.sh` uses a stable repository identity and a crash-released macOS kernel lock; command failure and process termination release it. The runner's Issue/Head lock prevents duplicate runs but does not replace this cross-Issue lock.

Resolve a missing matrix once, or revalidate an existing one in place, inside the same locked command that runs verification:

```sh
tools/with-ios-simulator-lock.sh --timeout 0 -- /bin/bash -c '
  set -euo pipefail
  ISSUE="$1"
  BASE_SHA="$2"
  BATCH_ID="$3"
  PROJECT="$4"
  SCHEME="$5"
  MATRIX=".artifacts/batches/${BATCH_ID}/simulator-matrix.json"
  tools/resolve-simulator-matrix.sh --batch-id "$BATCH_ID" --output "$MATRIX"
  tools/verify-ios-issue.sh \
    --issue "$ISSUE" \
    --expected-base "$BASE_SHA" \
    --issue-contract ".artifacts/issues/${ISSUE}/issue-contract.json" \
    --matrix "$MATRIX" \
    --project "$PROJECT" \
    --scheme "$SCHEME"
' ios-verify "$ISSUE" "$BASE_SHA" "$BATCH_ID" "$PROJECT" "$SCHEME"
```

The lifecycle command must preserve an existing complete matrix byte-for-byte. It must select the latest installed available iOS Runtime, iPhone Pro excluding Pro Max, and the latest iPad Air, with exact ordered rows `iphone-en` (`en_US`/`en`), `iphone-ja` (`ja_JP`/`ja`), `ipad-en` (`en_US`/`en`), and `ipad-ja` (`ja_JP`/`ja`). Never repair a partial frozen matrix or fall back to another device family. Treat missing dedicated devices or changed frozen bytes as `blocked:environment`.

Trust only the returned canonical `.artifacts/issues/${ISSUE}/${HEAD_SHA}/verify-draft.json`. The runner owns exact matrix hashing, Xcode identity, execution route, sealed Head inputs, one Build, one unit test, four serial locale cases, isolated `/tmp` DerivedData, screenshots, and failure evidence.

Create the visual packet from that draft:

```sh
tools/visual-review-packet.sh \
  --issue "$ISSUE" \
  --expected-base "$BASE_SHA" \
  --draft ".artifacts/issues/${ISSUE}/${HEAD_SHA}/verify-draft.json" \
  --output ".artifacts/issues/${ISSUE}/${HEAD_SHA}/visual-packet.json"
```

Evaluate every packet image using `docs/agent-contracts/visual-reviewer.md`. Write the exact canonical `visual-result.json`. If any finding exists, use `changes-requested` and stop; do not finalize failed visual evaluation.

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

Create the read-only opposite-model review handoff from `docs/agent-contracts/review-packet.md`:

```sh
REVIEW_ROOT=".artifacts/issues/${ISSUE}/${HEAD_SHA}"
REVIEW_DIFF="${REVIEW_ROOT}/review.diff"
REVIEW_PACKET="${REVIEW_ROOT}/review-packet.json"
git diff --binary --no-ext-diff --no-renames "$BASE_SHA" "$HEAD_SHA" -- >"$REVIEW_DIFF"
```

Write `REVIEW_PACKET` with the contract's exact schema: set `headSha` and `verifySha` to `HEAD_SHA`; copy the canonical Issue-contract path/digest, spec anchors, and ordered acceptance criteria; reference `REVIEW_DIFF` and this `verify.json`; and include every final visual image path for application evidence (an empty image list for documentation-only). Re-read current Head before dispatch. A changed Head restarts verification and review; an unavailable opposite model is `blocked:review`, never self-approval.

External account/provider preflights are separate Codex-only merge-time artifacts. This skill does not authorize GitHub, provider, signing-account, App Store Connect, or other authenticated operations.

After packet creation, independently validate the exact canonical evidence, derive its digest only after validation exits zero, and make the final Head/evidence recheck the last operation before returning:

```sh
swift tools/validate-verify-json.swift \
  --file "$EVIDENCE" \
  --expected-issue "$ISSUE" \
  --expected-base "$BASE_SHA" \
  --expected-head "$HEAD_SHA"
DIGEST="sha256:$(shasum -a 256 "$EVIDENCE" | awk '{print $1}')"
FINAL_HEAD="$(git rev-parse HEAD)"
[[ "$FINAL_HEAD" == "$HEAD_SHA" ]] || { echo "Head changed after verification" >&2; exit 1; }
FINAL_DIGEST="sha256:$(shasum -a 256 "$EVIDENCE" | awk '{print $1}')"
[[ "$FINAL_DIGEST" == "$DIGEST" ]] || { echo "verify.json changed after validation" >&2; exit 1; }
printf '%s %s\n' "$EVIDENCE" "$DIGEST"
```
