#!/usr/bin/env bash
set -euo pipefail

# Creates only the repository's declared dedicated Simulators that do not exist yet (D-063). It never deletes,
# renames, clones, boots, or erases a device, and it stops before creating anything when a declared name is
# ambiguous or already used by a device of another Device Type or Runtime.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$repo_root/tools/lib/bounded-command.sh"

usage() {
  echo "usage: setup-dedicated-simulators.sh [--config <path>]" >&2
  exit 2
}

config="$repo_root/Config/dedicated-simulators.json"
if [[ $# -gt 0 ]]; then
  [[ $# -eq 2 && $1 == --config ]] || usage
  config="$2"
fi
[[ -f "$config" && ! -L "$config" ]] || {
  echo "blocked:environment: dedicated Simulator declaration is missing or unsafe: $config" >&2
  exit 1
}

temporary="$(mktemp -d "${TMPDIR:-/tmp}/ios-template-dedicated-setup.XXXXXX")"
trap 'rm -rf -- "$temporary"' EXIT

simctl() {
  local label="$1"
  shift
  bounded_run "dedicated-setup-$label" "${IOS_TEMPLATE_SIMCTL_TIMEOUT_SECONDS:-180}" xcrun simctl "$@"
}

list_state() {
  simctl list-devices list devices -j >"$temporary/devices.json"
}

simctl list-runtimes list runtimes -j >"$temporary/runtimes.json"
simctl list-devicetypes list devicetypes -j >"$temporary/devicetypes.json"
list_state

# Prints one "<action>\t<name>\t<device type>\t<runtime>" line per declared device, or stops before any change.
plan() {
  ruby -rjson - "$config" "$temporary/devices.json" "$temporary/runtimes.json" "$temporary/devicetypes.json" <<'RUBY'
def blocked(message)
  warn "blocked:environment: #{message}"
  exit 1
end

config_path, devices_path, runtimes_path, types_path = ARGV
begin
  config = JSON.parse(File.binread(config_path))
  devices = JSON.parse(File.binread(devices_path)).fetch("devices")
  runtimes = JSON.parse(File.binread(runtimes_path)).fetch("runtimes")
  types = JSON.parse(File.binread(types_path)).fetch("devicetypes")
rescue JSON::ParserError, KeyError, TypeError
  blocked("Simulator declaration or simctl output is invalid")
end
blocked("Simulator declaration schema differs") unless config.is_a?(Hash) && config.keys.sort == %w[devices schemaVersion] &&
  config["schemaVersion"] == 1 && config["devices"].is_a?(Array) && config["devices"].length == 2
declared = config["devices"].map do |device|
  keys = %w[deviceTypeIdentifier family name runtimeIdentifier]
  blocked("Simulator declaration entry differs") unless device.is_a?(Hash) && device.keys.sort == keys &&
    device.values.all? { |value| value.is_a?(String) && !value.empty? }
  blocked("Simulator declaration name is invalid") unless device["name"].match?(/\A[^\x00-\x1f\x7f]{1,96}\z/) &&
    !device["name"].start_with?("iOS-Template-")
  device
end
blocked("Simulator declaration must name one iphone and one ipad") unless declared.map { |device| device["family"] }.sort == %w[ipad iphone]
blocked("Simulator declaration names must differ") unless declared.map { |device| device["name"] }.uniq.length == 2
blocked("simctl device list is invalid") unless devices.is_a?(Hash) && devices.values.all?(Array)

declared.sort_by { |device| device["family"] == "iphone" ? 0 : 1 }.each do |device|
  name = device.fetch("name")
  type = device.fetch("deviceTypeIdentifier")
  runtime = device.fetch("runtimeIdentifier")
  matches = devices.flat_map do |runtime_key, entries|
    entries.select { |entry| entry.is_a?(Hash) && entry["name"] == name }.map { |entry| entry.merge("runtime" => runtime_key) }
  end
  if matches.length > 1
    blocked("dedicated Simulator '#{name}' exists #{matches.length} times; keep exactly one and remove the others manually")
  elsif matches.length == 1
    match = matches.first
    unless match["deviceTypeIdentifier"] == type && match["runtime"] == runtime && match["isAvailable"] == true
      blocked("a Simulator named '#{name}' does not match the declared Device Type and Runtime or is unavailable; fix it manually")
    end
    puts ["present", name, type, runtime].join("\t")
  else
    blocked("declared Runtime #{runtime} is not installed and available") unless runtimes.any? { |entry|
      entry.is_a?(Hash) && entry["identifier"] == runtime && entry["isAvailable"] == true
    }
    blocked("declared Device Type #{type} is not available") unless types.any? { |entry|
      entry.is_a?(Hash) && entry["identifier"] == type
    }
    puts ["create", name, type, runtime].join("\t")
  end
end
RUBY
}

plan >"$temporary/plan.tsv"
while IFS=$'\t' read -r action name type runtime; do
  [[ "$action" == create ]] || continue
  simctl create create "$name" "$type" "$runtime" >/dev/null
done <"$temporary/plan.tsv"

# Re-read the live state: every declared device must now be present exactly once with its declared identity.
list_state
plan >"$temporary/final.tsv"
ruby -rjson - "$temporary/plan.tsv" "$temporary/final.tsv" "$temporary/devices.json" <<'RUBY'
initial, final, devices_path = ARGV
planned = File.readlines(initial, chomp: true).map { |line| line.split("\t") }
current = File.readlines(final, chomp: true).map { |line| line.split("\t") }
abort "blocked:environment: a dedicated Simulator is still missing after setup" unless current.all? { |row| row.first == "present" } &&
  current.map { |row| row[1] } == planned.map { |row| row[1] }
devices = JSON.parse(File.binread(devices_path)).fetch("devices").values.flatten
rows = planned.map do |action, name|
  udid = devices.find { |entry| entry["name"] == name }.fetch("udid")
  {"name" => name, "status" => action == "create" ? "created" : "present", "udid" => udid}
end
puts JSON.generate({"devices" => rows, "status" => "ready"})
RUBY
