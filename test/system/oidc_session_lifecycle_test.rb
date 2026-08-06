require "application_system_test_case"
require "timeout"

class OidcSessionLifecycleTest < ApplicationSystemTestCase
  setup do
    install_fake_push_subscription
  end

  test "existing browser push subscription binds to the newly authenticated session" do
    subscription = push_subscriptions(:jz_chrome)
    previous_session_id = subscription.session_id
    sign_in users(:jz).email_address

    join_room rooms(:designers)
    Timeout.timeout(5) do
      sleep 0.05 while subscription.reload.session_id == previous_session_id
    end

    assert_equal users(:jz), subscription.session.user
    assert_not_equal previous_session_id, subscription.session_id
  end

  test "service worker cleanup failure cannot prevent authoritative logout" do
    sign_in users(:jz).email_address
    visit user_profile_url

    click_on "Log out"

    assert_selector "input[name='email_address']", wait: 5
  end

  test "warns before an absolute session expiry" do
    sign_in users(:jz).email_address
    Session.order(:id).last.update!(expires_at: 4.minutes.from_now)

    visit room_url(rooms(:designers))

    assert_text "Your session expires in less than five minutes"
    assert_text "send pending attachments before signing in again"
  end

  test "restores an unsent text draft after expiry and reauthentication" do
    user = users(:jz)
    room = rooms(:designers)
    sign_in user.email_address
    Session.order(:id).last.update!(expires_at: 3.seconds.from_now)
    visit room_url(room)
    fill_in_rich_text_area "message_body", with: "Draft survives session expiry"

    assert_selector "input[name='email_address']", wait: 8
    sign_in user.email_address, navigate: false
    visit room_url(room)

    assert_equal "Draft survives session expiry",
      page.evaluate_script("document.querySelector('trix-editor').editor.getDocument().toString().trim()")
  end

  test "keeps a selected file after an authenticated upload is rejected" do
    subscription = push_subscriptions(:jz_chrome)
    previous_session_id = subscription.session_id
    sign_in users(:jz).email_address
    join_room rooms(:designers)
    Timeout.timeout(5) do
      sleep 0.05 while subscription.reload.session_id == previous_session_id
    end
    attach_file Rails.root.join("test/fixtures/files/earth.png"), make_visible: true
    Session.where(id: Session.order(:id).last.id).delete_all

    click_on "Send Message"

    assert_selector ".message--failed", wait: 5
    assert_text "File was not uploaded. It remains selected for retry."
    assert_selector ".composer__file-caption", text: /earth\.\s*png/
  end

  test "account linking confirmation posts directly to the protected OIDC endpoint" do
    sign_in users(:jz).email_address
    configure_oidc
    visit user_profile_url

    click_on "Connect Single Sign-On"

    assert_selector "h1", text: "Connect Single Sign-On"
    assert_field "Current password"
    fill_in "Current password", with: "secret123456"
    click_on "Verify password"

    assert_selector "form[action='#{openid_connect_path}']"
    assert_selector "input[name='linking_state']", visible: false
  end

  private
    def install_fake_push_subscription
      fixture = push_subscriptions(:jz_chrome)
      endpoint = fixture.endpoint.to_json
      p256dh_key = fixture.p256dh_key.to_json
      auth_key = fixture.auth_key.to_json
      install_new_document_script <<~JAVASCRIPT
        const subscription = {
          toJSON: () => ({ endpoint: #{endpoint}, keys: { p256dh: #{p256dh_key}, auth: #{auth_key} } }),
          unsubscribe: () => Promise.reject(new Error("simulated browser cleanup failure"))
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
end
