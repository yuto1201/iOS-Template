#!/bin/bash -p
set -euo pipefail

# D-086 (#379): builds the template app for one of the repository's dedicated Simulators, or builds it for
# the user's development iPhone and installs it there. Template repository only.
#
#   iphone-simulator, ipad-simulator: finds the dedicated device of Config/dedicated-simulators.json by its
#     exact name, Device Type and Runtime (exactly one, read-only `simctl list`), then runs only
#     `xcodebuild build -destination id=<UDID>`. The build action never boots the Simulator, and this tool
#     never boots, installs to, launches or erases it (a Simulator booted outside a lease accumulates data,
#     D-084, #380).
#   device: finds the physical device that Config/development-device.json names (read-only
#     `devicectl list devices`), requires exactly one match that is paired and reachable, builds with the
#     project's automatic signing and Team, and installs the app with `devicectl device install app`. It never
#     launches, tests or erases, never passes -allowProvisioningUpdates and never overrides signing settings;
#     missing signing stops with guidance for the user.
#
# Builds go through tools/xcodebuild-in-worktree.sh, so they reuse the worktree's fixed DerivedData (D-084).
# Every xcodebuild, simctl and devicectl call is bounded. Device identifiers are looked up at run time,
# never printed and never written into the repository.

usage() {
  echo 'usage: build-for-device.sh iphone-simulator|ipad-simulator|device' >&2
  exit 2
}
fail() { echo "build-for-device: $*" >&2; exit 2; }

[[ $# -eq 1 ]] || usage
target=$1
case "$target" in
  iphone-simulator) family=iphone ;;
  ipad-simulator) family=ipad ;;
  device) family="" ;;
  *) usage ;;
esac

script_dir="${BASH_SOURCE[0]%/*}"
script_dir="$(builtin cd "$script_dir" && /bin/pwd -P)"
repository_root="$(builtin cd "$script_dir/.." && /bin/pwd -P)"
top_level="$(/usr/bin/git -C "$repository_root" rev-parse --show-toplevel 2>/dev/null)" || fail 'run it inside a Git worktree'
[[ "$(builtin cd "$top_level" && /bin/pwd -P)" == "$repository_root" ]] || fail 'the tool must sit in tools/ of its worktree'
project_name=TemplateApp
project="$repository_root/$project_name.xcodeproj"
[[ -d "$project" && ! -L "$project" ]] || fail "this tool works only in the template repository, which has $project_name.xcodeproj (D-086)"
builtin cd "$repository_root"

source "$script_dir/lib/xcode.sh"
initialize_trusted_environment || fail 'the user environment could not be verified'
if [[ "${IOS_TEMPLATE_TEST_MODE:-}" == 1 ]]; then
  xcrun_path="${IOS_TEMPLATE_TEST_XCRUN:?}"
  derived_data_root="${IOS_TEMPLATE_TEST_DERIVED_DATA_ROOT:?}"
  [[ -f "$xcrun_path" && -x "$xcrun_path" ]] || fail 'the test xcrun is not executable'
  XCODE_DEVELOPER_DIR=''
else
  xcrun_path="$TRUSTED_XCRUN"
  derived_data_root="${TRUSTED_BASE_ENV[0]#HOME=}/Library/Caches/ios-template/derived-data"
  resolve_xcode_environment || fail 'Xcode is not available'
fi

work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ios-template-build-for-device.XXXXXX")"
trap '/bin/rm -rf -- "$work"' EXIT

# One bounded xcrun call; a timeout or an unreclaimed process group is reported with its stage.
bounded_xcrun() {
  local stage_name=$1 timeout_seconds=$2 command_status=0
  shift 2
  run_bounded_xcode_tool "$stage_name" "$timeout_seconds" "$xcrun_path" "$@" || command_status=$?
  [[ -z "${IOS_TEMPLATE_LAST_TIMEOUT_MESSAGE:-}" ]] || echo "build-for-device: $IOS_TEMPLATE_LAST_TIMEOUT_MESSAGE" >&2
  return "$command_status"
}

# xcode.sh exports only the readiness flag, not the trusted environment array, so the child must build its own.
xcodebuild_in_worktree() {
  /usr/bin/env -u TRUSTED_ENVIRONMENT_READY "$script_dir/xcodebuild-in-worktree.sh" -project "$project" -scheme "$project_name" -configuration Debug "$@"
}

