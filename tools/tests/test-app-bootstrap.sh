#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
if [[ "$mode" != "validation" && "$mode" != "transform" && "$mode" != "transaction" && "$mode" != "trunk-default" && "$mode" != "cleanup-failure" && "$mode" != "safety" && "$mode" != "all" ]]; then
  echo "usage: $0 validation|transform|transaction|trunk-default|cleanup-failure|safety|all" >&2
  exit 64
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
source "$root/tools/lib/bounded-command.sh"

manifest="Config/template-identity.json"
bootstrap="tools/bootstrap-app.swift"
output="$(mktemp -t app-bootstrap-output.XXXXXX)"
errors="$(mktemp -t app-bootstrap-errors.XXXXXX)"
fixture=""
escaped_fixture=""
trap 'rm -f "$output" "$errors"; [[ -z "$fixture" ]] || rm -rf "$fixture"; [[ -z "$escaped_fixture" ]] || rm -rf "$escaped_fixture"' EXIT

if [[ "$mode" == "all" ]]; then
  for suite in validation transform transaction trunk-default cleanup-failure safety; do
    bash "$0" "$suite"
  done
  echo 'all app bootstrap tests passed'
  exit 0
fi

fixture_hash() {
  {
    find TemplateApp TemplateAppTests TemplateAppUITests TemplateApp.xcodeproj Config specs docs -type f -print
    printf '%s\n' AGENTS.md README.md
  } | LC_ALL=C sort | while IFS= read -r path; do
    shasum "$path"
  done | shasum | awk '{print $1}'
}

source_tree_digest() {
  git ls-files -z | while IFS= read -r -d '' path; do
    if [[ -L "$path" ]]; then
      printf 'symlink %s %s\n' "$path" "$(readlink "$path")"
    else
      shasum "$path"
    fi
  done | shasum | awk '{print $1}'
}

repository_content_digest() {
  python3 - "$1" <<'PY'
import hashlib
import os
import sys

root = os.path.abspath(sys.argv[1])
digest = hashlib.sha256()
for directory, names, files in os.walk(root, topdown=True, followlinks=False):
    names[:] = sorted(name for name in names if not (directory == root and name == ".git"))
    for name in sorted(files):
        path = os.path.join(directory, name)
        relative = os.path.relpath(path, root).encode()
        digest.update(relative + b"\0")
        if os.path.islink(path):
            digest.update(b"symlink\0" + os.readlink(path).encode() + b"\0")
        else:
            with open(path, "rb") as source:
                digest.update(source.read())
print(digest.hexdigest())
PY
}

historical_plan_digest() {
  python3 - "$1/docs/superpowers/plans" <<'PY'
import hashlib
import os
import sys

root = os.path.abspath(sys.argv[1])
digest = hashlib.sha256()
for directory, _, files in os.walk(root):
    for name in sorted(files):
        path = os.path.join(directory, name)
        digest.update(os.path.relpath(path, root).encode() + b"\0")
        with open(path, "rb") as source:
            digest.update(source.read())
print(digest.hexdigest())
PY
}

new_safety_fixture() {
  local label="$1"
  fixture="$(mktemp -d -t "app-bootstrap-${label}.XXXXXX")"
  rm -rf "$fixture"
  git clone --no-local "$root" "$fixture" >/dev/null
  git -C "$fixture" checkout -b "codex/safety-${label}" >/dev/null
  cp "$root/tools/bootstrap-app.swift" "$fixture/tools/bootstrap-app.swift"
  if ! git -C "$fixture" diff --quiet -- tools/bootstrap-app.swift; then
    git -C "$fixture" add -- tools/bootstrap-app.swift
    git -C "$fixture" -c user.name='Bootstrap Test' -c user.email='bootstrap-test@example.invalid' \
      commit -m 'test: install current bootstrap helper' >/dev/null
  fi
}

commit_fixture_paths() {
  local message="$1"
  shift
  git -C "$fixture" add -- "$@"
  git -C "$fixture" -c user.name='Bootstrap Test' -c user.email='bootstrap-test@example.invalid' \
    commit -m "$message" >/dev/null
}

expect_bootstrap_rejection_without_mutation() {
  local label="$1"
  shift
  local before_status before_head before_digest after_status after_head after_digest status
  before_status="$(git -C "$fixture" status --porcelain=v1)"
  before_head="$(git -C "$fixture" rev-parse HEAD)"
  before_digest="$(repository_content_digest "$fixture")"
  set +e
  (
    cd "$fixture"
    "$root/tools/bootstrap-app.sh" "$@"
  ) >"$output" 2>"$errors"
  status=$?
  set -e
  after_status="$(git -C "$fixture" status --porcelain=v1)"
  after_head="$(git -C "$fixture" rev-parse HEAD)"
  after_digest="$(repository_content_digest "$fixture")"

  [[ $status -ne 0 ]] || {
    echo "rejected safety case unexpectedly succeeded: $label" >&2
    exit 1
  }
  [[ "$before_status" == "$after_status" ]] || {
    echo "rejected safety case changed git status: $label" >&2
    exit 1
  }
  [[ "$before_head" == "$after_head" ]] || {
    echo "rejected safety case changed HEAD: $label" >&2
    exit 1
  }
  [[ "$before_digest" == "$after_digest" ]] || {
    echo "rejected safety case changed repository content: $label" >&2
    exit 1
  }
  rm -rf "$fixture"
  fixture=''
}

garden_notes_arguments=(
  --display-name 'Garden Notes'
  --module-name 'GardenNotes'
  --app-slug 'garden-notes'
  --bundle-id 'com.yuto.GardenNotes'
)

