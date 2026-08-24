#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'digest'
require 'time'

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
  'elevenlabs.generate_audio' => ['elevenlabs-project', %w[outputPath text voice]],
  'appstore.inspect_app' => ['appstore-app', []],
  'appstore.upload_build' => ['appstore-app', %w[buildPath]],
  'appstore.update_metadata' => ['appstore-app', %w[metadata]],
  'appstore.submit_review' => ['appstore-app', %w[version]]
}.freeze

def validate_inputs(operation, inputs)
  expected = OPERATIONS.fetch(operation)[1]
  exact_keys(inputs, expected, 'inputs')
  inputs.each do |key, value|
    case key
    when 'issue', 'pullRequest'
      fail_closed("inputs.#{key} must be a positive integer") unless value.is_a?(Integer) && value.positive?
    when 'labels', 'migrations'
      fail_closed("inputs.#{key} must be a non-empty array") unless value.is_a?(Array) && !value.empty?
      value.each { |entry| nonempty_string(entry, "inputs.#{key}") }
    when 'metadata'
      object(value, 'inputs.metadata')
      fail_closed('inputs.metadata must not be empty') if value.empty?
    else
      nonempty_string(value, "inputs.#{key}")
    end
  end
end

def validate_request(request, expected_account)
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
  fail_closed('expectedAccount does not match configured account') unless request['expectedAccount'] == expected_account
  nonempty_string(request['reason'], 'reason')
  validate_inputs(request['operation'], request['inputs'])
  request
end

case ARGV.shift
when 'validate-request'
  path, artifacts_root, expected_account = ARGV
  fail_closed('validate-request arguments are invalid') unless ARGV.length == 3
  root = File.realpath(artifacts_root)
  request_path = File.realpath(path)
  fail_closed('request is outside .artifacts/ops-requests') unless request_path.start_with?(File.join(root, 'ops-requests') + '/')
  request = validate_request(read_json(request_path), expected_account)
  puts canonical_json(request)
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
  current = ARGV.fetch(0)
  comments = JSON.parse(STDIN.read).fetch('comments')
  fail_closed('Issue comments are invalid') unless comments.is_a?(Array)
  marker = nil
  comments.reverse_each do |comment|
    body = comment.is_a?(Hash) ? comment['body'] : nil
    next unless body.is_a?(String)
    match = body.match(/<!-- ios-template-state (\{.*\}) -->/m)
    next unless match
    begin
      parsed = JSON.parse(match[1])
      if parsed.is_a?(Hash) && parsed.keys.sort == %w[executor from resumeState timestamp to] && parsed['executor'] == 'codex' && parsed['from'].is_a?(String) && parsed['to'] == current && parsed['resumeState'].is_a?(String) && parsed['timestamp'].is_a?(String)
        marker = parsed
        break
      end
    rescue JSON::ParserError
      nil
    end
  end
  fail_closed('no unambiguous resume marker exists') unless marker
  puts marker.fetch('resumeState')
when 'state-record'
  state, from, to, resume_state, timestamp = ARGV
  fail_closed('state-record arguments are invalid') unless ARGV.length == 5
  record = {
    'state' => state, 'from' => (from == 'null' ? nil : from), 'to' => to,
    'resumeState' => (resume_state == 'null' ? nil : resume_state),
    'executor' => 'codex', 'timestamp' => timestamp
  }
  puts canonical_json(record)
when 'state-marker'
  from, to, resume_state, timestamp = ARGV
  fail_closed('state-marker arguments are invalid') unless ARGV.length == 4
  marker = {
    'from' => from, 'to' => to, 'resumeState' => (resume_state == 'null' ? nil : resume_state),
    'executor' => 'codex', 'timestamp' => timestamp
  }
  puts "<!-- ios-template-state #{canonical_json(marker)} -->"
when 'sanitize-result'
  path, request_path = ARGV
  fail_closed('sanitize-result arguments are invalid') unless ARGV.length == 2
  result = read_json(path)
  request = read_json(request_path)
  required = %w[executedAt executor operation status target verifiedAccount]
  fail_closed('Codex result is malformed') unless result.is_a?(Hash) && required.all? { |key| result.key?(key) }
  safe = result.slice(*(%w[executedAt executor operation resultReference status target verifiedAccount]))
  fail_closed('Codex result executor is invalid') unless safe['executor'] == 'codex'
  fail_closed('Codex result does not match request') unless safe['operation'] == request['operation'] && safe['target'] == request.dig('target', 'identifier') && safe['verifiedAccount'] == request['expectedAccount']
  fail_closed('Codex result status is invalid') unless %w[succeeded failed blocked:ops].include?(safe['status'])
  safe.each { |key, value| nonempty_string(value, "result.#{key}") unless key == 'resultReference' && value.nil? }
  puts canonical_json(safe)
else
  fail_closed('unknown workflow-json command')
end
