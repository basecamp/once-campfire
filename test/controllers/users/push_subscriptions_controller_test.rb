require "test_helper"

class Users::PushSubscriptionsControllerTest < ActionDispatch::IntegrationTest
  P256DH_KEY = "BFOmkBtSAO-lpyLxV4IW0pEJEa7UB3GDaoL4uNHv-Y8s5pbQgvAB9hJMpE4ZV0u4pxg9EDKwtxJbuIraUnjhx4w"
  ALTERNATE_P256DH_KEY = "BCAjl7vzXuVBONCjI3rJ3eHU1gNAPjogF4FUmzq7lavt7ZKOHle6SrBaoQRwlsMvQvFDYFCmavde4ZGNabdToU8"
  AUTH_KEY = "YWFhYWFhYWFhYWFhYWFhYQ"

  setup do
    sign_in :david
  end

  test "create new push subscription" do
    subscription_params = { "endpoint" => "https://apple", "p256dh_key" => P256DH_KEY, "auth_key" => AUTH_KEY }

    post user_push_subscriptions_url,
      params: { push_subscription: subscription_params }, headers: { "HTTP_USER_AGENT" => "Mozilla/5.0" }

    assert_response :ok

    assert_equal subscription_params, users(:david).push_subscriptions.last.attributes.slice("endpoint", "p256dh_key", "auth_key")
    assert_equal "Mozilla/5.0", users(:david).push_subscriptions.last.user_agent
    assert_equal Session.find_by!(token: parsed_cookies.signed[:session_token]), users(:david).push_subscriptions.last.session
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
    assert_equal Session.find_by!(token: parsed_cookies.signed[:session_token]), push_subscriptions(:david_chrome).reload.session
  end

  test "idempotent synchronization remains available across repeated navigation" do
    attributes = push_subscriptions(:david_chrome).attributes.slice("endpoint", "p256dh_key", "auth_key")

    assert_no_difference -> { Push::Subscription.count } do
      25.times do
        post user_push_subscriptions_url, params: { push_subscription: attributes }
        assert_response :ok
      end
    end
  end

  test "rotates the capability owned by the current session in place" do
    first = { endpoint: "https://example.com/push/first", p256dh_key: P256DH_KEY, auth_key: AUTH_KEY }
    second = { endpoint: "https://example.com/push/second", p256dh_key: ALTERNATE_P256DH_KEY, auth_key: AUTH_KEY }
    post user_push_subscriptions_url, params: { push_subscription: first }
    assert_response :ok
    session = Session.find_by!(token: parsed_cookies.signed[:session_token])
    subscription = Push::Subscription.find_by!(session:)

    assert_no_difference -> { Push::Subscription.count } do
      post user_push_subscriptions_url, params: { push_subscription: second }
    end

    assert_response :ok
    assert_equal subscription.id, Push::Subscription.find_by!(session:).id
    assert_equal second.stringify_keys, subscription.reload.attributes.slice("endpoint", "p256dh_key", "auth_key")
  end

  test "replaces the current session row when transferring an exact capability" do
    post user_push_subscriptions_url, params: {
      push_subscription: { endpoint: "https://example.com/push/old", p256dh_key: P256DH_KEY, auth_key: AUTH_KEY }
    }
    assert_response :ok
    session = Session.find_by!(token: parsed_cookies.signed[:session_token])
    old_subscription = Push::Subscription.find_by!(session:)
    transferred = push_subscriptions(:jz_chrome)

    assert_difference -> { Push::Subscription.count }, -1 do
      post user_push_subscriptions_url, params: {
        push_subscription: transferred.attributes.slice("endpoint", "p256dh_key", "auth_key")
      }
    end

    assert_response :ok
    assert_not Push::Subscription.exists?(old_subscription.id)
    assert_equal session, transferred.reload.session
    assert_equal users(:david), transferred.user
  end

  test "moves an existing browser capability to the current account and session" do
    subscription = push_subscriptions(:jz_chrome)

    assert_no_difference -> { Push::Subscription.count } do
      post user_push_subscriptions_url, params: {
        push_subscription: subscription.attributes.slice("endpoint", "p256dh_key", "auth_key")
      }
    end

    assert_response :ok
    assert_equal users(:david), subscription.reload.user
    assert_equal Session.find_by!(token: parsed_cookies.signed[:session_token]), subscription.session
  end

  test "does not transfer ownership based on the endpoint alone" do
    subscription = push_subscriptions(:jz_chrome)

    assert_difference -> { Push::Subscription.count }, +1 do
      post user_push_subscriptions_url, params: {
        push_subscription: {
          endpoint: subscription.endpoint,
          p256dh_key: ALTERNATE_P256DH_KEY,
          auth_key: AUTH_KEY
        }
      }
    end

    assert_response :ok
    assert_equal users(:jz), subscription.reload.user
  end

  test "rejects private endpoint literals" do
    assert_no_difference -> { Push::Subscription.count } do
      post user_push_subscriptions_url, params: {
        push_subscription: {
          endpoint: "https://127.0.0.1/push",
          p256dh_key: P256DH_KEY,
          auth_key: AUTH_KEY
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "rejects malformed subscription keys" do
    assert_no_difference -> { Push::Subscription.count } do
      post user_push_subscriptions_url, params: {
        push_subscription: {
          endpoint: "https://push.example.com/new",
          p256dh_key: P256DH_KEY,
          auth_key: "A"
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "rejects updating an existing capability with malformed keys" do
    subscription = push_subscriptions(:david_chrome)
    subscription.update_column(:auth_key, "A")

    assert_no_changes -> { subscription.reload.updated_at } do
      post user_push_subscriptions_url, params: {
        push_subscription: subscription.attributes.slice("endpoint", "p256dh_key", "auth_key")
      }
    end

    assert_response :unprocessable_entity
    assert_equal "A", subscription.reload.auth_key
  end

  test "rejects transfer into an account at its subscription quota" do
    user = users(:david)
    subscription = push_subscriptions(:jz_chrome)
    (Push::Subscription::MAXIMUM_SUBSCRIPTIONS_PER_USER - user.push_subscriptions.count).times do |index|
      user.push_subscriptions.create!(
        endpoint: "https://quota-#{index}.example.com/push",
        p256dh_key: P256DH_KEY, auth_key: AUTH_KEY
      )
    end

    assert_no_difference -> { Push::Subscription.count } do
      post user_push_subscriptions_url, params: {
        push_subscription: subscription.attributes.slice("endpoint", "p256dh_key", "auth_key")
      }
    end

    assert_response :unprocessable_entity
    assert_equal users(:jz), subscription.reload.user
  end

  test "destroy a push subscription via dev mode" do
    assert_difference -> { Push::Subscription.count }, -1 do
      delete user_push_subscription_url(push_subscriptions(:david_chrome))
      assert_redirected_to user_push_subscriptions_url
    end
  end
end