validate() {
  swift "$bootstrap" validate --manifest "$manifest" "$@" >"$output" 2>"$errors"
}

expect_valid() {
  if ! validate \
    --display-name 'Garden Notes' \
    --module-name 'GardenNotes' \
    --app-slug 'garden-notes' \
    --bundle-id 'com.yuto.GardenNotes'; then
    echo "valid case failed: $(<"$errors")" >&2
    exit 1
  fi

  local expected='{"appSlug":"garden-notes","bundleId":"com.yuto.GardenNotes","displayName":"Garden Notes","moduleName":"GardenNotes"}'
  local actual
  actual="$(<"$output")"
  [[ "$actual" == "$expected" ]] || {
    echo "valid case emitted unexpected JSON: $actual" >&2
    exit 1
  }
}

expect_valid_case() {
  local label="$1"
  shift

  if ! validate "$@"; then
    echo "valid case failed: $label: $(<"$errors")" >&2
    exit 1
  fi
}

expect_invalid() {
  local label="$1"
  shift
  local before after status
  before="$(fixture_hash)"
  set +e
  validate "$@"
  status=$?
  set -e
  after="$(fixture_hash)"

  [[ $status -ne 0 ]] || {
    echo "invalid case unexpectedly succeeded: $label" >&2
    exit 1
  }
  [[ "$before" == "$after" ]] || {
    echo "invalid case changed fixture: $label" >&2
    exit 1
  }
}

if [[ "$mode" == "safety" ]]; then
  new_safety_fixture dirty
  printf 'caller-owned\n' >"$fixture/dirty.txt"
  expect_bootstrap_rejection_without_mutation 'dirty worktree' "${garden_notes_arguments[@]}"

  new_safety_fixture default
  git -C "$fixture" branch trunk
  git -C "$fixture" update-ref refs/remotes/origin/trunk "$(git -C "$fixture" rev-parse HEAD)"
  git -C "$fixture" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  git -C "$fixture" checkout trunk >/dev/null
  expect_bootstrap_rejection_without_mutation 'default branch' "${garden_notes_arguments[@]}"

  new_safety_fixture detached
  git -C "$fixture" checkout --detach >/dev/null
  expect_bootstrap_rejection_without_mutation 'detached caller' "${garden_notes_arguments[@]}"

  new_safety_fixture destination
  mkdir "$fixture/GardenNotes"
  printf 'collision\n' >"$fixture/GardenNotes/.keep"
  commit_fixture_paths 'test: add exact destination collision' GardenNotes/.keep
  expect_bootstrap_rejection_without_mutation 'precreated GardenNotes directory' "${garden_notes_arguments[@]}"

  new_safety_fixture bundle-drift
  python3 - "$fixture/TemplateApp.xcodeproj/project.pbxproj" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
content = path.read_text()
path.write_text(content.replace("PRODUCT_BUNDLE_IDENTIFIER = com.yuto.TemplateApp;", "PRODUCT_BUNDLE_IDENTIFIER = com.yuto.Drifted;", 1))
PY
  commit_fixture_paths 'test: drift source bundle anchor' TemplateApp.xcodeproj/project.pbxproj
  expect_bootstrap_rejection_without_mutation 'changed source Bundle ID' "${garden_notes_arguments[@]}"

  new_safety_fixture scheme-drift
  python3 - "$fixture/TemplateApp.xcodeproj/xcshareddata/xcschemes/TemplateApp.xcscheme" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(path.read_text().replace("TemplateApp", "BrokenScheme"))
PY
  commit_fixture_paths 'test: remove scheme source anchors' TemplateApp.xcodeproj/xcshareddata/xcschemes/TemplateApp.xcscheme
  expect_bootstrap_rejection_without_mutation 'missing Scheme anchor' "${garden_notes_arguments[@]}"

  new_safety_fixture schema-drift
  python3 - "$fixture/Config/template-identity.json" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
manifest = json.loads(path.read_text())
manifest["schemaVersion"] = 2
path.write_text(json.dumps(manifest, indent=2) + "\n")
PY
  commit_fixture_paths 'test: drift manifest schema version' Config/template-identity.json
  expect_bootstrap_rejection_without_mutation 'manifest schemaVersion drift' "${garden_notes_arguments[@]}"

  new_safety_fixture live-path-drift
  python3 - "$fixture/Config/template-identity.json" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
manifest = json.loads(path.read_text())
manifest["liveContentPaths"].remove("README.md")
manifest["liveContentPaths"].append("docs/security.md")
path.write_text(json.dumps(manifest, indent=2) + "\n")
PY
  commit_fixture_paths 'test: drift manifest live content allowlist' Config/template-identity.json
  expect_bootstrap_rejection_without_mutation 'manifest liveContentPaths drift' "${garden_notes_arguments[@]}"

  new_safety_fixture case-collision
  mkdir "$fixture/gardennotes"
  printf 'case collision\n' >"$fixture/gardennotes/.keep"
  commit_fixture_paths 'test: add case-insensitive destination collision' gardennotes/.keep
  expect_bootstrap_rejection_without_mutation 'case-insensitive destination collision' "${garden_notes_arguments[@]}"

  new_safety_fixture symlink
  outside_file="$(mktemp -t app-bootstrap-symlink-target.XXXXXX)"
  printf 'outside\n' >"$outside_file"
  rm "$fixture/TemplateApp/ContentView.swift"
  ln -s "$outside_file" "$fixture/TemplateApp/ContentView.swift"
  commit_fixture_paths 'test: replace live source with escape symlink' TemplateApp/ContentView.swift
  expect_bootstrap_rejection_without_mutation 'symlink escape' "${garden_notes_arguments[@]}"
  rm -f "$outside_file"

  new_safety_fixture security-substitution
  python3 - "$fixture/docs/security.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
