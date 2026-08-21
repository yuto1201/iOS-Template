#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "bootstrap-app: $*" >&2
  exit 1
}

usage() {
  die 'usage: bootstrap-app.sh --display-name NAME --module-name MODULE --app-slug SLUG --bundle-id ID'
}

emit_result() {
  python3 - "$1" "$module_name" "$app_slug" "$bundle_id" <<'PY'
import json
import sys

print(json.dumps({
    "status": sys.argv[1],
    "resultRecordPath": "Config/app-identity.json",
    "moduleName": sys.argv[2],
    "appSlug": sys.argv[3],
    "bundleId": sys.argv[4],
}, sort_keys=True, separators=(",", ":")))
PY
}

display_name=''
module_name=''
app_slug=''
bundle_id=''

[[ $# -eq 8 ]] || usage
while [[ $# -gt 0 ]]; do
  flag="$1"
  value="$2"
  shift 2
  case "$flag" in
    --display-name) [[ -z "$display_name" ]] || usage; display_name="$value" ;;
    --module-name) [[ -z "$module_name" ]] || usage; module_name="$value" ;;
    --app-slug) [[ -z "$app_slug" ]] || usage; app_slug="$value" ;;
    --bundle-id) [[ -z "$bundle_id" ]] || usage; bundle_id="$value" ;;
    *) usage ;;
  esac
done

caller_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die 'must run inside a Git repository'
caller_root="$(cd "$caller_root" && pwd -P)"
[[ "$(pwd -P)" == "$caller_root" ]] || die 'must run from the repository root'

