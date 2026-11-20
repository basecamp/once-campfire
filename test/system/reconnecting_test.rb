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

  test "a room that loses its connection twice before getting it back isn't left offline" do
    page.execute_script(<<~JS)
      const element = document.querySelector("[data-controller~='refresh-room']")
      const { channel } = Stimulus.getControllerForElementAndIdentifier(element, "refresh-room")

      channel.disconnected({ willAttemptReconnect: false })
      channel.disconnected({ willAttemptReconnect: false })
      channel.connected()
    JS

    sleep 5.5 # Past the moment a lost connection takes the room offline.
    assert_no_selector "fieldset[data-composer-target='fields'][disabled]"
  end

  private
    def assert_cable_disconnected
      assert_no_selector "turbo-cable-stream-source[connected]", visible: false
    end
end
