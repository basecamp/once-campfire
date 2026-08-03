require "application_system_test_case"
require "timeout"

class MessageSubmissionFailureTest < ApplicationSystemTestCase
  setup do
    sign_in users(:jz).email_address
    join_room rooms(:designers)
  end

  test "membership revocation offers to restore an uncommitted message" do
    body = "Do not deliver after membership revocation"
    capture_next_composer_submission
    fill_in_rich_text_area "message_body", with: body
    membership = memberships(:jz_designers)
    membership_attributes = membership.attributes
    Membership.where(id: membership.id).delete_all

    click_on "Send Message"

    client_message_id = assert_permanent_pending_message body, room_id: rooms(:designers).id
    assert_not Message.exists?(creator: users(:jz), client_message_id:)

    within "#message_#{rooms(:designers).id}_#{client_message_id}" do
      find_button("Restore message").send_keys(:enter)
    end

    assert_no_selector "#message_#{rooms(:designers).id}_#{client_message_id}"
    assert_equal body, composer_text
    assert_nil pending_submissions(rooms(:designers).id)
  ensure
    Membership.insert_all!([ membership_attributes ]) if membership_attributes && !Membership.exists?(membership.id)
  end

  test "room deletion offers to discard an uncommitted message" do
    user = users(:jz)
    room = Rooms::Closed.create_for({ name: "Disappearing room" }, users: [ user ], actor: user)
    join_room room
    body = "Do not deliver after room deletion"
    capture_next_composer_submission
    fill_in_rich_text_area "message_body", with: body
    room.destroy!

    click_on "Send Message"

    client_message_id = assert_permanent_pending_message body, room_id: room.id
    assert_not Message.exists?(creator: user, client_message_id:)

    within "#message_#{room.id}_#{client_message_id}" do
      find_button("Discard message").send_keys(:enter)
    end

    assert_no_selector "#message_#{room.id}_#{client_message_id}"
    assert_equal "", composer_text
    assert_nil pending_submissions(room.id)
  end

  test "forbidden oversized and invalid messages are permanent failures" do
    install_message_failure_interceptor

    {
      403 => "access is no longer available",
      409 => "current form",
      413 => "too large to send",
      422 => "current form"
    }.each do |status, message|
      body = "Rejected with #{status}"
      page.execute_script("window.nextMessageFailureStatusForTest = #{status}")
      fill_in_rich_text_area "message_body", with: body
      click_on "Send Message"

      failed_message = find(".message--failed", text: body)
      failed_message_id = failed_message[:id]
      within failed_message do
        assert_selector "[role='alert']", text: message
        assert_button "Restore message"
        find_button("Discard message").send_keys(:enter)
      end
      assert_no_selector "##{failed_message_id}"
    end
  end

  test "a transient failure remains retryable" do
    install_message_failure_interceptor
    body = "Retry after a temporary outage"
    page.execute_script("window.nextMessageFailureStatusForTest = 503")
    fill_in_rich_text_area "message_body", with: body
    click_on "Send Message"

    failed_message = find(".message--failed", text: body)
    failed_message_id = failed_message[:id]
    client_message_id = failed_message["data-client-message-id"]
    within failed_message do
      assert_selector "[role='alert']", text: "Message was not sent."
      assert_button "Retry sending"
      assert_no_button "Restore message"
      find_button("Retry sending").send_keys(:enter)
    end

    assert_selector "##{failed_message_id}[data-message-id]", wait: 10
    assert_equal 1, rooms(:designers).messages.where(
      creator: users(:jz), client_message_id:
    ).count
  end

  test "restoring persisted failures preserves permalink pagination" do
    room = rooms(:designers)
    message = room.messages.ordered.first
    created_at = room.messages.maximum(:created_at) + 1.second
    Message.insert_all!(45.times.map do |index|
      {
        room_id: room.id,
        creator_id: users(:jason).id,
        client_message_id: "permalink-page-#{index}",
        created_at: created_at + index.seconds,
        updated_at: created_at + index.seconds
      }
    end)
    latest_message = room.messages.order(:created_at).last
    client_message_id = "restored-permalink-failure"
    body = "Pending while viewing a permalink"
    page.execute_script <<~JAVASCRIPT
      sessionStorage.setItem(
        #{pending_submissions_key(room.id).to_json},
        JSON.stringify([{
          clientMessageId: #{client_message_id.to_json},
          body: #{"<div>#{body}</div>".to_json},
          failureStatus: 404
        }])
      );
    JAVASCRIPT

    visit room_at_message_url(room, message.id)

    assert_selector ".message.search-highlight[data-message-id='#{message.id}']"
    assert_selector "#message_#{room.id}_#{client_message_id}.message--failed", text: body
    assert_button "Restore message"
    assert_selector ".message.search-highlight[data-message-id='#{message.id}']"
    assert_no_selector ".message[data-message-id='#{latest_message.id}']"

    page.execute_script("document.querySelector('.messages').scrollTop = document.querySelector('.messages').scrollHeight")

    assert_selector ".message[data-message-id='#{latest_message.id}']", wait: 10
    assert_selector "#message_#{room.id}_#{client_message_id}.message--failed", text: body
  end

  private
    def capture_next_composer_submission
      page.execute_script <<~JAVASCRIPT
        delete window.composerSubmissionSucceededForTest;
        document.querySelector("#composer").addEventListener("turbo:submit-end", (event) => {
          window.composerSubmissionSucceededForTest = event.detail.success;
          window.composerSubmissionContentTypeForTest = event.detail.fetchResponse?.response.headers.get("Content-Type");
        }, { once: true });
      JAVASCRIPT
    end

    def assert_permanent_pending_message(body, room_id:)
      Timeout.timeout(5) do
        sleep 0.05 until page.evaluate_script("'composerSubmissionSucceededForTest' in window")
      end
      assert_equal false, page.evaluate_script("window.composerSubmissionSucceededForTest")
      assert_includes page.evaluate_script("window.composerSubmissionContentTypeForTest"), "text/vnd.turbo-stream.html"
      assert_selector "#composer"

      failed_message = find(".message--failed", text: body)
      client_message_id = failed_message["data-client-message-id"]
      within failed_message do
        assert_selector "[role='alert']", text: "access is no longer available"
        assert_button "Restore message"
        assert_button "Discard message"
        assert_no_button "Retry sending"
      end

      pending_submission = pending_submissions(room_id).first
      assert_equal client_message_id, pending_submission.fetch("clientMessageId")
      assert_includes pending_submission.fetch("body"), body

      client_message_id
    end

    def install_message_failure_interceptor
      install_new_document_script <<~JAVASCRIPT
        (() => {
          const fetch = window.fetch;
          window.fetch = function(input, options = {}) {
            const request = input && typeof input === "object" && typeof input.url === "string" ? input : null;
            const method = String(request?.method || options.method || "GET").toUpperCase();
            const url = new URL(request ? request.url : String(input), window.location.origin);
            const status = window.nextMessageFailureStatusForTest;
            const composerPath = new URL(document.querySelector("#composer").action).pathname;
            if (status && method === "POST" && url.pathname === composerPath) {
              delete window.nextMessageFailureStatusForTest;
              return Promise.resolve(new Response("", {
                status,
                headers: { "Content-Type": "text/vnd.turbo-stream.html" }
              }));
            }
            return fetch(input, options);
          };
        })();
      JAVASCRIPT
      page.refresh
      wait_for_cable_connection
    end

    def pending_submissions(room_id)
      page.evaluate_script <<~JAVASCRIPT
        (() => {
          const value = sessionStorage.getItem(#{pending_submissions_key(room_id).to_json});
          return value && JSON.parse(value);
        })()
      JAVASCRIPT
    end

    def pending_submissions_key(room_id)
      "campfire-draft:#{users(:jz).id}:#{room_id}:pending"
    end

    def composer_text
      page.evaluate_script("document.querySelector('trix-editor').editor.getDocument().toString().trim()")
    end
end
