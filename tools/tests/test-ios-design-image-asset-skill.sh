#!/bin/bash
set -euo pipefail

# D-090: ios-design-image-asset is the repository adapter over the shared Mac skill. It keeps the gates for this
# repository (when it may be used, verification, evidence) and leaves the authoring procedures to the
# shared skill, which this test does not require to exist.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" python3

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)

[[ -L "$repo_root/.claude/skills/ios-design-image-asset" &&
   "$(readlink "$repo_root/.claude/skills/ios-design-image-asset")" == "../../.agents/skills/ios-design-image-asset" ]] || {
  echo "Claude alias for ios-design-image-asset must point to the shared skill" >&2
  exit 1
}

python3 - "$repo_root/.agents/skills/ios-design-image-asset/SKILL.md" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
match = re.match(r"\A---\n(.*?)\n---\n", text, re.S)
if not match:
    sys.exit("ios-design-image-asset: frontmatter is missing")
keys = [line.split(":", 1)[0] for line in match.group(1).splitlines() if line and not line.startswith(" ")]
if keys != ["name", "description"] or "name: ios-design-image-asset\n" not in match.group(0):
    sys.exit("ios-design-image-asset: frontmatter must hold exactly name and description")
required = (
    "`design-image-asset`",
    "`~/.agents/skills/design-image-asset/`",
    "this adapter, D-090, and `AGENTS.md` take precedence over the shared skill",
    "stop as `blocked:environment` before authoring",
    "`codex-imagegen`, `low-poly`, `vector`, or `elevenlabs`",
    "built-in `image_gen`",
    "Never draw text into the image",
    "Light and Dark",
    "maximum file size",
    "rights",
    "validate-visual.sh",
    "`image`",
    "PNG",
    "`blocked:user`",
    "[`app-icon`](../app-icon/SKILL.md)",
    "`appstore-creative`",
    "`ios-design-2d-asset`",
    "`ios-3d-assets`",
)
failures = [f"ios-design-image-asset lacks {anchor!r}" for anchor in required if anchor not in text]
if len(text.splitlines()) > 90:
    failures.append("ios-design-image-asset must stay a thin adapter (90 lines or fewer)")
if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
PY

echo "ios-design-image-asset adapter tests passed"
