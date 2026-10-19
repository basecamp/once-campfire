require "application_system_test_case"

class PushSubscriptionResyncTest < ApplicationSystemTestCase
  ENDPOINT = "https://fcm.googleapis.com/fcm/send/system-test"

  setup do
    stub_web_push_dns_resolution
    fake_a_browser_push_subscription
  end

  teardown do
    page.execute_script("localStorage.clear()") if page.current_url.start_with?("http")
  end

  test "a browser posts its subscription again once per session, so it survives a password change" do
    sign_in "david@37signals.com"
    assert_subscription_registered
    first_sync = subscription.updated_at

    join_room rooms(:hq)
    assert_equal first_sync, subscription.reload.updated_at, "posted again in the same session"

    change_password
    assert_nil Push::Subscription.find_by(endpoint: ENDPOINT)

    join_room rooms(:hq)
    assert_subscription_registered
    assert_not page.evaluate_script("localStorage.getItem('unsubscribed-for-test')")
  end

  test "a subscription the server refuses stays in the browser" do
    stub_dns_resolution("169.254.169.254")

    sign_in "david@37signals.com"
    Timeout.timeout(5) { sleep 0.1 until page.evaluate_script("localStorage.getItem('push-subscription-synced-session')") }
    join_room rooms(:hq)

    assert_not Push::Subscription.exists?(endpoint: ENDPOINT)
    assert_not page.evaluate_script("localStorage.getItem('unsubscribed-for-test')")
  end

  private
    # Headless Chrome has no push service, so stand in for the subscription the service worker would hold.
    def fake_a_browser_push_subscription
      page.driver.browser.execute_cdp "Page.addScriptToEvaluateOnNewDocument", source: <<~JS
        Object.defineProperty(Notification, "permission", { get: () => "granted" })
        const subscription = {
          toJSON: () => ({ endpoint: "#{ENDPOINT}", keys: { p256dh: "p256dh-key", auth: "auth-key" } }),
          unsubscribe: async () => { localStorage.setItem("unsubscribed-for-test", "true") }
        }
        navigator.serviceWorker.getRegistration = async () => ({ pushManager: { getSubscription: async () => subscription } })
      JS
    end

    def change_password
      visit user_profile_url
      find("input[name='user[password_challenge]']").fill_in with: "secret123456"
      find("input[name='user[password]']").fill_in with: "a new secret123456"
      find("input[name='user[password]']").send_keys :enter
      assert_selector ".flash", text: "✓"
    end

    def assert_subscription_registered
      assert_selector "[data-controller~=notifications]", visible: :all
      Timeout.timeout(5) { sleep 0.1 until Push::Subscription.exists?(endpoint: ENDPOINT, user: users(:david)) }
    end

    def subscription
      Push::Subscription.find_by!(endpoint: ENDPOINT)
    end
end
