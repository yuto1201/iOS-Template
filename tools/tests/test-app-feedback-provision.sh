#!/bin/bash
set -euo pipefail

# D-076: the app feedback provisioning tool, run in a sample app with fake gh, wrangler, security and
# curl. Fixes the refusals before any change, the order of the stages, reruns that create nothing
# twice, the stop while the shared GitHub App is not installed, and that no secret value leaves the
# child processes.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" node ruby

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-app-feedback-provision.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'chmod -R u+rwX "$work" 2>/dev/null || true; rm -rf -- "$work"' EXIT

major=$(node -p 'process.versions.node.split(".")[0]')
(( major >= 24 )) || {
  echo "test prerequisite unavailable (${0##*/}): Node 24 or later is required; see docs/verification.md (test prerequisites)" >&2
  exit 69
}

fail() {
  echo "app feedback provisioning test failed: $*" >&2
  exit 1
}

APP_ID=73519
INSTALLATION_ID=86421
ACCOUNT=0123456789abcdef0123456789abcdef
fakes="$work/fakes"
mkdir -p "$fakes"

# --- Fakes -------------------------------------------------------------------------------------
# Each fake logs its argv to calls.log and keeps its state in $FAKE_STATE/state.json. They keep only
# digests of the secrets they receive.

cat > "$fakes/common.rb" <<'RUBY'
require "json"
require "digest"
STATE = File.join(ENV.fetch("FAKE_STATE"), "state.json")
def state
  JSON.parse(File.read(STATE))
end
def save(value)
  File.write(STATE, JSON.pretty_generate(value))
end
def log(name, arguments)
  File.open(File.join(ENV.fetch("FAKE_STATE"), "calls.log"), "a") { |file| file.puts(([name] + arguments).join(" ")) }
end
def event(text)
  File.open(File.join(ENV.fetch("FAKE_STATE"), "events.log"), "a") { |file| file.puts(text) }
end
RUBY

cat > "$fakes/gh" <<'RUBY'
#!/usr/bin/ruby
require_relative "common"
log("gh", ARGV)
abort "fake gh supports only api" unless ARGV.first == "api"
arguments = ARGV.drop(1)
method = "GET"
fields = {}
path = nil
until arguments.empty?
  argument = arguments.shift
  case argument
  when "--method" then method = arguments.shift
  when "-f", "-F"
    key, value = arguments.shift.split("=", 2)
    fields[key] = argument == "-F" ? JSON.parse(value) : value
  else path = argument
  end
end
s = state
not_found = lambda { warn "gh: Not Found (HTTP 404)"; exit 1 }
case [method, path]
when ["GET", "user"]
  puts JSON.generate({"login" => s["ghLogin"]})
when ["POST", "user/repos"]
  name = "#{s["ghLogin"]}/#{fields.fetch("name")}"
  abort "already exists" if s["repos"].key?(name)
  abort "not private" unless fields["private"] == true
  s["repos"][name] = {"labels" => %w[bug documentation enhancement question], "issues" => []}
  save(s)
  event("repo-create #{name}")
  puts JSON.generate({"full_name" => name, "private" => true, "owner" => {"login" => s["ghLogin"]}})
else
  match = path.to_s.match(%r{\Arepos/([^/]+/[^/?]+)(/[^?]*)?(\?.*)?\z}) or abort "unexpected gh path #{path}"
  name, rest = match[1], match[2].to_s
  repository = s["repos"][name] or not_found.call
  case [method, rest]
  when ["GET", ""]
    puts JSON.generate({"full_name" => name, "private" => repository.fetch("private", true), "archived" => false,
                        "owner" => {"login" => name.split("/").first}})
  when ["GET", "/labels"]
    puts JSON.generate(repository["labels"].map { |label| {"name" => label} })
  when ["POST", "/labels"]
    abort "duplicate label" if repository["labels"].include?(fields.fetch("name"))
    repository["labels"] << fields.fetch("name")
    save(s)
    event("label-create #{fields.fetch("name")}")
    puts JSON.generate({"name" => fields.fetch("name")})
  when ["GET", "/issues"]
    puts JSON.generate(repository["issues"])
  else
    abort "unexpected gh request #{method} #{path}"
  end
