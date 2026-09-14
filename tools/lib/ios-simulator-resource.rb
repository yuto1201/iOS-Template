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

  class SimulatorResourceManager
    SCHEMA_VERSION = 1
    MAX_ALLOCATIONS = 4
    DEFAULT_MINIMUM_FREE_BYTES = 8 * 1024 * 1024 * 1024
    ACTIVE_STATUSES = %w[reserved active deleting cleanup-failed].freeze
    SESSION_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/
    BATCH_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9-]{0,63}\z/
    CASE_PATTERN = /\A(?:iphone|ipad)-(?:en|ja)\z/
    ATTEMPT_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/
    SHA_PATTERN = /\A[0-9a-f]{40}\z/
    UDID_PATTERN = /\A[0-9A-Fa-f-]{8,64}\z/
    DEVICE_NAME_PATTERN = /\AiOS-Template-[A-Za-z0-9-]{1,64}-(?:iphone|ipad)-(?:en|ja)-[0-9a-f]{12}\z/
    DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/
    RECORD_KEYS = %w[
      allocationId allocator attemptId batchId caseId cleanup createdAt dataPath deviceName deviceSet
      deviceTypeIdentifier events freeSpace headSha integrityDigest issue owner releasedAt repository
      reservedAt runtimeIdentifier schemaVersion sessionId status udid
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
        with_state do |state|
          recover_stale!(state, dry_run: false)
          existing = state.fetch("allocations").find do |record|
            ACTIVE_STATUSES.include?(record["status"]) && same_operation?(record, identity)
          end
          if existing
            if existing["status"] == "active" && process_active?(existing)
              write_receipt(existing)
              print_receipt(existing)
              return
            end
            denial = "matching allocation is not safely reusable"
            next
          end

          active = state.fetch("allocations").select { |record| ACTIVE_STATUSES.include?(record["status"]) }
          unmanaged = unmanaged_live_devices(active)
          unless unmanaged.empty?
            denial = "unmanaged iOS-Template Simulator use must be resolved before creating another device"
            next
          end
          if active.any? { |record| record["sessionId"] == identity.fetch("sessionId") }
            denial = "same session already owns a Simulator allocation"
            next
          end
          if active.length >= MAX_ALLOCATIONS
            denial = "Mac-wide iPhone/iPad Simulator allocation limit (#{MAX_ALLOCATIONS}) is in use"
            next
          end

          free_before = available_bytes
          if free_before < minimum_free
            denial = "insufficient free space for a new Simulator (available=#{free_before}, required=#{minimum_free})"
            next
          end

          allocation_id = SecureRandom.uuid.downcase
          short_id = allocation_id.delete("-")[0, 12]
          record = identity.merge(
            "schemaVersion" => SCHEMA_VERSION,
            "allocationId" => allocation_id,
            "allocator" => process_identity(Process.pid),
            "status" => "reserved",
            "deviceSet" => "default",
            "deviceName" => "iOS-Template-#{identity.fetch("batchId")}-#{identity.fetch("caseId")}-#{short_id}",
            "udid" => nil,
            "dataPath" => nil,
            "reservedAt" => timestamp,
            "createdAt" => nil,
            "releasedAt" => nil,
            "freeSpace" => {"beforeCreateBytes" => free_before, "afterDeleteBytes" => nil},
            "cleanup" => nil,
            "events" => []
          )
          add_event(record, "reserved", "capacityCount" => active.length + 1)
          state.fetch("allocations") << record
          reservation = snapshot_record(record)
        end
        break if reservation
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise SimulatorResourceError, "blocked:environment: #{denial}; wait expired"
        end
        sleep 0.1
      end

      begin
        output = run_simctl("create", reservation.fetch("deviceName"),
                            reservation.fetch("deviceTypeIdentifier"), reservation.fetch("runtimeIdentifier"))
        udid = output.strip
        raise SimulatorResourceError, "simctl create returned an invalid UDID" unless UDID_PATTERN.match?(udid)
        record = nil
        with_state do |state|
          current = find_record!(state, reservation.fetch("allocationId"))
          ensure_record_identity!(current, identity)
          raise SimulatorResourceError, "allocation reservation changed before creation completed" unless current["status"] == "reserved"
          live = unique_live_device!(current, udid: udid)
          current["udid"] = udid
          current["dataPath"] = safe_data_path(live["dataPath"], udid)
          current["status"] = "active"
          current["createdAt"] = timestamp
          add_event(current, "created", "udid" => udid)
          record = snapshot_record(current)
        end
        write_receipt(record)
        print_receipt(record)
      rescue StandardError => error
        cleanup_error = nil
        begin
          with_state do |state|
            current = find_record!(state, reservation.fetch("allocationId"))
            adopt_reserved_device!(current)
            cleanup_record!(current, dry_run: false, reason: "create-failure")
          end
        rescue StandardError => cleanup_failure
          cleanup_error = cleanup_failure.message
        end
        message = "blocked:environment: Simulator creation failed: #{error.message}"
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
      with_state do |state|
        current = find_record!(state, allocation_id)
        raise SimulatorResourceError, "allocation belongs to another session" unless current["sessionId"] == session_id
        if current["status"] == "released"
          record = snapshot_record(current)
          next
        end
        raise SimulatorResourceError, "allocation is not releasable" unless ACTIVE_STATUSES.include?(current["status"])
        begin
          cleanup_record!(current, dry_run: false, reason: required("--reason"))
        rescue SimulatorResourceError => error
          current["cleanup"] = {"status" => "failed", "reason" => error.message, "observedAt" => timestamp}
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
      with_state(write: false) do |state|
        record = find_record!(state, allocation_id)
        raise SimulatorResourceError, "allocation belongs to another session" unless record["sessionId"] == session_id
        raise SimulatorResourceError, "allocation is not active" unless record["status"] == "active"
        live = unique_live_device!(record, udid: record.fetch("udid"))
        if expected_state && live["state"] != expected_state
          raise SimulatorResourceError, "target Simulator state does not match the required state"
        end
        output = live.fetch("state")
      end
      puts output
    end

    def inventory(dry_run: true)
      result = nil
      with_state(write: !dry_run) do |state|
        candidates = recover_stale!(state, dry_run: dry_run)
        active = state.fetch("allocations").select { |record| ACTIVE_STATUSES.include?(record["status"]) }
        result = {
          "schemaVersion" => SCHEMA_VERSION,
          "dryRun" => dry_run,
          "observedAt" => timestamp,
          "limit" => MAX_ALLOCATIONS,
          "activeCount" => active.length,
          "availableBytes" => available_bytes,
          "allocations" => state.fetch("allocations").map { |record| inventory_record(record) },
          "protectedUnmanagedDevices" => unmanaged_live_devices(active).map { |device| unmanaged_inventory_record(device) },
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
      repository_identity = repository_identity(repository)
      {
        "sessionId" => session_id,
        "repository" => {"root" => repository, "identity" => repository_identity},
        "issue" => issue,
        "headSha" => head_sha,
        "batchId" => batch_id,
        "attemptId" => attempt_id,
        "caseId" => case_id,
        "owner" => {"pid" => owner_pid, "startToken" => owner_start},
        "runtimeIdentifier" => runtime,
        "deviceTypeIdentifier" => device_type
      }
    end

    def same_operation?(record, identity)
      %w[sessionId issue headSha batchId attemptId caseId runtimeIdentifier deviceTypeIdentifier].all? do |key|
        record[key] == identity[key]
      end && record["repository"] == identity["repository"] && record["owner"] == identity["owner"]
    end

    def ensure_record_identity!(record, identity)
      raise SimulatorResourceError, "allocation identity changed" unless same_operation?(record, identity)
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

    def recover_stale!(state, dry_run:)
      candidates = []
      state.fetch("allocations").each do |record|
        next unless ACTIVE_STATUSES.include?(record["status"])
        next if process_active?(record)
        candidate = {
          "allocationId" => record["allocationId"],
          "udid" => record["udid"],
          "sessionId" => record["sessionId"],
          "repositoryIdentity" => record.dig("repository", "identity"),
          "status" => record["status"],
          "reason" => "owner-process-identity-is-not-active"
        }
        candidates << candidate
        next if dry_run
        adopt_reserved_device!(record)
        cleanup_record!(record, dry_run: false, reason: "orphan-recovery")
      rescue SimulatorResourceError => error
        record["status"] = "cleanup-failed"
        record["cleanup"] = {"status" => "failed", "reason" => error.message, "observedAt" => timestamp}
        add_event(record, "cleanup-failed", "reason" => error.message)
      end
      candidates
    end

    def adopt_reserved_device!(record)
      return if record["udid"]
      matches = live_devices.select do |device|
        device["name"] == record["deviceName"] &&
          device["runtimeIdentifier"] == record["runtimeIdentifier"] &&
          device["deviceTypeIdentifier"] == record["deviceTypeIdentifier"]
      end
      if matches.empty?
        record["status"] = "released"
        record["releasedAt"] = timestamp
        record["cleanup"] = {"status" => "passed", "reason" => "reservation-had-no-device", "observedAt" => timestamp}
        add_event(record, "released", "reason" => "reservation-had-no-device")
        return
      end
      raise SimulatorResourceError, "reserved allocation device identity is ambiguous" unless matches.length == 1
      device = matches.first
      udid = device["udid"]
      raise SimulatorResourceError, "reserved allocation candidate has an invalid UDID" unless UDID_PATTERN.match?(udid.to_s)
      record["udid"] = udid
      record["dataPath"] = safe_data_path(device["dataPath"], udid)
      add_event(record, "adopted-after-interruption", "udid" => udid)
    end

    def cleanup_record!(record, dry_run:, reason:)
      if record["status"] == "released"
        return
      end
      udid = record["udid"]
      unless udid
        record["status"] = "released"
        record["releasedAt"] = timestamp
        record["cleanup"] = {"status" => "passed", "reason" => "no-device-created", "observedAt" => timestamp}
        add_event(record, "released", "reason" => "no-device-created")
        return
      end
      live_matches = live_devices.select { |device| device["udid"] == udid }
      if live_matches.empty?
        finish_release!(record, reason: "already-absent") unless dry_run
        return
      end
      raise SimulatorResourceError, "owned Simulator UDID is ambiguous" unless live_matches.length == 1
      live = live_matches.first
      unless live["name"] == record["deviceName"] &&
             live["runtimeIdentifier"] == record["runtimeIdentifier"] &&
             live["deviceTypeIdentifier"] == record["deviceTypeIdentifier"]
        raise SimulatorResourceError, "owned Simulator live identity does not match its durable allocation"
      end
      return if dry_run
      state = live["state"]
      if state == "Booted"
        run_simctl("shutdown", udid)
      elsif state != "Shutdown"
        raise SimulatorResourceError, "owned Simulator is in an unsafe state for deletion"
      end
      record["status"] = "deleting"
      add_event(record, "deleting", "reason" => reason)
      run_simctl("delete", udid)
      remaining = live_devices.select { |device| device["udid"] == udid }
      raise SimulatorResourceError, "simctl delete returned but the owned Simulator is still listed" unless remaining.empty?
      data_path = record["dataPath"]
      if data_path && File.exist?(data_path)
        raise SimulatorResourceError, "owned Simulator data path remains after simctl delete"
      end
      finish_release!(record, reason: reason)
    rescue SimulatorResourceError
      record["status"] = "cleanup-failed"
      raise
    end

    def finish_release!(record, reason:)
      free_after = available_bytes
      record["status"] = "released"
      record["releasedAt"] = timestamp
      record.fetch("freeSpace")["afterDeleteBytes"] = free_after
      record["cleanup"] = {
        "status" => "passed", "reason" => reason, "deviceAbsent" => true,
        "dataPathAbsent" => record["dataPath"].nil? || !File.exist?(record["dataPath"]),
        "observedAt" => timestamp
      }
      add_event(record, "released", "reason" => reason)
    end

    def unique_live_device!(record, udid:)
      matches = live_devices.select { |device| device["udid"] == udid }
      raise SimulatorResourceError, "created Simulator UDID is missing or ambiguous" unless matches.length == 1
      live = matches.first
      unless live["name"] == record["deviceName"] &&
             live["runtimeIdentifier"] == record["runtimeIdentifier"] &&
             live["deviceTypeIdentifier"] == record["deviceTypeIdentifier"]
        raise SimulatorResourceError, "created Simulator does not match the durable allocation"
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

    def with_state(write: true)
      lock = secure_open(@lock_path, File::RDWR | File::CREAT, 0o600)
      begin
        raise SimulatorResourceError, "unable to lock Simulator resource state" unless lock.flock(File::LOCK_EX)
        state = read_state
        validate_state!(state)
        begin
          result = yield state
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
    end

    def read_state
      return {"schemaVersion" => SCHEMA_VERSION, "allocations" => []} unless File.exist?(@state_path)
      info = File.lstat(@state_path)
      unless info.file? && !info.symlink? && info.uid == Process.uid && info.nlink == 1
        raise SimulatorResourceError, "Simulator resource state file is unsafe"
      end
      JSON.parse(File.binread(@state_path, 16 * 1024 * 1024))
    rescue JSON::ParserError => error
      raise SimulatorResourceError, "Simulator resource state is invalid: #{error.message}"
    end

    def validate_state!(state)
      unless state.is_a?(Hash) && state.keys.sort == %w[allocations schemaVersion] &&
             state["schemaVersion"] == SCHEMA_VERSION && state["allocations"].is_a?(Array)
        raise SimulatorResourceError, "Simulator resource state schema is invalid"
      end
      ids = state.fetch("allocations").map do |record|
        validate_record!(record)
        record.fetch("allocationId")
      end
      raise SimulatorResourceError, "Simulator resource state has duplicate allocations" unless ids.uniq.length == ids.length
    end

    def validate_record!(record)
      raise SimulatorResourceError, "Simulator allocation record is invalid" unless record.is_a?(Hash)
      unless record.keys.sort == RECORD_KEYS.sort && record["integrityDigest"].to_s.match?(DIGEST_PATTERN)
        raise SimulatorResourceError, "Simulator allocation record schema is invalid"
      end
      unless record["integrityDigest"] == record_integrity_digest(record)
        raise SimulatorResourceError, "Simulator allocation record integrity is invalid"
      end
      validate!(SESSION_PATTERN, record["sessionId"], "record session")
      validate!(BATCH_PATTERN, record["batchId"], "record batch")
      validate!(CASE_PATTERN, record["caseId"], "record case")
      validate!(SHA_PATTERN, record["headSha"], "record Head")
      validate!(UDID_PATTERN, record["udid"], "record UDID") if record["udid"]
      validate!(DEVICE_NAME_PATTERN, record["deviceName"], "record device name")
      unless record["schemaVersion"] == SCHEMA_VERSION && record["allocationId"].is_a?(String) &&
             (ACTIVE_STATUSES.include?(record["status"]) || record["status"] == "released")
        raise SimulatorResourceError, "Simulator allocation status is invalid"
      end
      unless record["schemaVersion"] == SCHEMA_VERSION && record["allocationId"].is_a?(String) &&
             record["repository"].is_a?(Hash) && record["repository"].keys.sort == %w[identity root] &&
             record.dig("repository", "root").is_a?(String) &&
             record.dig("repository", "identity").to_s.match?(DIGEST_PATTERN) &&
             valid_process_identity?(record["owner"]) && valid_process_identity?(record["allocator"]) &&
             record["deviceSet"] == "default" && record["issue"].is_a?(Integer) && record["issue"].positive? &&
             record["events"].is_a?(Array) && record["freeSpace"].is_a?(Hash) &&
             record["freeSpace"].keys.sort == %w[afterDeleteBytes beforeCreateBytes] &&
             record.dig("freeSpace", "beforeCreateBytes").is_a?(Integer) &&
             (record.dig("freeSpace", "afterDeleteBytes").nil? || record.dig("freeSpace", "afterDeleteBytes").is_a?(Integer))
        raise SimulatorResourceError, "Simulator allocation identity is invalid"
      end
      validate_identifier!(record["runtimeIdentifier"], "record Runtime")
      validate_identifier!(record["deviceTypeIdentifier"], "record Device Type")
      if record["dataPath"] && safe_data_path(record["dataPath"], record["udid"]) != record["dataPath"]
        raise SimulatorResourceError, "Simulator allocation data path is invalid"
      end
    end

    def write_state(state)
      state.fetch("allocations").each { |record| seal_record!(record) }
      temporary = File.join(@root, ".state-#{SecureRandom.uuid}.json")
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
        raise SimulatorResourceError, "allocation receipt directory is unsafe"
      end
      File.chmod(0o700, path)
    end

    def find_record!(state, allocation_id)
      matches = state.fetch("allocations").select { |record| record["allocationId"] == allocation_id }
      raise SimulatorResourceError, "allocation ID is missing or ambiguous" unless matches.length == 1
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
        "caseId" => record["caseId"], "udid" => record["udid"],
        "deviceName" => record["deviceName"], "runtimeIdentifier" => record["runtimeIdentifier"],
        "deviceTypeIdentifier" => record["deviceTypeIdentifier"],
        "ownerActive" => process_identity_active?(record["owner"]),
        "allocatorActive" => process_identity_active?(record["allocator"]), "dataPath" => record["dataPath"],
        "dataBytes" => nil, "dataMeasurement" => "not-measured",
        "freeSpace" => record["freeSpace"], "cleanup" => record["cleanup"]
      }
    end

    def unmanaged_live_devices(active_records)
      live_devices.select do |device|
        next false unless device["name"].to_s.start_with?("iOS-Template-")
        !active_records.any? do |record|
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
        "runtimeIdentifier" => device["runtimeIdentifier"],
        "deviceTypeIdentifier" => device["deviceTypeIdentifier"],
        "dataPath" => device["dataPath"], "dataBytes" => nil,
        "dataMeasurement" => "not-measured", "protection" => "no-active-durable-allocation"
      }
    end

    def receipt_record(record)
      {
        "schemaVersion" => record["schemaVersion"], "allocationId" => record["allocationId"],
        "status" => record["status"], "sessionId" => record["sessionId"],
        "repositoryIdentity" => record.dig("repository", "identity"), "issue" => record["issue"],
        "headSha" => record["headSha"], "batchId" => record["batchId"],
        "attemptId" => record["attemptId"], "caseId" => record["caseId"],
        "deviceSet" => record["deviceSet"], "deviceName" => record["deviceName"],
        "udid" => record["udid"], "runtimeIdentifier" => record["runtimeIdentifier"],
        "deviceTypeIdentifier" => record["deviceTypeIdentifier"],
        "reservedAt" => record["reservedAt"], "createdAt" => record["createdAt"],
        "releasedAt" => record["releasedAt"], "freeSpace" => record["freeSpace"],
        "cleanup" => record["cleanup"]
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
      @state_path = File.join(@root, "state-v1.json")
      @lock_path = File.join(@root, "state-v1.lock")
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

    def safe_data_path(value, udid)
      return nil if value.nil?
      unless value.is_a?(String) && value.start_with?("/") && udid && value.include?(udid)
        raise SimulatorResourceError, "Simulator data path does not match its exact UDID"
      end
      value
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
      unless value.match?(/\Acom\.apple\.CoreSimulator\.(?:SimRuntime|SimDeviceType)\.[A-Za-z0-9_.-]+\z/)
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
