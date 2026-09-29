#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby /usr/bin/ruby /usr/bin/swiftc
[[ $# == 0 ]] || exit 64
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

prepare_repo system-locale
AppleLanguages=fr-FR AppleLocale=fr_FR LANGUAGE=fr run_execute
[[ -f "$draft" ]] || { echo 'system locale success lacked draft' >&2; exit 1; }
/usr/bin/ruby - "$fake_log" <<'RUBY'
rows = File.readlines(ARGV.fetch(0)).map { |line| line.chomp.split("\t").drop(2) }
# Both iPhone cases lease the one dedicated iPhone and both iPad cases the one dedicated iPad. Each lease
# erases its device, so each erase opens the next case in the sealed order.
iphone = "00000000-0000-0000-0000-000000000001"
ipad = "00000000-0000-0000-0000-000000000003"
leased = [iphone, iphone, ipad, ipad]
preferences = rows.select { |r| r[0,2] == %w[simctl spawn] && r[3] == "defaults" }
abort "runner did not apply Simulator system preferences" unless preferences.length == 16
abort "preferences touched an unowned Simulator" unless preferences.all? { |r| [iphone, ipad].include?(r[2]) }
erases = rows.each_index.select { |i| rows[i][0,2] == %w[simctl erase] }
abort "each case was not leased by an erase of its dedicated device" unless erases.map { |i| rows[i][2] } == leased
leased.each_with_index do |udid, index|
  language, locale = index.even? ? %w[en-US en_US] : %w[ja-JP ja_JP]
  segment_end = erases[index + 1] || rows.length
  commands = rows[erases[index]...segment_end].select { |r| r[0] == "simctl" && r[2] == udid }
  language_write = commands.index(["simctl", "spawn", udid, "defaults", "write", "-g", "AppleLanguages", "-array", language])
  locale_write = commands.index(["simctl", "spawn", udid, "defaults", "write", "-g", "AppleLocale", "-string", locale])
  abort "system preferences were not derived from the matrix" unless language_write && locale_write
  restart = commands.each_index.find { |i| i > locale_write && commands[i][1] == "shutdown" }
  reboot = commands.each_index.find { |i| restart && i > restart && commands[i][1] == "boot" }
  reads = commands.each_index.select { |i| commands[i] == ["simctl", "spawn", udid, "defaults", "export", "-g", "-"] }
  install = commands.index { |r| r[1] == "install" }
  screenshot = commands.index { |r| r[1] == "io" }
  abort "locale restart/readback did not precede install and capture" unless language_write < locale_write && reboot && reads.length == 2 && reboot < reads[0] && reads[0] < install && install < reads[1] && reads[1] < screenshot
  abort "locale restart erased the applied preferences" if commands[(locale_write + 1)...install].any? { |r| r[1] == "erase" }
end
RUBY

for mode in wrong-language wrong-locale extra-language missing-language wrong-type malformed read-failure write-language write-locale restart-lost post-ui-drift; do
  prepare_repo "system-locale-$mode"
  FAKE_SYSTEM_LOCALE_MODE="$mode" expect_execute_failure "system-locale-$mode" 'case iphone-en failed'
  [[ ! -e "$draft" ]] || { echo "system locale failure published draft: $mode" >&2; exit 1; }
  /usr/bin/ruby - "$fake_log" <<'RUBY'
rows = File.readlines(ARGV.fetch(0)).map { |line| line.chomp.split("\t").drop(2) }
abort "mismatched system locale reached screenshot" if rows.any? { |r| r[0,2] == %w[simctl io] }
abort "cleanup deleted a Simulator" if rows.any? { |r| r[0,2] == %w[simctl delete] }
RUBY
  assert_runner_publication_cleanup
done

echo 'system locale iOS runner tests passed'
