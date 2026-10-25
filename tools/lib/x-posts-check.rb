# frozen_string_literal: true
# encoding: UTF-8

# D-096: checks every X post material folder under XPosts/ against the x-post-material skill's format.
require "date"
require "json"
require "open3"
require "optparse"

module XPostsCheck
  FOLDER = /\A(\d{4}-\d{2}-\d{2})-[a-z0-9]+(?:-[a-z0-9]+)*\z/
  MEDIA = /\A[a-z0-9]+(?:-[a-z0-9]+)*\.(png|jpg|mp4)\z/
  KEYS = %w[schemaVersion app title createdAt issue related media].freeze
  MEDIA_KEYS = %w[file kind description].freeze
  SECTIONS = ["## 事実", "## 推しどころ", "## 画像と動画"].freeze
  KINDS = {"png" => "image", "jpg" => "image", "mp4" => "video"}.freeze
  MIN_VIDEO_SECONDS = 5.0
  MAX_VIDEO_SECONDS = 30.0

  module_function

  def run(argv)
    options = {}
    parser = OptionParser.new do |cli|
      cli.banner = "usage: x-posts-check.rb --ffprobe PATH --readme-template PATH XPOSTS_DIR"
      cli.on("--ffprobe PATH") { |value| options[:ffprobe] = value }
      cli.on("--readme-template PATH") { |value| options[:readme] = value }
    end
    root = parser.parse(argv)
    fail!(parser.banner) unless root.length == 1 && options[:ffprobe] && options[:readme]
    root = root.first
    fail!("not a directory: #{root}") unless File.directory?(root) && !File.symlink?(root)

    entries = children(root)
    folders = entries - ["README.md"]
    check_readme(root, options[:readme]) if entries.include?("README.md")
    folders.each { |name| check_folder(root, name, folders, options[:ffprobe]) }
    puts "x-posts: #{folders.length} post folder(s) passed"
  end

  def children(dir)
    Dir.children(dir).reject { |name| name == ".DS_Store" }.sort
  end

  def check_readme(root, template)
    path = File.join(root, "README.md")
    fail!("README.md must be a regular file") unless File.file?(path) && !File.symlink?(path)
    fail!("README.md differs from the skill template") unless File.binread(path) == File.binread(template)
  end

  def check_folder(root, name, folders, ffprobe)
    dir = File.join(root, name)
    match = FOLDER.match(name)
    fail!("folder name must be <YYYY-MM-DD>-<lowercase-ascii-subtitle>: #{name}") unless match
    begin
      Date.strptime(match[1], "%Y-%m-%d")
    rescue ArgumentError
      fail!("folder date is not a calendar date: #{name}")
    end
    fail!("not a directory: #{name}") unless File.directory?(dir) && !File.symlink?(dir)

    files = children(dir)
    %w[post.md post.json].each { |required| fail!("#{name}: missing #{required}") unless files.include?(required) }
    media_files = files - %w[post.md post.json]
    media_files.each do |file|
      fail!("#{name}: unexpected file #{file}") unless MEDIA.match?(file)
      fail!("#{name}: #{file} must be a regular file") unless File.file?(File.join(dir, file)) && !File.symlink?(File.join(dir, file))
    end

    markdown = read_utf8(File.join(dir, "post.md"), name)
    check_markdown(markdown, name, media_files)
    check_json(File.join(dir, "post.json"), name, match[1], media_files, folders)
    media_files.select { |file| file.end_with?(".mp4") }.each do |file|
      check_video(File.join(dir, file), "#{name}/#{file}", ffprobe)
    end
  end

  def read_utf8(path, name)
    text = File.binread(path).force_encoding(Encoding::UTF_8)
    fail!("#{name}: #{File.basename(path)} is not UTF-8") unless text.valid_encoding?
    text
  end

  def check_markdown(text, name, media_files)
    lines = text.lines.map(&:chomp)
    fail!("#{name}: post.md must start with a '# ' title") unless lines.first&.match?(/\A# \S/)
    indexes = SECTIONS.map { |heading| lines.index(heading) }
    fail!("#{name}: post.md needs the sections #{SECTIONS.join(", ")}") if indexes.any?(&:nil?)
    fail!("#{name}: post.md sections are out of order") unless indexes == indexes.sort
    bounds = indexes + [lines.length]
    SECTIONS.each_with_index do |heading, index|
      body = lines[(bounds[index] + 1)...bounds[index + 1]].reject { |line| line.strip.empty? }
      fail!("#{name}: post.md section #{heading} is empty") if body.empty?
    end
    fail!("#{name}: post.md still has a template placeholder") if text.match?(/<[^>\n]*>/)
    media_files.each do |file|
      fail!("#{name}: post.md does not describe #{file}") unless text.include?("`#{file}`")
    end
  end

  def check_json(path, name, date, media_files, folders)
    data = begin
      JSON.parse(read_utf8(path, name))
    rescue JSON::ParserError
      fail!("#{name}: post.json is not valid JSON")
    end
    fail!("#{name}: post.json keys must be #{KEYS.join(", ")}") unless data.is_a?(Hash) && data.keys == KEYS
    fail!("#{name}: schemaVersion must be 1") unless data["schemaVersion"] == 1
    %w[app title].each do |key|
      fail!("#{name}: #{key} must be a nonempty string") unless nonempty?(data[key])
    end
    fail!("#{name}: createdAt must equal the folder date") unless data["createdAt"] == date
    fail!("#{name}: issue must be a positive Issue number") unless data["issue"].is_a?(Integer) && data["issue"].positive?
    related = data["related"]
    fail!("#{name}: related must be an array of folder names") unless related.is_a?(Array) && related.all? { |item| item.is_a?(String) }
    fail!("#{name}: related has duplicates") unless related.uniq.length == related.length
    related.each do |item|
      fail!("#{name}: related must not name itself") if item == name
      fail!("#{name}: related folder does not exist: #{item}") unless folders.include?(item)
    end

    media = data["media"]
    fail!("#{name}: media must be a nonempty array") unless media.is_a?(Array) && !media.empty?
    listed = media.map do |entry|
      fail!("#{name}: media entries must have keys #{MEDIA_KEYS.join(", ")}") unless entry.is_a?(Hash) && entry.keys == MEDIA_KEYS
      file = entry["file"]
      fail!("#{name}: media file is not in the folder: #{file}") unless media_files.include?(file)
      fail!("#{name}: #{file} kind must be #{KINDS[File.extname(file).delete(".")]}") unless entry["kind"] == KINDS[File.extname(file).delete(".")]
      fail!("#{name}: #{file} needs a description") unless nonempty?(entry["description"])
      file
    end
    fail!("#{name}: media lists a file more than once") unless listed.uniq.length == listed.length
    fail!("#{name}: media must list every image and video in the folder") unless listed.sort == media_files.sort
    fail!("#{name}: at least one image is required") unless media.any? { |entry| entry["kind"] == "image" }
  end

  def check_video(path, label, ffprobe)
    output, status = Open3.capture2e(ffprobe, "-v", "error", "-show_entries", "format=duration",
                                     "-of", "default=noprint_wrappers=1:nokey=1", path)
    seconds = Float(output.strip, exception: false)
    fail!("#{label}: unable to read the video length") unless status.success? && seconds
    unless seconds >= MIN_VIDEO_SECONDS && seconds <= MAX_VIDEO_SECONDS
      fail!(format("%s: video must be 5 to 30 seconds, found %.2f", label, seconds))
    end
  end

  def nonempty?(value)
    value.is_a?(String) && !value.strip.empty?
  end

  def fail!(message)
    warn "x-posts: #{message}"
    exit 1
  end
end

XPostsCheck.run(ARGV) if $PROGRAM_NAME == __FILE__
