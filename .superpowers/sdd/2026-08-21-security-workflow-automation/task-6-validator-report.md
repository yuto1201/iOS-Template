# Task 6 validator linked-worktree repair report

## 2026-08-24

- Implemented the single canonical shared-artifact exception in `validate-verify-json.swift`: the physical Issue worktree remains the trusted Git/source root, while `.artifacts` is read and published through a separate no-follow descriptor only after exact link, worktree, Branch, durable-state, primary-directory, and Git-common-directory checks.
- Added real temporary linked-worktree regressions for valid application and documentation evidence plus documentation code rejection, malformed/absolute link targets, deeper worktrees, unrelated Git common directories, mismatched state identity fields, primary-store symlinks, and artifact-file symlinks. The pre-existing arbitrary artifact-root symlink rejection remains covered.
- Verification: focused linked-worktree regression passed (valid shared application and documentation evidence; all specified link, topology, state, and per-file rejection cases), `swiftc tools/validate-verify-json.swift -o /tmp/validate-verify-json-task6` passed, and `git diff --check` passed.

## 2026-08-24 correction

- Restored the legacy `verify.json is unavailable or contains a symbolic link` rejection diagnostic for an arbitrary/noncanonical `.artifacts` symlink root. The exact shared-store path remains the sole exception and continues to emit its specific diagnostics after canonical worktree identity is established.
- Verification: full `bash tools/tests/test-ios-evidence.sh` passed (`all iOS evidence validator tests passed`); `swiftc tools/validate-verify-json.swift -o /tmp/validate-verify-json-task6-correction` and `git diff --check` passed.
