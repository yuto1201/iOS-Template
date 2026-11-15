#!/bin/bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby git swift swiftc

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
test_workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-appstore-package.XXXXXX")
trap 'rm -rf -- "$test_workspace"' EXIT
validator="$repo_root/tools/validate-appstore-package.sh"
requirements="$repo_root/tools/tests/fixtures/appstore/requirements.json"
fixture_project="$test_workspace/project"
package_root="$fixture_project/App Store"

write_valid_fixture() {
  rm -rf -- "$fixture_project"
  mkdir -p "$package_root/metadata/localizations" "$package_root/privacy" "$package_root/legal" \
    "$package_root/review" "$package_root/release-notes" "$package_root/submission" \
    "$package_root/screenshots/en-US/iphone-6.3" "$package_root/screenshots/en-US/ipad-13" \
    "$package_root/screenshots/ja/iphone-6.3" "$package_root/screenshots/ja/ipad-13"
  cat > "$package_root/metadata/app.yml" <<'EOF'
schemaVersion: 1
bundleId: "com.yuto.TemplateApp"
version: "1.0"
primaryLocale: "en-US"
platforms:
  iphone: true
  ipad: true
category: "Utilities"
copyright: "2026 Yuto"
supportURL: "https://example.com/support"
privacyPolicyURL: "https://example.com/privacy"
reviewContactReference: "keychain://app-store-connect/review-contact"
accountsSupported: false
EOF
  cat > "$package_root/metadata/localizations/en-US.yml" <<'EOF'
name: "Template App"
subtitle: "A focused utility"
description: "A truthful description of this fixture app."
keywords: "utility,focus"
promotionalText: "A concise fixture message."
EOF
  cat > "$package_root/metadata/localizations/ja.yml" <<'EOF'
name: "テンプレートアプリ"
subtitle: "集中できるユーティリティ"
description: "このフィクスチャアプリの実態に沿った説明です。"
keywords: "ユーティリティ,集中"
promotionalText: "簡潔なフィクスチャメッセージです。"
EOF
  cat > "$package_root/privacy/data-use.yml" <<'EOF'
schemaVersion: 1
collectsData: false
tracking: false
dataTypes: []
thirdPartySDKs: []
permissions: []
accountDeletion:
  required: false
  reason: "The app has no accounts."
EOF
  cat > "$package_root/legal/privacy-policy.md" <<'EOF'
# Privacy Policy

Status: Draft

Derived from `privacy/data-use.yml`; confirm before first publication.
EOF
  cat > "$package_root/legal/terms-of-use.md" <<'EOF'
# Terms of Use

Status: Draft

Confirm before first publication.
EOF
  cat > "$package_root/review/review-notes.md" <<'EOF'
# Review Notes

No account is required. Credential reference: none.
EOF
  printf '%s\n' '# Release Notes' '' 'Initial fixture release.' > "$package_root/release-notes/en-US.md"
  printf '%s\n' '# リリースノート' '' '初回フィクスチャリリース。' > "$package_root/release-notes/ja.md"
  cat > "$package_root/submission/checklist.yml" <<'EOF'
schemaVersion: 1
metadataValidated: true
privacyAudited: true
legalConfirmedForFirstPublication: false
screenshotsAudited: true
releaseAuditorApproved: false
EOF
  /bin/cp "$requirements" "$package_root/submission/requirements.json"
  for locale in en-US ja; do
    for family in iphone-6.3 ipad-13; do
      printf 'fixture image bytes' > "$package_root/screenshots/$locale/$family/01-primary.png"
    done
  done
}

assert_invalid() {
  local label=$1 expected_path=$2 forbidden_value=${3:-}
  set +e
  output=$("$validator" --root "$package_root" --project-root "$fixture_project" \
    --bundle-id com.yuto.TemplateApp --version 1.0 --requirements "$requirements" 2>"$test_workspace/stderr")
  status=$?
  set -e
  [[ "$status" -ne 0 && "$output" == *"$expected_path"* ]] || {
    echo "expected precise package failure: $label: $output" >&2
    exit 1
  }
  if [[ -n "$forbidden_value" && "$output" == *"$forbidden_value"* ]]; then
    echo "package failure leaked input value: $label" >&2
    exit 1
  fi
}

# D-079: the submission requirements and this fixture name the iPhone family Dynamic Island (medium display),
# with Apple's models and sizes, and keep the iPad 13-inch family.
# #433: the app owns App Store/submission/requirements.json and may have none yet, so the live file is checked
# only in the template, which does not record Config/template-base.json.
live_requirements=()
[[ -f "$repo_root/Config/template-base.json" ]] || live_requirements=("$repo_root/App Store/submission/requirements.json")
ruby -rjson -e '
  expected = [
    {"id" => "iphone-6.3", "platform" => "iphone",
     "deviceTypes" => ["iPhone 18 Pro", "iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro", "iPhone 16", "iPhone 15 Pro", "iPhone 15", "iPhone 14 Pro"],
     "portraitSizes" => [[1179, 2556], [1206, 2622]], "landscapeSizes" => [[2556, 1179], [2622, 1206]]},
    {"id" => "ipad-13", "platform" => "ipad", "deviceTypes" => ["iPad Air (M4)", "iPad Pro (M5)", "iPad Pro (M4)"],
     "portraitSizes" => [[2064, 2752], [2048, 2732]], "landscapeSizes" => [[2752, 2064], [2732, 2048]]}
  ]
  ARGV.each do |path|
    families = JSON.parse(File.binread(path)).dig("screenshots", "requiredFamilies")
    abort "screenshot families differ from D-079: #{path}" unless families == expected
  end
