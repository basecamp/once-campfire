require "test_helper"
require "rbconfig"
require "tmpdir"
require "campfire_backup/redis_validator"

class CampfireBackup::RedisValidatorTest < ActiveSupport::TestCase
  setup do
    CampfireBackup::RedisValidator.stubs(:redis_server_executable).returns(nil)
  end

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

  test "rejects an RDB-only layout that the configured Redis would ignore" do
    with_payload do |payload|
      rdb = payload.join("redis", "dump.rdb")
      rdb.dirname.mkpath
      rdb.write "structurally valid but not loadable under appendonly yes"
      CampfireBackup::Subprocess.expects(:capture3).never

      error = assert_raises(RuntimeError) { CampfireBackup::RedisValidator.validate!(payload) }

      assert_match "requires AOF persistence", error.message
    end
  end

  test "requires AOF persistence for current-format backups" do
    with_payload do |payload|
      error = assert_raises(RuntimeError) do
        CampfireBackup::RedisValidator.validate!(payload, require_aof: true)
      end
      assert_match "missing required AOF", error.message

      payload.join("redis").mkpath
      error = assert_raises(RuntimeError) do
        CampfireBackup::RedisValidator.validate!(payload, require_aof: true)
      end
      assert_match "missing required AOF", error.message
    end
  end

  test "rejects required AOF validation when target redis-server is unavailable" do
    with_payload do |payload|
      aof = payload.join("redis", "appendonly.aof")
      aof.dirname.mkpath
      aof.write("valid AOF bytes")
      status = stub(success?: true)
      CampfireBackup::Subprocess.expects(:capture3)
        .with("redis-check-aof", aof.to_s)
        .returns([ "valid", "", status ])
      CampfireBackup::RedisValidator.expects(:redis_server_executable).returns(nil)

      error = assert_raises(RuntimeError) do
        CampfireBackup::RedisValidator.validate!(payload, require_aof: true)
      end

      assert_match "requires redis-server for target replay", error.message
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

  test "preserves manifest file type and sequence" do
    entry = CampfireBackup::RedisValidator.send(
      :parse_manifest_entry!,
      "file appendonly.aof.17.incr.aof seq 17 type i startoffset 4 endoffset 92\n"
    )

    assert_equal "appendonly.aof.17.incr.aof", entry.filename
    assert_equal 17, entry.sequence
    assert_equal "i", entry.type
    assert_raises(RuntimeError) do
      CampfireBackup::RedisValidator.send(
        :parse_manifest_entry!,
        "file appendonly.aof.overflow.incr.aof seq 9223372036854775808 type i\n"
      )
    end
  end

  test "rejects malformed multi-part AOF type and sequence ordering" do
    manifests = {
      multiple_base: [
        "file appendonly.aof.1.base.rdb seq 1 type b\n",
        "file appendonly.aof.2.base.rdb seq 2 type b\n"
      ],
      type_order: [
        "file appendonly.aof.2.incr.aof seq 2 type i\n",
        "file appendonly.aof.1.history.aof seq 1 type h\n"
      ],
      sequence_order: [
        "file appendonly.aof.2.incr.aof seq 2 type i\n",
        "file appendonly.aof.1.incr.aof seq 1 type i\n"
      ]
    }

    manifests.each do |name, lines|
      with_payload do |payload|
        directory = payload.join("redis", "appendonlydir").tap(&:mkpath)
        directory.join("appendonly.aof.manifest").write(lines.join)

        error = assert_raises(RuntimeError) { CampfireBackup::RedisValidator.validate!(payload) }

        assert_match(/multiple base|out of order|non-monotonic/, error.message, name.to_s)
      end
    end
  end

  test "rejects a history-only multi-part AOF manifest" do
    [ false, true ].each do |require_aof|
      with_payload do |payload|
        directory = payload.join("redis", "appendonlydir").tap(&:mkpath)
        directory.join("appendonly.aof.manifest").write(
          "file appendonly.aof.1.history.aof seq 1 type h\n"
        )
        directory.join("appendonly.aof.1.history.aof").write("ignored history")
        CampfireBackup::Subprocess.expects(:capture3).never

        error = assert_raises(RuntimeError) do
          CampfireBackup::RedisValidator.validate!(payload, require_aof:)
        end

        assert_match "only history files", error.message
      end
    end
  end

  test "rejects target-server replay failure without changing the source AOF" do
    with_payload do |payload|
      aof = payload.join("redis", "appendonly.aof")
      aof.dirname.mkpath
      aof.write("source AOF bytes")
      before = aof.binread
      status = stub(success?: true)
      CampfireBackup::Subprocess.expects(:capture3)
        .with("redis-check-aof", aof.to_s)
        .returns([ "valid", "", status ])

      fake_server = payload.dirname.join("redis-server")
      fake_server.write <<~RUBY
        #!#{RbConfig.ruby}
        directory = ARGV.fetch(ARGV.index("--dir") + 1)
        File.binwrite(File.join(directory, "appendonly.aof"), "mutated replay copy")
        warn "simulated target replay failure"
        exit 1
      RUBY
      File.chmod 0o700, fake_server
      CampfireBackup::RedisValidator.stubs(:redis_server_executable).returns(fake_server.to_s)

      error = assert_raises(RuntimeError) do
        CampfireBackup::RedisValidator.validate!(payload, require_aof: true)
      end

      assert_match "target-server replay failed", error.message
      assert_match "simulated target replay failure", error.message
      assert_equal before, aof.binread
    end
  end

  test "accepts a successful target-server replay on a disposable copy" do
    with_payload do |payload|
      aof = payload.join("redis", "appendonly.aof")
      aof.dirname.mkpath
      aof.write("source AOF bytes")
      status = stub(success?: true)
      CampfireBackup::Subprocess.expects(:capture3)
        .with("redis-check-aof", aof.to_s)
        .returns([ "valid", "", status ])

      fake_server = payload.dirname.join("redis-server")
      fake_server.write <<~RUBY
        #!#{RbConfig.ruby}
        require "socket"
        directory = ARGV.fetch(ARGV.index("--dir") + 1)
        socket_path = ARGV.fetch(ARGV.index("--unixsocket") + 1)
        abort "missing fail-fast options: \#{ARGV.inspect}" unless
          ARGV.include?("--aof-load-truncated") && ARGV.include?("--propagation-error-behavior")
        File.binwrite(File.join(directory, "appendonly.aof"), "replayed copy")
        server = UNIXServer.new(socket_path)
        client = server.accept
        request = client.read(14)
        crlf = 13.chr + 10.chr
        expected = [ "*1", "$" + "4", "PING", "" ].join(crlf)
        abort "unexpected request: \#{request.inspect}" unless request == expected
        client.write "+PONG" + crlf
        sleep
      RUBY
      File.chmod 0o700, fake_server
      CampfireBackup::RedisValidator.stubs(:redis_server_executable).returns(fake_server.to_s)

      assert_nil CampfireBackup::RedisValidator.validate!(payload, require_aof: true)
      assert_equal "source AOF bytes", aof.binread
    end
  end

  test "Redis configuration fails fast on AOF truncation and replay errors" do
    configuration = Rails.root.join("config/redis.conf").read.lines.map(&:strip)

    assert_includes configuration, "aof-load-truncated no"
    assert_includes configuration, "propagation-error-behavior panic"
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
