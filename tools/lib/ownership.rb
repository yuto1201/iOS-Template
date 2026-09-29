#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "yaml"

module IOSTemplate
  module Ownership
    class ValidationError < StandardError; end

    TOP_LEVEL_KEYS = %w[schemaVersion github supabase cloudflare linear vercel elevenlabs appStore].freeze
    PROVIDER_FIELDS = {
      "supabase" => ["supabase", "organizationId", "projectRef"],
      "cloudflare" => ["cloudflare", "accountId", "target"],
      "linear" => ["linear", "workspaceSlug", "teamKey"],
      "vercel" => ["vercel", "teamId", "teamSlug"],
      "elevenlabs" => ["elevenlabs", "accountId", "workspaceId"],
      "app-store" => ["appStore", "teamId", "bundleId"]
    }.freeze
    SECTION_KEYS = {
      "github" => %w[login],
      "supabase" => %w[organizationId organizationName projectRef],
      "cloudflare" => %w[accountId accountName plan target],
      "linear" => %w[workspaceSlug workspaceUrl teamKey],
      "vercel" => %w[teamId teamSlug plan projectId],
      "elevenlabs" => %w[accountId workspaceId],
      "appStore" => %w[teamId bundleId]
    }.freeze
    # App Store Connect credentials live once per Apple team (D-066). `apiKeyType` records the key kind;
    # an ownership file without it stays valid for other providers but cannot resolve the team namespace.
    APP_STORE_OPTIONAL_KEYS = %w[apiKeyType].freeze
    APP_STORE_KEY_TYPE = "team-app-manager"
    APPLE_TEAM_ID = /\A[A-Z0-9]{10}\z/

    module_function

    def parse(bytes)
      value = YAML.safe_load(bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
      exact_keys!(value, TOP_LEVEL_KEYS, "ownership")
      refuse("ownership.schemaVersion must be 2") unless value["schemaVersion"] == 2
      SECTION_KEYS.each do |section, keys|
        if section == "appStore" && value[section].is_a?(Hash) && value[section].key?("apiKeyType")
          keys += APP_STORE_OPTIONAL_KEYS
        end
        exact_keys!(value[section], keys, "ownership.#{section}")
        value.fetch(section).each do |field, entry|
          refuse("ownership.#{section}.#{field} must be a string or null") unless entry.nil? || entry.is_a?(String)
          validate_identifier!(entry, "ownership.#{section}.#{field}") unless entry.nil?
        end
      end
      refuse("ownership.github.login must be configured") if value.dig("github", "login").nil?
      key_type = value.dig("appStore", "apiKeyType")
      refuse("ownership.appStore.apiKeyType must be #{APP_STORE_KEY_TYPE}") unless key_type.nil? || key_type == APP_STORE_KEY_TYPE
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

    # Returns the Keychain and file-secret namespace of the Apple team that owns the App Store Connect key.
    def apple_team_namespace!(value)
      team = value.dig("appStore", "teamId")
      refuse("ownership.appStore.teamId is not configured") if team.nil?
      refuse("ownership.appStore.teamId must be a 10-character Apple team ID") unless team.is_a?(String) && team.match?(APPLE_TEAM_ID)
      unless value.dig("appStore", "apiKeyType") == APP_STORE_KEY_TYPE
        refuse("ownership.appStore.apiKeyType must be #{APP_STORE_KEY_TYPE}")
      end
      "apple-team-#{team}"
    end

    def exact_keys!(value, keys, at)
      refuse("#{at} must be an object") unless value.is_a?(Hash)
      refuse("#{at} has unexpected or missing fields") unless value.keys.sort == keys.sort
    end

    def validate_identifier!(value, at)
      refuse("#{at} is not configured") unless value.is_a?(String)
      refuse("#{at} is invalid") unless value.bytesize.between?(1, 256) && value == value.strip && value.match?(/\A[\p{L}\p{N}][\p{L}\p{N} ._:@\/'-]*\z/u)
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
    cli.banner = "usage: ownership.rb --file PATH --provider supabase|cloudflare|linear|vercel|elevenlabs|app-store"
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
