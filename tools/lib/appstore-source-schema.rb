# frozen_string_literal: true

module IOSTemplate
  module AppStorePreparation
    # Versioned partial sources: missing/null values remain unanswered. A valid
    # shape is NOT confirmation and never supplies a default declaration.
    class SourceSchema
      PREPARATION_KEYS = %w[schemaVersion recordType build buildArtifact supportedLocales sku secondaryCategory marketingURL demoAccess ageRating contentRights exportCompliance legal iap account screenshots publicPages dispositions localizedURLs localizedPublicPages].freeze
      GROUP_KEYS = {
        "legal" => %w[eula], "account" => %w[appId bundleRegistration userAccess],
        "iap" => %w[productId productType price territories availability restore offerCodeApplicability]
      }.freeze
      APP_KEYS = %w[schemaVersion bundleId version primaryLocale platforms category copyright supportURL privacyPolicyURL reviewContactReference accountsSupported].freeze
      PRIVACY_KEYS = %w[schemaVersion collectsData tracking dataTypes thirdPartySDKs permissions accountDeletion].freeze
      AGE_BOOLEANS = %w[parentalControls ageAssurance unrestrictedWebAccess userGeneratedContent socialMedia socialMediaUnder13Disabled messagingAndChat advertising healthOrWellnessTopics gambling lootBox].freeze
      AGE_FREQUENCIES = %w[profanityOrCrudeHumor horrorOrFearThemes alcoholTobaccoOrDrugUseOrReferences medicalOrTreatmentInformation matureOrSuggestiveThemes sexualContentOrNudity sexualContentGraphicAndNudity violenceCartoonOrFantasy violenceRealistic violenceRealisticProlongedGraphicOrSadistic gunsOrOtherWeapons gamblingSimulated contests].freeze
      AGE_KEYS = %w[schemaVersion questionnaireVersion answers ageCategory ageSuitabilityURL].freeze
      MODELED_LOCALES = %w[en-US ja].freeze
      SCREENSHOT_DEVICES = %w[iphone ipad].freeze
      PUBLIC_PAGE_FIELDS = %w[supportURL privacyPolicyURL marketingURL legal.privacyPolicy legal.termsOfUse legal.eula ageRating].freeze
      DEMO_INSTRUCTIONS_SOURCE = %r{\AApp Store/review/[A-Za-z0-9][A-Za-z0-9._-]*\.md\z}
      # Reviewed against Apple's age-rating definitions and setting procedure
      # on 2026-09-09; see the preparation format documentation for source URLs.
      AGE_VERSION = "apple-age-rating-2026-09-09"

      def initialize(sources, values)
        @sources, @values = sources, values
        @documents = {}
      end

      def document(path)
        @documents.fetch(path) { @documents[path] = @sources.document(path) }
      end

      def object?(value, keys, exact: true)
        value.is_a?(Hash) && (exact ? value.keys.sort == keys.sort : (value.keys - keys).empty?)
      end

      def boolean?(value)
        value.equal?(true) || value.equal?(false)
      end

      def text?(value)
        value.is_a?(String) && !value.strip.empty? && value.bytesize <= 65_536 && !value.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/)
      end

      def string_list_error(value, allow_empty: false)
        return "invalid-field-type" unless value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) }
        return "invalid-field-value" unless value.length <= 256 && (allow_empty || !value.empty?) && value.uniq == value && value.all? { |entry| text?(entry) }
        nil
      end

      def preparation_error
        value = document(VALUES)
        return nil if value.nil? && @sources.error(VALUES)
        return "invalid-preparation-schema" unless object?(value, PREPARATION_KEYS, exact: false) && value["schemaVersion"] == 1 && value["recordType"] == "appstore-preparation-sources"
        %w[localizedURLs localizedPublicPages].each do |key|
          next unless value.key?(key)
          group = value[key]
          return "invalid-localized-url-schema" unless object?(group, MODELED_LOCALES, exact: false) && group.values.all? do |entries|
            object?(entries, %w[supportURL privacyPolicyURL marketingURL], exact: false)
          end
        end
        if value.key?("screenshots")
          screenshots = value["screenshots"]
          return "invalid-screenshot-source-schema" unless object?(screenshots, MODELED_LOCALES, exact: false) && screenshots.values.all? do |devices|
            object?(devices, SCREENSHOT_DEVICES, exact: false)
          end
        end
        if value.key?("publicPages")
          return "invalid-public-page-schema" unless object?(value["publicPages"], PUBLIC_PAGE_FIELDS, exact: false)
        end
        nil
      end

      def structure_error(path, anchor)
        if path == VALUES
          error = preparation_error
          return error if error
          group = anchor.split(".").first
          value = document(VALUES)
          return nil unless value.is_a?(Hash) && value.key?(group) && !value[group].nil?
          if GROUP_KEYS.key?(group)
            return "invalid-preparation-field-schema" unless object?(value[group], GROUP_KEYS[group], exact: false)
          end
        elsif path == APP || path == PRIVACY
          value = document(path)
          return nil if value.nil? && @sources.error(path)
          keys = path == APP ? APP_KEYS : PRIVACY_KEYS
          return "invalid-source-schema" unless object?(value, keys, exact: false) && value["schemaVersion"] == 1
          return "invalid-source-schema" if path == APP && value.key?("accountsSupported") && !boolean?(value["accountsSupported"])
        elsif path.start_with?("App Store/metadata/localizations/")
          value = document(path)
          return nil if value.nil? && @sources.error(path)
          return "invalid-source-schema" unless object?(value, %w[name subtitle description keywords promotionalText], exact: false)
        end
        nil
      end

      def age_error(value)
        return "invalid-questionnaire-schema" unless object?(value, AGE_KEYS) && value["schemaVersion"] == 1 && value["answers"].is_a?(Hash)
        return "unsupported-questionnaire-version" unless value["questionnaireVersion"] == AGE_VERSION
        answers = value["answers"]
        keys = AGE_BOOLEANS + AGE_FREQUENCIES
        return "invalid-questionnaire-schema" unless (answers.keys - keys).empty?
        return "questionnaire-unanswered" unless (keys - answers.keys).empty? && answers.values.none?(&:nil?)
        return "invalid-questionnaire-answer" unless AGE_BOOLEANS.all? { |key| boolean?(answers[key]) } && AGE_FREQUENCIES.all? { |key| %w[NONE INFREQUENT FREQUENT].include?(answers[key]) }
        return "inconsistent-questionnaire-answers" if answers["socialMediaUnder13Disabled"] && !answers["socialMedia"]
        category = value["ageCategory"]
        return "invalid-questionnaire-schema" unless object?(category, %w[choice value])
        return "questionnaire-unanswered" if category["choice"].nil?
        case category["choice"]
        when "not-applicable"
          return "invalid-questionnaire-answer" unless category["value"].nil?
        when "made-for-kids"
          return "questionnaire-unanswered" if category["value"].nil?
          return "invalid-questionnaire-answer" unless %w[5-and-under 6-8 9-11].include?(category["value"])
        when "higher-rating"
          return "questionnaire-unanswered" if category["value"].nil?
          return "invalid-questionnaire-answer" unless %w[9+ 13+ 16+ 18+].include?(category["value"])
        else return "invalid-questionnaire-answer"
        end
        # Report adds the public proof class when this optional destination is
        # supplied. Syntax alone never proves publication or approved content.
        return PublicEvidence.url_error(value["ageSuitabilityURL"]) unless value["ageSuitabilityURL"].nil?
        nil
      end

      def rights_error(value)
        return "invalid-questionnaire-schema" unless object?(value, %w[schemaVersion containsThirdPartyContent hasNecessaryRights rightsReferences]) && value["schemaVersion"] == 1
        return "questionnaire-unanswered" if value["containsThirdPartyContent"].nil?
        return "invalid-questionnaire-answer" unless boolean?(value["containsThirdPartyContent"]) && value["rightsReferences"].is_a?(Array)
        if value["containsThirdPartyContent"]
          return "content-rights-unresolved" unless value["hasNecessaryRights"] == true && !value["rightsReferences"].empty? && value["rightsReferences"].length <= 100 && value["rightsReferences"].uniq == value["rightsReferences"] &&
            value["rightsReferences"].all? { |reference| reference.is_a?(String) && reference.match?(%r{\Arights://[a-zA-Z0-9/_-]{1,256}\z}) }
        else
          return "inconsistent-questionnaire-answers" unless value["hasNecessaryRights"].nil? && value["rightsReferences"] == []
        end
        nil
      end

      def export_error(value)
        keys = %w[schemaVersion usesEncryption encryptionTypes distributedInFrance documentationRequired determinationReference documents]
        return "invalid-questionnaire-schema" unless object?(value, keys) && value["schemaVersion"] == 1
        booleans = %w[usesEncryption distributedInFrance documentationRequired]
        return "questionnaire-unanswered" if booleans.any? { |key| value[key].nil? }
        return "invalid-questionnaire-answer" unless booleans.all? { |key| boolean?(value[key]) } && value["encryptionTypes"].is_a?(Array) && value["documents"].is_a?(Array)
        types = value["encryptionTypes"]
        return "invalid-questionnaire-answer" unless types.uniq == types && (types - %w[apple-os-only standard proprietary]).empty?
        return "inconsistent-questionnaire-answers" unless value["usesEncryption"] == !types.empty?
        reference = value["determinationReference"]
        return "export-determination-unresolved" unless reference.is_a?(String) && reference.match?(%r{\Auser-approval://[a-z0-9-]{1,128}\z})
        docs = value["documents"]
        return "invalid-questionnaire-answer" unless docs.length <= 10 && docs.all? { |doc| object?(doc, %w[kind status reference]) && %w[ccats france].include?(doc["kind"]) && doc["status"] == "approved" && doc["reference"].is_a?(String) && doc["reference"].match?(%r{\Aasc://apps/[0-9]+/encryption/[A-Za-z0-9_-]+\z}) }
        return "invalid-questionnaire-answer" unless docs.map { |doc| doc["kind"] }.uniq.length == docs.length
        return "export-documentation-unresolved" if value["documentationRequired"] ? docs.empty? : !docs.empty?
        return "export-documentation-unresolved" if types.include?("proprietary") && !docs.any? { |doc| doc["kind"] == "ccats" }
        return "export-documentation-unresolved" if value["distributedInFrance"] && (types & %w[standard proprietary]).any? && !docs.any? { |doc| doc["kind"] == "france" }
        # The developer's explicit determination and actual documentation are
        # still reviewed by derive/user proofs; this never answers legal facts.
        nil
      end

      def iap_error(id, value)
        ids = @values.call(VALUES, "iap.productId")
        if id == "iap.productId"
          candidates = ids.is_a?(String) ? [ids] : ids
          error = string_list_error(candidates)
          return error if error
          return "invalid-field-value" unless candidates.all? { |item| item.match?(/\A[A-Za-z0-9._-]{1,255}\z/) }
          return nil
        end
        if ids.is_a?(Array)
          return "invalid-field-value" if string_list_error(ids)
          return "invalid-field-type" unless value.is_a?(Hash)
          return "invalid-field-value" unless value.keys.sort == ids.sort
          return value.values.map { |entry| iap_scalar_error(id, entry) }.compact.first
        end
        iap_scalar_error(id, value)
      end

      def iap_scalar_error(id, value)
        case id
        when "iap.price"
          return "invalid-field-type" unless object?(value, %w[amount currency]) && value.values.all? { |entry| entry.is_a?(String) }
          return "invalid-field-value" unless value["amount"].match?(/\A(?:0|[1-9][0-9]*)(?:\.[0-9]{1,3})?\z/) && value["currency"].match?(/\A[A-Z]{3}\z/)
        when "iap.territories"
          error = string_list_error(value)
          return error if error
          return "invalid-field-value" unless value.all? { |entry| entry.match?(/\A[A-Z]{2,3}\z/) }
        when "iap.restore" then return "invalid-field-type" unless boolean?(value)
        else
          return "invalid-field-type" unless value.is_a?(String)
          allowed = {"iap.productType" => AccountEvidence::TYPES, "iap.availability" => %w[available unavailable], "iap.offerCodeApplicability" => %w[applicable not-applicable]}.fetch(id)
          return "invalid-field-value" unless allowed.include?(value)
        end
        nil
      end

      def value_error(id, value)
        return nil if value.nil?
        return iap_error(id, value) if id.start_with?("iap.")
        case id
        when "ageRating" then return age_error(value)
        when "contentRights" then return rights_error(value)
        when "exportCompliance" then return export_error(value)
        when "platforms", "deviceSupport"
          return "invalid-field-type" unless object?(value, %w[iphone ipad]) && value.values.all? { |entry| boolean?(entry) }
          return "invalid-field-value" unless value.values.any?
        when "supportedLocales", "privacy.dataTypes", "privacy.permissions", "privacy.thirdPartySDKs"
          error = string_list_error(value, allow_empty: id.start_with?("privacy."))
          return error if error
          return "invalid-field-value" if id == "supportedLocales" && value.sort != MODELED_LOCALES.sort
        when "privacy.collectsData", "privacy.tracking"
          return "invalid-field-type" unless boolean?(value)
        when "privacy.accountDeletion"
          return "invalid-field-type" unless object?(value, %w[required reason]) && boolean?(value["required"]) && text?(value["reason"])
        when "demoAccess"
          return "invalid-field-type" unless object?(value, %w[required credentialsReference instructionsSource]) && boolean?(value["required"])
          if value["required"]
            return "invalid-field-value" unless value["credentialsReference"].is_a?(String) && value["credentialsReference"].match?(%r{\Akeychain://[A-Za-z0-9/_-]+\z}) &&
              value["instructionsSource"].is_a?(String) && value["instructionsSource"].match?(DEMO_INSTRUCTIONS_SOURCE)
          else
            return "invalid-field-value" unless value["credentialsReference"].nil? && value["instructionsSource"].nil?
          end
        when "legal.eula"
          return "invalid-field-type" unless object?(value, %w[choice url textSource]) && %w[standard custom].include?(value["choice"]) && text?(value["url"]) && value["textSource"].is_a?(Hash)
        when "screenshots.iphone", "screenshots.ipad"
          return "invalid-field-type" unless value.is_a?(Hash)
          return "invalid-field-value" unless object?(value, %w[status manifest review requirements]) && value["status"] == "adopted" && %w[manifest review requirements].all? { |key| value[key].is_a?(Hash) }
        else
          return "invalid-field-type" unless value.is_a?(String)
          return "invalid-field-value" unless text?(value)
          return "invalid-field-value" if %w[version build].include?(id) && !value.match?(/\A[0-9]+(?:\.[0-9]+){0,2}\z/)
          return "invalid-field-value" if id == "reviewContactReference" && !value.match?(%r{\Akeychain://[A-Za-z0-9/_-]+\z})
        end
        nil
      end

      def reasons(id, path, anchor, value)
        [structure_error(path, anchor), value_error(id, value)].compact.uniq
      end
    end
  end
end
