#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: check-spec-state.sh <issue-body.md>" >&2
  exit 2
fi

issue_body=$1
if [[ ! -f "$issue_body" ]]; then
  echo "Issue body file not found: $issue_body" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd -P)
repo_root=$(cd "$script_dir/../../../.." && pwd -P)

ruby - "$repo_root" "$issue_body" <<'RUBY'
require "pathname"
require "uri"

repo_root = Pathname(ARGV.fetch(0)).realpath
issue_body = Pathname(ARGV.fetch(1)).realpath

def heading_slug(title)
  title
    .downcase
    .gsub(/[`*_~]/, "")
    .gsub(/[^\p{L}\p{N}\s-]/u, "")
    .strip
    .gsub(/\s+/, "-")
    .gsub(/-+/, "-")
end

def visible_markdown_lines(lines)
  fence_character = nil
  fence_length = nil

  lines.map do |line|
    if fence_character
      closing_fence = /\A {0,3}#{Regexp.escape(fence_character)}{#{fence_length},}[ \t]*\z/
      if line.match?(closing_fence)
        fence_character = nil
        fence_length = nil
      end
      next nil
    end

    opening_fence = line.match(/\A {0,3}(`{3,}|~{3,})/)
    if opening_fence
      marker = opening_fence[1]
      fence_character = marker[0]
      fence_length = marker.length
      next nil
    end

    line
  end
end

def canonical_statuses(visible_lines, indices)
  indices.each_with_object([]) do |index, statuses|
    line = visible_lines[index]
    next unless line

    match = line.match(/\AStatus:[ \t]*(.*?)[ \t]*\z/u)
    next unless match

    statuses << [index, match[1]]
  end
end

def status_failure(scope, statuses, destination)
  if statuses.empty?
    return "referenced specification #{scope} has no canonical Status: #{destination}"
  end
  if statuses.length > 1
    return "referenced specification #{scope} has ambiguous canonical Status: #{destination}"
  end

  status = statuses.first[1]
  return nil if status == "確定"
  if %w[未決 提案 廃止].include?(status)
    return "referenced specification #{scope} is not confirmed (#{status}): #{destination}"
  end

  "referenced specification #{scope} has unknown canonical Status (#{status}): #{destination}"
end

destinations = issue_body.read.scan(/\[[^\]]*\]\(([^)]+)\)/).flatten
failures = []
local_specification_references = 0

destinations.each do |raw_destination|
  destination = raw_destination.strip.sub(/\s+["'][^"']*["']\z/, "")
  destination = destination[1...-1] if destination.start_with?("<") && destination.end_with?(">")
  next if destination.empty? || destination.start_with?("#")
  next if destination.match?(/\A[a-z][a-z0-9+.-]*:/i)

  raw_path, raw_anchor = destination.split("#", 2)
  path = URI::DEFAULT_PARSER.unescape(raw_path)
  next unless File.extname(path).downcase == ".md"

  spec_path = Pathname(path)
  spec_path = repo_root.join(spec_path).cleanpath unless spec_path.absolute?
  unless spec_path.file?
    failures << "missing referenced specification: #{raw_path}"
    next
  end
  local_specification_references += 1

  lines = spec_path.readlines(chomp: true)
  visible_lines = visible_markdown_lines(lines)
  headings = visible_lines.each_with_index.each_with_object([]) do |(line, index), result|
    next unless line
    match = line.match(/\A(#+)\s+(.+?)\s*\z/)
    next unless match

    result << [index, match[1].length, match[2]]
  end

  document_title = headings.find { |_, level, _| level == 1 }
  document_end = if document_title
    next_heading = headings.find { |index, _, _| index > document_title[0] }
    next_heading ? next_heading[0] : lines.length
  elsif headings.empty?
    lines.length
  else
    headings.first[0]
  end
  document_indices = (0...document_end)
  document_statuses = canonical_statuses(visible_lines, document_indices)
  if (failure = status_failure("document", document_statuses, destination))
    failures << failure
    next
  end

  section_indices = (document_end...lines.length)

  if raw_anchor && !raw_anchor.empty?
    anchor = URI::DEFAULT_PARSER.unescape(raw_anchor).downcase
    heading_index = nil
    heading_level = nil

    headings.each do |index, level, title|
      next unless heading_slug(title) == anchor

      heading_index = index
      heading_level = level
      break
    end

    unless heading_index
      failures << "missing referenced specification anchor: #{destination}"
      next
    end

    section_end = lines.length
    headings.each do |index, level, _|
      next if index <= heading_index
      if level <= heading_level
        section_end = index
        break
      end
    end
    section_indices = (heading_index...section_end)
  end

  section_statuses = canonical_statuses(visible_lines, section_indices)
    .reject { |index, _| document_indices.cover?(index) }
  unless section_statuses.empty?
    if (failure = status_failure("section", section_statuses, destination))
      failures << failure
    end
  end
end

if local_specification_references.zero?
  failures << "Issue body has no local Markdown specification reference"
end

unless failures.empty?
  warn failures.join("\n")
  exit 1
end

puts "Referenced specification sections are implementation-ready."
RUBY
