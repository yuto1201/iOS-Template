# frozen_string_literal: true

require_relative "issue-contract"

module IOSTemplate
  module AppStorePreparation
    # Explicit transient observations, never source files or reusable value
    # hashes. The caller must provide an already-authorized collector's pipe;
    # this evaluator does not open Keychain, authenticate, or fetch anything.
    class ProtectedFormInput
      RECORD_KEYS = %w[reference source identity sourceRevision section locale intentDigest savedAt observedAt references baseline readback].freeze
      BINDINGS = %w[source identity sourceRevision section locale intentDigest savedAt observedAt].freeze
      REFERENCE = %r{\Aprotected-observation://[a-z0-9-]{1,128}\z}
      SECRET_REFERENCE = %r{\Akeychain://[a-zA-Z0-9/_-]+\z}

      def self.read(input)
        raise InvalidInput, "protected-input-requires-pipe" unless input.stat.pipe?
        bytes = input.read(1_000_001)
        input.close
        raise InvalidInput, "invalid-protected-input" unless bytes && bytes.bytesize <= 1_000_000
        bytes.force_encoding(Encoding::UTF_8)
        raise InvalidInput, "invalid-protected-input" unless bytes.valid_encoding? && !bytes.include?("\0")
        document = JSON.parse(bytes, object_class: UniqueObject)
        raise InvalidInput, "invalid-protected-input" unless document.is_a?(Hash) &&
          document.keys.sort == %w[observations recordType schemaVersion] && document["schemaVersion"] == 1 &&
          document["recordType"] == "appstore-protected-form-input" && document["observations"].is_a?(Array) &&
          document["observations"].length.between?(1, 16)
        records = document["observations"]
        raise InvalidInput, "invalid-protected-input" unless records.all? do |record|
          record.is_a?(Hash) && record.keys.sort == RECORD_KEYS.sort &&
            record["reference"].is_a?(String) && record["reference"].match?(REFERENCE)
        end
        raise InvalidInput, "duplicate-protected-input" unless records.map { |record| record["reference"] }.uniq.length == records.length
        # Reject non-finite numbers before comparison; never let a serializer
        # exception print a diagnostic containing transient observation data.
        IssueContract.canonical_json(document)
        new(records)
      rescue JSON::ParserError, JSON::GeneratorError, IOError, SystemCallError
        raise InvalidInput, "invalid-protected-input"
      end

      def initialize(records)
        @records = records
      end

      def complete_review_value?(field, value)
        return true unless %w[reviewContactReference demoAccess].include?(field)
        return false unless value.is_a?(Hash)
        if field == "reviewContactReference"
          return value.keys.sort == %w[contactEmail contactFirstName contactLastName contactPhone] &&
            value.values.all? { |entry| entry.is_a?(String) && !entry.strip.empty? }
        end
        return false unless value.keys.sort == %w[demoAccountName demoAccountPassword demoAccountRequired] &&
          [true, false].include?(value["demoAccountRequired"])
        %w[demoAccountName demoAccountPassword].all? do |key|
          item = value[key]
          value["demoAccountRequired"] ? item.is_a?(String) && !item.strip.empty? : item.nil? || item.is_a?(String)
        end
      end

      def check(receipt, forms, fields)
        record = @records.find { |entry| entry["reference"] == receipt["protectedObservation"] }
        return "protected-form-input-missing" unless record
        return "protected-form-binding-mismatch" unless BINDINGS.all? { |key| record[key] == receipt[key] }
        return "protected-field-update-not-supported" unless (receipt["selectedFields"].map { |field| field["fieldId"] } & fields).empty?
        return "incomplete-protected-form" unless %w[references baseline readback].all? do |key|
          record[key].is_a?(Hash) && record[key].keys.sort == fields.sort
        end
        fields.each do |field|
          if receipt["section"] == "review" && !%w[baseline readback].all? { |key| complete_review_value?(field, record[key][field]) }
            return "incomplete-protected-review-details"
          end
          reference = record["references"][field]
          return "protected-form-reference-mismatch" unless reference.is_a?(String) && reference.match?(SECRET_REFERENCE) &&
            forms.all? do |form|
              value = form[field]
              value = value["credentialsReference"] if field == "demoAccess" && value.is_a?(Hash)
              value == reference
            end
          # Compare actual transient values, not matching Keychain labels.
          return "protected-form-value-mismatch" unless IssueContract.canonical_json(record["baseline"][field]) == IssueContract.canonical_json(record["readback"][field])
        end
        nil
      end
    end

    # Read-only evaluation of supplied historical evidence. This is NOT the
    # selective-save writer or its journal, and cannot authorize a future save.
    class ReadbackEvidence
      KEYS = %w[schemaVersion recordType source issue issueType repository executor operation environment identity sourceRevision section locale selectedFields savedAt observedAt outcome remoteReference remoteState intentDigest contract issueBody preflight approval baseline readback].freeze
      INTENT_KEYS = %w[issue issueType repository executor operation environment identity sourceRevision section locale selectedFields remoteState remoteReference].freeze
      PREFLIGHT_KEYS = %w[schemaVersion issue executor provider account target environment operation health checkedAt digest].freeze
      APPROVAL_KEYS = %w[schemaVersion recordType reviewer decision reference checkedAt intentDigest].freeze
      FORM_KEYS = %w[schemaVersion recordType identity section locale remoteReference values].freeze
      # Source chapters are not Apple resources. Never infer a remote form from
      # all rows that happen to share a report section (e.g. local module/slug,
      # legal drafts, questionnaires or production IAP evidence).
      FORM_FIELDS = {
        "app-info-localization" => %w[name subtitle privacyPolicyURL privacyChoicesURL privacyPolicyText],
        "version-localization" => %w[description keywords promotionalText releaseNotes supportURL marketingURL],
        "review" => %w[reviewNotes reviewContactReference demoAccess],
        "version" => %w[version copyright earliestReleaseDate releaseType downloadable reviewType usesIdfa build],
        "app-information" => %w[category primarySubcategoryOne primarySubcategoryTwo secondaryCategory secondarySubcategoryOne secondarySubcategoryTwo]
      }.freeze
      SELECTABLE_FIELDS = {
        "app-info-localization" => %w[name subtitle privacyPolicyURL],
        "version-localization" => %w[description keywords promotionalText releaseNotes supportURL marketingURL],
        "review" => %w[reviewNotes reviewContactReference demoAccess],
        "version" => %w[version copyright],
        "app-information" => %w[category secondaryCategory]
      }.freeze
      FORM_RESOURCES = {
        "app-info-localization" => "appInfoLocalizations", "version-localization" => "appStoreVersionLocalizations",
        "review" => "appStoreReviewDetails", "version" => "appStoreVersions", "app-information" => "appInfos"
      }.freeze
      LOCAL_SOURCE_FIELDS = %w[identity.displayName identity.module identity.slug deviceSupport supportedLocales privacy.permissions privacy.thirdPartySDKs iap.restore legal.privacyPolicy legal.termsOfUse].freeze
      REFERENCES = %w[contract issueBody preflight approval baseline readback].freeze

      def initialize(sources, values, now, validator, registration, rows, confirmed_keys, protected_input: nil)
        @sources, @values, @now, @validator = sources, values, now, validator
        @account = AccountEvidence.new(sources, values, now, validator, registration)
        @rows, @confirmed_keys = rows, confirmed_keys
        @protected_input = protected_input
      end

      def digest(value)
        AccountEvidence.value_digest(value)
      end

      def timestamp(value)
        return nil unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
        time = Time.iso8601(value)
        time if time.utc.iso8601 == value && time <= @now
      rescue ArgumentError
        nil
      end

      def evidence(descriptor, extension = "json")
        return nil unless @validator.descriptor_valid?(descriptor) && descriptor["anchor"] == "document" &&
          descriptor["path"].match?(%r{\A\.artifacts/appstore-preparation/readbacks/[a-z0-9-]+\.#{extension}\z}) &&
          @validator.fresh_source(descriptor)
        extension == "md" ? @sources.read(descriptor["path"]) : @sources.document(descriptor["path"])
      end

      def authority_error(receipt, inputs, saved_at)
        contract, body = inputs.values_at("contract", "issueBody")
        return "remote-save-authority-mismatch" unless receipt["issue"].is_a?(Integer) && receipt["issue"].positive? &&
          receipt["repository"].is_a?(String) && receipt["repository"] == @sources.repository &&
          %w[codex claude].include?(receipt["executor"]) && receipt["operation"] == "appstore.update_metadata" && receipt["environment"] == "production"
        return "remote-save-contract-mismatch" unless contract.is_a?(Hash) && body.is_a?(String)
        IssueContract.validate_snapshot!(contract, issue: receipt["issue"], repository: receipt["repository"])
        parsed = IssueContract.parse(body, issue_type: receipt["issueType"], issue: receipt["issue"], repository: receipt["repository"], fetched_at: contract["fetchedAt"], allow_legacy_delivery_stage: !contract.key?("deliveryStage"))
        return "remote-save-contract-mismatch" unless parsed.contract == contract && timestamp(contract["fetchedAt"]) && timestamp(contract["fetchedAt"]) <= saved_at
        detail = parsed.external_operation_details.find { |operation| operation["operation"] == "appstore.update_metadata" }
        return "remote-save-authority-mismatch" unless detail && detail["executor"].downcase == receipt["executor"] && detail["environment"] == "production"
        preflight = inputs["preflight"]
        expected = {"schemaVersion" => 2, "issue" => receipt["issue"], "executor" => receipt["executor"], "provider" => "app-store", "account" => receipt["identity"]["teamId"], "target" => receipt["identity"]["bundleId"], "environment" => "production", "operation" => "appstore.update_metadata", "health" => "healthy"}
        return "remote-save-preflight-mismatch" unless preflight.is_a?(Hash) && preflight.keys.sort == PREFLIGHT_KEYS.sort && expected.all? { |key, value| preflight[key] == value } &&
          preflight["digest"] == digest(preflight.reject { |key, _| key == "digest" })
        checked = timestamp(preflight["checkedAt"])
        return "remote-save-preflight-mismatch" unless checked && (saved_at - checked).between?(0, 3600)
        approval = inputs["approval"]
        # A scope-bound user decision is required for imported save evidence,
        # including its public effect. Merely allowing an operation is not that
        # decision. It is distinct from local naming/content confirmation.
        return "remote-save-approval-missing" unless approval.is_a?(Hash) && approval.keys.sort == APPROVAL_KEYS.sort &&
          approval["schemaVersion"] == 1 && approval["recordType"] == "appstore-save-approval" &&
          approval["reviewer"] == "user" && approval["decision"] == "approved" &&
          approval["reference"].is_a?(String) && approval["reference"].match?(%r{\Aapproval: user-approval://[a-z0-9-]{1,128}\z}) &&
          approval["intentDigest"] == receipt["intentDigest"] && timestamp(approval["checkedAt"]) && timestamp(approval["checkedAt"]) <= saved_at
        return "remote-save-approval-missing" if detail["approvalRequired"] && detail["approvalReference"] != approval["reference"]
        nil
      rescue IssueContract::ValidationError, ArgumentError
        "remote-save-contract-mismatch"
      end

      def projection_error(receipt, inputs)
        forms = inputs.values_at("baseline", "readback")
        expected_ids = FORM_FIELDS.fetch(receipt["section"])
        forms.each do |form|
          return "incomplete-remote-form" unless form.is_a?(Hash) && form.keys.sort == FORM_KEYS.sort &&
            form["schemaVersion"] == 1 && form["recordType"] == "appstore-form-projection" &&
            %w[identity section locale remoteReference].all? { |key| form[key] == receipt[key] } && form["values"].is_a?(Hash) &&
            form["values"].length.between?(1, 256) && (expected_ids - form["values"].keys).empty? &&
            form["values"].keys.all? { |key| key.match?(/\A[A-Za-z][A-Za-z0-9.]{0,127}\z/) }
        end
        baseline, readback = forms.map { |form| form["values"] }
        return "incomplete-remote-form" unless baseline.keys.sort == readback.keys.sort
        protected_fields = baseline.keys.select do |key|
          next false if receipt["section"] != "review" && key == "demoAccess" && [baseline[key], readback[key]].all? { |value| value.is_a?(Hash) && value["required"] == false && value["credentialsReference"].nil? }
          key.match?(/contact|credential|session|password|token|demoAccess/i)
        end
        return "unexpected-protected-observation" if protected_fields.empty? && receipt.key?("protectedObservation")
        unless protected_fields.empty?
          return "protected-form-input-missing" unless @protected_input && receipt["protectedObservation"]
          error = @protected_input.check(receipt, [baseline, readback], protected_fields)
          return error if error
          @protected_fields = protected_fields
        end
        selected = receipt["selectedFields"]
        selected.each do |field|
          return "remote-field-resource-mismatch" unless SELECTABLE_FIELDS.fetch(receipt["section"]).include?(field["fieldId"])
          row = @rows.find { |entry| entry["fieldId"] == field["fieldId"] && entry["locale"] == receipt["locale"] && entry["section"] == receipt["section"] }
          return "remote-unconfirmed-selected-source" unless row && @confirmed_keys.include?([row["fieldId"], row["locale"]])
          return "remote-readback-source-mismatch" unless row["sources"].all? { |source| source["digest"].nil? || source["path"].start_with?(".artifacts/") || source["revision"] == receipt["sourceRevision"] }
          return "remote-readback-source-mismatch" unless field["sourceFingerprint"] == row["sourceFingerprint"] && field["valueDigest"] == digest(@account.current_value(row))
          return "remote-selected-value-mismatch" unless readback.key?(field["fieldId"]) && digest(readback[field["fieldId"]]) == field["valueDigest"]
        end
        selected_ids = selected.map { |field| field["fieldId"] }
        return "remote-preserved-value-mismatch" unless (baseline.keys - selected_ids).all? { |key| digest(baseline[key]) == digest(readback[key]) }
        nil
      end

      def check(row, descriptor)
        @protected_fields = nil
        receipt = evidence(descriptor)
        return "remote-readback-not-validated" unless receipt.is_a?(Hash) &&
          [KEYS.sort, (KEYS + ["protectedObservation"]).sort].include?(receipt.keys.sort) && receipt["schemaVersion"] == 2 && receipt["recordType"] == "appstore-preparation-readback" &&
          %w[feature regression docs release].include?(receipt["issueType"])
        return "invalid-protected-observation-reference" if receipt.key?("protectedObservation") &&
          !(receipt["protectedObservation"].is_a?(String) && receipt["protectedObservation"].match?(ProtectedFormInput::REFERENCE))
        return "invalid-remote-readback-origin" unless %w[synthetic-fixture app-store-connect].include?(receipt["source"])
        return "remote-save-unresolved" unless %w[remote-saved unchanged-verified].include?(receipt["outcome"])
        state = receipt["remoteState"]
        return "remote-public-effect-unresolved" unless state.is_a?(Hash) && state.keys.sort == %w[appStatus build publicEffect versionStatus] &&
          %w[appStatus versionStatus].all? { |key| state[key].is_a?(String) && state[key].match?(/\A[A-Z][A-Z0-9_]{1,63}\z/) && state[key] != "UNKNOWN" } &&
          (state["build"].nil? || state["build"].is_a?(String) && state["build"].match?(/\A[0-9]+(?:\.[0-9]+){0,2}\z/)) &&
          %w[draft-only immediate-public-change].include?(state["publicEffect"])
        return "remote-readback-identity-mismatch" unless receipt["identity"].is_a?(Hash) && receipt["identity"].keys.sort == AccountEvidence::IDENTITY_KEYS.sort && receipt["identity"] == @account.expected_identity
        return "remote-readback-scope-mismatch" unless receipt["section"] == row["section"] && receipt["locale"] == row["locale"]
        return "not-a-remote-metadata-field" if LOCAL_SOURCE_FIELDS.include?(row["fieldId"])
        return "remote-form-adapter-unavailable" unless SELECTABLE_FIELDS.fetch(receipt["section"], []).include?(row["fieldId"])
        return "remote-readback-source-mismatch" unless @sources.revision && receipt["sourceRevision"] == @sources.revision
        observed, saved = timestamp(receipt["observedAt"]), timestamp(receipt["savedAt"])
        return "stale-remote-readback" unless observed && saved && (@now - observed).between?(0, 3600) && saved <= observed
        remote = receipt["remoteReference"]
        resource = FORM_RESOURCES.fetch(receipt["section"])
        return "invalid-remote-readback-reference" unless remote.is_a?(String) && remote.match?(%r{\Aasc://apps/#{Regexp.escape(receipt['identity']['appId'])}/#{resource}/[A-Za-z0-9_-]{1,128}\z})
        fields = receipt["selectedFields"]
        return "invalid-remote-selected-fields" unless fields.is_a?(Array) && fields.length.between?(1, 256) && fields.all? do |field|
          field.is_a?(Hash) && field.keys.sort == %w[fieldId sourceFingerprint valueDigest] && field["fieldId"].is_a?(String) &&
            %w[sourceFingerprint valueDigest].all? { |key| field[key].is_a?(String) && field[key].match?(Confirmation::DIGEST) }
        end
        return "invalid-remote-selected-fields" unless fields.map { |field| field["fieldId"] }.uniq.length == fields.length && fields.any? { |field| field["fieldId"] == row["fieldId"] }
        intent = receipt.select { |key, _| (INTENT_KEYS + ["protectedObservation"]).include?(key) }
        return "remote-readback-source-mismatch" unless digest(intent) == receipt["intentDigest"]
        inputs = REFERENCES.each_with_object({}) { |key, result| result[key] = evidence(receipt[key], key == "issueBody" ? "md" : "json") }
        return "remote-save-evidence-missing" if inputs.values.any?(&:nil?)
        error = authority_error(receipt, inputs, saved) || projection_error(receipt, inputs)
        return error if error
        row["evidenceSources"].concat([descriptor] + REFERENCES.map { |key| receipt[key] })
        row["observationOrigins"] << receipt["source"] unless row["observationOrigins"].include?(receipt["source"])
        row["protectedComparison"] = {"status" => "matched", "reference" => receipt["protectedObservation"], "fields" => @protected_fields} if @protected_fields
        nil
      rescue InvalidInput, ArgumentError
        "invalid-remote-readback"
      end
    end
  end
end
