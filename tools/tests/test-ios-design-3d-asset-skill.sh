#!/bin/bash
set -euo pipefail

# D-082: 3D authoring chooses its route by model complexity: Claude in Blender for very simple shapes,
# the Codex loop (gpt-6.1-sol reference images and gpt-6-astra models, both xhigh) for simple models and
# simple part motion, and Tripo in the browser for complex or skeleton-rigged models. The skill and every
# guidance document must keep that route and must not reintroduce the superseded Tripo-by-default rule
# (D-071) or the gpt-6-astra-only rule (D-032).

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" python3

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)

[[ -L "$repo_root/.claude/skills/ios-design-3d-asset" &&
   "$(readlink "$repo_root/.claude/skills/ios-design-3d-asset")" == "../../.agents/skills/ios-design-3d-asset" ]] || {
  echo "Claude alias for ios-design-3d-asset must point to the shared skill" >&2
  exit 1
}

python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

required = {
    ".agents/skills/ios-design-3d-asset/SKILL.md": (
        "name: ios-design-3d-asset",
        "## Authoring routes (D-082)",
        "`claude`, `codex`, or `tripo`",
        "### Choosing the route",
        "Shape", "Number of parts", "Texture", "Motion",
        "`blocked:user`",
        "## Shared authoring skill",
        "`design-3d-asset`",
        "`~/.agents/skills/design-3d-asset/`",
        "D-082 and `AGENTS.md` take precedence over the shared skill",
        "stop as `blocked:environment` before authoring",
        "Codex `gpt-6.1-sol` with reasoning effort `xhigh`",
        "Codex `gpt-6-astra` with reasoning effort `xhigh`",
        "`blocked:environment`; never substitute another model",
        "At most 5 rounds",
        "switch to Tripo",
        "## Tripo safety",
        "The user signs in, changes the plan or billing, and enters any credentials.",
        "never buys credits",
        "already signed-in session",
        "expected credit cost and wait for approval",
        "stop before any credit-spending operation and report the difference",
        "commercial use",
        "## App budgets and verification",
        "5,000 or fewer", "1024 px", "2 MB or less",
        "30,000 or fewer", "2048 px", "10 MB or less",
        "RealityKit",
        "Light and Dark",
    ),
    "AGENTS.md": (
        "[3D Asset skill](.agents/skills/ios-design-3d-asset/SKILL.md)に従い、経路をモデルの複雑さで選ぶ（D-082）",
        "ごく単純な形はClaudeがBlenderで直接作れる",
        "`gpt-6.1-sol`（reasoning effort `xhigh`）",
        "`gpt-6-astra`（reasoning effort `xhigh`）",
        "骨格で動くモデルだけを、ユーザーまたはClaudeがブラウザでTripoを操作して作る",
        "Tripoのログイン、プランや課金の変更、認証情報の入力はユーザーが行い",
        "クレジットを使う操作は毎回ユーザーの承認を得る",
        "authoringの経路を記録する",
    ),
    "docs/README.md": ("D-082", "Tripo", "`gpt-6.1-sol`（reasoning effort `xhigh`）", "`gpt-6-astra`（reasoning effort `xhigh`）"),
    "docs/workflow.md": ("### 2.3 3D authoring route", "D-082", "Tripo", "`gpt-6.1-sol`（reasoning effort `xhigh`）", "`gpt-6-astra`（reasoning effort `xhigh`）", "5回まで"),
    "docs/verification.md": ("authoringの経路（`claude`、`codex`", "`tripo`", "D-082"),
    "specs/acceptance.md": ("Tripo", "`gpt-6-astra`（reasoning effort `xhigh`）", "authoringの経路", "D-082"),
    "specs/architecture.md": ("Tripo", "`gpt-6-astra`（reasoning effort `xhigh`）", "D-082"),
    "specs/product.md": ("### 5.1 3Dモデル制作方針", "Tripo", "D-082", "5回まで", "三角形5,000以下", "三角形30,000以下"),
    "specs/decisions.md": ("## D-082: 3Dモデルの作成経路を、モデルの複雑さで選ぶ", "Related Issue: #318"),
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
    # Phrases of the superseded D-071 default.
    "標準はユーザーまたはClaudeがブラウザでTripoを操作して作る",
    "ブラウザで操作するTripoを標準とし",
    "Tripoを標準とし",
    "簡単なモデルや即効性を求める場合",
    "### Standard route: Tripo in the browser",
    "### Quick route: Claude or Codex `gpt-6-astra`",
)

# #356: specs/product.md belongs to the app (tools/template-sync/ownership.json). An app that adopted the
# template (it records Config/template-base.json, D-074) keeps its own product specification, so the template's
# section 5.1 is checked only in the template; the skill and the imported guidance above carry D-082 there.
if (root / "Config/template-base.json").is_file():
    del required["specs/product.md"]

# #435: ios-design-3d-asset is a thin adapter over the shared Mac skill design-3d-asset. The authoring
# procedures live there, so the adapter must not carry them again.
adapter_procedures = (
    "## Claude route",
    "## Codex route",
    "### A set of models: style reference first",
    "two style reference images",
    "front, side, top, and a three-quarter view",
    "multi-view generation",
    "set the number of generations to 4",
    "first 3 fixes spend no credits",
    "Never generate a model from text alone",
    "UI checked",
)

failures = []
adapter_text = (root / ".agents/skills/ios-design-3d-asset/SKILL.md").read_text(encoding="utf-8")
for phrase in adapter_procedures:
    if phrase in adapter_text:
        failures.append(f".agents/skills/ios-design-3d-asset/SKILL.md keeps shared-skill procedure {phrase!r}")
if len(adapter_text.splitlines()) > 65:
    failures.append(".agents/skills/ios-design-3d-asset/SKILL.md must stay a thin adapter (65 lines or fewer)")
for relative, anchors in required.items():
    text = (root / relative).read_text(encoding="utf-8")
    for anchor in anchors:
        if anchor not in text:
            failures.append(f"{relative} lacks {anchor!r}")
    if relative == "specs/decisions.md":
        continue
    for phrase in forbidden:
        if phrase in text:
            failures.append(f"{relative} keeps superseded 3D rule {phrase!r}")

if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
PY

echo "ios-design-3d-asset skill route tests passed"
