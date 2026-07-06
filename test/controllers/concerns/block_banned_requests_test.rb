require "test_helper"

class BlockBannedRequestsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @room = rooms(:watercooler)

    Ban.create!(user: users(:kevin), ip_address: "203.0.113.1")
  end

  test "POST requests from banned IPs are blocked with 429" do
    post room_messages_url(@room),
      params: { message: { body: "Test", client_message_id: "test-123" } },
      headers: { "REMOTE_ADDR" => "203.0.113.1" }

    assert_response :too_many_requests
  end

  test "POST requests from non-banned IPs are allowed" do
    post room_messages_url(@room, format: :turbo_stream),
      params: { message: { body: "Test", client_message_id: "test-123" } },
      headers: { "REMOTE_ADDR" => "203.0.113.99" }

    assert_response :success
  end

  test "GET requests from banned IPs are allowed" do
    get room_messages_url(@room), headers: { "REMOTE_ADDR" => "203.0.113.1" }

    assert_response :success
  end
end
