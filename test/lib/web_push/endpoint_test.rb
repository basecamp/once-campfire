require "test_helper"
require "web_push/endpoint"

class WebPush::EndpointTest < ActiveSupport::TestCase
  test "accepts a public HTTPS endpoint and returns its pinned address" do
    Resolv.stubs(:getaddresses).with("push.example.com").returns([ "93.184.216.34" ])

    uri, address = WebPush::Endpoint.resolve("https://push.example.com/messages/123")

    assert_equal "push.example.com", uri.host
    assert_equal "93.184.216.34", address
  end

  test "rejects invalid schemes, ports, credentials, and private literals" do
    endpoints = [
      "http://push.example.com/messages/123",
      "https://push.example.com:8443/messages/123",
      "https://user:password@push.example.com/messages/123",
      "https://127.0.0.1/messages/123",
      "https://[::1]/messages/123"
    ]

    endpoints.each do |endpoint|
      assert_raises(WebPush::Endpoint::Denied) { WebPush::Endpoint.parse(endpoint) }
    end
  end

  test "rejects a hostname if any resolved address is private" do
    Resolv.stubs(:getaddresses).with("rebind.example.com")
      .returns([ "93.184.216.34", "169.254.169.254" ])

    assert_raises(WebPush::Endpoint::Denied) do
      WebPush::Endpoint.resolve("https://rebind.example.com/messages/123")
    end
  end

  test "treats DNS failures as transient unavailability" do
    Resolv.stubs(:getaddresses).with("missing.example.com").raises(Resolv::ResolvError)

    assert_raises(WebPush::Endpoint::Unavailable) do
      WebPush::Endpoint.resolve("https://missing.example.com/messages/123")
    end
  end

  test "delivery executor has a bounded queue" do
    pool = WebPush::Pool.new(invalid_subscription_handler: nil, max_threads: 1)

    assert_equal 10_000, pool.delivery_pool.max_queue
  ensure
    pool&.shutdown
  end

  test "guarded delivery rejects oversized response bodies" do
    endpoint = "https://push.example.com/messages/123"
    WebPush::Endpoint.stubs(:resolve).with(endpoint).returns([ URI(endpoint), "93.184.216.34" ])
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.stubs(:read_body).yields("x" * (WebPush::GuardedRequest::MAXIMUM_RESPONSE_SIZE + 1))
    http = mock
    %i[ ipaddr= use_ssl= open_timeout= read_timeout= write_timeout= ].each { http.stubs(_1) }
    http.stubs(:request).yields(response).returns(response)
    Net::HTTP.stubs(:new).returns(http)
    request = WebPush::Request.new(
      message: "", subscription: { endpoint:, keys: { p256dh: "", auth: "" } }, vapid: {}
    )

    assert_raises(WebPush::Endpoint::Denied) { request.perform }
  end

  test "guarded delivery rejects an oversized response header line before parsing" do
    assert_guarded_request_rejects oversized_raw_response_header
  end

  test "guarded delivery rejects excessive response header lines before parsing" do
    assert_guarded_request_rejects excessive_raw_response_headers
  end

  private
    def assert_guarded_request_rejects(response)
      endpoint = "https://push.example.com/messages/123"
      WebPush::Endpoint.stubs(:resolve).with(endpoint).returns([ URI(endpoint), "93.184.216.34" ])

      with_raw_tls_response(response) do |server|
        http_client = server.http_client
        Net::HTTP.stubs(:new).with("push.example.com", 443, nil).returns(http_client)
        request = WebPush::Request.new(
          message: "", subscription: { endpoint:, keys: { p256dh: "", auth: "" } }, vapid: {}
        )

        error = assert_raises(WebPush::Endpoint::Denied) { request.perform }
        assert_instance_of RestrictedHTTP::ResponseHeaderGuard::Exceeded, error.cause
      end
    end
end