content = path.read_text()
app_store = "ios-template/template-app/app-store-connect/production/key-id"
cloudflare = "ios-template/template-app/cloudflare/production/api-token"
if content.count(app_store) != 1 or content.count(cloudflare) != 1:
    raise SystemExit("unexpected security fixture")
path.write_text(content.replace(app_store, cloudflare))
PY
  commit_fixture_paths 'test: substitute one security service anchor' docs/security.md
  expect_bootstrap_rejection_without_mutation 'security service substitution at constant total' "${garden_notes_arguments[@]}"

  new_safety_fixture security-drift
  printf 'ios-template/template-app/extra/production/key\n' >>"$fixture/docs/security.md"
  commit_fixture_paths 'test: add unexpected security source anchor' docs/security.md
  expect_bootstrap_rejection_without_mutation 'security anchor count drift' "${garden_notes_arguments[@]}"

  invalid_cases=(
    'slash|Garden/Notes|GardenNotes|garden-notes|com.yuto.GardenNotes'
    'dot-dot|Garden Notes|GardenNotes|garden..notes|com.yuto.GardenNotes'
    $'newline|Garden\nNotes|GardenNotes|garden-notes|com.yuto.GardenNotes'
    'shell-metacharacter|Garden Notes|GardenNotes|garden;touch-pwned|com.yuto.GardenNotes'
    'leading-digit-module|Garden Notes|1GardenNotes|garden-notes|com.yuto.GardenNotes'
    'swift-keyword|Garden Notes|class|garden-notes|com.yuto.GardenNotes'
    'source-name-no-op|Garden Notes|TemplateApp|garden-notes|com.yuto.GardenNotes'
    'source-slug-no-op|Garden Notes|GardenNotes|template-app|com.yuto.GardenNotes'
    'source-bundle-no-op|Garden Notes|GardenNotes|garden-notes|com.yuto.TemplateApp'
    'exact-source-identity|TemplateApp|TemplateApp|template-app|com.yuto.TemplateApp'
  )
  for row in "${invalid_cases[@]}"; do
    IFS='|' read -r label invalid_display invalid_module invalid_slug invalid_bundle <<<"$row"
    new_safety_fixture "input-${label}"
    expect_bootstrap_rejection_without_mutation "$label input" \
      --display-name "$invalid_display" \
      --module-name "$invalid_module" \
      --app-slug "$invalid_slug" \
      --bundle-id "$invalid_bundle"
  done

  new_safety_fixture independent-bundle-segment
  independent_bundle_arguments=(
    --display-name 'Garden Notes'
    --module-name 'GardenNotes'
    --app-slug 'garden-notes'
    --bundle-id 'com.example.TemplateApp'
  )
  if ! (
    cd "$fixture"
    "$root/tools/bootstrap-app.sh" "${independent_bundle_arguments[@]}"
  ) >"$output" 2>"$errors"; then
    echo "valid independent TemplateApp Bundle segment failed: $(<"$errors")" >&2
    exit 1
  fi
  if ! swift "$root/tools/bootstrap-app.swift" audit \
    --root "$fixture" \
    --manifest "$fixture/Config/template-identity.json" \
    --module-name GardenNotes >"$output" 2>"$errors"; then
    echo "audit rejected a valid independent TemplateApp Bundle segment: $(<"$errors")" >&2
    exit 1
  fi
  python3 - "$fixture/GardenNotes.xcodeproj/project.pbxproj" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
content = path.read_text()
anchor = "remoteInfo = GardenNotes;"
if content.count(anchor) < 1:
    raise SystemExit("missing transformed PBX residual fixture anchor")
path.write_text(content.replace(anchor, "remoteInfo = TemplateApp;", 1))
PY
  set +e
  swift "$root/tools/bootstrap-app.swift" audit \
    --root "$fixture" \
    --manifest "$fixture/Config/template-identity.json" \
    --module-name GardenNotes >"$output" 2>"$errors"
  status=$?
  set -e
  [[ $status -ne 0 ]] || {
    echo 'audit accepted a true TemplateApp PBX residual' >&2
    exit 1
  }
  rm -rf "$fixture"
  fixture=''

  new_safety_fixture whitespace-rerun
  whitespace_arguments=(
    --display-name '  Garden Notes  '
    --module-name 'GardenNotes'
    --app-slug 'garden-notes'
    --bundle-id 'com.yuto.GardenNotes'
  )
  if ! (
    cd "$fixture"
    "$root/tools/bootstrap-app.sh" "${whitespace_arguments[@]}"
  ) >"$output" 2>"$errors"; then
    echo "normalized display-name first run failed: $(<"$errors")" >&2
    exit 1
  fi
  python3 - "$fixture/Config/app-identity.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    identity = json.load(source)
if identity["displayName"] != "Garden Notes":
    raise SystemExit(f"display name was not normalized: {identity['displayName']!r}")
