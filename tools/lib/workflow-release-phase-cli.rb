#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "workflow-release-phase"

command = ARGV.shift
options = {}
parser = OptionParser.new do |cli|
  cli.banner = "usage: workflow-release-phase-cli.rb init|append|validate|gate [options]"
  cli.on("--release VALUE") { |value| options["release"] = value }
  cli.on("--revision VALUE", Integer) { |value| options["revision"] = value }
  cli.on("--scope-json VALUE") { |value| options["scopeJson"] = value }
  cli.on("--goal VALUE") { |value| options["goal"] = value }
  cli.on("--actor VALUE") { |value| options["actor"] = value }
  cli.on("--reason VALUE") { |value| options["reason"] = value }
  cli.on("--recorded-at VALUE") { |value| options["recordedAt"] = value }
  cli.on("--previous PATH") { |value| options["previous"] = value }
  cli.on("--event-json VALUE") { |value| options["eventJson"] = value }
  cli.on("--output PATH") { |value| options["output"] = value }
  cli.on("--record PATH") { |value| options["record"] = value }
  cli.on("--contract PATH") { |value| options["contract"] = value }
end

begin
  parser.parse!(ARGV)
  raise OptionParser::InvalidArgument, "unexpected positional arguments" unless ARGV.empty?

  case command
  when "init"
    required = %w[release revision scopeJson goal actor reason recordedAt output]
    missing = required.reject { |key| options.key?(key) }
    raise OptionParser::MissingArgument, missing.join(", ") unless missing.empty?
    bytes = IOSTemplate::ReleasePhase.create(
      release_identifier: options.fetch("release"),
      revision: options.fetch("revision"),
      scope: JSON.parse(options.fetch("scopeJson")),
      goal: options.fetch("goal"),
      actor: options.fetch("actor"),
      reason: options.fetch("reason"),
      recorded_at: options.fetch("recordedAt")
    )
    IOSTemplate::ReleasePhase.write_unique!(options.fetch("output"), bytes)
    puts JSON.generate({"status" => "created", "path" => options.fetch("output")})
  when "append"
    required = %w[previous eventJson output]
    missing = required.reject { |key| options.key?(key) }
    raise OptionParser::MissingArgument, missing.join(", ") unless missing.empty?
    bytes = IOSTemplate::ReleasePhase.append(
      File.binread(options.fetch("previous")),
      JSON.parse(options.fetch("eventJson"))
    )
    IOSTemplate::ReleasePhase.write_unique!(options.fetch("output"), bytes)
    puts JSON.generate({"status" => "appended", "path" => options.fetch("output")})
  when "validate"
    raise OptionParser::MissingArgument, "record" unless options["record"]
    previous = options["previous"] && File.binread(options.fetch("previous"))
    record = IOSTemplate::ReleasePhase.validate_record_bytes!(File.binread(options.fetch("record")), previous_bytes: previous)
    puts JSON.generate({"status" => "valid", "releaseIdentifier" => record.fetch("releaseIdentifier"), "revision" => record.fetch("currentRevision")})
  when "gate"
    raise OptionParser::MissingArgument, "contract" unless options["contract"]
    contract = JSON.parse(File.binread(options.fetch("contract")))
    record = options["record"] && File.binread(options.fetch("record"))
    puts JSON.generate(IOSTemplate::ReleasePhase.gate!(contract, record))
  else
    raise OptionParser::InvalidArgument, "command must be init, append, validate, or gate"
  end
rescue OptionParser::ParseError, JSON::ParserError, Errno::ENOENT, Errno::EACCES,
       IOSTemplate::ReleasePhase::ValidationError => error
  warn "release phase operation failed: #{error.message}"
  exit 1
end
