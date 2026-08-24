---
name: codex-external-ops
description: Use when an iOS-Template task needs one authenticated GitHub, Supabase, Cloudflare, ElevenLabs, or App Store Connect operation, especially from a Claude-primary session.
---

# Codex External Operations

One request authorizes at most one allowlisted operation. Read `docs/AUTHORITY.md`; completion of an Issue does not broaden that authority.

## Claude-primary route

Claude may create the canonical request JSON, but it may execute only:

```sh
tools/request-codex-op.sh \
  --request ".artifacts/ops-requests/${REQUEST_ID}.json" \
  --result ".artifacts/ops-results/${REQUEST_ID}.json"
```

Do not call `gh`, remote Git, provider CLI/MCP, Keychain, authenticated browser actions, or Codex CLI directly. Do not bundle operations. Use a new request ID for each new operation attempt and trust only the wrapper's sanitized result. Reusing the exact same ID and canonical bytes may only retrieve an already-completed receipt; it never authorizes changed bytes or an ambiguous replay.

## Request and execution gate

1. Include exactly the schema from `docs/AUTHORITY.md`: version/ID, Issue, one exact allowlisted `operation`, target kind/identifier, environment, configured `expectedAccount`, operation-specific inputs, and reason.
2. Never include approval state. Validate before execution:

```sh
tools/validate-codex-op-request.sh \
  --request ".artifacts/ops-requests/${REQUEST_ID}.json"
```

3. The wrapper resolves `.artifacts/issues/${ISSUE}/issue-contract.json`, verifies its digest through durable state, performs a fresh personal GitHub preflight, and reconstructs the same contract bytes from the current live Issue. The exact operation, service, environment, executor, and approval requirement must still match.
4. Codex independently derives approval requirements. Requester-selected approval is rejected. Until a separate Codex-owned approval-receipt workflow exists, every `Approval required: yes` operation stops before execution even when the Issue contains an approval reference.
5. Immediately before mutation, Codex verifies the configured personal identity and exact target from `Config/ownership.yml` plus provider-specific identity. GitHub uses login/repository; other providers use the exact account/target pair documented in `docs/AUTHORITY.md`. Unset or mismatched identifiers produce `blocked:ops`.
6. Execute exactly the validated operation—no preparatory or follow-up mutation outside it. A multi-step workflow uses separately validated requests. Use the wrapper-supplied provider idempotency key when supported; do not claim unsupported universal exactly-once behavior.
7. Return only the exact sanitized response schema (`status`, `executor`, `verifiedAccount`, `target`, `operation`, `resultReference`, `executedAt`) on stdout. Never write the result path and never expose tokens, scopes, secrets, prompts, permissions, raw provider output, control characters, or local secret paths.

The wrapper writes an `in-flight` receipt before invoking Codex and publishes the result itself with no-replace semantics. A completed exact replay returns the stored sanitized result without another child invocation. Concurrent, digest-mismatched, crashed/in-flight, preseeded-result, and unsafe symlink/hardlink/swap cases fail closed.

Schema failure, identity mismatch, missing approval, transport failure, or an ambiguous result is not success and must not be retried as a different operation.
