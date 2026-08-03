require "application_system_test_case"
require "timeout"

class DraftPersistenceTest < ApplicationSystemTestCase
  test "expiry warning tells the truth when session storage rejects writes" do
    reject_session_storage_writes
    sign_in users(:jz).email_address
    Session.order(:id).last.update!(expires_at: 4.minutes.from_now)

    join_room rooms(:designers)

    assert_text "Browser draft storage is unavailable; copy any unsent text before signing in again."
    assert_no_text "Saved text drafts in this tab will be restored."
  end

  test "a newer draft remains persisted when an earlier submission fails" do
    user = users(:jz)
    room = rooms(:designers)
    sign_in user.email_address
    join_room room
    reject_message_posts_after_delay
    fill_in_rich_text_area "message_body", with: "Earlier submission"

    click_on "Send Message"
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script("document.querySelector('trix-editor').textContent.trim()") == ""
    end
    fill_in_rich_text_area "message_body", with: "Newer unsent draft"

    assert_selector ".message--failed", wait: 5
    draft_key = "campfire-draft:#{user.id}:#{room.id}"
    stored_draft = page.evaluate_script("sessionStorage.getItem(#{draft_key.to_json})")
    pending_submissions = page.evaluate_script("JSON.parse(sessionStorage.getItem(#{"#{draft_key}:pending".to_json}))")
    pending_submission = pending_submissions.sole

    assert_includes stored_draft, "Newer unsent draft"
    assert_includes pending_submission.fetch("body"), "Earlier submission"
    assert_predicate pending_submission.fetch("clientMessageId"), :present?
    within "#message_#{room.id}_#{pending_submission.fetch("clientMessageId")}" do
      assert_text "Earlier submission"
      assert_text "Message was not sent."
      assert_button "Retry sending"
    end

    page.refresh

    assert_selector "#message_#{room.id}_#{pending_submission.fetch("clientMessageId")}.message--failed", wait: 5
    within "#message_#{room.id}_#{pending_submission.fetch("clientMessageId")}" do
      assert_text "Earlier submission"
      assert_button "Retry sending"
    end
    assert_equal "Newer unsent draft",
      page.evaluate_script("document.querySelector('trix-editor').editor.getDocument().toString().trim()")
    assert_equal pending_submissions,
      page.evaluate_script("JSON.parse(sessionStorage.getItem(#{"#{draft_key}:pending".to_json}))")
  end

  test "retry after a committed response drop reuses the original client id" do
    user = users(:jz)
    room = rooms(:designers)
    body = "Committed before the response disappeared"
    sign_in user.email_address
    join_room room
    drop_first_message_response_after_commit
    page.execute_script("document.querySelector('#message-area turbo-cable-stream-source')?.remove()")
    fill_in_rich_text_area "message_body", with: body

    click_on "Send Message"

    assert_selector ".message--failed", text: body, wait: 5
    draft_key = "campfire-draft:#{user.id}:#{room.id}"
    pending_submission = page.evaluate_script(
      "JSON.parse(sessionStorage.getItem(#{"#{draft_key}:pending".to_json}))[0]"
    )
    client_message_id = pending_submission.fetch("clientMessageId")
    messages = room.messages.where(creator: user, client_message_id:)
    assert_equal body, pending_submission.fetch("body").then { ActionText::Content.new(_1).to_plain_text.to_s.strip }
    assert_equal 1, messages.count

    within "#message_#{room.id}_#{client_message_id}" do
      assert_text "Message was not sent."
      find_button("Retry sending").send_keys(:enter)
    end

    assert_selector "#message_#{room.id}_#{client_message_id}[data-message-id]", text: body, wait: 5
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script("document.querySelector('#message-delivery-status').textContent") == "Message sent"
    end
    assert_equal "Message sent", page.evaluate_script("document.querySelector('#message-delivery-status').textContent")
    assert_equal "message_#{room.id}_#{client_message_id}", page.evaluate_script("document.activeElement.id")
    assert_equal 1, messages.reload.count
    assert_equal client_message_id, messages.first.client_message_id
    assert_nil page.evaluate_script("sessionStorage.getItem(#{"#{draft_key}:pending".to_json})")
  end

  private
    def reject_session_storage_writes
      install_new_document_script <<~JAVASCRIPT
        const originalSetItem = Storage.prototype.setItem;
        Storage.prototype.setItem = function(...args) {
          if (this === window.sessionStorage) throw new DOMException("blocked", "SecurityError");
          return originalSetItem.apply(this, args);
        };
      JAVASCRIPT
    end

    def reject_message_posts_after_delay
      execute_script_in_page_realm <<~JAVASCRIPT
        document.addEventListener("turbo:before-fetch-request", (event) => {
          const { fetchOptions, url } = event.detail;
          if (fetchOptions.method === "POST" && url.pathname.includes("/rooms/") && url.pathname.endsWith("/messages")) {
            event.detail.fetchRequest = {
              response: new Promise((_, reject) => setTimeout(() => reject(new TypeError("simulated network failure")), 750))
            };
          }
        });
      JAVASCRIPT
    end

    def drop_first_message_response_after_commit
      execute_script_in_page_realm <<~JAVASCRIPT
        let droppedMessageResponse = false;
        document.addEventListener("turbo:before-fetch-request", (event) => {
          const { fetchOptions, url } = event.detail;
          if (!droppedMessageResponse && fetchOptions.method === "POST" && url.pathname.includes("/rooms/") && url.pathname.endsWith("/messages")) {
            droppedMessageResponse = true;
            event.detail.fetchRequest = {
              response: window.fetch(url.href, fetchOptions).then(async (response) => {
                await response.text();
                throw new TypeError("simulated response loss after commit");
              })
            };
          }
        });
      JAVASCRIPT
    end
end
