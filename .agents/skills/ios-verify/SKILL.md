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

When XcodeBuildMCP is callable, inspect its session defaults first. It is compatible only if its project, shared scheme, Xcode identity, exact matrix UDIDs/locales, serial execution, and worktree-specific DerivedData match this workflow and it can publish the canonical draft/final evidence accepted by `tools/validate-verify-json.swift`, including `executionRoute: "xcodebuild-mcp"`.

If any default or evidence capability is absent or incompatible, use `tools/verify-ios-issue.sh`. This is the currently verified `xcodebuild-simctl` producer and must not be bypassed with manual `xcodebuild`, `simctl`, screenshots, or JSON. Tool unavailability is never test success.

## Application verification

Reserve the single repository-wide Simulator verification lane before matrix lifecycle work. Do not overlap another Issue's lifecycle or runner. The runner's Issue/Head lock prevents duplicate runs; it does not replace cross-Issue serialization. Keep the lane until the final evidence gate finishes, and release it on failure too.

Resolve a missing matrix once, or revalidate an existing one in place:

```sh
MATRIX=".artifacts/batches/${BATCH_ID}/simulator-matrix.json"
tools/resolve-simulator-matrix.sh --batch-id "$BATCH_ID" --output "$MATRIX"
```

The lifecycle command must preserve an existing complete matrix byte-for-byte. It must select the latest installed available iOS Runtime, iPhone Pro excluding Pro Max, and the latest iPad Air, with exact ordered rows `iphone-en` (`en_US`/`en`), `iphone-ja` (`ja_JP`/`ja`), `ipad-en` (`en_US`/`en`), and `ipad-ja` (`ja_JP`/`ja`). Never repair a partial frozen matrix or fall back to another device family. Treat missing dedicated devices or changed frozen bytes as `blocked:environment`.

Run the verified fallback from the Git top-level:

```sh
tools/verify-ios-issue.sh \
  --issue "$ISSUE" \
  --expected-base "$BASE_SHA" \
  --issue-contract ".artifacts/issues/${ISSUE}/issue-contract.json" \
  --matrix "$MATRIX" \
  --project "$PROJECT" \
  --scheme "$SCHEME"
```

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

Do not reserve the Simulator lane, resolve a matrix, call Xcode, capture images, or request visual evaluation. Create the canonical regular, non-symlink `.artifacts/issues/${ISSUE}/${HEAD_SHA}/verify.json` using the exact documentation-only object in `docs/verification.md`:

- `status: "not-applicable"`, `changeClassification: "documentation-only"`, and a nonempty reason
- exact Issue, trusted Base/current Head, and current Issue-contract path/digest
- null matrix/Xcode, `executionRoute: "none"`, empty cases, and not-applicable Build/Test/visual fields
- every contract `AC-*` exactly once, in order, with only `documents:` or `links:` evidence

Derive these values from the current contract and Git range; never copy a previous Issue or Head. The standalone validator below is the required publisher recipe's fail-closed gate. If it rejects the range or object, keep the Issue in progress and correct the evidence rather than switching classification.

## Final evidence and review handoff

For either path, independently validate the exact canonical evidence and derive its digest only after validation exits zero:

```sh
EVIDENCE=".artifacts/issues/${ISSUE}/${HEAD_SHA}/verify.json"
swift tools/validate-verify-json.swift \
  --file "$EVIDENCE" \
  --expected-issue "$ISSUE" \
  --expected-base "$BASE_SHA" \
  --expected-head "$HEAD_SHA"
DIGEST="sha256:$(shasum -a 256 "$EVIDENCE" | awk '{print $1}')"
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

After packet creation, return exactly:

```text
.artifacts/issues/${ISSUE}/${HEAD_SHA}/verify.json sha256:${SHA256_OF_THAT_EXACT_FILE}
```