PY
  whitespace_status_before="$(git -C "$fixture" status --porcelain=v1)"
  whitespace_head_before="$(git -C "$fixture" rev-parse HEAD)"
  whitespace_digest_before="$(repository_content_digest "$fixture")"
  if ! (
    cd "$fixture"
    "$root/tools/bootstrap-app.sh" "${whitespace_arguments[@]}"
  ) >"$output" 2>"$errors"; then
    echo "normalized display-name second run failed: $(<"$errors")" >&2
    exit 1
  fi
  [[ "$(<"$output")" == '{"appSlug":"garden-notes","bundleId":"com.yuto.GardenNotes","moduleName":"GardenNotes","resultRecordPath":"Config/app-identity.json","status":"already-complete"}' ]] || {
    echo "normalized display-name second run emitted unexpected result: $(<"$output")" >&2
    exit 1
  }
  [[ "$whitespace_status_before" == "$(git -C "$fixture" status --porcelain=v1)" &&
     "$whitespace_head_before" == "$(git -C "$fixture" rev-parse HEAD)" &&
     "$whitespace_digest_before" == "$(repository_content_digest "$fixture")" ]] || {
    echo 'normalized display-name second run mutated the repository' >&2
    exit 1
  }
  rm -rf "$fixture"
  fixture=''

  new_safety_fixture source-substring
  if ! (
    cd "$fixture"
    "$root/tools/bootstrap-app.sh" \
      --display-name 'TemplateApp Notes' \
      --module-name 'TemplateApplication' \
      --app-slug 'template-app-notes' \
      --bundle-id 'com.yuto.TemplateApplication'
  ) >"$output" 2>"$errors"; then
    echo "valid identity containing the source name failed: $(<"$errors")" >&2
    exit 1
  fi
  if ! swift "$root/tools/bootstrap-app.swift" audit \
    --root "$fixture" \
    --manifest "$fixture/Config/template-identity.json" \
    --module-name TemplateApplication >"$output" 2>"$errors"; then
    echo "audit rejected a valid identity containing the source name: $(<"$errors")" >&2
    exit 1
  fi
  printf '\nTemplateApp\n' >>"$fixture/README.md"
  set +e
  swift "$root/tools/bootstrap-app.swift" audit \
    --root "$fixture" \
    --manifest "$fixture/Config/template-identity.json" \
    --module-name TemplateApplication >"$output" 2>"$errors"
  status=$?
  set -e
  [[ $status -ne 0 ]] || {
    echo 'audit accepted an independent TemplateApp residual token' >&2
    exit 1
  }
  rm -rf "$fixture"
  fixture=''

  new_safety_fixture second-run
  historical_before="$(historical_plan_digest "$fixture")"
  if ! (
    cd "$fixture"
    "$root/tools/bootstrap-app.sh" "${garden_notes_arguments[@]}"
  ) >"$output" 2>"$errors"; then
    echo "initial safety bootstrap failed: $(<"$errors")" >&2
    exit 1
  fi
  [[ "$historical_before" == "$(historical_plan_digest "$fixture")" ]] || {
    echo 'bootstrap changed one or more historical plan files' >&2
    exit 1
  }
  grep -Fqx '`TemplateApp` は最小の SwiftUI アプリ、Unit Test、UI Test だけを持ちます。サンプル機能、ダミー課金、ダミーAPI、使われないサービス層は含めません。' "$fixture/specs/architecture.md" || {
    echo 'bootstrap removed the explicit source-provenance explanation' >&2
    exit 1
  }
  grep -Fqx '新しいアプリ用リポジトリでは、`TemplateApp`をFeature実装のまま残しません。共有bootstrapは、検証済みの入力と`Config/template-identity.json`を正本として、次のアプリ固有Identityだけを変換します。' "$fixture/specs/architecture.md" || {
    echo 'bootstrap removed the explicit Identity Bootstrap explanation' >&2
    exit 1
  }
  grep -Fqx '├── GardenNotes/' "$fixture/specs/architecture.md"
  grep -Fqx 'GardenNotes/' "$fixture/specs/architecture.md"

  if ! swift "$root/tools/bootstrap-app.swift" audit \
    --root "$fixture" \
    --manifest "$fixture/Config/template-identity.json" \
    --module-name GardenNotes >"$output" 2>"$errors"; then
    echo "audit rejected a valid transformed repository: $(<"$errors")" >&2
    exit 1
  fi

  same_status_before="$(git -C "$fixture" status --porcelain=v1)"
  same_head_before="$(git -C "$fixture" rev-parse HEAD)"
  same_digest_before="$(repository_content_digest "$fixture")"
  if ! (
    cd "$fixture"
    "$root/tools/bootstrap-app.sh" "${garden_notes_arguments[@]}"
  ) >"$output" 2>"$errors"; then
    echo "same second run failed: $(<"$errors")" >&2
    exit 1
  fi
  expected_complete='{"appSlug":"garden-notes","bundleId":"com.yuto.GardenNotes","moduleName":"GardenNotes","resultRecordPath":"Config/app-identity.json","status":"already-complete"}'
  [[ "$(<"$output")" == "$expected_complete" ]] || {
    echo "same second run emitted unexpected result: $(<"$output")" >&2
    exit 1
  }
  [[ "$same_status_before" == "$(git -C "$fixture" status --porcelain=v1)" &&
     "$same_head_before" == "$(git -C "$fixture" rev-parse HEAD)" &&
     "$same_digest_before" == "$(repository_content_digest "$fixture")" ]] || {
    echo 'same second run mutated the transformed repository' >&2
    exit 1
  }

  expect_bootstrap_rejection_without_mutation 'conflicting second run' \
    --display-name 'Other Garden' \
    --module-name 'OtherGarden' \
    --app-slug 'other-garden' \
    --bundle-id 'com.yuto.OtherGarden'

  new_safety_fixture display-tamper
  if ! (
    cd "$fixture"
    "$root/tools/bootstrap-app.sh" "${garden_notes_arguments[@]}"
  ) >"$output" 2>"$errors"; then
    echo "display-name tamper setup failed: $(<"$errors")" >&2
    exit 1
  fi
  python3 - "$fixture/GardenNotes.xcodeproj/project.pbxproj" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
content = path.read_text()
expected = 'INFOPLIST_KEY_CFBundleDisplayName = "Garden Notes";'
if content.count(expected) != 2:
    raise SystemExit("unexpected display-name setting fixture")
