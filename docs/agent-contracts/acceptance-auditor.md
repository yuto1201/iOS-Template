# Acceptance auditor contract

The acceptance auditor applies the canonical [opposite-model review packet](./review-packet.md) contract to the exact reviewed commit.

## Inputs

- A review packet conforming to `docs/agent-contracts/review-packet.md`.
- The Issue contract, verification result, diff, and images referenced by the packet.
- The exact `baseSha`, `headSha`, `verifySha`, and Issue-contract digest.

## Ordered checks

1. Validate required packet fields and confirm `headSha == verifySha`.
2. Recompute or compare the supplied Issue-contract digest and reject stale/mismatched evidence.
3. Map every `AC-*` to concrete implementation and verification evidence.
4. Inspect all listed simulator cases and images; do not infer unlisted runs.
5. Check for scope expansion and unsupported Build, Test, account, or external-operation claims.
6. Emit one `acceptanceAssessment` entry for every `AC-*` before deciding the verdict.

Use the [staged-development policy](../../specs/development-stages.md) to distinguish feature completion from release readiness. Explicitly deferred English/iPad polish is tracked in the adaptation Issue, not silently added to a Japanese iPhone feature's ACs. It is also not evidence of English/iPad support. Release readiness still requires the adaptation work and all four cases at the candidate Head. Until Issue #32 implements scoped evidence, do not waive the current four-case packet requirements.

## Finding schema

Use the JSON result and finding schemas in `docs/agent-contracts/review-packet.md`. Every acceptance item must be `supported` or `unsupported` and cite exact evidence paths.

## Severity

- `critical`: approval would conceal an authority breach, secret exposure, destructive action, or fabricated evidence.
- `high`: any `AC-*` is unsupported or the reviewed/verified SHA or contract digest does not match.
- `medium`: evidence exists but is incomplete, ambiguous, or does not test the claimed failure mode.
- `low`: a non-blocking evidence presentation improvement.

## Approval rule

Approve only if packet identity fields match, every `AC-*` is supported, all mandatory cases are evidenced, and no unresolved `critical`, `high`, or `medium` finding remains.

## Prohibited actions

Do not edit packet artifacts, regenerate evidence, run tests, operate simulators, use authenticated external services, commit, push, merge, or fill an evidence gap by assumption.
