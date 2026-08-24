#!/usr/bin/env ruby
# frozen_string_literal: true

require "fiddle"
require "securerandom"

module DescriptorFiles
  module_function

  HANDLE = Fiddle::Handle::DEFAULT
  OPENAT = Fiddle::Function.new(HANDLE["openat"], [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
  RENAMEAT = Fiddle::Function.new(HANDLE["renameat"], [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
  UNLINKAT = Fiddle::Function.new(HANDLE["unlinkat"], [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
  FCHMOD = Fiddle::Function.new(HANDLE["fchmod"], [Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)

  def system_error!(operation)
    raise SystemCallError.new(operation, Fiddle.last_error)
  end

  def component!(name)
    raise ArgumentError, "unsafe descriptor component" unless name.is_a?(String) && name.match?(/\A[^\/\0]+\z/) && name != "." && name != ".."
    name
  end

  def open_directory(path)
    before = File.lstat(path)
    raise IOError, "directory is not a plain directory" unless before.directory? && !before.symlink?
    io = File.open(path, File::RDONLY | File::NOFOLLOW)
    after = io.stat
    raise IOError, "directory changed while opening" unless after.directory? && after.dev == before.dev && after.ino == before.ino
    io
  end

  def open_directory_at(parent, name)
    name = component!(name)
    fd = OPENAT.call(parent.fileno, name, File::RDONLY | File::NOFOLLOW, 0)
    system_error!("openat directory") if fd.negative?
    io = IO.for_fd(fd, autoclose: true)
    raise IOError, "descriptor component is not a directory" unless io.stat.directory?
    io
  rescue StandardError
    io&.close unless io&.closed?
    raise
  end

  def open_regular_at(parent, name)
    name = component!(name)
    fd = OPENAT.call(parent.fileno, name, File::RDONLY | File::NOFOLLOW, 0)
    system_error!("openat regular file") if fd.negative?
    io = IO.for_fd(fd, autoclose: true)
    stat = io.stat
    raise IOError, "descriptor file is not an owned single-link regular file" unless stat.file? && stat.nlink == 1
    [io, stat]
  rescue StandardError
    io&.close unless io&.closed?
    raise
  end

  def read_regular_at(parent, name)
    io, opened = open_regular_at(parent, name)
    bytes = io.read
    final = io.stat
    raise IOError, "descriptor file changed while reading" unless final.dev == opened.dev && final.ino == opened.ino && final.nlink == 1 && final.size == bytes.bytesize
    [bytes, opened]
  ensure
    io&.close unless io&.closed?
  end

  def open_components(root, components)
    handles = [open_directory(root)]
    components.each { |component| handles << open_directory_at(handles.last, component) }
    handles
  rescue StandardError
    handles&.reverse_each { |handle| handle.close unless handle.closed? }
    raise
  end

  def atomic_replace_at(directory, destination, bytes, expected_stat)
    destination = component!(destination)
    current, current_stat = open_regular_at(directory, destination)
    raise IOError, "destination changed before publication" unless current_stat.dev == expected_stat.dev && current_stat.ino == expected_stat.ino && current_stat.nlink == 1
    current.close
    temporary = ".#{destination}.tmp.#{Process.pid}.#{SecureRandom.hex(8)}"
    fd = OPENAT.call(directory.fileno, temporary, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600)
    system_error!("openat temporary file") if fd.negative?
    output = IO.for_fd(fd, autoclose: true)
    system_error!("fchmod") unless FCHMOD.call(output.fileno, 0o600).zero?
    output.write(bytes)
    output.flush
    output.fsync
    output.close
    current, current_stat = open_regular_at(directory, destination)
    raise IOError, "destination changed during publication" unless current_stat.dev == expected_stat.dev && current_stat.ino == expected_stat.ino && current_stat.nlink == 1
    current.close
    result = RENAMEAT.call(directory.fileno, temporary, directory.fileno, destination)
    system_error!("renameat") unless result.zero?
    directory.fsync
  ensure
    output&.close unless output&.closed?
    current&.close unless current&.closed?
    UNLINKAT.call(directory.fileno, temporary, 0) if defined?(temporary) && temporary && directory && !directory.closed?
  end
end