end
RUBY

cat > "$fakes/wrangler" <<'RUBY'
#!/usr/bin/ruby
require_relative "common"
require "openssl"
log("wrangler", ARGV)
s = state
abort "account is not pinned" unless ENV["CLOUDFLARE_ACCOUNT_ID"] == s["expectedAccount"]
abort "metrics are not off" unless ENV["WRANGLER_SEND_METRICS"] == "false"
case ARGV.first(2)
when ["whoami", "--json"]
  puts JSON.generate({"loggedIn" => true, "authType" => "OAuth Token", "email" => "person@example.invalid",
                      "accounts" => [{"id" => s["wranglerAccount"], "name" => "Example"}]})
when ["deploy"]
  config = JSON.parse(File.read("wrangler.jsonc"))
  name = config.fetch("name")
  if s["deployFails"]
    warn "X [ERROR] A request to the Cloudflare API failed."
    exit 1
  end
  s["workers"][name] ||= {"secrets" => {}}
  s["workers"][name]["deploys"] = s["workers"][name].fetch("deploys", 0) + 1
  s["workers"][name]["namespace"] = config.dig("ratelimits", 0, "namespace_id")
  s["workers"][name]["repository"] = config.dig("vars", "GITHUB_REPOSITORY")
  save(s)
  event("deploy #{name}")
  puts "Uploaded #{name} (1.23 sec)"
  puts "Deployed #{name} triggers (0.45 sec)"
  puts "  https://#{name}.example-sub.workers.dev"
  puts "Current Version ID: 00000000-0000-0000-0000-000000000000"
when ["secret", "list"]
  name = ARGV[ARGV.index("--name") + 1]
  worker = s["workers"][name] or (warn "This Worker does not exist"; exit 1)
  puts JSON.generate(worker["secrets"].keys.map { |key| {"name" => key, "type" => "secret_text"} })
when ["secret", "put"]
  key = ARGV[2]
  name = ARGV[ARGV.index("--name") + 1]
  worker = s["workers"][name] or abort "no Worker"
  value = STDIN.read
  check = case key
          when "GITHUB_APP_SIGNING_PKCS8"
            key_object = OpenSSL::PKey.read(value)
            value.start_with?("-----BEGIN " + ["PRIVATE", "KEY"].join(" ") + "-----") &&
              key_object.public_key.to_der == OpenSSL::PKey.read(File.read(ENV.fetch("FAKE_PUBLIC_KEY"))).to_der ? "pkcs8-ok" : "pkcs8-bad"
          else
            Digest::SHA256.hexdigest(value)
          end
  worker["secrets"][key] = check
  save(s)
  event("secret-put #{key}")
  puts "Success! Uploaded secret #{key}"
else
  abort "unexpected wrangler #{ARGV.join(" ")}"
end
RUBY

cat > "$fakes/security" <<'RUBY'
#!/usr/bin/ruby
require_relative "common"
log("security", ARGV)
abort "unexpected security call" unless ARGV.first == "find-generic-password" && ARGV.last == "-w"
account = ARGV[ARGV.index("-a") + 1]
service = ARGV[ARGV.index("-s") + 1]
value = state["keychain"]["#{account} #{service}"]
exit 44 if value.nil?
puts value
RUBY

cat > "$fakes/curl" <<'RUBY'
#!/usr/bin/ruby
require_relative "common"
require "openssl"
require "base64"
log("curl", ARGV)
abort "curl must read its config from stdin" unless ARGV == ["--config", "-"]
config = {"header" => []}
STDIN.read.each_line do |line|
  line = line.chomp
  next if line.empty?
  key, raw = line.split(" = ", 2)
  value = raw && raw.start_with?("\"") ? raw[1...-1].gsub(/\\(.)/) { $1 == "n" ? "\n" : $1 } : raw
  key == "header" ? config["header"] << value : config[key] = value || true
