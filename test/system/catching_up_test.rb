require "application_system_test_case"

class CatchingUpTest < ApplicationSystemTestCase
  setup do
    sign_in "jz@37signals.com"
  end

  test "after missing more than a page, the room shows every missed message once, in order" do
    join_room rooms(:designers)
    missed = miss_messages(45)

    # A copy of one of them, appended live just before the refresh, out of order.
    append_to_messages <<~HTML
      <div class="message message--formatted" id="#{dom_id(missed[42])}" data-message-id="#{missed[42].id}" data-sort-value="#{missed[42].created_at.to_fs(:epoch)}"><div class="message__body">Early copy</div></div>
    HTML
    reconnect

    assert_message_text "Missed 44", wait: 30
    assert_equal (0..44).to_a, missed_messages_shown
    assert_no_message_text "Early copy"
  end

  test "catching up leaves a message being edited as it is" do
    join_room rooms(:designers)
    within_message messages(:third) do
      reveal_message_actions
      find(".message__edit-btn").click
    end
    assert_selector "##{dom_id(messages(:third))} .message__body-content--editing"

    miss_messages 45
    reconnect

    assert_message_text "Missed 44", wait: 30
    assert_selector "##{dom_id(messages(:third))} .message__body-content--editing"
  end

  test "a message that arrives while the list isn't at its end waits, then shows in order" do
    # Enough history after the message that the end of the page around it stays below the fold.
    earlier = miss_messages(60, label: "Earlier")
    visit room_at_message_url(rooms(:designers), messages(:first))
    wait_for_cable_connection
    dismiss_pwa_install_prompt

    # One older than the latest page, as if it had been held for long, and one just now.
    Turbo::StreamsChannel.broadcast_append_to rooms(:designers), :messages, target: dom_id(rooms(:designers), :messages), html: <<~HTML
      <div class="message message--formatted" id="message_999998" data-message-id="999998" data-sort-value="#{earlier[5].created_at.to_fs(:epoch)}"><div class="message__body">Held for long</div></div>
      <div class="message message--formatted" id="message_999999" data-message-id="999999" data-sort-value="#{Time.current.to_fs(:epoch)}"><div class="message__body">Arrived live</div></div>
    HTML

    assert_selector ".message-area__return-to-latest", visible: true, wait: 10
    assert_no_message_text "Arrived live"
    assert_selector ".search-highlight", text: messages(:first).plain_text_body

    # Sending one brings the list to its end first, and the held message comes before ours.
    send_message "Mine"

    last_two = all("##{dom_id(rooms(:designers), :messages)} > .message").last(2).map(&:text)
    assert_equal "Arrived live", last_two.first
    assert_match "Mine", last_two.last
    assert_no_message_text "Held for long"
  end

  private
    # Created without the controller, so none of them is broadcast: this browser misses them all live.
    def miss_messages(count, label: "Missed")
      count.times.map do |i|
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
