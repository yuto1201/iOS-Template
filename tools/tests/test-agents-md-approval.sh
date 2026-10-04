#!/bin/bash
set -euo pipefail

# D-075: every AGENTS.md change needs the user's approval of its exact text, recorded on the Issue.
# docs/agents-md-approvals.md keeps a copy of each record; the current AGENTS.md must match the last one.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" python3

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)

check() {
  python3 - "$1" <<'PY'
from pathlib import Path
import hashlib
import re
import sys

root = Path(sys.argv[1])
ledger = (root / "docs/agents-md-approvals.md").read_text(encoding="utf-8")
agents = (root / "AGENTS.md").read_bytes()

entries = re.split(r"^## ", ledger, flags=re.M)[1:]
if not entries:
    sys.exit("docs/agents-md-approvals.md has no approval record")
latest = entries[-1]

comment = re.search(r"^- 承認を記録したIssueコメント: (https://github\.com/[^/\s]+/[^/\s]+/issues/(\d+)#issuecomment-\d+)", latest, re.M)
issue = re.search(r"^- Issue: #(\d+)$", latest, re.M)
if not comment or not issue or comment.group(2) != issue.group(1):
    sys.exit("the latest AGENTS.md approval record lacks its Issue and Issue comment URL")

recorded = re.search(r"^- 承認後の`AGENTS\.md`（1行目を除く）のSHA-256: `sha256:([0-9a-f]{64})`$", latest, re.M)
# Identity bootstrap rewrites only the first heading line, so the digest covers everything after it.
actual = hashlib.sha256(agents.split(b"\n", 1)[1] if b"\n" in agents else b"").hexdigest()
if not recorded or recorded.group(1) != actual:
    sys.exit("AGENTS.md changed without a recorded user approval (D-075); "
             "show the exact text to the user, record the approval on the Issue, and append it to docs/agents-md-approvals.md")

diff = re.search(r"^```diff\n(.*?)^```$", latest, re.M | re.S)
if not diff:
    sys.exit("the latest AGENTS.md approval record lacks the approved diff")
lines = set(agents.decode("utf-8").splitlines())
for line in diff.group(1).splitlines():
    if line.startswith(("+++", "---", "@@")):
        continue
    if line.startswith("+") and line[1:] not in lines:
        sys.exit(f"AGENTS.md lacks an approved line: {line[1:80]!r}")
    if line.startswith("-") and line[1:] in lines:
        sys.exit(f"AGENTS.md keeps a line the approval removed: {line[1:80]!r}")
PY
}

check "$repo_root"

# Negative cases on a copy: an unrecorded edit and a mismatched approved line must fail.
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-agents-approval.XXXXXX")
trap 'rm -rf -- "$workspace"' EXIT
mkdir -p "$workspace/docs"
cp "$repo_root/docs/agents-md-approvals.md" "$workspace/docs/agents-md-approvals.md"

expect_failure() {
  local label=$1 message=$2
  if check "$workspace" >"$workspace/$label.out" 2>&1; then
    echo "AGENTS.md approval check accepted $label" >&2
    exit 1
  fi
  grep -Fq -- "$message" "$workspace/$label.out" || { echo "unexpected failure for $label" >&2; cat "$workspace/$label.out" >&2; exit 1; }
}

{ head -n 1 "$repo_root/AGENTS.md" | sed 's/.*/# Derived App agent contract/'; tail -n +2 "$repo_root/AGENTS.md"; } > "$workspace/AGENTS.md"
check "$workspace" || { echo 'a bootstrapped AGENTS.md heading must not invalidate the approval' >&2; exit 1; }

cp "$repo_root/AGENTS.md" "$workspace/AGENTS.md"
printf '%s\n' '- 承認されていない規則。' >> "$workspace/AGENTS.md"
expect_failure unrecorded-edit 'AGENTS.md changed without a recorded user approval'

cp "$repo_root/AGENTS.md" "$workspace/AGENTS.md"
python3 - "$workspace/docs/agents-md-approvals.md" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
marker = "\n+- `AGENTS.md`を書き換えるときは"
assert marker in text
path.write_text(text.replace(marker, "\n+- 別の文面。\n+- `AGENTS.md`を書き換えるときは", 1), encoding="utf-8")
PY
expect_failure unapproved-line 'AGENTS.md lacks an approved line'

echo "AGENTS.md approval record tests passed"
