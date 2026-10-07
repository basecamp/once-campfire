require "test_helper"
require "tmpdir"

class ResponseCacheTest < ActiveSupport::TestCase
  setup do
    @directory = Dir.mktmpdir
    @database = File.join(@directory, "cache.sqlite3")
    SQLite3::Database.new(@database) do |database|
      database.execute("PRAGMA journal_mode=WAL")
      database.execute("CREATE TABLE values_for_test (value TEXT)")
    end
    ActiveRecord::Base.stubs(:connection_db_config).returns(Struct.new(:database).new(@database))
    @cache = ResponseCache.new
    @cache.stubs(:budget).returns(1024)
  end

  teardown do
    @cache.clear
    FileUtils.remove_entry(@directory)
  end

  test "foreign commits expire entries and reject old render admission" do
    version = @cache.version
    @cache.write("page", version, entry("first"))
    assert_equal "first", @cache.read("page", version)[:body]
    SQLite3::Database.new(@database) { |database| database.execute("INSERT INTO values_for_test VALUES ('committed')") }
    assert_nil @cache.read("page", version)
    @cache.write("page", version, entry("old in-flight render"))
    assert_nil @cache.read("page", @cache.version)
    @cache.write("page", @cache.version, entry("fresh"))
    assert_equal "fresh", @cache.read("page", @cache.version)[:body]
  end

  test "byte budget evicts oldest and bypasses oversized entries and keys" do
    version = @cache.version
    @cache.stubs(:budget).returns(512)
    @cache.write("first", version, entry("a" * 100))
    @cache.write("second", version, entry("b" * 100))
    assert_nil @cache.read("first", version)
    assert_equal "b" * 100, @cache.read("second", version)[:body]
    @cache.write("oversized", version, entry("c" * 1000))
    assert_nil @cache.read("oversized", version)
    @cache.write("k" * 2049, version, entry("small"))
    assert_nil @cache.read("k" * 2049, version)
  end

  test "clearing the observer gives later pages a distinct namespace" do
    version = @cache.version
    @cache.clear
    assert_not_equal version, @cache.version
  end

  test "cold renders coalesce without holding the observer mutex" do
    version = @cache.version
    entered = Queue.new
    release = Queue.new
    first = Thread.new do
      @cache.synchronize_render("page", version) do
        entered << true
        release.pop
        @cache.write("page", version, entry("completed render"))
      end
    end
    entered.pop
    second_started = Queue.new
    second = Thread.new do
      second_started << true
      @cache.synchronize_render("page", version) { @cache.read("page", version) }
    end
    second_started.pop
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    Thread.pass until second.status == "sleep" || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    assert_equal "sleep", second.status
    assert_nil @cache.read("page", version)
    assert_equal version, @cache.version
    release << true
    first.value
    assert_equal "completed render", second.value[:body]
  ensure
    release << true if release
    [ first, second ].compact.each { |thread| thread.join(2) }
  end

  private
    def entry(body)
      { body: body, marker: "unexposed-marker", headers: {} }
    end
end
