# frozen_string_literal: true

module IOSTemplate
  module AppStorePreparation
    # Confirmation is computed, not read from a caller's "state: confirmed" flag.
    # Receipts attest to reviewed bytes; they never grant external-operation or
    # release authority. User receipts must originate in an actual user decision.
    class Confirmation
      INDEX = ".artifacts/appstore-preparation/confirmations.json"
      INDEX_KEYS = %w[schemaVersion recordType records].freeze
      RECORD_KEYS = %w[fieldId locale proofs remoteReadback].freeze
      PROOF_KEYS = %w[schemaVersion recordType kind fieldId locale section sourceFingerprint checkedAt reviewer decision reference basis].freeze
      DESCRIPTOR_KEYS = %w[path anchor revision digest].freeze
      DIGEST = /\Asha256:[0-9a-f]{64}\z/

      def initialize(sources, now, values: nil, registration: {}, protected_input: nil)
        @sources, @now, @values, @registration = sources, now, values, registration
        @protected_input = protected_input
      end

      def fingerprint(sources)
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(sources))}"
      end

      def record_key(record)
        [record["fieldId"], record["locale"]]
      end

      def descriptor_valid?(descriptor)
        descriptor.is_a?(Hash) && descriptor.keys.sort == DESCRIPTOR_KEYS.sort &&
          descriptor["path"].is_a?(String) && descriptor["anchor"].is_a?(String) &&
          !descriptor["anchor"].empty? && descriptor["anchor"].bytesize <= 256 &&
          descriptor["anchor"].match?(/\A[^\x00-\x1f\x7f@]+\z/) &&
          (descriptor["revision"].nil? || descriptor["revision"].is_a?(String) && descriptor["revision"].match?(/\A[0-9a-f]{40}\z/)) &&
          descriptor["digest"].is_a?(String) && descriptor["digest"].match?(DIGEST)
      end

      def fresh_source(descriptor)
        return false unless descriptor_valid?(descriptor)
        path = descriptor["path"]
        @sources.path!(path)
        return false if path.include?("@")
        return false if path.end_with?(".json", ".yml", ".yaml") && @sources.document(path).nil?
        current = @sources.descriptor(path, descriptor["anchor"])
        return false unless current == descriptor
        bytes = @sources.read(path)
        return false unless bytes && !@sources.sensitive_document?(bytes)
        if descriptor["anchor"] != "document"
          return false unless path.end_with?(".md") && bytes.lines.any? { |line| line.sub(/\r?\n\z/, "") == descriptor["anchor"] && line.start_with?("#") }
        end
        true
      rescue InvalidInput
        false
      end

      def proof(row, kind, descriptor)
        return "#{kind}-evidence-missing" unless descriptor
        return "invalid-#{kind}-evidence-reference" unless descriptor_valid?(descriptor) &&
          descriptor["anchor"] == "document" && descriptor["path"].match?(%r{\A\.artifacts/appstore-preparation/proofs/[a-z0-9-]+\.json\z})
        document = @sources.document(descriptor["path"])
        expected_keys = %w[public account].include?(kind) ? PROOF_KEYS + ["observation"] : PROOF_KEYS
        return "invalid-#{kind}-evidence" unless document.is_a?(Hash) && document.keys.sort == expected_keys.sort &&
          document["schemaVersion"] == 1 && document["recordType"] == "appstore-preparation-proof" &&
          document["kind"] == kind && document["fieldId"] == row["fieldId"] &&
          document["locale"] == row["locale"] && document["section"] == row["section"]
        return "stale-#{kind}-evidence" unless fresh_source(descriptor) && document["sourceFingerprint"] == row["sourceFingerprint"]
        timestamp = document["checkedAt"]
        return "invalid-#{kind}-evidence-time" unless timestamp.is_a?(String) && timestamp.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
        checked_at = Time.iso8601(timestamp)
        return "invalid-#{kind}-evidence-time" unless checked_at.utc.iso8601 == timestamp && checked_at <= @now
        basis = document["basis"]
        return "invalid-#{kind}-evidence-basis" unless basis.is_a?(Array) && basis.length.between?(1, 32) &&
          basis.all? { |entry| descriptor_valid?(entry) } && basis.map { |entry| [entry["path"], entry["anchor"]] }.uniq.length == basis.length
        return "stale-#{kind}-evidence-basis" unless basis.all? { |entry| fresh_source(entry) }
        reference = document["reference"]
        return "invalid-#{kind}-evidence-reference" unless reference.is_a?(String)
        case kind
        when "derive"
          return "derive-review-missing" unless %w[codex claude user].include?(document["reviewer"]) && document["decision"] == "reviewed" && reference.match?(%r{\Areview://[a-z0-9-]{1,128}\z})
          return "derive-spec-basis-missing" unless basis.any? { |entry| entry["path"].start_with?("specs/") && entry["path"].end_with?(".md") }
          return "derive-implementation-basis-missing" unless basis.any? { |entry| entry["path"].end_with?(".swift", ".pbxproj", ".xcstrings", ".plist", ".xcconfig") && !entry["path"].start_with?("tools/", ".artifacts/") }
        when "user"
          return "user-approval-missing" unless document["reviewer"] == "user" && document["decision"] == "approved" && reference.match?(%r{\Auser-approval://[a-z0-9-]{1,128}\z})
        when "public"
          error = PublicEvidence.new(@sources, @values, @now, self).check(row, document)
          return error if error
        when "account"
          error = AccountEvidence.new(@sources, @values, @now, self, @registration).check(row, document)
          return error if error
        else
          return "#{kind}-evidence-not-validated"
        end
        row["evidenceSources"].concat([descriptor] + basis)
        nil
      rescue ArgumentError, InvalidInput
        "invalid-#{kind}-evidence"
      end

      def apply(rows)
        rows.each do |row|
          row["sourceFingerprint"] = fingerprint(row.fetch("sources"))
          row["evidenceSources"] = []
          row["observationOrigins"] = row.fetch("artifactOrigins", []).dup
        end
        index = @sources.document(INDEX)
        return rows if index.nil? && @sources.error(INDEX) == "missing-source"
        valid = index.is_a?(Hash) && index.keys.sort == INDEX_KEYS.sort && index["schemaVersion"] == 1 &&
          index["recordType"] == "appstore-preparation-confirmations" && index["records"].is_a?(Array) && index["records"].length <= 256
        known_keys = rows.map { |row| record_key(row) }
        if valid
          records = index["records"]
          valid = records.all? do |record|
            record.is_a?(Hash) && record.keys.sort == RECORD_KEYS.sort && known_keys.include?(record_key(record)) &&
              record["proofs"].is_a?(Hash) && (record["proofs"].keys - %w[derive user public account]).empty?
          end && records.map { |record| record_key(record) }.uniq.length == records.length
        end
        unless valid
          rows.each { |row| row["reasons"] << "invalid-confirmation-index" }
          return rows
        end
        index["records"].each do |record|
          row = rows.find { |entry| record_key(entry) == record_key(record) }
          errors = row["classification"].map { |kind| proof(row, kind, record["proofs"][kind]) }.compact
          row["reasons"].delete("confirmation-missing")
          row["reasons"].concat(errors)
          row["reasons"].uniq!
          if row["plannedState"] == "deferred" && errors.empty?
            row["state"] = "deferred"
            row["reasons"] << "user-deferred"
            row["unblockConditions"] = ["resolve-deferred-field-and-provide-current-confirmation-evidence"]
          elsif row["reasons"].empty?
            row["state"] = row["plannedState"] == "not-applicable" ? "not-applicable" : "confirmed"
            row["unblockConditions"] = []
          end
          row["evidenceSources"].uniq!
        end
        # Finish all local confirmations before examining any multi-field save.
        # Each row is evaluated against that immutable confirmation snapshot;
        # iteration order cannot let an earlier readback promote another row.
        confirmed_keys = rows.select { |row| row["state"] == "confirmed" }.map { |row| record_key(row) }
        reader = ReadbackEvidence.new(@sources, @values, @now, self, @registration, rows, confirmed_keys, protected_input: @protected_input)
        index["records"].each do |record|
          next if record["remoteReadback"].nil?
          row = rows.find { |entry| record_key(entry) == record_key(record) }
          error = row["plannedState"] ? "remote-readback-disposition-conflict" : reader.check(row, record["remoteReadback"])
          if error
            row["state"] = "draft"
            row["reasons"] << error
            row["unblockConditions"] = [case error
                                       when "not-a-remote-metadata-field" then "remove-inapplicable-save-claim-and-retain-local-source-confirmation"
                                       when "remote-form-adapter-unavailable" then "provide-resource-specific-readback-adapter-and-evidence"
                                       else "provide-current-authorized-save-and-matching-readback-evidence"
                                       end]
          elsif row["state"] == "confirmed"
            row["state"] = "remote-saved"
          end
          row["evidenceSources"].uniq!
        end
        rows
      end
    end
  end
end
