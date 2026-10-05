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

  test "directs are queried separately and ordered by room recency, not name" do
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
end
