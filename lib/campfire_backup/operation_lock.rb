require "digest"
require "json"
require "pathname"
require "securerandom"
require "time"

module CampfireBackup
  class OperationLock
    SHARED_FILENAME = ".campfire-operation.lock"
    LOCK_ROOT_ENV = "CAMPFIRE_OPERATION_LOCK_ROOT"
    INHERITED_FILE_FD_ENV = "CAMPFIRE_INHERITED_OPERATION_LOCK_FILE_FD"
    INHERITED_SHARED_FD_ENV = "CAMPFIRE_INHERITED_OPERATION_LOCK_FD"
    INHERITED_SHARED_TARGET_ENV = "CAMPFIRE_INHERITED_OPERATION_LOCK_TARGET"
    INHERITED_LOCK_ROOT_ENV = "CAMPFIRE_INHERITED_OPERATION_LOCK_ROOT"

    attr_reader :directory, :parent, :namespace, :path, :shared_path, :operation_id,
      :target_identity

    def self.lock_root(environment = ENV)
      configured = environment[LOCK_ROOT_ENV].to_s
      raise "#{LOCK_ROOT_ENV} is required" if configured.empty?

      Pathname(configured).expand_path
    end

    def self.acquire(directory, purpose:, create: true, shared: false,
        lock_root: self.lock_root, inherited_file_fd: nil, inherited_shared_fd: nil)
      new(
        directory, purpose:, create:, shared:, lock_root:, inherited_file_fd:, inherited_shared_fd:
      ).tap(&:acquire!)
    end

    def initialize(directory, purpose:, create: true, shared: false, lock_root: self.class.lock_root,
        inherited_file_fd: nil, inherited_shared_fd: nil)
      @requested_directory = Pathname(directory).expand_path
      @requested_lock_root = Pathname(lock_root).expand_path
      @purpose = purpose
      @create = create
      @shared = shared
      @inherited_file_fd = inherited_file_fd
      @inherited_shared_fd = inherited_shared_fd
      @operation_id = SecureRandom.hex(16)
    end

    def acquire!
      if @inherited_shared_fd && !@inherited_file_fd
        raise "Campfire inherited operation lock requires both stable and shared descriptors"
      end

      prepare_canonical_paths!
      prepare_namespace!
      @inherited_file_fd ? adopt_file! : acquire_file!

      requested_parent = @requested_directory.dirname
      requested_parent.mkpath if @create
      unless requested_parent.directory? && !requested_parent.symlink?
        raise "Campfire operation lock parent is not an independent directory"
      end

      @parent = requested_parent.realpath
      unless @parent == @canonical_requested_parent
        raise "Campfire operation lock parent changed during acquisition"
      end
      @directory = parent.join(@requested_directory.basename)
      @parent_identity = identity(parent)
      prepare_target!
      if @shared
        @inherited_shared_fd ? adopt_shared_file! : acquire_shared_file!
      end
      assert_current!

      metadata = JSON.generate(
        format_version: 3, operation_id:, purpose: @purpose, target: directory.to_s,
        lock_root: namespace.to_s, pid: Process.pid, acquired_at: Time.now.utc.iso8601
      ) << "\n"
      write_metadata @file, metadata
      write_metadata @shared_file, metadata if @shared_file
      File.open(@namespace, &:fsync)
      File.open(directory, &:fsync) if @shared_file
      assert_current!
      self
    rescue Errno::EACCES, Errno::EAGAIN
      @shared_file&.close
      @file&.close
      raise "Campfire storage is in use by another process"
    rescue StandardError
      @shared_file&.close
      @file&.close
      raise
    end

    def assert_current!
      unless current_identity(parent) == @parent_identity
        raise "Campfire operation lock parent changed while locked"
      end
      if @namespace && current_identity(@namespace) != @namespace_identity
        raise "Campfire operation lock parent changed while locked"
      end
      unless current_identity(directory) == @target_identity
        raise "Campfire operation target changed while locked"
      end

      if @file
        opened = @file.stat
        current = path.lstat
        unless opened.file? && opened.nlink == 1 && current.file? &&
            [ opened.dev, opened.ino ] == [ current.dev, current.ino ]
          raise "Campfire operation lock path changed while locked"
        end
      end
      if @shared_file
        shared_opened = @shared_file.stat
        shared_current = shared_path.lstat
        unless shared_opened.file? && shared_opened.nlink == 1 && shared_current.file? &&
            [ shared_opened.dev, shared_opened.ino ] == [ shared_current.dev, shared_current.ino ]
          raise "Campfire shared operation lock path changed while locked"
        end
      end
      true
    rescue Errno::ENOENT
      raise "Campfire operation path changed while locked"
    end

    def apply_file_ownership!(uid:, gid:, mode: 0o600)
      assert_current!
      [ @file, @shared_file ].compact.each do |file|
        before = file.stat
        unless before.file? && before.nlink == 1
          raise "Campfire operation lock descriptor is not an independent regular file"
        end

        file.chown uid, gid
        file.chmod mode
        file.fsync
        after = file.stat
        unless [ before.dev, before.ino, before.ftype ] ==
            [ after.dev, after.ino, after.ftype ] && after.nlink == 1 &&
            after.uid == uid && after.gid == gid && (after.mode & 0o777) == mode
          raise "Campfire operation lock descriptor changed during ownership handoff"
        end
      rescue Errno::EPERM => error
        raise "Campfire operation lock ownership handoff to #{uid}:#{gid} failed from " \
          "#{before.uid}:#{before.gid}: #{error.message}"
      end
      assert_current!
      true
    end

    def release
      return unless @file || @shared_file

      if @shared_file
        @shared_file.flock File::LOCK_UN unless @inherited_shared
        @shared_file.close
        @shared_file = nil
      end
      if @file
        @file.flock File::LOCK_UN unless @inherited_file
        @file.close
        @file = nil
      end
      true
    end

    def held?
      (@shared_file && !@shared_file.closed?) || (@file && !@file.closed?)
    end

    def with_inheritable_shared_lock
      raise "Campfire operation lock is not shared" unless @file && @shared_file

      file_close_on_exec = @file.close_on_exec?
      shared_close_on_exec = @shared_file.close_on_exec?
      @file.close_on_exec = false
      @shared_file.close_on_exec = false
      yield({
        LOCK_ROOT_ENV => namespace.to_s,
        INHERITED_FILE_FD_ENV => @file.fileno.to_s,
        INHERITED_SHARED_FD_ENV => @shared_file.fileno.to_s,
        INHERITED_SHARED_TARGET_ENV => directory.to_s,
        INHERITED_LOCK_ROOT_ENV => namespace.to_s
      })
    ensure
      @file.close_on_exec = file_close_on_exec if @file && !@file.closed?
      @shared_file.close_on_exec = shared_close_on_exec if @shared_file && !@shared_file.closed?
    end

    private
      def prepare_canonical_paths!
        @canonical_requested_parent = canonical_future_path(@requested_directory.dirname)
        @canonical_lock_root = @requested_lock_root.realpath
        canonical_target = @canonical_requested_parent.join(@requested_directory.basename)
        parent_is_filesystem_root = @canonical_requested_parent.root?
        if contained_by?(canonical_target, @canonical_lock_root) ||
            (!parent_is_filesystem_root && contained_by?(@canonical_requested_parent, @canonical_lock_root))
          raise "Campfire operation lock root must be outside the target parent"
        end
      rescue Errno::ENOENT
        raise "Campfire operation lock root is not an independent directory"
      end

      def prepare_namespace!
        @namespace = @canonical_lock_root
        unless @namespace.directory? && !@requested_lock_root.symlink?
          raise "Campfire operation lock root is not an independent directory"
        end
        unless @namespace == @requested_lock_root
          raise "Campfire operation lock root must use its canonical path"
        end

        namespace_stat = @namespace.lstat
        private_root = namespace_stat.uid == Process.euid && (namespace_stat.mode & 0o077).zero?
        system_shared_root = namespace_stat.uid.zero? && (namespace_stat.mode & 0o1777) == 0o1777
        unless private_root || system_shared_root
          raise "Campfire operation lock root is not trusted"
        end

        @namespace_identity = identity(@namespace)
        key = Digest::SHA256.hexdigest(@requested_directory.to_s)
        @path = @namespace.join("#{key}.lock")
      end

      def canonical_future_path(path)
        missing = []
        current = path
        until current.exist? || current.symlink?
          missing.unshift current.basename
          current = current.dirname
        end
        missing.reduce(current.realpath) { |resolved, component| resolved.join(component) }
      end

      def contained_by?(container, candidate)
        candidate == container || candidate.to_s.start_with?("#{container}/")
      end

      def acquire_file!
        if path.symlink? || (path.exist? && !path.file?)
          raise "Campfire operation lock path is not a regular file"
        end

        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        @file = File.open(path, flags, 0o600)
        opened = @file.stat
        current = path.lstat
        unless opened.file? && opened.nlink == 1 && current.file? &&
            [ opened.dev, opened.ino ] == [ current.dev, current.ino ]
          raise "Campfire operation lock path changed during acquisition"
        end
        unless @file.flock(File::LOCK_EX | File::LOCK_NB)
          raise "Campfire storage is in use by another process"
        end
      end

      def adopt_file!
        @file = inherited_file(@inherited_file_fd)
        @inherited_file = true
        opened = @file.stat
        current = path.lstat
        unless opened.file? && opened.nlink == 1 && current.file? &&
            [ opened.dev, opened.ino ] == [ current.dev, current.ino ]
          raise "Campfire inherited operation lock does not match its stable target"
        end
        unless @file.flock(File::LOCK_EX | File::LOCK_NB)
          raise "Campfire storage is in use by another process"
        end
      rescue ArgumentError, TypeError, Errno::EBADF
        raise "Campfire inherited operation lock descriptor is invalid"
      end

      def acquire_shared_file!
        @shared_path = directory.join(SHARED_FILENAME)
        if shared_path.symlink? || (shared_path.exist? && !shared_path.file?)
          raise "Campfire shared operation lock path is not a regular file"
        end

        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        @shared_file = File.open(shared_path, flags, 0o600)
        opened = @shared_file.stat
        current = shared_path.lstat
        unless opened.file? && opened.nlink == 1 && current.file? &&
            [ opened.dev, opened.ino ] == [ current.dev, current.ino ]
          raise "Campfire shared operation lock path changed during acquisition"
        end
        unless @shared_file.flock(File::LOCK_EX | File::LOCK_NB)
          raise "Campfire storage is in use by another process"
        end
      end

      def adopt_shared_file!
        raise "Campfire inherited operation lock requires a shared target" unless @shared

        @shared_path = directory.join(SHARED_FILENAME)
        @shared_file = inherited_file(@inherited_shared_fd)
        @inherited_shared = true
        opened = @shared_file.stat
        current = shared_path.lstat
        unless opened.file? && opened.nlink == 1 && current.file? &&
            [ opened.dev, opened.ino ] == [ current.dev, current.ino ]
          raise "Campfire inherited operation lock does not match its shared target"
        end
        unless @shared_file.flock(File::LOCK_EX | File::LOCK_NB)
          raise "Campfire storage is in use by another process"
        end
      rescue ArgumentError, TypeError, Errno::EBADF
        raise "Campfire inherited operation lock descriptor is invalid"
      end

      def inherited_file(descriptor)
        inherited = File.for_fd(Integer(descriptor, 10), autoclose: false)
        inherited.close_on_exec = true
        inherited.dup.tap { _1.close_on_exec = true }
      end

      def prepare_target!
        if directory.exist? || directory.symlink?
          unless directory.directory? && !directory.symlink?
            raise "Campfire operation target is not an independent directory"
          end
        elsif @create
          Dir.mkdir directory, 0o700
          File.open(parent, &:fsync)
        else
          raise "Campfire operation lock directory does not exist: #{directory}"
        end
        @target_identity = identity(directory)
      rescue Errno::EEXIST
        raise "Campfire operation target changed during acquisition"
      end

      def identity(path)
        stat = path.lstat
        [ stat.dev, stat.ino, stat.ftype ].freeze
      end

      def current_identity(path)
        identity(path)
      rescue Errno::ENOENT
        nil
      end

      def write_metadata(file, metadata)
        file.chmod 0o600
        file.rewind
        file.truncate(0)
        file.write metadata
        file.flush
        file.fsync
      end
  end

  class OwnedPaths
    def initialize(root)
      @root = Pathname(root).expand_path
      @entries = {}
    end

    def record(path)
      path = contained_path(path)
      stat = path.lstat
      @entries[path.to_s] = [ stat.dev, stat.ino, stat.ftype ]
      path
    end

    def forget(path)
      @entries.delete Pathname(path).expand_path.to_s
    end

    def owned?(path)
      @entries.key? Pathname(path).expand_path.to_s
    end

    def each_current
      @entries.each do |name, identity|
        path = Pathname(name)
        raise "Operation-owned path disappeared: #{path}" unless path.exist? || path.symlink?

        stat = path.lstat
        unless [ stat.dev, stat.ino, stat.ftype ] == identity
          raise "Operation-owned path changed concurrently: #{path}"
        end
        yield path, stat
      end
    end

    def cleanup
      incomplete = []
      @entries.sort_by { |name, _| -Pathname(name).each_filename.count }.each do |name, identity|
        path = Pathname(name)
        next unless path.exist? || path.symlink?

        stat = path.lstat
        unless [ stat.dev, stat.ino, stat.ftype ] == identity
          incomplete << path
          next
        end

        if stat.directory?
          path.rmdir
        else
          path.unlink
        end
      rescue Errno::ENOTEMPTY, Errno::EEXIST, Errno::EACCES, Errno::EPERM
        incomplete << path
      end
      incomplete
    end

    private
      def contained_path(path)
        path = Pathname(path).expand_path
        unless path.to_s.start_with?("#{@root}/")
          raise "Operation-owned path escaped its destination"
        end
        path
      end
  end
end