path.write_text(content.replace(expected, 'INFOPLIST_KEY_CFBundleDisplayName = "Tampered";', 1))
PY
  expect_bootstrap_rejection_without_mutation 'tampered display-name setting on same second run' \
    "${garden_notes_arguments[@]}"

  new_safety_fixture display-delete
  if ! (
    cd "$fixture"
    "$root/tools/bootstrap-app.sh" "${garden_notes_arguments[@]}"
  ) >"$output" 2>"$errors"; then
    echo "display-name deletion setup failed: $(<"$errors")" >&2
    exit 1
  fi
  python3 - "$fixture/GardenNotes.xcodeproj/project.pbxproj" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
content = path.read_text()
expected = '\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = "Garden Notes";\n'
if content.count(expected) != 2:
    raise SystemExit("unexpected display-name setting fixture")
path.write_text(content.replace(expected, "", 1))
PY
  expect_bootstrap_rejection_without_mutation 'deleted display-name setting on same second run' \
    "${garden_notes_arguments[@]}"

  new_safety_fixture audit-residual
  if ! (
    cd "$fixture"
    "$root/tools/bootstrap-app.sh" "${garden_notes_arguments[@]}"
  ) >"$output" 2>"$errors"; then
    echo "residual audit setup failed: $(<"$errors")" >&2
    exit 1
  fi
  security_backup="$(mktemp -t app-bootstrap-security-backup.XXXXXX)"
  cp "$fixture/docs/security.md" "$security_backup"
  python3 - "$fixture/docs/security.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
content = path.read_text()
app_store = "ios-template/garden-notes/app-store-connect/production/key-id"
cloudflare = "ios-template/garden-notes/cloudflare/production/api-token"
if content.count(app_store) != 1 or content.count(cloudflare) != 1:
    raise SystemExit("unexpected transformed security fixture")
path.write_text(content.replace(app_store, cloudflare))
PY
  set +e
  swift "$root/tools/bootstrap-app.swift" audit \
    --root "$fixture" \
    --manifest "$fixture/Config/template-identity.json" \
    --module-name GardenNotes >"$output" 2>"$errors"
  status=$?
  set -e
  [[ $status -ne 0 ]] || {
    echo 'audit accepted a transformed security service substitution at constant total' >&2
    exit 1
  }
  cp "$security_backup" "$fixture/docs/security.md"
  rm -f "$security_backup"
  python3 - "$fixture/docs/security.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(path.read_text().replace("garden-notes", "template-app", 1))
PY
  set +e
  swift "$root/tools/bootstrap-app.swift" audit \
    --root "$fixture" \
    --manifest "$fixture/Config/template-identity.json" \
    --module-name GardenNotes >"$output" 2>"$errors"
  status=$?
  set -e
  [[ $status -ne 0 ]] || {
    echo 'audit accepted a live source residual' >&2
    exit 1
  }
  expect_bootstrap_rejection_without_mutation 'same second run with a live residual' \
    "${garden_notes_arguments[@]}"

  echo 'safety tests passed'
  exit 0
fi

if [[ "$mode" == "transaction" ]]; then
  source_hash_before="$(source_tree_digest)"
  fixture="$(mktemp -d -t app-bootstrap-transaction.XXXXXX)"
  rm -rf "$fixture"
  git clone --no-local "$root" "$fixture" >/dev/null
  git -C "$fixture" checkout -b codex/test-bootstrap >/dev/null
  cp "$root/tools/bootstrap-app.swift" "$fixture/tools/bootstrap-app.swift"
  if ! git -C "$fixture" diff --quiet -- tools/bootstrap-app.swift; then
    git -C "$fixture" add -- tools/bootstrap-app.swift
    git -C "$fixture" -c user.name='Bootstrap Test' -c user.email='bootstrap-test@example.invalid' \
      commit -m 'test: add transactional bootstrap helper' >/dev/null
  fi

  caller_head_before="$(git -C "$fixture" rev-parse HEAD)"
  caller_status_before="$(git -C "$fixture" status --porcelain=v1)"
  caller_tree_before="$(git -C "$fixture" ls-files -s | shasum | awk '{print $1}')"
  worktrees_before="$(git -C "$fixture" worktree list --porcelain)"

  if ! (
    cd "$fixture"
    "$root/tools/bootstrap-app.sh" \
      --display-name 'Garden Notes' \
      --module-name 'GardenNotes' \
      --app-slug 'garden-notes' \
      --bundle-id 'com.yuto.GardenNotes'
  ) >"$output" 2>"$errors"; then
    echo "transaction failed: $(<"$errors")" >&2
    exit 1
  fi

  [[ "$caller_head_before" == "$(git -C "$fixture" rev-parse HEAD)" ]] || {
    echo 'transaction changed caller HEAD' >&2
    exit 1
  }
  [[ -z "$caller_status_before" ]] || {
    echo 'transaction fixture was unexpectedly dirty before apply' >&2
    exit 1
  }
  [[ -n "$(git -C "$fixture" status --porcelain=v1)" ]] || {
    echo 'transaction left no reviewable changes' >&2
    exit 1
  }
  [[ -z "$(git -C "$fixture" diff --cached --name-only)" ]] || {
    echo 'transaction left changes staged' >&2
    exit 1
  }
  [[ -e "$fixture/GardenNotes/GardenNotesApp.swift" ]] || {
    echo 'transaction did not apply renamed app source' >&2
    exit 1
  }
  [[ -e "$fixture/Config/app-identity.json" ]] || {
    echo 'transaction did not apply app identity' >&2
    exit 1
  }
  [[ "$worktrees_before" == "$(git -C "$fixture" worktree list --porcelain)" ]] || {
    echo 'transaction left a temporary worktree registered' >&2
    exit 1
  }
  [[ "$source_hash_before" == "$(source_tree_digest)" ]] || {
    echo 'transaction changed the original test-runner repository' >&2
    exit 1
  }
  [[ "$caller_tree_before" == "$(git -C "$fixture" ls-files -s | shasum | awk '{print $1}')" ]] || {
    echo 'transaction changed the caller index' >&2
    exit 1
  }
  expected_applied='{"appSlug":"garden-notes","bundleId":"com.yuto.GardenNotes","moduleName":"GardenNotes","resultRecordPath":"Config/app-identity.json","status":"applied"}'
  [[ "$(<"$output")" == "$expected_applied" ]] || {
    echo "transaction emitted unexpected result: $(<"$output")" >&2
    exit 1
  }

  if ! (
    cd "$fixture"
    "$root/tools/bootstrap-app.sh" \
      --display-name 'Garden Notes' \
      --module-name 'GardenNotes' \
      --app-slug 'garden-notes' \
      --bundle-id 'com.yuto.GardenNotes'
  ) >"$output" 2>"$errors"; then
    echo "same-identity transaction failed: $(<"$errors")" >&2
    exit 1
  fi
  expected_complete='{"appSlug":"garden-notes","bundleId":"com.yuto.GardenNotes","moduleName":"GardenNotes","resultRecordPath":"Config/app-identity.json","status":"already-complete"}'
  [[ "$(<"$output")" == "$expected_complete" ]] || {
    echo "same-identity transaction emitted unexpected result: $(<"$output")" >&2
    exit 1
  }

  echo 'transaction tests passed'
  exit 0
