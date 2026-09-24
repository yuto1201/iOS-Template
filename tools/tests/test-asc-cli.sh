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
  %w[install-asc-cli.sh asc-run.sh run-with-secret.sh run-with-private-key.sh lib/asc-cli.rb lib/bounded-command.rb].each do |name|
    source = File.join(root, 'tools', name)
    check(File.file?(source), "implementation missing: #{name}")
    FileUtils.cp(source, File.join(repo, 'tools', name), preserve: true)
  end
  File.write(File.join(repo, 'Config/app-identity.json'), JSON.generate({'schemaVersion'=>1, 'sourceIdentityVersion'=>1, 'appSlug'=>'asc-fixture', 'displayName'=>'ASC Fixture', 'moduleName'=>'ASCFixture', 'bundleId'=>'com.example.ascfixture'}))
  home = File.join(temporary, 'home')
  secret_parent = File.join(home, 'Library', 'Application Support', 'iOS-Template', 'secrets')
  secret_dir = File.join(secret_parent, 'asc-fixture')
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
  env = {'PATH'=>'/usr/bin:/bin', 'LANG'=>'en_US.UTF-8', 'HOME'=>home, 'IOS_TEMPLATE_TEST_MODE'=>'1', 'IOS_TEMPLATE_TEST_ASC_PIN'=>pin_path, 'IOS_TEMPLATE_TEST_ASC_INSTALL_ROOT'=>install_root, 'IOS_TEMPLATE_TEST_ASC_RELEASE_DIR'=>release, 'IOS_TEMPLATE_TEST_SECURITY_BIN'=>File.join(fixture, 'fake-security'), 'IOS_TEMPLATE_TEST_ASC_TIMEOUT'=>'2'}
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
    ['testflight','review','submit','--build-id','build-1','--confirm'],
    ['builds','test-notes','list','--build-id','build-1','--locale','en-US','--paginate'],
    ['builds','test-notes','view','--build-id','build-1','--locale','ja'] ].each do |args|
    invoke.call(runner,testflight_op+args)
  end
  notes_value = "-Check onboarding\nVerify date handling"
  %w[create update].each do |action|
    out, = invoke.call(runner,testflight_op+['builds','test-notes',action,'--build-id','build-1',
      '--locale','en-US','--whats-new',notes_value])
    forwarded = JSON.parse(out).fetch('argv')
    check(forwarded.include?("--whats-new=#{notes_value}") && !forwarded.include?(notes_value) &&
      !forwarded.include?('--whats-new'),'What to Test uses one --flag=value argument')
  end
  [ ['testflight','groups','list','--app','123'],
    ['testflight','groups','list','--app','123','--build-id','build-1','--paginate'],
    ['builds','add-groups','--app','123','--build-number','7','--version','1.0','--platform','IOS','--group','group-1','--submit'],
    ['builds','remove-groups','--build-id','build-1','--group','group-1','--confirm'],
    ['testflight','review','submit','--build-id','build-1'],
    ['testflight','review','submissions','list','--build-id','build-1'],
    ['builds','test-notes','create','--build-id','build-1','--locale','en-US'],
    ['builds','test-notes','update','--build-id','build-1','--locale','en-US','--whats-new',"bad\rvalue"],
    ['builds','test-notes','list','--build-id','build-1','--locale','en-US'],
    ['builds','test-notes','delete','--build-id','build-1','--locale','en-US','--confirm'],
    ['builds','add-groups','--app','123','--build-number','7','--version','1.0','--platform','MAC_OS','--group','group-1'] ].each do |args|
    invoke.call(runner,testflight_op+args,{},:failure)
  end
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
  invoke.call(runner, read_args.map { |arg| arg == 'appstore.inspect_app' ? 'appstore.update_metadata' : arg })
  out, err = invoke.call(runner, read_args+['--name','fixture-leak'])
  check(out.include?('[REDACTED]') && err.include?('[REDACTED]'), 'both streams redacted')
  invoke.call(runner, read_args+['--name','fixture-fail'], {}, 17)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  invoke.call(runner, read_args+['--name','fixture-timeout'], {'IOS_TEMPLATE_TEST_ASC_TIMEOUT'=>'1'}, 124)
  check(Process.clock_gettime(Process::CLOCK_MONOTONIC)-started < 8, 'bounded timeout')
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
  wrong_version = original_bytes.sub('5.4.0 (commit:', '5.4.1 (commit:')
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
  puts "PASS: asc installer/runner #{count} cases (fake binary, offline only)"
end
RUBY
