require "test_helper"

class Push::SubscriptionTest < ActiveSupport::TestCase
  setup do
    stub_web_push_dns_resolution
  end

  test "valid subscription with permitted endpoint" do
    assert build_subscription(endpoint: "https://fcm.googleapis.com/fcm/send/abc123").valid?
  end

  test "rejects endpoint with non-https scheme" do
    subscription = build_subscription(endpoint: "http://fcm.googleapis.com/fcm/send/abc123")

    assert_not subscription.valid?
    assert_includes subscription.errors[:endpoint], "must use HTTPS"
  end

  test "rejects endpoint with non-permitted host" do
    subscription = build_subscription(endpoint: "https://attacker.example.com/webhook")

    assert_not subscription.valid?
    assert_includes subscription.errors[:endpoint], "is not a permitted push service"
  end

  test "rejects endpoint whose host only suffix-matches a permitted host" do
    subscription = build_subscription(endpoint: "https://evilfcm.googleapis.com.attacker.example/webhook")

    assert_not subscription.valid?
    assert_includes subscription.errors[:endpoint], "is not a permitted push service"
  end

  test "rejects blank endpoint" do
    subscription = build_subscription(endpoint: "")

    assert_not subscription.valid?
    assert_includes subscription.errors[:endpoint], "can't be blank"
  end

  test "rejects endpoint on a non-default port" do
    subscription = build_subscription(endpoint: "https://fcm.googleapis.com:8443/fcm/send/abc123")

    assert_not subscription.valid?
    assert_includes subscription.errors[:endpoint], "must use the default HTTPS port"
  end

  test "rejects endpoint that resolves to private IP" do
    stub_dns_resolution("192.168.1.1")
    subscription = build_subscription(endpoint: "https://fcm.googleapis.com/fcm/send/abc123")

    assert_not subscription.valid?
    assert_includes subscription.errors[:endpoint], "resolves to a private or invalid IP address"
  end

  test "rejects endpoint that resolves to loopback IP" do
    stub_dns_resolution("127.0.0.1")
    subscription = build_subscription(endpoint: "https://fcm.googleapis.com/fcm/send/abc123")

    assert_not subscription.valid?
    assert_includes subscription.errors[:endpoint], "resolves to a private or invalid IP address"
  end

  test "rejects endpoint that resolves to link-local IP (AWS IMDS)" do
    stub_dns_resolution("169.254.169.254")
    subscription = build_subscription(endpoint: "https://fcm.googleapis.com/fcm/send/abc123")

    assert_not subscription.valid?
    assert_includes subscription.errors[:endpoint], "resolves to a private or invalid IP address"
  end

  test "rejects endpoint whose host resolves to nothing without raising" do
    stub_dns_failure
    subscription = build_subscription(endpoint: "https://fcm.googleapis.com/fcm/send/abc123")

    assert_nil subscription.resolved_endpoint_ip
    assert_not subscription.valid?
    assert_includes subscription.errors[:endpoint], "resolves to a private or invalid IP address"
  end

  test "resolved_endpoint_ip returns the pinned public IP" do
    subscription = build_subscription(endpoint: "https://fcm.googleapis.com/fcm/send/abc123")

    assert_equal DnsTestHelper::WEB_PUSH_PUBLIC_TEST_IP, subscription.resolved_endpoint_ip
  end

  test "endpoint resolution is deferred from the enqueue path to the delivery worker" do
    lookups = 0
    # A side-effecting matcher lets us count resolver calls without a real lookup.
    Resolv.stubs(:getaddresses).with { |*| lookups += 1; true }.returns([ DnsTestHelper::WEB_PUSH_PUBLIC_TEST_IP ])

    subscription = build_subscription(endpoint: "https://fcm.googleapis.com/fcm/send/abc123")
    notification = subscription.notification(title: "t", body: "b", path: "/")
    assert_equal 0, lookups, "building the notification must not resolve DNS on the serial enqueue path"

    WebPush.stubs(:payload_send)
    notification.deliver
    assert_operator lookups, :>, 0, "delivery must resolve and pin the endpoint IP on the worker"
  end

  test "delivery is skipped when the endpoint no longer resolves to a public IP" do
    stub_dns_resolution("10.0.0.5") # host now answers with a private address
    subscription = build_subscription(endpoint: "https://fcm.googleapis.com/fcm/send/abc123")

    assert_nil subscription.resolved_endpoint_ip
    WebPush.expects(:payload_send).never
    subscription.notification(title: "t", body: "b", path: "/").deliver
  end

  test "delivery is skipped for a non-permitted host even when it resolves publicly" do
    # A row that predates endpoint validation: its host resolves to a public IP,
    # but it is not a permitted push service, so delivery must not proceed.
    subscription = build_subscription(endpoint: "https://attacker.example.com/collect")

    assert_nil subscription.resolved_endpoint_ip
    WebPush.expects(:payload_send).never
    subscription.notification(title: "t", body: "b", path: "/").deliver
  end

  test "delivery is skipped for a permitted host on a non-default port" do
    # A legacy/bypassed row: permitted host, resolves publicly, but port 22.
    subscription = build_subscription(endpoint: "https://fcm.googleapis.com:22/fcm/send/abc123")

    assert_nil subscription.resolved_endpoint_ip
    WebPush.expects(:payload_send).never
    subscription.notification(title: "t", body: "b", path: "/").deliver
  end

  test "delivery sends with the pinned endpoint_ip" do
    subscription = build_subscription(endpoint: "https://fcm.googleapis.com/fcm/send/abc123")

    WebPush.expects(:payload_send).with(has_entry(endpoint_ip: DnsTestHelper::WEB_PUSH_PUBLIC_TEST_IP))
    subscription.notification(title: "t", body: "b", path: "/").deliver
  end

  test "accepts all permitted push service domains" do
    [
      "https://fcm.googleapis.com/fcm/send/token123",
      "https://jmt17.google.com/fcm/send/token123",
      "https://updates.push.services.mozilla.com/wpush/v2/token123",
      "https://web.push.apple.com/QaBC123",
      "https://wns2-db5p.notify.windows.com/w/?token=abc123"
    ].each do |endpoint|
      subscription = build_subscription(endpoint: endpoint)
      assert subscription.valid?, "Expected #{endpoint} to be valid, got: #{subscription.errors.full_messages}"
    end
  end

  private
    def build_subscription(endpoint:)
      Push::Subscription.new(user: users(:david), endpoint: endpoint, p256dh_key: "test_key", auth_key: "test_auth")
    end
end