fi

if [[ "$mode" == "trunk-default" ]]; then
  fixture="$(mktemp -d -t app-bootstrap-trunk.XXXXXX)"
  rm -rf "$fixture"
  git clone --no-local "$root" "$fixture" >/dev/null
  git -C "$fixture" branch trunk
  git -C "$fixture" update-ref refs/remotes/origin/trunk "$(git -C "$fixture" rev-parse HEAD)"
  git -C "$fixture" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  git -C "$fixture" checkout trunk >/dev/null

  set +e
  (
    cd "$fixture"
    "$root/tools/bootstrap-app.sh" \
      --display-name 'Garden Notes' \
      --module-name 'GardenNotes' \
      --app-slug 'garden-notes' \
      --bundle-id 'com.yuto.GardenNotes'
  ) >"$output" 2>"$errors"
  status=$?
  set -e
  [[ $status -ne 0 ]] || {
    echo 'bootstrap allowed the caller default branch trunk' >&2
    exit 1
  }
  grep -Fq 'default branch' "$errors" || {
    echo "trunk rejection did not identify the default branch: $(<"$errors")" >&2
    exit 1
  }

  echo 'trunk default tests passed'
  exit 0
fi

if [[ "$mode" == "cleanup-failure" ]]; then
  fixture="$(mktemp -d -t app-bootstrap-cleanup.XXXXXX)"
  rm -rf "$fixture"
  git clone --no-local "$root" "$fixture" >/dev/null
  git -C "$fixture" checkout -b codex/test-bootstrap >/dev/null

  set +e
  (
    export BOOTSTRAP_TEST_REAL_GIT="$(command -v git)"
    export PATH="$root/tools/tests/fixtures/fail-worktree-remove:$PATH"
    cd "$fixture"
    "$root/tools/bootstrap-app.sh" \
      --display-name 'Garden Notes' \
      --module-name 'GardenNotes' \
      --app-slug 'garden-notes' \
      --bundle-id 'com.yuto.GardenNotes'
  ) >"$output" 2>"$errors"
  status=$?
  set -e
  [[ $status -ne 0 ]] || {
    echo 'bootstrap unexpectedly succeeded after worktree removal failed' >&2
    exit 1
  }
  retained_path="$(sed -n 's/^bootstrap-app: cleanup failed; staging worktree retained: //p' "$errors")"
  [[ ( "$retained_path" == /tmp/ios-template-bootstrap.*/worktree || "$retained_path" == /private/tmp/ios-template-bootstrap.*/worktree ) && -d "$retained_path" ]] || {
    echo "cleanup did not retain the exact staging worktree: $(<"$errors")" >&2
    exit 1
  }
  git -C "$fixture" worktree list --porcelain | grep -Fqx "worktree $retained_path" || {
    echo "cleanup removed the retained worktree registration: $(<"$errors")" >&2
    exit 1
  }
  git -C "$fixture" worktree remove --force "$retained_path"
  rm -rf -- "${retained_path%/worktree}"

  echo 'cleanup failure tests passed'
  exit 0
fi

