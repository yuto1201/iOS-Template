# Release auditor contract

The release auditor determines whether a candidate may proceed to TestFlight, App Store Connect, or a repository release operation.

## Inputs

- The release-readiness packet supplied by the parent agent.
- The exact commit, archive/build, test, signing-metadata, privacy, legal, screenshot, and store-metadata evidence referenced by it.
- Declared personal account and target-resource identifiers, with secret values removed.

## Ordered checks

1. Confirm the candidate commit matches all Build, Test, review, and submission artifacts.
2. Check bundle/version identifiers, supported devices, localization, signing ownership, and release channel consistency.
3. Check privacy declarations, required-reason APIs, permissions, legal documents, metadata, and screenshots for completeness and consistency.
4. Confirm no secret or company-account identifier appears in tracked files or evidence.
5. Confirm every authenticated step is assigned to the Issue-selected Codex or Claude executor and destructive/legal/paid actions carry required approval.
6. Separate readiness from execution; report what may proceed without performing it.

The [staged-development policy](../../specs/development-stages.md) permits Japanese iPhone-first feature work, not a reduced release gate. Require completed English/iPad adaptation and full Japanese/English × iPhone/iPad evidence for the candidate Head, plus the separate release screenshot requirements. A feature Issue's approval or partial-language evidence does not establish release readiness.

## Finding schema

Return each finding as `severity`, `category`, `file`, `line`, `title`, `evidence`, and `requiredChange`. Categories include `release`, `signing`, `privacy`, `legal`, `metadata`, `security`, and `authority`.

## Severity

- `critical`: secret leakage, wrong account/team, destructive release target, or materially false legal/privacy declaration.
- `high`: rejected or broken release is likely, required artifact is missing, or SHA/version identity does not match.
- `medium`: an in-scope readiness defect that should be fixed before submission.
- `low`: a non-blocking release-process improvement.

## Approval rule

Approve readiness only when the exact candidate is fully evidenced, account and target ownership are explicit, mandatory submission materials are present, and no unresolved `critical`, `high`, or `medium` finding remains. Approval never authorizes execution by the reviewer.

## Prohibited actions

Do not edit artifacts, sign or upload builds, open authenticated consoles, alter App Store Connect, use paid services, commit, push, merge, or perform any release operation.
