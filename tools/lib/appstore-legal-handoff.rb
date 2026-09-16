#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "digest"
require "json"
require "open3"
require "pathname"
require "tempfile"
require "time"
require "uri"

module AppStoreLegalHandoff
  TARGET_REPOSITORY = "yuto1201/Web-AppLibrary"
  KINDS = %w[support privacy terms].freeze
  LOCALES = %w[en-US ja].freeze
  SECRET_PATTERN = /(-----BEGIN [A-Z ]*PRIVATE KEY-----|\bBearer\s+\S+|\b(?:api[_-]?key|access[_-]?token|password)\s*[:=]\s*\S+)/i
  SHA_PATTERN = /\A[0-9a-f]{40}\z/
  DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/

  class Failure < StandardError; end

  module_function

  def run(argv)
    command = argv.shift or fail!("command is required: render, record-issue, or verify-publication")
    options = parse_options(argv)
    value = case command
            when "render" then render(options)
            when "record-issue" then record_issue(options)
            when "verify-publication" then verify_publication(options)
            else fail!("unknown command: #{command}")
            end
    puts JSON.generate(value)
  rescue Failure, JSON::ParserError, KeyError, URI::InvalidURIError, ArgumentError => error
    warn error.message
    exit 1
  end

  def parse_options(argv)
    options = {}
    until argv.empty?
      key = argv.shift
      fail!("unexpected argument: #{key}") unless key&.start_with?("--")
      value = argv.shift
      fail!("missing value for #{key}") if value.nil? || value.start_with?("--")
      name = key.delete_prefix("--")
      fail!("duplicate option: #{key}") if options.key?(name)
      options[name] = value
    end
    options
  end

  def render(options)
    require_options!(options, %w[repo-root request output])
    root = canonical_root(options.fetch("repo-root"))
    request_path = safe_input(root, options.fetch("request"), "request")
    request_bytes = File.binread(request_path)
    request = parse_object(request_bytes, "request")
    context = validate_request(root, request)
    output = safe_new_output(root, options.fetch("output"), "prompt output")
    body = render_prompt(request, context)
    write_new(output, body)
    {
      "schemaVersion" => 1,
      "status" => "rendered",
      "title" => issue_title(request),
      "targetRepository" => TARGET_REPOSITORY,
      "requestDigest" => digest(request_bytes),
      "promptDigest" => digest(body),
      "output" => relative(root, output)
    }
  end

  def record_issue(options)
    require_options!(options, %w[repo-root request prompt readback output now])
    root = canonical_root(options.fetch("repo-root"))
    request_path = safe_input(root, options.fetch("request"), "request")
    prompt_path = safe_input(root, options.fetch("prompt"), "prompt")
    readback_path = safe_input(root, options.fetch("readback"), "issue readback")
    request_bytes = File.binread(request_path)
    prompt_bytes = File.binread(prompt_path)
    request = parse_object(request_bytes, "request")
    context = validate_request(root, request)
    fail!("prompt differs from the deterministic request rendering") unless prompt_bytes == render_prompt(request, context).b
    readback = parse_object(File.binread(readback_path), "issue readback")
    exact_keys!(readback, %w[number url title body state], "issue readback")
    number = integer!(readback.fetch("number"), "issue readback.number", minimum: 1)
    expected_url = "https://github.com/#{TARGET_REPOSITORY}/issues/#{number}"
    fail!("issue readback must target #{TARGET_REPOSITORY}") unless readback.fetch("url") == expected_url
    fail!("issue readback title differs from rendered title") unless readback.fetch("title") == issue_title(request)
    fail!("issue readback body differs from rendered prompt") unless readback.fetch("body").b == prompt_bytes
    fail!("issue readback state must be OPEN") unless readback.fetch("state") == "OPEN"
    now = utc_time!(options.fetch("now"), "now")
    output = safe_new_output(root, options.fetch("output"), "issue record output")
    record = {
      "schemaVersion" => 1,
      "handoffId" => request.fetch("handoffId"),
      "status" => "awaiting-user-handoff",
      "request" => {"path" => relative(root, request_path), "digest" => digest(request_bytes)},
      "prompt" => {"path" => relative(root, prompt_path), "digest" => digest(prompt_bytes)},
      "webIssue" => {"repository" => TARGET_REPOSITORY, "number" => number, "url" => expected_url, "state" => "OPEN"},
      "recordedAt" => now
    }
    write_new(output, canonical_json(record))
    record
  end

  def verify_publication(options)
    required = %w[repo-root request prompt issue-record publication output now]
    missing = required - options.keys
    fail!("missing options: #{missing.join(", ")}") unless missing.empty?
    fixture_mode = options.key?("response-fixture")
    fail!("unknown options: #{(options.keys - required - ["response-fixture"]).sort.join(", ")}") unless (options.keys - required - ["response-fixture"]).empty?

    root = canonical_root(options.fetch("repo-root"))
    request_path = safe_input(root, options.fetch("request"), "request")
    prompt_path = safe_input(root, options.fetch("prompt"), "prompt")
    issue_record_path = safe_input(root, options.fetch("issue-record"), "issue record")
    publication_path = safe_input(root, options.fetch("publication"), "publication return")
    request_bytes = File.binread(request_path)
    prompt_bytes = File.binread(prompt_path)
    request = parse_object(request_bytes, "request")
    context = validate_request(root, request)
    fail!("prompt differs from the deterministic request rendering") unless prompt_bytes == render_prompt(request, context).b
    issue_record = parse_object(File.binread(issue_record_path), "issue record")
    publication = parse_object(File.binread(publication_path), "publication return")
    validate_issue_record!(issue_record, request, request_bytes, prompt_bytes)
    validate_publication!(publication, request, request_bytes, prompt_bytes, issue_record)

    responses = if fixture_mode
                  fixture = parse_object(File.binread(safe_input(root, options.fetch("response-fixture"), "response fixture")), "response fixture")
                  exact_keys!(fixture, %w[schemaVersion responses], "response fixture")
                  fail!("response fixture schemaVersion must be 1") unless fixture.fetch("schemaVersion") == 1
                  array!(fixture.fetch("responses"), "response fixture.responses")
                else
                  publication.fetch("pages").map { |page| fetch_public_page(page.fetch("url")) }
                end

    expected_pages = expected_page_map(request)
    fail!("public response count differs from requested pages") unless responses.length == expected_pages.length
    response_map = responses.to_h do |response|
      exact_keys!(response, %w[url finalURL status body], "public response")
      [string!(response.fetch("url"), "public response.url"), response]
    end
    fail!("public responses contain duplicate URLs") unless response_map.length == responses.length

    page_results = publication.fetch("pages").map do |page|
      key = page.values_at("locale", "kind")
      expected = expected_pages.fetch(key)
      response = response_map.fetch(page.fetch("url")) { fail!("public response missing for #{page.fetch("url")}") }
      validate_public_response!(response, page.fetch("url"), request.fetch("webHost"))
      source_text = context.fetch(:documents).fetch(key).fetch(:text)
      content_matches!(source_text, response.fetch("body"), page.fetch("url"))
      sibling_urls = expected_pages.select { |(locale, _kind), _value| locale == page.fetch("locale") }
                                   .values.map { |value| value.fetch(:url) } - [page.fetch("url")]
      links = absolute_links(response.fetch("body"), page.fetch("url"))
      missing_links = sibling_urls.reject { |url| links.include?(url) }
      fail!("public page interlink is missing for #{missing_links.join(", ")}") unless missing_links.empty?
      {
        "kind" => page.fetch("kind"), "locale" => page.fetch("locale"), "url" => expected.fetch(:url),
        "sourceDigest" => page.fetch("sourceDigest"), "httpStatus" => 200,
        "contentMatched" => true, "interlinks" => sibling_urls.sort
      }
    end.sort_by { |entry| [LOCALES.index(entry.fetch("locale")), KINDS.index(entry.fetch("kind"))] }

    output = safe_new_output(root, options.fetch("output"), "publication verification output")
    result = {
      "schemaVersion" => 1,
      "handoffId" => request.fetch("handoffId"),
      "status" => fixture_mode ? "fixture-validated" : "verified",
      "appStoreEligible" => !fixture_mode,
      "requestDigest" => digest(request_bytes),
      "promptDigest" => digest(prompt_bytes),
      "webIssueURL" => issue_record.fetch("webIssue").fetch("url"),
      "deploymentReference" => publication.fetch("deploymentReference"),
      "userApprovals" => publication.fetch("userActions"),
      "pages" => page_results,
      "verifiedAt" => utc_time!(options.fetch("now"), "now")
    }
    write_new(output, canonical_json(result))
    result
  end

  def validate_request(root, request)
    exact_keys!(request, %w[schemaVersion handoffId source app webHost locales facts documents routes expectedReturn], "request")
    fail!("request schemaVersion must be 1") unless request.fetch("schemaVersion") == 1
    identifier!(request.fetch("handoffId"), "request.handoffId")
    source = object!(request.fetch("source"), "request.source")
    exact_keys!(source, %w[repository issue headSha], "request.source")
    repository!(source.fetch("repository"), "request.source.repository")
    integer!(source.fetch("issue"), "request.source.issue", minimum: 1)
    fail!("request.source.headSha must be a 40-character lowercase SHA") unless source.fetch("headSha").match?(SHA_PATTERN)
    app = object!(request.fetch("app"), "request.app")
    exact_keys!(app, %w[name bundleId platforms], "request.app")
    nonempty!(app.fetch("name"), "request.app.name")
    fail!("request.app.bundleId is invalid") unless app.fetch("bundleId").match?(/\A[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z/)
    platforms = string_array!(app.fetch("platforms"), "request.app.platforms")
    fail!("request.app.platforms must contain only iOS and iPadOS") unless (platforms - %w[iOS iPadOS]).empty?
    validate_host!(request.fetch("webHost"))
    locales = string_array!(request.fetch("locales"), "request.locales")
    fail!("request.locales must be exactly en-US and ja") unless locales == LOCALES
    validate_facts!(request.fetch("facts"))
    expected_return = string_array!(request.fetch("expectedReturn"), "request.expectedReturn")
    fail!("request.expectedReturn differs from the return contract") unless expected_return == %w[deployment-reference public-urls source-digests]

    documents = array!(request.fetch("documents"), "request.documents")
    routes = array!(request.fetch("routes"), "request.routes")
    expected_pairs = LOCALES.product(KINDS)
    fail!("request.documents must contain every locale/kind exactly once") unless pair_list(documents, "documents") == expected_pairs
    fail!("request.routes must contain every locale/kind exactly once") unless pair_list(routes, "routes") == expected_pairs

    document_map = {}
    documents.each_with_index do |document, index|
      path = "request.documents[#{index}]"
      exact_keys!(document, %w[kind locale path digest approvalReference], path)
      approval_reference!(document.fetch("approvalReference"), "#{path}.approvalReference")
      source_path = safe_input(root, document.fetch("path"), "#{path}.path")
      bytes = File.binread(source_path)
      fail!("#{path}.digest is invalid") unless document.fetch("digest").match?(DIGEST_PATTERN)
      fail!("#{path}.digest does not match source bytes") unless document.fetch("digest") == digest(bytes)
      text = bytes.force_encoding(Encoding::UTF_8)
      fail!("#{path}.path is not valid UTF-8") unless text.valid_encoding?
      fail!("#{path}.path must contain Status: Confirmed") unless text.lines.any? { |line| line.strip == "Status: Confirmed" }
      fail!("#{path}.path contains secret-like text") if text.match?(SECRET_PATTERN)
      document_map[document.values_at("locale", "kind")] = {text: text, path: relative(root, source_path)}
    end

    route_paths = []
    routes.each_with_index do |route, index|
      path = "request.routes[#{index}]"
      exact_keys!(route, %w[kind locale path approvalReference], path)
      approval_reference!(route.fetch("approvalReference"), "#{path}.approvalReference")
      route_value = route.fetch("path")
      validate_route!(route_value, "#{path}.path")
      route_paths << route_value
    end
    fail!("request.routes contains duplicate paths") unless route_paths.uniq.length == route_paths.length
    {documents: document_map}
  end

  def validate_facts!(facts)
    facts = object!(facts, "request.facts")
    exact_keys!(facts, %w[features dataUse advertising purchases], "request.facts")
    %w[features dataUse].each { |name| string_array!(facts.fetch(name), "request.facts.#{name}") }
    %w[advertising purchases].each do |name|
      item = object!(facts.fetch(name), "request.facts.#{name}")
      exact_keys!(item, %w[status summary], "request.facts.#{name}")
      nonempty!(item.fetch("status"), "request.facts.#{name}.status")
      nonempty!(item.fetch("summary"), "request.facts.#{name}.summary")
    end
    fail!("request.facts contains secret-like text") if JSON.generate(facts).match?(SECRET_PATTERN)
  end

  def validate_issue_record!(record, request, request_bytes, prompt_bytes)
    exact_keys!(record, %w[schemaVersion handoffId status request prompt webIssue recordedAt], "issue record")
    fail!("issue record schemaVersion must be 1") unless record.fetch("schemaVersion") == 1
    fail!("issue record handoffId differs") unless record.fetch("handoffId") == request.fetch("handoffId")
    fail!("issue record status is invalid") unless record.fetch("status") == "awaiting-user-handoff"
    request_reference = object!(record.fetch("request"), "issue record.request")
    exact_keys!(request_reference, %w[path digest], "issue record.request")
    prompt_reference = object!(record.fetch("prompt"), "issue record.prompt")
    exact_keys!(prompt_reference, %w[path digest], "issue record.prompt")
    fail!("issue record request digest differs") unless request_reference.fetch("digest") == digest(request_bytes)
    fail!("issue record prompt digest differs") unless prompt_reference.fetch("digest") == digest(prompt_bytes)
    issue = object!(record.fetch("webIssue"), "issue record.webIssue")
    exact_keys!(issue, %w[repository number url state], "issue record.webIssue")
    fail!("issue record must target #{TARGET_REPOSITORY}") unless issue.fetch("repository") == TARGET_REPOSITORY
    integer!(issue.fetch("number"), "issue record.webIssue.number", minimum: 1)
    expected = "https://github.com/#{TARGET_REPOSITORY}/issues/#{issue.fetch("number")}"
    fail!("issue record URL differs") unless issue.fetch("url") == expected
    fail!("issue record state must be OPEN") unless issue.fetch("state") == "OPEN"
    utc_time!(record.fetch("recordedAt"), "issue record.recordedAt")
  end

  def validate_publication!(publication, request, request_bytes, prompt_bytes, issue_record)
    exact_keys!(publication, %w[schemaVersion handoffId requestDigest promptDigest webIssueURL deploymentReference userActions pages], "publication return")
    fail!("publication return schemaVersion must be 1") unless publication.fetch("schemaVersion") == 1
    fail!("publication return handoffId differs") unless publication.fetch("handoffId") == request.fetch("handoffId")
    fail!("publication return requestDigest differs") unless publication.fetch("requestDigest") == digest(request_bytes)
    fail!("publication return promptDigest differs") unless publication.fetch("promptDigest") == digest(prompt_bytes)
    fail!("publication return Web-AppLibrary Issue differs") unless publication.fetch("webIssueURL") == issue_record.fetch("webIssue").fetch("url")
    github_reference!(publication.fetch("deploymentReference"), "publication return.deploymentReference")
    actions = object!(publication.fetch("userActions"), "publication return.userActions")
    exact_keys!(actions, %w[promptForwarded publicationApproved], "publication return.userActions")
    actions.each do |name, action|
      action = object!(action, "publication return.userActions.#{name}")
      exact_keys!(action, %w[actor reference at], "publication return.userActions.#{name}")
      fail!("publication approvals must be performed by the user") unless action.fetch("actor") == "user"
      approval_reference!(action.fetch("reference"), "publication return.userActions.#{name}.reference")
      utc_time!(action.fetch("at"), "publication return.userActions.#{name}.at")
    end
    pages = array!(publication.fetch("pages"), "publication return.pages")
    expected = expected_page_map(request)
    fail!("publication return pages differ from requested pages") unless pair_list(pages, "publication pages") == LOCALES.product(KINDS)
    pages.each_with_index do |page, index|
      path = "publication return.pages[#{index}]"
      exact_keys!(page, %w[kind locale url sourceDigest], path)
      page_expected = expected.fetch(page.values_at("locale", "kind"))
      fail!("#{path}.url differs from approved route") unless page.fetch("url") == page_expected.fetch(:url)
      fail!("#{path}.sourceDigest differs from approved source") unless page.fetch("sourceDigest") == page_expected.fetch(:digest)
    end
  end

  def expected_page_map(request)
    documents = request.fetch("documents").to_h { |item| [item.values_at("locale", "kind"), item] }
    request.fetch("routes").to_h do |route|
      key = route.values_at("locale", "kind")
      [key, {url: "https://#{request.fetch("webHost")}#{route.fetch("path")}", digest: documents.fetch(key).fetch("digest")}]
    end
  end

  def render_prompt(request, context)
    lines = []
    lines << "# #{issue_title(request)}"
    lines << ""
    lines << "Target repository: `#{TARGET_REPOSITORY}`"
    lines << "Source: `#{request.dig("source", "repository")}##{request.dig("source", "issue")}` at `#{request.dig("source", "headSha")}`"
    lines << "Handoff ID: `#{request.fetch("handoffId")}`"
    lines << ""
    lines << "## Goal"
    lines << ""
    lines << "Publish the confirmed support, privacy, and terms pages for #{request.dig("app", "name")} at the approved routes below. Use 1 Issue = 1 Branch = 1 PR and preserve the source text and locale identity."
    lines << ""
    lines << "## Confirmed app facts"
    lines << ""
    lines << "- Bundle ID: `#{request.dig("app", "bundleId")}`"
    lines << "- Platforms: #{request.dig("app", "platforms").join(", ")}"
    request.dig("facts", "features").each { |value| lines << "- Feature: #{value}" }
    request.dig("facts", "dataUse").each { |value| lines << "- Data use: #{value}" }
    %w[advertising purchases].each do |name|
      value = request.dig("facts", name)
      lines << "- #{name.capitalize}: #{value.fetch("status")} — #{value.fetch("summary")}"
    end
    lines << ""
    lines << "## User-controlled handoff and approval"
    lines << ""
    lines << "The user forwards this prompt to the Web implementation agent and retains final approval of legal text and publication. AI review, this Issue, and a deployment do not grant that approval. Do not publish until the user's approval references are recorded."
    lines << ""
    lines << "## Approved routes and exact source text"
    lines << ""
    request.fetch("routes").each do |route|
      key = route.values_at("locale", "kind")
      source = request.fetch("documents").find { |item| item.values_at("locale", "kind") == key }
      lines << "### #{route.fetch("locale")} / #{route.fetch("kind")}"
      lines << ""
      lines << "- Route: `https://#{request.fetch("webHost")}#{route.fetch("path")}`"
      lines << "- Source: `#{context.fetch(:documents).fetch(key).fetch(:path)}`"
      lines << "- Source digest: `#{source.fetch("digest")}`"
      lines << "- Source approval: #{source.fetch("approvalReference")}"
      lines << "- Route approval: #{route.fetch("approvalReference")}"
      lines << ""
      lines << "```markdown"
      lines << context.fetch(:documents).fetch(key).fetch(:text).rstrip
      lines << "```"
      lines << ""
    end
    lines << "## Acceptance checks"
    lines << ""
    lines << "- Every URL returns HTTP 200 without authentication or an account."
    lines << "- Every public page matches its approved source text and locale."
    lines << "- Each locale's support, privacy, and terms pages link to the other two pages in that locale."
    lines << "- Read the created Issue back from exactly `#{TARGET_REPOSITORY}` before implementation starts."
    lines << ""
    lines << "## Expected return contract"
    lines << ""
    lines << "Return the deployment reference, the six exact public URLs with source digests, the Web-AppLibrary Issue URL, and the user's prompt-forward/publication approval references. Do not return credentials or authenticated transcripts."
    lines << ""
    lines.join("\n")
  end

  def fetch_public_page(url)
    validate_public_url!(url, URI.parse(url).host)
    Tempfile.create("legal-page") do |file|
      command = ["/usr/bin/curl", "--silent", "--show-error", "--fail", "--max-time", "20", "--connect-timeout", "10", "--output", file.path, "--write-out", "%{http_code}\n%{url_effective}", url]
      stdout, stderr, status = Open3.capture3(*command)
      fail!("public page fetch failed for #{url}: #{stderr.strip}") unless status.success?
      http_status, final_url = stdout.lines.map(&:strip)
      {"url" => url, "finalURL" => final_url, "status" => http_status.to_i, "body" => File.binread(file.path).force_encoding(Encoding::UTF_8)}
    end
  end

  def validate_public_response!(response, expected_url, expected_host)
    fail!("public response URL differs") unless response.fetch("url") == expected_url
    fail!("public page must return HTTP 200") unless response.fetch("status") == 200
    validate_public_url!(response.fetch("finalURL"), expected_host)
    fail!("public page redirected away from its approved URL") unless response.fetch("finalURL") == expected_url
    body = string!(response.fetch("body"), "public response.body")
    fail!("public page body is not valid UTF-8") unless body.valid_encoding?
  end

  def content_matches!(source, html, url)
    source_blocks = source.lines.map(&:strip).reject(&:empty?).reject { |line| line == "Status: Confirmed" }
                          .map { |line| normalize_text(line.sub(/\A#+\s*/, "")) }.reject(&:empty?)
    public_text = normalize_text(CGI.unescapeHTML(html.gsub(/<script\b.*?<\/script>/mi, " ").gsub(/<style\b.*?<\/style>/mi, " ").gsub(/<[^>]+>/m, " ")))
    fail!("public page does not match approved source text: #{url}") unless source_blocks.all? { |block| public_text.include?(block) }
  end

  def normalize_text(value)
    value.gsub(/[`*_>#\[\]()]/, " ").gsub(/\s+/, " ").strip
  end

  def absolute_links(html, base)
    html.scan(/\bhref\s*=\s*["']([^"']+)["']/i).flatten.each_with_object([]) do |href, values|
      uri = URI.join(base, CGI.unescapeHTML(href))
      next unless uri.is_a?(URI::HTTPS)
      uri.fragment = nil
      values << uri.to_s
    rescue URI::InvalidURIError
      next
    end.uniq
  end

  def pair_list(items, label)
    pairs = items.map.with_index do |item, index|
      item = object!(item, "#{label}[#{index}]")
      locale = string!(item.fetch("locale"), "#{label}[#{index}].locale")
      kind = string!(item.fetch("kind"), "#{label}[#{index}].kind")
      fail!("#{label}[#{index}].locale is unsupported") unless LOCALES.include?(locale)
      fail!("#{label}[#{index}].kind is unsupported") unless KINDS.include?(kind)
      [locale, kind]
    end
    fail!("#{label} contains duplicate locale/kind pairs") unless pairs.uniq.length == pairs.length
    pairs.sort_by { |locale, kind| [LOCALES.index(locale), KINDS.index(kind)] }
  end

  def validate_route!(value, label)
    value = string!(value, label)
    uri = URI.parse(value)
    fail!("#{label} must be an absolute path without query or fragment") unless value.start_with?("/") && uri.host.nil? && uri.query.nil? && uri.fragment.nil?
    fail!("#{label} contains unsafe path syntax") if value.include?("%") || value.include?("\\") || value.include?("//")
    fail!("#{label} contains unsafe path components") if Pathname.new(value).each_filename.any? { |part| part == "." || part == ".." }
  end

  def validate_host!(host)
    host = string!(host, "request.webHost")
    fail!("request.webHost is invalid") unless host.match?(/\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/)
  end

  def validate_public_url!(value, host)
    uri = URI.parse(value)
    fail!("public URL must use HTTPS and the approved host") unless uri.is_a?(URI::HTTPS) && uri.host == host && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
  end

  def approval_reference!(value, label)
    uri = URI.parse(string!(value, label))
    fail!("#{label} must be an HTTPS GitHub Issue comment") unless uri.is_a?(URI::HTTPS) && uri.host == "github.com" && uri.path.match?(%r{\A/[^/]+/[^/]+/issues/\d+\z}) && uri.fragment&.match?(/\Aissuecomment-\d+\z/)
  end

  def github_reference!(value, label)
    uri = URI.parse(string!(value, label))
    fail!("#{label} must be an HTTPS GitHub reference") unless uri.is_a?(URI::HTTPS) && uri.host == "github.com" && uri.path.match?(%r{\A/[^/]+/[^/]+/(?:issues|pull)/\d+\z})
  end

  def canonical_root(value)
    root = File.realpath(value)
    fail!("repo root is not a directory") unless File.directory?(root)
    root
  rescue Errno::ENOENT
    fail!("repo root does not exist")
  end

  def safe_input(root, value, label)
    candidate = absolute_candidate(root, value)
    real = File.realpath(candidate)
    fail!("#{label} escapes repo root") unless inside?(root, real)
    stat = File.lstat(candidate)
    fail!("#{label} must be a regular non-symlink file") unless stat.file? && !stat.symlink?
    real
  rescue Errno::ENOENT
    fail!("#{label} does not exist")
  end

  def safe_new_output(root, value, label)
    candidate = absolute_candidate(root, value)
    fail!("#{label} already exists") if File.exist?(candidate) || File.symlink?(candidate)
    parent = File.dirname(candidate)
    fail!("#{label} parent does not exist") unless File.directory?(parent)
    real_parent = File.realpath(parent)
    fail!("#{label} parent escapes repo root") unless inside?(root, real_parent)
    File.join(real_parent, File.basename(candidate))
  end

  def absolute_candidate(root, value)
    value = string!(value, "path")
    Pathname.new(value).absolute? ? value : File.join(root, value)
  end

  def inside?(root, path)
    path == root || path.start_with?(root + File::SEPARATOR)
  end

  def relative(root, path)
    Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
  end

  def write_new(path, content)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(content) }
  end

  def issue_title(request)
    "[Legal pages]: #{request.dig("app", "name")} privacy, terms, and support"
  end

  def canonical_json(value)
    JSON.pretty_generate(sort_json(value)) + "\n"
  end

  def sort_json(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, sort_json(value.fetch(key))] }
    when Array then value.map { |item| sort_json(item) }
    else value
    end
  end

  def digest(value)
    bytes = value.is_a?(String) ? value.b : value
    "sha256:#{Digest::SHA256.hexdigest(bytes)}"
  end

  def parse_object(bytes, label)
    value = JSON.parse(bytes)
    object!(value, label)
  end

  def exact_keys!(value, keys, label)
    object!(value, label)
    missing = keys - value.keys
    unknown = value.keys - keys
    return if missing.empty? && unknown.empty?
    fail!("#{label} keys differ (missing: #{missing.join(", ")}; unknown: #{unknown.join(", ")})")
  end

  def require_options!(options, keys)
    missing = keys - options.keys
    unknown = options.keys - keys
    fail!("missing options: #{missing.join(", ")}") unless missing.empty?
    fail!("unknown options: #{unknown.join(", ")}") unless unknown.empty?
  end

  def object!(value, label)
    fail!("#{label} must be an object") unless value.is_a?(Hash)
    value
  end

  def array!(value, label)
    fail!("#{label} must be an array") unless value.is_a?(Array)
    value
  end

  def string!(value, label)
    fail!("#{label} must be a string") unless value.is_a?(String)
    value
  end

  def nonempty!(value, label)
    value = string!(value, label)
    fail!("#{label} must not be empty") if value.strip.empty?
    value
  end

  def identifier!(value, label)
    value = string!(value, label)
    fail!("#{label} is invalid") unless value.match?(/\A[a-z0-9](?:[a-z0-9._-]{0,126}[a-z0-9])?\z/i)
  end

  def repository!(value, label)
    value = string!(value, label)
    fail!("#{label} is invalid") unless value.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z})
  end

  def integer!(value, label, minimum: nil)
    fail!("#{label} must be an integer") unless value.is_a?(Integer)
    fail!("#{label} is below minimum") if minimum && value < minimum
    value
  end

  def string_array!(value, label)
    array = array!(value, label)
    fail!("#{label} must be a nonempty string array") if array.empty? || array.any? { |item| !item.is_a?(String) || item.strip.empty? }
    fail!("#{label} must not contain duplicates") unless array.uniq.length == array.length
    array
  end

  def utc_time!(value, label)
    parsed = Time.iso8601(string!(value, label))
    fail!("#{label} must be an exact UTC timestamp") unless parsed.utc? && value.end_with?("Z")
    value
  rescue ArgumentError
    fail!("#{label} must be an ISO 8601 UTC timestamp")
  end

  def fail!(message)
    raise Failure, message
  end
end

AppStoreLegalHandoff.run(ARGV)
