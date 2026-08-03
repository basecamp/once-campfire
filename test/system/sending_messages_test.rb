require "application_system_test_case"
require "timeout"

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

    using_session("Kevin") do
      join_room rooms(:designers)
      assert_message_text "Is this thing on?"

      send_message "👍👍"
    end

    join_room rooms(:designers)
    assert_message_text "👍👍"
  end

  test "rapid duplicate send actions create one nonblank message" do
    body = "Send this exactly once"
    fill_in_rich_text_area "message_body", with: body

    page.execute_script <<~JAVASCRIPT
      const button = document.querySelector("button[name=send]");
      button.click();
      button.click();
    JAVASCRIPT

    assert_message_text body, count: 1
    Timeout.timeout(5) do
      sleep 0.05 until rooms(:designers).messages.reload.any? { |message| message.plain_text_body == body }
    end

    assert_equal 1, rooms(:designers).messages.reload.count { |message| message.plain_text_body == body }
    assert_not rooms(:designers).messages.order(:id).last.plain_text_body.blank?
  end

  test "a slow send uses an immutable body without clearing newer text" do
    original_body = "First immutable submission"
    newer_body = "Newer editor text"
    delay_pending_message_insertion
    fill_in_rich_text_area "message_body", with: original_body

    click_on "Send Message"
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script("Boolean(window.releasePendingMessageInsertionForTest)")
    end
    fill_in_rich_text_area "message_body", with: newer_body
    page.execute_script("window.releasePendingMessageInsertionForTest()")

    assert_selector ".message[data-message-id]", text: original_body, wait: 5
    assert_equal newer_body,
      page.evaluate_script("document.querySelector('trix-editor').editor.getDocument().toString().trim()")
    assert_equal 1, rooms(:designers).messages.count { |message| message.plain_text_body == original_body }
    assert_equal 0, rooms(:designers).messages.count { |message| message.plain_text_body == newer_body }
  end

  test "a locally visible cross-creator client ID collision is rerolled before submission" do
    room = rooms(:designers)
    existing = room.messages.create!(
      creator: users(:jason), body: "Existing collision owner", client_message_id: "i"
    )
    page.refresh
    fill_in_rich_text_area "message_body", with: "New collision-safe message"
    page.execute_script <<~JAVASCRIPT
      (() => {
        const random = Math.random.bind(Math);
        let calls = 0;
        Math.random = () => ++calls === 1 ? 0.5 : random();
      })();
    JAVASCRIPT

    click_on "Send Message"

    assert_selector "##{ActionView::RecordIdentifier.dom_id(existing)}", text: "Existing collision owner"
    assert_selector ".message[data-message-id]", text: "New collision-safe message", wait: 5
    created = room.messages.where(creator: users(:jz)).order(:id).last
    assert_equal "New collision-safe message", created.plain_text_body
    assert_not_equal existing.client_message_id, created.client_message_id
    dom_ids = page.evaluate_script(
      "Array.from(document.querySelectorAll('.message[data-message-id]'), (message) => message.id)"
    )
    assert_equal dom_ids.uniq, dom_ids
  end

  test "failed file uploads retry in place and unpicking cancels their optimistic message" do
    install_file_upload_interceptor
    file = Rails.root.join("test/fixtures/files/earth.png")

    page.execute_script("window.fileUploadFailuresForTest = 1")
    attach_file file, make_visible: true
    click_on "Send Message"

    assert_selector ".message--failed", text: "File was not uploaded", wait: 5
    canceled_message_id = find(".message--failed")[:id]
    find(".composer__file").click
    assert_no_selector "##{canceled_message_id}"
    assert_no_selector ".composer__file"

    page.execute_script("window.fileUploadFailuresForTest = 1")
    attach_file file, make_visible: true
    click_on "Send Message"

    assert_selector ".message--failed", text: "File was not uploaded", wait: 5
    retried_message_id = find(".message--failed")[:id]
    page.execute_script("window.delayNextFileUploadForTest = true")
    click_on "Send Message"
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script("Boolean(window.releaseFileUploadForTest)")
    end

    assert_equal 1, page.evaluate_script("document.querySelectorAll(#{"##{retried_message_id}".to_json}).length")
    assert_no_selector "##{retried_message_id}.message--failed"
    page.execute_script("window.releaseFileUploadForTest()")

    assert_selector "##{retried_message_id}[data-message-id]", wait: 10
    client_message_id = find("##{retried_message_id}")["data-client-message-id"]
    assert_equal 1, rooms(:designers).messages.where(creator: users(:jz), client_message_id:).count
  end

  test "a committed file is not requeued when its response is lost" do
    install_file_upload_interceptor
    page.execute_script(<<~JAVASCRIPT)
      window.delayNextFileUploadForTest = true;
      window.dropNextFileUploadResponseForTest = true;
    JAVASCRIPT
    attach_file Rails.root.join("test/fixtures/files/earth.png"), make_visible: true

    click_on "Send Message"
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script("Boolean(window.releaseFileUploadForTest)")
    end
    pending_message_id = page.evaluate_script(
      "document.querySelector('.message__pending-upload').closest('.message').id"
    )
    page.execute_script("window.releaseFileUploadForTest()")

    assert_selector "##{pending_message_id}[data-message-id]", wait: 10
    assert_no_selector ".composer__file"
    assert_no_selector "##{pending_message_id}.message--failed"
    assert_equal 1, page.evaluate_script("document.querySelectorAll(#{"##{pending_message_id}".to_json}).length")
    client_message_id = find("##{pending_message_id}")["data-client-message-id"]
    assert_equal 1, rooms(:designers).messages.where(creator: users(:jz), client_message_id:).count
  end

  test "an uncertain upload cannot be unpicked and an idempotent retry confirms its commit" do
    install_file_upload_interceptor
    page.execute_script <<~JAVASCRIPT
      document.querySelector("#message-area turbo-cable-stream-source")?.remove();
      window.dropNextFileUploadResponseForTest = true;
    JAVASCRIPT
    attach_file Rails.root.join("test/fixtures/files/earth.png"), make_visible: true

    click_on "Send Message"

    failed = find(".message--failed", text: "Upload outcome is unknown", wait: 10)
    client_message_id = failed["data-client-message-id"]
    within failed do
      assert_button "Retry to confirm"
      assert_no_button "Discard attachment"
    end
    assert_no_button "Remove earth.png"
    assert_equal 1, rooms(:designers).messages.where(creator: users(:jz), client_message_id:).count

    within failed do
      find_button("Retry to confirm").send_keys(:enter)
    end

    assert_selector ".message[data-message-id][data-client-message-id='#{client_message_id}']", wait: 10
    assert_equal 1, rooms(:designers).messages.where(creator: users(:jz), client_message_id:).count
  end

  test "Turbo cache preparation removes file-backed optimistic state" do
    install_file_upload_interceptor
    page.execute_script("window.fileUploadFailuresForTest = 1")
    attach_file Rails.root.join("test/fixtures/files/earth.png"), make_visible: true
    click_on "Send Message"

    failed_id = find(".message--failed", text: "File was not uploaded", wait: 5)[:id]
    assert_button "Remove earth.png"
    page.execute_script("document.dispatchEvent(new Event('turbo:before-cache'))")

    assert_no_selector "##{failed_id}"
    assert_no_button "Remove earth.png"
  end

  test "selected attachment controls describe removal and release preview URLs" do
    page.execute_script <<~JAVASCRIPT
      (() => {
        const createObjectURL = URL.createObjectURL.bind(URL);
        const revokeObjectURL = URL.revokeObjectURL.bind(URL);
        window.createdObjectUrlsForTest = [];
        window.revokedObjectUrlsForTest = [];
        URL.createObjectURL = (object) => {
          const url = createObjectURL(object);
          window.createdObjectUrlsForTest.push(url);
          return url;
        };
        URL.revokeObjectURL = (url) => {
          window.revokedObjectUrlsForTest.push(url);
          revokeObjectURL(url);
        };
      })();
    JAVASCRIPT
    attach_file Rails.root.join("test/fixtures/files/earth.png"), make_visible: true

    control = find(".composer__file[aria-label='Remove earth.png'][title='Remove earth.png']")
    preview_url = page.evaluate_script("window.createdObjectUrlsForTest[0]")
    control.send_keys(:enter)

    assert_no_selector ".composer__file"
    assert_includes page.evaluate_script("window.revokedObjectUrlsForTest"), preview_url
    assert_selector "trix-editor[aria-label='Write a message']:focus"
  end

  test "upload progress is announced and a permanent rejection can restore the attachment" do
    install_file_upload_interceptor
    file = Rails.root.join("test/fixtures/files/earth.png")
    page.execute_script <<~JAVASCRIPT
      window.fileUploadProgressForTest = 42;
      window.delayNextFileUploadForTest = true;
    JAVASCRIPT
    attach_file file, make_visible: true
    click_on "Send Message"

    assert_selector "[role='progressbar'][aria-label='Uploading earth.png'][aria-valuenow='42'][aria-valuetext='42% uploaded']"
    page.execute_script("window.releaseFileUploadForTest()")
    assert_no_selector ".message__pending-upload", wait: 10

    page.execute_script("window.fileUploadFailureStatusForTest = 413")
    attach_file file, make_visible: true
    click_on "Send Message"

    failed_message = find(".message--failed", text: "File is too large to send.", wait: 10)
    failed_message_id = failed_message[:id]
    within failed_message do
      assert_button "Restore attachment"
      assert_button "Discard attachment"
      find_button("Restore attachment").send_keys(:enter)
    end

    assert_no_selector "##{failed_message_id}"
    assert_button "Remove earth.png"
    assert_equal "Remove earth.png", page.evaluate_script("document.activeElement.getAttribute('aria-label')")
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

      accept_confirm(wait: 5) do
        click_on "Delete message"
      end
    end

    using_session("Kevin") do
      assert_message_text "Third time's a charm.", count: 0
    end
  end

  private
    def delay_pending_message_insertion
      page.execute_script <<~JAVASCRIPT
        (() => {
          const element = document.querySelector("#message-area");
          const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "messages");
          const insertPendingMessage = controller.insertPendingMessage;

          controller.insertPendingMessage = function(...args) {
            return new Promise((resolve, reject) => {
              window.releasePendingMessageInsertionForTest = () => {
                delete window.releasePendingMessageInsertionForTest;
                controller.insertPendingMessage = insertPendingMessage;
                insertPendingMessage.apply(controller, args).then(resolve, reject);
              };
            });
          };
        })();
      JAVASCRIPT
    end

    def install_file_upload_interceptor
      evaluate_module_script_in_page_realm <<~JAVASCRIPT
        const imports = JSON.parse(document.querySelector("script[type='importmap']").textContent).imports;
        const { default: FileUploader } = await import(imports["models/file_uploader"]);
        const upload = FileUploader.prototype.upload;
        if (!document.querySelector("meta[name=csrf-token]")) {
          const csrfToken = document.createElement("meta");
          csrfToken.name = "csrf-token";
          csrfToken.content = "system-test";
          document.head.append(csrfToken);
        }
        window.fileUploadFailuresForTest = 0;
        window.fileUploadFailureStatusForTest = null;
        window.fileUploadProgressForTest = null;
        window.delayNextFileUploadForTest = false;
        window.dropNextFileUploadResponseForTest = false;

        FileUploader.prototype.upload = function() {
          if (window.fileUploadProgressForTest != null) {
            this.progressCallback(window.fileUploadProgressForTest, this.clientMessageId, this.file);
            window.fileUploadProgressForTest = null;
          }
          if (window.fileUploadFailureStatusForTest) {
            const error = new Error("simulated permanent upload failure");
            error.status = window.fileUploadFailureStatusForTest;
            window.fileUploadFailureStatusForTest = null;
            return Promise.reject(error);
          }
          if (window.fileUploadFailuresForTest > 0) {
            window.fileUploadFailuresForTest -= 1;
            return Promise.reject(new Error("simulated upload failure"));
          }

          const delayUpload = window.delayNextFileUploadForTest;
          const dropResponse = window.dropNextFileUploadResponseForTest;
          window.delayNextFileUploadForTest = false;
          window.dropNextFileUploadResponseForTest = false;
          const performUpload = () => upload.call(this).then((response) => {
            if (dropResponse) {
              const error = new Error("simulated response loss after commit");
              error.outcomeUnknown = true;
              throw error;
            }
            return response;
          });

          if (delayUpload) {
            return new Promise((resolve, reject) => {
              window.releaseFileUploadForTest = () => {
                delete window.releaseFileUploadForTest;
                performUpload().then(resolve, reject);
              };
            });
          }

          return performUpload();
        };

        return null;
      JAVASCRIPT
    end
end
