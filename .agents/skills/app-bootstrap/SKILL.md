---
name: app-bootstrap
description: Use when converting a repository created from iOS-Template to one app-specific Xcode identity, or when checking whether feature development may start after that conversion.
---

# App Bootstrap

Identity/bootstrap uses strict + full coverage, not the normal feature form default. After bootstrap, ordinary new UI uses standard + iphone-ja with one shared English/iPad finishing Issue. Do not remove existing English resources or iPad targets.

Complete the identity conversion before Feature development. Treat `Config/template-identity.json` as the source contract and `Config/app-identity.json` as the non-secret result record.

## Feature gate

Before any Feature Issue starts, confirm that the app-specific `specs/product.md` and `specs/acceptance.md` are both `Status: 確定` and consistent with the Issue acceptance criteria. If either document is missing, not 確定, or inconsistent, have the Issue-selected Codex or Claude executor transition the Issue to `blocked:user`. Do not create its Branch/worktree and do not implement it.

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
5. Run `bash tools/tests/test-foundation.sh` and `bash tools/tests/test-app-bootstrap.sh all`. Run Xcode project listing, build, Unit Test, and UI Test with DerivedData and result bundles under `/tmp`, outside File Provider-managed repository paths. Verify that all targets and configurations retain the separately specified Deployment Target.
6. Resolve the latest installed iOS Runtime as described in [`docs/verification.md`](../../../docs/verification.md). Run and visually evaluate the four fixed Simulator cases: latest iPhone Pro in English and Japanese, and latest iPad Air in English and Japanese. Preserve Head-SHA-bound evidence.
7. Request the required opposite-model read-only review for the same Head SHA. Address blocking findings and repeat every affected verification before proceeding.
8. Let the Issue's selected executor verify the configured personal GitHub account, push only the Issue Branch, create the PR, compare the reviewed/verified Head SHA, Squash Merge, confirm Issue closure, delete the merged remote Branch, and clean up the local Branch/worktree.

Codex and Claude may both perform the local and authenticated steps. Every authenticated GitHub operation must use the account and target checks in [`docs/AUTHORITY.md`](../../../docs/AUTHORITY.md) and the shared `external-ops` skill.

Remote repository rename and Bundle ID registration are separate authenticated operations. The bootstrap command does not perform or authorize them.

## Re-running

- The same four Identity inputs after a completed conversion must return `already-complete` and make no changes.
- Any conflicting Identity input must fail without changing Head, index, or worktree. Resolve the mismatch explicitly; do not delete or rewrite the result record to force a second conversion.
