require "test_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "campfire_backup/operation_lock"

class OperationLockTest < ActiveSupport::TestCase
  test "a separate process cannot acquire the same persistent lock" do
    Dir.mktmpdir("campfire-operation-lock") do |directory|
      target = Pathname(directory).join("target").tap(&:mkpath)
      ready_reader, ready_writer = IO.pipe
      release_reader, release_writer = IO.pipe
      child = fork do
        ready_reader.close
        release_writer.close
        lock = CampfireBackup::OperationLock.acquire(target, purpose: "child")
        ready_writer.write "locked"
        ready_writer.close
        release_reader.read(1)
        lock.release
        exit! 0
      rescue StandardError => error
        warn error.full_message
        exit! 1
      end
      ready_writer.close
      release_reader.close

      assert_equal "locked", ready_reader.read(6)
      error = assert_raises(RuntimeError) do
        CampfireBackup::OperationLock.acquire(target, purpose: "parent")
      end
      assert_match "in use by another process", error.message

      release_writer.write "."
      release_writer.close
      Process.wait child
      assert_predicate $?, :success?
      assert_empty target.children
      lock = CampfireBackup::OperationLock.acquire(target, purpose: "parent-after-release")
      assert_equal CampfireBackup::OperationLock.lock_root.realpath, lock.namespace
      assert lock.release
    ensure
      ready_reader&.close unless ready_reader&.closed?
      ready_writer&.close unless ready_writer&.closed?
      release_reader&.close unless release_reader&.closed?
      release_writer&.close unless release_writer&.closed?
      if child
        begin
          Process.kill "KILL", child
        rescue Errno::ESRCH
          nil
        end
        begin
          Process.wait child
        rescue Errno::ECHILD
          nil
        end
      end
    end
  end

  test "cleanup preserves a concurrently replaced inode" do
    Dir.mktmpdir("campfire-owned-path") do |directory|
      root = Pathname(directory)
      target = root.join("target").tap { _1.write "owned" }
      paths = CampfireBackup::OwnedPaths.new(root)
      paths.record target
      replacement = root.join("replacement").tap { _1.write "concurrent" }
      File.rename replacement, target

      assert_equal [ target ], paths.cleanup
      assert_equal "concurrent", target.read
    end
  end

  test "a hard-linked lock path is rejected without modifying its other name" do
    Dir.mktmpdir("campfire-operation-hardlink") do |directory|
      root = Pathname(directory)
      target = root.join("target").tap(&:mkpath)
      initial = CampfireBackup::OperationLock.acquire(target, purpose: "initial")
      lock_path = initial.path
      initial.release
      lock_path.unlink
      outside = root.join("outside").tap { _1.write "preserve" }
      File.link outside, lock_path

      assert_raises(RuntimeError) do
        CampfireBackup::OperationLock.acquire(target, purpose: "test")
      end
      assert_equal "preserve", outside.read
    end
  end

  test "a shared-volume lock held outside the parent namespace blocks acquisition" do
    Dir.mktmpdir("campfire-operation-shared") do |directory|
      target = Pathname(directory).join("target").tap(&:mkpath)
      shared_path = target.join(CampfireBackup::OperationLock::SHARED_FILENAME)
      File.open(shared_path, File::RDWR | File::CREAT, 0o600) do |shared_file|
        assert shared_file.flock(File::LOCK_EX | File::LOCK_NB)

        error = assert_raises(RuntimeError) do
          CampfireBackup::OperationLock.acquire(target, purpose: "shared", shared: true)
        end
        assert_match "in use by another process", error.message
      end

      lock = CampfireBackup::OperationLock.acquire(target, purpose: "shared", shared: true)
      assert_equal shared_path.realpath, lock.shared_path.realpath
      assert shared_path.file?
      lock.release
    end
  end

  test "shared locking fails closed without the configured stable root" do
    Dir.mktmpdir("campfire-operation-shared-domain") do |directory|
      root = Pathname(directory)
      target = root.join("target").tap(&:mkpath)

      error = assert_raises(RuntimeError) do
        CampfireBackup::OperationLock.acquire(
          target, purpose: "shared", shared: true,
          lock_root: Pathname("#{directory}-missing-lock-root")
        )
      end

      assert_match "lock root is not an independent directory", error.message
      assert_empty target.children
    end
  end

  test "there is no implicit operation lock root" do
    error = assert_raises(RuntimeError) do
      CampfireBackup::OperationLock.lock_root({})
    end

    assert_match "CAMPFIRE_OPERATION_LOCK_ROOT is required", error.message
  end

  test "the stable root cannot move with the target parent" do
    Dir.mktmpdir("campfire-operation-parent-root") do |directory|
      parent = Pathname(directory).join("parent").tap(&:mkpath)
      lock_root = parent.join("locks").tap(&:mkpath)

      error = assert_raises(RuntimeError) do
        CampfireBackup::OperationLock.acquire(
          parent.join("target"), purpose: "test", lock_root:
        )
      end

      assert_match "must be outside the target parent", error.message
    end
  end

  test "a symlinked target ancestor cannot hide the physical lock root inside its parent" do
    Dir.mktmpdir("campfire-operation-symlink-containment") do |directory|
      root = Pathname(directory)
      physical_ancestor = root.join("physical-ancestor").tap(&:mkpath)
      physical_parent = physical_ancestor.join("parent").tap(&:mkpath)
      lock_root = physical_parent.join("locks").tap(&:mkpath)
      File.chmod 0o700, lock_root
      alias_ancestor = root.join("alias-ancestor")
      File.symlink physical_ancestor, alias_ancestor

      error = assert_raises(RuntimeError) do
        CampfireBackup::OperationLock.acquire(
          alias_ancestor.join("parent/target"), purpose: "test", lock_root:
        )
      end

      assert_match "must be outside the target parent", error.message
    end
  end

  test "a symlinked lock-root ancestor cannot hide its physical location inside the target parent" do
    Dir.mktmpdir("campfire-operation-lock-root-containment") do |directory|
      root = Pathname(directory)
      physical_parent = root.join("physical-parent").tap(&:mkpath)
      physical_parent.join("target").mkpath
      physical_parent.join("locks").mkpath
      alias_parent = root.join("alias-parent")
      File.symlink physical_parent, alias_parent

      error = assert_raises(RuntimeError) do
        CampfireBackup::OperationLock.acquire(
          physical_parent.join("target"), purpose: "test", lock_root: alias_parent.join("locks")
        )
      end

      assert_match "must be outside the target parent", error.message
    end
  end

  test "a symlinked ancestor rename cannot create a second lock domain" do
    Dir.mktmpdir("campfire-operation-symlink-replacement") do |directory|
      root = Pathname(directory).realpath
      physical_ancestor = root.join("physical-ancestor").tap(&:mkpath)
      physical_parent = physical_ancestor.join("parent").tap(&:mkpath)
      target = physical_parent.join("target").tap(&:mkpath)
      alias_ancestor = root.join("alias-ancestor")
      File.symlink physical_ancestor, alias_ancestor
      requested_target = alias_ancestor.join("parent/target")
      lock_root = root.join("locks").tap(&:mkpath)
      File.chmod 0o700, lock_root
      lock = CampfireBackup::OperationLock.acquire(
        requested_target, purpose: "original", lock_root:
      )
      File.rename physical_ancestor, root.join("original-ancestor")
      root.join("physical-ancestor/parent/target").mkpath

      error = assert_raises(RuntimeError) { lock.assert_current! }
      assert_match "parent changed", error.message
      script = <<~'RUBY'
        require "campfire_backup/operation_lock"
        CampfireBackup::OperationLock.acquire(ARGV.fetch(0), purpose: "replacement")
      RUBY
      _stdout, stderr, status = Open3.capture3(
        { CampfireBackup::OperationLock::LOCK_ROOT_ENV => lock_root.to_s },
        RbConfig.ruby, "-I#{Rails.root.join('lib')}", "-e", script, requested_target.to_s
      )

      assert_not status.success?
      assert_match "in use by another process", stderr
    ensure
      lock&.release
    end
  end

  test "a separate process contends on the shared target inode" do
    Dir.mktmpdir("campfire-operation-shared-process") do |directory|
      target = Pathname(directory).join("target").tap(&:mkpath)
      ready_reader, ready_writer = IO.pipe
      release_reader, release_writer = IO.pipe
      child = fork do
        ready_reader.close
        release_writer.close
        lock = CampfireBackup::OperationLock.acquire(target, purpose: "child", shared: true)
        ready_writer.write "locked"
        ready_writer.close
        release_reader.read(1)
        lock.release
        exit! 0
      rescue StandardError => error
        warn error.full_message
        exit! 1
      end
      ready_writer.close
      release_reader.close

      assert_equal "locked", ready_reader.read(6)
      error = assert_raises(RuntimeError) do
        CampfireBackup::OperationLock.acquire(target, purpose: "parent", shared: true)
      end
      assert_match "in use by another process", error.message

      release_writer.write "."
      release_writer.close
      Process.wait child
      assert_predicate $?, :success?
    ensure
      ready_reader&.close unless ready_reader&.closed?
      ready_writer&.close unless ready_writer&.closed?
      release_reader&.close unless release_reader&.closed?
      release_writer&.close unless release_writer&.closed?
      if child
        begin
          Process.kill "KILL", child
        rescue Errno::ESRCH
          nil
        end
        begin
          Process.wait child
        rescue Errno::ECHILD
          nil
        end
      end
    end
  end

  test "a child process can adopt the inherited shared lock without a release gap" do
    Dir.mktmpdir("campfire-operation-inherited") do |directory|
      target = Pathname(directory).join("target").tap(&:mkpath)
      lock = CampfireBackup::OperationLock.acquire(target, purpose: "parent", shared: true)
      script = <<~'RUBY'
        require "campfire_backup/operation_lock"
        2.times do |attempt|
          file_descriptor = ENV.fetch(CampfireBackup::OperationLock::INHERITED_FILE_FD_ENV)
          shared_descriptor = ENV.fetch(CampfireBackup::OperationLock::INHERITED_SHARED_FD_ENV)
          if attempt == 1
            file_descriptor = Integer(file_descriptor, 10)
            shared_descriptor = Integer(shared_descriptor, 10)
          end
          lock = CampfireBackup::OperationLock.acquire(
            ARGV.fetch(0), purpose: "child", shared: true,
            inherited_file_fd: file_descriptor,
            inherited_shared_fd: shared_descriptor
          )
          lock.assert_current!
          lock.release
        end
      RUBY

      _stdout, stderr, status = lock.with_inheritable_shared_lock do |environment|
        Open3.capture3(
          environment, RbConfig.ruby, "-I#{Rails.root.join('lib')}", "-e", script,
          target.to_s, close_others: false
        )
      end

      assert_predicate status, :success?, stderr
      assert lock.assert_current!
      assert_raises(RuntimeError) do
        CampfireBackup::OperationLock.acquire(target, purpose: "contender", shared: true)
      end
    ensure
      lock&.release
    end
  end

  test "a hard-linked shared-volume lock is rejected without modifying its peer" do
    Dir.mktmpdir("campfire-operation-shared-hardlink") do |directory|
      root = Pathname(directory)
      target = root.join("target").tap(&:mkpath)
      outside = root.join("outside").tap { _1.write "preserve" }
      File.link outside, target.join(CampfireBackup::OperationLock::SHARED_FILENAME)

      assert_raises(RuntimeError) do
        CampfireBackup::OperationLock.acquire(target, purpose: "shared", shared: true)
      end
      assert_equal "preserve", outside.read
    end
  end

  test "target replacement is detected and cannot create a second process lock domain" do
    Dir.mktmpdir("campfire-operation-replacement") do |directory|
      root = Pathname(directory)
      target = root.join("target").tap(&:mkpath)
      original = root.join("original-target")
      lock = CampfireBackup::OperationLock.acquire(target, purpose: "original")
      File.rename target, original
      target.mkpath

      error = assert_raises(RuntimeError) { lock.assert_current! }
      assert_match "target changed", error.message

      script = <<~'RUBY'
        require "campfire_backup/operation_lock"
        CampfireBackup::OperationLock.acquire(ARGV.fetch(0), purpose: "replacement")
      RUBY
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "-I#{Rails.root.join('lib')}", "-e", script, target.to_s
      )
      assert_not status.success?
      assert_match "in use by another process", stderr
    ensure
      lock&.release
    end
  end

  test "parent replacement is detected" do
    Dir.mktmpdir("campfire-operation-parent-replacement") do |directory|
      root = Pathname(directory)
      parent = root.join("parent").tap(&:mkpath)
      target = parent.join("target").tap(&:mkpath)
      lock = CampfireBackup::OperationLock.acquire(target, purpose: "original")
      File.rename parent, root.join("original-parent")
      root.join("parent/target").mkpath

      error = assert_raises(RuntimeError) { lock.assert_current! }
      assert_match "parent changed", error.message

      script = <<~'RUBY'
        require "campfire_backup/operation_lock"
        CampfireBackup::OperationLock.acquire(ARGV.fetch(0), purpose: "replacement")
      RUBY
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "-I#{Rails.root.join('lib')}", "-e", script, root.join("parent/target").to_s
      )
      assert_not status.success?
      assert_match "in use by another process", stderr
    ensure
      lock&.release
    end
  end

  test "cleanup preserves an unknown file created inside an owned directory" do
    Dir.mktmpdir("campfire-owned-directory") do |directory|
      root = Pathname(directory)
      owned_directory = root.join("owned").tap(&:mkpath)
      paths = CampfireBackup::OwnedPaths.new(root)
      paths.record owned_directory
      unknown = owned_directory.join("unknown").tap { _1.write "concurrent" }

      assert_equal [ owned_directory ], paths.cleanup
      assert_equal "concurrent", unknown.read
    end
  end
end
