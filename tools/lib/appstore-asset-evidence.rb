# frozen_string_literal: true

require "zlib"

module IOSTemplate
  module AppStorePreparation
    # Binds existing files and supplied export/review records. Does not capture,
    # build, sign, upload, visually approve, or seal a release package.
    class AssetEvidence
      BUILD_KEYS = %w[schemaVersion recordType source sourceRevision bundleId version build platform distributionMethod artifact].freeze
      MANIFEST_KEYS = %w[schemaVersion sourceSha buildDigest runtime requirementsDigest reviewDigest cases].freeze
      CASE_KEYS = %w[locale family state order path sourceSha buildDigest runtime deviceType width height digest].freeze
      REVIEW_KEYS = %w[schemaVersion sourceSha buildDigest visualReviewStatus releaseAuditor cases].freeze
      REVIEW_CASE_KEYS = %w[locale family state path digest safeArea textClipping truthfulRepresentation localeParity].freeze

      def initialize(sources, values, now, code_inventory)
        @sources, @values, @now, @code_inventory = sources, values, now, code_inventory
        @validator = Confirmation.new(sources, now)
      end

      def result(reasons = [], sources = [], origins = [])
        {"reasons" => reasons.compact.uniq, "sources" => sources.uniq, "origins" => origins.uniq}
      end

      def exact?(value, keys)
        value.is_a?(Hash) && value.keys.sort == keys.sort
      end

      def json_reference(reference, pattern)
        return nil unless @validator.descriptor_valid?(reference) && reference["anchor"] == "document" && reference["path"].match?(pattern) && @validator.fresh_source(reference)
        @sources.document(reference["path"])
      end

      def build
        return @build if @build
        unless @code_inventory["sourceRevisionCurrent"]
          return @build = result(["distribution-source-revision-mismatch"], @code_inventory.fetch("sources", []))
        end
        reference = @values.call(VALUES, "buildArtifact")
        record = json_reference(reference, %r{\A\.artifacts/appstore-preparation/builds/[a-z0-9-]+\.json\z})
        return @build = result(["distribution-build-evidence-missing"]) unless exact?(record, BUILD_KEYS) && record["schemaVersion"] == 1 && record["recordType"] == "appstore-distribution-build"
        return @build = result(["distribution-build-identity-mismatch"]) unless @sources.revision && record["sourceRevision"] == @sources.revision && record["bundleId"] == @values.call(APP, "bundleId") && record["version"] == @values.call(APP, "version") && record["build"] == @values.call(VALUES, "build") && record["platform"] == "iphoneos" && record["distributionMethod"] == "app-store-connect" && %w[synthetic-fixture xcode-export].include?(record["source"])
        artifact = record["artifact"]
        return @build = result(["invalid-distribution-artifact-reference"]) unless @validator.descriptor_valid?(artifact) && artifact["anchor"] == "document" && artifact["path"].match?(%r{\A\.artifacts/appstore-preparation/builds/[a-z0-9-]+\.ipa\z})
        bytes = @sources.read(artifact["path"], binary: true)
        return @build = result(["distribution-artifact-mismatch"]) unless bytes && bytes.start_with?("PK\x03\x04".b) && bytes.include?("PK\x05\x06".b) && @sources.binary_descriptor(artifact["path"]) == artifact
        return @build = result(["distribution-artifact-identity-mismatch"]) unless archive_identity?(bytes, record)
        @build_digest = artifact["digest"]
        @build = result([], @code_inventory.fetch("sources", []) + [reference, artifact], [record["source"]])
      end

      def inflate_bounded(bytes, maximum, raw: false)
        inflater = raw ? Zlib::Inflate.new(-Zlib::MAX_WBITS) : Zlib::Inflate.new
        output = "".b
        position = 0
        while position < bytes.bytesize
          output << inflater.inflate(bytes.byteslice(position, 1024))
          return nil if output.bytesize > maximum
          position += 1024
        end
        output if inflater.finished? && inflater.total_in == bytes.bytesize
      rescue Zlib::Error
        nil
      ensure
        inflater&.close
      end

      def archive_identity?(bytes, record)
        # Inspect a bounded ZIP central directory and the actual app Info.plist
        # without extracting files or executing app/archive contents. Signing,
        # executable validity and distribution entitlement remain release gates.
        ending = bytes.rindex("PK\x05\x06".b)
        return false unless ending && ending + 22 <= bytes.bytesize
        disk, directory_disk, disk_count, count, size, offset, comment = bytes.byteslice(ending + 4, 18).unpack("vvvvVVv")
        return false unless disk.zero? && directory_disk.zero? && disk_count == count && count.between?(1, 100_000) && offset + size == ending && ending + 22 + comment == bytes.bytesize
        pointer, candidates, names = offset, [], []
        count.times do
          return false unless pointer + 46 <= ending && bytes.byteslice(pointer, 4) == "PK\x01\x02".b
          flags, method = bytes.byteslice(pointer + 8, 4).unpack("vv")
          crc, compressed, expanded = bytes.byteslice(pointer + 16, 12).unpack("VVV")
          name_size, extra_size, comment_size = bytes.byteslice(pointer + 28, 6).unpack("vvv")
          attributes, local = bytes.byteslice(pointer + 38, 8).unpack("VV")
          name = bytes.byteslice(pointer + 46, name_size)
          return false unless name && !name.empty? && name.force_encoding(Encoding::UTF_8).valid_encoding? && !name.start_with?("/") && !name.match?(/[\x00-\x1f\\]/) && !name.split("/").include?("..") && (flags & 1).zero?
          names << name
          if name.match?(%r{\APayload/[^/]+\.app/Info\.plist\z})
            return false unless expanded.between?(1, 2_000_000) && compressed.between?(1, 2_000_000) && [0, 8].include?(method) && [0, 0100000].include?((attributes >> 16) & 0170000) && local + 30 < offset && bytes.byteslice(local, 4) == "PK\x03\x04".b
            local_name_size, local_extra_size = bytes.byteslice(local + 26, 4).unpack("vv")
            return false unless bytes.byteslice(local + 30, local_name_size) == name && bytes.byteslice(local + 6, 4).unpack("vv") == [flags, method]
            data_offset = local + 30 + local_name_size + local_extra_size
            return false unless data_offset + compressed <= offset
            payload = bytes.byteslice(data_offset, compressed)
            payload = inflate_bounded(payload, 2_000_000, raw: true) if method == 8
            return false unless payload && payload.bytesize == expanded && Zlib.crc32(payload) == crc
            output, _, status = Open3.capture3("/usr/bin/plutil", "-convert", "json", "-o", "-", "--", "-", stdin_data: payload)
            return false unless status.success?
            info = JSON.parse(output, object_class: UniqueObject)
            return false if @sources.sensitive_document?(info)
            candidates << info
          end
          pointer += 46 + name_size + extra_size + comment_size
          return false if pointer > ending
        end
        return false unless pointer == ending && names.uniq.length == names.length && candidates.length == 1
        info = candidates[0]
        info.is_a?(Hash) && info["CFBundleIdentifier"] == record["bundleId"] && info["CFBundleShortVersionString"] == record["version"] && info["CFBundleVersion"] == record["build"] && info["CFBundleSupportedPlatforms"] == ["iPhoneOS"]
      rescue ArgumentError, JSON::ParserError
        false
      end

      def png_valid?(bytes, width, height)
        return false unless bytes && bytes.start_with?("\x89PNG\r\n\x1a\n".b) && width.is_a?(Integer) && height.is_a?(Integer) && width.between?(1, 4096) && height.between?(1, 4096)
        offset, compressed, header, ended = 8, "".b, false, false
        while offset + 12 <= bytes.bytesize
          length = bytes.byteslice(offset, 4).unpack1("N")
          return false if length > bytes.bytesize - offset - 12
          type, payload = bytes.byteslice(offset + 4, 4), bytes.byteslice(offset + 8, length)
          return false unless bytes.byteslice(offset + 8 + length, 4).unpack1("N") == Zlib.crc32(type + payload)
          return false if !header && type != "IHDR"
          case type
          when "IHDR"
            return false if header || length != 13 || payload.unpack("NNC5") != [width, height, 8, 2, 0, 0, 0]
            header = true
          when "IDAT" then compressed << payload
          when "IEND"
            return false unless length.zero? && offset + 12 == bytes.bytesize
            ended = true
            break
          when "tRNS", "tEXt", "zTXt", "iTXt" then return false
          else
            return false unless %w[sRGB gAMA cHRM iCCP pHYs sBIT].include?(type)
          end
          offset += length + 12
        end
        return false unless header && ended && !compressed.empty?
        expected = height * (1 + width * 3)
        inflater = Zlib::Inflate.new
        decoded = "".b
        position = 0
        while position < compressed.bytesize
          decoded << inflater.inflate(compressed.byteslice(position, 1024))
          return false if decoded.bytesize > expected
          position += 1024
        end
        return false unless inflater.finished? && inflater.total_in == compressed.bytesize && decoded.bytesize == expected
        height.times.all? { |y| decoded.getbyte(y * (1 + width * 3)).between?(0, 4) }
      rescue Zlib::Error
        false
      ensure
        inflater&.close
      end

      def screenshots(id, locale, value)
        build_result = build
        return build_result unless build_result["reasons"].empty?
        return result(["screenshot-adoption-evidence-missing"]) unless value.is_a?(Hash) && value["status"] == "adopted"
        manifest = json_reference(value["manifest"], %r{\AApp Store/screenshots/manifest\.json\z})
        review = json_reference(value["review"], %r{\A\.artifacts/appstore-preparation/proofs/[a-z0-9-]+\.json\z})
        requirements = json_reference(value["requirements"], %r{\AApp Store/submission/requirements\.json\z})
        return result(["screenshot-adoption-evidence-missing"]) unless exact?(manifest, MANIFEST_KEYS) && exact?(review, REVIEW_KEYS) && requirements.is_a?(Hash)
        return result(["invalid-screenshot-requirements"]) unless exact?(requirements, %w[schemaVersion retrievedAt maxAgeDays sources fields screenshots]) && requirements["sources"].is_a?(Array) && !requirements["sources"].empty? && requirements["sources"].uniq == requirements["sources"] && requirements["sources"].all? { |url| url.is_a?(String) && url.match?(%r{\Ahttps://developer\.apple\.com/(?:help|documentation)/[a-z0-9/-]+\z}) } && requirements["fields"].is_a?(Hash)
        return result(["screenshot-identity-mismatch"]) unless manifest["schemaVersion"] == 1 && review["schemaVersion"] == 1 && [manifest, review].all? { |record| record["sourceSha"] == @sources.revision && record["buildDigest"] == @build_digest } && manifest["requirementsDigest"] == value["requirements"]["digest"] && manifest["reviewDigest"] == value["review"]["digest"] && manifest["runtime"].is_a?(String) && manifest["runtime"].match?(/\Acom\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+\z/)
        return result(["screenshot-review-unconfirmed"]) unless review["visualReviewStatus"] == "passed" && exact?(review["releaseAuditor"], %w[status model]) && review["releaseAuditor"]["status"] == "approved" && review["releaseAuditor"]["model"].is_a?(String) && !review["releaseAuditor"]["model"].strip.empty?
        retrieved = Time.iso8601(requirements.fetch("retrievedAt", ""))
        max_age = requirements["maxAgeDays"]
        return result(["screenshot-requirements-stale"]) unless max_age.is_a?(Integer) && max_age.between?(1, 30) && (@now - retrieved).between?(0, max_age * 86_400)
        limits = requirements["screenshots"]
        return result(["invalid-screenshot-requirements"]) unless requirements["schemaVersion"] == 1 && exact?(limits, %w[minimumPerFamily maximumPerFamily formats allowAlpha requiredFamilies]) && limits["formats"].is_a?(Array) && limits["formats"].include?("png") && (limits["formats"] - %w[png jpg jpeg]).empty? && [true, false].include?(limits["allowAlpha"]) && limits["requiredFamilies"].is_a?(Array) && limits["requiredFamilies"].all? { |family| exact?(family, %w[id platform deviceTypes portraitSizes landscapeSizes]) && family["id"].is_a?(String) && family["id"].match?(/\A[a-z0-9][a-z0-9.-]+\z/) && %w[iphone ipad].include?(family["platform"]) } && limits["minimumPerFamily"].is_a?(Integer) && limits["maximumPerFamily"].is_a?(Integer) && limits["minimumPerFamily"].between?(1, 10) && limits["maximumPerFamily"].between?(limits["minimumPerFamily"], 10)
        family_ids = limits["requiredFamilies"].map { |family| family["id"] }
        return result(["invalid-screenshot-requirements"]) unless family_ids.uniq.length == family_ids.length
        families = limits["requiredFamilies"].select { |family| family.is_a?(Hash) && family["platform"] == id.split(".").last }
        return result(["invalid-screenshot-requirements"]) if families.empty? || families.map { |family| family["id"] }.uniq.length != families.length
        cases, reviews = manifest["cases"], review["cases"]
        return result(["invalid-screenshot-manifest"]) unless cases.is_a?(Array) && cases.length.between?(1, 80) && cases.all? { |entry| exact?(entry, CASE_KEYS) } && reviews.is_a?(Array) && reviews.length == cases.length && reviews.all? { |entry| exact?(entry, REVIEW_CASE_KEYS) }
        return result(["invalid-screenshot-manifest"]) unless cases.all? { |entry| %w[en-US ja].include?(entry["locale"]) && limits["requiredFamilies"].any? { |family| family["id"] == entry["family"] } }
        return result(["duplicate-screenshot-evidence"]) unless cases.map { |entry| entry.values_at("locale", "family", "state") }.uniq.length == cases.length && cases.map { |entry| entry["digest"] }.uniq.length == cases.length
        sources = build_result["sources"] + %w[manifest review requirements].map { |key| value[key] }
        families.each do |family|
          entries = cases.select { |entry| entry["locale"] == locale && entry["family"] == family["id"] }
          return result(["screenshot-family-incomplete"]) unless entries.length.between?(limits["minimumPerFamily"], limits["maximumPerFamily"]) && entries.map { |entry| entry["order"] }.sort == (1..entries.length).to_a
          entries.each do |entry|
            return result(["screenshot-identity-mismatch"]) unless entry["sourceSha"] == @sources.revision && entry["buildDigest"] == @build_digest && entry["runtime"] == manifest["runtime"] && family["deviceTypes"].is_a?(Array) && family["deviceTypes"].include?(entry["deviceType"])
            return result(["invalid-screenshot-path"]) unless entry["path"].is_a?(String) && entry["path"].match?(%r{\A(?:en-US|ja)/[a-z0-9.-]+/[0-9]{2}-[a-z0-9-]+\.png\z}) && entry["path"] == "#{locale}/#{family['id']}/#{format('%02d', entry['order'])}-#{entry['state']}.png"
            sizes = [family["portraitSizes"], family["landscapeSizes"]]
            return result(["invalid-screenshot-dimensions"]) unless sizes.all? { |list| list.is_a?(Array) } && sizes.flatten(1).include?([entry["width"], entry["height"]])
            path = "App Store/screenshots/#{entry['path']}"
            bytes = @sources.read(path, binary: true)
            return result(["invalid-screenshot-image"]) unless png_valid?(bytes, entry["width"], entry["height"])
            source = @sources.binary_descriptor(path)
            return result(["screenshot-image-digest-mismatch"]) unless source["digest"] == entry["digest"]
            matches = reviews.select { |check| check.values_at("locale", "family", "state") == entry.values_at("locale", "family", "state") }
            return result(["screenshot-review-unconfirmed"]) unless matches.length == 1 && matches[0]["path"] == entry["path"] && matches[0]["digest"] == source["digest"] && %w[safeArea textClipping truthfulRepresentation localeParity].all? { |key| matches[0][key] == "passed" }
            sources << source
          end
        end
        result([], sources, build_result["origins"])
      rescue ArgumentError, TypeError
        result(["invalid-screenshot-evidence"])
      end

      def check(id, locale, value)
        return build if id == "build"
        return screenshots(id, locale, value) if id.start_with?("screenshots.")
        result
      rescue InvalidInput
        result(["unsafe-asset-evidence"])
      end
    end
  end
end
