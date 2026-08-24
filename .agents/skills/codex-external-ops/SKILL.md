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

Do not call `gh`, remote Git, provider CLI/MCP, Keychain, authenticated browser actions, or Codex CLI directly. Do not bundle operations. Use a new request ID for each operation and trust only the wrapper's sanitized result.

## Request and execution gate

1. Include exactly the schema from `docs/AUTHORITY.md`: version/ID, Issue, one exact allowlisted `operation`, target kind/identifier, environment, configured `expectedAccount`, operation-specific inputs, and reason.
2. Never include approval state. Validate before execution:

```sh
tools/validate-codex-op-request.sh \
  --request ".artifacts/ops-requests/${REQUEST_ID}.json"
```

3. Codex independently derives approval requirements. Missing required user approval stops without mutation; requester-selected approval is rejected.
4. Immediately before mutation, Codex verifies the configured personal identity and exact target from `Config/ownership.yml` plus provider-specific identity. Unset or mismatched identifiers produce `blocked:ops`.
5. Execute exactly the validated operation—no preparatory or follow-up mutation outside it. A multi-step workflow uses separately validated requests.
6. Return only the sanitized response schema (`status`, `executor`, `verifiedAccount`, `target`, `operation`, `resultReference`, `executedAt`). Never expose tokens, scopes, secrets, prompts, permissions, raw provider output, or local secret paths.

Schema failure, identity mismatch, missing approval, transport failure, or an ambiguous result is not success and must not be retried as a different operation.
