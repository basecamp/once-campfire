require "application_system_test_case"

class SendingMessagesTest < ApplicationSystemTestCase
  setup do
    sign_in "jz@37signals.com"
    join_room rooms(:designers)
  end

  test "sending messages between two users" do
    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room rooms(:designers)
    end

    join_room rooms(:designers)
    send_message "Is this thing on?"

    # The optimistic pending message is reconciled with the server broadcast even
    # though they no longer share a DOM id: exactly one element, no duplicate.
    assert_selector ".message__body", text: "Is this thing on?", count: 1
    assert_no_selector "[data-pending-message]"

    using_session("Kevin") do
      join_room rooms(:designers)
      assert_message_text "Is this thing on?"

      send_message "👍👍"
    end

    join_room rooms(:designers)
    assert_message_text "👍👍"
  end

  test "editing messages" do
    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room rooms(:designers)
    end

    within_message messages(:third) do
      reveal_message_actions
      find(".message__edit-btn").click
      fill_in_rich_text_area "message_body", with: "Redacted!"
      click_on "Save changes"
    end

    using_session("Kevin") do
      join_room rooms(:designers)

      assert_message_text "Redacted!"
    end
  end

  test "deleting messages" do
    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room rooms(:designers)

      assert_message_text "Third time's a charm."
    end

    within_message messages(:third) do
      reveal_message_actions
      find(".message__edit-btn").click

      accept_confirm do
        click_on "Delete message"
      end
    end

    using_session("Kevin") do
      assert_message_text "Third time's a charm.", count: 0
    end
  end

  test "a message sent while the one before is on its way waits for it" do
    record_messages_marked_failed

    taking_longer_to_post "Slow one" do
      send_message_without_waiting "Slow one"
      send_message_without_waiting "Quick one"

      assert_selector ".message[data-message-id]:not([data-pending-message]) .message__body", text: "Quick one", wait: 5
    end

    assert_selector ".message[data-message-id]:not([data-pending-message]) .message__body", text: "Slow one"
    assert_empty page.evaluate_script("window.messagesMarkedFailed")
    assert_equal [ "Slow one", "Quick one" ], rooms(:designers).messages.ordered.last(2).map { it.plain_text_body.strip }
  end

  test "a message isn't lost when the next one is sent before it left the browser" do
    holding_back_posts_of "Held one" do
      join_room rooms(:designers)

      send_message_without_waiting "Held one"
      send_message_without_waiting "Next one"

      assert_selector ".message[data-message-id]:not([data-pending-message]) .message__body", text: "Held one", wait: 5
    end

    assert_selector ".message[data-message-id]:not([data-pending-message]) .message__body", text: "Next one"
    assert_equal [ "Held one", "Next one" ], rooms(:designers).messages.ordered.last(2).map { it.plain_text_body.strip }
  end

  test "a message that isn't answered holds up the next one for ten seconds at most" do
    holding_back_posts_of "Stuck one", seconds: 30 do
      join_room rooms(:designers)

      send_message_without_waiting "Stuck one"
      send_message_without_waiting "Next one"

      assert_selector ".message[data-message-id]:not([data-pending-message]) .message__body", text: "Next one", wait: 13
      assert_selector "[data-pending-message] .message__body", text: "Stuck one"
    end
  end

  test "sending to a room deleted meanwhile says so, and marks the message failed" do
    posting_to_a_room_thats_gone do
      send_message_without_waiting "Anyone here?"

      within ".composer" do
        assert_text "This room was deleted."
        assert_no_selector "form"
      end
      assert_selector ".message--failed .message__body", text: "Anyone here?"
    end
  end

  test "sending a message stops showing its author as typing" do
    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room rooms(:designers)
      type_in_composer "On my way"
    end

    assert_selector ".typing-indicator--active", text: "Kevin"

    using_session("Kevin") do
      press_in_composer :enter
    end

    # Sooner than the indicator gives up on its own, after five seconds without news.
    assert_no_selector ".typing-indicator--active", wait: 3
  end

  test "a message the server refuses is marked failed, and the next one is still sent" do
    refusing_posts_of "Refused one" do
      send_message_without_waiting "Refused one"
      send_message_without_waiting "Fine one"

      assert_selector ".message--failed .message__body", text: "Refused one"
      assert_selector ".message[data-message-id]:not([data-pending-message]) .message__body", text: "Fine one"
    end
  end

  test "a message sent after the session ended, as on signing out in another tab, leads to signing in" do
    users(:jz).sessions.destroy_all

    send_message_without_waiting "Still there?"

    assert_current_path new_session_path
  end

  test "a message that can't reach the server is marked failed" do
    page.driver.browser.network_conditions = { offline: true, latency: 0, throughput: 0 }

    send_message_without_waiting "Lost in space"

    assert_selector ".message--failed .message__body", text: "Lost in space"
  ensure
    page.driver.browser.delete_network_conditions
  end

  private
    def send_message_without_waiting(text)
      type_in_composer text
      press_in_composer :enter
      assert_no_selector "#composer lexxy-editor", text: text
    end

    def record_messages_marked_failed
      page.execute_script <<~JS
        window.messagesMarkedFailed = []
        new MutationObserver(() => {
          for (const message of document.querySelectorAll(".message.message--failed")) {
            window.messagesMarkedFailed.push(message.querySelector(".message__body").innerText)
          }
        }).observe(document.querySelector(".messages"), { subtree: true, attributes: true, attributeFilter: [ "class" ] })
      JS
    end

    # The server takes a second to post a message with this text, as when it's busy.
    # Posting finds no room, as when it was deleted meanwhile, while the rest of the page carries on: deleting it for
    # real also sends the page's own requests for the room to a not found.
    def posting_to_a_room_thats_gone
      Message.define_singleton_method(:create_with_attachment!) { |_attributes| raise ActiveRecord::RecordNotFound }

      yield
    ensure
      Message.singleton_class.remove_method(:create_with_attachment!)
    end

    def taking_longer_to_post(text)
      Message.define_singleton_method(:create_with_attachment!) do |attributes|
        sleep 1 if attributes[:body].to_s.include?(text)
        super(attributes)
      end

      yield
    ensure
      Message.singleton_class.remove_method(:create_with_attachment!)
    end

    # The server answers 422 for a message with this text, as it would for any refused request.
    def refusing_posts_of(text)
      show_exceptions = Rails.application.env_config["action_dispatch.show_exceptions"]
      Rails.application.env_config["action_dispatch.show_exceptions"] = :rescuable

      Message.define_singleton_method(:create_with_attachment!) do |attributes|
        raise ActiveRecord::RecordInvalid if attributes[:body].to_s.include?(text)
        super(attributes)
      end

      yield
    ensure
      Message.singleton_class.remove_method(:create_with_attachment!)
      Rails.application.env_config["action_dispatch.show_exceptions"] = show_exceptions
    end

    # The browser holds a post with this text for a while before it sends it, as on a slow or reconnecting network; one
    # cancelled meanwhile never reaches the server.
    def holding_back_posts_of(text, seconds: 1.5)
      script = page.driver.browser.execute_cdp "Page.addScriptToEvaluateOnNewDocument", source: <<~JS
        const fetch = window.fetch
        window.fetch = (resource, options = {}) => {
          if (!String(options.body?.get?.("message[body]")).includes(#{text.to_json})) return fetch(resource, options)

          return new Promise((resolve, reject) => {
            const timer = setTimeout(() => fetch(resource, options).then(resolve, reject), #{(seconds * 1000).round})
            options.signal?.addEventListener("abort", () => {
              clearTimeout(timer)
              reject(new DOMException("The request was cancelled.", "AbortError"))
            })
          })
        }
      JS

      yield
    ensure
      page.driver.browser.execute_cdp "Page.removeScriptToEvaluateOnNewDocument", identifier: script["identifier"] if script
    end
end
