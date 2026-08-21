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
  section = lines

  if raw_anchor && !raw_anchor.empty?
    anchor = URI::DEFAULT_PARSER.unescape(raw_anchor).downcase
    heading_index = nil
    heading_level = nil

    lines.each_with_index do |line, index|
      match = line.match(/\A(#+)\s+(.+?)\s*\z/)
      next unless match
      next unless heading_slug(match[2]) == anchor

      heading_index = index
      heading_level = match[1].length
      break
    end

    unless heading_index
      failures << "missing referenced specification anchor: #{destination}"
      next
    end

    section_end = lines.length
    lines.each_with_index do |line, index|
      next if index <= heading_index
      match = line.match(/\A(#+)\s+/)
      if match && match[1].length <= heading_level
        section_end = index
        break
      end
    end
    section = lines[heading_index...section_end]
  end

  status = section.join("\n").match(/Status\s*:\s*(?:\*\*)?\s*(未決|提案)/u)&.captures&.first
  if status
    failures << "referenced specification section is not confirmed (#{status}): #{destination}"
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
