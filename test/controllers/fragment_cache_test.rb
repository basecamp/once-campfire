require "test_helper"

class FragmentRenderingTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    host! "once.campfire.test"
    sign_in :david
    @previous_caching = ActionController::Base.perform_caching
    @previous_message_caching = MessagesController.perform_caching
    @class_store = ApplicationController.cache_store
    @global_store = Rails.cache
    ActionController::Base.perform_caching = true
    MessagesController.perform_caching = true
    FragmentCache.store.clear
    ResponseCache.instance.clear
    @room = rooms(:watercooler)
    @message = @room.messages.ordered.last
  end

  teardown do
    ActionController::Base.perform_caching = @previous_caching
    MessagesController.perform_caching = @previous_message_caching
    FragmentCache.store.clear
    ResponseCache.instance.clear
  end

  test "native collection caching uses the bounded store without replacing shared stores" do
    assert_same FragmentCache.store, ApplicationController.new.cache_store
    assert_same FragmentCache.store, ActionView::PartialRenderer.collection_cache
    assert_same @class_store, ApplicationController.cache_store
    assert_same @global_store, Rails.cache
    ResponseCache.instance.stubs(:budget).returns(0)
    get room_messages_url(@room)
    assert_response :success
    hits = []
    ActiveSupport::Notifications.subscribed(->(event) { hits.concat(event.payload[:hits]) }, "cache_read_multi.active_support") do
      get room_messages_url(@room)
    end
    assert_response :success
    assert_not_empty hits
    token = users(:david).sessions.order(:id).last.token
    assert_not_includes hits.join, token
  end

  test "disabled page caching retains fresh native fragments after foreign leaf writes" do
    ResponseCache.instance.stubs(:budget).returns(0)
    get room_messages_url(@room)
    assert_response :success
    foreign_write("UPDATE action_text_rich_texts SET body = ? WHERE record_type = 'Message' AND record_id = ?", "foreign disabled body", @message.id)
    get room_messages_url(@room)
    assert_response :success
    assert_includes response.body, "foreign disabled body"
  end

  test "conditional pagination invalidates warmed native fragments without timestamp changes" do
    get room_messages_url(@room), headers: { "If-None-Match" => "unmatched" }
    assert_response :success
    etag = response.headers["ETag"]
    foreign_write("UPDATE action_text_rich_texts SET body = ? WHERE record_type = 'Message' AND record_id = ?", "foreign conditional body", @message.id)
    get room_messages_url(@room), headers: { "If-None-Match" => etag }
    assert_response :success
    assert_includes response.body, "foreign conditional body"
  end

  test "message controls survive creator edits while the author is rendered fresh" do
    get room_messages_url(@room)
    assert_response :success
    foreign_write("UPDATE users SET name = ? WHERE id = ?", "Fresh creator with cached controls", @message.creator_id)
    ActionView::Base.any_instance.expects(:form_with).never
    get room_messages_url(@room)
    assert_response :success
    assert_includes response.body, "Fresh creator with cached controls"
    assert_select "form[action=?]", message_boosts_path(@message)
  end

  test "a foreign commit after capture bypasses old native fragment lookups" do
    ResponseCache.instance.stubs(:budget).returns(0)
    get room_messages_url(@room)
    assert_response :success
    MessagesController.any_instance.stubs(:set_version_headers).with do
      foreign_write("UPDATE action_text_rich_texts SET body = ? WHERE record_type = 'Message' AND record_id = ?", "foreign before fragments", @message.id)
      true
    end
    get room_messages_url(@room), headers: { "If-None-Match" => "unmatched" }
    assert_response :success
    assert_includes response.body, "foreign before fragments"
  end

  test "refresh streams recheck native cached creator body and boost presentation" do
    message = messages(:first)
    room = message.room
    get room_refresh_url(room, format: :turbo_stream), params: { since: 0 }
    assert_response :success
    foreign_write("UPDATE action_text_rich_texts SET body = ? WHERE record_type = 'Message' AND record_id = ?", "foreign refreshed body", message.id)
    foreign_write("UPDATE users SET name = ? WHERE id = ?", "Foreign refreshed creator", message.creator_id)
    foreign_write("UPDATE boosts SET content = ? WHERE message_id = ?", "Foreign refreshed boost", message.id)
    get room_refresh_url(room, format: :turbo_stream), params: { since: 0 }
    assert_response :success
    assert_includes response.body, "foreign refreshed body"
    assert_includes response.body, "Foreign refreshed creator"
    assert_includes response.body, "Foreign refreshed boost"
  end

  test "Jbuilder fragments use the bounded store and do not create HTML token state" do
    api = open_session { |session| session.host! "once.campfire.test" }
    path = room_bot_messages_path(@room, users(:bender).bot_key)
    api.get path
    assert_equal 200, api.response.status
    assert_not api.cookies["_campfire_session"]
    hits = []
    ActiveSupport::Notifications.subscribed(->(event) { hits << event.payload[:key] if event.payload[:hit] }, "cache_read.active_support") do
      api.get path
    end
    assert_equal 200, api.response.status
    assert_not_empty hits
    foreign_write("UPDATE action_text_rich_texts SET body = ? WHERE record_type = 'Message' AND record_id = ?", "foreign JSON body", @message.id)
    foreign_write("UPDATE users SET name = ? WHERE id = ?", "Foreign JSON creator", @message.creator_id)
    api.get path
    json = JSON.parse(api.response.body).find { |message| message["id"] == @message.id }
    assert_includes json.dig("body", "html"), "foreign JSON body"
    assert_equal "Foreign JSON creator", json.dig("creator", "name")
    api.host! "another.campfire.test:8081"
    api.get path
    json = JSON.parse(api.response.body).find { |message| message["id"] == @message.id }
    assert_includes json["url"], "another.campfire.test:8081"
    assert_same @global_store, Rails.cache
  end

  test "detached broadcasts bypass fragments without a pre-render model snapshot" do
    get room_messages_url(@room)
    foreign_write("UPDATE action_text_rich_texts SET body = ? WHERE record_type = 'Message' AND record_id = ?", "foreign broadcast body", @message.id)
    FragmentCache.store.expects(:read).never
    FragmentCache.store.expects(:write).never
    FragmentCache.store.expects(:read_multi).never
    FragmentCache.store.expects(:write_multi).never
    @message.reload.broadcast_create
    assert_rendered_turbo_stream_broadcast @room, :messages, action: "append", target: [ @room, :messages ] do |stream|
      assert_includes stream.to_html, "foreign broadcast body"
    end
    body = ApplicationController.render(partial: "messages/message", locals: { message: @message.reload })
    assert_includes body, "foreign broadcast body"
    collection = ApplicationController.render(partial: "messages/message", collection: [ @message.reload ], cached: true)
    assert_includes collection, "foreign broadcast body"
    assert_not ApplicationController.new.perform_caching
  end

  private
    def foreign_write(sql, *bindings)
      SQLite3::Database.new(ActiveRecord::Base.connection_db_config.database) do |database|
        database.execute(sql, bindings)
      end
      ActiveRecord::Base.clear_query_caches_for_current_thread
    end
end