caller_branch="$(git -C "$caller_root" symbolic-ref --quiet --short HEAD 2>/dev/null)" || die 'must run on a symbolic branch'
default_branch_ref="$(git -C "$caller_root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)" || die 'caller default branch reference is unavailable'
[[ "$default_branch_ref" == refs/remotes/origin/* && "$default_branch_ref" != 'refs/remotes/origin/' ]] || die 'caller default branch reference is invalid'
git -C "$caller_root" show-ref --verify --quiet "$default_branch_ref" || die 'caller default branch reference is unavailable'
default_branch="${default_branch_ref#refs/remotes/origin/}"
[[ "$caller_branch" != "$default_branch" ]] || die 'must not run on the caller default branch'

manifest="$caller_root/Config/template-identity.json"
identity_record="$caller_root/Config/app-identity.json"
[[ -f "$manifest" && ! -L "$manifest" && -r "$manifest" ]] || die 'manifest must be a readable regular file'
[[ -f "$caller_root/tools/bootstrap-app.swift" && ! -L "$caller_root/tools/bootstrap-app.swift" ]] || die 'bootstrap helper is missing'

swift "$caller_root/tools/bootstrap-app.swift" validate \
  --manifest "$manifest" \
  --display-name "$display_name" \
  --module-name "$module_name" \
  --app-slug "$app_slug" \
  --bundle-id "$bundle_id" >/dev/null

if [[ -e "$identity_record" || -L "$identity_record" ]]; then
  [[ -f "$identity_record" && ! -L "$identity_record" ]] || die 'app identity must be a regular file'
  if python3 - "$identity_record" "$display_name" "$module_name" "$app_slug" "$bundle_id" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    identity = json.load(source)

expected = {
    "schemaVersion": 1,
    "sourceIdentityVersion": 1,
    "displayName": sys.argv[2],
    "moduleName": sys.argv[3],
    "appSlug": sys.argv[4],
    "bundleId": sys.argv[5],
}
raise SystemExit(0 if identity == expected else 1)
PY
  then
    swift "$caller_root/tools/bootstrap-app.swift" audit \
      --root "$caller_root" \
      --manifest "$manifest" \
      --module-name "$module_name" >/dev/null || die 'existing app identity failed residual audit'
    emit_result 'already-complete'
    exit 0
  fi
  die 'app identity already exists for another identity'
fi

[[ -z "$(git -C "$caller_root" status --porcelain=v1)" ]] || die 'caller worktree must be clean'

start_head="$(git -C "$caller_root" rev-parse HEAD)"
stage_parent=''
stage_worktree=''
patch_file=''
stage_registered=false

cleanup() {
  local original_status=$?
  local registered_worktree=''
  if [[ "$stage_registered" == true ]]; then
    registered_worktree="$(git -C "$caller_root" worktree list --porcelain 2>/dev/null | awk -v path="$stage_worktree" '$0 == "worktree " path { print; exit }')"
    if [[ "$registered_worktree" != "worktree $stage_worktree" ]]; then
      echo "bootstrap-app: cleanup failed; staging worktree retained: $stage_worktree" >&2
      return 1
    fi
    if ! git -C "$caller_root" worktree remove --force "$stage_worktree" >/dev/null; then
      echo "bootstrap-app: cleanup failed; staging worktree retained: $stage_worktree" >&2
      return 1
    fi
    stage_registered=false
  fi
  if [[ "$stage_parent" == /tmp/ios-template-bootstrap.* && "$stage_parent" != '/tmp/ios-template-bootstrap.' ]]; then
    rm -rf -- "$stage_parent"
  fi
  return "$original_status"
}
trap cleanup EXIT

stage_parent="$(mktemp -d /tmp/ios-template-bootstrap.XXXXXX)"
stage_worktree="$(cd "$stage_parent" && pwd -P)/worktree"
patch_file="$stage_parent/bootstrap.patch"
git -C "$caller_root" worktree add --detach "$stage_worktree" "$start_head" >/dev/null
stage_registered=true

swift "$stage_worktree/tools/bootstrap-app.swift" apply \
  --root "$stage_worktree" \
  --manifest "$stage_worktree/Config/template-identity.json" \
  --display-name "$display_name" \
  --module-name "$module_name" \
  --app-slug "$app_slug" \
  --bundle-id "$bundle_id" >/dev/null

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -list -json -project "$stage_worktree/$module_name.xcodeproj" >/dev/null

changed_paths=()
while IFS= read -r path; do
  [[ -n "$path" && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || die 'invalid controlled path'
  changed_paths+=("$path")
done < <(swift "$stage_worktree/tools/bootstrap-app.swift" changed-paths \
  --root "$stage_worktree" \
  --manifest "$stage_worktree/Config/template-identity.json")
[[ ${#changed_paths[@]} -gt 0 ]] || die 'no controlled paths were produced'

path_is_controlled() {
  local candidate="$1"
  local controlled
  for controlled in "${changed_paths[@]}"; do
    [[ "$candidate" == "$controlled" || "$candidate" == "$controlled/"* ]] && return 0
  done
  return 1
}

while IFS= read -r -d '' path; do
  path_is_controlled "$path" || die "staging changed an uncontrolled path: $path"
done < <(
  git -C "$stage_worktree" diff --name-only -z
  git -C "$stage_worktree" ls-files --others --exclude-standard -z
)

tracked_paths=()
present_paths=()
for path in "${changed_paths[@]}"; do
  if git -C "$stage_worktree" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
    tracked_paths+=("$path")
  fi
  if [[ -e "$stage_worktree/$path" ]]; then
    present_paths+=("$path")
  fi
done
[[ ${#tracked_paths[@]} -gt 0 && ${#present_paths[@]} -gt 0 ]] || die 'controlled paths do not cover the staged transformation'
git -C "$stage_worktree" add -u -- "${tracked_paths[@]}"
git -C "$stage_worktree" add -- "${present_paths[@]}"
git -C "$stage_worktree" diff --cached --binary --full-index > "$patch_file"
[[ -s "$patch_file" ]] || die 'staging patch is empty'

[[ "$(git -C "$caller_root" rev-parse HEAD)" == "$start_head" ]] || die 'caller HEAD changed during staging'
[[ -z "$(git -C "$caller_root" status --porcelain=v1)" ]] || die 'caller worktree changed during staging'
git -C "$caller_root" apply --check --index "$patch_file"
git -C "$caller_root" apply --index "$patch_file"
git -C "$caller_root" reset HEAD -- "${changed_paths[@]}" >/dev/null
[[ -z "$(git -C "$caller_root" diff --cached --name-only)" ]] || die 'bootstrap changes must remain unstaged'

git -C "$caller_root" worktree remove --force "$stage_worktree" >/dev/null
stage_registered=false
stage_worktree=''
emit_result 'applied'
