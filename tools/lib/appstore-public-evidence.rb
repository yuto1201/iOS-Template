# frozen_string_literal: true

require "uri"
require "ipaddr"

module IOSTemplate
  module AppStorePreparation
    class PublicEvidence
      OBSERVATION_KEYS = %w[schemaVersion recordType source observedAt url finalURL httpStatus authenticationRequired credentialsUsed contentType bodyTextSource].freeze

      def initialize(sources, values, now, validator)
        @sources, @values, @now, @validator = sources, values, now, validator
      end

      def self.url_error(url)
        return "public-url-missing" unless url.is_a?(String) && !url.empty?
        uri = URI.parse(url)
        return "invalid-public-url" unless uri.is_a?(URI::HTTPS) && uri.host && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && uri.port == 443
        host = uri.host.downcase
        labels = host.split(".", -1)
        return "invalid-public-url" unless host.bytesize <= 253 && labels.length >= 2 && labels.all? do |label|
          label.bytesize.between?(1, 63) && label.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/)
        end
        return "placeholder-public-url" if host == "localhost" || host.end_with?(".localhost", ".local", ".invalid", ".test", ".example") ||
          %w[example.com example.org example.net].any? { |domain| host == domain || host.end_with?(".#{domain}") }
        begin
          IPAddr.new(host)
          return "invalid-public-url"
        rescue IPAddr::InvalidAddressError
          # A hostname is required; this offline evaluator never resolves DNS.
        end
        return "catalog-top-public-url" if host == "app.yutodev.com" && ["", "/"].include?(uri.path)
        return "invalid-public-url" if uri.path.match?(/%(?:00|0a|0d|2e|2f|5c)/i) || uri.path.include?("\\") || uri.path.split("/").include?("..")
        nil
      rescue URI::InvalidURIError, ArgumentError
        "invalid-public-url"
      end

      def mapping(row)
        pages = @values.call(VALUES, "publicPages")
        entry = pages.is_a?(Hash) ? pages[row["fieldId"]] : nil
        localized = @values.call(VALUES, "localizedPublicPages.#{row['locale']}") if row["locale"]
        entry = localized[row["fieldId"]] if localized.is_a?(Hash) && localized.key?(row["fieldId"])
        return [nil, "approved-public-page-missing"] unless entry.is_a?(Hash) && entry.keys.sort == %w[textSource url]
        error = self.class.url_error(entry["url"])
        return [nil, error] if error
        expected = case row["fieldId"]
                   when "supportURL", "privacyPolicyURL", "marketingURL"
                     source = row.fetch("sources").first
                     @values.call(source["path"], source["anchor"])
                   when "legal.privacyPolicy" then @values.call(APP, "privacyPolicyURL")
                   when "ageRating" then @values.call(VALUES, "ageRating.ageSuitabilityURL")
                   when "legal.eula" then @values.call(VALUES, "legal.eula.url")
                   else entry["url"]
                   end
        return [nil, "public-page-url-mismatch"] unless entry["url"] == expected
        text = entry["textSource"]
        return [nil, "wrong-legal-text-source"] if row["fieldId"] == "legal.eula" && text != @values.call(VALUES, "legal.eula.textSource")
        return [nil, "invalid-approved-public-text"] unless @validator.descriptor_valid?(text) && text["anchor"] == "document" &&
          text["path"].match?(%r{\AApp Store/(?:legal|metadata/public-text)/[^/@]+\.(?:md|txt)\z})
        exact_legal = {"privacyPolicyURL" => "privacy-policy.md", "legal.privacyPolicy" => "privacy-policy.md", "legal.termsOfUse" => "terms-of-use.md"}[row["fieldId"]]
        return [nil, "wrong-legal-text-source"] if exact_legal && text["path"] != "App Store/legal/#{exact_legal}"
        return [nil, "stale-approved-public-text"] unless @validator.fresh_source(text)
        [entry, nil]
      end

      def plain_text(bytes, markdown:)
        text = bytes
        if markdown
          text = text.lines.reject { |line| line.strip == "Status: Confirmed" }.map { |line| line.sub(/\A\s*\#{1,6}\s+/, "") }.join
        end
        text.gsub(/\s+/, " ").strip
      end

      def check(row, proof)
        entry, error = mapping(row)
        return error if error
        observation_reference = proof["observation"]
        return "invalid-public-observation-reference" unless @validator.descriptor_valid?(observation_reference) && observation_reference["anchor"] == "document" &&
          observation_reference["path"].match?(%r{\A\.artifacts/appstore-preparation/public-pages/[a-z0-9-]+\.json\z})
        observation = @sources.document(observation_reference["path"])
        return "invalid-public-observation" unless observation.is_a?(Hash) && observation.keys.sort == OBSERVATION_KEYS.sort &&
          observation["schemaVersion"] == 1 && observation["recordType"] == "appstore-public-page-observation" &&
          %w[synthetic-fixture public-http browser-rendered].include?(observation["source"])
        return "stale-public-observation" unless @validator.fresh_source(observation_reference)
        return "public-page-url-mismatch" unless observation["url"] == entry["url"] && observation["finalURL"] == entry["url"]
        return "public-page-not-reachable" unless observation["httpStatus"] == 200
        return "public-page-requires-authentication" unless observation["authenticationRequired"] == false && observation["credentialsUsed"] == false
        return "public-content-type-unverified" unless %w[text/plain text/html].include?(observation["contentType"]) &&
          (observation["contentType"] == "text/plain" || %w[browser-rendered synthetic-fixture].include?(observation["source"]))
        timestamp = observation["observedAt"]
        return "invalid-public-observation-time" unless timestamp.is_a?(String) && timestamp.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
        observed = Time.iso8601(timestamp)
        age = @now - observed
        return "stale-public-observation" unless observed.utc.iso8601 == timestamp && age >= 0 && age <= 3600 && observed <= Time.iso8601(proof["checkedAt"])
        body = observation["bodyTextSource"]
        return "invalid-public-body-reference" unless @validator.descriptor_valid?(body) && body["anchor"] == "document" &&
          body["path"].match?(%r{\A\.artifacts/appstore-preparation/public-pages/[a-z0-9-]+\.txt\z})
        return "stale-public-body" unless @validator.fresh_source(body)
        expected = plain_text(@sources.read(entry["textSource"]["path"]), markdown: entry["textSource"]["path"].end_with?(".md"))
        actual = plain_text(@sources.read(body["path"]), markdown: false)
        return "public-content-mismatch" if expected.empty? || expected != actual
        return "public-observer-evidence-missing" unless proof["reviewer"] == "public-page-inspector" && proof["decision"] == "observed" && proof["reference"].match?(%r{\Apublic-observation://[a-z0-9-]{1,128}\z})
        row["evidenceSources"].concat([entry["textSource"], observation_reference, body])
        row["observationOrigins"] << observation["source"]
        nil
      rescue ArgumentError, InvalidInput
        "invalid-public-observation"
      end
    end
  end
end
