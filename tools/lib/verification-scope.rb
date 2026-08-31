# frozen_string_literal: true

module IOSTemplate
  # UI coverage, deliberately independent of the delivery risk profile.
  module VerificationScope
    NAMES = %w[iphone-ja full].freeze
    STAGES = %w[feature adaptation release].freeze
    FULL_IDS = %w[iphone-en iphone-ja ipad-en ipad-ja].freeze
    ROWS = [
      ["iphone-en", "iPhone", "en_US", "en"],
      ["iphone-ja", "iPhone", "ja_JP", "ja"],
      ["ipad-en", "iPad", "en_US", "en"],
      ["ipad-ja", "iPad", "ja_JP", "ja"]
    ].freeze

    module_function

    def validate!(value)
      unless value.is_a?(Hash) && value.keys.sort == %w[name reason stage] &&
             NAMES.include?(value["name"]) && STAGES.include?(value["stage"]) &&
             value["reason"].is_a?(String) && !value["reason"].strip.empty?
        raise ArgumentError, "Verification scope must contain exact name, stage, and nonempty reason"
      end
      if value["stage"] != "feature" && value["name"] != "full"
        raise ArgumentError, "adaptation and release require full Verification scope"
      end
      value
    end

    def effective_name(contract)
      return "full" unless contract.key?("verificationScope")
      validate!(contract["verificationScope"]).fetch("name")
    end

    def case_ids(name)
      raise ArgumentError, "unknown Verification scope" unless NAMES.include?(name)
      name == "iphone-ja" ? ["iphone-ja"] : FULL_IDS
    end

    def rows(name)
      ids = case_ids(name)
      ROWS.select { |row| ids.include?(row.first) }
    end

    def matrix_name(matrix)
      name = matrix.fetch("scope", "full")
      case_ids(name) # explicit null and unknown names are never legacy full
      name
    end

    def validate_contract!(contract)
      name = effective_name(contract)
      if contract.key?("verificationScope")
        raise ArgumentError, "Verification scope requires application Verification" unless contract["verification"].is_a?(Hash)
        profile_value = contract.fetch("deliveryProfile", {})
        raise ArgumentError, "invalid delivery profile" unless profile_value.is_a?(Hash)
        profile = profile_value.fetch("name", "strict")
        raise ArgumentError, "fast cannot use Verification scope" if profile == "fast"
        if contract["verificationScope"]["stage"] == "release" && profile != "strict"
          raise ArgumentError, "release requires strict delivery profile"
        end
      end
      if name != "full" && Array(contract["externalOperations"]).any? { |op| op.is_a?(String) && op.start_with?("appstore.") }
        raise ArgumentError, "App Store operations require full Verification scope"
      end
      name
    end
  end
end
