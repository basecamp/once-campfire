require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  test "connects with valid user_id cookie" do
    cookies.signed[:session_token] = sessions(:david_safari).token

    connect

    assert_equal users(:david), connection.current_user
  end

  test "rejects connection with missing user_id cookie" do
    assert_reject_connection { connect }
  end

  test "rejects connection with invalid user_id cookie" do
    cookies.signed[:session_token] = -1

    assert_reject_connection { connect }
  end

  test "closes once its session has ended without it hearing" do
    cookies.signed[:session_token] = sessions(:david_safari).token
    connect
    sessions(:david_safari).destroy

    travel 2.minutes
    connection.beat

    assert socket.closed
    assert_equal "disconnect", socket.transmissions.last[:type]
    assert socket.transmissions.last[:reconnect]
  end

  test "keeps checking its session while open" do
    cookies.signed[:session_token] = sessions(:david_safari).token
    connect

    travel 2.minutes
    connection.beat
    assert_not socket.closed

    sessions(:david_safari).destroy
    travel 2.minutes
    connection.beat
    assert socket.closed
  end

  test "checks its session at most once a minute" do
    cookies.signed[:session_token] = sessions(:david_safari).token
    connect
    sessions(:david_safari).destroy

    travel 30.seconds
    connection.beat

    assert_not socket.closed
  end

  test "a rejected connection's heartbeat doesn't fail" do
    request = ActionCable::Connection::TestSocket.build_request(ActionCable.server.config.mount_path || "/cable", cookies: cookies)
    rejected = ApplicationCable::Connection.new \
      ActionCable::Connection::TestServer.new(ActionCable.server), ActionCable::Connection::TestSocket.new(request)
    rejected.handle_open

    travel 2.minutes

    assert_nothing_raised { rejected.beat }
  end
end
