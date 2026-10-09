require "test_helper"

class CachedResponsesTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    host! "once.campfire.test"
    sign_in :david
    @login_cookie = cookies["_campfire_session"]
    @previous_forgery = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    @previous_cache = Rails.cache
    @previous_caching = ActionController::Base.perform_caching
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    ActionController::Base.perform_caching = true
    @room = rooms(:watercooler)
    # Establish last-room cookies before checking reuse.
    2.times { get room_url(@room) }
    ResponseCache.instance.clear
  end

  teardown do
    ResponseCache.instance.clear
    ActionController::Base.allow_forgery_protection = @previous_forgery
    Rails.cache = @previous_cache
    ActionController::Base.perform_caching = @previous_caching
  end

  test "all four read actions reuse completed pages" do
    urls = [ room_url(@room), room_messages_url(@room), user_sidebar_url(:me), searches_url(q: "hello") ]
    urls.each do |url|
      get url
      assert_response :success
    end
    ResponseCache.instance.expects(:write).never
    urls.each do |url|
      get url
      assert_response :success
    end
  end

  test "pagination caches the completed HTML rather than silently bypassing admission" do
    get room_messages_url(@room)
    assert_response :success
    assert_equal "text/html", response.media_type
    MessagesController.any_instance.expects(:find_paged_messages).never
    get room_messages_url(@room)
    assert_response :success
  end

  test "clients without token state reuse complete HTML and post without tokens" do
    cookies["_campfire_session"] = @login_cookie
    get room_url(@room)
    first = response.body
    assert_select 'meta[name="csrf-token"]', count: 0
    assert_select 'input[name="authenticity_token"]', count: 0
    cookies["_campfire_session"] = @login_cookie
    ResponseCache.instance.expects(:write).never
    get room_url(@room)
    assert_response :success
    assert_equal first, response.body
    post room_messages_url(@room, format: :turbo_stream), params: {
      message: { body: "tokenless replay works", client_message_id: "cache-replay" } },
      headers: { "Sec-Fetch-Site" => "same-origin", "Origin" => "http://once.campfire.test" }
    assert_response :success
  end

  test "literal token-like text survives complete page reuse" do
    literal = "campfire-csrf-literal authenticity_token csrf-token"
    @room.messages.create!(creator: users(:david), body: "literal #{literal}")
    get room_url(@room)
    first = response.body
    get room_url(@room)
    assert_equal first, response.body
    assert_includes response.body, "literal #{literal}"
  end

  test "gzip bytes are reused and identity negotiation stays separate" do
    require "stringio"
    get room_url(@room), headers: { "Accept-Encoding" => "gzip" }
    assert_equal "gzip", response.headers["Content-Encoding"]
    encoded = response.body
    decoded = Zlib::GzipReader.new(StringIO.new(encoded)).read
    assert_includes decoded, "<html"
    assert_includes response.headers["Vary"], "Accept-Encoding"
    get room_url(@room)
    assert_equal decoded, response.body
    ResponseCache.instance.expects(:write).never
    get room_url(@room), headers: { "Accept-Encoding" => "gzip" }
    assert_equal encoded, response.body
    get room_url(@room)
    assert_nil response.headers["Content-Encoding"]
    assert_equal decoded, response.body
    get room_url(@room), headers: { "Accept-Encoding" => "gzip;q=0, identity;q=1" }
    assert_nil response.headers["Content-Encoding"]
    assert_equal decoded, response.body
    get room_url(@room), headers: { "Accept-Encoding" => "*;q=0" }
    assert_nil response.headers["Content-Encoding"]
  end

  test "local and foreign commits invalidate pages and nested fragments" do
    message = @room.messages.ordered.last
    get room_url(@room)
    @room.messages.create!(creator: users(:david), body: "local commit")
    get room_url(@room)
    assert_includes response.body, "local commit"

    foreign_write("UPDATE users SET name = ? WHERE id = ?", "Foreign creator", message.creator_id)
    get room_url(@room)
    assert_includes response.body, "Foreign creator"
    foreign_write("UPDATE action_text_rich_texts SET body = ? WHERE record_type = 'Message' AND record_id = ?", "foreign message body", message.id)
    get room_url(@room)
    assert_includes response.body, "foreign message body"
  end

  test "cached room access and sessions are checked afresh" do
    get room_url(@room)
    foreign_write("DELETE FROM memberships WHERE room_id = ? AND user_id = ?", @room.id, users(:david).id)
    get room_url(@room)
    assert_redirected_to root_url
    get user_sidebar_url(:me)
    foreign_write("DELETE FROM sessions WHERE user_id = ?", users(:david).id)
    get user_sidebar_url(:me)
    assert_redirected_to new_session_url
  end

  test "conditional requests keep native validators" do
    get room_messages_url(@room)
    etag = response.headers["ETag"]
    assert etag.present?
    get room_messages_url(@room), headers: { "If-None-Match" => etag }
    assert_response :not_modified
  end

  test "foreign presentation changes cannot return a false not-modified response" do
    get room_messages_url(@room)
    etag = response.headers["ETag"]
    message = @room.messages.ordered.last
    foreign_write("UPDATE action_text_rich_texts SET body = ? WHERE record_type = 'Message' AND record_id = ?", "changed presentation", message.id)
    get room_messages_url(@room), headers: { "If-None-Match" => etag }
    assert_response :success
    assert_includes response.body, "changed presentation"
    assert_not_equal etag, response.headers["ETag"]
  end

  test "origins and frame variants have separate entries" do
    get room_url(@room)
    ResponseCache.instance.expects(:write).twice
    get room_url(@room), headers: { "Turbo-Frame" => "different-frame" }
    host! "once.campfire.test:8081"
    get room_path(@room)
    assert_response :success
  end

  test "cache can be disabled" do
    ResponseCache.instance.stubs(:budget).returns(0)
    ResponseCache.instance.expects(:read).never
    2.times { get room_url(@room) }
    assert_response :success
  end

  test "a commit after authentication cannot admit captured user fields" do
    Users::SidebarsController.any_instance.stubs(:set_version_headers).with do
      foreign_write("UPDATE users SET name = ? WHERE id = ?", "During authentication", users(:david).id)
      true
    end
    get user_sidebar_url(:me)
    Users::SidebarsController.any_instance.unstub(:set_version_headers)
    ResponseCache.instance.expects(:write).once
    get user_sidebar_url(:me)
    assert_includes response.body, "During authentication"
  end

  private
    def foreign_write(sql, *bindings)
      SQLite3::Database.new(ActiveRecord::Base.connection_db_config.database) do |database|
        database.execute(sql, bindings)
      end
      # Fixtures share this thread's query cache outside the request executor.
      ActiveRecord::Base.clear_query_caches_for_current_thread
    end
end