if [[ "$mode" == "transform" ]]; then
  source_hash_before="$(fixture_hash)"
  fixture="$(mktemp -d -t app-bootstrap-transform.XXXXXX)"
  rm -rf "$fixture"
  git clone --no-local "$root" "$fixture" >/dev/null
  git -C "$fixture" checkout -b codex/test-bootstrap >/dev/null
  cp "$root/README.md" "$fixture/README.md"
  cp "$root/Config/ownership.yml" "$fixture/Config/ownership.yml"
  cp "$root/tools/tests/test-foundation.sh" "$fixture/tools/tests/test-foundation.sh"
  cp "$root/.agents/skills/app-bootstrap/SKILL.md" "$fixture/.agents/skills/app-bootstrap/SKILL.md"
  historical_plan="$fixture/docs/superpowers/plans/2026-08-22-app-bootstrap.md"
  historical_plan_hash_before="$(shasum "$historical_plan" | awk '{print $1}')"
  pbx_uuid_hash_before="$(rg -o '[A-F0-9]{24}' "$fixture/TemplateApp.xcodeproj/project.pbxproj" | LC_ALL=C sort -u | shasum | awk '{print $1}')"

  if ! swift "$bootstrap" apply \
    --root "$fixture" \
    --manifest "$fixture/$manifest" \
    --display-name 'Garden Notes' \
    --module-name 'GardenNotes' \
    --app-slug 'garden-notes' \
    --bundle-id 'com.yuto.GardenNotes' >"$output" 2>"$errors"; then
    echo "transform failed: $(<"$errors")" >&2
    exit 1
  fi

  for expected_path in \
    GardenNotes.xcodeproj \
    GardenNotes.xcodeproj/xcshareddata/xcschemes/GardenNotes.xcscheme \
    GardenNotes/GardenNotesApp.swift \
    GardenNotesTests/GardenNotesTests.swift \
    GardenNotesUITests/GardenNotesUITests.swift; do
    [[ -e "$fixture/$expected_path" ]] || {
      echo "missing transformed path: $expected_path" >&2
      exit 1
    }
  done

  pbxproj="$fixture/GardenNotes.xcodeproj/project.pbxproj"
  grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = com.yuto.GardenNotes;' "$pbxproj"
  grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = com.yuto.GardenNotesTests;' "$pbxproj"
  grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = com.yuto.GardenNotesUITests;' "$pbxproj"
  grep -Fq 'DEVELOPMENT_TEAM = AUZ2MV247A;' "$pbxproj"
  python3 - "$pbxproj" <<'PY'
import sys

with open(sys.argv[1]) as source:
    content = source.read()

display_name_setting = 'INFOPLIST_KEY_CFBundleDisplayName = "Garden Notes";'
if content.count(display_name_setting) != 2:
    raise SystemExit(f"expected exactly two App display-name settings, found {content.count(display_name_setting)}")
PY
  [[ "$pbx_uuid_hash_before" == "$(rg -o '[A-F0-9]{24}' "$pbxproj" | LC_ALL=C sort -u | shasum | awk '{print $1}')" ]] || {
    echo 'PBX UUIDs changed during transform' >&2
    exit 1
  }
  grep -Fqx '@testable import GardenNotes' "$fixture/GardenNotesTests/GardenNotesTests.swift"
  grep -Fqx 'struct GardenNotesApp: App {' "$fixture/GardenNotes/GardenNotesApp.swift"
  grep -Fqx '            Text("garden-notes.welcome")' "$fixture/GardenNotes/ContentView.swift"
  grep -Fqx '                .accessibilityIdentifier("garden-notes.welcome-title")' "$fixture/GardenNotes/ContentView.swift"
  grep -Fqx 'ios-template/garden-notes/elevenlabs/production/api-key' "$fixture/docs/security.md"
  grep -Fqx '~/Library/Application Support/iOS-Template/secrets/${appSlug}/' "$fixture/docs/security.md"
  grep -Fqx '  "file": "GardenNotes/Settings/NotificationSettings.swift",' "$fixture/docs/agent-contracts/review-packet.md"
  grep -Fqx '# Garden Notes agent contract' "$fixture/AGENTS.md" || {
    echo 'AGENTS heading was not transformed with the display name' >&2
    exit 1
  }

  python3 - "$fixture/Config/app-identity.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    actual = json.load(source)

expected = {
    "appSlug": "garden-notes",
    "bundleId": "com.yuto.GardenNotes",
    "displayName": "Garden Notes",
    "moduleName": "GardenNotes",
    "schemaVersion": 1,
    "sourceIdentityVersion": 1,
}
if actual != expected:
    raise SystemExit(f"unexpected app identity: {actual!r}")
PY

  python3 - "$fixture/Config/ownership.yml" <<'PY'
import sys

with open(sys.argv[1]) as source:
    actual = source.read()

expected = """schemaVersion: 2

github:
  login: yuto1201

supabase:
  organizationId: kmjpkzaqlewqnypyqwkg
  organizationName: "yuto1201's Org"
  projectRef: null

cloudflare:
  accountId: 7ea8e713d76506f9e303f58624829aa5
  accountName: Yuto Dev
  plan: free
  target: null

linear:
  workspaceSlug: yuto33004
  workspaceUrl: https://linear.app/yuto33004
  teamKey: YUT

vercel:
  teamId: team_ANEUn6gVL8dccPaY08wkvxFt
  teamSlug: yuto16
  plan: hobby
  projectId: null

elevenlabs:
  accountId: null
  workspaceId: null

appStore:
  teamId: null
  bundleId: com.yuto.GardenNotes
"""
if actual != expected:
    raise SystemExit(f"unexpected ownership content: {actual!r}")
PY
  if ! (
    cd "$fixture"
    bash tools/tests/test-foundation.sh
  ) >"$output" 2>"$errors"; then
    echo "Foundation failed after disposable bootstrap: $(<"$errors")" >&2
    exit 1
  fi
  if ! (
    cd "$fixture"
    bash tools/tests/test-delivery-stages.sh
  ) >"$output" 2>"$errors"; then
    echo "Delivery-stage contracts failed after disposable bootstrap: $(<"$errors")" >&2
    exit 1
  fi
  [[ "$historical_plan_hash_before" == "$(shasum "$historical_plan" | awk '{print $1}')" ]] || {
    echo 'historical plan changed during transform' >&2
    exit 1
  }

  if ! bounded_run generated-sample-xcode-list "${IOS_TEMPLATE_BOOTSTRAP_XCODE_TIMEOUT_SECONDS:-300}" \
    /usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild -list -json -project "$fixture/GardenNotes.xcodeproj" >"$output" 2>"$errors"; then
    echo "xcodebuild -list failed: $(<"$errors")" >&2
    exit 1
  fi
  python3 - "$output" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    listing = json.load(source)

