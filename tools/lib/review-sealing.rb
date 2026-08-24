# frozen_string_literal: true

require "fiddle/import"

module IOSTemplate
  module ReviewSealing
    class SealError < StandardError; end

    module Native
      extend Fiddle::Importer
      dlload Fiddle.dlopen(nil)
      extern "int openat(int, const char*, int, int)"
      extern "int unlinkat(int, const char*, int)"
      extern "int fchmod(int, unsigned int)"
    end

    Directory = Struct.new(:io, :parent, :name, :stat, :at, keyword_init: true)
    Leaf = Struct.new(:io, :parent, :name, :stat, :bytes, :at, keyword_init: true)

    class SnapshotSet
      def initialize(root, at:, expected_identity: nil)
        raise SealError, "#{at} must be an absolute physical directory" unless root.start_with?("/") && File.realpath(root) == root
        root_io = File.open(root, File::RDONLY | File::NOFOLLOW)
        root_stat = root_io.stat
        raise SealError, "#{at} must be a physical directory" unless root_stat.directory?
        if expected_identity && [root_stat.dev, root_stat.ino] != expected_identity
          raise SealError, "#{at} identity changed"
        end
        @root = Directory.new(io: root_io, parent: nil, name: nil, stat: root_stat, at: at)
        @directories = [@root]
        @leaves = []
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP => error
        raise SealError, "#{at} is unavailable: #{error.message}"
      end

      attr_reader :root

      def directory(parent, name, at:)
        component!(name, at)
        fd = Native.openat(parent.io.fileno, name, File::RDONLY | File::NOFOLLOW, 0)
        system_error!("openat #{at}") if fd.negative?
        io = File.for_fd(fd, autoclose: true)
        stat = io.stat
        raise SealError, "#{at} is not a physical directory" unless stat.directory?
        directory = Directory.new(io: io, parent: parent, name: name, stat: stat, at: at)
        @directories << directory
        directory
      rescue StandardError
        io&.close unless io&.closed?
        raise
      end

      def leaf(parent, name, at:)
        component!(name, at)
        fd = Native.openat(parent.io.fileno, name, File::RDONLY | File::NOFOLLOW, 0)
        system_error!("openat #{at}") if fd.negative?
        io = File.for_fd(fd, autoclose: true)
        stat = io.stat
        raise SealError, "#{at} must be a regular single-link file" unless stat.file? && stat.nlink == 1
        io.binmode
        bytes = io.read
        final = io.stat
        raise SealError, "#{at} changed while read" unless metadata_equal?(stat, final) && final.size == bytes.bytesize
        leaf = Leaf.new(io: io, parent: parent, name: name, stat: final, bytes: bytes, at: at)
        @leaves << leaf
        leaf
      rescue StandardError
        io&.close unless io&.closed?
        raise
      end

      def relative_leaf(relative, at:)
        components = relative.split("/")
        raise SealError, "#{at} path is unsafe" if components.empty? || components.any? { |part| part.empty? || part == "." || part == ".." }
        current = @root
        components[0...-1].each_with_index do |component, index|
          current = directory(current, component, at: "#{at} component #{index + 1}")
        end
        leaf(current, components.last, at: at)
      end

      def verify!
        @directories.drop(1).each do |directory|
          current = open_at(directory.parent, directory.name, directory.at)
          stat = current.stat
          current.close
          raise SealError, "#{directory.at} component identity changed" unless
            directory.stat.dev == stat.dev && directory.stat.ino == stat.ino && stat.directory?
        end
        @leaves.each do |leaf|
          leaf.io.rewind
          descriptor_bytes = leaf.io.read
          descriptor_stat = leaf.io.stat
          raise SealError, "#{leaf.at} descriptor changed" unless metadata_equal?(leaf.stat, descriptor_stat) && descriptor_bytes == leaf.bytes
          current = open_at(leaf.parent, leaf.name, leaf.at)
          current.binmode
          current_bytes = current.read
          current_stat = current.stat
          current.close
          raise SealError, "#{leaf.at} path identity changed" unless metadata_equal?(leaf.stat, current_stat)
          raise SealError, "#{leaf.at} path bytes changed" unless current_bytes == leaf.bytes
        end
        true
      end

      def publish_exclusive(directory, name, bytes, at:)
        component!(name, at)
        fd = Native.openat(directory.io.fileno, name, File::RDWR | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600)
        system_error!("openat publish #{at}") if fd.negative?
        output = File.for_fd(fd, autoclose: true)
        created_stat = output.stat
        system_error!("fchmod #{at}") unless Native.fchmod(output.fileno, 0o600).zero?
        output.binmode
        output.write(bytes)
        output.flush
        output.fsync
        output.rewind
        written = output.read
        stat = output.stat
        raise SealError, "#{at} publication bytes changed" unless written == bytes
        raise SealError, "#{at} must be a regular single-link 0600 file" unless stat.file? && stat.nlink == 1 && (stat.mode & 0o777) == 0o600
        output.close
        current = leaf(directory, name, at: at)
        raise SealError, "#{at} publication identity changed" unless current.bytes == bytes && stable_identity?(current.stat, stat)
        directory.io.fsync
        current
      rescue StandardError
        output&.close unless output&.closed?
        unlink_if_identity(directory, name, created_stat) if defined?(created_stat) && created_stat
        raise
      end

      def unlink_if_same(directory, leaf)
        unlink_if_identity(directory, leaf.name, leaf.stat)
      end

      def unlink_if_identity(directory, name, expected_stat)
        component!(name, "unlink")
        current = open_at(directory, name, "unlink")
        current_stat = current.stat
        current.close
        return false unless expected_stat.dev == current_stat.dev && expected_stat.ino == current_stat.ino
        result = Native.unlinkat(directory.io.fileno, name, 0)
        system_error!("unlinkat") unless result.zero?
        directory.io.fsync
        true
      rescue SystemCallError => error
        return false if error.errno == Errno::ENOENT::Errno
        raise
      end

      def close
        (@leaves.map(&:io) + @directories.map(&:io)).reverse_each { |io| io.close unless io.closed? }
      end

      private

      def component!(name, at)
        raise SealError, "#{at} component is unsafe" unless name.is_a?(String) && name.match?(/\A[^\/\0]+\z/) && name != "." && name != ".."
      end

      def open_at(parent, name, at)
        fd = Native.openat(parent.io.fileno, name, File::RDONLY | File::NOFOLLOW, 0)
        system_error!("openat #{at}") if fd.negative?
        File.for_fd(fd, autoclose: true)
      end

      def stable_identity?(expected, actual)
        expected.dev == actual.dev && expected.ino == actual.ino && expected.mode == actual.mode &&
          expected.nlink == actual.nlink && expected.uid == actual.uid && expected.gid == actual.gid
      end

      def metadata_equal?(expected, actual)
        stable_identity?(expected, actual) && expected.size == actual.size &&
          expected.mtime.to_r == actual.mtime.to_r
      end

      def system_error!(operation)
        raise SystemCallError.new(operation, Fiddle.last_error)
      end
    end
  end
end