' "$requirements" ${live_requirements[@]+"${live_requirements[@]}"}

write_valid_fixture
ready=$("$validator" --root "$package_root" --project-root "$fixture_project" \
  --bundle-id com.yuto.TemplateApp --version 1.0 --requirements "$requirements")
[[ "$ready" == *'"status":"ready"'* && "$ready" == *'"errors":[]'* ]] || { echo "valid package failed: $ready" >&2; exit 1; }

write_valid_fixture
/usr/bin/sed -i '' '/^subtitle:/d' "$package_root/metadata/localizations/ja.yml"
assert_invalid 'missing Japanese subtitle' 'metadata/localizations/ja.yml.subtitle'

write_valid_fixture
ruby -e 'path=ARGV.fetch(0); text=File.binread(path); File.binwrite(path,text.sub(/description: .*/, "description: \\\"#{"x"*4001}\\\""))' "$package_root/metadata/localizations/en-US.yml"
assert_invalid 'over-limit description' 'metadata/localizations/en-US.yml.description'

write_valid_fixture
/usr/bin/sed -i '' 's#supportURL: "https://example.com/support"#supportURL: ""#' "$package_root/metadata/app.yml"
assert_invalid 'missing support URL' 'metadata/app.yml.supportURL'

write_valid_fixture
printf '%s\n' 'FirebaseAnalytics' > "$fixture_project/linked-sdk.txt"
assert_invalid 'privacy and linked SDK mismatch' 'privacy/data-use.yml.collectsData'

write_valid_fixture
rm -rf -- "$package_root/screenshots/ja/ipad-13"
assert_invalid 'missing screenshot family' 'screenshots/ja/ipad-13'

# D-079: images left in the former iPhone 6.9-inch family folder do not satisfy iphone-6.3.
write_valid_fixture
for locale in en-US ja; do
  /bin/mv "$package_root/screenshots/$locale/iphone-6.3" "$package_root/screenshots/$locale/iphone-6.9"
done
assert_invalid 'former iPhone 6.9-inch family' 'screenshots/en-US/iphone-6.3'

write_valid_fixture
secret_fixture='actual-secret-value-42'
printf '%s\n' "Password: $secret_fixture" >> "$package_root/review/review-notes.md"
assert_invalid 'secret-like review credential' 'review/review-notes.md.credentials' "$secret_fixture"


# #486 (D-101), D-106: a composed screenshot set. The App Store creative workspace delivers the adopted
# faces, tools/intake-appstore-delivery.sh binds them to the raw capture manifest and the user's recorded
# choice, tools/build-appstore-screenshot-set.sh --composition assembles them, and the package with the
# composition record passes the package check and the seal. Every image and record is made here from small
# generated PNGs and a throwaway Git repository; nothing is committed and nothing reaches the network.
builder="$repo_root/tools/build-appstore-screenshot-set.sh"
intake_tool="$repo_root/tools/intake-appstore-delivery.sh"
seal="$repo_root/.agents/skills/prepare-appstore-assets/scripts/seal-package.sh"
record_section="$repo_root/.agents/skills/submit-appstore-release/scripts/record-section.sh"
composed_bundle=com.example.TemplateApp
composed_build=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
composed_runtime=com.apple.CoreSimulator.SimRuntime.iOS-27-0
composed_now=2026-10-20T00:00:00Z
seal_project="$test_workspace/seal-project"
mkdir -p "$seal_project"
proof=$("$repo_root/tools/tests/test-ios-evidence.sh" --export-fixture "$seal_project" full | tail -n 1)
composed_sha=$(ruby -rjson -e 'puts JSON.parse(ARGV[0]).fetch("head")' "$proof")
verification_base=$(ruby -rjson -e 'puts JSON.parse(ARGV[0]).fetch("base")' "$proof")
composed="$test_workspace/composed"
fixture="$test_workspace/composed-fixture.rb"
cat >"$fixture" <<'RUBY'
require "json"
require "digest"
require "fileutils"
require "open3"
require "zlib"

SIZES = {"iphone-6.3" => [1206, 2622], "ipad-13" => [2064, 2752]}.freeze
DEVICES = {"iphone-6.3" => "iPhone 17 Pro", "ipad-13" => "iPad Pro (M5)"}.freeze
SETS = [["en-US", "iphone-6.3"], ["en-US", "ipad-13"], ["ja", "iphone-6.3"], ["ja", "ipad-13"]].freeze
STATES = %w[primary settings].freeze

def sha(path)
  "sha256:#{Digest::SHA256.file(path).hexdigest}"
end

def read(path)
  JSON.parse(File.binread(path))
end

def write(path, value)
  FileUtils.mkdir_p(File.dirname(path))
  File.binwrite(path, JSON.pretty_generate(value) + "\n")
end

# A one-color PNG: color type 2 is RGB without alpha, 6 is RGBA (opaque, but with an alpha channel).
def png(path, width, height, seed, color_type = 2)
  channels = color_type == 6 ? 4 : 3
  pixel = [seed % 251, (seed * 3) % 251, (seed * 7) % 251, 255].take(channels).pack("C*")
  raw = ("\x00".b + pixel * width) * height
  chunk = ->(type, data) { [data.bytesize].pack("N") + type.b + data + [Zlib.crc32(type.b + data)].pack("N") }
  bytes = "\x89PNG\r\n\x1a\n".b + chunk.("IHDR", [width, height, 8, color_type, 0, 0, 0].pack("NNC5")) +
          chunk.("IDAT", Zlib::Deflate.deflate(raw, 1)) + chunk.("IEND", "".b)
  FileUtils.mkdir_p(File.dirname(path))
  File.binwrite(path, bytes)
