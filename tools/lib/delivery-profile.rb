# frozen_string_literal: true

require "json"
require "time"
require_relative "delivery-stage"

module IOSTemplate
  module DeliveryProfile
    NAMES = %w[fast standard strict].freeze
    STRICT_OPERATIONS = %w[
      supabase.apply_migrations
      cloudflare.deploy
      elevenlabs.generate_audio
      elevenlabs.process_media
      appstore.upload_build
      appstore.update_metadata
      appstore.submit_review
      appstore.distribute_testflight
    ].freeze
    RELEASE_DISPOSITION_CUTOVER = Time.iso8601("2026-09-15T11:00:00Z").freeze
    RELEASE_PHASE_PREFIX = "Release-phase binding:"

    module_function

    def effective_name(contract)
      profile = contract["deliveryProfile"]
      return "strict" if profile.nil?
      raise ArgumentError, "deliveryProfile must be an object" unless profile.is_a?(Hash)
      raise ArgumentError, "deliveryProfile has unexpected fields" unless profile.keys.sort == %w[name reason]
      name = profile["name"]
      reason = profile["reason"]
      raise ArgumentError, "deliveryProfile.name is invalid" unless NAMES.include?(name)
      raise ArgumentError, "deliveryProfile.reason is required" unless reason.is_a?(String) && !reason.strip.empty?
      name
    end

    def review_required?(contract)
      profile = effective_name(contract)
      return true if release_disposition_required?(contract)
      return true if profile == "strict"
      # Preserve pre-migration profile behavior: legacy standard required
      # review and legacy fast did not. Explicit stages use the new rule.
      return profile == "standard" unless DeliveryStage.explicit?(contract)

      DeliveryStage.effective_name(contract) == "release"
    end

    def release_disposition_required?(contract)
      criteria = contract["acceptanceCriteria"]
      return false unless criteria.is_a?(Array)
      declarations = criteria.select do |criterion|
        criterion.is_a?(Hash) && criterion["text"].is_a?(String) &&
          criterion["text"].start_with?(RELEASE_PHASE_PREFIX)
      end
      return false if declarations.empty?
      # Keep legacy contracts dependency-light, but use the canonical binding
      # parser whenever a declaration exists so policy and phase gates cannot
      # disagree about malformed or noncanonical bytes.
      require_relative "workflow-release-phase"
      binding = ReleasePhase.binding_from_contract!(contract)
      return false unless binding["workKind"] == "implementation" && [5, 6].include?(binding["phase"])
      Time.iso8601(contract.fetch("fetchedAt")) >= RELEASE_DISPOSITION_CUTOVER
    rescue ReleasePhase::ValidationError, KeyError, ArgumentError => error
      raise ArgumentError, "release disposition policy is invalid: #{error.message}"
    end

    def strict_operation?(operation)
      STRICT_OPERATIONS.include?(operation)
    end
  end
end
