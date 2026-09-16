# frozen_string_literal: true

require "json"
require "yaml"
require "digest"
require "open3"
require "optparse"
require "time"
require_relative "descriptor-files"
require_relative "appstore-registration-preparation"
require_relative "appstore-xcode-facts"
require_relative "appstore-confirmation"
require_relative "appstore-code-inventory"
require_relative "appstore-public-evidence"
require_relative "appstore-account-evidence"
require_relative "appstore-readback-evidence"
require_relative "appstore-source-schema"
require_relative "appstore-asset-evidence"

module IOSTemplate
  module AppStorePreparation
    class InvalidInput < StandardError; end

    class UniqueObject < Hash
      def []=(key, value)
        raise InvalidInput, "duplicate-source-key" if key?(key)
        super
      end
    end

    # Keep descriptors until the complete report has been evaluated. Missing
    # sources are observations too: they may not appear unnoticed before output.
    class Sources
      MAX_BYTES = 2_000_000
      MAX_BINARY_BYTES = 64_000_000
      MAX_FILES = 2048
      MAX_TOTAL_BYTES = 32_000_000
      MAX_BUILD_INPUT_FILES = 20_000
      MAX_BUILD_INPUT_BYTES = 1_000_000_000
      MAX_BUILD_INPUT_FILE_BYTES = 512_000_000

      def initialize(root, shared_evidence: true, git_context: true)
        raise InvalidInput, "invalid-project-root" unless root.start_with?("/") && File.realpath(root) == root
        @path = root
        @root = DescriptorFiles.open_directory(root)
        @directories = {"" => @root}
        @files = {}
        @missing = []
        @errors = {}
        @listings = {}
        @current_path_checks = []
        @total_bytes = 0
        @binary_bytes = 0
        @git_context = git_context
        if @git_context
          output, status = Open3.capture2e("/usr/bin/git", "-C", root, "rev-parse", "--verify", "HEAD")
          @revision = status.success? && output.strip.match?(/\A[0-9a-f]{40}\z/) ? output.strip : nil
          @repository = resolve_repository
        end
        if shared_evidence && File.symlink?(File.join(root, ".artifacts"))
          @artifact_topology = resolve_artifact_topology
          @shared_evidence = Sources.new(@artifact_topology.fetch("artifactsRoot"), shared_evidence: false, git_context: false)
        end
      end

      attr_reader :revision, :repository

      def resolve_repository
        output, status = Open3.capture2e("/usr/bin/git", "-C", @path, "config", "--get", "remote.origin.url")
        return nil unless status.success?
        match = output.strip.match(%r{\A(?:https://github\.com/|git@github\.com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?\z})
        match && match[1]
      end

      def resolve_artifact_topology
        output, _, status = Open3.capture3("/usr/bin/ruby", "--disable-gems", File.join(__dir__, "review-artifacts.rb"), @path)
        raise InvalidInput, "invalid-shared-evidence-layout" unless status.success?
        topology = JSON.parse(output)
        raise InvalidInput, "invalid-shared-evidence-layout" unless topology["layout"] == "linked" && topology["repositoryRoot"] == @path
        topology
      rescue JSON::ParserError
        raise InvalidInput, "invalid-shared-evidence-layout"
      end

      def shared_path(path)
        return nil unless @shared_evidence && path.start_with?(".artifacts/appstore-preparation/")
        path.delete_prefix(".artifacts/")
      end

      def path!(relative)
        raise InvalidInput, "unsafe-source-path" unless relative.is_a?(String) &&
          relative.bytesize.between?(1, 512) && !relative.match?(/[\x00-\x1f\x7f\\]/) &&
          !relative.start_with?("/") && relative.split("/", -1).none? do |part|
            part.empty? || part == "." || part == ".." || part.casecmp?(".git")
          end
        relative
      end

      def directory(relative)
        return @directories.fetch(relative) if @directories.key?(relative)
        parent = File.dirname(relative)
        parent = "" if parent == "."
        fd = DescriptorFiles::OPENAT.call(directory(parent).fileno, File.basename(relative), File::RDONLY | File::NOFOLLOW | File::NONBLOCK, 0)
        DescriptorFiles.system_error!("source directory") if fd.negative?
        io = File.for_fd(fd, autoclose: true)
        raise IOError, "unsafe source directory" unless io.stat.directory?
        @directories[relative] = io
      rescue StandardError
        io&.close unless io&.closed?
        raise
      end

      def read(relative, binary: false)
        path!(relative)
        delegated = shared_path(relative)
        return @shared_evidence.read(delegated, binary: binary) if delegated
        return nil if @errors.key?(relative)
        if @files.key?(relative)
          entry = @files.fetch(relative)
          return nil if entry[:binary] && !binary
          return entry.fetch(:bytes)
        end
        raise InvalidInput, "source-inventory-limit" if @files.length >= MAX_FILES
        parent = File.dirname(relative)
        parent = "" if parent == "."
        owner = directory(parent)
        fd = DescriptorFiles::OPENAT.call(owner.fileno, File.basename(relative), File::RDONLY | File::NOFOLLOW | File::NONBLOCK, 0)
        DescriptorFiles.system_error!("source open") if fd.negative?
        io = File.for_fd(fd, autoclose: true)
        stat = io.stat
        limit = binary ? MAX_BINARY_BYTES : MAX_BYTES
        raise InvalidInput, "unsafe-source-file" unless stat.file? && stat.nlink == 1 && stat.size <= limit
        io.binmode
        bytes = io.read(limit + 1)
        raise InvalidInput, "source-changed" unless bytes.bytesize <= limit &&
          bytes.bytesize == stat.size && DescriptorFiles.metadata_equal?(stat, io.stat)
        raise InvalidInput, "source-byte-budget" if binary ? @binary_bytes + bytes.bytesize > 128_000_000 : @total_bytes + bytes.bytesize > MAX_TOTAL_BYTES
        text = binary ? bytes : bytes.dup.force_encoding(Encoding::UTF_8)
        raise InvalidInput, "invalid-source-encoding" unless binary || (text.valid_encoding? && !text.include?("\0"))
        @files[relative] = {io: io, stat: stat, bytes: text, binary: binary, parent: owner, name: File.basename(relative), revision: nil}
        binary ? @binary_bytes += bytes.bytesize : @total_bytes += bytes.bytesize
        @errors[relative] = "sensitive-source" if !binary && (sensitive?(text) || sensitive_private_text?(relative, text))
        @files[relative][:revision] = committed_revision(relative, bytes) unless @errors.key?(relative)
        @errors.key?(relative) ? nil : text
      rescue Errno::ENOENT, Errno::ENOTDIR
        io&.close unless io&.closed?
        @missing << relative
        @errors[relative] = "missing-source"
        nil
      rescue SystemCallError, IOError, InvalidInput
        io&.close unless io&.closed? || @files.key?(relative)
        @errors[relative] = "unsafe-source"
        nil
      end

      def sensitive?(bytes)
        keys = /(password|api[_ -]?key|access[_ -]?token|secret|cookie|authorization|session|credentials?Reference|reviewContactReference|reviewContactEmail|reviewContactPhone|contactEmail|contactPhone)["']?\s*[:=]\s*(?:"([^"]*)"|'([^']*)'|([^\s,}\]]+))/i
        bytes.scan(keys).any? do |parts|
          key = parts.shift.to_s.gsub(/[^a-zA-Z]/, "").downcase
          value = parts.compact.first.to_s
          reference = %w[credentialreference credentialsreference reviewcontactreference].include?(key)
          if value.match?(%r{\Akeychain://[a-zA-Z0-9/_-]+\z})
            false
          elsif reference
            !value.empty? && !%w[none null].include?(value.downcase)
          else
            !value.empty?
          end
        end || bytes.match?(/-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----|\bBearer\s+[A-Za-z0-9._-]+/)
      end

      # Review-only Markdown is allowed to describe deterministic steps, but it
      # must not become a reusable public digest for contact or demo-account
      # values. Keep this path-aware so public legal/support copy can still
      # contain intentionally published contact details.
      def sensitive_private_text?(relative, bytes)
        return false unless relative.start_with?("App Store/review/")
        return true if bytes.match?(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i)
        return true if bytes.match?(/\+\d[\d .()\-]{6,}\d/)
        return true if bytes.match?(/(?<![A-Za-z0-9])0\d{9,10}(?![A-Za-z0-9])/)
        return true if bytes.match?(/(?<!\d)\(?0\d{1,4}\)?(?:[ .-]\d{1,4}){1,3}(?!\d)/)

        private_label = /(?:demo\s+)?(?:user(?:\s*name)?|login|account\s+name|email|phone|first\s+name|last\s+name|session|credential|token)|(?:review\s+)?contact\s+(?:email|phone)/i
        bytes.each_line.any? do |line|
          line.match?(/\A\s*(?:[-*]\s*)?#{private_label}\s*[:=]\s*\S+/) ||
            line.match?(/\|\s*#{private_label}\s*\|\s*\S[^|]*\|/)
        end
      end

      def committed_revision(relative, bytes)
        return nil unless @revision
        output, status = Open3.capture2e(
          {"GIT_OPTIONAL_LOCKS" => "0", "GIT_NO_REPLACE_OBJECTS" => "1", "GIT_NO_LAZY_FETCH" => "1"},
          "/usr/bin/git", "--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", @path,
          "--literal-pathspecs", "ls-tree", "-z", @revision, "--", relative
        )
        return nil unless status.success?
        expected_blob = Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0".b + bytes.b)
        # An untracked or edited draft has a digest, but is not attributed to
        # HEAD merely because it happens to live inside that checkout.
        output == "100644 blob #{expected_blob}\t#{relative}\0" ||
          output == "100755 blob #{expected_blob}\t#{relative}\0" ? @revision : nil
      end

      def head_build_entries(checked)
        output, status = Open3.capture2e(
          {"GIT_OPTIONAL_LOCKS" => "0", "GIT_NO_REPLACE_OBJECTS" => "1", "GIT_NO_LAZY_FETCH" => "1"},
          "/usr/bin/git", "--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", @path,
          "--literal-pathspecs", "ls-tree", "-r", "-z", "--full-tree", @revision, "--", *checked
        )
        return nil unless status.success? && output.bytesize <= 16_000_000
        entries = {}
        output.b.split("\0".b, -1).tap { |parts| return nil unless parts.pop == "" }.each do |record|
          match = record.match(/\A(100644|100755|120000|160000) (blob|commit) ([0-9a-f]{40})\t(.+)\z/m)
          return nil unless match
          relative = match[4].dup.force_encoding(Encoding::UTF_8)
          return nil unless relative.valid_encoding?
          path!(relative)
          return nil unless checked.any? { |root| relative == root || relative.start_with?("#{root}/") }
          return nil if entries.key?(relative)
          entries[relative] = [match[1], match[3]]
        end
        entries
      rescue InvalidInput
        nil
      end

      def raw_build_blob(path, budget)
        parent = File.dirname(path)
        parent = "" if parent == "."
        owner = directory(parent)
        fd = DescriptorFiles::OPENAT.call(owner.fileno, File.basename(path), File::RDONLY | File::NOFOLLOW | File::NONBLOCK, 0)
        DescriptorFiles.system_error!("build input open") if fd.negative?
        io = File.for_fd(fd, autoclose: true)
        io.binmode
        opened = io.stat
        return nil unless opened.file? && opened.nlink == 1
        return nil unless opened.size <= MAX_BUILD_INPUT_FILE_BYTES && budget[0] + opened.size <= MAX_BUILD_INPUT_BYTES
        digest = Digest::SHA1.new
        digest.update("blob #{opened.size}\0".b)
        bytes_read = 0
        while (chunk = io.read(1_048_576))
          bytes_read += chunk.bytesize
          return nil if bytes_read > opened.size
          digest.update(chunk)
        end
        return nil unless bytes_read == opened.size && DescriptorFiles.metadata_equal?(opened, io.stat)
        budget[0] += bytes_read
        mode = opened.mode & 0o111 == 0 ? "100644" : "100755"
        [mode, digest.hexdigest]
      rescue SystemCallError, IOError
        nil
      ensure
        io&.close unless io&.closed?
      end

      def collect_build_entries(path, entries, budget, depth = 0)
        return false if depth > 64 || entries.length >= MAX_BUILD_INPUT_FILES
        type = kind(path)
        if type == "file"
          digest = raw_build_blob(path, budget)
          return false unless digest
          return entries[path] == digest if entries.key?(path)
          entries[path] = digest
          return true
        end
        children(path).each do |name|
          child = "#{path}/#{name}"
          return false unless collect_build_entries(child, entries, budget, depth + 1) == true
        end
        true
      rescue Errno::ENOENT, Errno::ENOTDIR
        :missing
      rescue SystemCallError, IOError, InvalidInput
        false
      end

      def current_path_state(checked)
        expected = head_build_entries(checked)
        return [false] unless expected
        index_output, index_status = Open3.capture2e(
          {"GIT_OPTIONAL_LOCKS" => "0", "GIT_NO_REPLACE_OBJECTS" => "1", "GIT_NO_LAZY_FETCH" => "1"},
          "/usr/bin/git", "--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", @path,
          "--literal-pathspecs", "diff-index", "--cached", "--raw", "-z", "--no-renames", "--no-ext-diff", "--no-textconv",
          @revision, "--", *checked
        )
        return [false] unless index_status.success? && index_output.bytesize <= 16_000_000
        actual = {}
        budget = [0]
        checked.each do |path|
          begin
            present = collect_build_entries(path, actual, budget)
            return [false] unless present == true || present == :missing
          rescue Errno::ENOENT, Errno::ENOTDIR
            next
          end
        end
        [true, expected.sort, actual.sort, index_output]
      end

      def committed_paths_current?(paths)
        return false unless @revision
        checked = paths.compact.uniq
        return false if checked.empty?
        checked.each { |path| path!(path) }
        checked = checked.sort_by { |path| [path.count("/"), path] }.reject do |path|
          checked.any? { |parent| parent != path && (path == parent || path.start_with?("#{parent}/")) }
        end
        state = current_path_state(checked)
        @current_path_checks << [checked, state]
        state[0] && state[1] == state[2] && state[3].empty?
      end

      # A dirty build tree is acceptable only when every changed input was
      # explicitly inspected and therefore participates in field fingerprints.
      # Unseen binary/folder additions remain fail-closed without requiring an
      # otherwise unrelated clean checkout.
      def build_inputs_bound?(paths, bound_paths)
        return false unless @revision
        checked = paths.compact.uniq
        return false if checked.empty?
        checked.each { |path| path!(path) }
        checked = checked.sort_by { |path| [path.count("/"), path] }.reject do |path|
          checked.any? { |parent| parent != path && path.start_with?("#{parent}/") }
        end
        state = current_path_state(checked)
        return false unless state[0]
        expected = state[1].to_h
        actual = state[2].to_h
        changed = (expected.keys | actual.keys).select { |path| expected[path] != actual[path] }
        bound = bound_paths.compact.each_with_object({}) { |path, output| output[path] = true }
        changed.all? { |path| bound[path] }
      rescue InvalidInput
        false
      end

      def package_scm_paths(value)
        return [] unless value.is_a?(Hash) && [1, 2, 3].include?(value["version"])
        if value["version"] == 1
          pins = value.dig("object", "pins")
          prefix = ["object", "pins"]
          location_key = "repositoryURL"
        else
          pins = value["pins"]
          prefix = ["pins"]
          location_key = "location"
        end
        return [] unless pins.is_a?(Array)

        pins.each_with_index.each_with_object([]) do |(pin, index), paths|
          location = pin.is_a?(Hash) && pin[location_key]
          identity = pin.is_a?(Hash) && (value["version"] == 1 ? pin["package"] : pin["identity"])
          state = pin.is_a?(Hash) && pin["state"]
          normalized = RemotePackageReference.parse(location)
          kind_valid = value["version"] == 1 || pin["kind"] == "remoteSourceControl"
          canonical = identity.is_a?(String) && identity.match?(/\A[A-Za-z0-9._-]{1,128}\z/) && normalized &&
            normalized["identity"] == identity.downcase && state.is_a?(Hash) &&
            state["revision"].is_a?(String) && state["revision"].match?(/\A[0-9a-f]{40}\z/) && kind_valid
          paths << prefix + [index, location_key] if canonical
        end
      end

      def sensitive_document?(value, context_path = [], allowed_scm_paths = [], allowed_plain_paths = [])
        case value
        when Hash
          value.any? do |key, child|
            normalized = key.to_s.gsub(/[^a-zA-Z]/, "").downcase
            child_path = context_path + [key.to_s]
            protected = %w[password demoaccountpassword demoaccountname apikey accesstoken secret cookie authorization session credentialreference credentialsreference reviewcontactreference reviewcontactemail reviewcontactphone contactemail contactphone phonenumber phone firstname lastname email username login loginid accountname userid].include?(normalized)
            reference = %w[credentialreference credentialsreference reviewcontactreference].include?(normalized)
            invalid = if !protected || child.nil? || allowed_plain_paths.include?(child_path)
                        false
                      elsif reference
                        child != "none" && !(child.is_a?(String) && child.match?(%r{\Akeychain://[a-zA-Z0-9/_-]+\z}))
                      else
                        !child.is_a?(String) || (!child.empty? && !child.match?(%r{\Akeychain://[a-zA-Z0-9/_-]+\z}))
                      end
            invalid || sensitive_document?(child, child_path, allowed_scm_paths, allowed_plain_paths)
          end
        when Array
          value.each_with_index.any? { |child, index| sensitive_document?(child, context_path + [index], allowed_scm_paths, allowed_plain_paths) }
        when String
          scm = allowed_scm_paths.include?(context_path) && RemotePackageReference.parse(value)
          private_contact = value.match?(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i) ||
            value.match?(/\+\d[\d .()\-]{6,}\d/) ||
            value.match?(/(?<![A-Za-z0-9])0\d{9,10}(?![A-Za-z0-9])/) ||
            value.match?(/(?<!\d)\(?0\d{1,4}\)?[ .-]\d{1,4}[ .-]\d{3,4}(?!\d)/)
          sensitive?(value) || (!scm && private_contact)
        else false
        end
      end

      def finite_document?(value)
        case value
        when Hash
          value.all? { |key, child| finite_document?(key) && finite_document?(child) }
        when Array
          value.all? { |child| finite_document?(child) }
        when Float
          value.finite?
        else
          true
        end
      end

      def sensitive_xcode_document?(value)
        allowed = []
        objects = value.is_a?(Hash) && value["objects"]
        project = objects.is_a?(Hash) && objects[value["rootObject"]]
        references = project.is_a?(Hash) && project["isa"] == "PBXProject" && project["packageReferences"]
        if references.is_a?(Array) && references.uniq == references
          references.each do |identifier|
            object = objects[identifier]
            if object.is_a?(Hash) && object["isa"] == "XCRemoteSwiftPackageReference" &&
                RemotePackageReference.parse(object["repositoryURL"])
              allowed << ["objects", identifier.to_s, "repositoryURL"]
            end
          end
        end
        sensitive_document?(value, [], allowed)
      end

      def descriptor(path, anchor)
        path!(path)
        delegated = shared_path(path)
        return @shared_evidence.descriptor(delegated, anchor).merge("path" => path) if delegated
        bytes = if path.end_with?(".json", ".yml", ".yaml", ".resolved")
                  document(path) ? @files.fetch(path).fetch(:bytes) : nil
                else
                  read(path)
                end
        {"path" => path, "anchor" => anchor, "revision" => bytes ? @files.fetch(path).fetch(:revision) : nil,
         "digest" => bytes ? "sha256:#{Digest::SHA256.hexdigest(bytes)}" : nil}
      end

      def binary_descriptor(path)
        path!(path)
        delegated = shared_path(path)
        return @shared_evidence.binary_descriptor(delegated).merge("path" => path) if delegated
        bytes = read(path, binary: true)
        {"path" => path, "anchor" => "document", "revision" => bytes ? @files.fetch(path)[:revision] : nil,
         "digest" => bytes ? "sha256:#{Digest::SHA256.hexdigest(bytes)}" : nil}
      end

      def error(path)
        path!(path)
        delegated = shared_path(path)
        return @shared_evidence.error(delegated) if delegated
        read(path)
        @errors[path]
      end

      def reject_sensitive(path)
        path!(path)
        delegated = shared_path(path)
        return @shared_evidence.reject_sensitive(delegated) if delegated
        @errors[path] = "sensitive-source"
      end

      def document(path)
        path!(path)
        delegated = shared_path(path)
        return @shared_evidence.document(delegated) if delegated
        bytes = read(path)
        return nil unless bytes
        if path.end_with?(".json", ".resolved")
          value = JSON.parse(bytes, object_class: UniqueObject)
        else
          # safe_load rejects object construction and aliases, but does not
          # reject duplicate keys. Inspect syntax before constructing values.
          syntax = Psych.parse_stream(bytes)
          pending = [[syntax, 0]]
          count = 0
          until pending.empty?
            node, depth = pending.pop
            count += 1
            raise InvalidInput, "source-structure-limit" if depth > 100 || count > 100_000
            if node.is_a?(Psych::Nodes::Mapping)
              keys = node.children.each_slice(2).map do |key, _|
                raise InvalidInput, "complex-source-key" unless key.is_a?(Psych::Nodes::Scalar)
                key.value
              end
              raise InvalidInput, "duplicate-source-key" unless keys.uniq == keys
            end
            (node.children || []).each { |child| pending << [child, depth + 1] }
          end
          raise InvalidInput, "multiple-source-documents" unless syntax.children.length == 1
          value = YAML.safe_load(bytes, permitted_classes: [], aliases: false)
        end
        unless value.is_a?(Hash) && finite_document?(value)
          @errors[path] = "invalid-source-schema"
          return nil
        end
        allowed_scm_paths = File.basename(path) == "Package.resolved" ? package_scm_paths(value) : []
        allowed_plain_paths = path == "Config/ownership.yml" ? [["github", "login"], ["cloudflare", "accountName"]] : []
        if sensitive_document?(value, [], allowed_scm_paths, allowed_plain_paths)
          @errors[path] = "sensitive-source"
          return nil
        end
        value
      rescue JSON::ParserError, Psych::Exception, InvalidInput
        @errors[path] = "invalid-source-schema"
        nil
      end

      def directory_names(relative)
        path!(relative) unless relative.empty?
        owner = directory(relative)
        names = nil
        Dir.open(File.join(@path, relative)) do |directory_stream|
          observed = IO.for_fd(directory_stream.fileno, autoclose: false).stat
          raise InvalidInput, "source-directory-changed" unless observed.dev == owner.stat.dev && observed.ino == owner.stat.ino
          names = []
          directory_stream.each do |name|
            next if name == "." || name == ".."
            path!(relative.empty? ? name : "#{relative}/#{name}")
            names << name
            raise InvalidInput, "source-directory-limit" if names.length > 8192
          end
        end
        names.sort
      end

      def children(relative)
        names = directory_names(relative)
        raise InvalidInput, "source-inventory-changed" if @listings.key?(relative) && @listings[relative] != names
        @listings[relative] = names
      end

      def kind(relative)
        path!(relative)
        parent = File.dirname(relative)
        parent = "" if parent == "."
        fd = DescriptorFiles::OPENAT.call(directory(parent).fileno, File.basename(relative), File::RDONLY | File::NOFOLLOW | File::NONBLOCK, 0)
        DescriptorFiles.system_error!("inventory entry") if fd.negative?
        io = File.for_fd(fd, autoclose: true)
        stat = io.stat
        return "directory" if stat.directory?
        return "file" if stat.file? && stat.nlink == 1
        raise InvalidInput, "unsafe-inventory-entry"
      ensure
        io&.close unless io&.closed?
      end

      def verify!
        stat = File.lstat(@path)
        raise InvalidInput, "project-changed" unless stat.directory? && !stat.symlink? && stat.dev == @root.stat.dev && stat.ino == @root.stat.ino
        @directories.each do |relative, io|
          current = File.lstat(File.join(@path, relative))
          raise InvalidInput, "source-directory-changed" unless current.directory? && !current.symlink? && current.dev == io.stat.dev && current.ino == io.stat.ino
        end
        @files.each_value do |entry|
          io = entry.fetch(:io)
          io.rewind
          raise InvalidInput, "source-changed" unless io.read(entry.fetch(:bytes).bytesize + 1) == entry.fetch(:bytes).b && DescriptorFiles.metadata_equal?(entry.fetch(:stat), io.stat)
          fd = DescriptorFiles::OPENAT.call(entry.fetch(:parent).fileno, entry.fetch(:name), File::RDONLY | File::NOFOLLOW | File::NONBLOCK, 0)
          DescriptorFiles.system_error!("source verification") if fd.negative?
          current = File.for_fd(fd, autoclose: true)
          begin
            raise InvalidInput, "source-changed" unless DescriptorFiles.metadata_equal?(entry.fetch(:stat), current.stat)
          ensure
            current.close
          end
        end
        @missing.each do |relative|
          raise InvalidInput, "source-appeared" if File.exist?(File.join(@path, relative)) || File.symlink?(File.join(@path, relative))
        end
        @listings.each do |relative, names|
          raise InvalidInput, "source-inventory-changed" unless directory_names(relative) == names
        end
        if @git_context
          output, status = Open3.capture2e("/usr/bin/git", "-C", @path, "rev-parse", "--verify", "HEAD")
          current_revision = status.success? && output.strip.match?(/\A[0-9a-f]{40}\z/) ? output.strip : nil
          raise InvalidInput, "source-revision-changed" unless current_revision == @revision
          raise InvalidInput, "source-repository-changed" unless resolve_repository == @repository
          @current_path_checks.each do |checked, state|
            raise InvalidInput, "build-input-state-changed" unless current_path_state(checked) == state
          end
        end
        if @shared_evidence
          @shared_evidence.verify!
          raise InvalidInput, "shared-evidence-layout-changed" unless resolve_artifact_topology == @artifact_topology
        end
      end

      def close
        @shared_evidence&.close
        @files.each_value { |entry| entry.fetch(:io).close unless entry.fetch(:io).closed? }
        @directories.values.reverse_each { |io| io.close unless io.closed? }
      end
    end

    APP = "App Store/metadata/app.yml"
    VALUES = "App Store/metadata/preparation.json"
    IDENTITY = "Config/app-identity.json"
    TEMPLATE_IDENTITY = "Config/template-identity.json"
    PRIVACY = "App Store/privacy/data-use.yml"
    OWNERSHIP = "Config/ownership.yml"
    LOCALIZED_FIELDS = %w[name subtitle description keywords promotionalText releaseNotes screenshots.iphone screenshots.ipad supportURL privacyPolicyURL marketingURL].freeze
    TEMPLATE_TEXT_VALUES = {
      ["name", "en-US"] => "Template App",
      ["subtitle", "en-US"] => "Replace before submission",
      ["description", "en-US"] => "Draft product-page copy. Replace this text with a truthful description of the app's implemented features before submission.",
      ["keywords", "en-US"] => "template,utility",
      ["promotionalText", "en-US"] => "Draft promotional text.",
      ["releaseNotes", "en-US"] => "# Release notes — 1.0\n\nDraft. Replace with concise notes about user-visible changes in the submitted build.",
      ["name", "ja"] => "テンプレートアプリ",
      ["subtitle", "ja"] => "提出前に置き換えてください",
      ["description", "ja"] => "プロダクトページ用の下書きです。提出前に、実装済み機能の実態に沿った説明へ置き換えてください。",
      ["keywords", "ja"] => "テンプレート,ユーティリティ",
      ["promotionalText", "ja"] => "プロモーション文の下書きです。",
      ["releaseNotes", "ja"] => "# リリースノート — 1.0\n\n下書きです。提出ビルドでユーザーに見える変更を簡潔に記載してください。",
      ["copyright", nil] => "Draft — replace for the app release",
      ["reviewNotes", nil] => "# App Review notes\n\nStatus: Draft\n\nDescribe only implemented behavior, deterministic review steps, and required hardware or account conditions. Store any review account in Keychain and put only its service reference here. The untouched template needs no review account.",
      ["supportURL", "en-US"] => "https://support.example.invalid/template-app",
      ["supportURL", "ja"] => "https://support.example.invalid/template-app",
      ["privacyPolicyURL", "en-US"] => "https://support.example.invalid/template-app/privacy",
      ["privacyPolicyURL", "ja"] => "https://support.example.invalid/template-app/privacy"
    }.freeze
    TEMPLATE_TEXT_SENTINELS = {
      ["legal.privacyPolicy", nil] => [
        "This file must be regenerated from `App Store/privacy/data-use.yml` and the actual release build.",
        "It must not be published until the user confirms the first-publication legal and privacy claims."
      ],
      ["legal.termsOfUse", nil] => [
        "This is a source placeholder, not legal advice or a publishable agreement.",
        "then obtain the user's first-publication confirmation."
      ]
    }.freeze

    # Each entry identifies one ASC field (or one internal identity check).
    # Classification and dependencies are policy, not supplied success flags.
    SHARED_FIELDS = [
      ["identity.displayName", IDENTITY, "displayName", %w[derive], "identity"],
      ["identity.module", IDENTITY, "moduleName", %w[derive], "identity"],
      ["identity.slug", IDENTITY, "appSlug", %w[derive], "identity"],
      ["identity.bundleId", IDENTITY, "bundleId", %w[derive account], "identity"],
      ["platforms", APP, "platforms", %w[derive], "registration"],
      ["deviceSupport", APP, "platforms", %w[derive], "registration"],
      ["version", APP, "version", %w[derive account], "version"],
      ["build", VALUES, "build", %w[derive account], "version"],
      ["primaryLocale", APP, "primaryLocale", %w[user derive], "registration"],
      ["supportedLocales", VALUES, "supportedLocales", %w[user derive], "registration"],
      ["sku", VALUES, "sku", %w[user account], "registration"],
      ["category", APP, "category", %w[derive user], "app-information"],
      ["secondaryCategory", VALUES, "secondaryCategory", %w[derive user], "app-information"],
      ["copyright", APP, "copyright", %w[derive user], "version"],
      ["reviewNotes", "App Store/review/review-notes.md", "document", %w[derive user], "review"],
      ["reviewContactReference", APP, "reviewContactReference", %w[user account], "review"],
      ["demoAccess", VALUES, "demoAccess", %w[derive user account], "review"],
      ["privacy.collectsData", PRIVACY, "collectsData", %w[derive user], "privacy"],
      ["privacy.dataTypes", PRIVACY, "dataTypes", %w[derive user], "privacy"],
      ["privacy.tracking", PRIVACY, "tracking", %w[derive user], "privacy"],
      ["privacy.permissions", PRIVACY, "permissions", %w[derive user], "privacy"],
      ["privacy.accountDeletion", PRIVACY, "accountDeletion", %w[derive user], "privacy"],
      ["privacy.thirdPartySDKs", PRIVACY, "thirdPartySDKs", %w[derive user], "privacy"],
      ["ageRating", VALUES, "ageRating", %w[derive user], "app-information"],
      ["contentRights", VALUES, "contentRights", %w[derive user], "app-information"],
      ["exportCompliance", VALUES, "exportCompliance", %w[derive user], "version"],
      ["legal.privacyPolicy", "App Store/legal/privacy-policy.md", "document", %w[user public], "legal"],
      ["legal.termsOfUse", "App Store/legal/terms-of-use.md", "document", %w[user public], "legal"],
      ["legal.eula", VALUES, "legal.eula", %w[user public], "legal"],
      ["iap.productId", VALUES, "iap.productId", %w[derive user account], "iap"],
      ["iap.productType", VALUES, "iap.productType", %w[derive user account], "iap"],
      ["iap.price", VALUES, "iap.price", %w[derive user account], "iap"],
      ["iap.territories", VALUES, "iap.territories", %w[derive user account], "iap"],
      ["iap.availability", VALUES, "iap.availability", %w[derive user account], "iap"],
      ["iap.restore", VALUES, "iap.restore", %w[derive user account], "iap"],
      ["iap.offerCodeApplicability", VALUES, "iap.offerCodeApplicability", %w[derive user account], "iap"],
      ["account.teamId", OWNERSHIP, "appStore.teamId", %w[account user], "registration"],
      ["account.appId", VALUES, "account.appId", %w[account user], "registration"],
      ["account.bundleRegistration", VALUES, "account.bundleRegistration", %w[account user], "registration"],
      ["account.userAccess", VALUES, "account.userAccess", %w[account user], "registration"]
    ].freeze

    # A declaration binds scope and reason, not approval. Approval is checked
    # through the same source-bound receipts as ordinary confirmations.
    class FieldDispositions
      OPTIONAL_TEXT = %w[secondaryCategory marketingURL subtitle promotionalText].freeze
      attr_reader :errors

      def initialize(values, definitions)
        @values, @entries, @errors = values, {}, []
        document = values.call(VALUES, "dispositions")
        return if document.nil?
        unless document.is_a?(Array) && document.length <= 256
          @errors << "invalid-dispositions"
          return
        end
        known = definitions.map { |definition, locale| [definition[0], locale] }
        document.each do |entry|
          unless entry.is_a?(Hash) && entry.keys.sort == %w[decision fieldId locale reason] &&
              %w[deferred not-applicable].include?(entry["decision"]) &&
              entry["reason"].is_a?(String) && !entry["reason"].strip.empty? &&
              entry["reason"].bytesize <= 4096 && !entry["reason"].match?(/[\x00-\x1f\x7f]/)
            @errors << "invalid-disposition"
            next
          end
          key = [entry["fieldId"], entry["locale"]]
          unless known.include?(key)
            @errors << "unknown-disposition-field"
            next
          end
          if @entries.key?(key)
            @errors << "duplicate-disposition-field"
            @entries[key] = nil
          else
            @entries[key] = entry["decision"]
          end
        end
        @errors.uniq!
      end

      def decision(id, locale)
        @entries[[id, locale]]
      end

      def applicability_error(id, value)
        if OPTIONAL_TEXT.include?(id)
          return nil if value.nil? || value == ""
          return "disposition-value-conflict"
        elsif id.start_with?("iap.")
          ids = SourceSchema::GROUP_KEYS.fetch("iap").map { |key| "iap.#{key}" }
          return "disposition-iap-group-incomplete" unless ids.all? { |key| decision(key, nil) == "not-applicable" }
          iap = @values.call(VALUES, "iap")
          return nil if iap.nil? || iap.is_a?(Hash) && (iap.keys - SourceSchema::GROUP_KEYS.fetch("iap")).empty? &&
            iap.all? { |key, item| item.nil? || key == "productId" && item == [] }
          return "disposition-value-conflict"
        elsif id.start_with?("screenshots.")
          return "disposition-value-conflict" unless value.nil?
          return nil if @values.call(APP, "platforms.#{id.split('.').last}") == false
        end
        "disposition-not-applicable-forbidden"
      end
    end

    class Report
      def initialize(root, protected_input: nil)
        @sources = Sources.new(root)
        @documents = {}
        @protected_input = protected_input
      end

      def value_at(path, anchor)
        return @sources.read(path) if anchor == "document"
        document = @documents.fetch(path) { @documents[path] = @sources.document(path) }
        anchor.split(".").reduce(document) { |value, part| value.is_a?(Hash) ? value[part] : nil }
      end

      def dependency_fields(id, section)
        case section
        when "identity" then %w[account.bundleRegistration account.appId build reviewNotes]
        when "privacy" then %w[legal.privacyPolicy legal.termsOfUse privacyPolicyURL reviewNotes]
        when "legal" then %w[privacyPolicyURL]
        when "registration" then %w[account.appId build]
        when "iap" then %w[reviewNotes legal.termsOfUse]
        else []
        end.reject { |field| field == id }
      end

      def template_text?(id, locale, value)
        return false unless value.is_a?(String)
        normalized = value.strip
        baseline = TEMPLATE_TEXT_VALUES[[id, locale]]
        sentinels = TEMPLATE_TEXT_SENTINELS.fetch([id, locale], [])
        localized_placeholder = if locale == "en-US"
                                  normalized.match?(/replace\s+before\s+submission|draft\s+(?:product-page\s+copy|promotional\s+text)|template\s*,\s*utility/i)
                                elsif locale == "ja"
                                  normalized.match?(/提出前に置き換え|下書き|テンプレート\s*,\s*ユーティリティ/)
                                else
                                  false
                                end
        normalized == baseline || localized_placeholder || sentinels.any? { |sentinel| normalized.downcase.include?(sentinel.downcase) } ||
          normalized.match?(/TemplateApp|Template App|テンプレートアプリ|\bDraft\b|replace for the app/i)
      end

      def row(definition, locale)
        id, path, anchor, classification, section = definition
        value = value_at(path, anchor)
        planned = @dispositions.decision(id, locale)
        disposition_error = @dispositions.applicability_error(id, value) if planned == "not-applicable"
        planned = nil if disposition_error
        if id == "ageRating" && value.is_a?(Hash) && !value["ageSuitabilityURL"].nil?
          classification = classification + ["public"]
        elsif id == "exportCompliance" && value.is_a?(Hash) && value["documents"].is_a?(Array) && !value["documents"].empty?
          classification = classification + ["account"]
        end
        error = @sources.error(path)
        reasons = [error || (value.nil? ? "missing-value" : "confirmation-missing")]
        reasons.concat(@source_schema.reasons(id, path, anchor, value))
        reasons << "template-value" if template_text?(id, locale, value)
        reasons << "unsupported-primary-locale" if id == "primaryLocale" && !value.nil? && value != "en-US"
        reasons << "team-unset" if id == "account.teamId" && (value.nil? || value == "")
        sources = [@sources.descriptor(path, anchor)]
        if section == "identity"
          sources << @sources.descriptor(TEMPLATE_IDENTITY, "source")
          template_error = @sources.error(TEMPLATE_IDENTITY)
          reasons << template_error if template_error
        end
        if id == "demoAccess" && value.is_a?(Hash) && value["required"] == true &&
            value["instructionsSource"].is_a?(String) && value["instructionsSource"].match?(SourceSchema::DEMO_INSTRUCTIONS_SOURCE)
          instructions = value["instructionsSource"]
          sources << @sources.descriptor(instructions, "document")
          reasons << @sources.error(instructions) if @sources.error(instructions)
        end
        if @dispositions.decision(id, locale)
          sources << @sources.descriptor(VALUES, "dispositions")
          reasons << @source_schema.preparation_error if @source_schema.preparation_error
        end
        reasons << disposition_error if disposition_error
        if planned
          classification = planned == "deferred" ? %w[user] : %w[derive user]
          if planned == "not-applicable"
            reasons -= %w[missing-value confirmation-missing]
            reasons.delete("invalid-field-value") if value == "" || id == "iap.productId" && value == []
          end
        end
        asset = planned ? {"reasons" => [], "sources" => [], "origins" => []} : @asset_evidence.check(id, locale, value)
        reasons.concat(asset["reasons"])
        sources.concat(asset["sources"])
        if classification.include?("public")
          preparation_error = @source_schema.preparation_error
          reasons << preparation_error if preparation_error
          sources << @sources.descriptor(VALUES, "publicPages")
          if %w[supportURL privacyPolicyURL marketingURL].include?(id)
            url_error = PublicEvidence.url_error(value)
            reasons << url_error if url_error
          end
        end
        if XcodeFacts::FIELDS.include?(id)
          reasons.concat(@xcode_facts.fetch("fields").fetch(id, []))
          sources.concat(@xcode_facts.fetch("sources"))
        end
        if planned == "not-applicable"
          sources.concat(@code_inventory.fetch("sources"))
          reasons << "code-inventory-unavailable" unless @code_inventory["inventoryComplete"]
        elsif CodeInventory.inventory_affected?(id)
          reasons.concat(@code_inventory.fetch("inventoryReasons"))
          reasons.concat(@code_inventory.fetch("privacyReasons")) if CodeInventory.privacy_affected?(id)
          sources.concat(@code_inventory.fetch("sources"))
          if CodeInventory.privacy_affected?(id) && path != PRIVACY
            sources << @sources.descriptor(PRIVACY, "document")
          end
        elsif CodeInventory.feature_copy?(id)
          sources.concat(@code_inventory.fetch("sources"))
          reasons << "code-inventory-unavailable" unless @code_inventory["inventoryComplete"]
        end
        if id.start_with?("privacy.")
          sources << @sources.descriptor(APP, "accountsSupported")
          app_error = @sources.error(APP) || @source_schema.structure_error(APP, "accountsSupported")
          reasons << app_error if app_error
        end
        {
          "fieldId" => id, "locale" => locale, "section" => section, "classification" => classification,
          "state" => "draft", "sources" => sources,
          "plannedState" => planned,
          "artifactOrigins" => asset["origins"],
          "reasons" => reasons.uniq, "unblockConditions" => ["provide-current-source-and-required-confirmation-evidence"],
          "dependentFields" => dependency_fields(id, section)
        }
      end

      def run
        @source_schema = SourceSchema.new(@sources, method(:value_at))
        @xcode_facts = XcodeFacts.new(@sources, method(:value_at)).run
        @code_inventory = CodeInventory.new(@sources, method(:value_at), @xcode_facts).run
        @asset_evidence = AssetEvidence.new(@sources, method(:value_at), Time.now.utc, @code_inventory)
        definitions = SHARED_FIELDS.map { |definition| [definition, nil] }
        %w[en-US ja].each do |locale|
          LOCALIZED_FIELDS.each do |id|
            if id == "releaseNotes"
              definition = [id, "App Store/release-notes/#{locale}.md", "document", %w[derive], "version-localization"]
            elsif id.start_with?("screenshots.")
              definition = [id, VALUES, "screenshots.#{locale}.#{id.split('.').last}", %w[derive], "screenshots"]
            elsif %w[supportURL privacyPolicyURL marketingURL].include?(id)
              overrides = value_at(VALUES, "localizedURLs.#{locale}")
              source_path, source_anchor = if overrides.is_a?(Hash) && overrides.key?(id)
                [VALUES, "localizedURLs.#{locale}.#{id}"]
              else
                [id == "marketingURL" ? VALUES : APP, id]
              end
              section = id == "privacyPolicyURL" ? "app-info-localization" : "version-localization"
              definition = [id, source_path, source_anchor, %w[public user], section]
            else
              classes = %w[name subtitle].include?(id) ? %w[derive user] : %w[derive]
              section = %w[name subtitle].include?(id) ? "app-info-localization" : "version-localization"
              definition = [id, "App Store/metadata/localizations/#{locale}.yml", id, classes, section]
            end
            definitions << [definition, locale]
          end
        end
        @dispositions = FieldDispositions.new(method(:value_at), definitions)
        fields = definitions.map { |definition, locale| row(definition, locale) }
        registration = Registration.new(@sources, method(:value_at), Time.now.utc, @source_schema).run
        unless registration["reasons"].empty?
          fields.select { |field| field["classification"].include?("account") }.each do |field|
            field["reasons"] = (field["reasons"] + registration["reasons"].map { |reason| "registration:#{reason}" }).uniq
          end
        end
        Confirmation.new(@sources, Time.now.utc, values: method(:value_at), registration: registration, protected_input: @protected_input).apply(fields)
        @sources.verify!
        prepared = @dispositions.errors.empty? && registration["status"] == "matched-observation" && fields.all? { |field| %w[confirmed remote-saved not-applicable].include?(field["state"]) }
        {"schemaVersion" => 1, "recordType" => "appstore-preparation", "status" => prepared ? "prepared" : "blocked",
         "sourceRevision" => @sources.revision, "checkedAt" => Time.now.utc.iso8601,
         "releaseReady" => false, "remoteMutations" => [], "liveRemoteInspection" => false,
         "fields" => fields, "registration" => registration, "planningErrors" => @dispositions.errors}
      ensure
        @sources.close
      end
    end

    def self.main(arguments)
      root = nil
      protected_stdin = false
      parser = OptionParser.new do |options|
        options.on("--project-root PATH") do |value|
          raise InvalidInput, "duplicate-project-root" if root
          root = value
        end
        options.on("--protected-forms-stdin") do
          raise InvalidInput, "duplicate-protected-input-option" if protected_stdin
          protected_stdin = true
        end
      end
      parser.parse!(arguments)
      raise InvalidInput, "invalid-arguments" unless root && arguments.empty?
      protected_input = ProtectedFormInput.read(STDIN) if protected_stdin
      report = Report.new(root, protected_input: protected_input).run
      puts JSON.generate(report)
      report.fetch("status") == "prepared" ? 0 : 1
    rescue InvalidInput, OptionParser::ParseError, SystemCallError, IOError, ArgumentError,
           JSON::GeneratorError, JSON::NestingError
      # Never echo supplied paths, values, parser excerpts or exception messages.
      puts JSON.generate({"schemaVersion" => 1, "recordType" => "appstore-preparation",
                          "status" => "invalid", "releaseReady" => false, "remoteMutations" => [],
                          "errors" => ["invalid-or-changing-preparation-input"]})
      2
    end
  end
end

exit IOSTemplate::AppStorePreparation.main(ARGV) if $PROGRAM_NAME == __FILE__
