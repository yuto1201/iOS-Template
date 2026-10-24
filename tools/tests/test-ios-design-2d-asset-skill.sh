#!/bin/bash
set -euo pipefail

# D-090: ios-design-2d-asset is the repository adapter over the shared Mac skill. It keeps the gates for this
# repository (when it may be used, verification, evidence) and leaves the authoring procedures to the
# shared skill, which this test does not require to exist.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" python3

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)

[[ -L "$repo_root/.claude/skills/ios-design-2d-asset" &&
   "$(readlink "$repo_root/.claude/skills/ios-design-2d-asset")" == "../../.agents/skills/ios-design-2d-asset" ]] || {
  echo "Claude alias for ios-design-2d-asset must point to the shared skill" >&2
  exit 1
}

python3 - "$repo_root/.agents/skills/ios-design-2d-asset/SKILL.md" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
match = re.match(r"\A---\n(.*?)\n---\n", text, re.S)
if not match:
    sys.exit("ios-design-2d-asset: frontmatter is missing")
keys = [line.split(":", 1)[0] for line in match.group(1).splitlines() if line and not line.startswith(" ")]
if keys != ["name", "description"] or "name: ios-design-2d-asset\n" not in match.group(0):
    sys.exit("ios-design-2d-asset: frontmatter must hold exactly name and description")
required = (
    "`design-2d-asset`",
    "`~/.agents/skills/design-2d-asset/`",
    "this adapter, D-090, and `AGENTS.md` take precedence over the shared skill",
    "stop as `blocked:environment` before authoring",
    "`swiftui`, `remotion`, `rive`, or `elevenlabs`",
    "Reduce Motion",
    "Dark appearance",
    "VoiceOver",
    "only while it is on screen",
    "`RiveRuntime`",
    "paid Rive plan",
    "maximum file size and duration",
    "validate-visual.sh",
    "`video`",
    "tools/provider-preflight.sh",
    "tools/run-with-secret.sh",
    "`retry: false`",
    "`blocked:user`",
    "`appstore-creative`",
    "`ios-design-image-asset`",
    "`ios-3d-assets`",
)
failures = [f"ios-design-2d-asset lacks {anchor!r}" for anchor in required if anchor not in text]
if len(text.splitlines()) > 90:
    failures.append("ios-design-2d-asset must stay a thin adapter (90 lines or fewer)")
if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
PY

echo "ios-design-2d-asset adapter tests passed"
