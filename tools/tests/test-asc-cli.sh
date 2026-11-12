#!/bin/bash
set -euo pipefail
export LANG=en_US.UTF-8
source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby
source_root=$(cd "$(dirname "$0")/../.." && pwd -P)
exec /usr/bin/ruby --disable-gems - "$source_root" <<'RUBY'
# encoding: UTF-8
require 'json'
require 'digest'
require 'tmpdir'
require 'fileutils'
require 'open3'
root = ARGV.fetch(0)
require File.join(root, 'tools/lib/asc-cli') if File.file?(File.join(root, 'tools/lib/asc-cli.rb'))
fixture = File.join(root, 'tools/tests/fixtures/asc')
def check(condition, label)
  abort "FAIL: #{label}" unless condition
end
Dir.mktmpdir('asc-cli-test.') do |temporary|
  temporary = File.realpath(temporary)
  repo = File.join(temporary, 'repository')
  FileUtils.mkdir_p(File.join(repo, 'tools/lib'))
  FileUtils.mkdir_p(File.join(repo, 'Config'))
  %w[install-asc-cli.sh asc-run.sh run-with-secret.sh run-with-private-key.sh lib/asc-cli.rb lib/bounded-command.rb lib/ownership.rb].each do |name|
    source = File.join(root, 'tools', name)
    check(File.file?(source), "implementation missing: #{name}")
    FileUtils.cp(source, File.join(repo, 'tools', name), preserve: true)
  end
  File.write(File.join(repo, 'Config/app-identity.json'), JSON.generate({'schemaVersion'=>1, 'sourceIdentityVersion'=>1, 'appSlug'=>'asc-fixture', 'displayName'=>'ASC Fixture', 'moduleName'=>'ASCFixture', 'bundleId'=>'com.example.ascfixture'}))
  # D-066: the credentials belong to the Apple team named in Config/ownership.yml, not to the app slug.
  ownership_yaml = lambda do |app_store|
    File.read(File.join(root, 'Config/ownership.yml')).sub(/^appStore:\n(?:  .*\n?)*/) do
      "appStore:\n" + app_store.map { |field, value| "  #{field}: #{value}\n" }.join
    end
  end
  ownership_path = File.join(repo, 'Config/ownership.yml')
  team_ownership = ownership_yaml.call('teamId'=>'ABCDE12345', 'bundleId'=>'com.example.ascfixture', 'apiKeyType'=>'team-app-manager')
  File.write(ownership_path, team_ownership)
  home = File.join(temporary, 'home')
  secret_parent = File.join(home, 'Library', 'Application Support', 'iOS-Template', 'secrets')
  secret_dir = File.join(secret_parent, 'apple-team-ABCDE12345')
  FileUtils.mkdir_p(secret_dir)
  File.chmod(0700, secret_parent, secret_dir)
  key = File.join(secret_dir, 'app-store-connect-production.p8')
  File.write(key, "synthetic key fixture\n")
  File.chmod(0600, key)
  [home, repo].each { |dir| FileUtils.mkdir_p(File.join(dir, '.asc')); File.write(File.join(dir, '.asc/config.json'), 'must not read') }
  release = File.join(temporary, 'release')
  FileUtils.mkdir_p(release)
  pin_path = File.join(temporary, 'pin.json')
  original_pin = JSON.parse(File.binread(File.join(fixture, 'pin.json')))
  reset_release = lambda do
    FileUtils.cp(File.join(fixture, 'fake-asc'), File.join(release, original_pin.fetch('asset')))
    FileUtils.cp(File.join(fixture, 'checksums.txt'), File.join(release, original_pin.fetch('checksumsAsset')))
    File.binwrite(pin_path, JSON.generate(original_pin.sort.to_h))
  end
  reset_release.call
  install_root = File.join(temporary, 'installed')
  binary = File.join(install_root, original_pin.fetch('version'), 'asc')
  env = {'PATH'=>'/usr/bin:/bin', 'LANG'=>'en_US.UTF-8', 'HOME'=>home, 'IOS_TEMPLATE_TEST_MODE'=>'1', 'IOS_TEMPLATE_TEST_ASC_PIN'=>pin_path, 'IOS_TEMPLATE_TEST_ASC_INSTALL_ROOT'=>install_root, 'IOS_TEMPLATE_TEST_ASC_RELEASE_DIR'=>release, 'IOS_TEMPLATE_TEST_SECURITY_BIN'=>File.join(fixture, 'fake-security'), 'IOS_TEMPLATE_TEST_ASC_TIMEOUT'=>'30'}
  installer = File.join(repo, 'tools/install-asc-cli.sh')
  runner = File.join(repo, 'tools/asc-run.sh')
  count = 0
  invoke = lambda do |command, args=[], overrides={}, expected=0|
    out, err, status = Open3.capture3(env.merge(overrides), command, *args, chdir: repo, unsetenv_others: true)
    count += 1
    check(expected == :failure ? !status.success? : status.exitstatus == expected, "case #{count} #{args.inspect} expected #{expected}, got #{status.exitstatus}: #{err}")
    ['fixture-key-130', 'fixture-issuer-130', key].each { |secret| check(!out.include?(secret) && !err.include?(secret), "case #{count} secret leak") }
    [out, err]
  end
  read_args = ['--operation', 'appstore.inspect_app', '--', 'apps', 'list']
  invoke.call(runner, read_args, {}, :failure)
  %w[schemaVersion repository version platform asset url sha256 checksumsAsset checksumsUrl checksumsSha256 reviewedAt].each do |field|
    invalid = original_pin.reject { |k,_| k == field }
    File.binwrite(pin_path, JSON.generate(invalid.sort.to_h))
    invoke.call(installer, [], {}, :failure)
    invoke.call(runner, read_args, {}, :failure)
  end
  ['url', 'asset', 'checksumsUrl', 'platform', 'repository', 'sha256', 'checksumsSha256', 'reviewedAt', 'version'].each do |field|
    File.binwrite(pin_path, JSON.generate(original_pin.merge(field=>'invalid').sort.to_h))
    invoke.call(installer, [], {}, :failure)
    invoke.call(runner, read_args, {}, :failure)
  end
  [JSON.pretty_generate(original_pin), JSON.generate(original_pin.sort.reverse.to_h), JSON.generate(original_pin)+"\n"].each do |bytes|
    File.binwrite(pin_path, bytes)
    invoke.call(installer, [], {}, :failure)
    invoke.call(runner, read_args, {}, :failure)
  end
  reset_release.call
  invoke.call(installer)
  # The real pin is validated without downloading or executing its binary.
  AscCLI.validate_pin(File.join(root, 'Config/asc-cli.json'))
  # #530: the official asc_6.6.1_checksums.txt published with the 6.6.1 release, byte for byte.
  # The production pin must name this file's SHA-256 and its exact macOS arm64 row.
  official_checksums = <<~CHECKSUMS
    b8e9a39362151551f0c9c5def7c6ee8676048afb19f423c9a4bf08d4880bfc21  asc_6.6.1_linux_amd64
    766bb3288d1f2c3e443adeba3dbff7ba4a4d14e71eee01afe9d6967ed8b9f6a6  asc_6.6.1_linux_arm64
    7430c11ecb5d6ef1b8f660c8ebe846f1719fe6c1d1aeaea393445797a4ce3ae4  asc_6.6.1_macOS_amd64
    63cf0cb8f16ce3976d844b135befc4906fe8a4c702ada4beda80a9b6a566d16e  asc_6.6.1_macOS_arm64
    5b16cc211328860056694d0f0bf32eeb2f508508cc9ecd19c3d0ed75e694c47f  asc_6.6.1_windows_amd64.exe
  CHECKSUMS
  production_pin = JSON.parse(File.binread(File.join(root, 'Config/asc-cli.json')))
  check(official_checksums.bytesize == 446 && official_checksums.end_with?("windows_amd64.exe\n"), 'official checksum bytes are complete')
  check(production_pin.fetch('version') == '6.6.1' && production_pin.fetch('checksumsAsset') == 'asc_6.6.1_checksums.txt',
    'production pin names the reviewed 6.6.1 checksum file')
  check(Digest::SHA256.hexdigest(official_checksums) == production_pin.fetch('checksumsSha256'),
    'production checksumsSha256 equals the official checksum file digest')
  official_rows = official_checksums.lines.map { |line| line.chomp.split('  ', 2) }
  check(official_rows.all? { |row| row.length == 2 && row[0].match?(/\A[0-9a-f]{64}\z/) }, 'official checksum file format')
  arm64 = official_rows.select { |_, name| name == production_pin.fetch('asset') }
  check(arm64.length == 1 && arm64.first[0] == production_pin.fetch('sha256'),
    'production sha256 equals the exact official asc_6.6.1_macOS_arm64 row')
  check(File.stat(binary).mode & 0777 == 0755, 'binary mode')
  check(File.stat(File.dirname(binary)).mode & 0777 == 0700, 'parent mode')
  inode = File.stat(binary).ino
  invoke.call(installer)
  check(File.stat(binary).ino == inode, 'idempotence preserves file')
  File.unlink(pin_path)
  invoke.call(installer, [], {}, :failure)
  invoke.call(runner, read_args, {}, :failure)
  reset_release.call
  File.binwrite(pin_path, JSON.generate(original_pin)+"\n")
  invoke.call(runner, read_args, {}, :failure)
  reset_release.call
  out, = invoke.call(runner, read_args, {'ASC_TELEMETRY_DISABLED'=>'0', 'ASC_PROFILE'=>'evil', 'ASC_PRIVATE_KEY_PATH'=>'evil', 'ASC_KEY_ID'=>'evil', 'ASC_PRIVATE_KEY'=>'evil', 'HTTPS_PROXY'=>'https://invalid', 'RUBYOPT'=>'-rdoes-not-exist'})
  check(JSON.parse(out)['envVerified'], 'child environment')
  [['apps','info','view','--app','123'], ['versions','list','--app','123'], ['bundle-ids','list','--identifier','com.example.app']].each do |args|
    invoke.call(runner, ['--operation','appstore.inspect_app','--']+args)
  end
  ipa_dir = File.join(repo, '.artifacts/appstore-builds/42/a123456789012345678901234/export')
  FileUtils.mkdir_p(ipa_dir)
  ipa = File.join(ipa_dir, 'GardenNotes.ipa')
  File.binwrite(ipa, 'synthetic ipa')
  build_op = ['--operation','appstore.upload_build','--']
  invoke.call(runner, build_op + ['apps','list','--bundle-id','com.example.ascfixture'])
  invoke.call(runner, build_op + ['builds','list','--app','123','--version','1.0','--build-number','7','--platform','IOS','--paginate'])
  invoke.call(runner, build_op + ['builds','info','--app','123','--version','1.0','--build-number','7','--platform','IOS'])
  invoke.call(runner, build_op + ['builds','upload','--app','123','--ipa',ipa])
  outside_ipa = File.join(temporary, 'outside.ipa')
  File.binwrite(outside_ipa, 'synthetic ipa')
  symlink_ipa = File.join(ipa_dir, 'alias.ipa')
  File.symlink(ipa, symlink_ipa)
  [outside_ipa, symlink_ipa, ipa + '/..', File.join(ipa_dir,'missing.ipa'),
   File.join(ipa_dir,'wrong.pkg')].each do |bad|
    invoke.call(runner, build_op + ['builds','upload','--app','123','--ipa',bad], {}, :failure)
  end
  [build_op + ['builds','upload','--app','123','--ipa',ipa,'--wait'],
   build_op + ['builds','upload','--app','123','--ipa',ipa,'--version','1.0'],
   build_op + ['builds','upload','--app','123'],
   build_op + ['builds','list','--app','123','--version','1.0','--build-number','7','--platform','IOS'],
   build_op + ['builds','list','--app','123','--version','1.0','--build-number','7','--platform','IOS','--paginate','--next','https://example.invalid'],
   build_op + ['builds','info','--app','123','--version','1.0','--build-number','7'],
   build_op + ['signing','sync']].each { |args| invoke.call(runner,args,{},:failure) }
  testflight_op = ['--operation','appstore.distribute_testflight','--']
  [ ['apps','list','--bundle-id','com.example.ascfixture'],
    ['builds','list','--app','123','--version','1.0','--build-number','7','--platform','IOS','--paginate'],
    ['builds','info','--app','123','--version','1.0','--build-number','7','--platform','IOS'],
    ['testflight','groups','list','--app','123','--paginate'],
    ['testflight','groups','list','--app','123','--build-id','build-1'],
    ['builds','add-groups','--app','123','--build-number','7','--version','1.0','--platform','IOS','--group','group-1'],
    ['testflight','review','submissions','list','--build-id','build-1','--paginate'],
    ['builds','test-notes','list','--build-id','build-1','--locale','en-US','--paginate'],
    ['builds','test-notes','view','--build-id','build-1','--locale','ja'],
    ['builds','test-notes','create','--build-id','build-1','--locale','en-US','--whats-new','-Try this flow'],
    ['testflight','review','submit','--build-id','build-1','--confirm'] ].each do |args|
    invoke.call(runner,testflight_op+args)
  end
  [ ['testflight','groups','list','--app','123'],
    ['testflight','groups','list','--app','123','--build-id','build-1','--paginate'],
    ['builds','add-groups','--app','123','--build-number','7','--version','1.0','--platform','IOS','--group','group-1','--submit'],
    ['builds','remove-groups','--build-id','build-1','--group','group-1','--confirm'],
    ['testflight','review','submit','--build-id','build-1'],
    ['testflight','review','submissions','list','--build-id','build-1'],
    ['builds','test-notes','update','--build-id','build-1','--locale','en-US','--whats-new','No'],
    ['builds','test-notes','delete','--build-id','build-1','--locale','en-US','--confirm'],
    ['builds','test-notes','list','--build-id','build-1','--locale','en-US'],
    ['builds','test-notes','view','--build-id','build-1'],
    ['builds','test-notes','create','--build-id','build-1','--locale','en-US'],
    ['builds','test-notes','create','--build-id','build-1','--locale','fr','--whats-new','No'],
    ['builds','add-groups','--app','123','--build-number','7','--version','1.0','--platform','MAC_OS','--group','group-1'] ].each do |args|
    invoke.call(runner,testflight_op+args,{},:failure)
  end
  note_args = testflight_op + ['builds','test-notes','create','--build-id','build-1','--locale','en-US','--whats-new','-Try this flow']
  out, = invoke.call(runner,note_args)
  check(JSON.parse(out).fetch('argv').include?('--whats-new=-Try this flow'),
    'What to Test leading hyphen remains one --whats-new=value argument')
  # #530: asc 6.6.1 NormalizeTestNotes removes "<", NFC-composes, and drops generic combining marks before it
  # writes. Text it would change is refused before asc runs; text it keeps as is still passes.
  notes = lambda { |text| testflight_op + ['builds','test-notes','create','--build-id','build-1','--locale','ja','--whats-new',text] }
  ["日本語のメモ。é と ñ を確認する。", "Check the café"].each_with_index do |text, index|
    if index.zero?
      out, = invoke.call(runner, notes.call(text))
      check(JSON.parse(out).fetch('argv').include?("--whats-new=#{text}"), 'NFC What to Test text passes unchanged')
    else
      invoke.call(runner, notes.call(text), {}, :failure)
    end
  end
  ["Open the <Settings> tab", "Check the café", "a̶strike", "x⃗", "half︠mark", "mark᪰", "mark᷀"].each do |text|
    begin
      AscCLI.command_arguments(notes.call(text))
      abort "What to Test text that asc 6.6.1 rewrites was accepted: #{text.inspect}"
    rescue AscCLI::Refused
      # Refused before any process invocation.
    end
  end
  # Script-specific marks such as Devanagari vowel signs are kept by asc 6.6.1, so they pass.
  AscCLI.command_arguments(notes.call("हिन्दी"))
  invoke.call(runner, read_args+['--output','json'])
  forbidden = [%w[web apps list], %w[auth login], %w[auth logout], %w[apps wall], %w[install-skills], %w[signing sync], %w[workflow run release], %w[telemetry enable], %w[apps update], %w[apps list --deep], %w[apps list --profile evil], %w[apps list --output table], %w[apps list --output=json], %w[apps list --debug], %w[apps list --next https://evil.example], %w[apps list --limit 0], %w[apps list --limit 201], %w[apps list --limit 2 --limit 3], %w[apps list extra], %w[apps list --bundle-id --deep]]
  forbidden.each { |args| invoke.call(runner, ['--operation','appstore.inspect_app','--']+args, {}, :failure) }
  update = ['--operation', 'appstore.update_metadata', '--', 'localizations', 'update', '--version', 'V1', '--type', 'version', '--locale', 'ja']
  list = ['--operation', 'appstore.update_metadata', '--', 'localizations', 'list', '--version', 'V1', '--type', 'version', '--locale', 'ja', '--paginate']
  invoke.call(runner, list)
  unicode_copy = "日本語の説明\n次の行。"
  out, = invoke.call(runner, update + ['--description', unicode_copy, '--keywords', '日本語,記録'])
  check(JSON.parse(out).fetch('argv').include?("--description=#{unicode_copy}"), 'long text is forwarded as --flag=value')
  out, = invoke.call(runner, ['--operation', 'appstore.update_metadata', '--', 'localizations', 'update', '--app', '123', '--type', 'app-info', '--locale', 'en-US', '--name', '-Leading name'])
  check(JSON.parse(out).fetch('argv').include?('--name=-Leading name'), 'leading hyphen value stays a value')
  invoke.call(runner, update + ['--description', 'A' * 4000])
  invoke.call(runner, update + ['--description', "e\u0301" * 2000])
  invoke.call(runner, update + ['--description', '💐' * 2000])
  invoke.call(runner, update + ['--keywords', 'あ' * 33])
  invoke.call(runner, update + ['--promotional-text', 'あ' * 170])
  invoke.call(runner, update + ['--whats-new', 'A' * 4000])
  [update + ['--description', 'A' * 4001], update + ['--keywords', 'あ' * 34],
   update + ['--description', "e\u0301" * 2001], update + ['--description', '💐' * 2001],
   update + ['--promotional-text', 'あ' * 171], update + ['--whats-new', 'A' * 4001],
   update + ['--description', "bad\tvalue"],
   update + ['--name', 'Wrong form'], update + ['--description', ''],
   list + ['--description', 'write'],
   ['--operation', 'appstore.update_metadata', '--', 'localizations', 'update', '--app', '123', '--type', 'app-info', '--locale', 'ja', '--privacy-policy-url', 'https://example.com'],
   ['--operation', 'appstore.update_metadata', '--', 'localizations', 'create', '--version', 'V1', '--locale', 'ja'],
   ['--operation', 'appstore.update_metadata', '--', 'versions', 'update', '--version-id', 'V1']].each do |args|
    invoke.call(runner, args, {}, :failure)
  end
  begin
    AscCLI.command_arguments(update + ['--description', "bad\0value"])
    abort 'NUL localization value was accepted'
  rescue AscCLI::Refused
    # Refused before any process invocation.
  end
  # #530: asc 6.6.1 expands @env:NAME, @file:PATH and @@ in every value flag, and the child holds the secrets,
  # so a value that starts with @ is refused for every value type before asc runs.
  [update + ['--description', '@env:ASC_ISSUER_ID'], update + ['--keywords', '@file:/etc/hosts'],
   update + ['--whats-new', '@@literal'], update + ['--promotional-text', '@mention'],
   ['--operation', 'appstore.update_metadata', '--', 'localizations', 'update', '--app', '123', '--type', 'app-info', '--locale', 'ja', '--name', '@env:ASC_KEY_ID'],
   ['--operation', 'appstore.update_metadata', '--', 'versions', 'update', '--version-id', 'V1', '--copyright', '@env:ASC_PRIVATE_KEY_PATH'],
   ['--operation', 'appstore.inspect_app', '--', 'apps', 'list', '--name', '@env:ASC_ISSUER_ID'],
   ['--operation', 'appstore.inspect_app', '--', 'apps', 'list', '--bundle-id', '@env:ASC_KEY_ID'],
   ['--operation', 'appstore.inspect_app', '--', 'versions', 'list', '--app', '123', '--version', '@file:/etc/hosts'],
   testflight_op + ['builds','test-notes','create','--build-id','build-1','--locale','en-US','--whats-new','@file:/etc/hosts'],
   testflight_op + ['builds','test-notes','view','--build-id','@env:ASC_KEY_ID','--locale','ja']].each do |args|
    begin
      AscCLI.command_arguments(args)
      abort "a value starting with @ was accepted: #{args.inspect}"
    rescue AscCLI::Refused
      # Refused before any process invocation.
    end
  end
  _, err = invoke.call(runner, update + ['--description', '@env:ASC_ISSUER_ID'], {}, :failure)
  check(err.include?('flag value is invalid'), "@env: value was not refused by the adapter: #{err}")
  # A @ that is not the first character stays ordinary text.
  out, = invoke.call(runner, update + ['--description', 'Mail support@example.com'])
  check(JSON.parse(out).fetch('argv').include?('--description=Mail support@example.com'), 'an inner @ is forwarded unchanged')
  # Flags that asc 6.6.1 added stay outside the allowlist.
  [['--operation','appstore.submit_review','--','versions','attach-build','--version-id','V1','--latest'],
   ['--operation','appstore.submit_review','--','versions','attach-build','--app','123','--version','1.0','--build-number','7'],
   ['--operation','appstore.submit_review','--','review','submit','--app','123','--version-id','V1','--build-id','B1','--confirm','--wait'],
   ['--operation','appstore.submit_review','--','review','submit','--app','123','--version','1.0','--build-number','7','--confirm'],
   ['--operation','appstore.update_metadata','--','localizations','update','--app','123','--type','app-info','--locale','ja','--clear-subtitle','--confirm'],
   update + ['--description', 'Text', '--platform', 'IOS'],
   ['--operation','appstore.update_metadata','--','screenshots','list','--set-id','SET1'],
   ['--operation','appstore.update_metadata','--','screenshots','upload','--version-localization','LOC1','--path','x.png','--device-type','APP_IPHONE_61','--asset-library'],
   ['--operation','appstore.update_metadata','--','versions','update','--version-id','V1','--copyright','2026 Example','--review-type','APP_STORE'],
   ['--operation','appstore.upload_build','--','builds','info','--app','123','--version','1.0','--build-number','7','--platform','IOS','--include','buildBetaDetail']].each do |args|
    begin
      AscCLI.command_arguments(args)
      abort "a flag added in asc 6.6.1 was accepted: #{args.inspect}"
    rescue AscCLI::Refused
      # Refused before any process invocation.
    end
  end
  # #532: submit_review reads the attached build with versions list --include build. No other include
  # value (appStoreReviewDetail carries review secrets) and no include in another operation is allowed.
  submit_versions = ['--operation','appstore.submit_review','--','versions','list','--app','123','--version','1.0','--platform','IOS']
  check(AscCLI.command_arguments(submit_versions + ['--include','build']).each_cons(2).include?(['--include','build']),
    'submit_review forwards versions list --include build')
  [submit_versions + ['--include','appStoreReviewDetail'], submit_versions + ['--include','build,appStoreReviewDetail'],
   submit_versions + ['--include','build', '--include','build'],
   ['--operation','appstore.inspect_app','--','versions','list','--app','123','--version','1.0','--platform','IOS','--include','build'],
   ['--operation','appstore.update_metadata','--','versions','list','--app','123','--version','1.0','--platform','IOS','--include','build']].each do |args|
    begin
      AscCLI.command_arguments(args)
      abort "a versions list include outside #532 was accepted: #{args.inspect}"
    rescue AscCLI::Refused
      # Refused before any process invocation.
    end
  end
  # D-079: iphone-6.3 images upload as APP_IPHONE_61 and ipad-13 images as APP_IPAD_PRO_3GEN_129. The former
  # APP_IPHONE_67 slot and iphone-6.9 folder are refused before asc runs.
  screenshot_root = File.join(repo, 'App Store/screenshots')
  screenshot_paths = %w[iphone-6.3 iphone-6.9 ipad-13].each_with_index.to_h do |family, index|
    path = File.join(screenshot_root, "en-US/#{family}/01-primary.png")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "synthetic screenshot #{index}")
    [family, path]
  end
  File.write(File.join(screenshot_root, 'manifest.json'), JSON.generate({'schemaVersion'=>1, 'cases'=>screenshot_paths.values.map do |path|
    {'path'=>path.delete_prefix(screenshot_root + '/'), 'digest'=>"sha256:#{Digest::SHA256.file(path).hexdigest}"}
  end}))
  upload = lambda do |family, display_type|
    ['--operation', 'appstore.update_metadata', '--', 'screenshots', 'upload', '--version-localization', 'LOC1',
     '--path', screenshot_paths.fetch(family), '--device-type', display_type]
  end
  out, = invoke.call(runner, upload.call('iphone-6.3', 'APP_IPHONE_61'))
  check(JSON.parse(out).fetch('argv').each_cons(2).include?(['--device-type', 'APP_IPHONE_61']), 'iPhone screenshots upload as APP_IPHONE_61')
  invoke.call(runner, upload.call('ipad-13', 'APP_IPAD_PRO_3GEN_129'))
  [%w[iphone-6.3 APP_IPHONE_67], %w[iphone-6.3 APP_IPHONE_69], %w[iphone-6.9 APP_IPHONE_61], %w[iphone-6.9 APP_IPHONE_67]].each do |family, display_type|
    _, err = invoke.call(runner, upload.call(family, display_type), {}, :failure)
    check(err.include?('flag value is invalid'), "#{family} as #{display_type} was not refused by the adapter: #{err}")
  end
  check(File.read(File.join(root, 'tools/lib/asc-cli.rb'), encoding: 'UTF-8').match?(/D-079: iPhone screenshots use APP_IPHONE_61 .*pending\s+#\s+confirmation until the first real save is read back/m),
    'the APP_IPHONE_61 mapping is not recorded as pending confirmation')
  invoke.call(runner, read_args.map { |arg| arg == 'appstore.inspect_app' ? 'appstore.update_metadata' : arg })
  out, err = invoke.call(runner, read_args+['--name','fixture-leak'])
  check(out.include?('[REDACTED]') && err.include?('[REDACTED]'), 'both streams redacted')
  invoke.call(runner, read_args+['--name','fixture-fail'], {}, 17)
  # #363: the normal cases run under a 30-second limit, not 2 seconds, so a slow host does not turn an ordinary
  # run into a timeout. A run slower than the old limit still succeeds; the timeout case below keeps 1 second.
  invoke.call(runner, read_args+['--name','fixture-slow'])
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  _, err = invoke.call(runner, read_args+['--name','fixture-timeout'], {'IOS_TEMPLATE_TEST_ASC_TIMEOUT'=>'1'}, 124)
  check(Process.clock_gettime(Process::CLOCK_MONOTONIC)-started < 8, 'bounded timeout')
  # The failure output says that the run was a timeout, of which stage, and under which limit.
  check(err.match?(/bounded command timed out: stage=asc-cli elapsedSeconds=\d+\.\d{3} timeoutSeconds=1\b/), "the timeout is not identifiable from its output: #{err}")
  File.chmod(0644, key)
  invoke.call(runner, read_args, {}, :failure)
  File.chmod(0600, key)
  File.link(key, key+'.hardlink')
  invoke.call(runner, read_args, {}, :failure)
  File.unlink(key+'.hardlink')
  File.rename(key, key+'.saved')
  File.symlink(key+'.saved', key)
  invoke.call(runner, read_args, {}, :failure)
  File.unlink(key)
  File.rename(key+'.saved', key)
  identity_path = File.join(repo, 'Config/app-identity.json')
  identity_bytes = File.binread(identity_path)
  File.unlink(identity_path)
  invoke.call(runner, read_args, {}, :failure)
  File.binwrite(identity_path, identity_bytes)
  # Without a 10-character team ID and the App Manager team key type, no secret is read.
  {
    'missing key type' => {'teamId'=>'ABCDE12345', 'bundleId'=>'com.example.ascfixture'},
    'other key type' => {'teamId'=>'ABCDE12345', 'bundleId'=>'com.example.ascfixture', 'apiKeyType'=>'team-admin'},
    'unset team' => {'teamId'=>'null', 'bundleId'=>'com.example.ascfixture', 'apiKeyType'=>'team-app-manager'},
    'malformed team' => {'teamId'=>'abcde12345', 'bundleId'=>'com.example.ascfixture', 'apiKeyType'=>'team-app-manager'}
  }.each do |label, app_store|
    File.write(ownership_path, ownership_yaml.call(app_store))
    _, err = invoke.call(runner, read_args, {}, :failure)
    check(err.include?('team namespace is unavailable'), "#{label} did not stop before reading secrets: #{err}")
  end
  File.write(ownership_path, team_ownership)
  # The per-app location is never read, even when a key sits there.
  legacy_dir = File.join(secret_parent, 'asc-fixture')
  FileUtils.mkdir_p(legacy_dir)
  File.chmod(0700, legacy_dir)
  FileUtils.cp(key, File.join(legacy_dir, 'app-store-connect-production.p8'), preserve: true)
  File.rename(secret_dir, secret_dir + '.aside')
  invoke.call(runner, read_args, {}, :failure)
  File.rename(secret_dir + '.aside', secret_dir)
  FileUtils.rm_rf(legacy_dir)
  original_bytes = File.binread(binary)
  ['', 'partial', 'different existing bytes'].each do |bytes|
    File.binwrite(binary, bytes)
    invoke.call(installer, [], {}, :failure)
    invoke.call(runner, read_args, {}, :failure)
    check(File.binread(binary) == bytes, 'existing bytes preserved')
  end
  File.unlink(binary)
  File.symlink(File.join(fixture,'fake-asc'), binary)
  invoke.call(installer, [], {}, :failure)
  invoke.call(runner, read_args, {}, :failure)
  File.unlink(binary)
  FileUtils.mkdir_p(binary)
  invoke.call(installer, [], {}, :failure)
  FileUtils.rmdir(binary)
  version_dir = File.dirname(binary)
  File.rename(version_dir, version_dir+'.saved')
  File.symlink(version_dir+'.saved', version_dir)
  invoke.call(installer, [], {}, :failure)
  invoke.call(runner, read_args, {}, :failure)
  File.unlink(version_dir)
  File.rename(version_dir+'.saved', version_dir)
  ['asset', 'checksumsAsset'].each do |field|
    path = File.join(release, original_pin.fetch(field))
    File.binwrite(path, 'corrupted')
    invoke.call(installer, [], {}, :failure)
    check(!File.exist?(binary), 'bad release never published')
    reset_release.call
    File.unlink(path)
    File.symlink(File.join(fixture, field == 'asset' ? 'fake-asc' : 'checksums.txt'), path)
    invoke.call(installer, [], {}, :failure)
    File.unlink(path)
    reset_release.call
  end
  wrong_checksums = "#{'0'*64}  #{original_pin.fetch('asset')}\n"
  File.binwrite(File.join(release, original_pin.fetch('checksumsAsset')), wrong_checksums)
  File.binwrite(pin_path, JSON.generate(original_pin.merge('checksumsSha256'=>Digest::SHA256.hexdigest(wrong_checksums)).sort.to_h))
  invoke.call(installer, [], {}, :failure)
  check(!File.exist?(binary), 'checksum row mismatch never published')
  reset_release.call
  children = 2.times.map do
    Process.spawn(env, installer, chdir: repo, unsetenv_others: true, out: File::NULL, err: File::NULL)
  end
  children.each { |pid| check(Process.waitpid2(pid).last.success?, 'concurrent install is idempotent') }
  check(File.binread(binary) == original_bytes, 'concurrent publication has exact bytes')
  check(Dir.children(File.dirname(binary)) == ['asc'], 'no partial publication remains')
  # A digest-valid fake with a different reported version must still be refused.
  wrong_version = original_bytes.sub('6.6.1 (commit:', '6.6.2 (commit:')
  File.binwrite(binary, wrong_version)
  File.chmod(0755, binary)
  File.binwrite(pin_path, JSON.generate(original_pin.merge('sha256'=>Digest::SHA256.hexdigest(wrong_version)).sort.to_h))
  invoke.call(runner, read_args, {}, :failure)
  reset_release.call
  env.keys.grep(/IOS_TEMPLATE_TEST_/).reject { |k| k == 'IOS_TEMPLATE_TEST_MODE' }.each do |name|
    isolated = env.keys.grep(/IOS_TEMPLATE_TEST_/).to_h { |k| [k,nil] }.merge(name=>env.fetch(name))
    invoke.call(installer, [], isolated, :failure)
    invoke.call(runner, read_args, isolated, :failure)
  end
  %w[IOS_TEMPLATE_TEST_ASC_PIN IOS_TEMPLATE_TEST_ASC_INSTALL_ROOT IOS_TEMPLATE_TEST_ASC_RELEASE_DIR IOS_TEMPLATE_TEST_SECURITY_BIN].each do |name|
    invoke.call(installer, [], {name=>'relative'}, :failure)
    link = File.join(temporary, 'override-link')
    File.symlink(env.fetch(name), link)
    invoke.call(installer, [], {name=>link}, :failure)
    File.unlink(link)
  end
  # docs/security.md lists every allowlisted subcommand of each operation. Drift in either direction fails.
  documented_allowlist = lambda do |text|
    section = text[/^### 固定版ascの利用\n(.*?)(?=^## |^### |\z)/m, 1] or return nil
    section.scan(/^- `(appstore\.[a-z_]+)`: (.+)$/).to_h do |operation, list|
      [operation, list.split('、').map { |item| item.strip.delete_prefix('`').delete_suffix('`') }.sort]
    end
  end
  implemented_allowlist = AscCLI::OPERATIONS.to_h { |operation, table| [operation, table.keys.map { |words| words.join(' ') }.sort] }
  security_text = File.read(File.join(root, 'docs/security.md'), encoding: 'UTF-8')
  check(documented_allowlist.call(security_text) == implemented_allowlist, 'docs/security.md asc allowlist differs from AscCLI::OPERATIONS')
  dropped = security_text.sub('、`review status`', '')
  check(dropped != security_text && documented_allowlist.call(dropped) != implemented_allowlist, 'a subcommand missing from the documented allowlist was not detected')
  read_only = '`apps list`、`apps info view`、`versions list`、`bundle-ids list`'
  added = security_text.sub(read_only, "#{read_only}、`builds upload`")
  check(added != security_text && documented_allowlist.call(added) != implemented_allowlist, 'a subcommand documented but not implemented was not detected')
  implementation_only = implemented_allowlist.merge('appstore.inspect_app' => (implemented_allowlist.fetch('appstore.inspect_app') + ['review submit']).sort)
  check(documented_allowlist.call(security_text) != implementation_only, 'a subcommand implemented but not documented was not detected')
  puts "PASS: asc installer/runner #{count} cases (fake binary, offline only)"
end
RUBY
