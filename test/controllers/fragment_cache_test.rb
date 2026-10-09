require "test_helper"

class FragmentRenderingTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    host! "once.campfire.test"
    sign_in :david
    @previous_caching = ActionController::Base.perform_caching
    @previous_message_caching = MessagesController.perform_caching
    @class_store = ApplicationController.cache_store
    @message_store = MessagesController.cache_store
    @collection_store = ActionView::PartialRenderer.collection_cache
    @global_store = Rails.cache
    ActionController::Base.perform_caching = true
    MessagesController.perform_caching = true
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    ApplicationController.cache_store = MessagesController.cache_store = Rails.cache
    ActionView::PartialRenderer.collection_cache = Rails.cache
    ResponseCache.instance.stubs(:budget).returns(0)
    ResponseCache.instance.clear
    @room = rooms(:watercooler)
    @message = @room.messages.ordered.last
  end

  teardown do
    ActionController::Base.perform_caching = @previous_caching
    MessagesController.perform_caching = @previous_message_caching
    Rails.cache = @global_store
    ApplicationController.cache_store = @class_store
    MessagesController.cache_store = @message_store
    ActionView::PartialRenderer.collection_cache = @collection_store
    ResponseCache.instance.clear
  end

  test "native collection fragments are shared between different authenticated viewers" do
    get room_messages_url(@room)
    assert_response :success
    first = response.body
    sign_in :jason
    hits = []
    ActiveSupport::Notifications.subscribed(->(event) { hits.concat(event.payload[:hits]) }, "cache_read_multi.active_support") do
      get room_messages_url(@room)
    end
    assert_response :success
    assert_not_empty hits
    assert_equal first, response.body
    token = users(:david).sessions.order(:id).last.token
    assert_not_includes hits.join, token
  end

  test "native fragments remain fresh after foreign leaf writes" do
    get room_messages_url(@room)
    assert_response :success
    foreign_write("UPDATE action_text_rich_texts SET body = ? WHERE record_type = 'Message' AND record_id = ?", "foreign disabled body", @message.id)
    get room_messages_url(@room)
    assert_response :success
    assert_includes response.body, "foreign disabled body"
    foreign_write("UPDATE rooms SET name = ? WHERE id = ?", "Fresh room label", @room.id)
    foreign_write("UPDATE users SET name = ? WHERE id = ?", "Fresh booster", users(:bender).id)
    get room_messages_url(@room)
    assert_response :success
    assert_includes response.body, "Fresh room label"
    assert_select "##{dom_id(boosts(:fourth_by_bender))} a[title^=?]", "Fresh booster"
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

  test "a commit in another room retains content-validated message collection hits" do
    get room_messages_url(@room)
    assert_response :success
    foreign_write("UPDATE rooms SET name = ? WHERE id = ?", "Unrelated room rename", rooms(:pets).id)
    collections = []
    ActiveSupport::Notifications.subscribed(->(event) { collections << event.payload }, "render_collection.action_view") do
      get room_messages_url(@room)
    end
    assert_response :success
    messages = collections.find { |payload| payload[:identifier].end_with?("messages/_message.html.erb") }
    assert messages
    assert_equal @room.messages.count, messages[:cache_hits]
  end

  test "a foreign commit after authentication renders current fragment dependencies" do
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

  test "bot JSON reads current leaf rows and URLs without creating HTML token state" do
    api = open_session { |session| session.host! "once.campfire.test" }
    path = room_bot_messages_path(@room, users(:bender).bot_key)
    api.get path
    assert_equal 200, api.response.status
    assert_not api.cookies["_campfire_session"]
    api.get path
    assert_equal 200, api.response.status
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
    assert_not api.cookies["_campfire_session"]
  end

  test "detached broadcasts bypass fragments without a pre-render model snapshot" do
    get room_messages_url(@room)
    foreign_write("UPDATE action_text_rich_texts SET body = ? WHERE record_type = 'Message' AND record_id = ?", "foreign broadcast body", @message.id)
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

  test "presentation deployment changes invalidate shared fragments" do
    get room_messages_url(@room)
    previous_version = Rails.configuration.x.presentation_cache_version
    Rails.configuration.x.presentation_cache_version = "new-presentation"
    collections = []
    ActiveSupport::Notifications.subscribed(->(event) { collections << event.payload }, "render_collection.action_view") do
      get room_messages_url(@room)
    end
    assert_response :success
    rendered = collections.find { |payload| payload[:identifier].end_with?("messages/_message.html.erb") }
    assert_equal 0, rendered[:cache_hits]
  ensure
    Rails.configuration.x.presentation_cache_version = previous_version
  end

  test "shared fragments separate URL origins" do
    get room_messages_url(@room)
    host! "another.campfire.test:8081"
    post session_path, params: { email_address: users(:david).email_address, password: "secret123456" }
    assert_response :redirect
    get room_messages_path(@room)
    assert_response :success
    assert_includes response.body, "http://another.campfire.test:8081/rooms/"
    assert_not_includes response.body, "http://once.campfire.test/rooms/"
  end

  test "shared fragments separate mounted URL prefixes" do
    get room_messages_url(@room)
    get room_messages_path(@room), env: { "SCRIPT_NAME" => "/campfire" }
    assert_response :success
    assert_includes response.body, "http://once.campfire.test/campfire/rooms/"
    assert_select "form[action=?]", "/campfire/messages/#{@message.id}/boosts"
  end

  test "direct sidebar participants stay fresh without membership timestamp changes" do
    get user_sidebar_url(:me)
    foreign_write("UPDATE users SET name = ? WHERE id = ?", "Renamed Jason", users(:jason).id)
    get user_sidebar_url(:me)
    assert_response :success
    assert_select "##{dom_id(rooms(:david_and_jason), :list)}", text: /Renamed/
  end

  test "mixed attachment collections read current blob metadata" do
    message = @room.messages.create! creator: users(:david), attachment: fixture_file_upload("moon.jpg", "image/jpeg")
    get room_messages_url(@room)
    assert_response :success
    foreign_write("UPDATE active_storage_blobs SET filename = ? WHERE id = ?", "renamed-moon.jpg", message.attachment.blob.id)
    get room_messages_url(@room)
    assert_response :success
    assert_select "##{dom_id(message)}", text: /renamed-moon.jpg/
  end

  test "renders inside primary transactions do not populate shared fragments" do
    writes = []
    ActiveRecord::Base.transaction do
      ActiveSupport::Notifications.subscribed(->(event) { writes << event.payload[:key] }, /cache_write.*\.active_support/) do
        get room_messages_url(@room)
      end
      assert_response :success
      assert_empty writes
      raise ActiveRecord::Rollback
    end
  end

  private
    def foreign_write(sql, *bindings)
      SQLite3::Database.new(ActiveRecord::Base.connection_db_config.database) do |database|
        database.execute(sql, bindings)
      end
      ActiveRecord::Base.clear_query_caches_for_current_thread
    end
end