end

def git(repo, *arguments)
  output, status = Open3.capture2e("git", "-C", repo, *arguments)
  abort "git #{arguments.join(' ')} failed: #{output}" unless status.success?
  output.strip
end

# The app's raw captures and the workspace's renders, materials and committed choice, then the delivery.
def base(root, source_sha, build_digest, runtime, requirements, bundle_id)
  raw_root = File.join(root, "raw")
  cases = []
  SETS.each_with_index do |(locale, family), set|
    STATES.each_with_index do |state, index|
      relative = "#{locale}/#{family}/#{format('%02d', index + 1)}-#{state}.png"
      png(File.join(raw_root, relative), *SIZES.fetch(family), 10 + set * 2 + index)
      cases << {"locale" => locale, "family" => family, "state" => state, "order" => index + 1, "path" => relative,
                "sourceSha" => source_sha, "buildDigest" => build_digest, "runtime" => runtime, "deviceType" => DEVICES.fetch(family),
                "width" => SIZES.fetch(family)[0], "height" => SIZES.fetch(family)[1], "digest" => sha(File.join(raw_root, relative))}
    end
  end
  write(File.join(raw_root, "manifest.json"), {"schemaVersion" => 1, "sourceSha" => source_sha, "buildDigest" => build_digest,
    "runtime" => runtime, "requirementsDigest" => sha(requirements), "cases" => cases})
  png(File.join(root, "assets", "leaf.png"), 64, 64, 200)
  png(File.join(root, "assets", "stray.png"), 64, 64, 201)
  leaf = File.join(root, "assets", "leaf.png")
  stray = File.join(root, "assets", "stray.png")
  write(File.join(root, "assets", "provenance.json"), {"schemaVersion" => 1, "images" => [
    {"file" => "leaf.png", "sha256" => sha(leaf), "materialReview" => {"decision" => "adopted"}},
    {"file" => "stray.png", "sha256" => sha(stray), "materialReview" => {"decision" => "rejected"}}]})
  write(File.join(root, "assets", "brand.json"), {"schemaVersion" => 1, "name" => "Template"})
  renders = SETS.each_with_index.map do |(locale, family), set|
    folder = File.join(root, "renders", "#{locale}-#{family}")
    spec = File.join(folder, "tiles.json")
    write(spec, {"schemaVersion" => 1, "device" => family, "locale" => locale, "style" => "editorial", "decorationLimit" => 2,
                 "tiles" => STATES.map { |state| {"id" => state} }})
    shown = STATES.map do |state|
      relative = cases.find { |entry| entry.values_at("locale", "family", "state") == [locale, family, state] }.fetch("path")
      {"path" => File.join(raw_root, relative), "sha256" => sha(File.join(raw_root, relative))}
    end
    files = STATES.each_with_index.map do |state, index|
      tile = File.join(folder, "tile-#{index + 1}.png")
      png(tile, *SIZES.fetch(family), 120 + set * 2 + index)
      {"path" => tile, "sha256" => sha(tile), "width" => SIZES.fetch(family)[0], "height" => SIZES.fetch(family)[1]}
    end
    tiles = STATES.each_with_index.map do |state, index|
      {"tile" => index + 1, "id" => state, "html" => File.join(folder, "tile-#{index + 1}.html"), "htmlSha256" => "sha256:#{'0' * 64}",
       "metrics" => {}, "marks" => [], "capture" => shown[index]}
    end
    record = File.join(folder, "creative-render-#{family}-#{locale}.json")
    write(record, {"schemaVersion" => 1, "renderer" => "appstore-creative-compose", "device" => family, "locale" => locale,
      "spec" => spec, "specSha256" => sha(spec), "style" => "editorial", "decorationLimit" => 2, "inputInventory" => "complete-v1",
      "fonts" => [], "captures" => shown, "backgrounds" => [], "decorations" => [],
      "layers" => [{"scene" => STATES.first, "src" => leaf, "sha256" => sha(leaf), "z" => "front", "tiles" => [1]}],
      "popouts" => [], "tiles" => tiles, "marks" => [], "files" => files})
    [locale, family, spec, record, files]
  end
  # The user chose pattern B on the workspace's sheet; the choice is committed in the workspace.
  workspace = File.join(root, "workspace")
  FileUtils.mkdir_p(File.join(workspace, "projects", "app", "case-1"))
  File.binwrite(File.join(root, "sheet.html"), "<!doctype html><title>proposal</title>\n")
  selection = File.join(workspace, "projects", "app", "case-1", "selection.json")
  write(selection, {"schemaVersion" => 1, "revision" => "r1", "sheetSha256" => sha(File.join(root, "sheet.html")),
    "selection" => {"type" => "pattern", "patternId" => "B"}, "decision" => "user-explicit", "recordedAt" => "2026-10-15T00:00:00Z"})
  git(workspace, "init", "-q")
  git(workspace, "add", "projects")
  git(workspace, "-c", "user.name=test", "-c", "user.email=test@example.invalid", "commit", "-q", "-m", "choice")
  commit = git(workspace, "rev-parse", "HEAD")

  delivery = File.join(root, "delivery")
  listed = []
  put = lambda do |source, relative, role|
    target = File.join(delivery, "files", relative)
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(source, target)
    listed << {"path" => relative, "sha256" => sha(target), "bytes" => File.size(target), "role" => role}
  end
  faces = []
  renders.each do |locale, family, spec, record, files|
    put.(spec, "screenshots/declarations/#{sha(spec).sub(':', '-')}.json", "declaration")
    put.(record, "screenshots/records/#{sha(record).sub(':', '-')}.json", "render-record")
    files.each_with_index do |file, index|
      state = STATES[index]
      relative = format("screenshots/faces/%s/%s/%02d-%s.png", locale, family, index + 1, state)
      put.(file["path"], relative, "face")
      raw_case = cases.find { |entry| entry.values_at("locale", "family", "state") == [locale, family, state] }
      faces << {"locale" => locale, "family" => family, "order" => index + 1, "state" => state, "rawDigest" => raw_case["digest"],
                "sha256" => file["sha256"], "renderRecord" => sha(record), "declaration" => sha(spec), "path" => relative}
    end
  end
  put.(File.join(root, "assets", "provenance.json"), "screenshots/provenance.json", "provenance")
  put.(File.join(root, "assets", "brand.json"), "screenshots/brand.json", "brand")
  write(File.join(delivery, "delivery.json"), {
    "schemaVersion" => 1,
    "workspace" => {"repository" => "example/Tool-AppStore-Creative", "commit" => commit, "caseId" => "case-1"},
    "app" => {"bundleId" => bundle_id},
    "kinds" => %w[screenshots],
    "inputs" => {"captureBatch" => "486-store-r1", "rawManifestSha256" => sha(File.join(raw_root, "manifest.json")),
                 "sourceSha" => source_sha, "buildDigest" => build_digest, "runtime" => runtime,
                 "requirementsSha256" => sha(requirements), "brandSha256" => sha(File.join(root, "assets", "brand.json")), "appCommit" => source_sha},
    "renderer" => {"path" => "workspace/tools/renderer.rb", "sha256" => "sha256:#{'c' * 64}"},
    "adoption" => {"decision" => "user-explicit", "at" => "2026-10-15T00:00:00Z", "where" => "chat",
                   "approvalReference" => "https://github.com/yuto1201/iOS-Example/issues/7#issuecomment-123", "choice" => "B",
                   "sheetKind" => "proposal", "sheetSha256" => sha(File.join(root, "sheet.html")),
                   "record" => {"path" => "projects/app/case-1/selection.json", "sha256" => sha(selection)}},
    "faces" => faces,
    "files" => listed.sort_by { |file| file["path"] },
    "checks" => []
  })
  FileUtils.mkdir_p(File.join(root, "project", "App Store", "submission"))
  FileUtils.cp(requirements, File.join(root, "project", "App Store", "submission", "requirements.json"))
