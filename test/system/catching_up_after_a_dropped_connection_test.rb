require "application_system_test_case"

class CatchingUpAfterADroppedConnectionTest < ApplicationSystemTestCase
  setup do
    sign_in "jz@37signals.com"
    join_room rooms(:designers)

    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room rooms(:designers)
    end
  end

  test "a message sent while the connection is down doesn't hide the ones missed before it" do
    drop_connection
    using_session("Kevin") { send_message "Missed while away" }
    assert_no_message_text "Missed while away"

    send_message "Sent while away"
    restore_connection

    assert_message_text "Missed while away", wait: 10
    assert_equal [ "Missed while away", "Sent while away" ], texts_from_while_away
  end

  test "messages missed or sent while the connection is down stay before one that arrives live as it comes back" do
    drop_connection
    using_session("Kevin") { send_message "Missed while away" }
    send_message "Sent while away"
    send_message "Sent again while away"
    mark_message "Sent again while away"

    # As if it arrived live once the connection was back, between the refresh's query and its answer.
    execute_script <<~JS, dom_id(rooms(:designers), :messages), 1.minute.from_now.to_fs(:epoch)
      document.getElementById(arguments[0]).insertAdjacentHTML("beforeend",
        `<div class="message message--formatted" id="message_999999" data-message-id="999999" data-sort-value="${arguments[1]}"><div class="lexxy-content">Live while away</div></div>`)
    JS
    restore_connection

    # The refresh brings the newest one again whatever happens, so its mark goes once the refresh is in.
    assert_no_selector ".message[data-marked]", wait: 10
    assert_equal [ "Missed while away", "Sent while away", "Sent again while away", "Live while away" ], texts_from_while_away
  end

  test "messages missed while the connection is down show once it's back, and the ones shown before stay as they are" do
    using_session("Kevin") do
      send_message "Seen live"
      # The refresh asks from the newest message's millisecond, so that one comes again whatever happens.
      send_message "Seen live, the newest"
    end
    mark_message "Seen live"

    drop_connection
    using_session("Kevin") { send_message "Missed while away" }
    assert_no_message_text "Missed while away"

    restore_connection

    assert_message_text "Missed while away", wait: 10
    assert_equal [ "Missed while away" ], texts_from_while_away
    assert_selector ".message[data-marked]", text: "Seen live", count: 1
  end

  private
    # The server drops the connection, as it does when the user signs out elsewhere, and Chrome keeps it from coming
    # back until restore_connection, while the rest of the page still reaches the server.
    def drop_connection
      page.driver.browser.execute_cdp "Network.enable"
      page.driver.browser.execute_cdp "Network.setBlockedURLs", urls: [ "*/cable*" ]
      users(:jz).reset_remote_connections
      assert_no_selector "turbo-cable-stream-source[connected]", visible: false
    end

    def restore_connection
      page.driver.browser.execute_cdp "Network.setBlockedURLs", urls: []
      # Action Cable tries again on its own schedule, several seconds apart.
      assert_selector "turbo-cable-stream-source[connected]", count: 3, visible: false, wait: 30
    end

    # A refresh that brings the message again replaces its element, and the mark with it.
    def mark_message(text)
      assert_message_text text
      execute_script <<~JS, text
        Array.from(document.querySelectorAll(".message")).find((message) => message.textContent.includes(arguments[0])).dataset.marked = "true"
      JS
      assert_selector ".message[data-marked]", text: text
    end

    def texts_from_while_away
      all(".message .lexxy-content", text: "while away").map(&:text)
    end

    def assert_no_message_text(text)
      assert_no_selector ".message__body", text: text
    end
end
