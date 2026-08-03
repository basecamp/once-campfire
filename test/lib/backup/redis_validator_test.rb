require "test_helper"
require "tmpdir"
require "campfire_backup/redis_validator"

class CampfireBackup::RedisValidatorTest < ActiveSupport::TestCase
  test "checks a copied multi-part AOF manifest" do
    with_payload do |payload|
      manifest = payload.join("redis", "appendonlydir", "appendonly.aof.manifest")
      manifest.dirname.mkpath
      manifest.write "file appendonly.aof.1.incr.aof seq 1 type i startoffset 0 endoffset 123\n"
      manifest.dirname.join("appendonly.aof.1.incr.aof").write "valid"
      status = stub(success?: true)
      CampfireBackup::Subprocess.expects(:capture3)
        .with("redis-check-aof", regexp_matches(/appendonly\.aof\.manifest\z/))
        .returns([ "valid", "", status ])

      assert_nil CampfireBackup::RedisValidator.validate!(payload)
    end
  end

  test "checks read-only multi-part AOF files through a writable copy" do
    with_payload do |payload|
      directory = payload.join("redis", "appendonlydir").tap(&:mkpath)
      manifest = directory.join("appendonly.aof.manifest")
      aof = directory.join("appendonly.aof.1.incr.aof")
      manifest.write "file appendonly.aof.1.incr.aof seq 1 type i\n"
      aof.write "valid bytes"
      File.chmod 0o400, manifest
      File.chmod 0o400, aof
      status = stub(success?: true)
      CampfireBackup::Subprocess.expects(:capture3).with do |command, candidate|
        candidate = Pathname(candidate)
        command == "redis-check-aof" && candidate != manifest &&
          candidate.read == manifest.read &&
          candidate.dirname.join(aof.basename).read == aof.read
      end.returns([ "valid", "", status ])

      assert_nil CampfireBackup::RedisValidator.validate!(payload)
      assert_equal "valid bytes", aof.read
    end
  end

  test "rejects invalid Redis persistence" do
    with_payload do |payload|
      aof = payload.join("redis", "appendonly.aof")
      aof.dirname.mkpath
      aof.write "not an AOF"
      status = stub(success?: false)
      CampfireBackup::Subprocess.stubs(:capture3).returns([ "", "invalid AOF", status ])

      error = assert_raises(RuntimeError) { CampfireBackup::RedisValidator.validate!(payload) }

      assert_match "invalid AOF", error.message
    end
  end

  test "rejects orphaned multi-part AOF files" do
    with_payload do |payload|
      directory = payload.join("redis", "appendonlydir").tap(&:mkpath)
      directory.join("appendonly.aof.manifest").write "file appendonly.aof.1.incr.aof seq 1 type i\n"
      directory.join("appendonly.aof.1.incr.aof").write "valid bytes"
      directory.join("orphan.aof").write "unreferenced bytes"

      error = assert_raises(RuntimeError) { CampfireBackup::RedisValidator.validate!(payload) }

      assert_match "orphaned", error.message
    end
  end

  test "rejects incomplete multi-part AOF offsets" do
    with_payload do |payload|
      directory = payload.join("redis", "appendonlydir").tap(&:mkpath)
      directory.join("appendonly.aof.manifest").write(
        "file appendonly.aof.1.incr.aof seq 1 type i endoffset 123\n"
      )
      directory.join("appendonly.aof.1.incr.aof").write "valid bytes"

      error = assert_raises(RuntimeError) { CampfireBackup::RedisValidator.validate!(payload) }

      assert_match "invalid AOF manifest entry", error.message
    end
  end

  test "rejects a multi-part directory without its manifest" do
    with_payload do |payload|
      directory = payload.join("redis", "appendonlydir").tap(&:mkpath)
      directory.join("appendonly.aof.1.incr.aof").write "bytes"

      assert_raises(RuntimeError) { CampfireBackup::RedisValidator.validate!(payload) }
    end
  end

  test "rejects wrong node types at reserved Redis paths" do
    with_payload do |payload|
      payload.join("redis").write "not a directory"
      assert_raises(RuntimeError) { CampfireBackup::RedisValidator.validate!(payload) }
    end

    %w[ appendonly.aof dump.rdb ].each do |name|
      with_payload do |payload|
        payload.join("redis", name).mkpath
        assert_raises(RuntimeError) { CampfireBackup::RedisValidator.validate!(payload) }
      end
    end

    with_payload do |payload|
      redis = payload.join("redis").tap(&:mkpath)
      redis.join("appendonlydir").write "not a directory"
      assert_raises(RuntimeError) { CampfireBackup::RedisValidator.validate!(payload) }
    end
  end

  test "rejects symbolic links at reserved Redis paths" do
    with_payload do |payload|
      target = payload.join("redis-target").tap(&:mkpath)
      payload.join("redis").make_symlink(target)
      assert_raises(RuntimeError) { CampfireBackup::RedisValidator.validate!(payload) }
    end

    with_payload do |payload|
      directory = payload.join("redis", "appendonlydir").tap(&:mkpath)
      target = payload.join("manifest-target").tap { _1.write "" }
      directory.join("appendonly.aof.manifest").make_symlink(target)
      error = assert_raises(RuntimeError) { CampfireBackup::RedisValidator.validate!(payload) }
      assert_match "loadable manifest", error.message
    end

    with_payload do |payload|
      directory = payload.join("redis", "appendonlydir").tap(&:mkpath)
      directory.join("appendonly.aof.manifest").write "file appendonly.aof.1.incr.aof seq 1 type i\n"
      target = payload.join("aof-target").tap { _1.write "valid" }
      directory.join("appendonly.aof.1.incr.aof").make_symlink(target)
      CampfireBackup::Subprocess.expects(:capture3).never

      error = assert_raises(RuntimeError) { CampfireBackup::RedisValidator.validate!(payload) }
      assert_match "links", error.message
    end
  end

  private
    def with_payload
      Dir.mktmpdir("campfire-redis-validator") do |directory|
        yield Pathname(directory).join("payload").tap(&:mkpath)
      end
    end
end
