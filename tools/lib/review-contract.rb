# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "time"
require_relative "verification-scope"

module IOSTemplate
  module ReviewContract
    class ValidationError < StandardError; end

    module_function

    PACKET_V1_KEYS = %w[
      schemaVersion issue primaryModel reviewerModel baseSha headSha verifySha
      issueContract specAnchors acceptanceCriteria diffFile verifyFile imageFiles
    ].freeze
    PACKET_V2_KEYS = %w[
      schemaVersion issue primaryModel reviewerModel baseSha headSha verifySha
      issueContract specAnchors acceptanceCriteria diff verify imageFiles
    ].freeze
    PACKET_V2_REPOSITORY_TEST_KEYS = (PACKET_V2_KEYS + %w[repositoryTests]).freeze
    PACKET_V2_REVISION_TEST_KEYS = (PACKET_V2_REPOSITORY_TEST_KEYS + %w[repositoryTestsFile]).freeze
    RESULT_V1_KEYS = %w[
      schemaVersion issue reviewerModel baseSha headSha verifySha
      issueContractDigest verdict findings acceptanceAssessment reviewedAt
    ].freeze
    RESULT_V2_KEYS = (RESULT_V1_KEYS + %w[reviewPacketDigest]).freeze
    CONTRACT_KEYS = %w[
      schemaVersion issue repository goal specAnchors acceptanceCriteria dependencies
      externalOperations externalOperationDetailsDigest fetchedAt
    ].freeze
    CONTRACT_OPTIONAL_KEYS = %w[verification deliveryProfile verificationScope deliveryStage].freeze
    LEGACY_CONTRACT_KEYS = (CONTRACT_KEYS - %w[externalOperationDetailsDigest]).freeze
    REFERENCE_KEYS = %w[path digest].freeze
    DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/

    # Pure validation entry point. strict: true is the merge-ready v2 contract.
    # Gate callers pass bytes from already-held descriptors. This method never
    # opens an artifact path. actual_diff_bytes must be independently generated
    # from the exact Base..Head commits by the caller (or with actual_diff()).
    def validate!(packet_bytes:, result_bytes:, verify_bytes:, contract_bytes:, primary:, issue:, base_sha:, head_sha:,
                  now: Time.now.utc, require_temporal_order: false, strict: false,
                  diff_bytes: nil, image_bytes: nil, actual_diff_bytes: nil,
                  repository_tests_bytes: nil, revision_context: nil)
      reject("primary model is invalid") unless %w[codex claude].include?(primary)
      reviewer = primary == "codex" ? "claude" : "codex"
      packet = parse_object(packet_bytes, "packet")
      result = parse_object(result_bytes, "result")
      verify = parse_object(verify_bytes, "verify")
      contract = parse_object(contract_bytes, "issue contract")
      contract_digest = digest(contract_bytes)

      schema = packet["schemaVersion"]
      reject("merge-ready review requires packet schemaVersion 2") if strict && schema != 2
      reject("packet.schemaVersion is unsupported") unless [1, 2].include?(schema)
      validate_packet_identity!(packet, schema, primary, reviewer, issue, base_sha, head_sha)
      validate_contract!(packet, contract, contract_digest, issue, schema: schema)
      criteria = validate_scope!(packet, contract)
      validate_repository_closure!(packet: packet, contract: contract, contract_digest: contract_digest,
        issue: issue, base_sha: base_sha, head_sha: head_sha,
        repository_tests_bytes: repository_tests_bytes, revision_context: revision_context,
        workflow_required: verify["changeClassification"] == "workflow-only")
      completed_at = validate_verify_identity!(packet, schema, verify, issue, base_sha, head_sha, contract_digest, require_temporal_order)

      if schema == 2
        validate_evidence_scope!(contract, verify)
        validate_strict_closure!(
          packet: packet, packet_bytes: packet_bytes, verify: verify, verify_bytes: verify_bytes,
          issue: issue, head_sha: head_sha, diff_bytes: diff_bytes, image_bytes: image_bytes,
          actual_diff_bytes: actual_diff_bytes
        )
      elsif strict
        reject("merge-ready review requires packet schemaVersion 2")
      end

      validate_result!(
        result, schema, packet_bytes, reviewer, issue, base_sha, head_sha,
        contract_digest, criteria, completed_at, now, require_temporal_order
      )
      validate_repository_assessments!(result, packet["repositoryTests"]) if repository_test_scope(criteria) == "base-and-head"
      {"packet" => packet, "result" => result, "verify" => verify, "contract" => contract}
    end

    # First phase for descriptor-owning Gate callers. It validates only enough
    # untrusted packet structure to determine the exact canonical leaves to hold.
    # Call validate!(strict: true, ...) with those held bytes before approving.
    def strict_references!(packet_bytes:, issue:, head_sha:)
      packet = parse_object(packet_bytes, "packet")
      reject("merge-ready review requires packet schemaVersion 2") unless packet["schemaVersion"] == 2
      exact_packet_v2_keys!(packet)
      reject("packet identity differs from caller") unless packet["issue"] == issue && packet["headSha"] == head_sha
      prefix = ".artifacts/issues/#{issue}/#{head_sha}/"
      diff = reference!(packet["diff"], "packet.diff")
      verify = reference!(packet["verify"], "packet.verify")
      reject("packet.diff.path is not canonical") unless diff["path"] == "#{prefix}review.diff"
      reject("packet.verify.path is not canonical") unless verify["path"] == "#{prefix}verify.json"
      images = packet["imageFiles"]
      reject("packet.imageFiles must be an array") unless images.is_a?(Array)
      images.each_with_index do |entry, index|
        reference!(entry, "packet.imageFiles[#{index}]")
        reject("packet.imageFiles[#{index}].path is outside the exact Issue/Head") unless entry["path"].start_with?(prefix)
      end
      reject("packet.imageFiles paths must be unique") unless images.map { |entry| entry["path"] }.uniq.length == images.length
      references = {"diff" => diff, "verify" => verify, "imageFiles" => images}
      if packet.key?("repositoryTestsFile")
        reference = reference!(packet["repositoryTestsFile"], "packet.repositoryTestsFile")
        reject("packet.repositoryTestsFile.path is not canonical") unless reference["path"] == "#{prefix}repository-tests.json"
        references["repositoryTestsFile"] = reference
      end
      references
    end

    def actual_diff(repo:, base_sha:, head_sha:)
      reject("repository root must be physical") unless repo.is_a?(String) && repo.start_with?("/") && File.realpath(repo) == repo
      [base_sha, head_sha].each { |sha| sha!(sha, "Git SHA") }
      environment = {
        "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil,
        "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null",
        "LANG" => "C", "LC_ALL" => "C"
      }
      command = [
        "/usr/bin/git", "-C", repo, "-c", "core.quotepath=true", "-c", "diff.noprefix=false",
        "diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", "--no-renames",
        "--src-prefix=a/", "--dst-prefix=b/", base_sha, head_sha, "--"
      ]
      bytes, error, status = Open3.capture3(environment, *command)
      reject("actual Base..Head diff could not be generated: #{error.strip}") unless status.success?
      bytes.b
    rescue Errno::ENOENT, Errno::EACCES => error
      reject("actual Base..Head diff could not be generated: #{error.message}")
    end

    def verified_image_references!(verify, issue:, head_sha:)
      prefix = ".artifacts/issues/#{issue}/#{head_sha}/"
      visual = verify["visualEvaluation"]
      return [] if visual.is_a?(Hash) && visual["status"] == "not-applicable"
      reject("verify.visualEvaluation must contain canonical cases") unless visual.is_a?(Hash) && visual["status"] == "passed" && visual["cases"].is_a?(Array)
      references = []
      visual["cases"].each_with_index do |review_case, case_index|
        reject("verify.visualEvaluation.cases[#{case_index}] must be an object") unless review_case.is_a?(Hash)
        images = review_case["images"]
        reject("verify visual case images must be a nonempty array") unless images.is_a?(Array) && !images.empty?
        images.each do |image|
          reject("verify visual image must be an object") unless image.is_a?(Hash)
          path = string!(image["path"], "verify visual image path")
          safe_relative!(path, "verify visual image path")
          digest!(image["digest"], "verify visual image digest")
          references << {"path" => "#{prefix}#{path}", "digest" => image["digest"]}
        end
      end
      reject("verified visual image paths must be unique") unless references.map { |entry| entry["path"] }.uniq.length == references.length
      references
    end

    def validate_packet_identity!(packet, schema, primary, reviewer, issue, base_sha, head_sha)
      schema == 2 ? exact_packet_v2_keys!(packet) : exact_keys!(packet, PACKET_V1_KEYS, "packet")
      reject("packet identity does not match the merge identity") unless
        packet["issue"] == issue && packet["primaryModel"] == primary &&
        packet["reviewerModel"] == reviewer && packet["baseSha"] == base_sha &&
        packet["headSha"] == head_sha && packet["verifySha"] == head_sha
      sha!(base_sha, "base SHA")
      sha!(head_sha, "head SHA")
    end

    # Selection is contract-derived, never a CLI switch or an inferred prose
    # mention. Existing sealed contracts and Head-only record bytes stay valid.
    def repository_test_scope(criteria)
      declarations = criteria.select { |entry| entry.fetch("text").start_with?("Repository-test scope:") }
      return "head" if declarations.empty?
      reject("repository-test scope declaration is malformed or duplicated") unless declarations.length == 1 &&
        declarations.first.fetch("text").match?(/\ARepository-test scope: base-and-head; \S/)
      "base-and-head"
    end

    # Immutable Git inputs are obtained independently by descriptor-owning
    # callers, not from the record's self-declared tested SHA or inventory.
    def repository_revision_context(repo:, base_sha:, head_sha:)
      reject("repository root must be physical") unless repo.start_with?("/") && File.realpath(repo) == repo
      [base_sha, head_sha].each { |sha| sha!(sha, "repository revision SHA") }
      reject("Base and Head must differ") if base_sha == head_sha
      environment = {"GIT_DIR"=>nil, "GIT_WORK_TREE"=>nil, "GIT_COMMON_DIR"=>nil,
        "GIT_CONFIG_GLOBAL"=>"/dev/null", "GIT_CONFIG_SYSTEM"=>"/dev/null", "GIT_NO_REPLACE_OBJECTS"=>"1",
        "LANG"=>"C", "LC_ALL"=>"C"}
      git = lambda do |*args|
        bytes, _, status = Open3.capture3(environment, "/usr/bin/git", "-C", repo,
          "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", *args)
        reject("repository revision Git lookup failed: #{args.first}") unless status.success?
        bytes.b
      end
      git.call("merge-base", "--is-ancestor", base_sha, head_sha)
      inventories = [base_sha, head_sha].map do |sha|
        git.call("ls-tree", "-rz", sha, "--", "tools/tests").split("\0").map do |entry|
          metadata, path = entry.split("\t", 2)
          next unless path&.match?(%r{\Atools/tests/test-[a-z0-9-]+\.sh\z})
          mode, type, oid = metadata.split(" ")
          reject("repository test must be a regular tracked blob") unless type == "blob" && %w[100644 100755].include?(mode)
          {"path"=>path, "sourceDigest"=>digest(git.call("cat-file", "blob", oid))}
        end.compact.sort_by { |entry| entry.fetch("path") }
      end
      producer = %w[tools/run-repository-tests.sh tools/lib/run-repository-tests.rb].map do |path|
        {"path"=>path, "digest"=>digest(git.call("show", "#{head_sha}:#{path}"))}
      end
      {"baseSha"=>base_sha, "headSha"=>head_sha, "inventories"=>inventories, "producerFiles"=>producer}
    end

    def validate_repository_closure!(packet:, contract:, contract_digest:, issue:, base_sha:, head_sha:,
                                     repository_tests_bytes: nil, revision_context: nil, workflow_required: false)
      criteria = contract.fetch("acceptanceCriteria")
      required = repository_test_scope(criteria) == "base-and-head"
      reject("Base and Head repository evidence is required") if required && !packet.key?("repositoryTests")
      reject("workflow-only verification requires repository evidence") if workflow_required && !packet.key?("repositoryTests")
      if required
        reject("Base and Head evidence requires packet schemaVersion 2") unless packet["schemaVersion"] == 2
        reference = reference!(packet["repositoryTestsFile"], "packet.repositoryTestsFile")
        reject("packet.repositoryTestsFile.path is not canonical") unless reference["path"] == ".artifacts/issues/#{issue}/#{head_sha}/repository-tests.json"
        reject("held repository test bytes are required") unless repository_tests_bytes.is_a?(String)
        reject("repository record digest differs") unless digest(repository_tests_bytes) == reference["digest"]
        reject("packet repository evidence differs from held record") unless parse_object(repository_tests_bytes, "repository record") == packet["repositoryTests"]
      elsif packet.key?("repositoryTestsFile")
        reject("Head-only contract cannot use a Base and Head record reference")
      end
      if packet.key?("repositoryTests")
        validate_repository_tests!(packet["repositoryTests"], issue: issue, base_sha: base_sha, head_sha: head_sha,
          contract_digest: contract_digest, criteria: criteria, revision_context: revision_context)
        if workflow_required
          recorded = packet.fetch("repositoryTests").fetch("tests").map { |entry| entry.fetch("path") }
          mapped = packet.fetch("repositoryTests").fetch("acceptanceEvidence").flat_map { |entry| entry.fetch("tests") }.uniq.sort
          reject("workflow-only repository test selection differs from its AC mappings") unless recorded == mapped
        end
        if required
          reject("repository execution predates Issue contract") if iso8601!(packet["repositoryTests"]["startedAt"], "repository start") < iso8601!(contract["fetchedAt"], "contract fetchedAt")
        end
      end
    end

    def validate_revision_repository_tests!(value, issue:, base_sha:, head_sha:, contract_digest:, criteria:, revision_context:)
      exact_keys!(value, %w[schemaVersion scope status issue baseSha headSha issueContract producer revisions acceptanceEvidence startedAt completedAt], "repositoryTests")
      reject("repositoryTests identity differs from the review packet") unless value.values_at("schemaVersion", "scope", "status", "issue", "baseSha", "headSha") == [2, "base-and-head", "passed", issue, base_sha, head_sha]
      reject("repositoryTests issue contract differs") unless value["issueContract"] == {"path"=>".artifacts/issues/#{issue}/issue-contract.json", "digest"=>contract_digest}
      reject("independent repository revision context is required") unless revision_context.is_a?(Hash) && revision_context.values_at("baseSha", "headSha") == [base_sha, head_sha]
      reject("repositoryTests producer differs from current Head") unless value["producer"] == {"headSha"=>head_sha, "files"=>revision_context.fetch("producerFiles")}
      revisions = value["revisions"]
      reject("repositoryTests requires exact ordered Base and Head revisions") unless revisions.is_a?(Array) && revisions.length == 2
      start = iso8601!(value["startedAt"], "repositoryTests.startedAt")
      finish = iso8601!(value["completedAt"], "repositoryTests.completedAt")
      reject("repositoryTests interval is invalid") if finish < start || finish > Time.now.utc + 300
      previous = start
      inventories = revisions.each_with_index.map do |revision, index|
        exact_keys!(revision, %w[role testedSha suite tests startedAt completedAt], "repositoryTests revision")
        reject("repositoryTests revision identity differs") unless revision.values_at("role", "testedSha") == [["base", base_sha], ["head", head_sha]][index]
        revision_start = iso8601!(revision["startedAt"], "revision startedAt")
        revision_finish = iso8601!(revision["completedAt"], "revision completedAt")
        reject("repositoryTests revision interval is invalid") if revision_start < previous || revision_finish < revision_start || revision_finish > finish
        tests = revision["tests"]
        expected = revision_context.fetch("inventories").fetch(index)
        reject("repositoryTests full revision inventory differs") unless tests.is_a?(Array) && !expected.empty? && tests.map { |t| t.is_a?(Hash) ? t.slice("path", "sourceDigest") : nil } == expected
        reject("repositoryTests suite totals differ") unless revision["suite"] == {"path"=>"tools/tests", "pattern"=>"test-*.sh", "total"=>tests.length, "passed"=>tests.length, "failed"=>0}
        test_previous = revision_start
        tests.each do |test|
          exact_keys!(test, %w[path sourceDigest arguments command status exitStatus outputDigest timeoutSeconds elapsedSeconds startedAt completedAt], "repositoryTests test")
          arguments = test["path"] == "tools/tests/test-app-bootstrap.sh" ? ["all"] : []
          reject("repositoryTests test argv differs") unless test["arguments"] == arguments && test["command"] == ["/bin/bash", "-p", test["path"], *arguments]
          reject("repositoryTests contains a failed or incomplete test") unless test["status"] == "passed" && test["exitStatus"] == 0
          bound = test["timeoutSeconds"]
          elapsed = test["elapsedSeconds"]
          reject("repositoryTests test bound is invalid") unless bound.is_a?(Integer) && bound.positive? && bound <= 900 && elapsed.is_a?(Numeric) && elapsed.finite? && elapsed >= 0 && elapsed <= bound + 5
          digest!(test["outputDigest"], "repositoryTests outputDigest")
          test_start = iso8601!(test["startedAt"], "test startedAt")
          test_finish = iso8601!(test["completedAt"], "test completedAt")
          reject("repositoryTests test interval is invalid") if test_start < test_previous || test_finish < test_start || test_finish > revision_finish
          test_previous = test_finish
        end
        previous = revision_finish
        tests.map { |test| test.fetch("path") }
      end
      acceptance = value["acceptanceEvidence"]
      reject("repositoryTests acceptance evidence differs from Issue criteria") unless acceptance.is_a?(Array) && acceptance.length == criteria.length
      acceptance.each_with_index do |entry, index|
        exact_keys!(entry, %w[id status baseTests headTests], "repositoryTests acceptanceEvidence")
        reject("repositoryTests acceptance IDs differ") unless entry.values_at("id", "status") == [criteria[index]["id"], "passed"]
        %w[baseTests headTests].each_with_index do |field, role|
          paths = unique_nonempty_strings!(entry[field], "repositoryTests #{field}", require_nonempty: role == 1)
          reject("repositoryTests acceptance test reference is unknown") unless paths.all? { |path| inventories[role].include?(path) }
        end
      end
      declaration_index = criteria.index { |entry| entry["text"].start_with?("Repository-test scope:") }
      reject("repository scope AC must cite both complete suites") unless %w[baseTests headTests].each_with_index.all? { |field, role| acceptance[declaration_index][field].sort == inventories[role] }
      value
    end

    def validate_repository_assessments!(result, record)
      result.fetch("acceptanceAssessment").each_with_index do |assessment, index|
        next unless assessment["status"] == "supported"
        required = "repository-tests.json#acceptanceEvidence/#{index}"
        reject("supported repository AC must cite its exact sealed mapping") unless assessment["evidence"].include?(required)
      end
      reject("review predates repository suite completion") if iso8601!(result["reviewedAt"], "reviewedAt") < iso8601!(record["completedAt"], "repository completion")
    end

    def validate_repository_tests!(value, issue:, base_sha:, head_sha:, contract_digest:, criteria:, revision_context: nil)
      if repository_test_scope(criteria) == "base-and-head"
        return validate_revision_repository_tests!(value, issue: issue, base_sha: base_sha, head_sha: head_sha,
          contract_digest: contract_digest, criteria: criteria, revision_context: revision_context)
      end
      exact_keys!(value, %w[schemaVersion status issue baseSha headSha issueContract runnerFiles suite tests acceptanceEvidence startedAt completedAt], "repositoryTests")
      reject("repositoryTests identity differs from the review packet") unless
        value["schemaVersion"] == 1 && value["status"] == "passed" && value["issue"] == issue &&
        value["baseSha"] == base_sha && value["headSha"] == head_sha
      expected_contract = {"path" => ".artifacts/issues/#{issue}/issue-contract.json", "digest" => contract_digest}
      reject("repositoryTests issue contract differs") unless value["issueContract"] == expected_contract

      runners = value["runnerFiles"]
      reject("repositoryTests runnerFiles are invalid") unless runners.is_a?(Array) && runners.length == 2
      expected_runner_paths = %w[tools/run-repository-tests.sh tools/lib/run-repository-tests.rb]
      runners.each_with_index do |reference, index|
        reference!(reference, "repositoryTests.runnerFiles[#{index}]")
        reject("repositoryTests runner file differs") unless reference["path"] == expected_runner_paths[index]
      end

      suite = value["suite"]
      exact_keys!(suite, %w[path pattern total passed failed], "repositoryTests.suite")
      reject("repositoryTests suite selector differs") unless suite["path"] == "tools/tests" && suite["pattern"] == "test-*.sh"
      tests = value["tests"]
      reject("repositoryTests tests must be a nonempty array") unless tests.is_a?(Array) && !tests.empty?
      test_paths = []
      tests.each_with_index do |test, index|
        exact_keys!(test, %w[path arguments status exitStatus outputDigest startedAt completedAt], "repositoryTests.tests[#{index}]")
        path = string!(test["path"], "repositoryTests.tests[#{index}].path")
        reject("repositoryTests test path is invalid") unless path.match?(%r{\Atools/tests/test-[a-z0-9-]+\.sh\z})
        expected_arguments = path == "tools/tests/test-app-bootstrap.sh" ? ["all"] : []
        reject("repositoryTests test arguments differ") unless test["arguments"] == expected_arguments
        reject("repositoryTests contains a failed test") unless test["status"] == "passed" && test["exitStatus"] == 0
        digest!(test["outputDigest"], "repositoryTests.tests[#{index}].outputDigest")
        started = iso8601!(test["startedAt"], "repositoryTests.tests[#{index}].startedAt")
        completed = iso8601!(test["completedAt"], "repositoryTests.tests[#{index}].completedAt")
        reject("repositoryTests test completion precedes its start") if completed < started
        test_paths << path
      end
      reject("repositoryTests test paths must be sorted and unique") unless test_paths == test_paths.sort && test_paths.uniq == test_paths
      reject("repositoryTests suite totals differ") unless
        suite["total"] == tests.length && suite["passed"] == tests.length && suite["failed"] == 0

      acceptance = value["acceptanceEvidence"]
      reject("repositoryTests acceptance evidence differs from Issue criteria") unless acceptance.is_a?(Array) && acceptance.length == criteria.length
      acceptance.each_with_index do |entry, index|
        exact_keys!(entry, %w[id status tests], "repositoryTests.acceptanceEvidence[#{index}]")
        reject("repositoryTests acceptance IDs differ") unless entry["id"] == criteria[index]["id"] && entry["status"] == "passed"
        references = unique_nonempty_strings!(entry["tests"], "repositoryTests.acceptanceEvidence[#{index}].tests", require_nonempty: true)
        reject("repositoryTests acceptance test reference is unknown") unless references.all? { |path| test_paths.include?(path) }
      end
      started_at = iso8601!(value["startedAt"], "repositoryTests.startedAt")
      completed_at = iso8601!(value["completedAt"], "repositoryTests.completedAt")
      reject("repositoryTests completion precedes its start") if completed_at < started_at
      tests.each do |test|
        reject("repositoryTests test time is outside the suite interval") if
          iso8601!(test["startedAt"], "repositoryTests test start") < started_at ||
          iso8601!(test["completedAt"], "repositoryTests test completion") > completed_at
      end
      value
    end

    def exact_packet_v2_keys!(packet)
      reject("packet must be an object") unless packet.is_a?(Hash)
      allowed = [PACKET_V2_KEYS.sort, PACKET_V2_REPOSITORY_TEST_KEYS.sort, PACKET_V2_REVISION_TEST_KEYS.sort]
      reject("packet: unexpected or missing keys") unless allowed.include?(packet.keys.sort)
    end

    def validate_contract!(packet, contract, contract_digest, issue, schema: packet["schemaVersion"])
      exact_keys!(packet["issueContract"], REFERENCE_KEYS, "packet.issueContract")
      expected_contract_path = ".artifacts/issues/#{issue}/issue-contract.json"
      reject("packet issue contract does not match exact bytes") unless
        packet["issueContract"] == {"path" => expected_contract_path, "digest" => contract_digest}
      validate_contract_keys!(contract, allow_legacy: schema == 1)
      reject("issue contract identity is invalid") unless contract["schemaVersion"] == 1 && contract["issue"] == issue
      digest!(contract["externalOperationDetailsDigest"], "issue contract.externalOperationDetailsDigest") if contract.key?("externalOperationDetailsDigest")
    end

    def validate_contract_keys!(contract, allow_legacy: false)
      required_sets = [CONTRACT_KEYS]
      required_sets << LEGACY_CONTRACT_KEYS if allow_legacy
      valid = contract.is_a?(Hash) && required_sets.any? do |required|
        required.all? { |key| contract.key?(key) } &&
          (contract.keys - required - CONTRACT_OPTIONAL_KEYS).empty?
      end
      reject("issue contract: unexpected or missing keys") unless valid
      contract
    end

    def validate_evidence_scope!(contract, verify)
      name = VerificationScope.validate_contract!(contract)
      application = verify["changeClassification"] == "application-code"
      reject("explicit Verification scope requires application-code verification") if contract.key?("verificationScope") && !application
      application ||= verify["changeClassification"].nil? && verify.dig("visualEvaluation", "status") == "passed"
      return unless application

      expected = VerificationScope.case_ids_for_contract(contract)
      configured = contract.dig("verification", "cases")
      if configured
        reject("contract verification cases differ from scope") unless configured.is_a?(Array) &&
          configured.all? { |entry| entry.is_a?(Hash) } && configured.map { |entry| entry["id"] } == expected
      end
      [verify["cases"], verify.dig("visualEvaluation", "cases")].each do |cases|
        reject("verification or visual cases differ from sealed scope") unless cases.is_a?(Array) &&
          cases.all? { |entry| entry.is_a?(Hash) } && cases.map { |entry| entry["id"] } == expected
      end
    rescue ArgumentError, TypeError => error
      reject(error.message)
    end

    def validate_scope!(packet, contract)
      anchors = unique_nonempty_strings!(packet["specAnchors"], "packet.specAnchors", require_nonempty: true)
      reject("packet spec anchors do not match issue contract") unless anchors == contract["specAnchors"]
      criteria = packet["acceptanceCriteria"]
      reject("packet.acceptanceCriteria must be a nonempty array") unless criteria.is_a?(Array) && !criteria.empty?
      criteria.each_with_index do |criterion, index|
        exact_keys!(criterion, %w[id text], "packet.acceptanceCriteria[#{index}]")
        reject("packet acceptance criteria must have ordered IDs") unless criterion["id"] == "AC-#{index + 1}"
        string!(criterion["text"], "packet.acceptanceCriteria[#{index}].text")
      end
      reject("packet acceptance criteria do not match issue contract") unless criteria == contract["acceptanceCriteria"]
      criteria
    end

    def validate_verify_identity!(packet, schema, verify, issue, base_sha, head_sha, contract_digest, require_temporal_order)
      if schema == 1
        prefix = ".artifacts/issues/#{issue}/#{head_sha}/"
        reject("packet.diffFile is not canonical") unless packet["diffFile"] == "#{prefix}review.diff"
        reject("packet.verifyFile is not canonical") unless packet["verifyFile"] == "#{prefix}verify.json"
        images = unique_nonempty_strings!(packet["imageFiles"], "packet.imageFiles")
        images.each { |path| safe_relative!(path, "packet.imageFiles") }
      end
      reject("verify identity does not match packet") unless
        verify.is_a?(Hash) && verify["schemaVersion"] == 1 && verify["issue"] == issue &&
        verify["baseSha"] == base_sha && verify["headSha"] == head_sha
      exact_keys!(verify["issueContract"], REFERENCE_KEYS, "verify.issueContract")
      reject("verify issue contract does not match packet") unless
        verify["issueContract"] == {"path" => ".artifacts/issues/#{issue}/issue-contract.json", "digest" => contract_digest}
      iso8601!(verify["completedAt"], "verify.completedAt") if require_temporal_order
    end

    def validate_strict_closure!(packet:, packet_bytes:, verify:, verify_bytes:, issue:, head_sha:, diff_bytes:, image_bytes:, actual_diff_bytes:)
      references = strict_references!(packet_bytes: packet_bytes, issue: issue, head_sha: head_sha)
      reject("strict review validation requires held diff bytes") unless diff_bytes.is_a?(String)
      reject("strict review validation requires independently generated actual diff bytes") unless actual_diff_bytes.is_a?(String)
      reject("review.diff bytes are not the deterministic actual Base..Head diff") unless diff_bytes.b == actual_diff_bytes.b
      reject("packet.diff.digest does not match held review.diff bytes") unless references["diff"]["digest"] == digest(diff_bytes)
      reject("packet.verify.digest does not match held verify.json bytes") unless references["verify"]["digest"] == digest(verify_bytes)
      expected_images = verified_image_references!(verify, issue: issue, head_sha: head_sha)
      reject("packet.imageFiles are not the ordered canonical verified visual evidence") unless packet["imageFiles"] == expected_images
      reject("strict review validation requires held image bytes") unless image_bytes.is_a?(Hash)
      reject("held image set differs from the packet") unless image_bytes.keys == expected_images.map { |entry| entry["path"] }
      expected_images.each do |entry|
        bytes = image_bytes[entry["path"]]
        reject("held image bytes are unavailable: #{entry['path']}") unless bytes.is_a?(String)
        reject("held image digest differs from packet: #{entry['path']}") unless digest(bytes) == entry["digest"]
      end
    end

    # Classify without probing the filesystem: a failed source lookup must not
    # fall through to some other file with the same name.
    def finding_reference!(file, packet, at:)
      safe_relative!(string!(file, at), at)
      prefix = ".artifacts/issues/#{packet.fetch('issue')}/#{packet.fetch('headSha')}/"
      if file.start_with?(".artifacts/")
        reject("#{at} is outside the current Issue/Head") unless file.start_with?(prefix) || file == packet.fetch("issueContract").fetch("path")
        return ["artifact", file]
      end
      images = packet.fetch("imageFiles").map { |entry| entry.is_a?(Hash) ? entry.fetch("path").delete_prefix(prefix) : entry }
      aliases = %w[verify.json review.diff review-packet.json]
      aliases << "repository-tests.json" if packet.key?("repositoryTests")
      return ["artifact", prefix + file] if (aliases + images).include?(file)
      ["source", file]
    end

    def validate_result!(result, schema, packet_bytes, reviewer, issue, base_sha, head_sha, contract_digest, criteria, completed_at, now, require_temporal_order)
      exact_keys!(result, schema == 2 ? RESULT_V2_KEYS : RESULT_V1_KEYS, "result")
      reject("result.schemaVersion must equal packet.schemaVersion") unless result["schemaVersion"] == schema
      reject("result identity does not match packet") unless
        result["issue"] == issue && result["reviewerModel"] == reviewer &&
        result["baseSha"] == base_sha && result["headSha"] == head_sha &&
        result["verifySha"] == head_sha && result["issueContractDigest"] == contract_digest
      if schema == 2
        digest!(result["reviewPacketDigest"], "result.reviewPacketDigest")
        reject("result.reviewPacketDigest does not match exact packet bytes") unless result["reviewPacketDigest"] == digest(packet_bytes)
      end
      verdict = result["verdict"]
      reject("result.verdict is invalid") unless %w[approved changes-requested].include?(verdict)
      findings = result["findings"]
      reject("result.findings must be an array") unless findings.is_a?(Array)
      findings.each_with_index do |finding, index|
        exact_keys!(finding, %w[severity category file line title evidence requiredChange], "result.findings[#{index}]")
        reject("result.findings[#{index}].severity is invalid") unless %w[critical high medium low].include?(finding["severity"])
        reject("result.findings[#{index}].category is invalid") unless string!(finding["category"], "result.findings[#{index}].category").match?(/\A[a-z][a-z-]*\z/)
        finding_reference!(finding["file"], JSON.parse(packet_bytes), at: "result.findings[#{index}].file")
        reject("result.findings[#{index}].line must be positive") unless finding["line"].is_a?(Integer) && finding["line"].positive?
        %w[title evidence requiredChange].each { |key| string!(finding[key], "result.findings[#{index}].#{key}") }
      end
      assessments = result["acceptanceAssessment"]
      reject("result.acceptanceAssessment must match packet criteria") unless assessments.is_a?(Array) && assessments.length == criteria.length
      assessments.each_with_index do |assessment, index|
        exact_keys!(assessment, %w[id status evidence], "result.acceptanceAssessment[#{index}]")
        reject("result.acceptanceAssessment IDs must match packet") unless assessment["id"] == criteria[index]["id"]
        reject("result.acceptanceAssessment status is invalid") unless %w[supported unsupported].include?(assessment["status"])
        evidence = unique_nonempty_strings!(assessment["evidence"], "result.acceptanceAssessment[#{index}].evidence", require_nonempty: true)
        evidence.each { |reference| safe_reference!(reference, "result.acceptanceAssessment[#{index}].evidence") }
      end
      reviewed_at = iso8601!(result["reviewedAt"], "result.reviewedAt")
      reject("result.reviewedAt must be after verify.completedAt") if require_temporal_order && reviewed_at <= completed_at
      reject("result.reviewedAt is implausibly in the future") if reviewed_at > now + 300
      if verdict == "approved"
        reject("approved result must have no findings") unless findings.empty?
        reject("approved result must support every acceptance criterion") unless assessments.all? { |entry| entry["status"] == "supported" }
      else
        blocking = findings.any? { |finding| %w[critical high medium].include?(finding["severity"]) } || assessments.any? { |entry| entry["status"] == "unsupported" }
        reject("changes-requested result must contain a blocking finding or unsupported criterion") unless blocking
      end
    end

    def parse_object(bytes, at)
      # Preserve descriptor-held evidence strings. JSON.parse may retag its
      # input as UTF-8 when the JSON contains non-ASCII text.
      value = JSON.parse(bytes.dup)
      reject("#{at} must be an object") unless value.is_a?(Hash)
      value
    rescue JSON::ParserError => error
      reject("#{at} is not readable JSON: #{error.message}")
    end

    def exact_keys!(value, keys, at)
      reject("#{at} must be an object") unless value.is_a?(Hash)
      reject("#{at}: unexpected or missing keys") unless value.keys.sort == keys.sort
    end

    def string!(value, at)
      reject("#{at} must be a nonempty string") unless value.is_a?(String) && !value.empty? && !value.include?("\0")
      value
    end

    def sha!(value, at)
      reject("#{at} must be a lowercase 40-character SHA") unless value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/)
      value
    end

    def digest(value)
      "sha256:#{Digest::SHA256.hexdigest(value)}"
    end

    def digest!(value, at)
      reject("#{at} must be a sha256 digest") unless value.is_a?(String) && value.match?(DIGEST_PATTERN)
      value
    end

    def reference!(value, at)
      exact_keys!(value, REFERENCE_KEYS, at)
      safe_relative!(string!(value["path"], "#{at}.path"), "#{at}.path")
      digest!(value["digest"], "#{at}.digest")
      value
    end

    def unique_nonempty_strings!(value, at, require_nonempty: false)
      reject("#{at} must be an array") unless value.is_a?(Array)
      reject("#{at} must not be empty") if require_nonempty && value.empty?
      reject("#{at} must contain unique nonempty strings") unless value.uniq == value && value.all? { |entry| entry.is_a?(String) && !entry.empty? && !entry.include?("\0") }
      value
    end

    def safe_relative!(value, at)
      reject("#{at} must be a safe relative path") if value.start_with?("/") || value.split("/").any? { |part| part.empty? || part == "." || part == ".." }
      value
    end

    def safe_reference!(value, at)
      reject("#{at} must be a safe relative reference") if value.start_with?("/") || value.split("#", 2).first.split("/").include?("..")
    end

    def iso8601!(value, at)
      Time.iso8601(string!(value, at)).utc
    rescue ArgumentError
      reject("#{at} must be ISO 8601")
    end

    def reject(message)
      raise ValidationError, message
    end
  end
end
