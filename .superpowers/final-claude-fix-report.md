# Final Claude review fix report

Base Head: `1566533fa1e00790ec9da3b794a29d68cbdbf4c9`

Implemented:

- Added shared shell-token boundaries including backticks and other shell metacharacters, with positive and negative regressions.
- Denied all `mcp__*` tools by default and allowlisted only the documented local `mcp__xcodebuildmcp__*` prefix.
- Replaced manual AGENTS escaping with standard JSON generation that preserves exact UTF-8 bytes and all C0 controls, with 32768/32769-byte boundary coverage.
- Removed ambient live-contract authority and made `approved -> claimed` the sole explicit non-exported live authorization mode; all other paths use the sealed contract.
- Terminated timed-out reviewer process groups and added a real descendant regression.
- Added the previously missing tracked local Python fixture.

Verification:

- `bash tools/tests/test-claude-guard.sh` — passed.
- `bash tools/tests/test-workflow-state.sh` — passed.
- `bash tools/tests/test-claim-resume.sh` — passed.
- `bash tools/tests/test-cross-model-review.sh` — passed.
- Bash/Ruby syntax checks and `git diff --check` — passed before commit.

Self-review found no unresolved concern within the assigned scope. No authenticated external operation was used.
