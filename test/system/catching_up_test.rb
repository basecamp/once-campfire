require "application_system_test_case"

class CatchingUpTest < ApplicationSystemTestCase
  setup do
    sign_in "jz@37signals.com"
  end

  test "after missing more than a page, the room shows the latest page with nothing left out in between" do
    join_room rooms(:designers)

    miss_messages 45
    reconnect

    assert_message_text "Missed 44", wait: 30
    sleep 3 # let a second refresh, if any, land
    assert_equal (5..44).to_a, missed_messages_shown
    assert_selector ".message:last-child .message__body", text: "Missed 44"
  end

  test "replacing the messages keeps the ones the latest page can't know about" do
    join_room rooms(:designers)

    # One that arrived live after the page was rendered, and one of ours that failed to send.
    append_to_messages <<~HTML
      <div class="message message--formatted" id="message_999999" data-message-id="999999" data-sort-value="#{1.hour.from_now.to_fs(:epoch)}"><div class="message__body">Arrived live</div></div>
      <div class="message message--formatted message--failed" id="message_unsent" data-pending-message="true" data-client-message-id="unsent"><div class="message__body">Unsent words</div></div>
    HTML

    miss_messages 45
    reconnect

    assert_message_text "Missed 44", wait: 30
    last_three = all("##{dom_id(rooms(:designers), :messages)} > .message").last(3).map(&:text)
    assert_match "Missed 44", last_three.first
    assert_equal [ "Arrived live", "Unsent words" ], last_three.last(2)
  end

  test "a reader of older messages keeps their place when more than a page was missed" do
    # Enough history after the message that the end of the page around it stays below the fold.
    miss_messages 60, label: "Earlier"
    visit room_at_message_url(rooms(:designers), messages(:first))
    wait_for_cable_connection
    dismiss_pwa_install_prompt

    miss_messages 45
    reconnect

    assert_selector ".message-area__return-to-latest", visible: true, wait: 30
    assert_selector ".search-highlight", text: messages(:first).plain_text_body
    assert_no_message_text "Missed 44"
  end

  private
    # Created without the controller, so none of them is broadcast: this browser misses them all live.
    def miss_messages(count, label: "Missed")
      count.times do |i|
        rooms(:designers).messages.create!(creator: users(:kevin), body: "#{label} #{i}", client_message_id: "#{label.downcase}-#{i}")
      end
    end

    # Without a prompt reconnect, Action Cable's monitor notices the dropped socket only after its stale threshold.
    def reconnect
      ActionCable.server.remote_connections.where(current_user: users(:jz)).disconnect(reconnect: true)
    end

    def missed_messages_shown
      all(".message__body", text: /Missed \d+/).map { |body| body.text[/Missed (\d+)/, 1].to_i }
    end

    def append_to_messages(html)
      page.execute_script("document.getElementById(arguments[0]).insertAdjacentHTML('beforeend', arguments[1])", dom_id(rooms(:designers), :messages), html)
    end

    def assert_no_message_text(text)
      assert_no_selector ".message__body", text: text
    end
end
