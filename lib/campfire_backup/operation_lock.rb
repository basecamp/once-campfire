require "digest"
require "json"
require "pathname"
require "securerandom"
require "time"
require_relative "descriptor_tree"

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
        create_parent: false, lock_root: self.lock_root, inherited_file_fd: nil,
        inherited_shared_fd: nil)
      new(
        directory, purpose:, create:, shared:, create_parent:, lock_root:, inherited_file_fd:,
        inherited_shared_fd:
      ).tap(&:acquire!)
    end

    def initialize(directory, purpose:, create: true, shared: false, lock_root: self.class.lock_root,
        create_parent: false, inherited_file_fd: nil, inherited_shared_fd: nil)
      @requested_directory = Pathname(directory).expand_path
      @requested_lock_root = Pathname(lock_root).expand_path
      @purpose = purpose
      @create = create
      @create_parent = create_parent
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

      requested_parent = prepare_requested_parent!
      unless requested_parent.directory? && !requested_parent.symlink?
        raise "Campfire operation lock parent is not an independent directory"
      end

      @parent = requested_parent.realpath
      unless @parent == @canonical_requested_parent
        raise "Campfire operation lock parent changed during acquisition"
      end
      if @canonical_requested_parent_identity &&
          identity(@parent) != @canonical_requested_parent_identity
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
      @namespace_tree.flush_root
      @target_tree.flush_root if @shared_file
      assert_current!
      self
    rescue Errno::EACCES, Errno::EAGAIN
      close_resources
      raise "Campfire storage is in use by another process"
    rescue StandardError
      close_resources
      raise
    end

    def assert_current!
      unless current_identity(parent) == @parent_identity
        raise "Campfire operation lock parent changed while locked"
      end
      if @namespace && current_identity(@namespace) != @namespace_identity
        raise "Campfire operation lock parent changed while locked"
      end
      @namespace_tree&.assert_root_current!
      unless current_identity(directory) == @target_identity
        raise "Campfire operation target changed while locked"
      end

      if @file
        opened = @file.stat
        @namespace_tree.open_regular_file(
          path.basename.to_s,
          expected_identity: [ opened.dev, opened.ino, opened.ftype ]
        ) do |_current, current|
          unless opened.file? && opened.nlink == 1 && current.file? && current.nlink == 1
            raise "Campfire operation lock path changed while locked"
          end
        end
      end
      if @shared_file
        shared_opened = @shared_file.stat
        @target_tree.open_regular_file(
          SHARED_FILENAME,
          expected_identity: [ shared_opened.dev, shared_opened.ino, shared_opened.ftype ]
        ) do |_current, shared_current|
          unless shared_opened.file? && shared_opened.nlink == 1 && shared_current.file?
            raise "Campfire shared operation lock path changed while locked"
          end
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
      return unless @file || @shared_file || @target_tree || @namespace_tree

      errors = []
      close_lock_file(@shared_file, inherited: @inherited_shared, errors:)
      @shared_file = nil
      close_lock_file(@file, inherited: @inherited_file, errors:)
      @file = nil
      close_resource(@target_tree, errors:)
      @target_tree = nil
      close_resource(@namespace_tree, errors:)
      @namespace_tree = nil
      raise errors.first if errors.any?

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
        @canonical_target = @canonical_requested_parent.join(@requested_directory.basename)
        if @canonical_requested_parent.exist?
          @canonical_requested_parent_identity = identity(@canonical_requested_parent)
        end
        parent_is_filesystem_root = @canonical_requested_parent.root?
        if contained_by?(@canonical_target, @canonical_lock_root) ||
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
        @namespace_tree = DescriptorTree.new(
          @namespace, expected_identity: @namespace_identity,
          description: "Campfire operation lock root"
        )
        key = Digest::SHA256.hexdigest(@canonical_target.to_s)
        @path = @namespace.join("#{key}.lock")
      end

      def prepare_requested_parent!
        requested_parent = @requested_directory.dirname
        return requested_parent if requested_parent.exist? || requested_parent.symlink?

        unless @create && @create_parent
          raise "Campfire operation lock parent is not an independent directory"
        end

        requested_grandparent = requested_parent.dirname
        unless requested_grandparent.directory? && !requested_grandparent.symlink?
          raise "Campfire operation lock parent is not an independent directory"
        end
        canonical_grandparent = requested_grandparent.realpath
        unless canonical_grandparent.join(requested_parent.basename) == @canonical_requested_parent
          raise "Campfire operation lock parent changed during acquisition"
        end

        grandparent_tree = DescriptorTree.new(
          canonical_grandparent, description: "Campfire operation target grandparent"
        )
        grandparent_tree.mkdir(requested_parent.basename.to_s, mode: 0o700)
        grandparent_tree.flush_root
        requested_parent
      rescue Errno::EEXIST
        raise "Campfire operation lock parent changed during acquisition"
      ensure
        grandparent_tree&.close
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
        @namespace_tree.open_or_create_regular_file(path.basename.to_s, mode: 0o600) do |file, opened|
          unless opened.file? && opened.nlink == 1
            raise "Campfire operation lock path is not a regular file"
          end
          @file = file.dup
          @file.close_on_exec = true
        end
        unless @file.flock(File::LOCK_EX | File::LOCK_NB)
          raise "Campfire storage is in use by another process"
        end
      end

      def adopt_file!
        @file = inherited_file(@inherited_file_fd)
        @inherited_file = true
        opened = @file.stat
        @namespace_tree.open_regular_file(
          path.basename.to_s,
          expected_identity: [ opened.dev, opened.ino, opened.ftype ]
        ) do |_file, current|
          unless opened.file? && opened.nlink == 1 && current.file? && current.nlink == 1
            raise "Campfire inherited operation lock does not match its stable target"
          end
        end
        unless @file.flock(File::LOCK_EX | File::LOCK_NB)
          raise "Campfire storage is in use by another process"
        end
      rescue ArgumentError, TypeError, Errno::EBADF
        raise "Campfire inherited operation lock descriptor is invalid"
      end

      def acquire_shared_file!
        @shared_path = directory.join(SHARED_FILENAME)
        @target_tree.open_or_create_regular_file(SHARED_FILENAME, mode: 0o600) do |file, opened|
          unless opened.file? && opened.nlink == 1
            raise "Campfire shared operation lock path is not a regular file"
          end
          @shared_file = file.dup
          @shared_file.close_on_exec = true
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
        @target_tree.open_regular_file(
          SHARED_FILENAME, expected_identity: [ opened.dev, opened.ino, opened.ftype ]
        ) do |_file, current|
          unless opened.file? && opened.nlink == 1 && current.file?
            raise "Campfire inherited operation lock does not match its shared target"
          end
        end
        unless @shared_file.flock(File::LOCK_EX | File::LOCK_NB)
          raise "Campfire storage is in use by another process"
        end
      rescue ArgumentError, TypeError, Errno::EBADF
        raise "Campfire inherited operation lock descriptor is invalid"
      end

      def inherited_file(descriptor)
        descriptor = Integer(descriptor, 10) unless descriptor.is_a?(Integer)
        inherited = File.for_fd(descriptor, autoclose: false)
        inherited.close_on_exec = true
        inherited.dup.tap { _1.close_on_exec = true }
      end

      def prepare_target!
        parent_tree = DescriptorTree.new(
          parent, expected_identity: @parent_identity,
          description: "Campfire operation target parent"
        )
        name = directory.basename.to_s
        if parent_tree.entry_missing?(name)
          unless @create
            raise "Campfire operation lock directory does not exist: #{directory}"
          end
          parent_tree.mkdir(name, mode: 0o700)
          parent_tree.flush_root
        end
        parent_tree.open_directory(name) do |_target, stat|
          @target_identity = [ stat.dev, stat.ino, stat.ftype ].freeze
        end
        @target_tree = DescriptorTree.new(
          directory, expected_identity: @target_identity,
          description: "Campfire operation target"
        )
      rescue Errno::EEXIST
        raise "Campfire operation target changed during acquisition"
      ensure
        parent_tree&.close
      end

      def close_resources
        errors = []
        close_resource(@shared_file, errors:)
        @shared_file = nil
        close_resource(@file, errors:)
        @file = nil
        close_resource(@target_tree, errors:)
        @target_tree = nil
        close_resource(@namespace_tree, errors:)
        @namespace_tree = nil
        errors
      end

      def close_lock_file(file, inherited:, errors:)
        return unless file

        begin
          file.flock File::LOCK_UN unless inherited
        rescue StandardError => error
          errors << error
        ensure
          close_resource(file, errors:)
        end
      end

      def close_resource(resource, errors:)
        return unless resource

        resource.close unless resource.respond_to?(:closed?) && resource.closed?
      rescue StandardError => error
        errors << error
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
    def initialize(root, descriptor_tree: nil)
      @root = Pathname(root).expand_path
      @descriptor_tree = descriptor_tree
      @entries = {}
    end

    def record(path, stat: nil)
      path = contained_path(path)
      stat ||= if @descriptor_tree
        @descriptor_tree.open_entry(relative_path(path)) { |_file, opened| opened }
      else
        path.lstat
      end
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
        if @descriptor_tree
          @descriptor_tree.open_entry(relative_path(path), expected_identity: identity) do |file, stat|
            assert_independent_metadata_target! path, stat
            yield path, stat, file
          end
        else
          raise "Operation-owned path disappeared: #{path}" unless path.exist? || path.symlink?

          stat = path.lstat
          unless [ stat.dev, stat.ino, stat.ftype ] == identity
            raise "Operation-owned path changed concurrently: #{path}"
          end
          assert_independent_metadata_target! path, stat
          yield path, stat
        end
      end
    end

    def cleanup
      incomplete = []
      @entries.sort_by { |name, _| -Pathname(name).each_filename.count }.each do |name, identity|
        path = Pathname(name)
        if @descriptor_tree
          @descriptor_tree.remove(
            relative_path(path), expected_identity: identity, directory: identity.last == "directory"
          )
          next
        end
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
      rescue RuntimeError, SystemCallError
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

      def relative_path(path)
        path.relative_path_from(@root).to_s
      end

      def assert_independent_metadata_target!(path, stat)
        unless stat.directory? || (stat.file? && stat.nlink == 1)
          raise "Operation-owned path is not safe for metadata mutation: #{path}"
        end
      end
  end
end