end

# The visual review of a composed set covers both the raw capture (truthfulness) and the composed face.
def review(root, source_sha, build_digest)
  composition = read(File.join(root, "composed", "composition.json"))
  write(File.join(root, "review.json"), {"schemaVersion" => 1, "sourceSha" => source_sha, "buildDigest" => build_digest,
    "visualReviewStatus" => "passed", "releaseAuditor" => {"status" => "approved", "model" => "release-auditor"},
    "cases" => composition.fetch("cases").map do |entry|
      entry.slice("locale", "family", "state", "path", "digest", "rawDigest").merge(
        "safeArea" => "passed", "textClipping" => "passed", "truthfulRepresentation" => "passed", "localeParity" => "passed")
    end})
end

# A record copy under composed/records is named by its SHA-256; a changed record is renamed and every
# composition reference to it follows, so only the change under test is inconsistent.
def rebind_record(root, old_digest)
  composed = File.join(root, "composed")
  old_path = File.join(composed, "records", "#{old_digest.sub(':', '-')}.json")
  yield(value = read(old_path))
  File.delete(old_path)
  File.binwrite(new_path = File.join(composed, "records", "tmp.json"), JSON.pretty_generate(value) + "\n")
  new_digest = sha(new_path)
  File.rename(new_path, File.join(composed, "records", "#{new_digest.sub(':', '-')}.json"))
  new_digest
end

