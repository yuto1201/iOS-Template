# frozen_string_literal: true

module IOSTemplate
  module AppStorePreparation
    class AccountEvidence
      OBSERVATION_KEYS = %w[schemaVersion recordType source observedAt environment status identity fieldId locale section sourceFingerprint valueDigest remoteReference products].freeze
      IDENTITY_KEYS = %w[teamId appId bundleId platform version].freeze
      PRODUCT_KEYS = %w[appleId productId productType price territories availability restore offerCodeApplicability].freeze
      TYPES = %w[CONSUMABLE NON_CONSUMABLE AUTO_RENEWABLE_SUBSCRIPTION NON_RENEWING_SUBSCRIPTION].freeze

      def initialize(sources, values, now, validator, registration)
        @sources, @values, @now, @validator, @registration = sources, values, now, validator, registration
      end

      def self.canonical(value)
        case value
        when Hash then value.keys.sort.each_with_object({}) { |key, result| result[key] = canonical(value[key]) }
        when Array then value.map { |entry| canonical(entry) }
        else value
        end
      end

      def self.value_digest(value)
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(value)))}"
      end

      def expected_identity
        existing = @registration["existingApp"]
        return nil unless @registration["status"] == "matched-observation" && existing.is_a?(Hash)
        existing.merge("platform" => "IOS", "version" => @values.call(APP, "version"))
      end

      def current_value(row)
        source = row.fetch("sources").first
        @values.call(source["path"], source["anchor"])
      end

      def product_error(row, products)
        return "unexpected-product-observation" unless row["fieldId"].start_with?("iap.") || products == []
        return nil unless row["fieldId"].start_with?("iap.")
        expected_ids = @values.call(VALUES, "iap.productId")
        single = expected_ids.is_a?(String)
        ids = single ? [expected_ids] : expected_ids
        return "iap-product-source-unresolved" unless ids.is_a?(Array) && !ids.empty? && ids.length <= 100 &&
          ids.all? { |id| id.is_a?(String) && id.match?(/\A[A-Za-z0-9._-]{1,255}\z/) } && ids.uniq == ids
        return "production-iap-unobserved" unless products.is_a?(Array) && !products.empty? && products.length <= 100
        products.each do |product|
          return "invalid-production-iap" unless product.is_a?(Hash) && product.keys.sort == PRODUCT_KEYS.sort &&
            product["appleId"].is_a?(String) && product["appleId"].match?(/\A[0-9]+\z/) &&
            product["productId"].is_a?(String) && TYPES.include?(product["productType"])
          price = product["price"]
          return "unverified-production-price" unless price.is_a?(Hash) && price.keys.sort == %w[amount currency] &&
            price["currency"].is_a?(String) && price["currency"].match?(/\A[A-Z]{3}\z/) &&
            price["amount"].is_a?(String) && price["amount"].match?(/\A(?:0|[1-9][0-9]*)(?:\.[0-9]{1,3})?\z/)
          territories = product["territories"]
          return "unverified-production-territories" unless territories.is_a?(Array) && !territories.empty? && territories.uniq == territories &&
            territories.all? { |territory| territory.is_a?(String) && territory.match?(/\A[A-Z]{2,3}\z/) }
          return "production-iap-unavailable" unless product["availability"] == "available"
          return "unverified-production-restore" unless [true, false].include?(product["restore"])
          return "unverified-production-offers" unless %w[applicable not-applicable].include?(product["offerCodeApplicability"])
        end
        return "production-iap-identity-mismatch" unless products.map { |product| product["productId"] }.sort == ids.sort &&
          products.map { |product| product["appleId"] }.uniq.length == products.length
        products.each do |product|
          %w[productType price territories availability restore offerCodeApplicability].each do |attribute|
            declared = @values.call(VALUES, "iap.#{attribute}")
            declared = declared[product["productId"]] if !single && declared.is_a?(Hash)
            return "production-iap-context-mismatch" if !declared.nil? && declared != product[attribute]
          end
        end
        field = row["fieldId"].delete_prefix("iap.")
        observed_value = if field == "productId"
                           expected_ids
                         elsif single
                           products.first[field]
                         else
                           products.each_with_object({}) { |product, values| values[product["productId"]] = product[field] }
                         end
        return "production-iap-value-mismatch" unless observed_value == current_value(row)
        nil
      end

      def check(row, proof)
        identity = expected_identity
        return "account-identity-unconfirmed" unless identity
        reference = proof["observation"]
        return "invalid-account-observation-reference" unless @validator.descriptor_valid?(reference) && reference["anchor"] == "document" &&
          reference["path"].match?(%r{\A\.artifacts/appstore-preparation/account-fields/[a-z0-9-]+\.json\z})
        observation = @sources.document(reference["path"])
        return "invalid-account-field-observation" unless observation.is_a?(Hash) && observation.keys.sort == OBSERVATION_KEYS.sort &&
          observation["schemaVersion"] == 1 && observation["recordType"] == "appstore-account-field-observation" &&
          %w[synthetic-fixture app-store-connect].include?(observation["source"])
        return "stale-account-field-observation" unless @validator.fresh_source(reference)
        return "account-field-identity-mismatch" unless observation["identity"].is_a?(Hash) && observation["identity"].keys.sort == IDENTITY_KEYS.sort && observation["identity"] == identity
        return "account-field-scope-mismatch" unless observation["fieldId"] == row["fieldId"] && observation["locale"] == row["locale"] && observation["section"] == row["section"]
        return "non-production-account-observation" unless observation["environment"] == "production"
        return "account-field-unknown" unless observation["status"] == "observed"
        return "stale-account-field-source" unless observation["sourceFingerprint"] == row["sourceFingerprint"]
        value = current_value(row)
        return "account-field-value-mismatch" if value.nil? || observation["valueDigest"] != self.class.value_digest(value)
        remote = observation["remoteReference"]
        return "invalid-account-remote-reference" unless remote.is_a?(String) && remote.match?(%r{\Aasc://apps/#{Regexp.escape(identity['appId'])}/[a-z0-9/-]+\z}) && remote.index("//", 6).nil?
        timestamp = observation["observedAt"]
        return "invalid-account-field-time" unless timestamp.is_a?(String) && timestamp.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
        observed = Time.iso8601(timestamp)
        age = @now - observed
        return "stale-account-field-observation" unless observed.utc.iso8601 == timestamp && age >= 0 && age <= 3600 && observed <= Time.iso8601(proof["checkedAt"])
        error = product_error(row, observation["products"])
        return error if error
        return "account-observer-evidence-missing" unless proof["reviewer"] == "account-inspector" && proof["decision"] == "observed" && proof["reference"].match?(%r{\Aaccount-observation://[a-z0-9-]{1,128}\z})
        row["evidenceSources"] << reference
        row["observationOrigins"] << observation["source"]
        nil
      rescue ArgumentError, InvalidInput
        "invalid-account-field-observation"
      end
    end
  end
end
