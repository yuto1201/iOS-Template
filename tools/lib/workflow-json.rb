#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'digest'
require 'time'
require 'open3'
require 'uri'
require_relative 'descriptor-files'
require_relative 'issue-contract'
require_relative 'ownership'
require_relative 'review-sealing'

def fail_closed(message)
  warn "workflow validation failed: #{message}"
  exit 1
end

def object(value, name)
  fail_closed("#{name} must be an object") unless value.is_a?(Hash)
  value
end

def exact_keys(value, keys, name)
  object(value, name)
  fail_closed("#{name} has unknown or missing fields") unless value.keys.sort == keys.sort
end

def nonempty_string(value, name)
  fail_closed("#{name} must be a non-empty string") unless value.is_a?(String) && !value.empty? && !value.include?("\0")
end

def canonical(value)
  case value
  when Hash
    value.keys.sort.each_with_object({}) { |key, out| out[key] = canonical(value.fetch(key)) }
  when Array
    value.map { |entry| canonical(entry) }
  else
    value
  end
end

def canonical_json(value)
  JSON.generate(canonical(value))
end

def read_json(path)
  JSON.parse(File.binread(path))
rescue Errno::ENOENT, JSON::ParserError => error
  fail_closed("cannot read JSON: #{error.class}")
end

OPERATIONS = {
  'github.read_issue' => ['repository', %w[issue]],
  'github.create_issue' => ['repository', %w[body title]],
  'github.update_issue' => ['repository', %w[body issue labels state title]],
  'github.push_branch' => ['repository', %w[branch headSha]],
  'github.create_pr' => ['repository', %w[base head]],
  'github.merge_pr' => ['repository', %w[headSha pullRequest]],
  'github.delete_branch' => ['repository', %w[branch]],
  'github.sync_labels' => ['repository', %w[labels]],
  'supabase.inspect_project' => ['supabase-project', []],
  'supabase.apply_migrations' => ['supabase-project', %w[migrations]],
  'cloudflare.inspect_account' => ['cloudflare-account', []],
  'cloudflare.deploy' => ['cloudflare-project', %w[source]],
  'linear.inspect_workspace' => ['linear-workspace', []],
  'vercel.inspect_team' => ['vercel-team', []],
  'elevenlabs.generate_audio' => ['elevenlabs-project', %w[outputPath text voice]],
  'elevenlabs.process_media' => ['elevenlabs-project', %w[mode outputPath request]],
  'appstore.inspect_app' => ['appstore-app', []],
  'appstore.upload_build' => ['appstore-app', %w[buildPath]],
  'appstore.update_metadata' => ['appstore-app', %w[metadata]],
  'appstore.submit_review' => ['appstore-app', %w[version]]
}.freeze

WORKFLOW_STATES = %w[
  proposed approved claimed in-progress verify-passed review-requested changes-requested
  approved-for-merge merged done paused superseded blocked:user blocked:ops blocked:review
  blocked:conflict blocked:dependency blocked:environment blocked:repeated-failure
].freeze

def workflow_state(value, name, nullable: false)
  return if nullable && value.nil?

  fail_closed("#{name} must be a workflow state") unless value.is_a?(String) && WORKFLOW_STATES.include?(value)
end

def blocked_state?(value)
  value.is_a?(String) && value.start_with?('blocked:') && WORKFLOW_STATES.include?(value)
end

def transition_allowed?(from, to)
  return false unless WORKFLOW_STATES.include?(from) && WORKFLOW_STATES.include?(to)
  exact = %w[
    proposed:approved proposed:blocked:user proposed:superseded
    approved:claimed approved:blocked:dependency approved:paused approved:superseded
    claimed:in-progress claimed:blocked:conflict claimed:paused
    in-progress:verify-passed in-progress:paused
    verify-passed:review-requested verify-passed:in-progress verify-passed:blocked:review
    review-requested:changes-requested review-requested:approved-for-merge review-requested:blocked:review
    changes-requested:in-progress changes-requested:blocked:user changes-requested:paused
    approved-for-merge:merged approved-for-merge:in-progress approved-for-merge:blocked:conflict approved-for-merge:blocked:ops
    merged:done
  ]
  return true if exact.include?("#{from}:#{to}")
  return blocked_state?(to) if from == 'in-progress'
  return to == 'paused' || to == 'superseded' || WORKFLOW_STATES.include?(to) if blocked_state?(from)
  return to == 'superseded' || WORKFLOW_STATES.include?(to) if from == 'paused'
  false
end

def latest_owned_state_marker(document, current, owner)
  comments = document.fetch('comments')
  fail_closed('Issue comments are invalid') unless comments.is_a?(Array)
  candidates = []
  comments.each_with_index do |comment, index|
    next unless comment.is_a?(Hash) && comment.dig('author', 'login') == owner
    body = comment['body']
    created_at_raw = comment['createdAt']
    next unless body.is_a?(String) && created_at_raw.is_a?(String)
    matches = body.scan(/<!-- ios-template-state (.*?) -->/m)
    next unless matches.length == 1
    begin
      marker = JSON.parse(matches.fetch(0).fetch(0))
      next unless marker.is_a?(Hash) && marker.keys.sort == %w[executor from resumeState timestamp to]
      next unless %w[codex claude].include?(marker['executor'])
      next unless marker['from'].is_a?(String) && marker['to'].is_a?(String)
      next unless marker['resumeState'].nil? || marker['resumeState'].is_a?(String)
      marker_time = Time.iso8601(marker['timestamp'])
      created_at = Time.iso8601(created_at_raw)
      next unless marker_time.utc.iso8601 == marker['timestamp'] && created_at.utc.iso8601 == created_at_raw
      next unless created_at >= marker_time && created_at - marker_time <= 300
      next unless marker['to'] == current && transition_allowed?(marker['from'], marker['to'])
      if blocked_state?(marker['to']) || marker['to'] == 'paused'
        next unless marker['resumeState'] == marker['from']
      elsif blocked_state?(marker['from']) || marker['from'] == 'paused'
        next unless marker['to'] == 'superseded' || marker['to'] == 'paused' || marker['resumeState'] == marker['to']
      else
        next unless marker['resumeState'].nil?
      end
      candidates << [marker_time, created_at, index, marker]
    rescue JSON::ParserError, ArgumentError
      next
    end
  end
  fail_closed('no valid owned current-state transition marker exists') if candidates.empty?
  newest_time = candidates.map(&:first).max
  newest = candidates.select { |entry| entry.first == newest_time }
  fail_closed('owned current-state transition marker history is ambiguous') unless newest.length == 1
  newest.fetch(0).fetch(3)
