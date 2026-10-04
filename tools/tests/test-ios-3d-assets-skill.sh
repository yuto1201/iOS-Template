#!/bin/bash
set -euo pipefail

# D-071: 3D authoring uses Tripo in the browser by default, and Claude or Codex gpt-6-astra (xhigh)
# for simple or quick models. The skill and every guidance document must keep that route and must
# not reintroduce the superseded gpt-6-astra-only rule.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" python3

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)

[[ -L "$repo_root/.claude/skills/ios-3d-assets" &&
   "$(readlink "$repo_root/.claude/skills/ios-3d-assets")" == "../../.agents/skills/ios-3d-assets" ]] || {
  echo "Claude alias for ios-3d-assets must point to the shared skill" >&2
  exit 1
}

python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

required = {
    ".agents/skills/ios-3d-assets/SKILL.md": (
        "name: ios-3d-assets",
        "## Authoring routes (D-071)",
        "### Standard route: Tripo in the browser",
        "The user signs in, changes the plan or billing, and enters any credentials.",
        "never buys credits",
        "already signed-in session",
        "commercial use",
        "### Quick route: Claude or Codex `gpt-6-astra`",
        "reasoning effort `xhigh`",
        "`tripo`, `claude`, or `gpt-6-astra`",
        "RealityKit",
        "`blocked:user`",
    ),
    "AGENTS.md": (
        "[3D Asset skill](.agents/skills/ios-3d-assets/SKILL.md)に従う",
        "ブラウザでTripoを操作して作る経路",
        "`gpt-6-astra`（reasoning effort `xhigh`）",
        "Tripoのログイン、プランや課金の変更、認証情報の入力はユーザーが行う",
        "authoringの経路を記録する",
    ),
    "docs/README.md": ("Tripo", "`gpt-6-astra`（reasoning effort `xhigh`）"),
    "docs/workflow.md": ("### 2.3 3D authoring route", "Tripo", "`gpt-6-astra`（reasoning effort `xhigh`）", "D-071"),
    "docs/verification.md": ("authoringの経路（Tripo、Claude、またはCodex `gpt-6-astra`）",),
    "specs/acceptance.md": ("Tripo", "`gpt-6-astra`（reasoning effort `xhigh`）", "authoringの経路"),
    "specs/architecture.md": ("Tripo", "`gpt-6-astra`（reasoning effort `xhigh`）", "D-071"),
    "specs/product.md": ("### 5.1 3Dモデル制作方針", "Tripo", "D-071"),
}

# Phrases of the superseded D-032 exclusivity. specs/decisions.md keeps D-032 as history.
forbidden = (
    "exact model identifier `gpt-6-astra`",
    "exclusively to Codex",
    "別modelへfallbackせず停止",
    "Codexのexact model `gpt-6-astra`だけ",
    "authoringをCodexのexact model `gpt-6-astra`へ固定",
    "3D asset authoringだけをCodex `gpt-6-astra`へ固定",
    "authoring modelをexact `gpt-6-astra`",
    "authoring modelがexact `gpt-6-astra`",
)

failures = []
for relative, anchors in required.items():
    text = (root / relative).read_text(encoding="utf-8")
    for anchor in anchors:
        if anchor not in text:
            failures.append(f"{relative} lacks {anchor!r}")
    for phrase in forbidden:
        if phrase in text:
            failures.append(f"{relative} keeps superseded 3D rule {phrase!r}")

if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
PY

echo "ios-3d-assets skill route tests passed"