end
url = config.fetch("url")
method = config.fetch("request", "GET")
s = state
respond = lambda do |code, body|
  print body.nil? ? "" : JSON.generate(body)
  print "\n#{code}"
  exit 0
end
if url.start_with?("https://api.github.com/")
  token = config["header"].find { |header| header.start_with?("Authorization: Bearer ") }.to_s.delete_prefix("Authorization: Bearer ")
  header, payload, signature = token.split(".")
  public_key = OpenSSL::PKey.read(File.read(ENV.fetch("FAKE_PUBLIC_KEY")))
  decode = ->(part) { Base64.urlsafe_decode64(part + "=" * ((4 - part.length % 4) % 4)) }
  valid = signature && public_key.verify(OpenSSL::Digest::SHA256.new, decode.call(signature), "#{header}.#{payload}") &&
    JSON.parse(decode.call(payload))["iss"] == s["appId"]
  respond.call(401, {"message" => "Bad credentials"}) unless valid
  path = url.delete_prefix("https://api.github.com/")
  File.open(File.join(ENV.fetch("FAKE_STATE"), "requests.log"), "a") { |file| file.puts("#{method} #{path}") }
  permissions = s["appPermissions"]
  case path
  when "app"
    respond.call(200, {"id" => s["appId"].to_i, "permissions" => permissions, "events" => []})
  when "app/installations/#{s["installationId"]}"
    respond.call(200, {"id" => s["installationId"].to_i, "account" => {"login" => s["ghLogin"]},
                       "repository_selection" => "selected", "permissions" => permissions, "suspended_at" => nil})
  when %r{\Arepos/(.+)/installation\z}
    installed = s["repos"].key?($1) && s["installedRepositories"].include?($1)
    respond.call(installed ? 200 : 404, installed ? {"id" => s["installationId"].to_i} : {"message" => "Not Found"})
  else
    respond.call(404, {"message" => "Not Found"})
  end
end
match = url.match(%r{\Ahttps://([a-z0-9-]+)\.example-sub\.workers\.dev/v1/feedback\z}) or abort "unexpected URL #{url}"
worker = s["workers"][match[1]] or respond.call(404, nil)
abort "not a POST" unless method == "POST"
submission = JSON.parse(config.fetch("data-raw"))
abort "unexpected fields" unless submission.keys.sort == %w[appVersion body build category deviceModel locale osVersion]
repository = s["repos"].fetch(worker.fetch("repository"))
repository["issues"] << {"number" => repository["issues"].length + 1, "body" => "## Feedback\n\n#{submission["body"]}",
                         "labels" => [{"name" => "feedback"}, {"name" => submission["category"]}]}
save(s)
event("delivered")
respond.call(201, {"status" => "created"})
RUBY
chmod 755 "$fakes/gh" "$fakes/wrangler" "$fakes/security" "$fakes/curl"

# --- The sample app and the shared GitHub App key ----------------------------------------------

private_key="$work/github-app.pem"
ruby -ropenssl -e 'key = OpenSSL::PKey::RSA.new(2048); File.write(ARGV[0], key.to_pem); File.write(ARGV[1], key.public_key.to_pem)' \
  "$private_key" "$work/github-app.pub"
pem_line=$(sed -n 2p "$private_key")
pkcs8_line=$(ruby -ropenssl -rbase64 -e '
  key = OpenSSL::PKey.read(File.read(ARGV[0]))
  algorithm = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::ObjectId("rsaEncryption"), OpenSSL::ASN1::Null(nil)])
  der = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::Integer(0), algorithm, OpenSSL::ASN1::OctetString(key.to_der)]).to_der
  puts Base64.strict_encode64(der)[0, 64]' "$private_key")

