require "test_helper"

class Rooms::RefreshesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
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

  test "refresh appends a whole page of new messages" do
    missed = post_messages(Message::PAGE_SIZE)

    get room_refresh_url(rooms(:hq), format: :turbo_stream), params: { since: 10.minutes.ago.to_fs(:epoch) }

    assert_response :success
    assert_select "turbo-stream[action='update']", count: 0
    assert_equal missed.size, missed.count { |message| css_select("turbo-stream[action='append'] #" + dom_id(message)).any? }
  end

  test "refresh replaces the messages with the latest page when more than a page was posted" do
    travel_to 1.day.ago do
      @old_message = rooms(:hq).messages.create!(creator: users(:jason), body: "Old message", client_message_id: "old")
    end
    travel_to(1.minute.ago) { @old_message.touch }
    missed = post_messages(Message::PAGE_SIZE + 5)

    get room_refresh_url(rooms(:hq), format: :turbo_stream), params: { since: 10.minutes.ago.to_fs(:epoch) }

    assert_response :success
    assert_select "turbo-stream[action='append']", count: 0
    assert_select "turbo-stream[action='update'][target='#{dom_id(rooms(:hq), :messages)}']" do
      assert_select "[data-message-id]", count: Message::PAGE_SIZE
      missed.last(Message::PAGE_SIZE).each { |message| assert_select "#" + dom_id(message) }
    end

    # Only for a message the page already had: someone reading older messages keeps them on screen.
    assert_select "turbo-stream[action='replace']", count: 1
    assert_select "turbo-stream[action='replace'][target='#{dom_id(@old_message)}']"
  end

  private
    def post_messages(count)
      base = 5.minutes.ago

      count.times.map do |i|
        travel_to(base + i.seconds) do
          rooms(:hq).messages.create!(creator: users(:jason), body: "Missed #{i}", client_message_id: "missed-#{i}")
        end
      end
    end
end
