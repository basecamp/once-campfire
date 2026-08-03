require "application_system_test_case"
require "timeout"

class WebShareTest < ApplicationSystemTestCase
  setup do
    install_fake_web_share
    @message = rooms(:designers).messages.first
    @message.attachment.attach(
      io: StringIO.new("private share bytes"), filename: "private.txt", content_type: "text/plain"
    )
  end

  test "shares the authenticated attachment with its original filename" do
    delay_first_attachment_fetch
    sign_in users(:jz).email_address
    join_room rooms(:designers)

    click_on "Share private.txt"

    assert_selector "[data-web-share-target='label']", text: "Preparing private.txt for sharing...", visible: true
    assert_not page.evaluate_script("window.shareCalledForTest")
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script("Boolean(window.releaseSharePreparationForTest)")
    end
    page.execute_script("window.releaseSharePreparationForTest()")

    assert_button "Share private.txt now", wait: 5
    assert_not page.evaluate_script("window.shareCalledForTest")
    click_on "Share private.txt now"
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script("window.sharedFileForTest")
    end

    shared = page.evaluate_script("window.sharedFileForTest")
    assert page.evaluate_script("window.activationAtShareForTest")
    assert_equal "private.txt", shared.fetch("name")
    assert_equal "text/plain", shared.fetch("type")
    assert_equal @message.attachment.byte_size, shared.fetch("size")
    assert_equal 1, page.evaluate_script("window.shareCallCountForTest")
    assert_button "private.txt was shared. Share again"
    assert page.evaluate_script("document.activeElement.matches('[data-controller=web-share]')")

    click_on "private.txt was shared. Share again"

    assert_button "Share private.txt now", wait: 5
    assert_equal 1, page.evaluate_script("window.shareCallCountForTest")
  end

  test "does not share an authentication redirect" do
    sign_in users(:jz).email_address
    join_room rooms(:designers)
    Session.order(:id).last.destroy!

    click_on "Share private.txt"

    assert_selector ".flash--error[data-web-share-failure]", text: /could not be shared/, wait: 5
    assert_not page.evaluate_script("window.shareCalledForTest")
    assert page.evaluate_script("document.activeElement.matches('[data-controller=web-share]')")
  end

  test "expires prepared attachment data before sharing" do
    capture_prepared_data_expiration
    sign_in users(:jz).email_address
    join_room rooms(:designers)

    click_on "Share private.txt"
    assert_button "Share private.txt now", wait: 5
    assert page.evaluate_script("Boolean(window.expirePreparedShareForTest)")
    page.execute_script("window.expirePreparedShareForTest()")

    assert_button "Share private.txt"
    click_on "Share private.txt"
    assert_button "Share private.txt now", wait: 5
    assert_equal 0, page.evaluate_script("window.shareCallCountForTest")
  end

  private
    def install_fake_web_share
      install_new_document_script <<~JAVASCRIPT
        window.shareCalledForTest = false;
        window.shareCallCountForTest = 0;
        window.shareActivationForTest = false;
        document.addEventListener("click", () => {
          window.shareActivationForTest = true;
          setTimeout(() => window.shareActivationForTest = false, 0);
        }, true);
        Object.defineProperty(navigator, "canShare", {
          configurable: true,
          value: () => true
        });
        Object.defineProperty(navigator, "share", {
          configurable: true,
          value: async (data) => {
            window.activationAtShareForTest = window.shareActivationForTest;
            if (!window.activationAtShareForTest) throw new DOMException("User activation is required", "NotAllowedError");
            window.shareCalledForTest = true;
            window.shareCallCountForTest += 1;
            const file = data.files?.[0];
            window.sharedFileForTest = file && { name: file.name, type: file.type, size: file.size };
          }
        });
      JAVASCRIPT
    end

    def capture_prepared_data_expiration
      install_new_document_script <<~JAVASCRIPT
        const setTimeoutForShareExpirationTest = window.setTimeout.bind(window);
        const clearTimeoutForShareExpirationTest = window.clearTimeout.bind(window);
        const preparedShareTimerForTest = 987654321;
        window.setTimeout = (callback, delay, ...args) => {
          if (delay === 60000) {
            window.expirePreparedShareForTest = callback;
            return preparedShareTimerForTest;
          }
          return setTimeoutForShareExpirationTest(callback, delay, ...args);
        };
        window.clearTimeout = (timer) => {
          if (timer !== preparedShareTimerForTest) clearTimeoutForShareExpirationTest(timer);
        };
      JAVASCRIPT
    end

    def delay_first_attachment_fetch
      install_new_document_script <<~JAVASCRIPT
        const originalFetch = window.fetch;
        let delayedAttachmentFetch = false;
        window.fetch = async function(input, options = {}) {
          const url = input instanceof Request ? input.url : input.toString();
          const path = new URL(url, window.location.origin).pathname;
          if (!delayedAttachmentFetch && path.endsWith("/attachment")) {
            delayedAttachmentFetch = true;
            await new Promise((resolve) => window.releaseSharePreparationForTest = resolve);
          }
          return originalFetch(input, options);
        };
      JAVASCRIPT
    end
end
