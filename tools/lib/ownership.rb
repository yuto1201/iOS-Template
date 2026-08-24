#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "yaml"

module IOSTemplate
  module Ownership
    class ValidationError < StandardError; end

    TOP_LEVEL_KEYS = %w[schemaVersion github supabase cloudflare elevenlabs appStore].freeze
    PROVIDER_FIELDS = {
      "supabase" => ["supabase", "organization", "projectRef"],
      "cloudflare" => ["cloudflare", "accountId", "target"],
      "elevenlabs" => ["elevenlabs", "accountId", "workspaceId"],
      "app-store" => ["appStore", "teamId", "bundleId"]
    }.freeze
    SECTION_KEYS = {
      "github" => %w[login],
      "supabase" => %w[organization projectRef],
      "cloudflare" => %w[accountId target],
      "elevenlabs" => %w[accountId workspaceId],
      "appStore" => %w[teamId bundleId]
    }.freeze

    module_function

    def parse(bytes)
      value = YAML.safe_load(bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
      exact_keys!(value, TOP_LEVEL_KEYS, "ownership")
      refuse("ownership.schemaVersion must be 1") unless value["schemaVersion"] == 1
      SECTION_KEYS.each do |section, keys|
        exact_keys!(value[section], keys, "ownership.#{section}")
        value.fetch(section).each do |field, entry|
          refuse("ownership.#{section}.#{field} must be a string or null") unless entry.nil? || entry.is_a?(String)
          validate_identifier!(entry, "ownership.#{section}.#{field}") unless entry.nil?
        end
      end
      refuse("ownership.github.login must be configured") if value.dig("github", "login").nil?
      value
    rescue Psych::Exception => error
      refuse("ownership is invalid YAML: #{error.message}")
    end

    def github_login!(value)
      validate_identifier!(value.dig("github", "login"), "ownership.github.login")
    end

    def provider_identity!(value, provider)
      section, account_field, target_field = PROVIDER_FIELDS.fetch(provider) { refuse("unknown provider: #{provider}") }
      account = validate_identifier!(value.dig(section, account_field), "ownership.#{section}.#{account_field}")
      target = validate_identifier!(value.dig(section, target_field), "ownership.#{section}.#{target_field}")
      {"account" => account, "target" => target}
    end

    def exact_keys!(value, keys, at)
      refuse("#{at} must be an object") unless value.is_a?(Hash)
      refuse("#{at} has unexpected or missing fields") unless value.keys.sort == keys.sort
    end

    def validate_identifier!(value, at)
      refuse("#{at} is not configured") unless value.is_a?(String)
      refuse("#{at} is invalid") unless value.bytesize.between?(1, 256) && value == value.strip && value.match?(/\A[A-Za-z0-9][A-Za-z0-9 ._:@\/-]*\z/)
      value
    end

    def refuse(message)
      raise ValidationError, message
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |cli|
    cli.banner = "usage: ownership.rb --file PATH --provider supabase|cloudflare|elevenlabs|app-store"
    cli.on("--file PATH") { |value| options["file"] = value }
    cli.on("--provider PROVIDER") { |value| options["provider"] = value }
  end
  begin
    parser.parse!
    raise OptionParser::InvalidArgument, "unexpected positional arguments" unless ARGV.empty?
    raise OptionParser::MissingArgument, "--file" unless options["file"]
    raise OptionParser::MissingArgument, "--provider" unless options["provider"]
    ownership = IOSTemplate::Ownership.parse(File.binread(options.fetch("file")))
    puts JSON.generate(IOSTemplate::Ownership.provider_identity!(ownership, options.fetch("provider")))
  rescue OptionParser::ParseError, IOSTemplate::Ownership::ValidationError, Errno::ENOENT => error
    warn error.message
    exit 1
  end
end
