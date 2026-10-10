#!/usr/bin/env ruby
# frozen_string_literal: true

# Prepares an app's anonymous in-app feedback (D-076) in the repository that runs it: the private
# feedback repository and its labels, the app's Cloudflare Worker with its secrets, and the host the
# app sends to. `plan` only reads; `apply` changes nothing unless the user approved the same plan;
# `check-delivery` runs apply for the approved plan and then sends one real submission. Secrets go to
# child processes on stdin only.

require "base64"
require "digest"
require "fileutils"
require "json"
require "open3"
require "openssl"
require "securerandom"
require_relative "ownership"

module IOSTemplate
  module AppFeedbackProvision
    class Refused < StandardError; end

    # Waiting for the user to install the shared GitHub App on the feedback repository.
    class WaitingForInstallation < StandardError; end

    WRANGLER_VERSION = "4.147.0"
    SKILL = ".agents/skills/app-feedback"
    TEMPLATE = "#{SKILL}/templates/feedback-worker"
    WORKER_DIRECTORY = "Services/feedback-worker"
    RECORD = "Config/app-feedback.json"
    IDENTITY = "Config/app-identity.json"
    IDENTITY_KEYS = %w[appSlug bundleId displayName moduleName schemaVersion sourceIdentityVersion].freeze
    SECRET_NAMES = %w[GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_SIGNING_PKCS8].freeze
    # GitHub creates `bug` in a new repository; only the missing labels are added.
    LABELS = [
      {"name" => "feedback", "color" => "0e8a16", "description" => "Anonymous in-app feedback"},
      {"name" => "bug", "color" => "d73a4a", "description" => "Feedback: something does not work"},
      {"name" => "request", "color" => "a2eeef", "description" => "Feedback: a request"},
      {"name" => "other", "color" => "c5def5", "description" => "Feedback: anything else"}
    ].freeze
    APP_PERMISSIONS = {"issues" => "write", "metadata" => "read"}.freeze
    # Created by wrangler, npm or Finder; never part of the Worker.
    WORKER_IGNORED = %w[.wrangler node_modules].freeze
    IGNORED_FILES = %w[.DS_Store].freeze
    TEST_OVERRIDES = %w[
      IOS_TEMPLATE_TEST_GH_BIN IOS_TEMPLATE_TEST_WRANGLER_BIN IOS_TEMPLATE_TEST_SECURITY_BIN
      IOS_TEMPLATE_TEST_CURL_BIN IOS_TEMPLATE_TEST_NODE_BIN
    ].freeze
    EXIT_WAITING = 3

    module_function

    def refuse(message)
      raise Refused, message
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.map { |key| [key, canonical(value.fetch(key))] }.to_h
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def digest(value)
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(value)))}"
    end

    def progress(message)
      warn "app feedback: #{message}"
    end

    # --- Files ---------------------------------------------------------------------------------

    def root
      @root ||= File.realpath(File.expand_path("../..", __dir__))
    end

    def path(relative)
      File.join(root, relative)
    end

    # A regular file inside the repository, reached without symlinks.
    def read_regular(relative, limit = 65_536)
      cursor = root
      relative.split("/").each do |component|
        cursor = File.join(cursor, component)
        refuse("#{relative} must not be a symlink") if File.symlink?(cursor)
      end
      stat = File.lstat(cursor)
      refuse("#{relative} must be a regular file") unless stat.file?
      refuse("#{relative} is too large") if stat.size > limit
      File.binread(cursor)
    rescue Errno::ENOENT
      nil
    end

    def json_object(relative, bytes)
      value = JSON.parse(bytes)
      refuse("#{relative} must be a JSON object") unless value.is_a?(Hash)
      value
    rescue JSON::ParserError
      refuse("#{relative} is not valid JSON")
    end

    def directory_inside!(relative)
      cursor = root
      relative.split("/").each do |component|
        cursor = File.join(cursor, component)
        next unless File.exist?(cursor) || File.symlink?(cursor)
        stat = File.lstat(cursor)
        refuse("#{relative} must be a directory without symlinks") unless stat.directory?
      end
      cursor
    end

    # Writes bytes through a temporary sibling and a rename, so a reader never sees half a file.
    def write_atomically(relative, bytes)
      directory = directory_inside!(File.dirname(relative))
      Dir.mkdir(directory) unless File.directory?(directory)
      temporary = File.join(directory, ".#{File.basename(relative)}.#{SecureRandom.hex(6)}.tmp")
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write(bytes) }
      File.rename(temporary, path(relative))
    ensure
      File.unlink(temporary) if temporary && File.exist?(temporary)
    end

    def pretty(value)
      "#{JSON.pretty_generate(value)}\n"
    end

    # --- The app's values ----------------------------------------------------------------------

    def values
      @values ||= begin
        identity_bytes = read_regular(IDENTITY, 16_384)
        refuse("Identity bootstrap has not been applied: #{IDENTITY} is missing") if identity_bytes.nil?
        identity = json_object(IDENTITY, identity_bytes)
        refuse("#{IDENTITY} has unexpected or missing fields") unless identity.keys.sort == IDENTITY_KEYS
        refuse("#{IDENTITY} schema version is unsupported") unless identity["schemaVersion"] == 1
        module_name = identity["moduleName"]
        slug = identity["appSlug"]
        display_name = identity["displayName"]
        refuse("#{IDENTITY} moduleName is invalid") unless module_name.is_a?(String) && module_name.match?(/\A[A-Za-z_][A-Za-z0-9_]{0,80}\z/)
        refuse("#{IDENTITY} appSlug is invalid") unless slug.is_a?(String) && slug.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
        refuse("#{IDENTITY} displayName is invalid") unless display_name.is_a?(String) && !display_name.strip.empty? && display_name.length <= 80
        refuse("Identity bootstrap has not been applied: the module is still TemplateApp") if module_name == "TemplateApp"

        ownership_bytes = read_regular("Config/ownership.yml", 100_000)
        refuse("Config/ownership.yml is missing") if ownership_bytes.nil?
        begin
          ownership = Ownership.parse(ownership_bytes)
          login = Ownership.github_login!(ownership)
          cloudflare = Ownership.provider_identity!(ownership, "cloudflare")
        rescue Ownership::ValidationError => error
          refuse("configured account or target: #{error.message}")
        end
        refuse("ownership.github.login is invalid") unless login.match?(/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/)
        account = cloudflare.fetch("account")
        refuse("ownership.cloudflare.accountId is invalid") unless account.match?(/\A[0-9a-f]{32}\z/)

        contract = json_object("#{SKILL}/worker-values.json", read_regular("#{SKILL}/worker-values.json") || refuse("#{SKILL}/worker-values.json is missing"))
        patterns = contract.fetch("placeholders").map { |name, rule| [name, Regexp.new(rule.fetch("pattern"))] }.to_h
        worker = "#{slug}-feedback"
        repository = "#{login}/#{module_name}-feedback"
        namespace = (Digest::SHA256.hexdigest("#{account}/#{worker}")[0, 15].to_i(16) % 999_999_999 + 1).to_s
        refuse("Worker name #{worker} does not fit the Worker template") unless worker.match?(patterns.fetch("WORKER_NAME"))
        refuse("repository #{repository} does not fit the Worker template") unless repository.match?(patterns.fetch("GITHUB_REPOSITORY"))
        refuse("rate-limit namespace does not fit the Worker template") unless namespace.match?(patterns.fetch("RATE_LIMIT_NAMESPACE_ID"))
        unless cloudflare.fetch("target") == worker
          refuse("ownership.cloudflare.target must be the Worker name #{worker} before the Worker is deployed")
        end

        endpoint = "#{module_name}/Features/Feedback/FeedbackEndpoint.json"
        refuse("#{endpoint} is missing; the app does not have the feedback feature") if read_regular(endpoint, 4096).nil?
        {
          "displayName" => display_name, "moduleName" => module_name, "appSlug" => slug, "login" => login,
          "repository" => repository, "workerName" => worker, "accountId" => account,
          "rateLimitNamespaceId" => namespace, "endpointFile" => endpoint,
          "secretNamespace" => "github-#{login.downcase}"
        }
      end
    end

    def template_files
      @template_files ||= begin
        base = directory_inside!(TEMPLATE)
        refuse("#{TEMPLATE} is missing") unless File.directory?(base)
        files = {}
        Dir.glob("**/*", File::FNM_DOTMATCH, base: base).sort.each do |relative|
          parts = relative.split("/")
          next if parts.any? { |part| part == "." || part == ".." }
          next if WORKER_IGNORED.include?(parts.first) || IGNORED_FILES.include?(parts.last)
          full = File.join(base, relative)
          stat = File.lstat(full)
          refuse("#{TEMPLATE}/#{relative} must not be a symlink") if stat.symlink?
          next if stat.directory?
          refuse("#{TEMPLATE}/#{relative} must be a regular file") unless stat.file?
          files[relative] = File.binread(full)
        end
        refuse("#{TEMPLATE} has no wrangler.jsonc") unless files.key?("wrangler.jsonc")
        files
      end
    end

    def rendered_worker
      replacements = {
        "WORKER_NAME" => values.fetch("workerName"),
        "GITHUB_REPOSITORY" => values.fetch("repository"),
        "RATE_LIMIT_NAMESPACE_ID" => values.fetch("rateLimitNamespaceId")
      }
      template_files.map do |relative, bytes|
        next [relative, bytes] unless relative == "wrangler.jsonc"
        text = bytes.dup.force_encoding(Encoding::UTF_8).gsub(/\{\{([A-Z_]+)\}\}/) do
          replacements.fetch(Regexp.last_match(1)) { refuse("unknown placeholder #{Regexp.last_match(1)}") }
        end
        refuse("a placeholder remains in wrangler.jsonc") if text.include?("{{")
        [relative, text.b]
      end.to_h
    end

    def plan
      {
        "schemaVersion" => 1,
        "repository" => values.fetch("repository"),
        "visibility" => "private",
        "labels" => LABELS.map { |label| label.fetch("name") },
        "workerName" => values.fetch("workerName"),
        "cloudflareAccountId" => values.fetch("accountId"),
        "rateLimitNamespaceId" => values.fetch("rateLimitNamespaceId"),
        "workerDirectory" => WORKER_DIRECTORY,
        "workerTemplateDigest" => digest(template_files.map { |relative, bytes| [relative, Digest::SHA256.hexdigest(bytes)] }.to_h),
        "endpointFile" => values.fetch("endpointFile"),
        "record" => RECORD,
        "secretNamespace" => values.fetch("secretNamespace"),
        "wranglerVersion" => WRANGLER_VERSION
      }
    end

    # --- Child processes -----------------------------------------------------------------------

    def test_mode?
      ENV["IOS_TEMPLATE_TEST_MODE"] == "1"
    end

    def check_environment!
      return if test_mode?
      refuse("test overrides are not allowed in production mode") if TEST_OVERRIDES.any? { |name| ENV.key?(name) }
    end

    def executable!(candidate, name)
      refuse("#{name} is unavailable") unless candidate.is_a?(String) && candidate.start_with?("/") &&
        File.file?(candidate) && File.executable?(candidate)
      candidate
    end

    def from_path(name)
      ENV.fetch("PATH", "").split(":").map { |directory| File.join(directory, name) }
        .find { |candidate| candidate.start_with?("/") && File.file?(candidate) && File.executable?(candidate) }
    end

    def tool(name)
      @tools ||= {}
      @tools[name] ||= if test_mode?
        override = ENV["IOS_TEMPLATE_TEST_#{name.upcase}_BIN"]
        refuse("test #{name} executable is not set") if override.nil?
        refuse("test #{name} executable must not be a symlink") if File.symlink?(override.to_s)
        [executable!(override, name)]
      else
        case name
        when "gh" then [executable!(%w[/opt/homebrew/bin/gh /usr/local/bin/gh].find { |candidate| File.file?(candidate) }, "GitHub CLI")]
        when "wrangler" then [executable!(from_path("npx"), "npx (Node 24 or later)"), "--yes", "wrangler@#{WRANGLER_VERSION}"]
        when "security" then [executable!("/usr/bin/security", "macOS security")]
        when "curl" then [executable!("/usr/bin/curl", "curl")]
        when "node" then [executable!(from_path("node"), "Node 24 or later")]
        else refuse("unknown tool #{name}")
        end
      end
    end

    def child_environment(extra = {})
      ENV.to_h.merge("NO_COLOR" => "1", "FORCE_COLOR" => "0", "GH_PROMPT_DISABLED" => "1",
                     "WRANGLER_SEND_METRICS" => "false").merge(extra)
    end

    # Runs one bounded child. Secrets reach it only on stdin. Its standard output is parsed and never
    # printed; its standard error, which a refusal may show, has the secrets removed.
    def run(stage, command, input: "", timeout: 120, chdir: root, extra_env: {}, secrets: [])
      bounded = ["/usr/bin/ruby", File.join(__dir__, "bounded-command.rb"), "--stage", stage,
                 "--timeout-seconds", timeout.to_s, "--grace-seconds", "2", "--", *command]
      output, error, status = Open3.capture3(child_environment(extra_env), *bounded, stdin_data: input, chdir: chdir)
      [output.force_encoding(Encoding::UTF_8), redact(error, secrets), status.exitstatus]
    end

    def redact(text, secrets)
      secrets.compact.reject(&:empty?).reduce(text.to_s.b) do |result, secret|
        pieces = [secret] + secret.lines.map(&:strip).select { |line| line.length >= 16 }
        pieces.reduce(result) { |current, piece| current.gsub(piece.b, "[redacted]".b) }
      end.force_encoding(Encoding::UTF_8)
    end

    def tail(text)
      text.to_s.b.lines.last(5).map { |line| line.strip[0, 300] }.join(" | ").force_encoding(Encoding::UTF_8).scrub
    end

    # --- GitHub through the user's gh session --------------------------------------------------

    def gh(stage, *arguments, input: "", allow_not_found: false)
      output, error, status = run("app-feedback-#{stage}", [*tool("gh"), "api", *arguments], input: input, timeout: 60)
      return :not_found if allow_not_found && status != 0 && error.include?("HTTP 404")
      refuse("GitHub #{stage} failed: #{tail(error)}") unless status.zero?
      output.empty? ? nil : JSON.parse(output)
    rescue JSON::ParserError
      refuse("GitHub #{stage} returned an unreadable response")
    end

    def check_github_account!
      user = gh("account", "user")
      refuse("GitHub account response is unreadable") unless user.is_a?(Hash)
      return if user["login"] == values.fetch("login")

      refuse("the active GitHub account does not match the configured login #{values.fetch("login")}")
    end

    def repository_state
      repository = gh("repository-read", "repos/#{values.fetch("repository")}", allow_not_found: true)
      return {"exists" => false} if repository == :not_found
      refuse("GitHub repository response is unreadable") unless repository.is_a?(Hash)
      unless repository["full_name"] == values.fetch("repository") && repository.dig("owner", "login") == values.fetch("login")
        refuse("#{values.fetch("repository")} resolves to another repository")
      end
      refuse("#{values.fetch("repository")} exists but is not private") unless repository["private"] == true
      refuse("#{values.fetch("repository")} is archived") if repository["archived"] == true
      labels = gh("labels-read", "repos/#{values.fetch("repository")}/labels?per_page=100")
      refuse("GitHub label response is unreadable") unless labels.is_a?(Array) && labels.all? { |label| label.is_a?(Hash) && label["name"].is_a?(String) }
      names = labels.map { |label| label["name"] }
      {"exists" => true, "missingLabels" => LABELS.map { |label| label["name"] }.reject { |name| names.include?(name) }}
    end

    def create_repository!
      progress("creating the private repository #{values.fetch("repository")}")
      name = values.fetch("repository").split("/", 2).last
      created = gh("repository-create", "--method", "POST", "user/repos", "-f", "name=#{name}", "-F", "private=true",
                   "-f", "description=Anonymous in-app feedback for #{values.fetch("displayName")} (D-076)",
                   "-F", "has_wiki=false", "-F", "has_projects=false")
      refuse("the created repository differs from the plan") unless created.is_a?(Hash) &&
        created["full_name"] == values.fetch("repository") && created["private"] == true
    end

    def create_labels!(missing)
      LABELS.select { |label| missing.include?(label["name"]) }.each do |label|
        progress("creating the label #{label["name"]}")
        gh("label-create", "--method", "POST", "repos/#{values.fetch("repository")}/labels", "-f", "name=#{label["name"]}",
           "-f", "color=#{label["color"]}", "-f", "description=#{label["description"]}")
      end
    end

    # --- The shared GitHub App -----------------------------------------------------------------

    def keychain_value(key)
      namespace = values.fetch("secretNamespace")
      service = "ios-template/#{namespace}/feedback-github-app/production/#{key}"
      output, _error, status = run("app-feedback-keychain", [*tool("security"), "find-generic-password", "-a", namespace, "-s", service, "-w"], timeout: 120)
      if status == 44
        refuse("the shared GitHub App #{key} is not in the Keychain (#{service}); store it as the app-feedback skill describes")
      end
      refuse("the Keychain could not be read for #{service}") unless status.zero?
      value = output.chomp
      refuse("the Keychain value of #{service} must be a positive integer") unless value.match?(/\A[1-9][0-9]{0,15}\z/)
      value
    end

    def signing_key_path
      home = ENV["HOME"].to_s
      refuse("HOME must be an absolute directory") unless home.start_with?("/") && File.directory?(home)
      File.join(home, "Library", "Application Support", "iOS-Template", "secrets", values.fetch("secretNamespace"), "feedback-github-app.pem")
    end

    def owner_only!(stat, mode, what)
      refuse("#{what} must belong to the current user") unless stat.uid == Process.uid
      refuse(format("%s must have mode %o", what, mode)) unless (stat.mode & 0o777) == mode
    end

    def signing_key
      file = signing_key_path
      secrets = File.dirname(File.dirname(file))
      [secrets, File.dirname(file)].each do |directory|
        refuse("the shared GitHub App signing key is missing: #{file}") unless File.exist?(directory)
        stat = File.lstat(directory)
        refuse("#{directory} must be a directory, not a symlink") unless stat.directory?
        owner_only!(stat, 0o700, directory)
      end
      refuse("the shared GitHub App signing key is missing: #{file}") unless File.exist?(file) || File.symlink?(file)
      stat = File.lstat(file)
      refuse("the signing key must be a regular file, not a symlink") unless stat.file?
      owner_only!(stat, 0o600, "the signing key")
      refuse("the signing key must have one hard link") unless stat.nlink == 1
      refuse("the signing key is too large") if stat.size > 16_384
      # An empty passphrase keeps OpenSSL from prompting; an encrypted key is refused.
      key = OpenSSL::PKey.read(File.binread(file), "")
      refuse("the signing key must be an RSA private key of 2048 bits or more") unless key.is_a?(OpenSSL::PKey::RSA) && key.private? && key.n.num_bits >= 2048
      key
    rescue OpenSSL::PKey::PKeyError, ArgumentError
      refuse("the signing key could not be read as a private key")
    end

    # PKCS#8 PEM, which the Worker imports with WebCrypto. Built with ASN.1 because Ruby 2.6 has no
    # PKCS#8 writer; the header label is assembled so this file carries no literal key header.
    def pkcs8_pem(key)
      algorithm = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::ObjectId("rsaEncryption"), OpenSSL::ASN1::Null(nil)])
      der = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::Integer(0), algorithm, OpenSSL::ASN1::OctetString(key.to_der)]).to_der
      label = ["PRIVATE", "KEY"].join(" ")
      body = Base64.strict_encode64(der).scan(/.{1,64}/).join("\n")
      pem = "-----BEGIN #{label}-----\n#{body}\n-----END #{label}-----\n"
      refuse("the PKCS#8 conversion did not round-trip") unless OpenSSL::PKey.read(pem).to_der == key.to_der
      pem
    end

    def credentials
      @credentials ||= begin
        app_id = keychain_value("app-id")
        installation_id = keychain_value("installation-id")
        key = signing_key
        {"appId" => app_id, "installationId" => installation_id, "key" => key, "pkcs8" => pkcs8_pem(key)}
      end
    end

    def jwt
      encode = ->(value) { Base64.urlsafe_encode64(value, padding: false) }
      now = Time.now.to_i
      message = [encode.call(JSON.generate({"alg" => "RS256", "typ" => "JWT"})),
                 encode.call(JSON.generate({"iat" => now - 60, "exp" => now + 540, "iss" => credentials.fetch("appId")}))].join(".")
      "#{message}.#{encode.call(credentials.fetch("key").sign(OpenSSL::Digest::SHA256.new, message))}"
    end

    def curl_config_string(value)
      escaped = value.gsub(/[\\"]/) { |character| "\\#{character}" }
      "\"#{escaped}\""
    end

    # curl reads its URL, headers and body from a config on stdin, so neither the token nor the
    # installation ID appears in a process listing.
    def curl(stage, url, headers: [], method: "GET", body: nil, secrets: [])
      lines = ["silent", "show-error", "proto = \"=https\"", "max-time = 20", "write-out = \"\\n%{http_code}\"",
               "request = #{curl_config_string(method)}", "url = #{curl_config_string(url)}"]
      headers.each { |header| lines << "header = #{curl_config_string(header)}" }
      lines << "data-raw = #{curl_config_string(body)}" if body
      output, error, status = run("app-feedback-#{stage}", [*tool("curl"), "--config", "-"], input: "#{lines.join("\n")}\n",
                                  timeout: 40, secrets: secrets)
      refuse("#{stage} request failed: #{tail(error)}") unless status.zero?
      response, separator, code = output.rpartition("\n")
      refuse("#{stage} response is unreadable") if separator.empty? || !code.match?(/\A[0-9]{3}\z/)
      [code.to_i, response]
    end

    def github_app(stage, api_path)
      token = jwt
      code, body = curl(stage, "https://api.github.com/#{api_path}", secrets: [token, credentials.fetch("installationId")],
                        headers: ["Accept: application/vnd.github+json", "Authorization: Bearer #{token}",
                                  "X-GitHub-Api-Version: 2022-11-28", "User-Agent: ios-template-app-feedback"])
      [code, code == 200 ? JSON.parse(body) : nil]
    rescue JSON::ParserError
      refuse("GitHub App #{stage} returned an unreadable response")
    end

    def check_github_app!
      code, app = github_app("github-app-read", "app")
      refuse("the shared GitHub App could not authenticate (HTTP #{code}); check its App ID and signing key") unless code == 200 && app.is_a?(Hash)
      refuse("the signing key belongs to another GitHub App") unless app["id"].to_s == credentials.fetch("appId")
      unless app["permissions"] == APP_PERMISSIONS && app["events"] == []
        refuse("the shared GitHub App must have only Issues: Read and write and no webhook events")
      end
      code, installation = github_app("installation-read", "app/installations/#{credentials.fetch("installationId")}")
      refuse("the shared GitHub App installation was not found (HTTP #{code})") unless code == 200 && installation.is_a?(Hash)
      refuse("the installation belongs to another account") unless installation.dig("account", "login") == values.fetch("login")
      refuse("the installation must be limited to selected repositories") unless installation["repository_selection"] == "selected"
      refuse("the installation must have only Issues: Read and write") unless installation["permissions"] == APP_PERMISSIONS
      refuse("the installation is suspended") unless installation["suspended_at"].nil?
    end

    def installed_on_repository?
      code, installation = github_app("repository-installation-read", "repos/#{values.fetch("repository")}/installation")
      return false if code == 404
      refuse("the repository installation could not be read (HTTP #{code})") unless code == 200 && installation.is_a?(Hash)
      refuse("the repository is installed through another installation") unless installation["id"].to_s == credentials.fetch("installationId")
      true
    end

    def installation_steps
      "install the shared GitHub App on #{values.fetch("repository")}: GitHub > Settings > Applications > the shared App > " \
        "Configure > Repository access > Only select repositories > add #{values.fetch("repository")} > Save; then run apply again"
    end

    # --- Cloudflare through wrangler -----------------------------------------------------------

    def wrangler(stage, *arguments, input: "", timeout: 180, chdir: root, secrets: [])
      run("app-feedback-#{stage}", [*tool("wrangler"), *arguments], input: input, timeout: timeout, chdir: chdir,
          extra_env: {"CLOUDFLARE_ACCOUNT_ID" => values.fetch("accountId")}, secrets: secrets)
    end

    def check_cloudflare_account!
      output, error, status = wrangler("cloudflare-account", "whoami", "--json", timeout: 120)
      refuse("Cloudflare is not authenticated for wrangler: #{tail(error)}") unless status.zero?
      whoami = JSON.parse(output)
      accounts = whoami.is_a?(Hash) && whoami["loggedIn"] == true ? whoami["accounts"] : nil
      refuse("wrangler whoami returned no accounts") unless accounts.is_a?(Array)
      return if accounts.any? { |account| account.is_a?(Hash) && account["id"] == values.fetch("accountId") }

      refuse("the wrangler session cannot use the configured Cloudflare account")
    rescue JSON::ParserError
      refuse("wrangler whoami returned an unreadable response")
    end

    def worker_directory
      path(WORKER_DIRECTORY)
    end

    # nil: absent; true: the same bytes as the plan; refuses when anything else is there.
    def worker_state
      directory = directory_inside!(WORKER_DIRECTORY)
      return nil unless File.exist?(directory)
      expected = rendered_worker
      present = {}
      Dir.glob("**/*", File::FNM_DOTMATCH, base: directory).sort.each do |relative|
        parts = relative.split("/")
        next if parts.any? { |part| part == "." || part == ".." }
        next if WORKER_IGNORED.include?(parts.first) || parts.first.start_with?(".dev.vars") || IGNORED_FILES.include?(parts.last)
        full = File.join(directory, relative)
        stat = File.lstat(full)
        refuse("#{WORKER_DIRECTORY}/#{relative} must not be a symlink") if stat.symlink?
        next if stat.directory?
        present[relative] = File.binread(full)
      end
      return true if present == expected

      refuse("#{WORKER_DIRECTORY} already exists and differs from the planned Worker; resolve it by hand")
    end

    def write_worker!
      return if worker_state

      progress("writing #{WORKER_DIRECTORY} from the Worker template")
      parent = directory_inside!(File.dirname(WORKER_DIRECTORY))
      Dir.mkdir(parent) unless File.directory?(parent)
      staging = File.join(parent, ".feedback-worker.#{SecureRandom.hex(6)}.tmp")
      Dir.mkdir(staging, 0o755)
      rendered_worker.each do |relative, bytes|
        destination = File.join(staging, relative)
        FileUtils.mkdir_p(File.dirname(destination))
        File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write(bytes) }
      end
      File.rename(staging, worker_directory)
    ensure
      FileUtils.rm_rf(staging) if staging && File.exist?(staging)
    end

    def run_worker_tests!
      progress("running the Worker tests")
      output, error, status = run("app-feedback-worker-tests", [*tool("node"), "test/all.ts"], timeout: 180, chdir: worker_directory)
      refuse("the Worker tests failed: #{tail(error.empty? ? output : error)}") unless status.zero?
    end

    def deploy!
      progress("deploying the Worker #{values.fetch("workerName")}")
      output, error, status = wrangler("worker-deploy", "deploy", timeout: 300, chdir: worker_directory)
      refuse("the Worker deploy failed: #{tail(error.empty? ? output : error)}") unless status.zero?
      pattern = %r{https://(#{Regexp.escape(values.fetch("workerName"))}\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.workers\.dev)(?![A-Za-z0-9.-])}
      hosts = "#{output}\n#{error}".scan(pattern).flatten.uniq
      refuse("the deploy output did not name exactly one workers.dev host") unless hosts.length == 1
      hosts.first
    end

    def worker_secret_names
      output, error, status = wrangler("worker-secrets-read", "secret", "list", "--name", values.fetch("workerName"), "--format", "json", timeout: 120)
      refuse("the Worker secrets could not be listed: #{tail(error)}") unless status.zero?
      listed = JSON.parse(output)
      refuse("the Worker secret list is unreadable") unless listed.is_a?(Array) && listed.all? { |entry| entry.is_a?(Hash) && entry["name"].is_a?(String) }
      listed.map { |entry| entry["name"] }
    rescue JSON::ParserError
      refuse("the Worker secret list is unreadable")
    end

    def put_missing_secrets!
      missing = SECRET_NAMES - worker_secret_names
      values_by_name = {
        "GITHUB_APP_ID" => credentials.fetch("appId"),
        "GITHUB_APP_INSTALLATION_ID" => credentials.fetch("installationId"),
        "GITHUB_APP_SIGNING_PKCS8" => credentials.fetch("pkcs8")
      }
      missing.each do |name|
        progress("registering the Worker secret #{name}")
        secret = values_by_name.fetch(name)
        _output, error, status = wrangler("worker-secret-put", "secret", "put", name, "--name", values.fetch("workerName"),
                                          input: secret, timeout: 120, secrets: values_by_name.values)
        refuse("the Worker secret #{name} could not be registered: #{tail(error)}") unless status.zero?
      end
      refuse("the Worker does not have every secret after registration") unless (SECRET_NAMES - worker_secret_names).empty?
    end

    # --- The app's host and the record ---------------------------------------------------------

    def endpoint_host
      endpoint = values.fetch("endpointFile")
      value = json_object(endpoint, read_regular(endpoint, 4096))
      refuse("#{endpoint} must contain only host") unless value.keys == ["host"] && value["host"].is_a?(String)
      value["host"]
    end

    def record
      bytes = read_regular(RECORD, 16_384)
      bytes && json_object(RECORD, bytes)
    end

    def expected_record(host)
      {
        "schemaVersion" => 1,
        "repository" => values.fetch("repository"),
        "labels" => LABELS.map { |label| label.fetch("name") },
        "workerName" => values.fetch("workerName"),
        "cloudflareAccountId" => values.fetch("accountId"),
        "rateLimitNamespaceId" => values.fetch("rateLimitNamespaceId"),
        "host" => host,
        "planDigest" => digest(plan)
      }
    end

    def check_local_settings!
      current = endpoint_host
      saved = record
      if saved && saved != expected_record(saved["host"])
        refuse("#{RECORD} differs from the plan; resolve it by hand")
      end
      if !current.empty? && (saved.nil? || saved["host"] != current)
        refuse("#{values.fetch("endpointFile")} already names a host that this tool did not record")
      end
      saved
    end

    def finish_settings!(host)
      unless endpoint_host == host
        progress("setting the app's feedback host")
        write_atomically(values.fetch("endpointFile"), pretty({"host" => host}))
      end
      write_atomically(RECORD, pretty(expected_record(host))) unless record == expected_record(host)
    end

    # --- Commands ------------------------------------------------------------------------------

    def preflight!
      check_environment!
      values
      check_local_settings!
      worker_state
      check_github_account!
      check_cloudflare_account!
      credentials
      check_github_app!
    end

    def command_plan
      preflight!
      repository = repository_state
      installed = repository["exists"] ? installed_on_repository? : false
      saved = record
      {
        "plan" => plan,
        "planDigest" => digest(plan),
        "current" => {
          "repository" => repository["exists"] ? "exists" : "to-create",
          "missingLabels" => repository["exists"] ? repository["missingLabels"] : LABELS.map { |label| label["name"] },
          "installedOnRepository" => installed,
          "workerDirectory" => worker_state ? "written" : "to-write",
          "host" => saved ? saved["host"] : nil
        }
      }
    end

    def command_apply(approved_digest)
      refuse("apply needs --plan-digest from the plan the user approved") unless approved_digest.to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
      check_environment!
      refuse("the plan differs from the approved plan digest; run plan again and get approval") unless digest(plan) == approved_digest
      preflight!
      write_worker!
      run_worker_tests!
      repository = repository_state
      unless repository["exists"]
        create_repository!
        repository = repository_state
        refuse("the repository is not readable after creation") unless repository["exists"]
      end
      create_labels!(repository["missingLabels"])
      refuse("labels are still missing after creation") unless repository_state["missingLabels"].empty?
      raise WaitingForInstallation, installation_steps unless installed_on_repository?

      # The host comes from Cloudflare on every run, never from the repository's files, which anyone
      # could change. Deploying again updates the same Worker; it creates nothing new.
      host = deploy!
      saved = record
      refuse("#{RECORD} names #{saved["host"]}, not the deployed Worker's host #{host}") if saved && saved["host"] != host
      current = endpoint_host
      unless current.empty? || current == host
        refuse("#{values.fetch("endpointFile")} names #{current}, not the deployed Worker's host #{host}")
      end
      put_missing_secrets!
      finish_settings!(host)
      {"status" => "provisioned", "repository" => values.fetch("repository"), "workerName" => values.fetch("workerName"),
       "host" => host, "record" => RECORD}
    end

    # Runs apply for the approved plan first, so the submission goes only to the host Cloudflare just
    # reported for this app's Worker.
    def command_check_delivery(approved_digest)
      provisioned = command_apply(approved_digest)
      host = provisioned.fetch("host")
      repository = values.fetch("repository")
      nonce = SecureRandom.hex(8)
      payload = JSON.generate({"category" => "other", "body" => "Feedback provisioning check #{nonce}", "appVersion" => "0.0",
                               "build" => "0", "osVersion" => "0.0", "deviceModel" => "provisioning-check", "locale" => "en_US"})
      code, = curl("delivery-send", "https://#{host}/v1/feedback", method: "POST", body: payload,
                   headers: ["Content-Type: application/json", "User-Agent: ios-template-app-feedback"])
      refuse("the Worker answered HTTP #{code} instead of 201") unless code == 201
      5.times do |attempt|
        sleep 2 unless attempt.zero?
        issues = gh("issues-read", "repos/#{repository}/issues?labels=feedback&state=open&per_page=20")
        refuse("GitHub issue response is unreadable") unless issues.is_a?(Array)
        found = issues.find { |issue| issue.is_a?(Hash) && issue["body"].to_s.include?(nonce) }
        next unless found

        labels = Array(found["labels"]).map { |label| label.is_a?(Hash) ? label["name"] : nil }
        refuse("the created issue does not have the feedback and other labels") unless (%w[feedback other] - labels).empty?
        return {"status" => "delivered", "repository" => repository, "issue" => found["number"]}
      end
      refuse("the Worker answered 201, but no matching issue appeared in #{repository}")
    end

    def usage
      warn "usage: provision-app-feedback.sh plan | apply --plan-digest sha256:HEX | check-delivery --plan-digest sha256:HEX"
      2
    end

    def main(arguments)
      command = arguments.first
      result = case command
               when "plan"
                 return usage unless arguments.length == 1
                 command_plan
               when "apply"
                 return usage unless arguments.length == 3 && arguments[1] == "--plan-digest"
                 command_apply(arguments[2])
               when "check-delivery"
                 return usage unless arguments.length == 3 && arguments[1] == "--plan-digest"
                 command_check_delivery(arguments[2])
               else
                 return usage
               end
      puts JSON.pretty_generate(result)
      0
    rescue WaitingForInstallation => error
      warn "app feedback stopped: #{error.message}"
      puts JSON.pretty_generate({"status" => "waiting-for-installation", "repository" => values.fetch("repository")})
      EXIT_WAITING
    rescue Refused => error
      warn "app feedback refused: #{error.message}"
      1
    rescue SystemCallError, IOError, JSON::ParserError => error
      warn "app feedback failed: #{error.class}"
      1
    end
  end
end

if $PROGRAM_NAME == __FILE__
  exit IOSTemplate::AppFeedbackProvision.main(ARGV)
end
