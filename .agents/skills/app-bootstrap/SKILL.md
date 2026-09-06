---
name: app-bootstrap
description: Use when converting a repository created from iOS-Template to one app-specific Xcode identity, or when checking whether feature development may start after that conversion.
---

# App Bootstrap

Identity/bootstrap is a `release` stage with `strict` + `full` coverage because it changes the generated repository's identity and delivery gates. After bootstrap, ordinary new UI starts as `shape` + `standard` + `iphone-ja`; focused quality work uses `harden` + `targeted`. Do not remove existing English resources or iPad targets.

Complete the identity conversion before Feature development. Treat `Config/template-identity.json` as the source contract and `Config/app-identity.json` as the non-secret result record.

## Feature gate

Before any Feature Issue starts, confirm that the app-specific `specs/product.md` and `specs/acceptance.md` are both `Status: 確定` and consistent with the Issue acceptance criteria. If either document is missing, not 確定, or inconsistent, have the Issue-selected Codex or Claude executor transition the Issue to `blocked:user`. Do not create its Branch/worktree and do not implement it. After Identity bootstrap, use [`app-icon`](../app-icon/SKILL.md) and complete its dependent Issue before the first user-facing UI `shape`; do not block independent non-UI work on that selection.

For a post-D-030 Claim, treat Identity bootstrap itself as non-UI work: set its UI verification body to exactly `Not applicable`, put its exact scope and non-UI reason in Goal/In scope or another existing scope section, start one acceptance-criterion text immediately after its `AC-*:` ID with `UI-direction route: not-applicable; Scope: <nonempty>; Reason: <nonempty>`, and cite the relevant confirmed product/specification anchor in Spec anchors. It needs no confirmed UI-direction anchor.

When resuming an already sealed bootstrap contract, compare its `fetchedAt` with `2026-09-06T00:31:41Z`. A declaration candidate is any AC text beginning with exact `UI-direction route:`; it is fully valid only in form `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>` using a route allowed by `ui-direction`. Incidental route words outside the prefix do not create a candidate. An earlier contract with zero candidates is pre-D-030 legacy: do not add a not-applicable declaration, require retroactive HTML, or modify/reseal it; continue against its original sealed AC/spec/evidence. If an earlier contract has one or more candidates, validate normally and reject unless exactly one is fully valid; malformed, unknown-route, empty Scope/Reason, and multiple-candidate cases are not legacy. A contract at or after the cutoff has the same exactly-one and validity requirements, including rejection when no candidate exists.

Evaluate each dependent native UI outcome through [`ui-direction`](../ui-direction/SKILL.md). A current explicit user request for HTML comparison takes priority regardless of an existing direction; an explicit skip overrides the normal route only with unambiguous current applicability, scope, authority, reason, and no conflicting comparison request. Otherwise, use confirmed-direction reuse when a confirmed spec covers the exact hierarchy/flow; run the gate when that direction is unconfirmed and a first-UI, root-navigation/information-architecture, or material primary-flow trigger applies; permit bounded direction-neutral UI only when direction is unconfirmed, no structural trigger applies, and acceptance does not decide hierarchy, navigation, or primary-flow interaction. Ambiguity fails closed into the gate.

Before a post-cutover Claim, require exactly one valid declaration across the existing acceptance criteria. It must begin an AC text with exact `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`, use an allowed route, and place applicable selection/reuse/neutral/explicit-skip facts after Reason; prefix-external route words do not count. Put confirmed anchors in Spec anchors and the completed selection prerequisite in Dependencies. UI Issues retain the exact ordered `Target screens/states`, `English expectations`, and `Japanese expectations` UI verification fields as live guidance, and pre-Claim review checks both them and the authoritative declaration to be sealed. A gated record includes common scope, artifact path/revision, exact presented-bytes SHA-256, adopted/rejected elements, screens/states, and native adaptation; a single selection adds selected concept ID, while a hybrid adds an exhaustive adopted-element-to-source-concept-ID mapping and only adds a selected/base ID when the user chose one. Ambiguity or conflict makes the dependent UI work `blocked:user`.

## Identity bootstrap order

Follow this order without skipping a gate:

1. Confirm these four Identity inputs with the user or approved app specification: display name, Swift module name, lowercase kebab-case app slug, and reverse-DNS Bundle ID. Separately confirm the app's Deployment Target in its specification and Xcode settings; it is not a fifth Identity input.
2. Have the selected Codex or Claude executor create or update an approved Identity Bootstrap Issue after the shared account preflight. Then create one clean nondefault Branch and worktree for that Issue. Do not run the conversion from the default Branch, a detached Head, or a dirty worktree.
3. From the repository root, run:

```sh
tools/bootstrap-app.sh \
  --display-name 'Garden Notes' \
  --module-name GardenNotes \
  --app-slug garden-notes \
  --bundle-id com.yuto.GardenNotes
```

4. Inspect all tracked and untracked output without staging or changing the index. Start with the complete status, inspect the tracked diff, then render every untracked file individually. A `git diff --no-index` exit status of `1` means a difference was displayed; any other nonzero status is an error.

```sh
git status --short --untracked-files=all
git diff --
while IFS= read -r -d '' path; do
  git diff --no-index -- /dev/null "$path" || {
    status=$?
    [[ "$status" -eq 1 ]] || exit "$status"
  }
done < <(git ls-files --others --exclude-standard -z)
```

Also inspect `Config/app-identity.json` and confirm the Head SHA is unchanged. Reject unrelated edits or any Identity mismatch. Do not stage any bootstrap output during this inspection.
5. Run `bash tools/tests/test-foundation.sh` and `bash tools/tests/test-app-bootstrap.sh all`. Confirm the generated repository retains the shape, harden, and release Issue contracts, validators, bounded verification tools, and repository tests. Exercise both a valid shape contract and a valid release contract in the generated sample. Run Xcode project listing, build, Unit Test, and UI Test through the repository's bounded wrappers with DerivedData and result bundles under `/tmp`, outside File Provider-managed repository paths. Verify that all targets and configurations retain the separately specified Deployment Target.
6. Resolve the latest installed iOS Runtime as described in [`docs/verification.md`](../../../docs/verification.md). Run and visually evaluate the four fixed Simulator cases: latest iPhone Pro in English and Japanese, and latest iPad Air in English and Japanese. Preserve Head-SHA-bound evidence.
7. Request the required opposite-model read-only review for the same Head SHA. Address blocking findings and repeat every affected verification before proceeding.
8. Let the Issue's selected executor verify the configured personal GitHub account, push only the Issue Branch, create the PR, compare the reviewed/verified Head SHA, Squash Merge, confirm Issue closure, delete the merged remote Branch, and clean up the local Branch/worktree.
9. Create the dependent App Icon Issue from the confirmed app purpose/direction and Identity. Use [`app-icon`](../app-icon/SKILL.md) to generate exactly two simple candidates, obtain one explicit user selection, and install the selected icon before the first user-facing UI `shape`. This selection does not satisfy or bypass `ui-direction`; independent non-UI work may proceed while selection is pending.

Codex and Claude may both perform the local and authenticated steps. Every authenticated GitHub operation must use the account and target checks in [`docs/AUTHORITY.md`](../../../docs/AUTHORITY.md) and the shared `external-ops` skill.

Remote repository rename and Bundle ID registration are separate authenticated operations. The bootstrap command does not perform or authorize them.

## Re-running

- The same four Identity inputs after a completed conversion must return `already-complete` and make no changes.
- Any conflicting Identity input must fail without changing Head, index, or worktree. Resolve the mismatch explicitly; do not delete or rewrite the result record to force a second conversion.
