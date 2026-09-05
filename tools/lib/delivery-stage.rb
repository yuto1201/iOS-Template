# frozen_string_literal: true

module IOSTemplate
  # Delivery stage controls when expensive quality evidence becomes mandatory.
  # It is deliberately independent from workflow state and delivery risk.
  module DeliveryStage
    NAMES = %w[shape harden release].freeze

    module_function

    def validate!(value)
      unless value.is_a?(Hash) && value.keys.sort == %w[name reason timeBudgetMinutes]
        raise ArgumentError, "deliveryStage must contain exact name, reason, and timeBudgetMinutes"
      end
      raise ArgumentError, "deliveryStage.name is invalid" unless NAMES.include?(value["name"])
      unless value["reason"].is_a?(String) && !value["reason"].strip.empty?
        raise ArgumentError, "deliveryStage.reason is required"
      end
      unless value["timeBudgetMinutes"].is_a?(Integer) && value["timeBudgetMinutes"].positive?
        raise ArgumentError, "deliveryStage.timeBudgetMinutes must be a positive integer"
      end
      value
    end

    def explicit?(contract)
      contract.key?("deliveryStage")
    end

    # Missing means a sealed pre-migration contract. It keeps the former
    # release-level gates without changing the canonical snapshot bytes.
    def effective_name(contract)
      return "release" unless explicit?(contract)

      validate!(contract.fetch("deliveryStage")).fetch("name")
    end

    def visual_required?(contract)
      return true unless explicit?(contract)
      return true if effective_name(contract) == "release"
      return false if effective_name(contract) == "shape"

      Array(contract.dig("verification", "acceptanceMappings")).any? do |mapping|
        Array(mapping["checks"]).any? { |check| check.is_a?(String) && check.start_with?("visual:") }
      end
    end
  end
end