# make_app DIRECTORY: a bootstrapped sample app with the template's feedback pieces.
make_app() {
  local app=$1
  mkdir -p "$app/tools/lib" "$app/Config" "$app/GardenNotes/Features/Feedback" "$app/.agents/skills"
  cp "$repo_root/tools/provision-app-feedback.sh" "$app/tools/"
  cp "$repo_root/tools/lib/app-feedback-provision.rb" "$repo_root/tools/lib/ownership.rb" \
    "$repo_root/tools/lib/bounded-command.rb" "$app/tools/lib/"
  cp -R "$repo_root/.agents/skills/app-feedback" "$app/.agents/skills/"
  printf '%s' '{"appSlug":"garden-notes","bundleId":"com.example.GardenNotes","displayName":"Garden Notes","moduleName":"GardenNotes","schemaVersion":1,"sourceIdentityVersion":1}' \
    > "$app/Config/app-identity.json"
  ruby -e '
    text = File.read(ARGV[0])
    text.sub!(/^  login: .*$/, "  login: example-owner") or abort
    text.sub!(/^  accountId: [0-9a-f]{32}$/, "  accountId: #{ARGV[2]}") or abort
    text.sub!(/^(cloudflare:\n(?:  .*\n)*?)  target: null$/) { "#{$1}  target: garden-notes-feedback" } or abort
    File.write(ARGV[1], text)
  ' "$repo_root/Config/ownership.yml" "$app/Config/ownership.yml" "$ACCOUNT"
  printf '{\n  "host": ""\n}\n' > "$app/GardenNotes/Features/Feedback/FeedbackEndpoint.json"
}

home="$work/home"
secrets_dir="$home/Library/Application Support/iOS-Template/secrets"
mkdir -p "$secrets_dir/github-example-owner"
chmod 700 "$secrets_dir" "$secrets_dir/github-example-owner"
cp "$private_key" "$secrets_dir/github-example-owner/feedback-github-app.pem"
chmod 600 "$secrets_dir/github-example-owner/feedback-github-app.pem"

# reset_state DIRECTORY: a fresh fake GitHub and Cloudflare.
reset_state() {
  local state=$1
  rm -rf -- "$state"
  mkdir -p "$state"
  ruby -rjson -e '
    namespace = "github-example-owner"
    service = "ios-template/#{namespace}/feedback-github-app/production"
    File.write(File.join(ARGV[0], "state.json"), JSON.pretty_generate({
      "ghLogin" => "example-owner", "wranglerAccount" => ARGV[1], "expectedAccount" => ARGV[1],
      "appId" => ARGV[2], "installationId" => ARGV[3],
      "appPermissions" => {"issues" => "write", "metadata" => "read"},
      "keychain" => {"#{namespace} #{service}/app-id" => ARGV[2], "#{namespace} #{service}/installation-id" => ARGV[3]},
      "repos" => {}, "installedRepositories" => [], "workers" => {}, "deployFails" => false
    }))
  ' "$state" "$ACCOUNT" "$APP_ID" "$INSTALLATION_ID"
  : > "$state/calls.log"
  : > "$state/events.log"
}

# set_state DIRECTORY RUBY: changes the fake state with a Ruby expression on `s`.
set_state() {
  ruby -rjson -e 'path = File.join(ARGV[0], "state.json"); s = JSON.parse(File.read(path)); eval(ARGV[1]); File.write(path, JSON.pretty_generate(s))' "$1" "$2"
}

