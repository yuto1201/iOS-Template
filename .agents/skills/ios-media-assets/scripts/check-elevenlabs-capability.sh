#!/bin/bash
set -euo pipefail

script_directory=$(cd "$(dirname "$0")" && pwd -P)
skill_root=$(cd "$script_directory/.." && pwd -P)

fail() {
  printf '%s\n' "ElevenLabs capability check refused: $1" >&2
  exit 1
}

[[ $# -eq 4 && $1 == --capability && $3 == --provider-status ]] || {
  echo 'usage: check-elevenlabs-capability.sh --capability text-to-speech|speech-to-speech|speech-to-text|sound-effect|audio-isolation|music|image|video --provider-status available|paid_plan_required|permission_required|unavailable' >&2
  exit 2
}
capability=${2:-}
provider_status=${4:-}
[[ "$capability" =~ ^(text-to-speech|speech-to-speech|speech-to-text|sound-effect|audio-isolation|music|image|video)$ ]] || fail 'capability is invalid'
[[ "$provider_status" =~ ^(available|paid_plan_required|permission_required|unavailable)$ ]] || fail 'provider status is invalid'

/usr/bin/ruby -ryaml -e '
  text=File.binread(ARGV.fetch(0)); match=text.match(/\A---\n(.*?)\n---\n/m) or abort
  value=YAML.safe_load(match[1], permitted_classes: [], aliases: false)
  abort unless value.is_a?(Hash) && value["name"] == "ios-media-assets"
' "$skill_root/SKILL.md" 2>/dev/null || fail 'repository media skill is invalid'

case "$provider_status" in
  available)
    printf '{"capability":"%s","source":"repository","status":"available"}\n' "$capability"
    ;;
  *)
    printf '{"capability":"%s","reason":"%s","retry":false,"status":"blocked:ops"}\n' "$capability" "$provider_status"
    exit 3
    ;;
esac
