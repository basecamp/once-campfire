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

    testserver.advance_time 1.minute

    assert socket.closed
    assert_equal "disconnect", socket.transmissions.last[:type]
    assert socket.transmissions.last[:reconnect]
  end

  test "stays open while its session remains" do
    cookies.signed[:session_token] = sessions(:david_safari).token
    connect

    testserver.advance_time 5.minutes

    assert_not socket.closed
  end

  test "stops checking its session once disconnected" do
    cookies.signed[:session_token] = sessions(:david_safari).token
    connect
    disconnect

    Session.expects(:exists?).never
    testserver.advance_time 5.minutes
  end
end
