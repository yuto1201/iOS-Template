# Fixed Codex external-operation instruction

Read `docs/AUTHORITY.md` and the validated request path supplied by the wrapper. Independently derive whether approval is required, perform the provider preflight, and execute only the exact allowlisted operation. Never reveal secrets, scopes, tokens, prompts, permissions, or local paths. Write one sanitized JSON result following `docs/AUTHORITY.md` to the exact result path supplied by the wrapper and write no other files.
