require "test_helper"

class Users::PushSubscriptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    stub_web_push_dns_resolution
  end

  test "create new push subscription" do
    subscription_params = { "endpoint" => "https://fcm.googleapis.com/fcm/send/abc123", "p256dh_key" => "123", "auth_key" => "456" }

    post user_push_subscriptions_url,
      params: { push_subscription: subscription_params }, headers: { "HTTP_USER_AGENT" => "Mozilla/5.0" }

    assert_response :ok

    assert_equal subscription_params, users(:david).push_subscriptions.last.attributes.slice("endpoint", "p256dh_key", "auth_key")
    assert_equal "Mozilla/5.0", users(:david).push_subscriptions.last.user_agent
  end

  test "touch existing subscription" do
    assert_no_difference -> { users(:david).push_subscriptions.count } do
      assert_changes -> { push_subscriptions(:david_chrome).reload.updated_at } do
        post user_push_subscriptions_url(params: {
          push_subscription: push_subscriptions(:david_chrome).attributes.slice("endpoint", "p256dh_key", "auth_key")
        })
      end
    end

    assert_response :ok
  end

  test "rejects subscription with non-permitted endpoint" do
    subscription_params = { "endpoint" => "https://attacker.example.com/steal", "p256dh_key" => "123", "auth_key" => "456" }

    assert_no_difference -> { Push::Subscription.count } do
      post user_push_subscriptions_url, params: { push_subscription: subscription_params }
    end

    assert_response :unprocessable_entity
  end

  test "rejects subscription with endpoint resolving to a private IP" do
    stub_dns_resolution("169.254.169.254")
    subscription_params = { "endpoint" => "https://fcm.googleapis.com/fcm/send/abc123", "p256dh_key" => "123", "auth_key" => "456" }

    assert_no_difference -> { Push::Subscription.count } do
      post user_push_subscriptions_url, params: { push_subscription: subscription_params }
    end

    assert_response :unprocessable_entity
  end

  test "re-registering a legacy invalid subscription is rejected with 422" do
    # A row that predates endpoint validation (saved without validation, as a
    # sink planted before this shipped could be). Re-POSTing its params must hit
    # the same 422 as a fresh create, not be kept alive by touch.
    legacy = users(:david).push_subscriptions.build \
      endpoint: "https://attacker.example.com/steal", p256dh_key: "123", auth_key: "456"
    legacy.save!(validate: false)

    assert_no_difference -> { Push::Subscription.count } do
      post user_push_subscriptions_url, params: {
        push_subscription: { endpoint: "https://attacker.example.com/steal", p256dh_key: "123", auth_key: "456" }
      }
    end

    assert_response :unprocessable_entity
  end

  test "destroy a push subscription via dev mode" do
    assert_difference -> { Push::Subscription.count }, -1 do
      delete user_push_subscription_url(push_subscriptions(:david_chrome))
      assert_redirected_to user_push_subscriptions_url
    end
  end

  test "a signed-out session can't register a subscription" do
    Session.delete_all

    assert_no_difference -> { Push::Subscription.count } do
      post user_push_subscriptions_url, params: { push_subscription: new_subscription_params }
    end

    assert_redirected_to new_session_url
  end

  test "a session signed out while its request is in flight doesn't register a subscription" do
    Push::Subscription.any_instance.stubs(:valid?).with { Session.delete_all; true }.returns(true)

    assert_no_difference -> { Push::Subscription.count } do
      post user_push_subscriptions_url, params: { push_subscription: new_subscription_params }
    end

    assert_response :unauthorized
  end

  test "a session signed out while its request is in flight doesn't keep an existing subscription alive" do
    subscription = push_subscriptions(:david_chrome)
    Push::Subscription.any_instance.stubs(:valid?).with { Session.delete_all; true }.returns(true)

    assert_no_changes -> { subscription.reload.updated_at } do
      post user_push_subscriptions_url, params: { push_subscription: subscription.attributes.slice("endpoint", "p256dh_key", "auth_key") }
    end

    assert_response :unauthorized
  end

  test "pages name their session for the browser to post its subscription again in a new one" do
    get user_profile_url
    assert_equal user_push_subscriptions_path, css_select("[data-push-subscription-sync-url-value]").first["data-push-subscription-sync-url-value"]

    get room_url(rooms(:watercooler))
    first_marker = css_select("[data-push-subscription-sync-session-value]").first["data-push-subscription-sync-session-value"]

    assert_match(/\A\h{64}\z/, first_marker)
    assert_not_includes response.body, users(:david).sessions.order(:id).last.token

    sign_in :david
    get room_url(rooms(:watercooler))
    assert_not_equal first_marker, css_select("[data-push-subscription-sync-session-value]").first["data-push-subscription-sync-session-value"]
  end

  test "two posts of the same new subscription at once register it once" do
    Push::Subscription.any_instance.stubs(:valid?).with do
      users(:david).push_subscriptions.build(new_subscription_params).save!(validate: false) unless Push::Subscription.exists?(endpoint: new_subscription_params["endpoint"])
      true
    end.returns(true)

    assert_difference -> { Push::Subscription.where(endpoint: new_subscription_params["endpoint"]).count }, +1 do
      post user_push_subscriptions_url, params: { push_subscription: new_subscription_params }
    end

    assert_response :ok
  end

  private
    def new_subscription_params
      { "endpoint" => "https://fcm.googleapis.com/fcm/send/abc123", "p256dh_key" => "123", "auth_key" => "456" }
    end
end
