#!/usr/bin/env ruby
require "json"

matrix_path, batch_id, devices_path = ARGV
abort "usage" unless matrix_path && batch_id
matrix = JSON.parse(File.read(matrix_path))
expected = [
  ["iphone-en", "iPhone", "en_US", "en"],
  ["iphone-ja", "iPhone", "ja_JP", "ja"],
  ["ipad-en", "iPad", "en_US", "en"],
  ["ipad-ja", "iPad", "ja_JP", "ja"]
]
abort "blocked:environment: invalid complete frozen batch matrix" unless matrix.keys.sort == %w[batchId cases resolvedAt runtime schemaVersion xcode]
abort "blocked:environment: invalid complete frozen batch matrix" unless matrix["schemaVersion"] == 1 && matrix["batchId"] == batch_id && matrix["resolvedAt"].is_a?(String) && !matrix["resolvedAt"].empty?
runtime = matrix["runtime"]
abort "blocked:environment: invalid complete frozen batch matrix" unless runtime.is_a?(Hash) && runtime.keys.sort == %w[identifier version] && runtime.values.all? { |value| value.is_a?(String) && !value.empty? }
xcode = matrix["xcode"]
abort "blocked:environment: invalid complete frozen batch matrix" unless xcode.is_a?(Hash) && xcode.keys.sort == %w[build path version] && xcode.values.all? { |value| value.is_a?(String) && !value.empty? }
cases = matrix["cases"]
abort "blocked:environment: invalid complete frozen batch matrix" unless cases.is_a?(Array) && cases.length == 4
abort "blocked:environment: invalid complete frozen batch matrix" unless cases.map { |entry| [entry["id"], entry["family"], entry["locale"], entry["language"]] } == expected
types = {}
udids = []
cases.each do |entry|
  required = %w[deviceType family id language locale udid]
  abort "blocked:environment: invalid complete frozen batch matrix" unless entry.keys.sort == required
  type = entry["deviceType"]
  abort "blocked:environment: invalid complete frozen batch matrix" unless type.is_a?(Hash) && type.keys.sort == %w[identifier name] && type.values.all? { |value| value.is_a?(String) && !value.empty? }
  family = entry["family"]
  types[family] ||= type
  abort "blocked:environment: invalid complete frozen batch matrix" unless types[family] == type
  abort "blocked:environment: invalid complete frozen batch matrix" unless entry["udid"].is_a?(String) && entry["udid"].match?(/\A[0-9A-Fa-f-]+\z/)
  udids << entry["udid"]
end
abort "blocked:environment: invalid complete frozen batch matrix" unless udids.uniq.length == 4
if devices_path
  buckets = JSON.parse(File.read(devices_path)).fetch("devices")
  all = buckets.values.flatten
  cases.each do |entry|
    name = "iOS-Template-#{batch_id}-#{entry["id"]}"
    matches = Array(buckets[runtime["identifier"]]).select { |device| device["udid"] == entry["udid"] && device["name"] == name && device["deviceTypeIdentifier"] == entry["deviceType"]["identifier"] }
    abort "blocked:environment: recorded Simulator no longer matches its batch matrix" unless matches.length == 1 && all.count { |device| device["name"] == name } == 1
  end
end