project = listing["project"]
if project["name"] != "GardenNotes":
    raise SystemExit(f"unexpected project: {project['name']!r}")
if project["schemes"] != ["GardenNotes"]:
    raise SystemExit(f"unexpected schemes: {project['schemes']!r}")
if project["targets"] != ["GardenNotes", "GardenNotesTests", "GardenNotesUITests"]:
    raise SystemExit(f"unexpected targets: {project['targets']!r}")
PY

  escaped_fixture="$(mktemp -d -t app-bootstrap-escaped.XXXXXX)"
  rm -rf "$escaped_fixture"
  git clone --no-local "$root" "$escaped_fixture" >/dev/null
  git -C "$escaped_fixture" checkout -b codex/test-bootstrap-escaped >/dev/null
  escaped_display_name='Garden "Notes" \ Draft'
  if ! swift "$bootstrap" apply \
    --root "$escaped_fixture" \
    --manifest "$escaped_fixture/$manifest" \
    --display-name "$escaped_display_name" \
    --module-name 'QuotedGardenNotes' \
    --app-slug 'quoted-garden-notes' \
    --bundle-id 'com.yuto.QuotedGardenNotes' >"$output" 2>"$errors"; then
    echo "quoted display-name transform failed: $(<"$errors")" >&2
    exit 1
  fi
  python3 - "$escaped_fixture/QuotedGardenNotes.xcodeproj/project.pbxproj" <<'PY'
import sys

with open(sys.argv[1]) as source:
    content = source.read()

display_name_setting = r'INFOPLIST_KEY_CFBundleDisplayName = "Garden \"Notes\" \\ Draft";'
if content.count(display_name_setting) != 2:
    raise SystemExit(f"expected exactly two escaped display-name settings, found {content.count(display_name_setting)}")
PY
  if ! bounded_run generated-sample-quoted-xcode-list "${IOS_TEMPLATE_BOOTSTRAP_XCODE_TIMEOUT_SECONDS:-300}" \
    /usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild -list -json -project "$escaped_fixture/QuotedGardenNotes.xcodeproj" >"$output" 2>"$errors"; then
    echo "quoted display-name xcodebuild -list failed: $(<"$errors")" >&2
    exit 1
  fi
  [[ "$source_hash_before" == "$(fixture_hash)" ]] || {
    echo 'apply changed content outside its staging root' >&2
    exit 1
  }

  echo 'transform tests passed'
  exit 0
fi

expect_valid

display_30='123456789012345678901234567890'
display_31='1234567890123456789012345678901'
module_50="$(printf 'M%.0s' {1..50})"
module_51="${module_50}M"
slug_50="$(printf 'a%.0s' {1..50})"
slug_51="${slug_50}a"

expect_valid_case 'display name at 30 characters' \
  --display-name "$display_30" --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_valid_case 'display name with quotes and backslash' \
  --display-name 'Garden "Notes" \ Draft' --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'display name at 31 characters' \
  --display-name "$display_31" --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_valid_case 'module name at 50 characters' \
  --display-name 'Garden Notes' --module-name "$module_50" --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'module name at 51 characters' \
  --display-name 'Garden Notes' --module-name "$module_51" --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_valid_case 'app slug at 50 characters' \
  --display-name 'Garden Notes' --module-name 'GardenNotes' --app-slug "$slug_50" --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'app slug at 51 characters' \
  --display-name 'Garden Notes' --module-name 'GardenNotes' --app-slug "$slug_51" --bundle-id 'com.yuto.GardenNotes'
expect_valid_case 'bundle segment beginning with a digit' \
  --display-name 'Garden Notes' --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.3yuto.GardenNotes'
expect_valid_case 'target values may contain the source prefix without being no-ops' \
  --display-name 'TemplateApp Notes' --module-name 'TemplateApplication' --app-slug 'template-app-notes' --bundle-id 'com.yuto.TemplateApplication'

expect_invalid 'empty display name' \
  --display-name '' --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'display name equal to source identity' \
  --display-name 'TemplateApp' --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'display name containing slash' \
  --display-name 'Garden/Notes' --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'module beginning with a digit' \
  --display-name 'Garden Notes' --module-name '1GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'module name with one character' \
  --display-name 'Garden Notes' --module-name 'A' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'module name beginning with an underscore' \
  --display-name 'Garden Notes' --module-name '_Garden' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'module name containing an underscore' \
  --display-name 'Garden Notes' --module-name 'Garden_Notes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'module containing whitespace' \
  --display-name 'Garden Notes' --module-name 'Garden Notes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'module equal to TemplateApp' \
  --display-name 'Garden Notes' --module-name 'TemplateApp' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'Swift keyword as module' \
  --display-name 'Garden Notes' --module-name 'class' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'uppercase app slug' \
  --display-name 'Garden Notes' --module-name 'GardenNotes' --app-slug 'Garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'slug with adjacent hyphens' \
  --display-name 'Garden Notes' --module-name 'GardenNotes' --app-slug 'garden--notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'app slug equal to source identity' \
  --display-name 'Garden Notes' --module-name 'GardenNotes' --app-slug 'template-app' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'bundle ID without a dot' \
  --display-name 'Garden Notes' --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'comyutoGardenNotes'
expect_invalid 'bundle segment beginning with a hyphen' \
  --display-name 'Garden Notes' --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.-GardenNotes'
expect_invalid 'Bundle ID equal to source identity' \
  --display-name 'Garden Notes' --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.TemplateApp'

echo 'validation tests passed'
