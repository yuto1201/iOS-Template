# frozen_string_literal: true

require_relative "delivery-stage"

module IOSTemplate
  # UI coverage, deliberately independent of the delivery risk profile.
  module VerificationScope
    NAMES = %w[iphone-ja targeted full].freeze
    STAGES = %w[feature adaptation release].freeze
    FULL_IDS = %w[iphone-en iphone-ja ipad-en ipad-ja].freeze
    ROWS = [
      ["iphone-en", "iPhone", "en_US", "en"],
      ["iphone-ja", "iPhone", "ja_JP", "ja"],
      ["ipad-en", "iPad", "en_US", "en"],
      ["ipad-ja", "iPad", "ja_JP", "ja"]
    ].freeze

    module_function

    def validate!(value, delivery_stage: nil)
      legacy = value.is_a?(Hash) && value.keys.sort == %w[name reason stage]
      current = value.is_a?(Hash) && value.keys.sort == %w[name reason]
      unless (legacy || current) && NAMES.include?(value["name"]) &&
             value["reason"].is_a?(String) && !value["reason"].strip.empty?
        raise ArgumentError, "Verification scope must contain exact name and nonempty reason"
      end
      if legacy
        raise ArgumentError, "legacy Verification scope cannot use targeted" if value["name"] == "targeted"
        raise ArgumentError, "Verification scope legacy stage is invalid" unless STAGES.include?(value["stage"])
        if value["stage"] != "feature" && value["name"] != "full"
          raise ArgumentError, "adaptation and release require full Verification scope"
        end
      elsif delivery_stage.nil?
        raise ArgumentError, "current Verification scope requires Delivery stage"
      else
        case delivery_stage
        when "shape"
          raise ArgumentError, "shape requires iphone-ja Verification scope" unless value["name"] == "iphone-ja"
        when "harden"
          raise ArgumentError, "harden requires targeted Verification scope" unless value["name"] == "targeted"
        when "release"
          raise ArgumentError, "release requires full Verification scope" unless value["name"] == "full"
        else
          raise ArgumentError, "unknown Delivery stage"
        end
      end
      value
    end

    def effective_name(contract)
      return "full" unless contract.key?("verificationScope")
      stage = contract.key?("deliveryStage") ? DeliveryStage.effective_name(contract) : nil
      validate!(contract["verificationScope"], delivery_stage: stage).fetch("name")
    end

    def case_ids(name)
      raise ArgumentError, "unknown Verification scope" unless NAMES.include?(name)
      raise ArgumentError, "targeted Verification scope needs explicit cases" if name == "targeted"
      name == "iphone-ja" ? ["iphone-ja"] : FULL_IDS
    end

    def rows(name, targeted_ids: nil)
      ids = name == "targeted" ? validate_targeted_case_ids!(targeted_ids) : case_ids(name)
      ROWS.select { |row| ids.include?(row.first) }
    end

    def case_ids_for_matrix(matrix)
      name = matrix_name(matrix)
      return case_ids(name) unless name == "targeted"

      validate_targeted_case_ids!(Array(matrix["cases"]).map { |entry| entry.is_a?(Hash) ? entry["id"] : nil })
    end

    def matrix_name(matrix)
      name = matrix.fetch("scope", "full")
      if name == "targeted"
        ids = Array(matrix["cases"]).map { |entry| entry.is_a?(Hash) ? entry["id"] : nil }
        validate_targeted_case_ids!(ids)
      else
        case_ids(name) # explicit null and unknown names are never legacy full
      end
      name
    end

    def validate_targeted_case_ids!(ids)
      unless ids.is_a?(Array) && !ids.empty? && ids.uniq == ids &&
             ids.all? { |id| FULL_IDS.include?(id) } && ids == FULL_IDS.select { |id| ids.include?(id) }
        raise ArgumentError, "targeted Verification cases must be a nonempty canonical subset"
      end
      ids
    end

    def case_ids_for_contract(contract)
      name = effective_name(contract)
      return case_ids(name) unless name == "targeted"

      verification = contract["verification"]
      raise ArgumentError, "targeted Verification scope requires application Verification" unless verification.is_a?(Hash)
      validate_targeted_case_ids!(Array(verification["cases"]).map { |entry| entry.is_a?(Hash) ? entry["id"] : nil })
    end

    def validate_contract!(contract)
      name = effective_name(contract)
      delivery_stage = DeliveryStage.effective_name(contract)
      profile_value = contract.fetch("deliveryProfile", {})
      raise ArgumentError, "invalid delivery profile" unless profile_value.is_a?(Hash)
      profile = profile_value.fetch("name", "strict")
      if contract.key?("verificationScope")
        raise ArgumentError, "Verification scope requires application Verification" unless contract["verification"].is_a?(Hash)
        raise ArgumentError, "fast cannot use Verification scope" if profile == "fast"
        legacy_release = contract["verificationScope"]["stage"] == "release"
        if (legacy_release || (DeliveryStage.explicit?(contract) && delivery_stage == "release")) && profile != "strict"
          raise ArgumentError, "release requires strict delivery profile"
        end
      end
      if DeliveryStage.explicit?(contract)
        if delivery_stage == "shape" && profile == "fast"
          raise ArgumentError, "shape requires standard or strict delivery profile"
        end
        if %w[shape release].include?(delivery_stage) && !contract["verification"].is_a?(Hash)
          raise ArgumentError, "#{delivery_stage} requires application Verification"
        end
        if delivery_stage == "release" && name != "full"
          raise ArgumentError, "release requires full Verification scope"
        end
        if delivery_stage == "shape" && name != "iphone-ja"
          raise ArgumentError, "shape requires iphone-ja Verification scope"
        end
        if delivery_stage == "harden" && contract["verification"].is_a?(Hash) && name != "targeted"
          raise ArgumentError, "harden application Verification requires targeted scope"
        end
      end
      if name != "full" && Array(contract["externalOperations"]).any? { |op| op.is_a?(String) && op.start_with?("appstore.") }
        raise ArgumentError, "App Store operations require full Verification scope"
      end
      if DeliveryStage.explicit?(contract) && Array(contract["externalOperations"]).any? { |op| op.is_a?(String) && op.start_with?("appstore.") } && delivery_stage != "release"
        raise ArgumentError, "App Store operations require release Delivery stage"
      end
      case_ids_for_contract(contract) if name == "targeted"
      name
    end
  end
end
