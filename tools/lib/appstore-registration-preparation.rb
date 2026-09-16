# frozen_string_literal: true

module IOSTemplate
  module AppStorePreparation
    # Evaluate a supplied, sanitized observation, never query an Apple account.
    # A match is a resume candidate, not authorization to create or update it.
    class Registration
      OBSERVATION = ".artifacts/appstore-preparation/account-observation.json"
      OBSERVATION_KEYS = %w[schemaVersion recordType source observedAt status inventoryComplete teamId role agreements bundles apps].freeze
      APP_KEYS = %w[appId bundleId name sku primaryLocale platforms userAccess].freeze
      MAX_AGE_SECONDS = 3600

      def initialize(sources, values, now)
        @sources, @values, @now = sources, values, now
      end

      def value(path, anchor)
        @values.call(path, anchor)
      end

      def result(reasons, existing = nil)
        {
          "status" => reasons.empty? ? "matched-observation" : "blocked",
          "reasons" => reasons.uniq,
          "existingApp" => reasons.empty? ? existing : nil,
          "observation" => @sources.descriptor(OBSERVATION, "document"),
          "evidenceOrigin" => @evidence_origin,
          "liveRemoteInspection" => false, "mutationAuthorized" => false,
          "retryAuthorized" => false,
          "unblockConditions" => reasons.empty? ? [] : ["resolve-reported-prerequisites-and-obtain-fresh-authorized-observation"]
        }
      end

      def nonempty_string?(value)
        value.is_a?(String) && !value.strip.empty? && value.bytesize <= 512 && !value.match?(/[\x00-\x1f\x7f]/)
      end

      def schema_valid?(observation)
        return false unless observation.is_a?(Hash) && observation.keys.sort == OBSERVATION_KEYS.sort &&
          observation["schemaVersion"] == 1 && observation["recordType"] == "appstore-account-observation" &&
          %w[synthetic-fixture app-store-connect].include?(observation["source"]) &&
          %w[observed unknown].include?(observation["status"])
        return false unless %w[teamId role].all? { |key| nonempty_string?(observation[key]) } &&
          observation["teamId"].match?(/\A[A-Z0-9]{10}\z/) &&
          %w[current action-required unknown].include?(observation["agreements"])
        return false unless [true, false].include?(observation["inventoryComplete"])
        return false unless observation["bundles"].is_a?(Array) && observation["bundles"].size <= 1000 &&
          observation["bundles"].all? { |bundle| bundle_identifier?(bundle) }
        return false unless observation["apps"].is_a?(Array) && observation["apps"].size <= 1000
        observation["apps"].all? do |app|
          app.is_a?(Hash) && app.keys.sort == APP_KEYS.sort &&
            %w[appId bundleId name sku primaryLocale userAccess].all? { |key| nonempty_string?(app[key]) } &&
            app["appId"].match?(/\A[0-9]+\z/) && bundle_identifier?(app["bundleId"]) &&
            app["platforms"].is_a?(Array) && !app["platforms"].empty? && app["platforms"].uniq == app["platforms"] &&
            (app["platforms"] - %w[IOS MAC_OS TV_OS VISION_OS]).empty?
        end
      end

      def bundle_identifier?(value)
        nonempty_string?(value) && value.match?(/\A[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z/)
      end

      def run
        team = value(OWNERSHIP, "appStore.teamId")
        return result(%w[team-unset]) unless nonempty_string?(team)
        return result(%w[invalid-team-identifier]) unless team.match?(/\A[A-Z0-9]{10}\z/)
        bundle = value(OWNERSHIP, "appStore.bundleId")
        return result(%w[bundle-unset]) unless nonempty_string?(bundle)
        return result(%w[invalid-bundle-identifier]) unless bundle_identifier?(bundle)
        identity_bundle = value(IDENTITY, "bundleId")
        metadata_bundle = value(APP, "bundleId")
        return result(%w[bundle-identity-mismatch]) unless bundle == identity_bundle && bundle == metadata_bundle
        return result(%w[template-bundle]) if bundle.match?(/templateapp/i)

        observation = @sources.document(OBSERVATION)
        if observation.nil?
          reason = @sources.error(OBSERVATION)
          return result([reason == "missing-source" ? "account-observation-missing" : "invalid-account-observation"])
        end
        return result(%w[invalid-account-observation]) unless schema_valid?(observation)
        @evidence_origin = observation["source"]
        return result(%w[account-mismatch]) unless observation["teamId"] == team
        return result(%w[remote-state-unknown]) unless observation["status"] == "observed" && observation["inventoryComplete"]
        begin
          timestamp = observation["observedAt"]
          return result(%w[invalid-observation-time]) unless timestamp.is_a?(String) && timestamp.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
          observed_at = Time.iso8601(timestamp)
          return result(%w[invalid-observation-time]) unless observed_at.utc.iso8601 == timestamp
          age = @now - observed_at
          return result(%w[stale-account-observation]) unless age >= 0 && age <= MAX_AGE_SECONDS
        rescue ArgumentError
          return result(%w[invalid-observation-time])
        end

        reasons = []
        reasons << "missing-role" unless %w[ACCOUNT_HOLDER ADMIN APP_MANAGER].include?(observation["role"])
        reasons << "agreement-action-required" if observation["agreements"] == "action-required"
        reasons << "agreement-state-unknown" if observation["agreements"] == "unknown"
        bundles = observation.fetch("bundles")
        reasons << "ambiguous-bundle-inventory" unless bundles.uniq == bundles
        reasons << "bundle-not-registered" unless bundles.include?(bundle)
        apps = observation.fetch("apps")
        reasons << "conflicting-app-identities" unless apps.map { |app| app["appId"] }.uniq.length == apps.length
        matches = apps.select { |app| app["bundleId"] == bundle }
        expected_id = value(VALUES, "account.appId")
        if expected_id && apps.any? { |app| app["appId"] == expected_id && app["bundleId"] != bundle }
          reasons << "app-identity-mismatch"
        end
        if matches.empty?
          reasons << "app-not-created"
        elsif matches.length > 1
          reasons << "duplicate-app-identities"
        end

        name = value(APP, "primaryLocale")
        locale_path = {"en-US" => "App Store/metadata/localizations/en-US.yml", "ja" => "App Store/metadata/localizations/ja.yml"}[name]
        proposed_name = locale_path && value(locale_path, "name")
        reasons << "naming-choice-missing" unless nonempty_string?(proposed_name)
        if proposed_name && apps.any? { |app| app["bundleId"] != bundle && app["name"] == proposed_name }
          reasons << "name-collision"
        end
        local_fields = {
          "name" => proposed_name, "sku" => value(VALUES, "sku"),
          "primaryLocale" => name, "userAccess" => value(VALUES, "account.userAccess")
        }
        local_fields.each { |field, current| reasons << "#{field}-choice-missing" unless nonempty_string?(current) }
        reasons << "unsupported-primary-locale" unless name == "en-US"
        support = value(APP, "platforms")
        reasons << "platform-support-unresolved" unless support.is_a?(Hash) && support.keys.sort == %w[ipad iphone] &&
          support.values.all? { |supported| supported == true || supported == false } && support.values.include?(true)
        if matches.length == 1
          matched = matches.first
          reasons << "registration-platform-mismatch" unless matched["platforms"] == ["IOS"]
          reasons << "app-identity-mismatch" if expected_id && expected_id != matched["appId"]
          local_fields.each { |field, current| reasons << "registration-#{field}-mismatch" unless matched[field] == current }
        end
        existing = matches.length == 1 ? {"appId" => matches.first["appId"], "bundleId" => bundle, "teamId" => team} : nil
        result(reasons, existing)
      end
    end
  end
end
