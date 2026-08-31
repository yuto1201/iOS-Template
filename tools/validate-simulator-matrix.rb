#!/usr/bin/env ruby
require "json"
require_relative "lib/verification-scope"

requested_scope = nil
if ARGV.length >= 2 && ARGV[-2] == "--scope"
  requested_scope = ARGV.pop
  ARGV.pop
  IOSTemplate::VerificationScope.case_ids(requested_scope)
end

phase, matrix_path, batch_id, devices_path = ARGV
valid_arity = %w[planned planned-with-xcode].include?(phase) ? ARGV.length == 3 : phase == "complete" && [3, 4].include?(ARGV.length)
abort "usage" unless valid_arity && matrix_path && batch_id
matrix = JSON.parse(File.read(matrix_path))
abort "blocked:environment: invalid matrix object" unless matrix.is_a?(Hash)
scope = IOSTemplate::VerificationScope.matrix_name(matrix)
abort "blocked:environment: frozen matrix scope differs from requested scope" if requested_scope && requested_scope != scope
expected = IOSTemplate::VerificationScope.rows(scope)
error = "blocked:environment: invalid #{phase} matrix"
expected_keys = phase == "planned" ? %w[batchId cases resolvedAt runtime schemaVersion] : %w[batchId cases resolvedAt runtime schemaVersion xcode]
expected_keys = (expected_keys + ["scope"]).sort if matrix.key?("scope")
abort error unless matrix.is_a?(Hash) && matrix.keys.sort == expected_keys
abort error unless matrix["schemaVersion"] == 1 && matrix["batchId"] == batch_id && matrix["resolvedAt"].is_a?(String) && !matrix["resolvedAt"].empty?
runtime = matrix["runtime"]
abort error unless runtime.is_a?(Hash) && runtime.keys.sort == %w[identifier version] && runtime.values.all? { |value| value.is_a?(String) && !value.empty? }
if phase != "planned"
  xcode = matrix["xcode"]
  abort error unless xcode.is_a?(Hash) && xcode.keys.sort == %w[build path version] && xcode.values.all? { |value| value.is_a?(String) && !value.empty? }
end
cases = matrix["cases"]
abort error unless cases.is_a?(Array) && cases.length == expected.length
abort error unless cases.all? { |entry| entry.is_a?(Hash) }
abort error unless cases.map { |entry| [entry["id"], entry["family"], entry["locale"], entry["language"]] } == expected
types = {}
udids = []
cases.each do |entry|
  required = phase == "complete" ? %w[deviceType family id language locale udid] : %w[deviceType family id language locale]
  abort error unless entry.keys.sort == required
  type = entry["deviceType"]
  abort error unless type.is_a?(Hash) && type.keys.sort == %w[identifier name] && type.values.all? { |value| value.is_a?(String) && !value.empty? }
  family = entry["family"]
  types[family] ||= type
  abort error unless types[family] == type
  if phase == "complete"
    abort error unless entry["udid"].is_a?(String) && entry["udid"].match?(/\A[0-9A-Fa-f-]+\z/)
    udids << entry["udid"]
  end
end
abort error if phase == "complete" && udids.uniq.length != expected.length
if phase == "complete" && devices_path
  buckets = JSON.parse(File.read(devices_path)).fetch("devices")
  all = buckets.values.flatten
  cases.each do |entry|
    name = "iOS-Template-#{batch_id}-#{entry["id"]}"
    matches = Array(buckets[runtime["identifier"]]).select { |device| device["udid"] == entry["udid"] && device["name"] == name && device["deviceTypeIdentifier"] == entry["deviceType"]["identifier"] }
    abort "blocked:environment: recorded Simulator no longer matches its batch matrix" unless matches.length == 1 && all.count { |device| device["name"] == name } == 1
  end
end
