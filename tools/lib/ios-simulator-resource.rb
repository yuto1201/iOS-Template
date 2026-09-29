#!/usr/bin/ruby --disable-gems
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "time"
require "timeout"

module IOSTemplate
  class SimulatorResourceError < StandardError; end

  # Leases the repository's dedicated iPhone and iPad Simulators (D-063). The manager never creates,
  # clones, renames, or deletes a device: it erases a dedicated device before each lease and shuts
  # it down when the lease is returned. Legacy per-case allocations written by older managers stay
  # in state-v1.json; this manager only reads them to count Mac-wide capacity and never changes them.
  class SimulatorResourceManager
    STATE_SCHEMA_VERSION = 1
    LEASE_SCHEMA_VERSION = 2
    RECEIPT_KIND = "dedicated-lease"
    CONFIG_PATH = "Config/dedicated-simulators.json"
    FAMILIES = %w[iphone ipad].freeze
    MAX_ALLOCATIONS = 4
    DEFAULT_MINIMUM_FREE_BYTES = 8 * 1024 * 1024 * 1024
    ACTIVE_STATUSES = %w[reserved active cleanup-failed].freeze
    LEGACY_ACTIVE_STATUSES = %w[reserved active deleting cleanup-failed].freeze
    SHUTDOWN_WAIT_SECONDS = 30
    SESSION_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/
    BATCH_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9-]{0,63}\z/
    CASE_PATTERN = /\A(?:iphone|ipad)-(?:en|ja)\z/
    ATTEMPT_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/
    SHA_PATTERN = /\A[0-9a-f]{40}\z/
    UDID_PATTERN = /\A[0-9A-Fa-f-]{8,64}\z/
    DEVICE_NAME_PATTERN = /\A[^\x00-\x1f\x7f]{1,96}\z/
    DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/
    LEASE_KEYS = %w[
      allocationId allocator attemptId batchId caseId cleanup deviceName deviceSet deviceTypeIdentifier
      events family freeSpace headSha integrityDigest issue owner preparation preparedAt releasedAt
      repository reservedAt runtimeIdentifier schemaVersion sessionId status udid
    ].freeze

    def initialize(options)
      @options = options
      @test_mode = options.delete("--test-mode") == "true"
      @xcrun = if @test_mode && options["--xcrun"]
        File.realpath(options["--xcrun"])
      else
        "/usr/bin/xcrun"
      end
      @developer_dir = options["--developer-dir"]
      @command_timeout = positive_integer(options.fetch("--command-timeout", "180"), "command timeout")
      @root = resolve_root(options["--state-root"])
      ensure_secure_root
    end

    def allocate
      identity = allocation_identity
      wait_seconds = nonnegative_integer(@options.fetch("--wait-seconds", "0"), "wait seconds")
      minimum_free = nonnegative_integer(
        @options.fetch("--minimum-free-bytes", DEFAULT_MINIMUM_FREE_BYTES.to_s),
        "minimum free bytes"
      )
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait_seconds
      reservation = nil

      loop do
        denial = nil
        with_state do |legacy_active, state|
          recover_stale!(state, dry_run: false)
          leases = state.fetch("leases")
          existing = leases.find do |record|
            ACTIVE_STATUSES.include?(record["status"]) && same_operation?(record, identity)
          end
          if existing
            if existing["status"] == "active" && process_active?(existing)
              write_receipt(existing)
              print_receipt(existing)
              return
            end
            denial = "matching lease is not safely reusable"
            next
          end

          active = leases.select { |record| ACTIVE_STATUSES.include?(record["status"]) }
          if active.any? { |record| record["sessionId"] == identity.fetch("sessionId") }
            denial = "same session already owns a Simulator lease"
            next
          end
          if active.any? { |record| record["deviceName"] == identity.fetch("deviceName") }
            denial = "dedicated Simulator '#{identity.fetch("deviceName")}' is leased by another run"
            next
          end
          in_use = capacity_in_use(active, legacy_active)
          if in_use >= MAX_ALLOCATIONS
            denial = "Mac-wide iPhone/iPad Simulator allocation limit (#{MAX_ALLOCATIONS}) is in use"
            next
          end

          free_before = available_bytes
          if free_before < minimum_free
            denial = "insufficient free space for a Simulator lease (available=#{free_before}, required=#{minimum_free})"
            next
          end

          device = dedicated_live_device!(identity)
          unless device["state"] == "Shutdown"
            denial = "dedicated Simulator '#{identity.fetch("deviceName")}' is #{device["state"]} outside a lease"
            next
          end

          record = identity.merge(
            "schemaVersion" => LEASE_SCHEMA_VERSION,
            "allocationId" => SecureRandom.uuid.downcase,
            "allocator" => process_identity(Process.pid),
            "status" => "reserved",
            "deviceSet" => "default",
            "udid" => device.fetch("udid"),
            "reservedAt" => timestamp,
            "preparedAt" => nil,
            "releasedAt" => nil,
            "freeSpace" => {"beforeLeaseBytes" => free_before, "afterReleaseBytes" => nil},
            "preparation" => nil,
            "cleanup" => nil,
            "events" => []
          )
          add_event(record, "reserved", "capacityCount" => in_use + 1, "udid" => device.fetch("udid"))
          leases << record
          reservation = snapshot_record(record)
        end
        break if reservation
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise SimulatorResourceError, "blocked:environment: #{denial}; wait expired"
        end
        sleep 0.1
      end

      begin
        run_simctl("erase", reservation.fetch("udid"))
        record = nil
        with_state do |_legacy_active, state|
          current = find_record!(state, reservation.fetch("allocationId"))
          ensure_record_identity!(current, identity)
          raise SimulatorResourceError, "lease reservation changed before preparation completed" unless current["status"] == "reserved"
          live = unique_live_device!(current)
          raise SimulatorResourceError, "dedicated Simulator is not shut down after erase" unless live["state"] == "Shutdown"
          observed = timestamp
          current["status"] = "active"
          current["preparedAt"] = observed
          current["preparation"] = {"status" => "passed", "erased" => true, "observedAt" => observed}
          add_event(current, "prepared", "udid" => current.fetch("udid"))
          record = snapshot_record(current)
        end
        write_receipt(record)
        print_receipt(record)
      rescue StandardError => error
        cleanup_error = nil
        begin
          with_state do |_legacy_active, state|
            current = find_record!(state, reservation.fetch("allocationId"))
            if cleanup_lease!(current, reason: "prepare-failure") == "unverified"
              raise SimulatorResourceError, "leased Simulator disappeared before its Shutdown was observed"
            end
          end
        rescue StandardError => cleanup_failure
          cleanup_error = cleanup_failure.message
        end
        message = "blocked:environment: dedicated Simulator preparation failed: #{error.message}"
        message += "; cleanup failed: #{cleanup_error}" if cleanup_error
        raise SimulatorResourceError, message
      end
    end

    def release
      allocation_id = required("--allocation-id")
      session_id = required("--session")
      validate!(SESSION_PATTERN, session_id, "session")
      record = nil
      failure = nil
      with_state do |_legacy_active, state|
        current = find_record!(state, allocation_id)
        raise SimulatorResourceError, "lease belongs to another session" unless current["sessionId"] == session_id
        if current["status"] == "released"
          record = snapshot_record(current)
          next
        end
        raise SimulatorResourceError, "lease is not releasable" unless ACTIVE_STATUSES.include?(current["status"])
        begin
          if cleanup_lease!(current, reason: required("--reason")) == "unverified"
            failure = SimulatorResourceError.new("leased Simulator disappeared before its Shutdown was observed")
          end
        rescue SimulatorResourceError => error
          current["cleanup"] = {"status" => "failed", "reason" => error.message, "deviceState" => "unknown", "observedAt" => timestamp}
          add_event(current, "cleanup-failed", "reason" => error.message)
          failure = error
        end
        record = snapshot_record(current)
      end
      write_receipt(record)
      raise failure if failure
      print_receipt(record)
    end

    def validate
      allocation_id = required("--allocation-id")
      session_id = required("--session")
      expected_state = @options["--expected-state"]
      if expected_state && !%w[Booted Shutdown].include?(expected_state)
        raise SimulatorResourceError, "expected state is invalid"
      end
      output = nil
      with_state(write: false) do |_legacy_active, state|
        record = find_record!(state, allocation_id)
        raise SimulatorResourceError, "lease belongs to another session" unless record["sessionId"] == session_id
        raise SimulatorResourceError, "lease is not active" unless record["status"] == "active"
        live = unique_live_device!(record)
        if expected_state && live["state"] != expected_state
          raise SimulatorResourceError, "target Simulator state does not match the required state"
        end
        output = live.fetch("state")
      end
      puts output
    end

    def inventory(dry_run: true)
      result = nil
      with_state(write: !dry_run) do |legacy_active, state|
        candidates = recover_stale!(state, dry_run: dry_run)
        active = state.fetch("leases").select { |record| ACTIVE_STATUSES.include?(record["status"]) }
        unmanaged = unmanaged_live_devices(legacy_active)
        result = {
          "schemaVersion" => LEASE_SCHEMA_VERSION,
          "dryRun" => dry_run,
          "observedAt" => timestamp,
          "limit" => MAX_ALLOCATIONS,
          "capacityInUse" => capacity_in_use(active, legacy_active, unmanaged),
          "activeCount" => active.length,
          "legacyActiveCount" => legacy_active.length,
          "availableBytes" => available_bytes,
          "allocations" => state.fetch("leases").map { |record| inventory_record(record) },
          "legacyAllocations" => legacy_active,
          "protectedUnmanagedDevices" => unmanaged.map { |device| unmanaged_inventory_record(device) },
          "recoveryCandidates" => candidates
        }
      end
      puts JSON.pretty_generate(result)
    end

    private

    def allocation_identity
      session_id = required("--session")
      repository = File.realpath(required("--repository"))
      issue = positive_integer(required("--issue"), "issue")
      head_sha = required("--head")
      batch_id = required("--batch")
      attempt_id = required("--attempt")
      case_id = required("--case")
      runtime = required("--runtime")
      device_type = required("--device-type")
      owner_pid = positive_integer(required("--owner-pid"), "owner PID")
      validate!(SESSION_PATTERN, session_id, "session")
      validate!(SHA_PATTERN, head_sha, "Head SHA")
      validate!(BATCH_PATTERN, batch_id, "batch")
      validate!(ATTEMPT_PATTERN, attempt_id, "attempt")
      validate!(CASE_PATTERN, case_id, "case")
      validate_identifier!(runtime, "Runtime")
      validate_identifier!(device_type, "Device Type")
      owner_start = process_start_token(owner_pid)
      raise SimulatorResourceError, "owner process is not active" unless owner_start
      family = case_id.split("-").first
      declared = declared_device!(repository, family)
      unless declared["deviceTypeIdentifier"] == device_type && declared["runtimeIdentifier"] == runtime
        raise SimulatorResourceError,
              "blocked:environment: requested #{family} Device Type and Runtime differ from the dedicated Simulator declaration"
      end
      {
        "sessionId" => session_id,
        "repository" => {"root" => repository, "identity" => repository_identity(repository)},
        "issue" => issue,
        "headSha" => head_sha,
        "batchId" => batch_id,
        "attemptId" => attempt_id,
        "caseId" => case_id,
        "family" => family,
        "deviceName" => declared.fetch("name"),
        "owner" => {"pid" => owner_pid, "startToken" => owner_start},
        "runtimeIdentifier" => runtime,
        "deviceTypeIdentifier" => device_type
      }
    end

    # Reads the tracked dedicated Simulator declaration of the repository under verification.
    def declared_device!(repository, family)
      path = File.join(repository, CONFIG_PATH)
      info = File.lstat(path)
      unless info.file? && !info.symlink?
        raise SimulatorResourceError, "blocked:environment: #{CONFIG_PATH} is not a regular file"
      end
      config = JSON.parse(File.binread(path, 64 * 1024))
      devices = config.is_a?(Hash) && config.keys.sort == %w[devices schemaVersion] && config["schemaVersion"] == 1 ? config["devices"] : nil
      unless devices.is_a?(Array) && devices.length == FAMILIES.length &&
             devices.map { |entry| entry.is_a?(Hash) ? entry["family"] : nil } == FAMILIES
        raise SimulatorResourceError, "blocked:environment: #{CONFIG_PATH} must declare exactly one iphone and one ipad Simulator"
      end
      devices.each do |entry|
        unless entry.keys.sort == %w[deviceTypeIdentifier family name runtimeIdentifier] &&
               DEVICE_NAME_PATTERN.match?(entry["name"].to_s) && !entry["name"].start_with?("iOS-Template-")
          raise SimulatorResourceError, "blocked:environment: #{CONFIG_PATH} has an invalid device declaration"
        end
        validate_identifier!(entry["deviceTypeIdentifier"], "declared Device Type")
        validate_identifier!(entry["runtimeIdentifier"], "declared Runtime")
      end
      raise SimulatorResourceError, "blocked:environment: #{CONFIG_PATH} device names must be unique" unless devices.map { |entry| entry["name"] }.uniq.length == devices.length
      devices.find { |entry| entry["family"] == family }
    rescue Errno::ENOENT
      raise SimulatorResourceError, "blocked:environment: #{CONFIG_PATH} is missing"
    rescue JSON::ParserError
      raise SimulatorResourceError, "blocked:environment: #{CONFIG_PATH} is not valid JSON"
    end

    # Finds the one live device that matches the dedicated declaration by exact name, type, and Runtime.
    def dedicated_live_device!(identity)
      name = identity.fetch("deviceName")
      matches = live_devices.select { |device| device["name"] == name }
      unless matches.length == 1
        raise SimulatorResourceError,
              "blocked:environment: dedicated Simulator '#{name}' must exist exactly once (found #{matches.length})"
      end
      device = matches.first
      unless device["runtimeIdentifier"] == identity.fetch("runtimeIdentifier") &&
             device["deviceTypeIdentifier"] == identity.fetch("deviceTypeIdentifier") &&
             device["isAvailable"] != false && UDID_PATTERN.match?(device["udid"].to_s)
        raise SimulatorResourceError,
              "blocked:environment: dedicated Simulator '#{name}' does not match its declared Device Type and Runtime or is unavailable"
      end
      device
    end

    def same_operation?(record, identity)
      %w[sessionId issue headSha batchId attemptId caseId family deviceName runtimeIdentifier deviceTypeIdentifier].all? do |key|
        record[key] == identity[key]
      end && record["repository"] == identity["repository"] && record["owner"] == identity["owner"]
    end

    def ensure_record_identity!(record, identity)
      raise SimulatorResourceError, "lease identity changed" unless same_operation?(record, identity)
    end

    def repository_identity(repository)
      output, status = Open3.capture2e(
        {"PATH" => "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null"},
        "/usr/bin/git", "-C", repository, "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
        "rev-parse", "--path-format=absolute", "--git-common-dir"
      )
      unless status.success?
        diagnostic = output.encode("UTF-8", invalid: :replace, undef: :replace).lines.first.to_s.strip
        raise SimulatorResourceError, "repository identity is unavailable#{diagnostic.empty? ? "" : ": #{diagnostic}"}"
      end
      common = File.realpath(output.strip)
      "sha256:#{Digest::SHA256.hexdigest(common)}"
    end

    def capacity_in_use(active, legacy_active, unmanaged = nil)
      unmanaged ||= unmanaged_live_devices(legacy_active)
      active.length + legacy_active.length + unmanaged.count { |device| device["state"] != "Shutdown" }
    end

    def recover_stale!(state, dry_run:)
      candidates = []
      state.fetch("leases").each do |record|
        next unless ACTIVE_STATUSES.include?(record["status"])
        next if process_active?(record)
        candidates << {
          "allocationId" => record["allocationId"],
          "udid" => record["udid"],
          "deviceName" => record["deviceName"],
          "sessionId" => record["sessionId"],
          "repositoryIdentity" => record.dig("repository", "identity"),
          "status" => record["status"],
          "reason" => "owner-process-identity-is-not-active"
        }
        next if dry_run
        cleanup_lease!(record, reason: "orphan-recovery")
      rescue SimulatorResourceError => error
        record["status"] = "cleanup-failed"
        record["cleanup"] = {"status" => "failed", "reason" => error.message, "deviceState" => "unknown", "observedAt" => timestamp}
        add_event(record, "cleanup-failed", "reason" => error.message)
      end
      candidates
    end

    # Shuts the leased dedicated device down and returns the lease. The device is never deleted.
    # Cleanup passes only on an observed Shutdown of the exact leased identity. A device that is
    # absent, or disappears before that observation, releases the lease as explicitly unverified
    # so no receipt claims a Shutdown that was never seen. Returns the cleanup status.
    def cleanup_lease!(record, reason:)
      return record.dig("cleanup", "status") if record["status"] == "released"
      device_state = observed_shutdown_state!(record)
      status = device_state == "Shutdown" ? "passed" : "unverified"
      observed = timestamp
      record["status"] = "released"
      record["releasedAt"] = observed
      record.fetch("freeSpace")["afterReleaseBytes"] = available_bytes
      record["cleanup"] = {"status" => status, "reason" => reason, "deviceState" => device_state, "observedAt" => observed}
      add_event(record, "released", "reason" => reason, "deviceState" => device_state)
      status
    rescue SimulatorResourceError
      record["status"] = "cleanup-failed"
      raise
    end

    # Returns "Shutdown" once the exact leased device is observed shut down, or "absent" when it is
    # not listed. An ambiguous UDID, a changed identity, or a timeout raises.
    def observed_shutdown_state!(record)
      live = leased_live_device(record)
      return "absent" if live.nil?
      return "Shutdown" if live["state"] == "Shutdown"
      begin
        run_simctl("shutdown", record.fetch("udid"))
      rescue SimulatorResourceError
        nil
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SHUTDOWN_WAIT_SECONDS
      loop do
        live = leased_live_device(record)
        return "absent" if live.nil?
        return "Shutdown" if live["state"] == "Shutdown"
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise SimulatorResourceError, "leased Simulator did not shut down"
        end
        sleep 0.2
      end
    end

    def leased_live_device(record)
      matches = live_devices.select { |device| device["udid"] == record.fetch("udid") }
      return nil if matches.empty?
      raise SimulatorResourceError, "leased Simulator UDID is ambiguous" unless matches.length == 1
      live = matches.first
      unless live["name"] == record["deviceName"] &&
             live["runtimeIdentifier"] == record["runtimeIdentifier"] &&
             live["deviceTypeIdentifier"] == record["deviceTypeIdentifier"]
        raise SimulatorResourceError, "leased Simulator live identity does not match its durable lease"
      end
      live
    end

    def unique_live_device!(record)
      matches = live_devices.select { |device| device["udid"] == record.fetch("udid") }
      raise SimulatorResourceError, "leased Simulator UDID is missing or ambiguous" unless matches.length == 1
      live = matches.first
      unless live["name"] == record["deviceName"] &&
             live["runtimeIdentifier"] == record["runtimeIdentifier"] &&
             live["deviceTypeIdentifier"] == record["deviceTypeIdentifier"]
        raise SimulatorResourceError, "leased Simulator does not match the durable lease"
      end
      live
    end

    def live_devices
      raw = run_simctl("list", "devices", "-j")
      root = JSON.parse(raw)
      buckets = root.fetch("devices")
      raise SimulatorResourceError, "simctl devices response is invalid" unless buckets.is_a?(Hash)
      buckets.flat_map do |runtime, entries|
        raise SimulatorResourceError, "simctl devices bucket is invalid" unless entries.is_a?(Array)
        entries.map do |entry|
          raise SimulatorResourceError, "simctl device entry is invalid" unless entry.is_a?(Hash)
          entry.merge("runtimeIdentifier" => runtime)
        end
      end
    rescue JSON::ParserError, KeyError => error
      raise SimulatorResourceError, "unable to parse simctl devices: #{error.message}"
    end

    def run_simctl(*arguments)
      if %w[create clone rename delete].include?(arguments.first)
        raise SimulatorResourceError, "simctl #{arguments.first} is forbidden for dedicated Simulators"
      end
      command = [@xcrun, "simctl", *arguments]
      environment = {"PATH" => "/usr/bin:/bin", "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8"}
      environment["DEVELOPER_DIR"] = @developer_dir if @developer_dir
      output_path = File.join(@root, ".command-#{SecureRandom.uuid}.out")
      error_path = File.join(@root, ".command-#{SecureRandom.uuid}.err")
      output = ""
      error = ""
      status = nil
      File.open(output_path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |stdout|
        File.open(error_path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |stderr|
          pid = Process.spawn(environment, *command, in: File::NULL, out: stdout, err: stderr, pgroup: true)
          begin
            Timeout.timeout(@command_timeout) { _, status = Process.wait2(pid) }
          rescue Timeout::Error
            Process.kill("TERM", -pid) rescue Errno::ESRCH
            sleep 0.1
            Process.kill("KILL", -pid) rescue Errno::ESRCH
            Process.wait(pid) rescue Errno::ECHILD
            raise SimulatorResourceError, "simctl command timed out"
          end
        end
      end
      output = File.binread(output_path, 16 * 1024 * 1024)
      error = File.binread(error_path, 1024 * 1024)
      unless status&.success?
        diagnostic = error.encode("UTF-8", invalid: :replace, undef: :replace).lines.first.to_s.strip
        raise SimulatorResourceError, "simctl #{arguments.first} failed#{diagnostic.empty? ? "" : ": #{diagnostic}"}"
      end
      output
    ensure
      File.unlink(output_path) if output_path && File.file?(output_path)
      File.unlink(error_path) if error_path && File.file?(error_path)
    end

    # Lock order: legacy state lock (shared, read-only) first, then the dedicated lease lock.
    def with_state(write: true)
      legacy_lock = secure_open(@legacy_lock_path, File::RDWR | File::CREAT, 0o600)
      begin
        raise SimulatorResourceError, "unable to lock legacy Simulator resource state" unless legacy_lock.flock(File::LOCK_SH)
        lock = secure_open(@lock_path, File::RDWR | File::CREAT, 0o600)
        begin
          raise SimulatorResourceError, "unable to lock Simulator lease state" unless lock.flock(File::LOCK_EX)
          legacy_active = read_legacy_active
          state = read_state
          validate_state!(state)
          begin
            result = yield legacy_active, state
          rescue StandardError
            write_state(state) if write
            raise
          end
          write_state(state) if write
          result
        ensure
          lock.flock(File::LOCK_UN) rescue nil
          lock.close
        end
      ensure
        legacy_lock.flock(File::LOCK_UN) rescue nil
        legacy_lock.close
      end
    end

    # Summarizes the active per-case allocations of older managers without validating or changing them.
    def read_legacy_active
      return [] unless File.exist?(@legacy_state_path)
      info = File.lstat(@legacy_state_path)
      unless info.file? && !info.symlink? && info.uid == Process.uid && info.nlink == 1
        raise SimulatorResourceError, "legacy Simulator resource state file is unsafe"
      end
      state = JSON.parse(File.binread(@legacy_state_path, 16 * 1024 * 1024))
      records = state.is_a?(Hash) ? state["allocations"] : nil
      raise SimulatorResourceError, "legacy Simulator resource state is invalid" unless records.is_a?(Array) && records.all? { |record| record.is_a?(Hash) }
      records.select { |record| LEGACY_ACTIVE_STATUSES.include?(record["status"]) }.map do |record|
        {
          "allocationId" => record["allocationId"], "status" => record["status"],
          "sessionId" => record["sessionId"], "udid" => record["udid"], "deviceName" => record["deviceName"],
          "runtimeIdentifier" => record["runtimeIdentifier"], "deviceTypeIdentifier" => record["deviceTypeIdentifier"]
        }
      end
    rescue JSON::ParserError => error
      raise SimulatorResourceError, "legacy Simulator resource state is invalid: #{error.message}"
    end

    def read_state
      return {"schemaVersion" => STATE_SCHEMA_VERSION, "leases" => []} unless File.exist?(@state_path)
      info = File.lstat(@state_path)
      unless info.file? && !info.symlink? && info.uid == Process.uid && info.nlink == 1
        raise SimulatorResourceError, "Simulator lease state file is unsafe"
      end
      JSON.parse(File.binread(@state_path, 16 * 1024 * 1024))
    rescue JSON::ParserError => error
      raise SimulatorResourceError, "Simulator lease state is invalid: #{error.message}"
    end

    def validate_state!(state)
      unless state.is_a?(Hash) && state.keys.sort == %w[leases schemaVersion] &&
             state["schemaVersion"] == STATE_SCHEMA_VERSION && state["leases"].is_a?(Array)
        raise SimulatorResourceError, "Simulator lease state schema is invalid"
      end
      ids = state.fetch("leases").map do |record|
        validate_record!(record)
        record.fetch("allocationId")
      end
      raise SimulatorResourceError, "Simulator lease state has duplicate leases" unless ids.uniq.length == ids.length
    end

    def validate_record!(record)
      raise SimulatorResourceError, "Simulator lease record is invalid" unless record.is_a?(Hash)
      unless record.keys.sort == LEASE_KEYS.sort && record["integrityDigest"].to_s.match?(DIGEST_PATTERN)
        raise SimulatorResourceError, "Simulator lease record schema is invalid"
      end
      unless record["integrityDigest"] == record_integrity_digest(record)
        raise SimulatorResourceError, "Simulator lease record integrity is invalid"
      end
      validate!(SESSION_PATTERN, record["sessionId"], "record session")
      validate!(BATCH_PATTERN, record["batchId"], "record batch")
      validate!(CASE_PATTERN, record["caseId"], "record case")
      validate!(SHA_PATTERN, record["headSha"], "record Head")
      validate!(UDID_PATTERN, record["udid"], "record UDID")
      validate!(DEVICE_NAME_PATTERN, record["deviceName"], "record device name")
      unless record["schemaVersion"] == LEASE_SCHEMA_VERSION && record["allocationId"].is_a?(String) &&
             (ACTIVE_STATUSES.include?(record["status"]) || record["status"] == "released") &&
             FAMILIES.include?(record["family"]) && record["caseId"].start_with?("#{record["family"]}-")
        raise SimulatorResourceError, "Simulator lease status is invalid"
      end
      unless record["repository"].is_a?(Hash) && record["repository"].keys.sort == %w[identity root] &&
             record.dig("repository", "root").is_a?(String) &&
             record.dig("repository", "identity").to_s.match?(DIGEST_PATTERN) &&
             valid_process_identity?(record["owner"]) && valid_process_identity?(record["allocator"]) &&
             record["deviceSet"] == "default" && record["issue"].is_a?(Integer) && record["issue"].positive? &&
             record["events"].is_a?(Array) && record["freeSpace"].is_a?(Hash) &&
             record["freeSpace"].keys.sort == %w[afterReleaseBytes beforeLeaseBytes] &&
             record.dig("freeSpace", "beforeLeaseBytes").is_a?(Integer) &&
             (record.dig("freeSpace", "afterReleaseBytes").nil? || record.dig("freeSpace", "afterReleaseBytes").is_a?(Integer))
        raise SimulatorResourceError, "Simulator lease identity is invalid"
      end
      validate_identifier!(record["runtimeIdentifier"], "record Runtime")
      validate_identifier!(record["deviceTypeIdentifier"], "record Device Type")
    end

    def write_state(state)
      state.fetch("leases").each { |record| seal_record!(record) }
      temporary = File.join(@root, ".dedicated-state-#{SecureRandom.uuid}.json")
      data = JSON.pretty_generate(state) + "\n"
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
        file.write(data)
        file.flush
        file.fsync
      end
      File.rename(temporary, @state_path)
      File.open(@root, File::RDONLY) { |directory| directory.fsync }
    ensure
      File.unlink(temporary) if temporary && File.file?(temporary)
    end

    def write_receipt(record)
      directory = @options["--receipt-dir"]
      return unless directory
      ensure_secure_receipt_directory(directory)
      destination = File.join(File.realpath(directory), "allocation-#{record.fetch("allocationId")}.json")
      temporary = File.join(File.realpath(directory), ".receipt-#{SecureRandom.uuid}.json")
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
        file.write(JSON.pretty_generate(receipt_record(record)) + "\n")
        file.flush
        file.fsync
      end
      File.rename(temporary, destination)
      File.open(File.realpath(directory), File::RDONLY) { |dir| dir.fsync }
    ensure
      File.unlink(temporary) if defined?(temporary) && temporary && File.file?(temporary)
    end

    def receipt_path(record)
      directory = @options["--receipt-dir"]
      directory ? File.join(File.realpath(directory), "allocation-#{record.fetch("allocationId")}.json") : "-"
    end

    def print_receipt(record)
      puts [record.fetch("allocationId"), record["udid"], receipt_path(record)].join("\t")
    end

    def ensure_secure_receipt_directory(path)
      parent = File.dirname(path)
      FileUtils.mkdir_p(parent, mode: 0o700) unless File.exist?(parent)
      Dir.mkdir(path, 0o700) unless File.exist?(path)
      info = File.lstat(path)
      unless info.directory? && !info.symlink? && info.uid == Process.uid
        raise SimulatorResourceError, "lease receipt directory is unsafe"
      end
      File.chmod(0o700, path)
    end

    def find_record!(state, allocation_id)
      matches = state.fetch("leases").select { |record| record["allocationId"] == allocation_id }
      raise SimulatorResourceError, "lease ID is missing or ambiguous" unless matches.length == 1
      matches.first
    end

    def process_active?(record)
      process_identity_active?(record["owner"]) ||
        (record["status"] == "reserved" && process_identity_active?(record["allocator"]))
    end

    def process_identity(pid)
      start_token = process_start_token(pid)
      raise SimulatorResourceError, "resource manager process identity is unavailable" unless start_token
      {"pid" => pid, "startToken" => start_token}
    end

    def valid_process_identity?(identity)
      identity.is_a?(Hash) && identity.keys.sort == %w[pid startToken] &&
        identity["pid"].is_a?(Integer) && identity["pid"].positive? &&
        identity["startToken"].is_a?(String) && !identity["startToken"].empty?
    end

    def process_identity_active?(identity)
      valid_process_identity?(identity) && process_start_token(identity["pid"]) == identity["startToken"]
    end

    def process_start_token(pid)
      output, status = Open3.capture2e({"PATH" => "/usr/bin:/bin"}, "/bin/ps", "-o", "lstart=", "-p", pid.to_s)
      return nil unless status.success?
      token = output.strip
      token.empty? ? nil : token
    end

    def available_bytes
      output, status = Open3.capture2e({"PATH" => "/usr/bin:/bin", "LANG" => "C", "LC_ALL" => "C"}, "/bin/df", "-Pk", @root)
      raise SimulatorResourceError, "unable to measure Simulator volume free space" unless status.success?
      fields = output.lines.last.to_s.split
      blocks = Integer(fields.fetch(3), 10)
      blocks * 1024
    rescue ArgumentError, IndexError
      raise SimulatorResourceError, "unable to parse Simulator volume free space"
    end

    def inventory_record(record)
      {
        "allocationId" => record["allocationId"], "status" => record["status"],
        "sessionId" => record["sessionId"], "repository" => record["repository"],
        "issue" => record["issue"], "headSha" => record["headSha"],
        "batchId" => record["batchId"], "attemptId" => record["attemptId"],
        "caseId" => record["caseId"], "family" => record["family"], "udid" => record["udid"],
        "deviceName" => record["deviceName"], "runtimeIdentifier" => record["runtimeIdentifier"],
        "deviceTypeIdentifier" => record["deviceTypeIdentifier"],
        "ownerActive" => process_identity_active?(record["owner"]),
        "allocatorActive" => process_identity_active?(record["allocator"]),
        "freeSpace" => record["freeSpace"], "preparation" => record["preparation"], "cleanup" => record["cleanup"]
      }
    end

    # Devices named like the legacy per-case allocations that no legacy durable record owns.
    def unmanaged_live_devices(legacy_active)
      live_devices.select do |device|
        next false unless device["name"].to_s.start_with?("iOS-Template-")
        !legacy_active.any? do |record|
          (record["udid"] && record["udid"] == device["udid"]) ||
            (record["status"] == "reserved" && record["deviceName"] == device["name"] &&
             record["runtimeIdentifier"] == device["runtimeIdentifier"] &&
             record["deviceTypeIdentifier"] == device["deviceTypeIdentifier"])
        end
      end
    end

    def unmanaged_inventory_record(device)
      {
        "udid" => device["udid"], "name" => device["name"], "state" => device["state"],
        "countsTowardCapacity" => device["state"] != "Shutdown",
        "runtimeIdentifier" => device["runtimeIdentifier"],
        "deviceTypeIdentifier" => device["deviceTypeIdentifier"],
        "dataPath" => device["dataPath"], "dataBytes" => nil,
        "dataMeasurement" => "not-measured", "protection" => "no-active-durable-allocation"
      }
    end

    def receipt_record(record)
      {
        "schemaVersion" => record["schemaVersion"], "kind" => RECEIPT_KIND,
        "allocationId" => record["allocationId"],
        "status" => record["status"], "sessionId" => record["sessionId"],
        "repositoryIdentity" => record.dig("repository", "identity"), "issue" => record["issue"],
        "headSha" => record["headSha"], "batchId" => record["batchId"],
        "attemptId" => record["attemptId"], "caseId" => record["caseId"],
        "deviceSet" => record["deviceSet"], "deviceName" => record["deviceName"],
        "udid" => record["udid"], "runtimeIdentifier" => record["runtimeIdentifier"],
        "deviceTypeIdentifier" => record["deviceTypeIdentifier"],
        "reservedAt" => record["reservedAt"], "preparedAt" => record["preparedAt"],
        "releasedAt" => record["releasedAt"], "freeSpace" => record["freeSpace"],
        "preparation" => record["preparation"], "cleanup" => record["cleanup"]
      }
    end

    def resolve_root(requested)
      if requested
        raise SimulatorResourceError, "custom state root requires test mode" unless @test_mode
        root = File.expand_path(requested)
        raise SimulatorResourceError, "test state root must be absolute" unless root.start_with?("/")
        return root
      end
      output, status = Open3.capture2e({"PATH" => "/usr/bin:/bin"}, "/usr/bin/getconf", "DARWIN_USER_CACHE_DIR")
      base = status.success? ? output.strip : ""
      base = "/tmp/ios-template-simulator-resources-#{Process.uid}" if base.empty?
      File.join(base, "ios-template-simulator-resources")
    end

    def ensure_secure_root
      FileUtils.mkdir_p(@root, mode: 0o700) unless File.exist?(@root)
      info = File.lstat(@root)
      unless info.directory? && !info.symlink? && info.uid == Process.uid
        raise SimulatorResourceError, "Simulator resource directory is unsafe"
      end
      File.chmod(0o700, @root)
      @root = File.realpath(@root)
      @legacy_state_path = File.join(@root, "state-v1.json")
      @legacy_lock_path = File.join(@root, "state-v1.lock")
      @state_path = File.join(@root, "dedicated-v1.json")
      @lock_path = File.join(@root, "dedicated-v1.lock")
    end

    def secure_open(path, flags, mode)
      if File.exist?(path)
        info = File.lstat(path)
        unless info.file? && !info.symlink? && info.uid == Process.uid && info.nlink == 1
          raise SimulatorResourceError, "Simulator resource lock is unsafe"
        end
      end
      File.open(path, flags | File::NOFOLLOW, mode)
    end

    def required(key)
      value = @options[key]
      raise SimulatorResourceError, "missing #{key}" unless value.is_a?(String) && !value.empty?
      value
    end

    def positive_integer(value, label)
      number = Integer(value, 10)
      raise SimulatorResourceError, "#{label} must be positive" unless number.positive?
      number
    rescue ArgumentError
      raise SimulatorResourceError, "#{label} must be an integer"
    end

    def nonnegative_integer(value, label)
      number = Integer(value, 10)
      raise SimulatorResourceError, "#{label} must be nonnegative" if number.negative?
      number
    rescue ArgumentError
      raise SimulatorResourceError, "#{label} must be an integer"
    end

    def validate!(pattern, value, label)
      raise SimulatorResourceError, "#{label} is invalid" unless value.is_a?(String) && pattern.match?(value)
    end

    def validate_identifier!(value, label)
      unless value.is_a?(String) && value.match?(/\Acom\.apple\.CoreSimulator\.(?:SimRuntime|SimDeviceType)\.[A-Za-z0-9_.-]+\z/)
        raise SimulatorResourceError, "#{label} identifier is invalid"
      end
    end

    def add_event(record, type, details = {})
      events = record.fetch("events")
      events << {"sequence" => events.length + 1, "type" => type, "at" => timestamp, "details" => details}
    end

    def timestamp
      Time.now.utc.iso8601(6)
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def snapshot_record(record)
      seal_record!(record)
      deep_copy(record)
    end

    def seal_record!(record)
      record["integrityDigest"] = record_integrity_digest(record)
    end

    def record_integrity_digest(record)
      material = record.reject { |key, _value| key == "integrityDigest" }
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical_value(material)))}"
    end

    def canonical_value(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) { |key, result| result[key] = canonical_value(value.fetch(key)) }
      when Array
        value.map { |entry| canonical_value(entry) }
      else
        value
      end
    end
  end

  module SimulatorResourceCLI
    module_function

    def parse(arguments)
      command = arguments.shift
      raise SimulatorResourceError, usage unless %w[allocate release validate inventory recover].include?(command)
      options = {}
      until arguments.empty?
        key = arguments.shift
        raise SimulatorResourceError, usage unless key&.start_with?("--") && !options.key?(key)
        if key == "--test-mode" || key == "--dry-run"
          options[key] = "true"
        else
          value = arguments.shift
          raise SimulatorResourceError, usage unless value && !value.empty?
          options[key] = value
        end
      end
      [command, options]
    end

    def usage
      "usage: ios-simulator-resource.rb allocate|release|validate|inventory|recover [options]"
    end

    def run(arguments)
      command, options = parse(arguments)
      manager = SimulatorResourceManager.new(options)
      case command
      when "allocate" then manager.allocate
      when "release" then manager.release
      when "validate" then manager.validate
      when "inventory" then manager.inventory(dry_run: true)
      when "recover" then manager.inventory(dry_run: options["--dry-run"] == "true")
      end
    end
  end
end

begin
  IOSTemplate::SimulatorResourceCLI.run(ARGV.dup)
rescue IOSTemplate::SimulatorResourceError => error
  warn error.message
  exit 1
end
