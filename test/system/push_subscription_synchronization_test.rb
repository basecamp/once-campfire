require "application_system_test_case"
require "timeout"

class PushSubscriptionSynchronizationTest < ApplicationSystemTestCase
  setup do
    install_fake_push_subscription
  end

  test "rapid Turbo visits are debounced and a later visit repairs a deleted subscription" do
    subscription = push_subscriptions(:jz_chrome)
    endpoint = subscription.endpoint
    previous_session_id = subscription.session_id
    sign_in users(:jz).email_address
    join_room rooms(:designers)

    Timeout.timeout(5) do
      sleep 0.05 while subscription.reload.session_id == previous_session_id
    end
    initial_count = page.evaluate_script("window.pushSynchronizationCountForTest")
    page.execute_script <<~JAVASCRIPT
      window.pushSynchronizationNowForTest = Date.now();
      Date.now = () => window.pushSynchronizationNowForTest;
    JAVASCRIPT

    click_on "Search"
    click_on "Exit search"
    assert_equal initial_count, page.evaluate_script("window.pushSynchronizationCountForTest")

    subscription.destroy!
    page.execute_script("window.pushSynchronizationNowForTest += 30001")
    click_on "Search"
    assert_current_path searches_path
    click_on "Exit search"
    assert_current_path room_path(rooms(:designers))
    Timeout.timeout(5) do
      sleep 0.05 until Push::Subscription.exists?(endpoint:)
    end

    assert_equal initial_count + 1, page.evaluate_script("window.pushSynchronizationCountForTest")
    assert_equal Session.order(:id).last, Push::Subscription.find_by!(endpoint:).session
  end

  test "rotating either capability key triggers synchronization on the live page" do
    fixture = push_subscriptions(:jz_chrome)
    rotated_auth_key = Base64.urlsafe_encode64("b" * Push::Subscription::AUTH_KEY_BYTES, padding: false)
    sign_in users(:jz).email_address
    join_room rooms(:designers)
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script("window.pushSynchronizationCountForTest") >= 1
    end
    initial_count = page.evaluate_script("window.pushSynchronizationCountForTest")
    page.execute_script("window.pushCapabilityForTest.keys.auth = #{rotated_auth_key.to_json}")

    click_on "Search"
    click_on "Exit search"

    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script("window.pushSynchronizationCountForTest") > initial_count &&
        Push::Subscription.exists?(endpoint: fixture.endpoint, auth_key: rotated_auth_key)
    end
    assert Push::Subscription.exists?(endpoint: fixture.endpoint, auth_key: rotated_auth_key)
  end

  test "enrollment is single flight and exposes retry feedback" do
    install_delayed_push_enrollment
    sign_in users(:jz).email_address
    join_room rooms(:designers)
    page.execute_script <<~JAVASCRIPT
      window.failPushEnrollmentForTest = true;
      const bell = document.querySelector("[data-notifications-target='bell']");
      bell.click();
      bell.click();
    JAVASCRIPT

    assert_selector "[data-notifications-target='bell'][disabled][aria-busy]"
    assert_selector "[data-notifications-target='bell'] .for-screen-reader", text: "Enabling notifications…", visible: :all
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script("Boolean(window.releasePushEnrollmentForTest)")
    end
    assert_equal 1, page.evaluate_script("window.pushSubscribeCallsForTest")
    page.execute_script("window.releasePushEnrollmentForTest()")

    assert_button "Notifications could not be enabled. Try again.", wait: 5
    page.execute_script("window.failPushEnrollmentForTest = false")
    click_on "Notifications could not be enabled. Try again."
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script("Boolean(window.releasePushEnrollmentForTest)")
    end
    page.execute_script("window.releasePushEnrollmentForTest()")

    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script("window.pushSynchronizationCountForTest") >= 1
    end
    assert_equal 2, page.evaluate_script("window.pushSubscribeCallsForTest")
    assert_no_selector "[data-notifications-target='bell'][aria-busy]"
  end

  private
    def install_fake_push_subscription
      fixture = push_subscriptions(:jz_chrome)
      endpoint = fixture.endpoint.to_json
      p256dh_key = fixture.p256dh_key.to_json
      auth_key = fixture.auth_key.to_json
      install_new_document_script <<~JAVASCRIPT
        window.pushCapabilityForTest = {
          endpoint: #{endpoint},
          keys: { p256dh: #{p256dh_key}, auth: #{auth_key} }
        };
        window.pushSynchronizationCountForTest = 0;
        const fetchForPushSynchronizationTest = window.fetch;
        window.fetch = function(input, options = {}) {
          const request = input && typeof input === "object" && typeof input.url === "string" ? input : null;
          const url = new URL(request ? request.url : String(input), window.location.origin);
          const method = String(request?.method || options.method || "GET").toUpperCase();
          if (method === "POST" && url.pathname.endsWith("/push_subscriptions")) {
            window.pushSynchronizationCountForTest += 1;
          }
          return fetchForPushSynchronizationTest(input, options);
        };
        const subscription = {
          get endpoint() { return window.pushCapabilityForTest.endpoint; },
          toJSON: () => window.pushCapabilityForTest,
          unsubscribe: () => Promise.resolve(true)
        };
        const registration = {
          pushManager: {
            getSubscription: () => Promise.resolve(subscription),
            subscribe: () => Promise.resolve(subscription)
          }
        };
        Object.defineProperty(navigator, "serviceWorker", {
          configurable: true,
          value: {
            getRegistration: () => Promise.resolve(registration),
            register: () => Promise.resolve(registration)
          }
        });
        Object.defineProperty(window, "Notification", {
          configurable: true,
          value: { permission: "granted", requestPermission: () => Promise.resolve("granted") }
        });
      JAVASCRIPT
    end


    def install_delayed_push_enrollment
      install_new_document_script <<~JAVASCRIPT
        window.pushSubscribeCallsForTest = 0;
        const enrollmentSubscription = {
          get endpoint() { return window.pushCapabilityForTest.endpoint; },
          toJSON: () => window.pushCapabilityForTest,
          unsubscribe: () => Promise.resolve(true)
        };
        const enrollmentRegistration = {
          pushManager: {
            getSubscription: () => Promise.resolve(null),
            subscribe: () => {
              window.pushSubscribeCallsForTest += 1;
              return new Promise((resolve, reject) => {
                window.releasePushEnrollmentForTest = () => {
                  delete window.releasePushEnrollmentForTest;
                  if (window.failPushEnrollmentForTest) {
                    reject(new Error("simulated enrollment failure"));
                  } else {
                    resolve(enrollmentSubscription);
                  }
                };
              });
            }
          }
        };
        Object.defineProperty(navigator, "serviceWorker", {
          configurable: true,
          value: {
            getRegistration: () => Promise.resolve(enrollmentRegistration),
            register: () => Promise.resolve(enrollmentRegistration)
          }
        });
      JAVASCRIPT
    end
end