def mutate(root, scenario, value = nil)
  composition_path = File.join(root, "composed", "composition.json")
  composition = read(composition_path)
  target = composition.fetch("cases").find { |entry| entry["path"] == (value || "en-US/iphone-6.3/01-primary.png") }
  review_path = File.join(root, "review.json")
  review = read(review_path)
  check = review.fetch("cases").find { |entry| entry["path"] == target["path"] }
  case scenario
  when "raw-digest" then target["rawDigest"] = "sha256:#{'1' * 64}"
  when "declaration" then target["declarationDigest"] = "sha256:#{'2' * 64}"
  # A missing or malformed render record reference cannot skip the checks it carries.
  when "record-null"
    target["renderRecordDigest"] = nil
    target["declarationDigest"] = "sha256:#{'2' * 64}"
  when "record-malformed"
    target["renderRecordDigest"] = "sha256:xyz"
    target["declarationDigest"] = "sha256:#{'2' * 64}"
  # The English iPhone faces in the other order, kept consistent with their render record, against the
  # Japanese order; or one English face left out.
  when "reorder"
    first, second = composition.fetch("cases").select { |entry| entry.values_at("locale", "family") == ["en-US", "iphone-6.3"] }.sort_by { |entry| entry["order"] }
    swap = {1 => 2, 2 => 1}
    old = first["renderRecordDigest"]
    fresh = rebind_record(root, old) do |record|
      record["files"].reverse!
      record["tiles"].reverse!
      record["layers"].each { |layer| layer["tiles"] = layer["tiles"].map { |number| swap.fetch(number, number) } }
    end
    composition.fetch("cases").each { |entry| entry["renderRecordDigest"] = fresh if entry["renderRecordDigest"] == old }
    [first, second].each do |entry|
      old_path = entry["path"]
      entry["order"] = swap.fetch(entry["order"])
      entry["path"] = format("%s/%s/%02d-%s.png", entry["locale"], entry["family"], entry["order"], entry["state"])
      File.rename(File.join(root, "composed", old_path), File.join(root, "composed", entry["path"]))
      review.fetch("cases").find { |row| row["path"] == old_path }["path"] = entry["path"]
    end
  when "drop"
    dropped = composition.fetch("cases").find { |entry| entry.values_at("locale", "family", "order") == ["en-US", "iphone-6.3", 2] }
    composition.fetch("cases").delete(dropped)
    review.fetch("cases").reject! { |row| row["path"] == dropped["path"] }
    File.delete(File.join(root, "composed", dropped["path"]))
  when "raw-missing"
    path = File.join(root, "raw", "manifest.json")
    raw = read(path)
    raw.fetch("cases").reject! { |entry| entry["path"] == target["rawPath"] }
    write(path, raw)
  when "unadopted"
    composition["adoption"]["provenanceDigest"] = rebind_record(root, composition.dig("adoption", "provenanceDigest")) do |provenance|
      provenance.fetch("images").each { |image| image["materialReview"]["decision"] = "rejected" }
    end
  when "alpha", "size", "replace"
    width, height = scenario == "size" ? [1200, 2600] : [target["width"], target["height"]]
    face = File.join(root, "composed", target["path"])
    png(face, width, height, scenario == "replace" ? 241 : 240, scenario == "alpha" ? 6 : 2)
    old = target["renderRecordDigest"]
    fresh = rebind_record(root, old) do |record|
      record.fetch("files")[target["order"] - 1].merge!("sha256" => sha(face), "width" => width, "height" => height)
    end
    composition.fetch("cases").each { |entry| entry["renderRecordDigest"] = fresh if entry["renderRecordDigest"] == old }
    target.merge!("digest" => sha(face), "width" => width, "height" => height)
    check["digest"] = sha(face)
  when "digest" then File.open(File.join(root, "composed", target["path"]), "ab") { |file| file.write("\0") }
  when "symlink"
    face = File.join(root, "composed", target["path"])
    File.rename(face, File.join(root, "outside.png"))
    File.symlink(File.join(root, "outside.png"), face)
  when "review-composed" then check["digest"] = target["rawDigest"]
  when "review-raw" then check.delete("rawDigest")
  when /\Acomposition-(sourceSha|buildDigest|runtime|requirementsDigest)\z/
    composition[$1] = $1 == "runtime" ? "com.apple.CoreSimulator.SimRuntime.iOS-26-0" : ($1 == "sourceSha" ? "f" * 40 : "sha256:#{'3' * 64}")
  when /\Araw-(sourceSha|buildDigest|runtime|requirementsDigest)\z/
    path = File.join(root, "raw", "manifest.json")
    raw = read(path)
    raw[$1] = $1 == "runtime" ? "com.apple.CoreSimulator.SimRuntime.iOS-26-0" : ($1 == "sourceSha" ? "f" * 40 : "sha256:#{'3' * 64}")
    write(path, raw)
  else abort "unknown scenario #{scenario}"
  end
  write(composition_path, composition)
  write(review_path, review)
end

command, *arguments = ARGV
case command
when "base" then base(*arguments)
when "review" then review(*arguments)
when "mutate" then mutate(*arguments)
else abort "unknown command #{command}"
end
RUBY
mkdir -p "$composed/valid"
ruby "$fixture" base "$composed/valid" "$composed_sha" "$composed_build" "$composed_runtime" "$requirements" "$composed_bundle"

take_in() { # root
  "$intake_tool" --delivery "$1/delivery" --raw-root "$1/raw" --requirements "$requirements" --bundle-id "$composed_bundle" \
    --workspace-repo "$1/workspace" --project-root "$1/project" --out "$1/composed"
}
build_composed() { # root output
  "$builder" --raw-root "$1/raw" --output-root "$2" --requirements "$requirements" --review "$1/review.json" \
    --source-sha "$composed_sha" --runtime "$composed_runtime" --build-digest "$composed_build" \
    --composition "$1/composed/composition.json" --composed-root "$1/composed"
}
take_in "$composed/valid" >/dev/null || { echo 'the intake refused the composed fixture' >&2; exit 1; }
ruby "$fixture" review "$composed/valid" "$composed_sha" "$composed_build"

