#!/usr/bin/env ruby
# frozen_string_literal: true

# #385: checks App Store localization sources against the parts of the ASO guide (docs/appstore-aso.md) that a
# machine can check. It reads local files only: it never opens the network, App Store Connect, a credential
# store, or a public page, and it never writes. Errors are fixed before submission; a warning may stay when the
# reason is recorded next to the copy. A passing check is not approval, release readiness, or an App Review
# prediction.

require "json"
require "optparse"
require "pathname"
require "yaml"

module AppStoreASO
  LOCALIZATIONS_RELATIVE = "App Store/metadata/localizations"
  REQUIREMENTS_RELATIVE = "App Store/submission/requirements.json"
  CONFIG_RELATIVE = "App Store/metadata/aso.json"
  EXPECTED_LOCALES = %w[en-US ja].freeze
  LOCALE_FILE = /\A([a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*)\.yml\z/.freeze
  CONFIG_KEYS = %w[competitors firstSentenceMaxCharacters keywordLimit schemaVersion trademarks].freeze
  KEYWORD_UNITS = %w[bytes characters].freeze
  # Template defaults for the first sentence of the description, not Apple values. An app may change them.
  FIRST_SENTENCE_DEFAULTS = { "ja" => 60 }.freeze
  FIRST_SENTENCE_FALLBACK = 120
  MAX_FILE_BYTES = 1_000_000
  MAX_LIST = 500
  MAX_NAME = 200

  BROAD_TERMS = %w[app apps application applications game games アプリ アプリケーション ゲーム].freeze
  # Prices and "free" in the name or subtitle (App Review Guideline 2.3.7).
  PRICE_PATTERNS = [
    /[¥$€£]\s*\d/,
    /\d[\d,.]*\s*(?:円|ドル|yen\b|dollars?\b|usd\b|jpy\b)/i,
    /(?<![-\p{L}])free\b/i,
    /無料|半額/,
    /\d+\s*%\s*(?:off\b|オフ|引き)/i
  ].freeze
  # Ranking and superlative claims that the copy cannot verify (Guideline 2.3.7, Apple's product page guidance).
  CLAIM_PATTERNS = [
    /(?<![a-z])no\.?\s*1(?!\d)|#\s*1(?!\d)|\bnumber\s+one\b|\bbest\b|\bworld'?s\s+(?:best|first|top)\b|\btop[- ]rated\b/i,
    /ナンバーワン|世界一|日本一|最高|最強/
  ].freeze
  SENTENCE_END = /[。．！？!?]|\.(?=\s|\z)/.freeze
  LIST_START = /\A(?:[-*•・●○■□◆◇★☆▶►#>※]|\d+[.)．）])/.freeze
  KEYWORD_ALLOWED = /[\p{L}\p{M}\p{N} '’.+\-]/.freeze
  FULL_WIDTH_COMMAS = %w[、 ，].freeze
  PROMOTION_SEPARATORS = /[,、，\/｜|]/.freeze

  class InputError < StandardError; end

  module_function

  def run(argv, out: $stdout, err: $stderr)
    options = parse(argv)
    root = Pathname.new(options[:project_root])
    raise InputError, "project root must be an absolute directory" unless root.absolute? && root.directory?

    requirements = read_requirements(resolve(root, options[:requirements] || REQUIREMENTS_RELATIVE))
    config = read_config(root, options[:config])
    directory = resolve(root, options[:localizations] || LOCALIZATIONS_RELATIVE)
    raise InputError, "localizations directory is missing" unless directory.directory?
    raise InputError, "localizations directory must not be a symbolic link" if directory.symlink?

    summary = check(directory, requirements, config)
    out.puts JSON.generate(summary)
    summary["errors"].empty? ? 0 : 1
  rescue InputError, OptionParser::ParseError, ArgumentError => e
    err.puts "App Store ASO check refused: #{e.message}"
    2
  rescue SystemCallError, IOError
    err.puts "App Store ASO check refused: an input could not be read"
    2
  end

  def parse(argv)
    options = {}
    OptionParser.new do |cli|
      cli.banner = "usage: check-appstore-aso.sh --project-root DIR [--localizations DIR] [--requirements PATH] [--config PATH]"
      cli.on("--project-root DIR") { |value| options[:project_root] = value }
      cli.on("--localizations DIR") { |value| options[:localizations] = value }
      cli.on("--requirements PATH") { |value| options[:requirements] = value }
      cli.on("--config PATH") { |value| options[:config] = value }
    end.parse!(argv)
    raise InputError, "unexpected arguments" unless argv.empty?
    raise InputError, "--project-root is required" if options[:project_root].to_s.empty?
    options
  end

  def resolve(root, value)
    path = Pathname.new(value)
    path.absolute? ? path : root.join(path)
  end

  def read_regular(path, label)
    raise InputError, "#{label} must not be a symbolic link" if path.symlink?
    raise InputError, "#{label} is missing" unless path.file?
    raise InputError, "#{label} is too large" if path.size > MAX_FILE_BYTES
    text = path.binread.force_encoding(Encoding::UTF_8)
    raise InputError, "#{label} is not UTF-8" unless text.valid_encoding?
    text
  rescue SystemCallError, IOError
    raise InputError, "#{label} could not be read"
  end

  def read_json(path, label)
    value = JSON.parse(read_regular(path, label))
    raise InputError, "#{label} must be a JSON object" unless value.is_a?(Hash)
    value
  rescue JSON::ParserError
    raise InputError, "#{label} is not valid JSON"
  end

  def read_requirements(path)
    fields = read_json(path, "requirements").fetch("fields", nil)
    raise InputError, "requirements have no fields" unless fields.is_a?(Hash)
    limits = {
      "nameMin" => fields.dig("name", "minCharacters"),
      "name" => fields.dig("name", "maxCharacters"),
      "subtitle" => fields.dig("subtitle", "maxCharacters"),
      "promotionalText" => fields.dig("promotionalText", "maxCharacters"),
      "description" => fields.dig("description", "maxCharacters"),
      "keywordBytes" => fields.dig("keywords", "maxBytes")
    }
    # requirements.json records the App Store Connect help's byte limit. Apple's search page says 100 characters
    # for the same field; until requirements.json records a character limit, the character mode uses the same
    # number. Which unit is right stays open (docs/appstore-aso.md).
    characters = fields.dig("keywords", "maxCharacters")
    limits["keywordCharacters"] = characters.nil? ? limits["keywordBytes"] : characters
    limits.each do |key, value|
      raise InputError, "requirements limit #{key} must be a positive integer" unless value.is_a?(Integer) && value.positive?
    end
    limits
  end

  def read_config(root, explicit)
    path = explicit ? resolve(root, explicit) : root.join(CONFIG_RELATIVE)
    return default_config if explicit.nil? && !path.exist? && !path.symlink?

    config = read_json(path, "ASO config")
    unknown = config.keys - CONFIG_KEYS
    raise InputError, "ASO config keys must be among #{CONFIG_KEYS.join(', ')}" unless unknown.empty?
    raise InputError, "ASO config schemaVersion must be 1" unless config["schemaVersion"] == 1
    unit = config.fetch("keywordLimit", "bytes")
    raise InputError, "ASO config keywordLimit must be bytes or characters" unless KEYWORD_UNITS.include?(unit)
    lists = %w[competitors trademarks].map do |key|
      value = config.fetch(key, [])
      unless value.is_a?(Array) && value.length <= MAX_LIST && value.all? { |entry| entry.is_a?(String) && !entry.strip.empty? && entry.length <= MAX_NAME }
        raise InputError, "ASO config #{key} must be a list of names"
      end
      [key, value]
    end.to_h
    first = config.fetch("firstSentenceMaxCharacters", {})
    unless first.is_a?(Hash) && first.all? { |locale, value| locale.is_a?(String) && locale.match?(/\A[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z/) && value.is_a?(Integer) && value.positive? }
      raise InputError, "ASO config firstSentenceMaxCharacters must map locales to positive integers"
    end
    { "keywordLimit" => unit, "competitors" => lists["competitors"], "trademarks" => lists["trademarks"],
      "firstSentence" => FIRST_SENTENCE_DEFAULTS.merge(first) }
  end

  def default_config
    { "keywordLimit" => "bytes", "competitors" => [], "trademarks" => [], "firstSentence" => FIRST_SENTENCE_DEFAULTS.dup }
  end

  def check(directory, limits, config)
    findings = []
    keyword_reports = []
    files = directory.children.select { |child| child.basename.to_s.match?(LOCALE_FILE) }.sort_by { |child| child.basename.to_s }
    locales = files.map { |child| child.basename.to_s[LOCALE_FILE, 1] }
    if files.empty?
      findings << finding("error", nil, nil, "no-localizations", "no localization file was found")
    else
      (EXPECTED_LOCALES - locales).each do |locale|
        findings << finding("warning", locale, nil, "missing-locale", "the #{locale} localization is missing; the guide expects both ja and en-US")
      end
    end
    files.zip(locales).each do |path, locale|
      localization = load_localization(path, locale, findings)
      next unless localization

      findings.concat(check_localization(locale, localization, limits, config, keyword_reports))
    end
    unit = config["keywordLimit"]
    errors, warnings = findings.partition { |entry| entry["severity"] == "error" }
    {
      "status" => errors.empty? ? "passed" : "failed",
      "locales" => locales,
      "keywordLimit" => { "unit" => unit, "value" => unit == "bytes" ? limits["keywordBytes"] : limits["keywordCharacters"] },
      "keywords" => keyword_reports,
      "errors" => errors,
      "warnings" => warnings
    }
  end

  def load_localization(path, locale, findings)
    text = read_regular(path, "localization #{locale}")
    value = YAML.safe_load(text, permitted_classes: [], aliases: false)
    return value if value.is_a?(Hash)

    findings << finding("error", locale, nil, "invalid-localization", "the localization must be a mapping of fields")
    nil
  rescue Psych::Exception
    findings << finding("error", locale, nil, "invalid-localization", "the localization is not valid YAML")
    nil
  end

  def check_localization(locale, localization, limits, config, keyword_reports)
    findings = []
    values = {}
    %w[name subtitle keywords promotionalText description].each do |field|
      value = localization[field]
      if value.nil?
        values[field] = ""
      elsif value.is_a?(String)
        values[field] = value
      else
        findings << finding("error", locale, field, "invalid-field", "#{field} must be text")
        values[field] = ""
      end
    end
    %w[name keywords description].each do |field|
      findings << finding("error", locale, field, "missing", "#{field} is empty") if values[field].strip.empty? && !findings.any? { |entry| entry["field"] == field }
    end

    findings.concat(check_lengths(locale, values, limits))
    findings.concat(check_keywords(locale, values, limits, config, keyword_reports))
    findings.concat(check_name_and_subtitle(locale, values, config))
    findings.concat(check_description(locale, values, config))
    findings.concat(check_promotional_text(locale, values, config))
    findings
  end

  def check_lengths(locale, values, limits)
    findings = []
    name = values["name"]
    unless name.strip.empty? || name.length.between?(limits["nameMin"], limits["name"])
      findings << finding("error", locale, "name", "length", "name has #{name.length} characters; the limit is #{limits['nameMin']} to #{limits['name']}")
    end
    %w[subtitle promotionalText description].each do |field|
      length = values[field].length
      next if length <= limits[field]

      findings << finding("error", locale, field, "length", "#{field} has #{length} characters; the limit is #{limits[field]}")
    end
    findings
  end

  def check_keywords(locale, values, limits, config, keyword_reports)
    keywords = values["keywords"]
    bytes = keywords.bytesize
    characters = keywords.length
    keyword_reports << { "locale" => locale, "bytes" => bytes, "characters" => characters }
    findings = []
    measured = { "bytes" => [bytes, limits["keywordBytes"]], "characters" => [characters, limits["keywordCharacters"]] }
    unit = config["keywordLimit"]
    other = (KEYWORD_UNITS - [unit]).first
    value, limit = measured.fetch(unit)
    if value > limit
      findings << finding("error", locale, "keywords", "keywords-length", "keywords have #{bytes} bytes and #{characters} characters; the limit is #{limit} #{unit}")
    end
    other_value, other_limit = measured.fetch(other)
    if other_value > other_limit && value <= limit
      findings << finding("warning", locale, "keywords", "keywords-length-other-unit",
                          "keywords have #{bytes} bytes and #{characters} characters; within #{limit} #{unit} but over #{other_limit} #{other}")
    end
    return findings if keywords.strip.empty?

    if keywords.match?(/\s,|,\s/) || keywords != keywords.strip
      findings << finding("error", locale, "keywords", "space-around-comma", "keywords have a space next to a comma or at an end; separate terms with commas only")
    end
    FULL_WIDTH_COMMAS.each do |comma|
      next unless keywords.include?(comma)

      findings << finding("error", locale, "keywords", "full-width-comma", "keywords use #{comma}; separate terms with the ASCII comma", comma)
    end
    terms = keywords.split(",", -1).map(&:strip)
    findings << finding("error", locale, "keywords", "empty-term", "keywords have an empty term") if terms.any?(&:empty?)
    terms.reject!(&:empty?)

    counts = Hash.new(0)
    terms.each { |term| counts[normalize(term)] += 1 }
    counts.each do |term, count|
      findings << finding("error", locale, "keywords", "duplicate-term", "the term appears #{count} times", term) if count > 1
    end

    terms.uniq { |term| normalize(term) }.each do |term|
      findings.concat(check_keyword_term(locale, term, values))
      special = term.each_char.reject { |char| char.match?(KEYWORD_ALLOWED) || FULL_WIDTH_COMMAS.include?(char) }.uniq
      unless special.empty?
        findings << finding("warning", locale, "keywords", "special-character", "the term has special characters #{special.join(' ')}", term)
      end
      findings << finding("warning", locale, "keywords", "broad-term", "the term is too broad to help search", term) if BROAD_TERMS.include?(normalize(term))
    end
    findings.concat(check_plurals(locale, terms))
    findings.concat(check_listed_names(locale, "keywords", terms.join(" "), config, "error"))
    findings
  end

  # A keyword already in the name or subtitle of the same locale adds nothing: Apple combines words across fields.
  def check_keyword_term(locale, term, values)
    findings = []
    words = latin?(term) ? normalize(term).split(/\s+/).select { |word| word.length >= 2 } : [normalize(term)]
    %w[name subtitle].each do |field|
      words.each do |word|
        next unless contains?(values[field], word)

        findings << finding("warning", locale, "keywords", "keyword-overlap", "#{word} is already in the #{field}", term)
      end
    end
    findings
  end

  def check_plurals(locale, terms)
    words = terms.select { |term| latin?(term) }.flat_map { |term| normalize(term).split(/\s+/) }.uniq
    words.each_with_object([]) do |word, findings|
      next unless word.match?(/\A[a-z]{3,}\z/)

      plurals = [word + "s", word + "es"]
      plurals << word.sub(/y\z/, "ies") if word.match?(/[^aeiou]y\z/)
      plural = plurals.find { |candidate| words.include?(candidate) }
      next unless plural

      findings << finding("warning", locale, "keywords", "plural-duplicate", "#{word} and #{plural} are both present; keep the singular", "#{word},#{plural}")
    end
  end

  def check_name_and_subtitle(locale, values, config)
    findings = []
    %w[name subtitle].each do |field|
      text = values[field]
      next if text.strip.empty?

      if PRICE_PATTERNS.any? { |pattern| normalize(text).match?(pattern) }
        findings << finding("error", locale, field, "price", "#{field} mentions a price, a discount or free")
      end
      if CLAIM_PATTERNS.any? { |pattern| normalize(text).match?(pattern) }
        findings << finding("error", locale, field, "unverifiable-claim", "#{field} makes a ranking or superlative claim that the copy cannot verify")
      end
      findings.concat(check_listed_names(locale, field, text, config, "error"))
    end
    findings
  end

  def check_description(locale, values, config)
    description = values["description"]
    return [] if description.strip.empty?

    findings = []
    first_line = description.sub(/\A[ \t　]+/, "").lines.first.to_s.chomp
    if description.match?(/\A\s*\n/) || first_line.strip.empty? || first_line.match?(LIST_START)
      findings << finding("error", locale, "description", "first-sentence-missing",
                          "the description does not open with a sentence that says what the app does")
    else
      sentence = first_line[/\A.*?#{SENTENCE_END}/] || first_line
      limit = config["firstSentence"].fetch(locale, FIRST_SENTENCE_FALLBACK)
      if sentence.length > limit
        findings << finding("warning", locale, "description", "first-sentence-long",
                            "the first sentence has #{sentence.length} characters; the guide's target is #{limit}")
      end
    end
    if PRICE_PATTERNS.any? { |pattern| normalize(description).match?(pattern) }
      findings << finding("warning", locale, "description", "price", "the description mentions a price, a discount or free")
    end
    findings.concat(check_listed_names(locale, "description", description, config, "warning"))
    findings
  end

  def check_promotional_text(locale, values, config)
    text = values["promotionalText"]
    return [] if text.strip.empty?

    findings = []
    segments = text.split(PROMOTION_SEPARATORS).map(&:strip)
    if segments.length >= 4 && segments.all? { |segment| segment.length <= 15 } && !text.match?(SENTENCE_END)
      findings << finding("warning", locale, "promotionalText", "keyword-list",
                          "the promotional text looks like a list of keywords; it does not affect search, so write a sentence")
    end
    findings.concat(check_listed_names(locale, "promotionalText", text, config, "warning"))
    findings
  end

  def check_listed_names(locale, field, text, config, severity)
    findings = []
    { "competitors" => "competitor-name", "trademarks" => "trademark" }.each do |key, code|
      config[key].each do |name|
        next unless contains?(text, normalize(name))

        findings << finding(severity, locale, field, code, "#{field} contains a listed #{code.tr('-', ' ')}", name)
      end
    end
    findings
  end

  def normalize(text)
    text.unicode_normalize(:nfkc).downcase.strip
  end

  def latin?(text)
    text.match?(/\p{Latin}/) && !text.match?(/[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]/)
  end

  # Latin words match whole words; other scripts have no spaces between words, so they match as text.
  def contains?(text, normalized_term)
    return false if normalized_term.empty?

    haystack = normalize(text)
    if latin?(normalized_term)
      haystack.match?(/(?<![\p{Latin}\p{N}])#{Regexp.escape(normalized_term)}(?![\p{Latin}\p{N}])/)
    else
      haystack.include?(normalized_term)
    end
  end

  def finding(severity, locale, field, code, message, term = nil)
    entry = { "severity" => severity, "locale" => locale, "field" => field, "code" => code, "message" => message }
    entry["term"] = term if term
    entry
  end
end

exit AppStoreASO.run(ARGV) if $PROGRAM_NAME == __FILE__