rescue KeyError
  fail_closed('Issue comments are invalid')
end

def sha(value, name)
  fail_closed("#{name} must be a SHA-1") unless value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/)
end

def full_state_record(value, issue, repository)
  required = %w[baseSha branch executor issue issueContract previousState primaryImplementer repository resumeState schemaVersion state worktree]
  optional = %w[from headSha pullRequest to transitionedAt]
  object(value, 'state record')
  fail_closed('state record has unknown or missing fields') unless (value.keys - required - optional).empty? && required.all? { |key| value.key?(key) }
  fail_closed('state record schemaVersion is invalid') unless value['schemaVersion'] == 1
  fail_closed('state record Issue identity is invalid') unless value['issue'] == issue
  fail_closed('state record repository identity is invalid') unless value['repository'] == repository
  fail_closed('state record branch is noncanonical') unless value['branch'].is_a?(String) && value['branch'].match?(%r{\A(codex|claude)/#{issue}-[a-z0-9][a-z0-9-]*\z})
  fail_closed('state record worktree is noncanonical') unless value['worktree'].is_a?(String) && value['worktree'].match?(%r{\A\.worktrees/#{issue}-[a-z0-9][a-z0-9-]*\z})
  fail_closed('state record worktree and branch disagree') unless value['worktree'] == ".worktrees/#{value['branch'].split('/', 2).fetch(1)}"
  sha(value['baseSha'], 'state record baseSha')
  fail_closed('state record primary implementer is invalid') unless value['primaryImplementer'].is_a?(String) && %w[codex claude].include?(value['primaryImplementer']) && value['branch'].start_with?("#{value['primaryImplementer']}/")
  exact_keys(value['issueContract'], %w[digest path], 'state record issueContract')
  fail_closed('state record issue contract path is invalid') unless value.dig('issueContract', 'path') == ".artifacts/issues/#{issue}/issue-contract.json"
  fail_closed('state record issue contract digest is invalid') unless value.dig('issueContract', 'digest').is_a?(String) && value.dig('issueContract', 'digest').match?(/\Asha256:[0-9a-f]{64}\z/)
  workflow_state(value['state'], 'state record state')
  workflow_state(value['previousState'], 'state record previousState', nullable: true)
  workflow_state(value['resumeState'], 'state record resumeState', nullable: true)
  fail_closed('state record executor is invalid') unless %w[codex claude].include?(value['executor']) && value['executor'] == value['primaryImplementer']
  sha(value['headSha'], 'state record headSha') if value.key?('headSha')
  fail_closed('state record pull request identity is invalid') if value.key?('pullRequest') && !(value['pullRequest'].is_a?(Integer) && value['pullRequest'].positive?)
  workflow_state(value['from'], 'state record from', nullable: true) if value.key?('from')
  workflow_state(value['to'], 'state record to', nullable: true) if value.key?('to')
  if value.key?('transitionedAt')
    begin
      Time.iso8601(value['transitionedAt'])
    rescue ArgumentError
      fail_closed('state record transitionedAt is invalid')
    end
  end
  value
end

def minimal_state_record(value, expected_state: nil)
  exact_keys(value, %w[executor from resumeState state timestamp to], 'minimal state record')
  workflow_state(value['state'], 'minimal state record state')
  fail_closed('minimal state record state differs from the live Issue') if expected_state && value['state'] != expected_state
  workflow_state(value['from'], 'minimal state record from', nullable: true)
  workflow_state(value['to'], 'minimal state record to')
  workflow_state(value['resumeState'], 'minimal state record resumeState', nullable: true)
  fail_closed('minimal state record executor is invalid') unless %w[codex claude].include?(value['executor'])
  begin
    Time.iso8601(value['timestamp'])
  rescue ArgumentError, TypeError
    fail_closed('minimal state record timestamp is invalid')
  end
  value
end

def live_preclaim_state_record(value, expected_state)
  value = minimal_state_record(value, expected_state: expected_state)
  post_claim = %w[claimed in-progress verify-passed review-requested changes-requested approved-for-merge merged done]
  history = %w[state from to resumeState].map { |key| value[key] }.compact
  fail_closed('minimal state record contains post-Claim history') unless (history & post_claim).empty?
  value
end

def transition_state_record(path, issue, repository, state, from, to, resume_state, timestamp, head_sha)
  workflow_state(state, 'new state')
  workflow_state(from, 'new from', nullable: true)
  workflow_state(to, 'new to')
  workflow_state(resume_state, 'new resumeState', nullable: true)
  Time.iso8601(timestamp)
  verification_binding = from == 'in-progress' && to == 'verify-passed'
  fail_closed('verification transition requires an explicit Head') if verification_binding && head_sha.nil?
  fail_closed('Head binding is forbidden for this transition') if !verification_binding && !head_sha.nil?
  sha(head_sha, 'verification transition headSha') unless head_sha.nil?
  fail_closed('state record path is a symlink') if File.symlink?(path)
  unless File.exist?(path)
    fail_closed('verification Head requires a full durable state record') unless head_sha.nil?
    return {
      'state' => state, 'from' => from, 'to' => to,
      'resumeState' => resume_state, 'executor' => 'codex', 'timestamp' => timestamp
    }
  end

  value = read_json(path)
  minimal_keys = %w[executor from resumeState state timestamp to]
  if value.is_a?(Hash) && value.keys.sort == minimal_keys
    fail_closed('verification Head requires a full durable state record') unless head_sha.nil?
    minimal_state_record(value)
    return {
      'state' => state, 'from' => from, 'to' => to,
      'resumeState' => resume_state, 'executor' => 'codex', 'timestamp' => timestamp
    }
  end

  value = full_state_record(value, issue, repository)
  if from.nil?
    value['state'] = state
    value['resumeState'] = resume_state
  else
    value['state'] = state
    value['previousState'] = from
    value['resumeState'] = resume_state
    value['from'] = from
    value['to'] = to
    value['transitionedAt'] = timestamp
  end
  if to == 'in-progress' && %w[verify-passed changes-requested approved-for-merge].include?(from)
    value.delete('headSha')
  end
  value['headSha'] = head_sha unless head_sha.nil?
  canonical(value)
rescue ArgumentError
  fail_closed('state record timestamp is invalid')
end

def contained_path(value, name, repo_root, allowed, required_type)
  nonempty_string(value, name)
  fail_closed("#{name} contains unsafe characters") if value.match?(/[\x00-\x1f\x7f]/)
  fail_closed("#{name} must be repository-relative") if value.start_with?('/') || value.split('/').any? { |component| component.empty? || component == '.' || component == '..' }
  components = value.split('/')
  fail_closed("#{name} is outside its allowed root") unless allowed.call(components)
  current = repo_root
  components.each do |component|
    current = File.join(current, component)
    next unless File.exist?(current) || File.symlink?(current)
    fail_closed("#{name} must not traverse a symlink") if File.symlink?(current)
    resolved = File.realpath(current)
    fail_closed("#{name} escapes the repository") unless resolved.start_with?(repo_root + '/') || resolved == repo_root
  end
  return if required_type == :output
  fail_closed("#{name} does not exist") unless File.exist?(current)
  fail_closed("#{name} must be a regular file") if required_type == :file && !File.file?(current)
  fail_closed("#{name} must be a file or directory") if required_type == :source && !(File.file?(current) || File.directory?(current))
end

def validate_inputs(operation, inputs, repo_root)
  expected = OPERATIONS.fetch(operation)[1]
  exact_keys(inputs, expected, 'inputs')
  inputs.each do |key, value|
    case key
    when 'issue', 'pullRequest'
      fail_closed("inputs.#{key} must be a positive integer") unless value.is_a?(Integer) && value.positive?
    when 'labels', 'migrations'
      fail_closed("inputs.#{key} must be a non-empty array") unless value.is_a?(Array) && !value.empty?
      value.each do |entry|
        nonempty_string(entry, "inputs.#{key}")
        fail_closed('inputs.migrations must contain migration filenames only') if key == 'migrations' && !entry.match?(/\A[0-9][A-Za-z0-9_.-]*\.sql\z/)
      end
    when 'metadata'
      object(value, 'inputs.metadata')
      fail_closed('inputs.metadata must not be empty') if value.empty?
    when 'source'
      contained_path(value, 'inputs.source', repo_root, ->(parts) { parts.first != '.artifacts' }, :source)
    when 'outputPath'
      contained_path(value, 'inputs.outputPath', repo_root, ->(parts) { parts.length >= 3 && parts[1] == 'Resources' }, :output)
    when 'mode'
      nonempty_string(value, 'inputs.mode')
      allowed = %w[text-to-speech speech-to-speech speech-to-text sound-effect audio-isolation music image video]
      fail_closed('inputs.mode is not an allowed ElevenLabs media mode') unless allowed.include?(value)
    when 'buildPath'
      contained_path(value, 'inputs.buildPath', repo_root, ->(parts) { parts.length >= 3 && parts[0] == '.artifacts' && parts[1] == 'appstore-builds' }, :file)
    else
      nonempty_string(value, "inputs.#{key}")
    end
  end
end

def request_provider(operation)
  prefix = operation.split('.', 2).first
  prefix == 'appstore' ? 'app-store' : prefix
end

def expected_request_identity(ownership, operation, repository)
  provider = request_provider(operation)
  if provider == 'github'
    {
      'account' => IOSTemplate::Ownership.github_login!(ownership),
      'target' => repository
    }
  else
    IOSTemplate::Ownership.provider_identity!(ownership, provider)
  end
end

def validate_request(request, ownership, repo_root, repository: nil)
  exact_keys(request, %w[environment expectedAccount inputs issue operation reason requestId requestVersion target], 'request')
  fail_closed('requestVersion must be 1') unless request['requestVersion'] == 1
  fail_closed('requestId is invalid') unless request['requestId'].is_a?(String) && request['requestId'].match?(/\A[a-z0-9][a-z0-9-]*\z/)
  fail_closed('issue must be a positive integer') unless request['issue'].is_a?(Integer) && request['issue'].positive?
  fail_closed('operation is not allowlisted') unless OPERATIONS.key?(request['operation'])
  exact_keys(request['target'], %w[identifier kind], 'target')
  expected_kind = OPERATIONS.fetch(request['operation'])[0]
  fail_closed('target.kind does not match operation') unless request['target']['kind'] == expected_kind
  nonempty_string(request['target']['identifier'], 'target.identifier')
  fail_closed('target.identifier is unsafe') if request['target']['identifier'].include?('..') || request['target']['identifier'].start_with?('/')
  fail_closed('environment is invalid') unless %w[local preview staging production].include?(request['environment'])
  nonempty_string(request['expectedAccount'], 'expectedAccount')
  repository ||= request_provider(request['operation']) == 'github' ? request.dig('target', 'identifier') : nil
  expected_identity = expected_request_identity(ownership, request['operation'], repository)
  fail_closed('expectedAccount does not match configured account') unless request['expectedAccount'] == expected_identity.fetch('account')
  fail_closed('target.identifier does not match Config ownership') unless request.dig('target', 'identifier') == expected_identity.fetch('target')
  nonempty_string(request['reason'], 'reason')
  validate_inputs(request['operation'], request['inputs'], repo_root)
  request
end

def request_snapshots(path, artifacts_root, repo_root)
  repo_root = File.realpath(repo_root)
  lexical = File.expand_path(path)
  request_root = File.join(repo_root, '.artifacts', 'ops-requests')
  fail_closed('request is outside .artifacts/ops-requests') unless File.dirname(lexical) == request_root
  physical_artifacts = File.realpath(artifacts_root)
  artifacts = IOSTemplate::ReviewSealing::SnapshotSet.new(physical_artifacts, at: '.artifacts')
  source = IOSTemplate::ReviewSealing::SnapshotSet.new(repo_root, at: 'repository')
  requests = artifacts.directory(artifacts.root, 'ops-requests', at: '.artifacts/ops-requests')
  request_leaf = artifacts.leaf(requests, File.basename(lexical), at: 'operation request')
  config = source.directory(source.root, 'Config', at: 'Config')
  ownership_leaf = source.leaf(config, 'ownership.yml', at: 'Config/ownership.yml')
  request = JSON.parse(request_leaf.bytes)
  ownership = IOSTemplate::Ownership.parse(ownership_leaf.bytes)
  validated = validate_request(request, ownership, repo_root)
  expected_name = "#{validated.fetch('requestId')}.json"
  fail_closed('request path must be the fixed path for this request ID') unless request_leaf.name == expected_name
  artifacts.verify!
  source.verify!
  [canonical_json(validated), ownership, physical_artifacts]
rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, JSON::ParserError,
       IOSTemplate::ReviewSealing::SealError, IOSTemplate::Ownership::ValidationError => error
  fail_closed("request is not a descriptor-bound canonical file: #{error.message}")
ensure
  artifacts&.close
  source&.close
end

def strict_result(result, request)
  exact_keys(result, %w[executedAt executor operation resultReference status target verifiedAccount], 'external operation result')
  fail_closed('external operation result executor is invalid') unless %w[codex claude].include?(result['executor'])
  fail_closed('external operation result does not match request') unless
    result['operation'] == request['operation'] &&
    result['target'] == request.dig('target', 'identifier') &&
    result['verifiedAccount'] == request['expectedAccount']
  fail_closed('external operation result status is invalid') unless %w[succeeded failed blocked:ops].include?(result['status'])
  %w[executedAt executor operation status target verifiedAccount].each do |key|
    nonempty_string(result[key], "result.#{key}")
    fail_closed("result.#{key} contains unsafe characters") if result[key].match?(/[\x00-\x1f\x7f]/)
  end
  begin
    executed_at = Time.iso8601(result['executedAt']).utc
  rescue ArgumentError
    fail_closed('result.executedAt is invalid')
  end
  fail_closed('result.executedAt is implausibly in the future') if executed_at > Time.now.utc + 300
  reference = result['resultReference']
  unless reference.nil?
    nonempty_string(reference, 'result.resultReference')
    fail_closed('result.resultReference contains unsafe characters') if reference.match?(/[\x00-\x1f\x7f]/)
    fail_closed('result.resultReference is too long') if reference.bytesize > 2048
    local_path = reference.start_with?('/', '~', 'file:') ||
      reference.match?(%r{(?:^|[ /])(?:Users|private|tmp|var/folders)/}) ||
      reference.include?('\\')
    fail_closed('result.resultReference contains a local path') if local_path
    if reference.match?(%r{\Ahttps?://})
      uri = URI.parse(reference)
      fail_closed('result.resultReference must be an HTTPS URL') unless uri.scheme == 'https' && uri.host && !uri.userinfo
      fail_closed('result.resultReference contains secret-like query data') if uri.query&.match?(/(?:token|secret|password|api[_-]?key)=/i)
    else
      fail_closed('result.resultReference is unsafe') unless reference.match?(/\A[A-Za-z0-9][A-Za-z0-9 ._:@\/-]{0,511}\z/)
    end
  end
  canonical(result)
rescue URI::InvalidURIError
  fail_closed('result.resultReference is invalid')
end

class ExternalOperationTransport
  def initialize(request_path:, result_path:)
    @request_path = request_path
    @result_path = result_path
    @repo_root = File.realpath(File.join(__dir__, '..', '..'))
    @artifact_snapshots = nil
    @source_snapshots = nil
  end

  def run
    canonical_request, = request_snapshots(@request_path, File.join(@repo_root, '.artifacts'), @repo_root)
    @request = JSON.parse(canonical_request)
    @request_bytes = canonical_request
    @request_digest = "sha256:#{Digest::SHA256.hexdigest(@request_bytes)}"
    @request_id = @request.fetch('requestId')
    expected_result = File.join(@repo_root, '.artifacts', 'ops-results', "#{@request_id}.json")
    fail_closed('result path must be the fixed path for this request ID') unless File.expand_path(@result_path) == expected_result

    open_transport_directories
    lock = open_lock
    fail_closed('operation request is already in flight') unless lock.flock(File::LOCK_EX | File::LOCK_NB)
    @lock = lock
    @lock_stat = lock.stat
    verify_lock_identity
    replay = completed_replay
    return replay if replay
    refuse_existing_result

    authorization = authorize!
    verify_lock_identity
    idempotency_key = "ios-template:#{@request_id}:#{@request_digest.delete_prefix('sha256:')}"
    in_flight = canonical_json(
      'schemaVersion' => 1, 'requestId' => @request_id,
      'requestDigest' => @request_digest, 'contractDigest' => authorization.fetch('contractDigest'),
      'idempotencyKey' => idempotency_key, 'status' => 'in-flight',
      'startedAt' => Time.now.utc.iso8601
    )
    receipt_leaf = @artifact_snapshots.publish_exclusive(@receipts, "#{@request_id}.json", in_flight, at: 'operation receipt')

    sanitized = invoke_executor(authorization, idempotency_key)
    @artifact_snapshots.verify!
    @source_snapshots.verify!
    verify_lock_identity
    result_bytes = "#{canonical_json(sanitized)}\n"
    result_leaf = @artifact_snapshots.publish_exclusive(@results, "#{@request_id}.json", result_bytes, at: 'operation result')
    @artifact_snapshots.verify!
    @source_snapshots.verify!
    verify_lock_identity
    result_digest = "sha256:#{Digest::SHA256.hexdigest(result_bytes)}"
    completed = canonical_json(
      'schemaVersion' => 1, 'requestId' => @request_id,
      'requestDigest' => @request_digest, 'contractDigest' => authorization.fetch('contractDigest'),
      'idempotencyKey' => idempotency_key, 'status' => 'completed',
      'resultDigest' => result_digest, 'result' => sanitized,
      'startedAt' => JSON.parse(in_flight).fetch('startedAt'), 'completedAt' => Time.now.utc.iso8601
    )
    DescriptorFiles.atomic_replace_at(
      @receipts.io, receipt_leaf.name, completed,
      receipt_leaf.bytes, receipt_leaf.stat
    )
    verify_published_result(result_leaf, result_bytes)
    verify_lock_identity
    canonical_json(sanitized)
  rescue IOSTemplate::IssueContract::ValidationError => error
    fail_closed("live Issue is invalid: #{error.failures.join('; ')}")
  rescue IOSTemplate::Ownership::ValidationError, IOSTemplate::ReviewSealing::SealError,
         SystemCallError, IOError, JSON::ParserError, KeyError => error
    fail_closed("external operation transport refused: #{error.message}")
  ensure
    lock&.close unless lock&.closed?
    @artifact_snapshots&.close
    @source_snapshots&.close
  end

  private

  def open_transport_directories
    physical_artifacts = File.realpath(File.join(@repo_root, '.artifacts'))
    @artifact_snapshots = IOSTemplate::ReviewSealing::SnapshotSet.new(physical_artifacts, at: '.artifacts')
    @source_snapshots = IOSTemplate::ReviewSealing::SnapshotSet.new(@repo_root, at: 'repository')
    @requests = @artifact_snapshots.directory(@artifact_snapshots.root, 'ops-requests', at: '.artifacts/ops-requests')
    @results = directory_at(@artifact_snapshots.root, 'ops-results', '.artifacts/ops-results')
    @receipts = directory_at(@artifact_snapshots.root, 'ops-receipts', '.artifacts/ops-receipts')
    request_leaf = @artifact_snapshots.leaf(@requests, "#{@request_id}.json", at: 'operation request')
    fail_closed('operation request changed after validation') unless canonical_json(JSON.parse(request_leaf.bytes)) == @request_bytes
    config = @source_snapshots.directory(@source_snapshots.root, 'Config', at: 'Config')
    @ownership_leaf = @source_snapshots.leaf(config, 'ownership.yml', at: 'Config/ownership.yml')
    @ownership = IOSTemplate::Ownership.parse(@ownership_leaf.bytes)
    validate_request(@request, @ownership, @repo_root)
  end

  def directory_at(parent, name, at)
    @artifact_snapshots.directory(parent, name, at: at)
  rescue IOSTemplate::ReviewSealing::SealError => error
    raise unless error.message.include?('No such file')
    Dir.mkdir(File.join(File.realpath(File.join(@repo_root, '.artifacts')), name), 0o700)
    @artifact_snapshots.directory(parent, name, at: at)
  end

  def open_lock
    name = "#{@request_id}.lock"
    fd = IOSTemplate::ReviewSealing::Native.openat(
      @receipts.io.fileno, name,
      File::RDWR | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600
    )
    created = !fd.negative?
    if fd.negative?
      error = SystemCallError.new('openat operation lock', Fiddle.last_error)
      raise error unless error.is_a?(Errno::EEXIST)
      fd = IOSTemplate::ReviewSealing::Native.openat(
        @receipts.io.fileno, name, File::RDWR | File::NOFOLLOW, 0
      )
      raise SystemCallError.new('openat existing operation lock', Fiddle.last_error) if fd.negative?
    end
    io = File.for_fd(fd, autoclose: true)
    if created
      result = IOSTemplate::ReviewSealing::Native.fchmod(io.fileno, 0o600)
      raise SystemCallError.new('fchmod operation lock', Fiddle.last_error) unless result.zero?
      io.fsync
      @receipts.io.fsync
    end
    stat = io.stat
    fail_closed('operation lock is not a single-link 0600 regular file') unless
      stat.file? && stat.nlink == 1 && (stat.mode & 0o777) == 0o600
    io
  end

  def completed_replay
    receipt_leaf = @artifact_snapshots.leaf(@receipts, "#{@request_id}.json", at: 'operation receipt')
    fail_closed('completed receipt permissions are unsafe') unless (receipt_leaf.stat.mode & 0o777) == 0o600
    receipt = JSON.parse(receipt_leaf.bytes)
    fail_closed('operation receipt request identity differs') unless
      receipt['schemaVersion'] == 1 && receipt['requestId'] == @request_id &&
      receipt['requestDigest'] == @request_digest
    fail_closed('an earlier operation attempt is in flight or ambiguous') unless receipt['status'] == 'completed'
    exact_keys(
      receipt,
      %w[completedAt contractDigest idempotencyKey requestDigest requestId result resultDigest schemaVersion startedAt status],
      'completed receipt'
    )
    fail_closed('completed receipt contract digest is invalid') unless receipt['contractDigest'].is_a?(String) && receipt['contractDigest'].match?(/\Asha256:[0-9a-f]{64}\z/)
    expected_key = "ios-template:#{@request_id}:#{@request_digest.delete_prefix('sha256:')}"
    fail_closed('completed receipt idempotency key differs') unless receipt['idempotencyKey'] == expected_key
    fail_closed('completed receipt result digest is invalid') unless receipt['resultDigest'].is_a?(String) && receipt['resultDigest'].match?(/\Asha256:[0-9a-f]{64}\z/)
    begin
      started_at = Time.iso8601(receipt['startedAt']).utc
      completed_at = Time.iso8601(receipt['completedAt']).utc
    rescue ArgumentError, TypeError
      fail_closed('completed receipt timestamps are invalid')
    end
    fail_closed('completed receipt timestamp order is invalid') if completed_at < started_at || completed_at > Time.now.utc + 300
    sanitized = strict_result(receipt.fetch('result'), @request)
    result_leaf = @artifact_snapshots.leaf(@results, "#{@request_id}.json", at: 'operation result')
    fail_closed('completed result permissions are unsafe') unless (result_leaf.stat.mode & 0o777) == 0o600
    result_bytes = "#{canonical_json(sanitized)}\n"
    fail_closed('completed result bytes differ from the receipt') unless
      result_leaf.bytes == result_bytes && receipt['resultDigest'] == "sha256:#{Digest::SHA256.hexdigest(result_bytes)}"
    canonical_json(sanitized)
  rescue Errno::ENOENT
    nil
  end

  def refuse_existing_result
    @artifact_snapshots.leaf(@results, "#{@request_id}.json", at: 'operation result')
    fail_closed('operation result already exists without a completed receipt')
  rescue Errno::ENOENT
    nil
  end

  def authorize!
    repository = @request['operation'].start_with?('github.') ? @request.dig('target', 'identifier') : contract_repository
    preflight_out, preflight_status = Open3.capture2e(
      File.join(@repo_root, 'tools', 'github-account-preflight.sh'), '--repo', repository,
      chdir: @repo_root
    )
    fail_closed('fresh personal GitHub preflight failed') unless preflight_status.success?
    preflight = JSON.parse(preflight_out)
    fail_closed('fresh GitHub preflight identity differs') unless
      preflight['account'] == IOSTemplate::Ownership.github_login!(@ownership) &&
      preflight['repository'] == repository

    issue_number = @request.fetch('issue')
    issues = @artifact_snapshots.directory(@artifact_snapshots.root, 'issues', at: '.artifacts/issues')
    issue_dir = @artifact_snapshots.directory(issues, issue_number.to_s, at: 'Issue artifact directory')
    fail_closed('Issue artifact directory is locked by a writer') unless issue_dir.io.flock(File::LOCK_SH | File::LOCK_NB)
    contract_leaf = @artifact_snapshots.leaf(issue_dir, 'issue-contract.json', at: 'Issue contract')
    state_leaf = @artifact_snapshots.leaf(issue_dir, 'state.json', at: 'Issue state')
    contract = JSON.parse(contract_leaf.bytes)
    IOSTemplate::IssueContract.validate_snapshot!(contract, issue: issue_number, repository: repository)
    contract_digest = "sha256:#{Digest::SHA256.hexdigest(contract_leaf.bytes)}"
    state = full_state_record(JSON.parse(state_leaf.bytes), issue_number, repository)
    fail_closed('Issue state does not bind the exact contract bytes') unless
      state.dig('issueContract', 'path') == ".artifacts/issues/#{issue_number}/issue-contract.json" &&
      state.dig('issueContract', 'digest') == contract_digest

    issue_output, issue_status = Open3.capture2e(
      'gh', 'issue', 'view', issue_number.to_s, '--repo', repository,
      '--json', 'number,url,body,labels'
    )
    fail_closed('current live Issue could not be read') unless issue_status.success?
    live = JSON.parse(issue_output)
    exact_keys(live, %w[body labels number url], 'live Issue')
    fail_closed('live Issue identity differs') unless
      live['number'] == issue_number && live['url'] == "https://github.com/#{repository}/issues/#{issue_number}"
    labels = live['labels']
    fail_closed('live Issue labels are invalid') unless labels.is_a?(Array) && labels.all? { |label| label.is_a?(Hash) && label['name'].is_a?(String) }
    types = labels.map { |label| label.fetch('name') }.select { |name| %w[type:feature type:regression type:docs type:release].include?(name) }
    fail_closed('live Issue must have exactly one type label') unless types.length == 1
    parsed = IOSTemplate::IssueContract.parse(
      live.fetch('body'), issue_type: types.first.delete_prefix('type:'),
      issue: issue_number, repository: repository, fetched_at: contract.fetch('fetchedAt')
    )
    reconstructed = parsed.contract
    reconstructed['verification'] = contract['verification'] if contract.key?('verification')
    fail_closed('live Issue reconstruction differs from sealed contract bytes') unless
      canonical_json(reconstructed) == contract_leaf.bytes
    operation_detail = parsed.external_operation_details.find { |detail| detail.fetch('operation') == @request.fetch('operation') }
    fail_closed('operation is not declared by the sealed current Issue') unless operation_detail
    fail_closed('request environment differs from the Issue contract') unless operation_detail.fetch('environment') == @request.fetch('environment')
    fail_closed('Issue contract executor is invalid') unless %w[Codex Claude].include?(operation_detail.fetch('executor'))
    fail_closed('operation requires a separately verified approval receipt') if operation_detail.fetch('approvalRequired')
    expected = expected_request_identity(@ownership, @request.fetch('operation'), repository)
    fail_closed('request account or target differs from Config ownership') unless
      @request.fetch('expectedAccount') == expected.fetch('account') &&
      @request.dig('target', 'identifier') == expected.fetch('target')
    @artifact_snapshots.verify!
    @source_snapshots.verify!
    {'contractDigest' => contract_digest, 'repository' => repository, 'operationDetail' => operation_detail}
  end

  def contract_repository
    issues = @artifact_snapshots.directory(@artifact_snapshots.root, 'issues', at: '.artifacts/issues identity')
    issue_dir = @artifact_snapshots.directory(issues, @request.fetch('issue').to_s, at: 'Issue artifact identity')
    contract = @artifact_snapshots.leaf(issue_dir, 'issue-contract.json', at: 'Issue contract identity')
    JSON.parse(contract.bytes).fetch('repository')
  end

  def invoke_executor(_authorization, _idempotency_key)
    fail_closed('embedded external-operation transport was retired; use the selected executor with the shared external-ops workflow')
  end

  def verify_published_result(result_leaf, expected_bytes)
    current = @artifact_snapshots.leaf(@results, result_leaf.name, at: 'published operation result')
    fail_closed('published result identity or bytes changed') unless
      current.bytes == expected_bytes &&
      [current.stat.dev, current.stat.ino] == [result_leaf.stat.dev, result_leaf.stat.ino]
  end

  def verify_lock_identity
    current, stat = DescriptorFiles.open_regular_at(@receipts.io, "#{@request_id}.lock")
    current.close
    held = @lock.stat
    fail_closed('operation lock path identity changed') unless
      held.file? && held.nlink == 1 && (held.mode & 0o777) == 0o600 &&
      [held.dev, held.ino, held.mode, held.nlink] == [@lock_stat.dev, @lock_stat.ino, @lock_stat.mode, @lock_stat.nlink] &&
      [stat.dev, stat.ino, stat.mode, stat.nlink] == [@lock_stat.dev, @lock_stat.ino, @lock_stat.mode, @lock_stat.nlink]
  rescue SystemCallError, IOError => error
    fail_closed("operation lock path identity changed: #{error.message}")
  end
end

case ARGV.shift
when 'validate-request'
  path, artifacts_root, repo_root = ARGV
  fail_closed('validate-request arguments are invalid') unless ARGV.length == 3
  canonical_request, = request_snapshots(path, artifacts_root, repo_root)
  puts canonical_request
when 'verify-request-snapshot'
  path, expected_digest, repo_root = ARGV
  fail_closed('verify-request-snapshot arguments are invalid') unless ARGV.length == 3 && expected_digest.match?(/\Asha256:[0-9a-f]{64}\z/)
  bytes = File.binread(path)
  fail_closed('request snapshot digest changed') unless "sha256:#{Digest::SHA256.hexdigest(bytes)}" == expected_digest
  ownership = IOSTemplate::Ownership.parse(File.binread(File.join(File.realpath(repo_root), 'Config', 'ownership.yml')))
  request = validate_request(JSON.parse(bytes), ownership, File.realpath(repo_root))
  fail_closed('request snapshot is not canonical') unless bytes == canonical_json(request)
  puts canonical_json(request)
when 'merge-freshness'
  verify_path, review_path, checked_at = ARGV
  fail_closed('merge-freshness arguments are invalid') unless ARGV.length == 3
  verify = read_json(verify_path)
  review = read_json(review_path)
  begin
    completed_at = Time.iso8601(verify.fetch('completedAt'))
    reviewed_at = Time.iso8601(review.fetch('reviewedAt'))
    checked = Time.iso8601(checked_at)
  rescue KeyError, ArgumentError
    fail_closed('merge evidence timestamps are missing or invalid')
  end
  fail_closed('merge preflight is not fresher than canonical evidence') unless checked > completed_at && checked > reviewed_at
when 'preflight'
  account, repository, default_branch, url, intended_operation, issue, head_sha, checked_at = ARGV
  fail_closed('preflight arguments are invalid') unless ARGV.length == 8
  document = {
    'account' => account, 'repository' => repository, 'defaultBranch' => default_branch,
    'url' => url, 'intendedOperation' => intended_operation, 'issue' => Integer(issue),
    'headSha' => head_sha, 'checkedAt' => checked_at
  }
  document['digest'] = "sha256:#{Digest::SHA256.hexdigest(canonical_json(document))}"
  puts canonical_json(document)
when 'state-from-issue'
  issue = JSON.parse(STDIN.read)
  labels = issue.fetch('labels')
  fail_closed('Issue labels are invalid') unless labels.is_a?(Array)
  states = labels.map { |label| label.is_a?(Hash) && label['name'].is_a?(String) && label['name'].start_with?('state:') ? label['name'].delete_prefix('state:') : nil }.compact
  fail_closed('Issue has no current state label') if states.empty?
  fail_closed('Issue has ambiguous current state labels') unless states.length == 1
  puts states.first
when 'resume-from-comments'
  current, owner = ARGV
  fail_closed('resume-from-comments arguments are invalid') unless ARGV.length == 2 && owner&.match?(/\A[A-Za-z0-9-]+\z/)
  marker = latest_owned_state_marker(JSON.parse(STDIN.read), current, owner)
  puts marker.fetch('resumeState')
when 'latest-state-marker'
  current, owner = ARGV
  fail_closed('latest-state-marker arguments are invalid') unless ARGV.length == 2 && owner&.match?(/\A[A-Za-z0-9-]+\z/)
  puts canonical_json(latest_owned_state_marker(JSON.parse(STDIN.read), current, owner))
when 'state-record'
  state, from, to, resume_state, timestamp, executor = ARGV
  fail_closed('state-record arguments are invalid') unless ARGV.length == 6 && %w[codex claude].include?(executor)
  record = {
    'state' => state, 'from' => (from == 'null' ? nil : from), 'to' => to,
    'resumeState' => (resume_state == 'null' ? nil : resume_state),
    'executor' => executor, 'timestamp' => timestamp
  }
  puts canonical_json(record)
when 'validate-preclaim-state'
  path, expected_state = ARGV
  fail_closed('validate-preclaim-state arguments are invalid') unless ARGV.length.between?(1, 2)
  fail_closed('pre-Claim state record path is a symlink') if File.symlink?(path)
  puts canonical_json(minimal_state_record(read_json(path), expected_state: expected_state))
when 'validate-live-preclaim-state'
  path, expected_state = ARGV
  fail_closed('validate-live-preclaim-state arguments are invalid') unless ARGV.length == 2
  fail_closed('live pre-Claim state record path is a symlink') if File.symlink?(path)
  puts canonical_json(live_preclaim_state_record(read_json(path), expected_state))
when 'transition-state-record'
  path, issue, repository, state, from, to, resume_state, timestamp, head_sha = ARGV
  fail_closed('transition-state-record arguments are invalid') unless ARGV.length == 9 && issue.match?(/\A[1-9][0-9]*\z/)
  record = transition_state_record(path, Integer(issue), repository, state, from == 'null' ? nil : from, to, resume_state == 'null' ? nil : resume_state, timestamp, head_sha == 'null' ? nil : head_sha)
  puts canonical_json(record)
when 'state-head-identity'
  path, issue, repository = ARGV
  fail_closed('state-head-identity arguments are invalid') unless ARGV.length == 3 && issue.match?(/\A[1-9][0-9]*\z/)
  fail_closed('state record path is a symlink') if File.symlink?(path)
  value = full_state_record(read_json(path), Integer(issue), repository)
  fail_closed('verification Head can be bound only from in-progress state') unless value['state'] == 'in-progress'
  puts canonical_json('branch' => value.fetch('branch'), 'worktree' => value.fetch('worktree'))
when 'validate-claim-state'
  path, issue, repository, branch, worktree, base_sha, agent, contract_digest = ARGV
  fail_closed('validate-claim-state arguments are invalid') unless ARGV.length == 8 && issue.match?(/\A[1-9][0-9]*\z/)
  fail_closed('state record path is a symlink') if File.symlink?(path)
  value = full_state_record(read_json(path), Integer(issue), repository)
  fail_closed('Claim state Branch differs') unless value['branch'] == branch
  fail_closed('Claim state worktree differs') unless value['worktree'] == worktree
  fail_closed('Claim state Base differs') unless value['baseSha'] == base_sha
  fail_closed('Claim state agent differs') unless value['primaryImplementer'] == agent
  fail_closed('Claim state contract differs') unless value.dig('issueContract', 'digest') == contract_digest
  fail_closed('Claim state is not recoverable') unless %w[approved claimed].include?(value['state'])
  puts canonical_json(value)
when 'state-marker'
  from, to, resume_state, timestamp, executor = ARGV
  fail_closed('state-marker arguments are invalid') unless ARGV.length == 5 && %w[codex claude].include?(executor)
  marker = {
    'from' => from, 'to' => to, 'resumeState' => (resume_state == 'null' ? nil : resume_state),
    'executor' => executor, 'timestamp' => timestamp
  }
  puts "<!-- ios-template-state #{canonical_json(marker)} -->"
when 'state-transition-pending'
  issue, repository, from, to, resume_state, timestamp, head_sha, executor = ARGV
  fail_closed('state-transition-pending arguments are invalid') unless ARGV.length == 8 && issue.match?(/\A[1-9][0-9]*\z/) && %w[codex claude].include?(executor)
  workflow_state(from, 'pending from')
  workflow_state(to, 'pending to')
  workflow_state(resume_state, 'pending resumeState', nullable: true) unless resume_state == 'null'
  begin
    Time.iso8601(timestamp)
  rescue ArgumentError
    fail_closed('pending timestamp is invalid')
  end
  sha(head_sha, 'pending headSha') unless head_sha == 'null'
  puts canonical_json(
    'schemaVersion' => 1, 'issue' => Integer(issue), 'repository' => repository,
    'from' => from, 'to' => to, 'resumeState' => (resume_state == 'null' ? nil : resume_state),
    'executor' => executor, 'timestamp' => timestamp, 'headSha' => (head_sha == 'null' ? nil : head_sha)
  )
when 'validate-state-transition-pending'
  path, issue, repository, from, to, head_sha, executor = ARGV
  fail_closed('validate-state-transition-pending arguments are invalid') unless ARGV.length == 7 && issue.match?(/\A[1-9][0-9]*\z/) && %w[codex claude].include?(executor)
  fail_closed('pending transition path is a symlink') if File.symlink?(path)
  bytes = File.binread(path)
  value = JSON.parse(bytes)
  exact_keys(value, %w[executor from headSha issue repository resumeState schemaVersion timestamp to], 'pending transition')
  fail_closed('pending transition identity differs') unless value['schemaVersion'] == 1 && value['issue'] == Integer(issue) && value['repository'] == repository && value['from'] == from && value['to'] == to && value['executor'] == executor
  expected_head = head_sha == 'null' ? nil : head_sha
  fail_closed('pending transition Head differs') unless value['headSha'] == expected_head
  workflow_state(value['resumeState'], 'pending resumeState', nullable: true)
  begin
    Time.iso8601(value.fetch('timestamp'))
  rescue ArgumentError, KeyError
    fail_closed('pending timestamp is invalid')
  end
  fail_closed('pending transition is not canonical') unless bytes == canonical_json(value)
  puts canonical_json(value)
when 'sanitize-result'
  path, request_path = ARGV
  fail_closed('sanitize-result arguments are invalid') unless ARGV.length == 2
  result = read_json(path)
  request = read_json(request_path)
  puts canonical_json(strict_result(result, request))
else
  fail_closed('unknown workflow-json command')
end