# provision APP STATE ARGS...: runs the tool; output in $work/out and $work/err, status in $status.
provision() {
  local app=$1 state=$2
  shift 2
  set +e
  env HOME="$home" IOS_TEMPLATE_TEST_MODE=1 FAKE_STATE="$state" FAKE_PUBLIC_KEY="$work/github-app.pub" \
    IOS_TEMPLATE_TEST_GH_BIN="$fakes/gh" IOS_TEMPLATE_TEST_WRANGLER_BIN="$fakes/wrangler" \
    IOS_TEMPLATE_TEST_SECURITY_BIN="$fakes/security" IOS_TEMPLATE_TEST_CURL_BIN="$fakes/curl" \
    IOS_TEMPLATE_TEST_NODE_BIN="$(ruby -e 'puts File.realpath(ARGV[0])' "$(type -P node)")" \
    "$app/tools/provision-app-feedback.sh" "$@" > "$work/out" 2> "$work/err"
  status=$?
  set -e
  cat "$work/out" "$work/err" >> "$work/all-output"
}

expect_refused() {
  local label=$1 pattern=$2
  [[ $status == 1 ]] || fail "$label: expected a refusal, got status $status: $(cat "$work/err")"
  grep -Fq -- "$pattern" "$work/err" || fail "$label: expected '$pattern' in: $(cat "$work/err")"
}

no_changes() {
  local label=$1 state=$2
  [[ ! -s "$state/events.log" ]] || fail "$label: something was created: $(cat "$state/events.log")"
}

plan_digest() {
  ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("planDigest")' "$work/out"
}

count() {
  grep -c -x -- "$2" "$1/events.log" || true
}

# --- Refusals before anything is created --------------------------------------------------------

app="$work/app"
state="$work/state"
make_app "$app"
reset_state "$state"

provision "$app" "$state" bogus
[[ $status == 2 ]] || fail "an unknown command must be a usage error"

mv "$app/Config/app-identity.json" "$work/identity.json"
provision "$app" "$state" plan
expect_refused 'identity missing' 'Identity bootstrap has not been applied'
mv "$work/identity.json" "$app/Config/app-identity.json"

cp "$app/Config/ownership.yml" "$work/ownership.yml"
ruby -e 'p = ARGV[0]; t = File.read(p); t.sub!("  target: garden-notes-feedback", "  target: null") or abort; File.write(p, t)' "$app/Config/ownership.yml"
provision "$app" "$state" plan
expect_refused 'target unset' 'ownership.cloudflare.target is not configured'
ruby -e 'p = ARGV[0]; t = File.read(p); t.sub!("  target: null", "  target: other-feedback") or abort; File.write(p, t)' "$app/Config/ownership.yml"
provision "$app" "$state" plan
expect_refused 'target differs' 'ownership.cloudflare.target must be the Worker name garden-notes-feedback'
cp "$work/ownership.yml" "$app/Config/ownership.yml"

set_state "$state" 's["ghLogin"] = "someone-else"'
provision "$app" "$state" plan
expect_refused 'GitHub account differs' 'the active GitHub account does not match the configured login example-owner'
set_state "$state" 's["ghLogin"] = "example-owner"'

set_state "$state" 's["wranglerAccount"] = "ffffffffffffffffffffffffffffffff"'
provision "$app" "$state" plan
expect_refused 'Cloudflare account differs' 'the wrangler session cannot use the configured Cloudflare account'
set_state "$state" "s[\"wranglerAccount\"] = \"$ACCOUNT\""

set_state "$state" 's["keychain"].delete_if { |key, _| key.end_with?("/installation-id") }'
provision "$app" "$state" plan
expect_refused 'installation ID missing' 'the shared GitHub App installation-id is not in the Keychain'
reset_state "$state"

chmod 644 "$secrets_dir/github-example-owner/feedback-github-app.pem"
provision "$app" "$state" plan
expect_refused 'signing key mode' 'the signing key must have mode 600'
chmod 600 "$secrets_dir/github-example-owner/feedback-github-app.pem"

