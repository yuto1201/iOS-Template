#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-ownership.XXXXXX")
trap 'rm -rf "$workspace"' EXIT

write_fixture() {
  cat >"$workspace/ownership.yml" <<'EOF'
schemaVersion: 1
github:
  login: yuto1201
supabase:
  organization: YUTO1201
  projectRef: personal-project
cloudflare:
  accountId: personal-cloudflare
  target: personal-worker
elevenlabs:
  accountId: personal-elevenlabs
  workspaceId: personal-workspace
appStore:
  teamId: PERSONALTEAM
  bundleId: com.yuto1201.personal
EOF
}

assert_fails() {
  local label=$1
  shift
  if "$@" >"$workspace/output" 2>&1; then
    echo "expected failure: $label" >&2
    exit 1
  fi
}

read_provider() {
  ruby "$repo_root/tools/lib/ownership.rb" --file "$workspace/ownership.yml" --provider "$1"
}

assert_provider() {
  local provider=$1 expected=$2 actual
  actual=$(read_provider "$provider") || { echo "provider read failed: $provider" >&2; exit 1; }
  [[ "$actual" == "$expected" ]] || { echo "provider mismatch: $provider: $actual" >&2; exit 1; }
}

write_fixture
assert_provider supabase '{"account":"YUTO1201","target":"personal-project"}'
assert_provider cloudflare '{"account":"personal-cloudflare","target":"personal-worker"}'
assert_provider elevenlabs '{"account":"personal-elevenlabs","target":"personal-workspace"}'
assert_provider app-store '{"account":"PERSONALTEAM","target":"com.yuto1201.personal"}'

ruby -e 'path=ARGV.fetch(0); text=File.binread(path); File.binwrite(path,text.sub("organization: YUTO1201","organization: Company"))' "$workspace/ownership.yml"
assert_provider supabase '{"account":"Company","target":"personal-project"}'

write_fixture
ruby -e 'path=ARGV.fetch(0); text=File.binread(path); File.binwrite(path,text.sub("projectRef: personal-project","projectRef: Personal-Project"))' "$workspace/ownership.yml"
assert_provider supabase '{"account":"YUTO1201","target":"Personal-Project"}'

for replacement in \
  'projectRef: personal-project|projectRef: null' \
  'target: personal-worker|target: null' \
  'workspaceId: personal-workspace|workspaceId: null' \
  'bundleId: com.yuto1201.personal|bundleId: null'; do
  write_fixture
  from=${replacement%%|*}; to=${replacement#*|}
  FROM="$from" TO="$to" ruby -e 'path=ARGV.fetch(0); text=File.binread(path); File.binwrite(path,text.sub(ENV.fetch("FROM"),ENV.fetch("TO")))' "$workspace/ownership.yml"
  case "$from" in
    projectRef*) provider=supabase ;;
    target*) provider=cloudflare ;;
    workspaceId*) provider=elevenlabs ;;
    bundleId*) provider=app-store ;;
  esac
  assert_fails "$provider null target" read_provider "$provider"
done

write_fixture
printf '\nunknown: true\n' >>"$workspace/ownership.yml"
assert_fails 'unknown ownership field' read_provider supabase

echo 'PASS: provider ownership schema maps exact configured personal account and target identifiers'
