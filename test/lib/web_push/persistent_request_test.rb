require "test_helper"

class WebPush::PersistentRequestTest < ActiveSupport::TestCase
  include PushServiceTestHelper

  ENDPOINT = "https://fcm.googleapis.com/fcm/send/test123"

  # The delivery must connect to the public IP resolved and guarded by
  # Push::Subscription, never re-resolve the raw endpoint host at connect time --
  # otherwise a rebind between resolution and delivery reopens the SSRF. An empty
  # message keeps the request past encryption and onto the socket we assert on.
  test "pins delivery to endpoint_ip instead of re-resolving the host" do
    host = URI(ENDPOINT).host
    WebMock.disable_net_connect! allow: [ host ]

    TCPSocket.expects(:open).with { |*args, **| args.first == host }.never
    TCPSocket.expects(:open).with { |*args, **| args.first == DnsTestHelper::WEB_PUSH_PUBLIC_TEST_IP && args[1] == 443 }.throws(:pinned_to_ip)

    assert_throws :pinned_to_ip do
      WebPush.payload_send \
        message: "",
        endpoint: ENDPOINT,
        endpoint_ip: DnsTestHelper::WEB_PUSH_PUBLIC_TEST_IP,
        p256dh: "", auth: "", vapid: {},
        urgency: "high"
    end
  end

  # An egress proxy would open the TCP connection itself and re-resolve the
  # endpoint host, defeating the ipaddr pin. The pinned path must ignore
  # http_proxy/https_proxy and connect straight to the resolved public IP.
  test "ignores proxy env so the pin can't be routed through a re-resolving proxy" do
    host = URI(ENDPOINT).host

    saved = ENV.slice("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY")
    %w[ http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ].each { |k| ENV[k] = "http://proxy.internal:3128" }

    WebMock.disable_net_connect! allow: [ host ]

    TCPSocket.expects(:open).with { |*args, **| args.first == "proxy.internal" }.never
    TCPSocket.expects(:open).with { |*args, **| args.first == DnsTestHelper::WEB_PUSH_PUBLIC_TEST_IP && args[1] == 443 }.throws(:pinned_to_ip)

    assert_throws :pinned_to_ip do
      WebPush.payload_send \
        message: "",
        endpoint: ENDPOINT,
        endpoint_ip: DnsTestHelper::WEB_PUSH_PUBLIC_TEST_IP,
        p256dh: "", auth: "", vapid: {},
        urgency: "high"
    end
  ensure
    %w[ http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  test "deliveries through the pool to the same host and address share one connection" do
    pool = WebPush::Pool.new(invalid_subscription_handler: nil)

    with_push_service do |server|
      2.times { deliver_to server, connection: pool.connection }

      assert_equal 2, server.requests.size
      assert_equal 1, server.connections
    end
  ensure
    pool.shutdown
  end

  test "a pooled delivery checks the response like any other" do
    pool = WebPush::Pool.new(invalid_subscription_handler: nil)

    with_push_service(status: "410 Gone") do |server|
      assert_raises(WebPush::ExpiredSubscription) { deliver_to server, connection: pool.connection }
    end
  ensure
    pool.shutdown
  end

  test "pooled deliveries are pinned and ignore proxy env too" do
    host = URI(ENDPOINT).host
    saved = ENV.slice("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY")
    %w[ http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ].each { |k| ENV[k] = "http://proxy.internal:3128" }

    WebMock.disable_net_connect! allow: [ host ]

    TCPSocket.expects(:open).with { |*args, **| args.first == host || args.first == "proxy.internal" }.never
    TCPSocket.expects(:open).with { |*args, **| args.first == DnsTestHelper::WEB_PUSH_PUBLIC_TEST_IP && args[1] == 443 }.throws(:pinned_to_ip)

    assert_throws :pinned_to_ip do
      WebPush.payload_send \
        message: "",
        endpoint: ENDPOINT,
        endpoint_ip: DnsTestHelper::WEB_PUSH_PUBLIC_TEST_IP,
        p256dh: "", auth: "", vapid: {},
        connection: WebPush::Connections.new,
        urgency: "high"
    end
  ensure
    %w[ http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  test "nothing is sent without a resolved endpoint IP" do
    WebMock.disable_net_connect! allow: [ URI(ENDPOINT).host ]
    TCPSocket.expects(:open).never

    error = assert_raises(ArgumentError) do
      WebPush.payload_send message: "", endpoint: ENDPOINT, p256dh: "", auth: "", vapid: {}, urgency: "high"
    end
    assert_equal "Push deliveries must be pinned to a resolved endpoint IP", error.message
  end

  private
    def deliver_to(server, connection:)
      WebPush.payload_send \
        message: "",
        endpoint: "https://#{PushServiceTestHelper::HOST}:#{server.port}/fcm/send/test123",
        endpoint_ip: PushServiceTestHelper::IP,
        p256dh: "", auth: "", vapid: {},
        connection: connection,
        urgency: "high"
    end
end