# AC-6 (#549): the intake writes composition.json (schemaVersion 1) from the delivery and the raw capture
# manifest, with the fields of the exception adopted.json (capture batch, source, build, runtime,
# requirements, raw and composed digest of each face) and the adoption and provenance of the faces.
COMPOSED="$composed/valid" REQUIREMENTS="$requirements" SOURCE_SHA="$composed_sha" BUILD="$composed_build" RUNTIME="$composed_runtime" \
ruby -rjson -rdigest -e '
  root = ENV.fetch("COMPOSED")
  sha = ->(path) { "sha256:#{Digest::SHA256.file(path).hexdigest}" }
  value = JSON.parse(File.binread(File.join(root, "composed", "composition.json")))
  keys = %w[schemaVersion rawManifestDigest captureBatchId sourceSha buildDigest runtime requirementsDigest rendererDigest adoption cases]
  abort "composition keys #{value.keys}" unless value.keys == keys
  abort "composition identity" unless value["schemaVersion"] == 1 && value["captureBatchId"] == "486-store-r1" &&
    value["sourceSha"] == ENV.fetch("SOURCE_SHA") && value["buildDigest"] == ENV.fetch("BUILD") && value["runtime"] == ENV.fetch("RUNTIME") &&
    value["requirementsDigest"] == sha.(ENV.fetch("REQUIREMENTS")) && value["rawManifestDigest"] == sha.(File.join(root, "raw", "manifest.json")) &&
    value["rendererDigest"] == "sha256:#{"c" * 64}"
  adoption = value.fetch("adoption")
  expected = {"proposalSheetDigest" => sha.(File.join(root, "sheet.html")),
              "selectionDigest" => sha.(File.join(root, "workspace", "projects", "app", "case-1", "selection.json")),
              "conceptId" => "B", "decision" => "user-explicit", "approvalReference" => "https://github.com/yuto1201/iOS-Example/issues/7#issuecomment-123",
              "recordedAt" => "2026-10-15T00:00:00Z", "provenanceDigest" => sha.(File.join(root, "assets", "provenance.json"))}
  abort "adoption #{adoption}" unless adoption == expected
  abort "provenance copy" unless File.binread(File.join(root, "composed", "records", "#{expected["provenanceDigest"].sub(":", "-")}.json")) == File.binread(File.join(root, "assets", "provenance.json"))
  raw = JSON.parse(File.binread(File.join(root, "raw", "manifest.json"))).fetch("cases")
  cases = value.fetch("cases")
  abort "case count #{cases.length}" unless cases.length == 8
  leaf = sha.(File.join(root, "assets", "leaf.png"))
  case_keys = %w[locale family state order path rawPath rawDigest declarationDigest renderRecordDigest assetDigests width height digest]
  cases.each do |entry|
    abort "case keys #{entry.keys}" unless entry.keys == case_keys
    source = raw.find { |row| row.values_at("locale", "family", "state") == entry.values_at("locale", "family", "state") }
    folder = File.join(root, "renders", "#{entry["locale"]}-#{entry["family"]}")
    record = File.join(folder, "creative-render-#{entry["family"]}-#{entry["locale"]}.json")
    abort "raw binding #{entry["path"]}" unless entry["rawPath"] == source["path"] && entry["rawDigest"] == source["digest"]
    abort "path #{entry["path"]}" unless entry["path"] == format("%s/%s/%02d-%s.png", entry["locale"], entry["family"], entry["order"], entry["state"])
    abort "declaration #{entry["path"]}" unless entry["declarationDigest"] == sha.(File.join(folder, "tiles.json"))
    abort "render record #{entry["path"]}" unless entry["renderRecordDigest"] == sha.(record) &&
      File.binread(File.join(root, "composed", "records", "#{sha.(record).sub(":", "-")}.json")) == File.binread(record)
    abort "assets #{entry["path"]}" unless entry["assetDigests"] == (entry["order"] == 1 ? [leaf] : [])
    face = File.join(root, "composed", entry["path"])
    abort "face #{entry["path"]}" unless File.file?(face) && entry["digest"] == sha.(face) && entry["digest"] == sha.(File.join(folder, "tile-#{entry["order"]}.png"))
    abort "size #{entry["path"]}" unless [entry["width"], entry["height"]] == (entry["family"] == "iphone-6.3" ? [1206, 2622] : [2064, 2752])
  end
  abort "composition holds an absolute path" if File.binread(File.join(root, "composed", "composition.json")).include?(root)
' || { echo 'the intake did not write the expected composition record' >&2; exit 1; }

# AC-4: the composed set is ready, and its manifest keeps the composition digest and each face's rawDigest.
ready=$(build_composed "$composed/valid" "$composed/valid/out")
[[ "$ready" == *'"status":"ready"'* && "$ready" == *'"compositionDigest":"sha256:'* ]] || { echo "composed set failed: $ready" >&2; exit 1; }
COMPOSED="$composed/valid" ruby -rjson -rdigest -e '
  root = ENV.fetch("COMPOSED")
  sha = ->(path) { "sha256:#{Digest::SHA256.file(path).hexdigest}" }
  manifest = JSON.parse(File.binread(File.join(root, "out", "manifest.json")))
  composition = JSON.parse(File.binread(File.join(root, "composed", "composition.json")))
  abort "manifest keys #{manifest.keys}" unless manifest.keys == %w[schemaVersion sourceSha buildDigest runtime requirementsDigest reviewDigest compositionDigest cases]
  abort "composition digest" unless manifest["schemaVersion"] == 1 && manifest["compositionDigest"] == sha.(File.join(root, "composed", "composition.json"))
  abort "composition copy" unless File.binread(File.join(root, "out", "composition.json")) == File.binread(File.join(root, "composed", "composition.json"))
  raw = JSON.parse(File.binread(File.join(root, "raw", "manifest.json"))).fetch("cases")
  abort "case count" unless manifest.fetch("cases").length == 8
  manifest.fetch("cases").each do |entry|
    source = raw.find { |row| row.values_at("locale", "family", "state") == entry.values_at("locale", "family", "state") }
    face = composition.fetch("cases").find { |row| row["path"] == entry["path"] }
    abort "rawDigest #{entry["path"]}" unless entry["rawDigest"] == source["digest"] && entry["rawDigest"] == face["rawDigest"]
    abort "digest #{entry["path"]}" unless entry["digest"] == sha.(File.join(root, "out", entry["path"])) && entry["digest"] == face["digest"] && entry["digest"] != entry["rawDigest"]
    abort "identity #{entry["path"]}" unless entry.values_at("sourceSha", "buildDigest", "runtime", "deviceType") == source.values_at("sourceSha", "buildDigest", "runtime", "deviceType")
  end
