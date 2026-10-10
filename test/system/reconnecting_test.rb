require "application_system_test_case"

class ReconnectingTest < ApplicationSystemTestCase
  setup do
    sign_in "jz@37signals.com"
    join_room rooms(:designers)
  end

  test "a connection the server drops is back before the room goes offline" do
    users(:jz).reset_remote_connections
    assert_cable_disconnected

    # The room goes offline, and the composer with it, five seconds after the connection is lost.
    assert_selector "turbo-cable-stream-source[connected]", count: 3, visible: false, wait: 4
  end

  test "a connection the server closes for good stays closed" do
    ActionCable.server.remote_connections.where(current_user: users(:jz)).disconnect reconnect: false
    assert_cable_disconnected

    sleep 2.5 # Past the moment a dropped connection is tried again.
    assert_cable_disconnected
  end

  private
    def assert_cable_disconnected
      assert_no_selector "turbo-cable-stream-source[connected]", visible: false
    end
end
