require "test_helper"

class Users::SidebarsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "show" do
    get user_sidebar_url

    users(:david).rooms.opens.each do |room|
      assert_match /#{room.name}/, @response.body
    end
  end

  test "unread directs" do
    rooms(:david_and_jason).messages.create! client_message_id: 999, body: "Hello", creator: users(:jason)

    get user_sidebar_url
    assert_select ".unread", count: users(:david).memberships.select { |m| m.room.direct? && m.unread? }.count
  end


  test "unread other" do
    rooms(:watercooler).messages.create! client_message_id: 999, body: "Hello", creator: users(:jason)

    get user_sidebar_url
    assert_select ".unread", count: users(:david).memberships.reject { |m| m.room.direct? || !m.unread? }.count
  end

  test "a cached direct that is already unread still sorts by its latest message" do
    room = rooms(:david_and_jason)

    with_memory_cache do
      travel_to 1.hour.ago do
        room.messages.create! client_message_id: 998, body: "First", creator: users(:jason)
      end
      get user_sidebar_url
      assert memberships(:david_david_and_jason).reload.unread?

      room.messages.create! client_message_id: 999, body: "Second", creator: users(:jason)
      get user_sidebar_url

      assert_select "##{dom_id(room, :list)}[data-sorted-list-number=?]", room.reload.updated_at.to_fs(:epoch)
    end
  end

  test "directs are ordered by room recency, not name" do
    older = rooms(:david_and_jason)
    newer = rooms(:david_and_kevin)
    older.update_column :updated_at, 2.days.ago
    newer.update_column :updated_at, 1.minute.ago

    get user_sidebar_url

    assert_operator @response.body.index(dom_id(newer, :list)), :<, @response.body.index(dom_id(older, :list))
  end

  test "shared rooms stay ordered by name" do
    get user_sidebar_url

    shared_ids = users(:david).rooms.without_directs.sort_by { |room| room.name.downcase }.map { |room| dom_id(room, :list) }
    positions = shared_ids.map { |id| @response.body.index(id) }

    assert positions.all?
    assert_equal positions.sort, positions
  end

  private
    def with_memory_cache
      old_cache = Rails.cache
      old_collection_cache = ActionView::PartialRenderer.collection_cache
      old_controller_cache = Users::SidebarsController.cache_store
      old_caching = Users::SidebarsController.perform_caching

      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      ActionView::PartialRenderer.collection_cache = Rails.cache
      Users::SidebarsController.cache_store = Rails.cache
      Users::SidebarsController.perform_caching = true
      yield
    ensure
      Rails.cache = old_cache
      ActionView::PartialRenderer.collection_cache = old_collection_cache
      Users::SidebarsController.cache_store = old_controller_cache
      Users::SidebarsController.perform_caching = old_caching
    end
end