' || { echo 'composed manifest does not bind the composition and raw digests' >&2; exit 1; }

# AC-5: each inconsistency is refused with its reason, and nothing is written.
assert_composed_refused() { # label root expected
  rm -rf -- "$2/out"
  set +e; output=$(build_composed "$2" "$2/out" 2>&1); status=$?; set -e
  [[ "$status" -ne 0 && "$output" == *"$3"* && ! -e "$2/out" ]] || { echo "expected composed failure: $1: $output" >&2; exit 1; }
}
refuse_mutation() { # scenario expected [path]
  local root="$composed/m-$1"
  rm -rf -- "$root"; /bin/cp -R "$composed/valid" "$root"; rm -rf -- "$root/out"
  ruby "$fixture" mutate "$root" "$1" ${3:+"$3"}
  assert_composed_refused "$1" "$root" "$2"
}
refuse_mutation raw-digest 'en-US/iphone-6.3/01-primary.png:raw-digest-mismatch'
refuse_mutation raw-missing 'en-US/iphone-6.3/01-primary.png:raw-case-missing'
refuse_mutation declaration 'en-US/iphone-6.3/01-primary.png:declaration-mismatch'
refuse_mutation unadopted 'en-US/iphone-6.3/01-primary.png:asset-not-adopted'
refuse_mutation alpha 'ja/iphone-6.3/01-primary.png:alpha-not-allowed' ja/iphone-6.3/01-primary.png
refuse_mutation size 'ja/iphone-6.3/01-primary.png:dimensions-not-allowed' ja/iphone-6.3/01-primary.png
refuse_mutation digest 'en-US/iphone-6.3/01-primary.png:digest-mismatch'
refuse_mutation symlink 'en-US/iphone-6.3/01-primary.png:unsafe-file'
refuse_mutation reorder 'screenshots/iphone-6.3:locale-structure-mismatch'
refuse_mutation drop 'screenshots/iphone-6.3:locale-structure-mismatch'
refuse_mutation record-null 'en-US/iphone-6.3/01-primary.png:render-record:record-digest-invalid'
refuse_mutation record-malformed 'en-US/iphone-6.3/01-primary.png:render-record:record-digest-invalid'
refuse_mutation review-composed 'en-US/iphone-6.3/01-primary.png:review-digest-mismatch'
refuse_mutation review-raw '.rawDigest:missing'
for field in sourceSha buildDigest runtime requirementsDigest; do
  refuse_mutation "composition-$field" "composition.$field:mismatch"
  refuse_mutation "raw-$field" "manifest.$field:mismatch"
done

# AC-7: a package with the composed set passes the package check and the seal, and the package digest
# that the release auditor approves covers screenshots/composition.json.
seal_package_root="$seal_project/App Store"
saved_project=$fixture_project saved_package=$package_root
fixture_project="$test_workspace/seal-staging"; package_root="$fixture_project/App Store"
write_valid_fixture
/usr/bin/sed -i '' "s/com.yuto.TemplateApp/$composed_bundle/" "$package_root/metadata/app.yml"
rm -rf -- "$package_root/screenshots"
/bin/cp -R "$composed/valid/out" "$package_root/screenshots"
/bin/mv "$package_root" "$seal_package_root"
fixture_project=$saved_project package_root=$saved_package
mkdir -p "$seal_project/tools"
/bin/cp "$validator" "$seal_project/tools/validate-appstore-package.sh"; chmod +x "$seal_project/tools/validate-appstore-package.sh"
fresh=$("$validator" --root "$seal_package_root" --project-root "$seal_project" --bundle-id "$composed_bundle" --version 1.0 \
  --requirements "$seal_package_root/submission/requirements.json" --require-fresh --now "$composed_now")
