require "test_helper"
require "tmpdir"

class RecordCacheTest < ActiveSupport::TestCase
  setup do
    @directory = Dir.mktmpdir
    @database = File.join(@directory, "records.sqlite3")
    SQLite3::Database.new(@database) do |database|
      database.execute("PRAGMA journal_mode=WAL")
      database.execute("CREATE TABLE changes_for_test (value TEXT)")
    end
    ActiveRecord::Base.stubs(:connection_db_config).returns(Struct.new(:database).new(@database))
    ActiveRecord::Base.connection.stubs(:transaction_open?).returns(false)
    @cache = ResponseCache.new
    @cache.stubs(:budget).returns(4096)
    ResponseCache.stubs(:instance).returns(@cache)
    FragmentCache.stubs(:store).returns(ActiveSupport::Cache::MemoryStore.new(size: 64.kilobytes))
    @record = User.instantiate(users(:david).attributes_before_type_cast.merge(
      "created_at" => "2026-10-08 12:34:56.123456", "updated_at" => "2026-10-08 12:34:57.654321",
      "status" => 2, "role" => 1))
  end

  teardown do
    @cache.clear
    FileUtils.remove_entry(@directory)
  end

  test "hits reconstruct independent persisted models without losing raw timestamps or enum values" do
    version = @cache.version
    assert_same @record, RecordCache.fetch("user", version) { [ @record ] }.first
    first = RecordCache.fetch("user", version) { flunk "cache hit queried records" }.first
    second = RecordCache.fetch("user", version) { flunk "cache hit queried records" }.first

    assert_not_same @record, first
    assert_not_same first, second
    assert first.persisted?
    assert_not first.changed?
    assert_equal @record.attributes_before_type_cast, first.attributes_before_type_cast
    assert_equal 123456, first.created_at.usec
    assert_equal 654321, first.updated_at.usec
    assert_equal "banned", first.status
    assert_equal "administrator", first.role
    first.name = "Request-local edit"
    assert_equal @record.name, second.name
    assert_equal @record.name, RecordCache.fetch("user", version) { flunk "cache hit queried records" }.first.name
  end

  test "foreign commit makes an old captured epoch query fresh records instead of reusing a snapshot" do
    version = @cache.version
    RecordCache.fetch("user", version) { [ @record ] }
    foreign_commit
    fresh = User.instantiate(@record.attributes_before_type_cast.merge("name" => "Changed elsewhere"))
    assert_same fresh, RecordCache.fetch("user", version) { [ fresh ] }.first
    assert_same fresh, RecordCache.fetch("user", @cache.version) { [ fresh ] }.first
    assert_equal fresh.name, RecordCache.fetch("user", @cache.version) { flunk "fresh snapshot missing" }.first.name
  end

  test "observer is rechecked after a snapshot lookup" do
    version = @cache.version
    RecordCache.fetch("user", version) { [ @record ] }
    store = FragmentCache.store
    original_read = store.method(:read)
    commit = method(:foreign_commit)
    store.define_singleton_method(:read) do |*arguments|
      original_read.call(*arguments).tap { |snapshot| commit.call if snapshot }
    end
    fresh = User.instantiate(@record.attributes_before_type_cast.merge("name" => "Committed during lookup"))
    assert_same fresh, RecordCache.fetch("user", version) { [ fresh ] }.first
  end

  test "a commit while loading records prevents admission under the old epoch" do
    version = @cache.version
    FragmentCache.store.expects(:write).never
    assert_same @record, RecordCache.fetch("user", version) { foreign_commit; [ @record ] }.first
    replacement = User.instantiate(@record.attributes_before_type_cast.merge("name" => "Fresh load"))
    assert_same replacement, RecordCache.fetch("user", version) { [ replacement ] }.first
  end

  test "disabled budget missing epoch and open transactions always query and never admit" do
    version = @cache.version
    RecordCache.fetch("user", version) { [ @record ] }
    FragmentCache.store.expects(:write).never
    @cache.stubs(:budget).returns(0)
    assert_same @record, RecordCache.fetch("user", version) { [ @record ] }.first
    @cache.stubs(:budget).returns(4096)
    assert_same @record, RecordCache.fetch("user", nil) { [ @record ] }.first
    ActiveRecord::Base.connection.stubs(:transaction_open?).returns(true)
    assert_same @record, RecordCache.fetch("user", version) { [ @record ] }.first
    assert_same @record, RecordCache.fetch("transaction-only", version) { [ @record ] }.first
  end

  private
    def foreign_commit
      SQLite3::Database.new(@database) { |database| database.execute("INSERT INTO changes_for_test VALUES ('committed')") }
    end
end
