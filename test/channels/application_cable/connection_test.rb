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
end
