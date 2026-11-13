require "test_helper"

class Rooms::RefreshesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "refresh removes the messages shown that are gone" do
    kept = rooms(:hq).messages.create!(creator: users(:jason), body: "Kept", client_message_id: "kept")
    deleted = rooms(:hq).messages.create!(creator: users(:jason), body: "Deleted", client_message_id: "deleted")
    elsewhere = rooms(:pets).messages.create!(creator: users(:jason), body: "Elsewhere", client_message_id: "elsewhere")
    deleted.destroy

    get room_refresh_url(rooms(:hq), format: :turbo_stream),
      params: { since: Time.current.to_fs(:epoch), shown: [ kept.id, deleted.id, elsewhere.id ].join(",") }

    assert_response :success
    assert_select "turbo-stream[action='remove']", count: 2
    assert_select "turbo-stream[action='remove'][target='#{dom_id(deleted)}']"
    assert_select "turbo-stream[action='remove'][target='#{dom_id(elsewhere)}']"
  end

  test "refresh removes nothing when the page doesn't say what it shows" do
    rooms(:hq).messages.create!(creator: users(:jason), body: "Deleted", client_message_id: "deleted").destroy

    get room_refresh_url(rooms(:hq), format: :turbo_stream), params: { since: Time.current.to_fs(:epoch) }

    assert_response :success
    assert_select "turbo-stream[action='remove']", count: 0
  end

  test "refresh includes new messages since the last known" do
    travel_to 1.day.ago do
      @old_message = rooms(:hq).messages.create!(creator: users(:jason), body: "Old message", client_message_id: "old")
    end

    travel_to 1.minute.ago do
      @new_message = rooms(:hq).messages.create!(creator: users(:jason), body: "New message", client_message_id: "new")
      @old_message.touch
    end

    get room_refresh_url(rooms(:hq), format: :turbo_stream), params: { since: 10.minutes.ago.to_fs(:epoch) }

    assert_response :success

    assert_select "turbo-stream[action='append']" do
      assert_select "#" + dom_id(@new_message)
      assert_select "template", count: 1
    end

    assert_select "turbo-stream[action='replace']" do
      assert_select "#" + dom_id(@old_message)
      assert_select "template", count: 1
    end
  end
end
