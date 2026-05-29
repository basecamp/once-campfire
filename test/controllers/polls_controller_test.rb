require "test_helper"

class PollsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "once.campfire.test"
    sign_in :david
    @room = rooms(:designers)
  end

  test "create poll" do
    assert_difference -> { Poll.count }, 1 do
      assert_difference -> { Message.count }, 1 do
        post room_polls_url(@room), params: {
          poll: {
            question: "Ship it?",
            options_attributes: {
              "0" => { body: "Yes", position: 0 },
              "1" => { body: "No", position: 1 }
            }
          },
          message: {
            client_message_id: "poll-client-id"
          }
        }
      end
    end

    assert_redirected_to room_url(@room)
    assert_equal "poll", Message.last.content_type
    assert_equal "poll-client-id", Message.last.client_message_id
  end

  test "create multi-select poll" do
    post room_polls_url(@room), params: {
      poll: {
        question: "Pick any?",
        multi_select: "1",
        options_attributes: {
          "0" => { body: "A", position: 0 },
          "1" => { body: "B", position: 1 }
        }
      }
    }

    assert_redirected_to room_url(@room)
    assert_predicate Poll.last, :multi_select?
  end

  test "new poll renders as a full page" do
    get new_room_poll_url(@room)

    assert_response :success
    assert_select "turbo-frame#composer-modal", false
    assert_select "#message-area .poll-editor"
  end

  test "new poll reuses client message id until create succeeds" do
    get new_room_poll_url(@room)
    first_client_message_id = css_select("input[name='message[client_message_id]']").first["value"]

    get new_room_poll_url(@room)

    assert_select "input[name='message[client_message_id]'][value='#{first_client_message_id}']"

    post room_polls_url(@room), params: valid_poll_params(first_client_message_id)
    assert_redirected_to room_url(@room)

    get new_room_poll_url(@room)
    next_client_message_id = css_select("input[name='message[client_message_id]']").first["value"]

    assert_not_equal first_client_message_id, next_client_message_id
  end

  test "duplicate poll create with same client message id is ignored" do
    params = valid_poll_params("duplicate-client-id")

    post room_polls_url(@room), params: params

    assert_no_difference -> { Message.count } do
      assert_no_difference -> { Poll.count } do
        post room_polls_url(@room), params: params
      end
    end
  end

  test "poll question renders rich text" do
    post room_polls_url(@room), params: {
      poll: {
        question: "<ul><li>Mobile</li><li>Desktop</li></ul>",
        options_attributes: {
          "0" => { body: "Yes", position: 0 },
          "1" => { body: "No", position: 1 }
        }
      }
    }

    follow_redirect!

    assert_select ".poll__question li", text: "Mobile"
    assert_select ".poll__question li", text: "Desktop"
  end

  test "created poll renders edit and close actions" do
    post room_polls_url(@room), params: {
      poll: {
        question: "Ship it?",
        options_attributes: {
          "0" => { body: "Yes", position: 0 },
          "1" => { body: "No", position: 1 }
        }
      }
    }

    follow_redirect!

    assert_select "a[aria-label='Edit poll'][hidden][data-poll-actions-target='adminAction']"
    assert_select "form[action='#{close_message_poll_path(Message.last)}'][hidden][data-poll-actions-target='adminAction']"
  end

  test "invalid create does not persist message" do
    assert_no_difference -> { Poll.count } do
      assert_no_difference -> { Message.count } do
        post room_polls_url(@room), params: {
          poll: {
            question: "",
            options_attributes: {
              "0" => { body: "Only one", position: 0 }
            }
          }
        }
      end
    end

    assert_response :unprocessable_entity
  end

  test "invalid create preserves client message id" do
    post room_polls_url(@room), params: {
      poll: {
        question: "",
        options_attributes: {
          "0" => { body: "Only one", position: 0 }
        }
      },
      message: {
        client_message_id: "retry-client-id"
      }
    }

    assert_response :unprocessable_entity
    assert_select "input[name='message[client_message_id]'][value='retry-client-id']"
  end

  private
    def valid_poll_params(client_message_id)
      {
        poll: {
          question: "Ship it?",
          options_attributes: {
            "0" => { body: "Yes", position: 0 },
            "1" => { body: "No", position: 1 }
          }
        },
        message: {
          client_message_id: client_message_id
        }
      }
    end
end