set_state "$state" 's["appPermissions"] = {"issues" => "write", "metadata" => "read", "contents" => "read"}'
provision "$app" "$state" plan
expect_refused 'App permissions' 'the shared GitHub App must have only Issues: Read and write'
set_state "$state" 's["appPermissions"] = {"issues" => "write", "metadata" => "read"}'

set_state "$state" "s[\"appId\"] = \"99999\""
provision "$app" "$state" plan
expect_refused 'another App' 'the shared GitHub App could not authenticate (HTTP 401)'
reset_state "$state"
no_changes 'refusals' "$state"
[[ ! -e "$app/Services" && ! -e "$app/Config/app-feedback.json" ]] || fail 'a refusal wrote files'

# --- Plan, approval and the stop until the App is installed -------------------------------------

provision "$app" "$state" plan
[[ $status == 0 ]] || fail "plan failed: $(cat "$work/err")"
digest=$(plan_digest)
ruby -rjson -e '
  value = JSON.parse(File.read(ARGV[0]))
  plan = value.fetch("plan")
  abort "plan values differ: #{plan}" unless plan["repository"] == "example-owner/GardenNotes-feedback" &&
    plan["workerName"] == "garden-notes-feedback" && plan["visibility"] == "private" &&
    plan["labels"] == %w[feedback bug request other] && plan["rateLimitNamespaceId"].match?(/\A[1-9][0-9]{0,8}\z/)
  abort "plan state differs: #{value["current"]}" unless value["current"]["repository"] == "to-create" &&
    value["current"]["installedOnRepository"] == false
' "$work/out"
no_changes 'plan' "$state"

provision "$app" "$state" apply --plan-digest "sha256:$(printf '0%.0s' {1..64})"
expect_refused 'digest differs' 'the plan differs from the approved plan digest'
no_changes 'digest differs' "$state"

provision "$app" "$state" apply --plan-digest "$digest"
[[ $status == 3 ]] || fail "apply must wait for the installation, got $status: $(cat "$work/err")"
grep -Fq 'install the shared GitHub App on example-owner/GardenNotes-feedback' "$work/err" || fail 'installation steps are missing'
[[ "$(count "$state" 'repo-create example-owner/GardenNotes-feedback')" == 1 ]] || fail 'the repository was not created once'
for label in feedback request other; do
  [[ "$(count "$state" "label-create $label")" == 1 ]] || fail "label $label was not created once"
done
[[ "$(count "$state" 'label-create bug')" == 0 ]] || fail 'the existing bug label was created again'
! grep -q '^deploy\|^secret-put' "$state/events.log" || fail 'the Worker was deployed before the installation'
grep -Fxq '  "host": ""' "$app/GardenNotes/Features/Feedback/FeedbackEndpoint.json" || fail 'the host was set before the installation'
[[ ! -e "$app/Config/app-feedback.json" ]] || fail 'the record was written before the installation'
[[ -f "$app/Services/feedback-worker/wrangler.jsonc" ]] || fail 'the Worker was not written'
grep -Fq '"name": "garden-notes-feedback"' "$app/Services/feedback-worker/wrangler.jsonc" || fail 'the Worker name was not written'
! grep -q '{{' "$app/Services/feedback-worker/wrangler.jsonc" || fail 'a placeholder remains in the Worker'

# --- Installed: deploy, secrets, host and record; a rerun creates nothing ------------------------

set_state "$state" 's["installedRepositories"] << "example-owner/GardenNotes-feedback"'
provision "$app" "$state" apply --plan-digest "$digest"
[[ $status == 0 ]] || fail "apply failed after the installation: $(cat "$work/err")"
[[ "$(count "$state" 'repo-create example-owner/GardenNotes-feedback')" == 1 ]] || fail 'the repository was created twice'
[[ "$(count "$state" 'deploy garden-notes-feedback')" == 1 ]] || fail 'the Worker was not deployed once'
for secret in GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_SIGNING_PKCS8; do
  [[ "$(count "$state" "secret-put $secret")" == 1 ]] || fail "secret $secret was not registered once"
