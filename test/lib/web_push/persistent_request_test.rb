require "test_helper"

class WebPush::PersistentRequestTest < ActiveSupport::TestCase
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
end
