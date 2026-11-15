#!/usr/bin/env bash
set -euo pipefail

# D-106 (#537): tools/intake-appstore-delivery.sh takes in a delivery from the App Store creative
# workspace. Every capture, face, render record, material, choice and copy is made here from small
# generated files and a throwaway Git repository; nothing is committed and nothing reaches the network.
source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby mktemp

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
intake="$repo_root/tools/intake-appstore-delivery.sh"
builder="$repo_root/tools/build-appstore-screenshot-set.sh"
requirements="$repo_root/tools/tests/fixtures/appstore/requirements.json"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/appstore-intake.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)

source_sha=$(printf 'a%.0s' {1..40})
build_digest=sha256:$(printf 'b%.0s' {1..64})
runtime=com.apple.CoreSimulator.SimRuntime.iOS-27-0
bundle_id=com.example.TemplateApp

fixture="$tmp/fixture.rb"
cat >"$fixture" <<'RUBY'
# encoding: UTF-8
require "json"
require "digest"
require "fileutils"
require "open3"
require "zlib"

SIZES = {"iphone-6.3" => [1206, 2622], "ipad-13" => [2064, 2752]}.freeze
DEVICES = {"iphone-6.3" => "iPhone 17 Pro", "ipad-13" => "iPad Pro (M5)"}.freeze
SETS = [["en-US", "iphone-6.3"], ["en-US", "ipad-13"], ["ja", "iphone-6.3"], ["ja", "ipad-13"]].freeze
STATES = %w[primary settings].freeze
COPY = {
  "en-US" => {"name" => "Tempo: Focus Timer", "subtitle" => "Plan work sessions and breaks",
              "description" => "Tempo splits your work into focused sessions with short breaks in between.\n\nFeatures:\n- Set the length of each session\n- See the sessions you finished today",
              "keywords" => "study,concentration,productivity,deadline,routine,exam",
              "promotionalText" => "New sound themes for quiet study are here."},
  "ja" => {"name" => "Tempo：集中タイマー", "subtitle" => "作業と休憩のリズムを作る",
           "description" => "Tempoは、作業を短い集中の時間と休憩に分けて進めるためのタイマーです。\n\n主な機能：\n・1回の長さを決める\n・今日終えた回数を見る",
           "keywords" => "勉強,学習,習慣,時間管理,試験,集中力",
           "promotionalText" => "静かな勉強に合う新しい音のテーマを追加しました。"}
}.freeze

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