done
ruby -rjson -rdigest -e '
  worker = JSON.parse(File.read(ARGV[0]))["workers"].fetch("garden-notes-feedback")
  secrets = worker.fetch("secrets")
  abort "secret values differ" unless secrets["GITHUB_APP_ID"] == Digest::SHA256.hexdigest(ARGV[1]) &&
    secrets["GITHUB_APP_INSTALLATION_ID"] == Digest::SHA256.hexdigest(ARGV[2]) && secrets["GITHUB_APP_SIGNING_PKCS8"] == "pkcs8-ok"
  abort "the deployed Worker differs" unless worker["repository"] == "example-owner/GardenNotes-feedback"
' "$state/state.json" "$APP_ID" "$INSTALLATION_ID"
grep -Fxq '  "host": "garden-notes-feedback.example-sub.workers.dev"' "$app/GardenNotes/Features/Feedback/FeedbackEndpoint.json" ||
  fail 'the host was not set'
ruby -rjson -e '
  record = JSON.parse(File.read(ARGV[0]))
  abort "record differs: #{record}" unless record.keys.sort == %w[cloudflareAccountId host labels planDigest rateLimitNamespaceId repository schemaVersion workerName] &&
    record["host"] == "garden-notes-feedback.example-sub.workers.dev" && record["planDigest"] == ARGV[1]
' "$app/Config/app-feedback.json" "$digest"

# A rerun deploys the same Worker again to read its host from Cloudflare, and creates nothing else.
grep -v '^deploy ' "$state/events.log" > "$work/events-before-rerun"
provision "$app" "$state" apply --plan-digest "$digest"
[[ $status == 0 ]] || fail "the rerun failed: $(cat "$work/err")"
grep -v '^deploy ' "$state/events.log" | cmp -s - "$work/events-before-rerun" ||
  fail "the rerun created something: $(grep -v '^deploy ' "$state/events.log" | diff "$work/events-before-rerun" -)"
[[ "$(count "$state" 'deploy garden-notes-feedback')" == 2 ]] || fail 'the rerun did not read the host from a deploy'

provision "$app" "$state" check-delivery
[[ $status == 2 ]] || fail 'check-delivery without the approved digest must be a usage error'
provision "$app" "$state" check-delivery --plan-digest "$digest"
[[ $status == 0 ]] || fail "check-delivery failed: $(cat "$work/err")"
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); abort "delivery differs: #{value}" unless value["status"] == "delivered" && value["issue"] == 1' "$work/out"

# A host changed in the repository's files is refused, even when the record and the app agree, and
# nothing is sent to it.
cp "$app/Config/app-feedback.json" "$work/record.json"
ruby -rjson -e '
  record = JSON.parse(File.read(ARGV[0])); record["host"] = "garden-notes-feedback.elsewhere.workers.dev"
  File.write(ARGV[0], JSON.pretty_generate(record) + "\n")' "$app/Config/app-feedback.json"
printf '{\n  "host": "garden-notes-feedback.elsewhere.workers.dev"\n}\n' > "$app/GardenNotes/Features/Feedback/FeedbackEndpoint.json"
provision "$app" "$state" apply --plan-digest "$digest"
expect_refused 'changed host' "Config/app-feedback.json names garden-notes-feedback.elsewhere.workers.dev, not the deployed Worker's host"
provision "$app" "$state" check-delivery --plan-digest "$digest"
expect_refused 'changed host before delivery' "not the deployed Worker's host"
[[ "$(count "$state" delivered)" == 1 ]] || fail 'a submission was sent to a changed host'
grep -Fxq '  "host": "garden-notes-feedback.elsewhere.workers.dev"' "$app/GardenNotes/Features/Feedback/FeedbackEndpoint.json" ||
  fail 'a refusal overwrote the app host'
