require "pathname"
require "rbconfig"
require "securerandom"
require_relative "subprocess"

module CampfireBackup
  class DescriptorTree
    CHDIR_MUTEX = Mutex.new

    attr_reader :path, :root

    def initialize(path, expected_identity: nil, description: "Descriptor tree")
      raise "No-follow descriptor support is required for #{description.downcase}" unless defined?(File::NOFOLLOW)
      raise "Descriptor-relative directory support is required for #{description.downcase}" unless Dir.respond_to?(:fchdir)

      @path = Pathname(path).expand_path
      flags = File::RDONLY | File::NOFOLLOW
      flags |= File::NONBLOCK if defined?(File::NONBLOCK)
      @root = File.open(@path, flags)
      opened = @root.stat
      current = @path.lstat
      identity = file_identity(opened)
      unless opened.directory? && current.directory? && !current.symlink? &&
          identity == file_identity(current) &&
          (!expected_identity || identity_matches?(opened, expected_identity))
        raise "#{description} changed while its root descriptor was opened"
      end
      @root.close_on_exec = true
      @description = description
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR
      @root&.close
      raise "#{description} is not an independent directory"
    rescue StandardError
      @root&.close
      raise
    end

    def close
      root.close unless root.closed?
    end

    def to_path
      path.to_s
    end

    def pinned_root_stat
      root.stat
    end

    def assert_root_current!
      opened = root.stat
      current = path.lstat
      unless opened.directory? && current.directory? && !current.symlink? &&
          file_identity(opened) == file_identity(current)
        raise "#{@description} changed while in use"
      end
      true
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR
      raise "#{@description} changed while in use"
    end

    def children(relative = ".")
      open_directory(relative) do |directory|
        duplicate = directory.dup
        duplicate.autoclose = false
        stream = Dir.for_fd(duplicate.fileno)
        stream.children
      ensure
        stream&.close
      end
    end

    def entry_missing?(relative)
      components = safe_components(relative)
      return false if components.empty?

      with_parent(components) do |parent, name|
        file = open_at(parent, name, File::RDONLY)
        false
      ensure
        file&.close
      end
    rescue Errno::ENOENT
      true
    rescue Errno::ELOOP, Errno::ENOTDIR, Errno::ENXIO, Errno::ENODEV
      false
    end

    def open_entry(relative, expected_identity: nil)
      components = safe_components(relative)
      if components.empty?
        stat = root.stat
        if expected_identity && !identity_matches?(stat, expected_identity)
          raise "Descriptor-tree entry changed concurrently: #{display_path(relative)}"
        end
        result = yield root, stat
        assert_root_current!
        return result
      end

      with_parent(components) do |parent, name|
        file = open_at(parent, name, File::RDONLY)
        stat = file.stat
        identity = file_identity(stat)
        if expected_identity && !identity_matches?(stat, expected_identity)
          raise "Descriptor-tree entry changed concurrently: #{display_path(relative)}"
        end
        result = yield file, stat
        after = file.stat
        current = open_at(parent, name, File::RDONLY)
        unless identity == file_identity(after) && identity == file_identity(current.stat)
          raise "Descriptor-tree entry changed concurrently: #{display_path(relative)}"
        end
        result
      ensure
        active_error = $!
        close_error = close_descriptors(current, file).first
        raise close_error if close_error && !active_error
      end
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, Errno::ENXIO, Errno::ENODEV
      raise "Descriptor-tree entry changed concurrently: #{display_path(relative)}"
    end

    def open_directory(relative = ".", expected_identity: nil)
      open_entry(relative, expected_identity:) do |file, stat|
        unless stat.directory?
          raise "Descriptor-tree path is not a directory: #{display_path(relative)}"
        end
        yield file, stat
      end
    end

    def open_regular_file(relative, flags: File::RDONLY, expected_identity: nil)
      components = safe_components(relative)
      raise "Descriptor-tree file path is empty" if components.empty?

      with_parent(components) do |parent, name|
        file = open_at(parent, name, flags)
        file.binmode
        stat = file.stat
        unless stat.file? && stat.nlink == 1 &&
            (!expected_identity || identity_matches?(stat, expected_identity))
          raise "Descriptor-tree path is not the expected independent regular file: #{display_path(relative)}"
        end
        signature = stable_file_signature(stat)
        result = yield file, stat
        after = file.stat
        current = open_at(parent, name, File::RDONLY)
        unless signature == stable_file_signature(after) &&
            signature == stable_file_signature(current.stat)
          raise "Descriptor-tree file changed concurrently: #{display_path(relative)}"
        end
        result
      ensure
        active_error = $!
        close_error = close_descriptors(current, file).first
        raise close_error if close_error && !active_error
      end
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, Errno::ENXIO, Errno::ENODEV
      raise "Descriptor-tree path is not an independent regular file: #{display_path(relative)}"
    end

    def create_file(relative, mode: 0o600, flags: File::WRONLY)
      components = safe_components(relative)
      raise "Descriptor-tree file path is empty" if components.empty?

      with_parent(components) do |parent, name|
        file = open_at(parent, name, flags | File::CREAT | File::EXCL, mode)
        file.binmode
        stat = file.stat
        unless stat.file? && stat.nlink == 1
          raise "Descriptor-tree file creation did not produce an independent regular file"
        end
        identity = file_identity(stat)
        result = yield file, stat
        result
      ensure
        active_error = $!
        post_callback_error = nil
        if file && !active_error
          begin
            after = file.stat
            current = open_at(parent, name, File::RDONLY)
            unless after.file? && after.nlink == 1 && current.stat.file? &&
                current.stat.nlink == 1 && identity == file_identity(after) &&
                identity == file_identity(current.stat)
              raise "Descriptor-tree file changed during creation: #{display_path(relative)}"
            end
          rescue StandardError => error
            post_callback_error = error
          ensure
            begin
              current&.close
            rescue StandardError => error
              post_callback_error ||= error
            end
          end
        end
        begin
          file&.close
        rescue StandardError => error
          post_callback_error ||= error
        end
        raise post_callback_error if post_callback_error && !active_error
      end
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, Errno::ENXIO, Errno::ENODEV
      raise "Descriptor-tree path changed concurrently: #{display_path(relative)}"
    end

    def open_or_create_regular_file(relative, mode: 0o600, flags: File::RDWR)
      components = safe_components(relative)
      raise "Descriptor-tree file path is empty" if components.empty?

      with_parent(components) do |parent, name|
        file = open_at(parent, name, flags | File::CREAT, mode)
        stat = file.stat
        unless stat.file? && stat.nlink == 1
          raise "Descriptor-tree path is not an independent regular file: #{display_path(relative)}"
        end
        result = yield file, stat
        current = open_at(parent, name, File::RDONLY)
        unless file_identity(stat) == file_identity(file.stat) &&
            file_identity(stat) == file_identity(current.stat) && current.stat.nlink == 1
          raise "Descriptor-tree file changed concurrently: #{display_path(relative)}"
        end
        result
      ensure
        active_error = $!
        close_error = close_descriptors(current, file).first
        raise close_error if close_error && !active_error
      end
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, Errno::ENXIO, Errno::ENODEV
      raise "Descriptor-tree path changed concurrently: #{display_path(relative)}"
    end

    def mkdir(relative, mode: 0o700)
      components = safe_components(relative)
      raise "Descriptor-tree directory path is empty" if components.empty?

      with_parent(components) do |parent, name|
        at(parent) { Dir.mkdir(name, mode) }
        directory = open_at(parent, name, File::RDONLY)
        stat = directory.stat
        unless stat.directory?
          raise "Descriptor-tree directory creation did not produce a directory"
        end
        yield directory, stat if block_given?
      ensure
        active_error = $!
        close_error = close_descriptors(directory).first
        raise close_error if close_error && !active_error
      end
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR
      raise "Descriptor-tree path changed concurrently: #{display_path(relative)}"
    end

    def link(source_relative, destination_relative)
      source = safe_components(source_relative)
      destination = safe_components(destination_relative)
      unless source.length > 1 && source[0...-1] == destination[0...-1]
        raise "Descriptor-tree hard links must stay in one directory"
      end

      with_directory_components(source[0...-1]) do |parent|
        at(parent) { File.link(source.last, destination.last) }
      end
    end

    def remove(relative, expected_identity:, directory:, independent: true)
      components = safe_components(relative)
      raise "Descriptor-tree removal path is empty" if components.empty?

      with_parent(components) do |parent, name|
        quarantine_name, quarantine, quarantine_identity = create_quarantine(parent)
        at(parent) { File.rename(name, "#{quarantine_name}/entry") }
        moved = true
        current_quarantine = open_at(parent, quarantine_name, File::RDONLY)
        unless current_quarantine.stat.directory? &&
            file_identity(current_quarantine.stat) == quarantine_identity
          raise "Descriptor-tree removal quarantine changed concurrently: #{display_path(relative)}"
        end

        file = open_at(quarantine, "entry", File::RDONLY)
        stat = file.stat
        expected_type = directory ? stat.directory? : stat.file? && (!independent || stat.nlink == 1)
        unless expected_type && identity_matches?(stat, expected_identity)
          raise "Descriptor-tree entry changed concurrently and was preserved in " \
            "#{display_path(quarantine_name)}"
        end

        at(quarantine) { directory ? Dir.rmdir("entry") : File.unlink("entry") }
        quarantine.fsync
        at(parent) { Dir.rmdir(quarantine_name) }
        parent.fsync
        true
      ensure
        active_error = $!
        close_errors = close_descriptors(file, current_quarantine, quarantine)
        begin
          remove_empty_quarantine(parent, quarantine_name, quarantine_identity) if
            quarantine_name && !moved
        rescue StandardError => error
          close_errors << error
        end
        raise close_errors.first if close_errors.any? && !active_error
      end
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, Errno::ENXIO, Errno::ENODEV
      raise "Descriptor-tree entry changed concurrently: #{display_path(relative)}"
    end

    def flush_root
      root.fsync
    end

    def available_bytes
      df = [ "/bin/df", "/usr/bin/df" ].find { File.executable?(_1) } || "df"
      script = <<~'RUBY'
        descriptor = Integer(ARGV.shift, 10)
        Dir.fchdir(descriptor)
        exec(*ARGV)
      RUBY
      output, status = CampfireBackup::Subprocess.capture2(
        RbConfig.ruby, "-e", script, root.fileno.to_s, df, "-Pk", ".",
        spawn_options: { root.fileno => root.fileno, close_others: true }
      )
      raise "Could not determine pinned filesystem capacity" unless status.success?

      fields = output.lines.last.to_s.split
      raise "Could not determine pinned filesystem capacity" if fields.length < 6

      Integer(fields.fetch(3), 10) * 1024
    rescue ArgumentError, Errno::ENOENT
      raise "Could not determine pinned filesystem capacity"
    end

    def with_unlinked_temporary_file
      file = open_anonymous_temporary_file
      return yield(file) if file

      relative = nil
      named_identity = nil
      created_file = nil
      32.times do
        candidate = ".campfire-unlinked-#{SecureRandom.hex(16)}"
        begin
          create_file(candidate, mode: 0o600, flags: File::RDWR | File::BINARY) do |created, stat|
            relative = candidate
            named_identity = file_identity(stat)
            created.flush
            created.fsync
            created_file = created.dup
            created_file.binmode
            created_file.close_on_exec = true
          end
          flush_root
          remove(relative, expected_identity: named_identity, directory: false)
          flush_root
          unless created_file.stat.nlink.zero?
            raise "Backup plaintext staging could not be made private"
          end
          return yield(created_file)
        rescue Errno::EEXIST
          created_file&.close
          created_file = nil
          next
        end
      end
      raise "Could not create exclusive backup plaintext staging"
    ensure
      active_error = $!
      close_errors = close_descriptors(file, created_file)
      if relative && named_identity && !entry_missing?(relative)
        begin
          remove(relative, expected_identity: named_identity, directory: false)
          flush_root
        rescue StandardError => error
          close_errors << error
        end
      end
      raise close_errors.first if close_errors.any? && !active_error
    end

    private
      def open_anonymous_temporary_file
        return unless RUBY_PLATFORM.match?(/linux/)

        tmpfile_flag = File.const_defined?(:TMPFILE) ? File::TMPFILE : 0o20_200_000
        at(root) { File.open(".", File::RDWR | File::BINARY | tmpfile_flag, 0o600) }
      rescue Errno::EISDIR, Errno::EINVAL, Errno::EOPNOTSUPP, Errno::ENOTSUP
        nil
      end

      def create_quarantine(parent)
        32.times do
          name = ".campfire-quarantine-#{SecureRandom.hex(16)}"
          directory = nil
          begin
            at(parent) { Dir.mkdir(name, 0o700) }
            directory = open_at(parent, name, File::RDONLY)
            stat = directory.stat
            unless stat.directory?
              raise "Descriptor-tree removal quarantine is not a directory"
            end
            return [ name, directory, file_identity(stat) ]
          rescue Errno::EEXIST
            next
          rescue StandardError
            directory&.close
            raise
          end
        end
        raise "Could not create descriptor-tree removal quarantine"
      end

      def remove_empty_quarantine(parent, name, expected_identity)
        return unless parent && name && expected_identity

        directory = open_at(parent, name, File::RDONLY)
        return unless directory.stat.directory? && file_identity(directory.stat) == expected_identity

        at(parent) { Dir.rmdir(name) }
        parent.fsync
      rescue Errno::ENOENT, Errno::ENOTEMPTY, Errno::EEXIST
        nil
      ensure
        directory&.close
      end

      def with_parent(components)
        with_directory_components(components[0...-1]) { yield _1, components.last }
      end

      def with_directory_components(components)
        current = root.dup
        components.each do |name|
          child = open_at(current, name, File::RDONLY)
          unless child.stat.directory?
            child.close
            raise Errno::ENOTDIR, name
          end
          current.close
          current = child
        end
        yield current
      ensure
        active_error = $!
        close_error = close_descriptors(current).first
        raise close_error if close_error && !active_error
      end

      def open_at(parent, name, flags, mode = nil)
        flags |= File::NOFOLLOW
        flags |= File::NONBLOCK if defined?(File::NONBLOCK)
        at(parent) { mode ? File.open(name, flags, mode) : File.open(name, flags) }.tap do |file|
          file.close_on_exec = true
        end
      end

      def at(directory)
        CHDIR_MUTEX.synchronize { Dir.fchdir(directory.fileno) { yield } }
      rescue NotImplementedError
        raise "Descriptor-relative directory support is unavailable"
      end

      def safe_components(relative)
        path = Pathname(relative.to_s)
        if path.absolute?
          raise "Descriptor-tree path must be relative"
        end
        return [] if path.to_s == "."

        components = path.each_filename.to_a
        if components.empty? || components.any? { _1.empty? || _1 == "." || _1 == ".." || _1.include?(File::SEPARATOR) }
          raise "Descriptor-tree path is unsafe"
        end
        components
      end

      def display_path(relative)
        path.join(relative.to_s)
      end

      def file_identity(stat)
        [ stat.dev, stat.ino, stat.ftype ]
      end

      def close_descriptors(*descriptors)
        descriptors.compact.uniq.each_with_object([]) do |descriptor, errors|
          begin
            descriptor.close unless descriptor.closed?
          rescue StandardError => error
            errors << error
          end
        end
      end

      def stable_file_signature(stat)
        [
          stat.dev, stat.ino, stat.ftype, stat.nlink, stat.size,
          stat.mtime.to_i, stat.mtime.nsec, stat.ctime.to_i, stat.ctime.nsec
        ]
      end

      def identity_matches?(stat, expected)
        actual = file_identity(stat)
        actual << stat.nlink if expected.length == 4
        actual == expected
      end
  end
end
