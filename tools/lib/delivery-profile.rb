# frozen_string_literal: true

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
    ].freeze

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
      effective_name(contract) != "fast"
    end

    def strict_operation?(operation)
      STRICT_OPERATIONS.include?(operation)
    end
  end
end