# The app's raw captures, the workspace's renders and choice, and the delivery made from them.
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

  # The workspace: renders with absolute paths (as the compose renderer writes them) and a committed choice.
  workspace = File.join(root, "workspace")
  work = File.join(workspace, "outputs")
  png(File.join(work, "assets", "leaf.png"), 64, 64, 200)
  png(File.join(work, "assets", "stray.png"), 64, 64, 201)
  leaf = File.join(work, "assets", "leaf.png")
  stray = File.join(work, "assets", "stray.png")
  write(File.join(work, "provenance.json"), {"schemaVersion" => 1, "images" => [
    {"file" => "leaf.png", "sha256" => sha(leaf), "materialReview" => {"decision" => "adopted"}},
    {"file" => "stray.png", "sha256" => sha(stray), "materialReview" => {"decision" => "rejected"}}]})
  write(File.join(work, "brand.json"), {"schemaVersion" => 1, "name" => "Tempo"})
  renders = SETS.each_with_index.map do |(locale, family), set|
    folder = File.join(work, "renders", "#{locale}-#{family}")
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
  FileUtils.mkdir_p(File.join(workspace, "projects", "app", "case-1"))
  sheet_html = File.join(work, "sheet.html")
  File.binwrite(sheet_html, "<!doctype html><title>preview</title>\n")
  selection = File.join(workspace, "projects", "app", "case-1", "selection.json")
  write(selection, {"schemaVersion" => 1, "revision" => "p1", "sheetSha256" => sha(sheet_html),
    "selection" => {"type" => "pattern", "patternId" => "B"}, "decision" => "user-explicit", "recordedAt" => "2026-11-14T00:00:00Z"})
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
  put.(File.join(work, "provenance.json"), "screenshots/provenance.json", "provenance")
  put.(File.join(work, "brand.json"), "screenshots/brand.json", "brand")
  COPY.each do |locale, fields|
    path = File.join(work, "copy", "#{locale}.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, fields.map { |key, value| "#{key}: #{JSON.generate(value)}" }.join("\n") + "\n")
    put.(path, "copy/localizations/#{locale}.yml", "copy")
  end
  write(File.join(delivery, "delivery.json"), {
    "schemaVersion" => 1,
    "workspace" => {"repository" => "example/Tool-AppStore-Creative", "commit" => commit, "caseId" => "case-1"},
    "app" => {"bundleId" => bundle_id},
    "kinds" => %w[screenshots copy],
    "inputs" => {"captureBatch" => "534-store-r1", "rawManifestSha256" => sha(File.join(raw_root, "manifest.json")),
                 "sourceSha" => source_sha, "buildDigest" => build_digest, "runtime" => runtime,
                 "requirementsSha256" => sha(requirements), "brandSha256" => sha(File.join(work, "brand.json")), "appCommit" => source_sha},
    "renderer" => {"path" => "tools/lib/appstore-creative-compose.rb", "sha256" => "sha256:#{'c' * 64}"},
    "adoption" => {"decision" => "user-explicit", "at" => "2026-11-14T00:00:00Z", "where" => "chat",
                   "approvalReference" => "https://github.com/yuto1201/iOS-Example/issues/7#issuecomment-123", "choice" => "B",
                   "sheetKind" => "preview", "sheetSha256" => sha(sheet_html),
                   "record" => {"path" => "projects/app/case-1/selection.json", "sha256" => sha(selection)}},
    "faces" => faces,
    "files" => listed.sort_by { |file| file["path"] },
    "checks" => []
  })
  # The app's project: only its submission requirements, for the store-copy check.
  project = File.join(root, "project")
  FileUtils.mkdir_p(File.join(project, "App Store", "submission"))
  FileUtils.cp(requirements, File.join(project, "App Store", "submission", "requirements.json"))
end

# A copy of the valid delivery with one change, written to `target`.
def mutate(root, target, scenario)
  FileUtils.cp_r(File.join(root, "delivery"), target)
  path = File.join(target, "delivery.json")
  delivery = read(path)
  files = File.join(target, "files")
  relist = lambda do |relative|
    entry = delivery["files"].find { |file| file["path"] == relative }
    entry["sha256"] = sha(File.join(files, relative))
    entry["bytes"] = File.size(File.join(files, relative))
  end
  face = delivery["faces"].first
  case scenario
  when "file-digest" then File.open(File.join(files, face["path"]), "ab") { |file| file.write("\0") }
  when "unlisted" then File.binwrite(File.join(files, "screenshots", "extra.txt"), "extra\n")
  when "bundle" then delivery["app"]["bundleId"] = "com.example.Other"
  when "raw-manifest" then delivery["inputs"]["rawManifestSha256"] = "sha256:#{'d' * 64}"
  when "raw-source" then delivery["inputs"]["buildDigest"] = "sha256:#{'e' * 64}"
  when "requirements" then delivery["inputs"]["requirementsSha256"] = "sha256:#{'f' * 64}"
  when "unnamed-face"
    png(File.join(files, face["path"]), 1206, 2622, 250)
    relist.(face["path"])
    face["sha256"] = sha(File.join(files, face["path"]))
  when "unadopted"
    provenance = File.join(files, "screenshots", "provenance.json")
    value = read(provenance)
    value["images"].each { |image| image["materialReview"]["decision"] = "rejected" }
    write(provenance, value)
    relist.("screenshots/provenance.json")
  when "choice-missing" then delivery["adoption"]["record"]["path"] = "projects/app/case-1/missing.json"
  when "choice-digest" then delivery["adoption"]["record"]["sha256"] = "sha256:#{'9' * 64}"
  when "not-explicit" then delivery["adoption"]["decision"] = "recommended"
  when "choice-other" then delivery["adoption"]["choice"] = "A"
  else abort "unknown scenario #{scenario}"
  end
  write(path, delivery)
end

def review(composed, source_sha, build_digest, output)
  composition = read(File.join(composed, "composition.json"))
  write(output, {"schemaVersion" => 1, "sourceSha" => source_sha, "buildDigest" => build_digest,
    "visualReviewStatus" => "passed", "releaseAuditor" => {"status" => "approved", "model" => "release-auditor"},
    "cases" => composition.fetch("cases").map do |entry|
      entry.slice("locale", "family", "state", "path", "digest", "rawDigest").merge(
        "safeArea" => "passed", "textClipping" => "passed", "truthfulRepresentation" => "passed", "localeParity" => "passed")
    end})
end

command, *arguments = ARGV
case command
when "base" then base(*arguments)
when "mutate" then mutate(*arguments)
when "review" then review(*arguments)
else abort "unknown command #{command}"
end
RUBY

root="$tmp/case"
mkdir -p "$root"
ruby "$fixture" base "$root" "$source_sha" "$build_digest" "$runtime" "$requirements" "$bundle_id"

run_intake() { # delivery out
  "$intake" --delivery "$1" --raw-root "$root/raw" --requirements "$requirements" --bundle-id "$bundle_id" \
    --workspace-repo "$root/workspace" --project-root "$root/project" --out "$2"
}
snapshot() {
  (cd "$root" && find raw project workspace -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) | shasum -a 256
}

# AC-4: a valid delivery is taken in, and the builder accepts what the intake wrote.
before=$(snapshot)
out="$tmp/out-valid"
run_intake "$root/delivery" "$out" >"$tmp/valid.json" || { echo 'intake refused the valid delivery' >&2; exit 1; }
COMPOSED="$out" RAW="$root/raw" REQUIREMENTS="$requirements" SOURCE_SHA="$source_sha" BUILD="$build_digest" RUNTIME="$runtime" ruby -rjson -rdigest -e '
  root = ENV.fetch("COMPOSED")
  sha = ->(path) { "sha256:#{Digest::SHA256.file(path).hexdigest}" }
  value = JSON.parse(File.binread(File.join(root, "composition.json")))
  keys = %w[schemaVersion rawManifestDigest captureBatchId sourceSha buildDigest runtime requirementsDigest rendererDigest adoption cases]
  abort "composition keys #{value.keys}" unless value.keys == keys
  abort "composition identity" unless value["schemaVersion"] == 1 && value["captureBatchId"] == "534-store-r1" &&
    value["sourceSha"] == ENV.fetch("SOURCE_SHA") && value["buildDigest"] == ENV.fetch("BUILD") && value["runtime"] == ENV.fetch("RUNTIME") &&
    value["rawManifestDigest"] == sha.(File.join(ENV.fetch("RAW"), "manifest.json")) && value["requirementsDigest"] == sha.(ENV.fetch("REQUIREMENTS"))
  adoption = value["adoption"]
  abort "adoption keys #{adoption.keys}" unless adoption.keys == %w[proposalSheetDigest selectionDigest conceptId decision approvalReference recordedAt provenanceDigest]
  abort "adoption values" unless adoption["decision"] == "user-explicit" && adoption["conceptId"] == "B" && adoption["recordedAt"] == "2026-11-14T00:00:00Z"
  abort "case count" unless value["cases"].size == 8
  value["cases"].each do |entry|
    abort "case keys #{entry.keys}" unless entry.keys == %w[locale family state order path rawPath rawDigest declarationDigest renderRecordDigest assetDigests width height digest]
    abort "face #{entry["path"]}" unless sha.(File.join(root, entry["path"])) == entry["digest"]
    abort "record #{entry["renderRecordDigest"]}" unless File.file?(File.join(root, "records", entry["renderRecordDigest"].sub(":", "-") + ".json"))
  end
  abort "provenance copy" unless File.file?(File.join(root, "records", adoption["provenanceDigest"].sub(":", "-") + ".json"))
  intake = JSON.parse(File.binread(File.join(root, "intake.json")))
  abort "intake #{intake}" unless intake["status"] == "accepted" && intake["compositionSha256"] == sha.(File.join(root, "composition.json")) &&
    intake["copy"] == {"locales" => %w[en-US ja], "errors" => 0, "warnings" => 0}
'
ruby "$fixture" review "$out" "$source_sha" "$build_digest" "$tmp/review.json"
"$builder" --raw-root "$root/raw" --output-root "$tmp/assembled" --requirements "$requirements" --review "$tmp/review.json" \
  --source-sha "$source_sha" --runtime "$runtime" --build-digest "$build_digest" \
  --composition "$out/composition.json" --composed-root "$out" >"$tmp/assembled.log" 2>&1 ||
  { cat "$tmp/assembled.log" >&2; echo 'the builder refused what the intake wrote' >&2; exit 1; }
[[ -f "$tmp/assembled/composition.json" && -f "$tmp/assembled/manifest.json" ]] || { echo 'the assembled set has no composition record' >&2; exit 1; }

# AC-5: each defect stops the intake before anything is written.
expect_refused() { # scenario message
  local delivery="$tmp/delivery-$1" target="$tmp/out-$1" log="$tmp/refused-$1.log"
  ruby "$fixture" mutate "$root" "$delivery" "$1"
  if run_intake "$delivery" "$target" >"$log" 2>&1; then
    echo "intake accepted the $1 delivery" >&2; exit 1
  fi
  grep -q -- "$2" "$log" || { cat "$log" >&2; echo "intake refused the $1 delivery for another reason" >&2; exit 1; }
  [[ ! -e "$target" ]] || { echo "intake wrote output for the $1 delivery" >&2; exit 1; }
}
expect_refused file-digest 'does not have its listed SHA-256'
expect_refused unlisted 'is delivered but not listed'
expect_refused bundle 'not com.example.TemplateApp'
expect_refused raw-manifest 'is not the one the delivery was made from'
expect_refused raw-source 'inputs.buildDigest differs'
expect_refused requirements 'made for other submission requirements'
expect_refused unnamed-face 'is not the tile its record drew'
expect_refused unadopted 'does not record as adopted'
expect_refused choice-missing 'is not in the workspace commit'
expect_refused choice-digest 'does not have the delivered SHA-256'
expect_refused not-explicit 'must be user-explicit'
expect_refused choice-other 'differs from the recorded choice'

# An existing --out is never overwritten.
mkdir "$tmp/existing"
if run_intake "$root/delivery" "$tmp/existing" >"$tmp/existing.log" 2>&1; then
  echo 'intake wrote into an existing folder' >&2; exit 1
fi
grep -q 'must be a new folder' "$tmp/existing.log" || { cat "$tmp/existing.log" >&2; exit 1; }

# AC-6: --out may not land in the app's project (its App Store folder, its source), not even through a
# link to an ancestor; only the project's .artifacts working folder is allowed inside it.
mkdir -p "$root/project/App Store/screenshots" "$root/project/TemplateApp"
ln -s "$root/project" "$tmp/project-link"
expect_out_refused() { # name out
  local log="$tmp/out-refused-$1.log"
  if run_intake "$root/delivery" "$2" >"$log" 2>&1; then
    echo "intake wrote its output into the project ($1)" >&2; exit 1
  fi
  grep -q -- 'must be outside the app' "$log" || { cat "$log" >&2; echo "intake refused --out ($1) for another reason" >&2; exit 1; }
  [[ ! -e "$2" ]] || { echo "intake left output at --out ($1)" >&2; exit 1; }
}
expect_out_refused app-store "$root/project/App Store/intake-new"
expect_out_refused source "$root/project/TemplateApp/intake-new"
expect_out_refused through-link "$tmp/project-link/App Store/screenshots/intake-new"
[[ -z "$(find "$root/project" -name composition.json -print -quit)" ]] || { echo 'intake wrote composition.json into the project' >&2; exit 1; }

# AC-6: the intake changes nothing in the app's project, the raw captures or the workspace, and its code
# loads no network library and writes only under --out.
[[ "$(snapshot)" == "$before" ]] || { echo 'intake changed the project, the captures or the workspace' >&2; exit 1; }
library="$repo_root/tools/lib/appstore-intake.rb"
for name in net/http net/https open-uri socket resolv; do
  ! grep -Eq "require ['\"]$name['\"]" "$library" || { echo "intake loads $name" >&2; exit 1; }
done
! grep -Ev '^[[:space:]]*#' "$library" | grep -q 'App Store/' || { echo 'intake code names the App Store folder' >&2; exit 1; }
grep -q '/usr/bin/env -i PATH=/usr/bin:/bin' "$intake" || { echo 'intake wrapper must clear the environment' >&2; exit 1; }
grep -q 'bounded-command.rb' "$intake" || { echo 'intake wrapper must bound the run' >&2; exit 1; }

# AC-6: a partial (promisor) clone of the workspace that lacks the choice blob is refused offline; Git
# never runs its transport to fetch the blob and the clone gains no object.
git clone -q --bare "$root/workspace" "$tmp/upstream.git"
git -C "$tmp/upstream.git" config uploadpack.allowFilter true
git clone -q --bare --filter=blob:none "file://$tmp/upstream.git" "$tmp/partial.git"
cat >"$tmp/sentinel-upload-pack.sh" <<SENTINEL
#!/bin/bash
: >"$tmp/transport-ran"
exec /usr/bin/git upload-pack "\$@"
SENTINEL
chmod +x "$tmp/sentinel-upload-pack.sh"
git -C "$tmp/partial.git" config remote.origin.uploadpack "$tmp/sentinel-upload-pack.sh"
partial_objects() { find "$tmp/partial.git/objects" -type f | LC_ALL=C sort | shasum -a 256; }
partial_before=$(partial_objects)
if "$intake" --delivery "$root/delivery" --raw-root "$root/raw" --requirements "$requirements" --bundle-id "$bundle_id" \
  --workspace-repo "$tmp/partial.git" --project-root "$root/project" --out "$tmp/out-partial" >"$tmp/partial.log" 2>&1; then
  echo 'intake fetched the missing choice blob from the promisor remote' >&2; exit 1
fi
grep -q 'is not in the workspace commit' "$tmp/partial.log" || { cat "$tmp/partial.log" >&2; echo 'intake refused the partial clone for another reason' >&2; exit 1; }
[[ ! -e "$tmp/transport-ran" ]] || { echo 'intake ran a Git transport' >&2; exit 1; }
[[ "$(partial_objects)" == "$partial_before" ]] || { echo 'intake changed the workspace clone' >&2; exit 1; }
[[ ! -e "$tmp/out-partial" ]] || { echo 'intake wrote output for the partial clone' >&2; exit 1; }

# The project's .artifacts working folder is the one place inside the project that --out may use.
mkdir -p "$root/project/.artifacts"
run_intake "$root/delivery" "$root/project/.artifacts/intake-ok" >"$tmp/artifacts.json" ||
  { echo 'intake refused --out under the project .artifacts folder' >&2; exit 1; }
[[ -f "$root/project/.artifacts/intake-ok/composition.json" ]] || { echo 'intake wrote no composition under .artifacts' >&2; exit 1; }

echo "App Store intake passed (2 deliveries accepted, 1 assembled, 17 refusals, no writes outside --out, no Git transport)"
