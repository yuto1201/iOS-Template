# Task 6 integration repair report

## Scope

Repaired only the Task 2/4 interfaces named in `task-6-integration-request.md`. Task 6 gate, merge, cleanup, and PR-rendering files were not changed. No live GitHub, model, or API operation was performed.

## TDD evidence

- RED: `bash tools/tests/test-claim-resume.sh` failed with `claim did not install the shared artifact link` after the new linked-worktree regression was added.
- RED: the added durable-identity transition regression failed when the pre-existing Task 2 writer replaced a complete Task 4 record with its minimal state record.
- GREEN: Claim and Resume now prove the exact canonical worktree and Git common directory before installing or accepting only `.artifacts -> ../../.artifacts`; a fake-gh preflight launched in that worktree binds its local Head and writes to the primary artifact store.
- GREEN: state transitions validate the durable record before any label mutation, reject unsafe/malformed identities, and atomically retain the exact compatible Task 4 identity plus optional Task 6 `headSha` and `pullRequest` metadata.

## Verification

- `bash -n tools/claim-issue.sh tools/resume-issue.sh tools/issue-state.sh tools/lib/workflow.sh tools/tests/test-claim-resume.sh tools/tests/test-workflow-state.sh`
- `ruby -c tools/lib/workflow-json.rb`
- `bash tools/tests/test-claim-resume.sh`
- `bash tools/tests/test-workflow-state.sh`
- `bash tools/tests/test-cross-model-review.sh`
- `git diff --check`

All commands passed locally. The test fixtures use temporary repositories and fake `gh`; no authenticated operation occurred.

## Remaining concern

`pullRequest` is intentionally accepted only as a positive Issue/PR number in the compatible state schema. Any future expansion of that identity needs a deliberate schema migration and matching regression instead of silently retaining arbitrary fields.