[[ "$fresh" == *'"status":"ready"'* ]] || { echo "composed package failed the fresh package check: $fresh" >&2; exit 1; }
package_tree_digest() { # [excluded relative path]
  PACKAGE="$seal_package_root" EXCLUDED="${1-}" ruby -rdigest -e '
    root = ENV.fetch("PACKAGE"); entries = []
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
      next if [".", ".."].include?(File.basename(path)); relative = path.delete_prefix(root + File::SEPARATOR)
      next unless File.file?(path) && !File.symlink?(path)
      next if relative.match?(%r{\Asubmission/[0-9]+(?:\.[0-9]+){1,2}-(?:package|result)\.json\z}) || relative == ENV.fetch("EXCLUDED")
      entries << "#{relative}\0#{Digest::SHA256.file(path).hexdigest}\0"
    end
    puts "sha256:#{Digest::SHA256.hexdigest(entries.join)}"
  '
}
write_release_audit() { # package digest
  DIGEST="$1" SOURCE_SHA="$composed_sha" BUILD="$composed_build" ruby -rjson -e '
    File.binwrite(ARGV[0], JSON.generate({"schemaVersion" => 1, "status" => "approved", "role" => "release-auditor",
      "sourceSha" => ENV.fetch("SOURCE_SHA"), "buildDigest" => ENV.fetch("BUILD"), "packageDigest" => ENV.fetch("DIGEST"), "findings" => []}))
  ' "$test_workspace/release-audit.json"
}
seal_composed() {
  "$seal" --repo "$seal_project" --package-root "$seal_package_root" --requirements "$seal_package_root/submission/requirements.json" \
    --bundle-id "$composed_bundle" --version 1.0 --source-sha "$composed_sha" --build-digest "$composed_build" \
    --verification-issue 42 --verification-base "$verification_base" --audit "$test_workspace/release-audit.json" \
    --first-publication no --legal-approval none --output "$seal_package_root/submission/1.0-package.json" --now "$composed_now"
}
assert_seal_refused() { # label expected
  rm -f -- "$seal_package_root/submission/1.0-package.json"
  set +e; output=$(seal_composed 2>&1); status=$?; set -e
  [[ "$status" -ne 0 && "$output" == *"$2"* ]] || { echo "expected seal failure: $1: $output" >&2; exit 1; }
}
approved_digest=$(package_tree_digest)
without_composition=$(package_tree_digest screenshots/composition.json)
[[ "$approved_digest" != "$without_composition" ]] || { echo 'the package digest ignores the composition record' >&2; exit 1; }
write_release_audit "$approved_digest"
sealed=$(seal_composed)
[[ "$sealed" == *'"status":"prepared"'* ]] || { echo "composed package was not sealed: $sealed" >&2; exit 1; }
SEALED="$seal_package_root/submission/1.0-package.json" DIGEST="$approved_digest" MANIFEST="$seal_package_root/screenshots/manifest.json" ruby -rjson -rdigest -e '
  value = JSON.parse(File.binread(ENV.fetch("SEALED")))
  abort "package digest" unless value["packageDigest"] == ENV.fetch("DIGEST")
  abort "screenshot manifest digest" unless value["screenshotManifestDigest"] == "sha256:#{Digest::SHA256.file(ENV.fetch("MANIFEST")).hexdigest}"
  abort "composition digest" unless JSON.parse(File.binread(ENV.fetch("MANIFEST")))["compositionDigest"].to_s.start_with?("sha256:")
' || { echo 'the seal does not bind the composed package digest' >&2; exit 1; }

# AC-8: the release auditor's approval binds the composed package digest exactly as for raw captures.
# A changed composition record or one replaced composed image makes the approval and the seal stale.
record_composed() {
  printf '{}\n' >"$test_workspace/preflight.json"
  "$record_section" --repo "$seal_project" --package-root "$seal_package_root" --package-manifest "$seal_package_root/submission/1.0-package.json" \
    --preflight "$test_workspace/preflight.json" --audit "$test_workspace/release-audit.json" --result "$seal_package_root/submission/1.0-result.json" \
    --team-id YUTO-PERSONAL-TEAM --bundle-id "$composed_bundle" --version 1.0 --build-id 42 --source-sha "$composed_sha" \
    --build-digest "$composed_build" --primary-model claude --section app-information --readback-source api \
    --remote-reference "asc://apps/$composed_bundle/versions/1.0/app-information" \
    --readback-digest sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc --resume-readback no --now "$composed_now" 2>&1 || true
}
current=$(record_composed)
[[ "$current" != *'stale'* ]] || { echo "the sealed composed package was already stale: $current" >&2; exit 1; }
/bin/cp "$seal_package_root/screenshots/composition.json" "$test_workspace/composition.json"
printf '\n' >>"$seal_package_root/screenshots/composition.json"
assert_seal_refused 'changed composition record' 'release audit identity mismatch'
/bin/cp "$test_workspace/composition.json" "$seal_package_root/screenshots/composition.json"
seal_composed >/dev/null
replaced="$composed/m-replaced"
rm -rf -- "$replaced"; /bin/cp -R "$composed/valid" "$replaced"; rm -rf -- "$replaced/out"
ruby "$fixture" mutate "$replaced" replace ja/ipad-13/02-settings.png
replaced_ready=$(build_composed "$replaced" "$replaced/out")
[[ "$replaced_ready" == *'"status":"ready"'* ]] || { echo "the replaced composed set failed: $replaced_ready" >&2; exit 1; }
rm -rf -- "$seal_package_root/screenshots"
/bin/cp -R "$replaced/out" "$seal_package_root/screenshots"
[[ "$(package_tree_digest)" != "$approved_digest" ]] || { echo 'replacing a composed image did not change the package digest' >&2; exit 1; }
stale=$(record_composed)
[[ "$stale" == *'prepared package digest is stale'* ]] || { echo "the seal stayed current after a composed image was replaced: $stale" >&2; exit 1; }
assert_seal_refused 'replaced composed image under the old approval' 'release audit identity mismatch'

echo 'PASS: App Store package validation catches localized limits, privacy mismatches, missing families, URLs, and review credentials, and seals a composed screenshot set bound to its raw captures'
