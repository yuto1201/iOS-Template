#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-ownership.XXXXXX")
trap 'rm -rf "$workspace"' EXIT

write_fixture() {
  cat >"$workspace/ownership.yml" <<'EOF'
schemaVersion: 2
github:
  login: yuto1201
supabase:
  organizationId: kmjpkzaqlewqnypyqwkg
  organizationName: "yuto1201's Org"
  projectRef: personal-project
cloudflare:
  accountId: personal-cloudflare
  accountName: Yuto Dev
  plan: free
  target: personal-worker
linear:
  workspaceSlug: yuto33004
  workspaceUrl: https://linear.app/yuto33004
  teamKey: YUT
vercel:
  teamId: team_ANEUn6gVL8dccPaY08wkvxFt
  teamSlug: yuto16
  plan: hobby
  projectId: personal-vercel-project
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
grep -Fq 'organizationName: "yuto1201'"'"'s Org"' "$workspace/ownership.yml" || { echo 'Supabase organization display name is not exact' >&2; exit 1; }
assert_provider supabase '{"account":"kmjpkzaqlewqnypyqwkg","target":"personal-project"}'
assert_provider cloudflare '{"account":"personal-cloudflare","target":"personal-worker"}'
assert_provider linear '{"account":"yuto33004","target":"YUT"}'
assert_provider vercel '{"account":"team_ANEUn6gVL8dccPaY08wkvxFt","target":"yuto16"}'
assert_provider elevenlabs '{"account":"personal-elevenlabs","target":"personal-workspace"}'
assert_provider app-store '{"account":"PERSONALTEAM","target":"com.yuto1201.personal"}'

ruby -e 'path=ARGV.fetch(0); text=File.binread(path); File.binwrite(path,text.sub("organizationId: kmjpkzaqlewqnypyqwkg","organizationId: company"))' "$workspace/ownership.yml"
assert_provider supabase '{"account":"company","target":"personal-project"}'

write_fixture
ruby -e 'path=ARGV.fetch(0); text=File.binread(path); File.binwrite(path,text.sub("projectRef: personal-project","projectRef: Personal-Project"))' "$workspace/ownership.yml"
assert_provider supabase '{"account":"kmjpkzaqlewqnypyqwkg","target":"Personal-Project"}'

for replacement in \
  'projectRef: personal-project|projectRef: null' \
  'target: personal-worker|target: null' \
  'teamKey: YUT|teamKey: null' \
  'teamSlug: yuto16|teamSlug: null' \
  'workspaceId: personal-workspace|workspaceId: null' \
  'bundleId: com.yuto1201.personal|bundleId: null'; do
  write_fixture
  from=${replacement%%|*}; to=${replacement#*|}
  FROM="$from" TO="$to" ruby -e 'path=ARGV.fetch(0); text=File.binread(path); File.binwrite(path,text.sub(ENV.fetch("FROM"),ENV.fetch("TO")))' "$workspace/ownership.yml"
  case "$from" in
    projectRef*) provider=supabase ;;
    target*) provider=cloudflare ;;
    teamKey*) provider=linear ;;
    teamSlug*) provider=vercel ;;
    workspaceId*) provider=elevenlabs ;;
    bundleId*) provider=app-store ;;
  esac
  assert_fails "$provider null target" read_provider "$provider"
done

write_fixture
printf '\nunknown: true\n' >>"$workspace/ownership.yml"
assert_fails 'unknown ownership field' read_provider supabase

echo 'PASS: provider ownership schema maps exact configured account and target identifiers independently of model identity'