cp "$work/record.json" "$app/Config/app-feedback.json"
printf '{\n  "host": "garden-notes-feedback.example-sub.workers.dev"\n}\n' > "$app/GardenNotes/Features/Feedback/FeedbackEndpoint.json"

# Finder's .DS_Store is not part of the Worker; a Worker changed by hand is not overwritten.
: > "$app/Services/feedback-worker/.DS_Store"
provision "$app" "$state" plan
[[ $status == 0 ]] || fail "a .DS_Store file changed the Worker: $(cat "$work/err")"
printf '\n' >> "$app/Services/feedback-worker/src/index.ts"
provision "$app" "$state" plan
expect_refused 'Worker changed' 'Services/feedback-worker already exists and differs from the planned Worker'

# --- A failed deploy stops before the host; the next run finishes --------------------------------

app2="$work/app2"
state2="$work/state2"
make_app "$app2"
reset_state "$state2"
set_state "$state2" 's["deployFails"] = true; s["repos"]["example-owner/GardenNotes-feedback"] = {"labels" => %w[bug], "issues" => []}; s["installedRepositories"] << "example-owner/GardenNotes-feedback"'
provision "$app2" "$state2" plan
[[ $status == 0 ]] || fail "plan failed for the second app: $(cat "$work/err")"
digest2=$(plan_digest)
[[ "$digest2" == "$digest" ]] || fail 'the same app values must give the same plan digest'
provision "$app2" "$state2" apply --plan-digest "$digest2"
expect_refused 'deploy failure' 'the Worker deploy failed'
[[ "$(count "$state2" 'repo-create example-owner/GardenNotes-feedback')" == 0 ]] || fail 'an existing repository was created again'
! grep -q '^secret-put' "$state2/events.log" || fail 'secrets were registered after a failed deploy'
grep -Fxq '  "host": ""' "$app2/GardenNotes/Features/Feedback/FeedbackEndpoint.json" || fail 'the host was set after a failed deploy'
[[ ! -e "$app2/Config/app-feedback.json" ]] || fail 'the record was written after a failed deploy'
set_state "$state2" 's["deployFails"] = false'
provision "$app2" "$state2" apply --plan-digest "$digest2"
[[ $status == 0 ]] || fail "apply failed after the deploy was fixed: $(cat "$work/err")"
grep -Fxq '  "host": "garden-notes-feedback.example-sub.workers.dev"' "$app2/GardenNotes/Features/Feedback/FeedbackEndpoint.json" ||
  fail 'the host was not set after the deploy was fixed'

# A public repository with the planned name is refused.
reset_state "$state2"
set_state "$state2" 's["repos"]["example-owner/GardenNotes-feedback"] = {"labels" => [], "issues" => [], "private" => false}'
rm -f "$app2/Config/app-feedback.json"
printf '{\n  "host": ""\n}\n' > "$app2/GardenNotes/Features/Feedback/FeedbackEndpoint.json"
provision "$app2" "$state2" apply --plan-digest "$digest2"
expect_refused 'public repository' 'exists but is not private'

# --- Production mode and secrets -----------------------------------------------------------------

set +e
env IOS_TEMPLATE_TEST_GH_BIN="$fakes/gh" HOME="$home" "$app/tools/provision-app-feedback.sh" plan > "$work/out" 2> "$work/err"
status=$?
set -e
expect_refused 'production overrides' 'test overrides are not allowed in production mode'

# No secret value in what the tool printed, in any child's argv, or in the app's files.
for secret in "$APP_ID" "$INSTALLATION_ID" "$pem_line" "$pkcs8_line"; do
  ! grep -rqF -- "$secret" "$work/all-output" "$state/calls.log" "$state2/calls.log" "$app" "$app2" ||
    fail 'a secret value appeared in the output, a command line, or the app'
done
! grep -qF 'person@example.invalid' "$work/all-output" || fail 'the Cloudflare account email was printed'

echo "app feedback provisioning tests passed"
