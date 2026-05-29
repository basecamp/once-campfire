require "test_helper"

class Messages::PollsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @poll = create_poll
    @message = @poll.message
  end

  test "update edits poll before votes" do
    patch message_poll_url(@message), params: {
      poll: {
        question: "Updated?",
        options_attributes: {
          "0" => { id: @poll.options.first.id, body: "Yes", position: 0 },
          "1" => { id: @poll.options.second.id, body: "No", position: 1 }
        }
      }
    }

    assert_redirected_to room_message_url(@message.room, @message)
    assert_equal "Updated?", @poll.reload.question_plain_text
    assert_equal [ "Yes", "No" ], @poll.options.pluck(:body)
  end

  test "update after votes edits question only" do
    @poll.votes.create!(poll_option: @poll.options.first, voter: users(:david))

    patch message_poll_url(@message), params: {
      poll: {
        question: "Updated?",
        options_attributes: {
          "0" => { id: @poll.options.first.id, body: "Yes", position: 0 },
          "1" => { id: @poll.options.second.id, body: "No", position: 1 }
        }
      }
    }

    assert_redirected_to room_message_url(@message.room, @message)
    assert_equal "Updated?", @poll.reload.question_plain_text
    assert_equal [ "Yep", "Nope" ], @poll.options.pluck(:body)
  end

  test "update blocked when closed" do
    @poll.close!

    patch message_poll_url(@message), params: { poll: { question: "Updated?" } }

    assert_response :unprocessable_entity
    assert_equal "Ready?", @poll.reload.question_plain_text
  end

  test "edit renders delete-only management when closed" do
    @poll.close!

    get edit_message_poll_url(@message)

    assert_response :success
    assert_select "h2", text: "Manage poll"
    assert_select "form[action='#{room_message_path(@message.room, @message)}']"
    assert_select "button", text: /Delete poll|/
  end

  test "delete poll destroys message and poll" do
    assert_difference -> { Message.count }, -1 do
      assert_difference -> { Poll.count }, -1 do
        delete room_message_url(@message.room, @message, format: :turbo_stream)
        assert_response :success
      end
    end
  end

  test "delete closed poll with votes destroys message and poll" do
    @poll.votes.create!(poll_option: @poll.options.first, voter: users(:david))
    @poll.close!

    assert_difference -> { Message.count }, -1 do
      assert_difference -> { Poll.count }, -1 do
        delete room_message_url(@message.room, @message, format: :turbo_stream)
        assert_response :success
      end
    end
  end

  test "close closes poll when user can administer" do
    patch close_message_poll_url(@message, format: :turbo_stream)

    assert_response :ok
    assert @poll.reload.closed?
  end

  test "close forbidden for non-admin and non-author" do
    sign_in :kevin

    patch close_message_poll_url(@message, format: :turbo_stream)

    assert_response :forbidden
    assert_includes response.body, "Only the poll creator or an admin can edit or close this poll."
    assert_not @poll.reload.closed?
  end

  test "edit forbidden for non-admin and non-author shows an alert" do
    sign_in :kevin

    get edit_message_poll_url(@message, format: :turbo_stream)

    assert_response :forbidden
    assert_includes response.body, "Only the poll creator or an admin can edit or close this poll."
  end

  test "update forbidden for non-admin and non-author shows an alert" do
    sign_in :kevin

    patch message_poll_url(@message, format: :turbo_stream), params: { poll: { question: "Updated?" } }

    assert_response :forbidden
    assert_includes response.body, "Only the poll creator or an admin can edit or close this poll."
    assert_equal "Ready?", @poll.reload.question_plain_text
  end

  private
    def create_poll
      message = rooms(:designers).messages.create!(creator: users(:jason), body: "", client_message_id: SecureRandom.uuid)
      message.create_poll!(question: "Ready?", options_attributes: [ { body: "Yep", position: 0 }, { body: "Nope", position: 1 } ])
    end
end