if [[ -n "$family" ]]; then
  bounded_xcrun simctl-list 60 simctl list devices -j > "$work/simulators.json" || fail 'could not list the Simulators'
  # Prints the UDID on the first line and the name on the second; the UDID stays in this process.
  resolved="$(/usr/bin/ruby --disable-gems -rjson -e '
    config_path, family, listing_path = ARGV
    def stop(message)
      warn "build-for-device: #{message}"
      exit 2
    end
    config = JSON.parse(File.read(config_path, encoding: "UTF-8")) rescue stop("Config/dedicated-simulators.json is not valid JSON")
    stop("Config/dedicated-simulators.json has an unknown schema") unless config.is_a?(Hash) && config["schemaVersion"] == 1 && config["devices"].is_a?(Array)
    declared = config["devices"].select { |device| device.is_a?(Hash) && device["family"] == family }
    stop("Config/dedicated-simulators.json must declare exactly one #{family} device") unless declared.length == 1
    declared = declared.first
    name, type, runtime = declared.values_at("name", "deviceTypeIdentifier", "runtimeIdentifier")
    stop("the #{family} declaration is incomplete") unless [name, type, runtime].all? { |value| value.is_a?(String) && !value.empty? }
    listing = JSON.parse(File.read(listing_path, encoding: "UTF-8")) rescue stop("the Simulator list is not valid JSON")
    devices = listing.is_a?(Hash) && listing["devices"].is_a?(Hash) ? listing["devices"] : stop("the Simulator list has no devices")
    entries = devices[runtime].is_a?(Array) ? devices[runtime] : []
    matches = entries.select do |device|
      device.is_a?(Hash) && device["name"] == name && device["deviceTypeIdentifier"] == type && device["isAvailable"] != false
    end
    unless matches.length == 1
      stop("blocked:environment: #{matches.length} available Simulators match #{name} (#{type}, #{runtime}); exactly one is required. " \
           "Create it only through tools/setup-dedicated-simulators.sh (D-063)")
    end
    udid = matches.first["udid"].to_s
    stop("the dedicated Simulator has an invalid UDID") unless udid.match?(/\A[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\z/i)
    puts udid, name
  ' "$repository_root/Config/dedicated-simulators.json" "$family" "$work/simulators.json")" || exit 2
  udid="${resolved%%$'\n'*}"
  device_name="${resolved#*$'\n'}"
  # `build` compiles for the device's platform and architecture only; it does not boot or install.
  xcodebuild_in_worktree -destination "id=$udid" build || fail "the build for $device_name failed"
  echo "build-for-device: built $project_name for $device_name; the Simulator was not booted and nothing was installed"
  exit 0
fi

declared_name="$(/usr/bin/ruby --disable-gems -rjson -e '
  config = JSON.parse(File.read(ARGV.fetch(0), encoding: "UTF-8")) rescue abort("build-for-device: Config/development-device.json is not valid JSON")
  # Only the name is declared; a device identifier must never be committed (D-086).
  unless config.is_a?(Hash) && config.keys.sort == %w[name schemaVersion] && config["schemaVersion"] == 1 &&
         config["name"].is_a?(String) && config["name"].match?(/\A[^[:cntrl:]]{1,64}\z/) && config["name"].strip == config["name"]
    abort "build-for-device: Config/development-device.json must hold exactly schemaVersion 1 and a device name"
  end
  puts config["name"]
' "$repository_root/Config/development-device.json")" || exit 2

bounded_xcrun devicectl-list 120 devicectl list devices --json-output "$work/devices.json" >/dev/null ||
  fail 'could not list the devices with devicectl'
udid="$(/usr/bin/ruby --disable-gems -rjson -e '
  listing_path, name = ARGV
  name = name.dup.force_encoding("UTF-8")
  def stop(message)
    warn "build-for-device: #{message}"
    exit 2
  end
  listing = JSON.parse(File.read(listing_path, encoding: "UTF-8")) rescue stop("the device list is not valid JSON")
  devices = listing.dig("result", "devices") if listing.is_a?(Hash) && listing["result"].is_a?(Hash)
  stop("the device list has no devices") unless devices.is_a?(Array)
  # The `properties` dictionary replaces the deprecated hardwareProperties, deviceProperties and
  # connectionProperties; either form is read.
  field = lambda do |device, current, deprecated|
    value = device.dig("properties", *current) if device["properties"].is_a?(Hash)
    value.nil? && deprecated ? device.dig(*deprecated) : value
  end
  physical = devices.select do |device|
    device.is_a?(Hash) && field.call(device, %w[hardware reality], %w[hardwareProperties reality]) == "physical"
  end
  matches = physical.select { |device| field.call(device, %w[state name], %w[deviceProperties name]) == name }
  stop("no physical device named #{name} is known to this Mac; pair it in Xcode first") if matches.empty?
  stop("#{matches.length} physical devices are named #{name}; give the development device a unique name") if matches.length > 1
  device = matches.first
  pairing = field.call(device, %w[connection pairingState], %w[connectionProperties pairingState])
  state = field.call(device, %w[connection state], %w[connectionProperties tunnelState])
  transport = field.call(device, %w[connection transportType], %w[connectionProperties transportType])
  # "disconnected" is a reachable device whose tunnel is not open yet; "unavailable" means it cannot be reached.
  unless pairing == "paired" && %w[connected disconnected].include?(state) && transport.is_a?(String) && !transport.empty?
    stop("#{name} is not connected; connect and unlock it (USB or the same network), then try again")
  end
  developer_mode = field.call(device, %w[state developerModeStatus], %w[deviceProperties developerModeStatus])
  enabled = developer_mode.is_a?(Hash) ? developer_mode.key?("enabled") : developer_mode == "enabled"
  stop("Developer Mode is off on #{name}; turn it on in Settings on the device") unless developer_mode.nil? || enabled
  udid = field.call(device, %w[hardware udid], %w[hardwareProperties udid]).to_s
  stop("#{name} has no usable device identifier") unless udid.match?(/\A[0-9A-Fa-f][0-9A-Fa-f-]{7,63}\z/)
  puts udid
' "$work/devices.json" "$declared_name")" || exit 2

# The project's automatic signing and Team are used as they are; nothing on the command line changes them.
xcodebuild_in_worktree -destination generic/platform=iOS -showBuildSettings -json > "$work/settings.json" ||
  fail 'could not read the build settings'
app_path="$(/usr/bin/ruby --disable-gems -rjson -e '
  settings_path, target, derived_data_root = ARGV
  def stop(message)
    warn "build-for-device: #{message}"
    exit 2
  end
  entries = JSON.parse(File.read(settings_path, encoding: "UTF-8")) rescue stop("the build settings are not valid JSON")
  entry = entries.find { |item| item.is_a?(Hash) && item["target"] == target } if entries.is_a?(Array)
  settings = entry && entry["buildSettings"]
  stop("the build settings have no #{target} target") unless settings.is_a?(Hash)
  unless settings["CODE_SIGN_STYLE"] == "Automatic" && settings["DEVELOPMENT_TEAM"].to_s.match?(/\A[A-Z0-9]{10}\z/)
    stop("#{target} must use automatic signing with a Team set in the project; set it in Xcode (D-086)")
  end
  directory, product = settings.values_at("TARGET_BUILD_DIR", "FULL_PRODUCT_NAME")
  stop("the build settings have no product path") unless directory.is_a?(String) && product.is_a?(String) && product.end_with?(".app")
  path = File.join(directory, product)
  # The product must come from the fixed DerivedData of this worktree (D-084).
  unless path.start_with?("#{derived_data_root}/") && path.include?("/DerivedData/Build/Products/Debug-iphoneos/") && !path.include?("/../")
    stop("the product path is not in the fixed DerivedData: #{path}")
  end
  puts path
' "$work/settings.json" "$project_name" "$derived_data_root")" || exit 2

set +e
xcodebuild_in_worktree -destination "id=$udid" build 2>&1 | /usr/bin/tee "$work/build.log"
build_status=${PIPESTATUS[0]}
set -e
if [[ "$build_status" != 0 ]]; then
  if /usr/bin/grep -Eiq 'No profiles for|provisioning profile|No signing certificate|No Account for Team|No Accounts|requires a development team|Signing for .* requires|doesn.t include the currently selected device|is not registered' "$work/build.log"; then
    echo "build-for-device: the development signing for $declared_name is missing. Open $project_name.xcodeproj in Xcode," \
      "keep Automatic signing with the project's Team, choose $declared_name as the run destination and build once so Xcode" \
      "prepares the development profile, then run this tool again. It does not pass -allowProvisioningUpdates or create" \
      "certificates, keys or profiles (D-086)." >&2
    exit 3
  fi
  fail "the build for $declared_name failed"
fi

[[ -d "$app_path" && ! -L "$app_path" ]] || fail 'the built app was not found in the fixed DerivedData'
bounded_xcrun devicectl-install 600 devicectl device install app --device "$udid" "$app_path" ||
  fail "the install on $declared_name failed"
echo "build-for-device: installed $project_name on $declared_name; it was not launched, so open it on the device yourself"
