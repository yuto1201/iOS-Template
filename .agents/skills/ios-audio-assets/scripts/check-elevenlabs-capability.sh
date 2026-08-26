#!/bin/bash
set -euo pipefail

script_directory=$(cd "$(dirname "$0")" && pwd -P)
repository_root=$(cd "$script_directory/../../../.." && pwd -P)

fail() {
  printf '%s\n' "ElevenLabs capability check refused: $1" >&2
  exit 1
}

[[ $# -eq 4 && $1 == --capability && $3 == --provider-status ]] || {
  echo 'usage: check-elevenlabs-capability.sh --capability sound-effect|music|bgm --provider-status available|paid_plan_required|unavailable' >&2
  exit 2
}
capability=${2:-}
provider_status=${4:-}
[[ "$capability" =~ ^(sound-effect|music|bgm)$ ]] || fail 'capability is invalid'
[[ "$provider_status" =~ ^(available|paid_plan_required|unavailable)$ ]] || fail 'provider status is invalid'

source_name=''
skill_file=''
if [[ "${IOS_TEMPLATE_TEST_MODE:-}" == 1 ]]; then
  [[ -n "${IOS_TEMPLATE_TEST_SKILL_ROOTS:-}" ]] || fail 'test skill roots are missing'
  IFS=: read -r -a skill_roots <<< "$IOS_TEMPLATE_TEST_SKILL_ROOTS"
  source_name=test
else
  [[ -z "${IOS_TEMPLATE_TEST_SKILL_ROOTS:-}" ]] || fail 'test skill roots are not allowed in production mode'
  skill_roots=(
    "$repository_root/.agents/skills"
    "${HOME:?}/.agents/skills"
    "${HOME:?}/.codex/skills"
  )
fi

for skill_root in "${skill_roots[@]}"; do
  candidate="$skill_root/generating-elevenlabs-audio/SKILL.md"
  if [[ -f "$candidate" && ! -L "$candidate" ]]; then
    /usr/bin/ruby -ryaml -e '
      text=File.binread(ARGV.fetch(0)); match=text.match(/\A---\n(.*?)\n---\n/m) or abort
      value=YAML.safe_load(match[1], permitted_classes: [], aliases: false)
      abort unless value.is_a?(Hash) && value["name"] == "generating-elevenlabs-audio"
    ' "$candidate" 2>/dev/null || continue
    skill_file=$candidate
    if [[ -z "$source_name" ]]; then
      if [[ "$skill_root" == "$repository_root/.agents/skills" ]]; then source_name=repository; else source_name=user; fi
    fi
    break
  fi
done
[[ -n "$skill_file" ]] || {
  printf '{"capability":"%s","reason":"capability_missing","retry":false,"status":"blocked:ops"}\n' "$capability"
  exit 3
}

case "$provider_status" in
  available)
    printf '{"capability":"%s","source":"%s","status":"available"}\n' "$capability" "$source_name"
    ;;
  paid_plan_required)
    printf '{"capability":"%s","reason":"paid_plan_required","retry":false,"status":"blocked:ops"}\n' "$capability"
    exit 3
    ;;
  unavailable)
    printf '{"capability":"%s","reason":"provider_unavailable","retry":false,"status":"blocked:ops"}\n' "$capability"
    exit 3
    ;;
esac
