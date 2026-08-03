require "test_helper"
require "restricted_http/private_network_guard"

class Opengraph::FetchTest < ActiveSupport::TestCase
  setup do
    @fetch = Opengraph::Fetch.new
    @url = URI.parse("https://www.example.com")
    Resolv.stubs(:getaddresses).with("www.example.com").returns([ "93.184.216.34" ])
    Resolv.stubs(:getaddresses).with("www.other.com").returns([ "93.184.216.35" ])
    Resolv.stubs(:getaddresses).with("example.com").returns([ "93.184.216.34" ])
  end

  test "#fetch_document fetches valid HTML" do
    WebMock.stub_request(:get, "https://www.example.com/")
      .to_return(status: 200, body: "<body>ok<body>", headers: { content_type: "text/html" })

    assert_equal "<body>ok<body>", @fetch.fetch_document(@url)
  end

  test "#fetch_document discards other content types" do
    WebMock.stub_request(:get, "https://www.example.com/")
      .to_return(status: 200, body: "I'm not HTML!", headers: { content_type: "text/plain" })

    assert_nil @fetch.fetch_document(@url)
  end

  test "#fetch_document follows redirects" do
    WebMock.stub_request(:get, "https://www.example.com/")
      .to_return(status: 302, headers: { location: "https://www.other.com/" })

    WebMock.stub_request(:get, "https://www.other.com/")
      .to_return(status: 200, body: "<body>ok<body>", headers: { content_type: "text/html" })

    assert_equal "<body>ok<body>", @fetch.fetch_document(@url)
  end

  test "#fetch_document does not follow redirects to private networks" do
    WebMock.stub_request(:get, "https://www.example.com/")
      .to_return(status: 302, headers: { location: "https://www.other.com/" })

    WebMock.stub_request(:get, "https://www.other.com/")
      .to_return(status: 200, body: "<body>ok<body>", headers: { content_type: "text/html" })
    Resolv.stubs(:getaddresses).with("www.other.com").returns([ "127.0.0.1" ])

    assert_raises RestrictedHTTP::Violation do
      @fetch.fetch_document(@url)
    end
  end

  test "#fetch_document rejects a hostname when any address is private" do
    Resolv.stubs(:getaddresses).with(@url.host).returns([ "93.184.216.34", "127.0.0.1" ])

    assert_raises RestrictedHTTP::Violation do
      @fetch.fetch_document(@url)
    end
  end

  test "#fetch_document disables environment proxies while retaining the validated address" do
    previous_proxy = ENV["http_proxy"]
    ENV["http_proxy"] = "http://127.0.0.1:8888"
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1

    http = @fetch.send(:http_for, @url, "93.184.216.34", deadline:)

    assert_not http.proxy?
    assert_equal "93.184.216.34", http.ipaddr
  ensure
    ENV["http_proxy"] = previous_proxy
  end

  test "#fetch_document resolves hostnames once to avoid DNS rebinding" do
    # Allow but interrupt a real connection to demonstrate that we connect
    # to a resolved IP, not a hostname to re-resolve.
    WebMock.disable_net_connect! allow: [ @url.host ]
    Resolv.stubs(:getaddresses).with(@url.host).returns([ "1.2.3.4" ], [ "127.0.0.1" ])
    TCPSocket.expects(:open).with { |*args, **| args.first == @url.host }.never
    TCPSocket.expects(:open).with { |*args, **| args.first == "1.2.3.4" && args[1] == 443 }.throws(:dns_not_rebound)

    assert_throws :dns_not_rebound do
      @fetch.fetch_document(@url)
    end
  end

  test "#fetch_document resolves redirect location hostnames once to avoid DNS rebinding" do
    # Stub the initial URL to redirect to a DNS-rebound location
    WebMock.stub_request(:get, "https://www.other.com/")
      .to_return(status: 302, headers: { location: @url.to_s })

    # Allow but interrupt a real connection to demonstrate that we connect
    # to a resolved IP, not a hostname to re-resolve.
    WebMock.disable_net_connect! allow: [ @url.host ]
    Resolv.stubs(:getaddresses).with(@url.host).returns([ "1.2.3.4" ], [ "127.0.0.1" ])
    TCPSocket.expects(:open).with { |*args, **| args.first == @url.host }.never
    TCPSocket.expects(:open).with { |*args, **| args.first == "1.2.3.4" && args[1] == 443 }.throws(:dns_not_rebound)

    assert_throws :dns_not_rebound do
      @fetch.fetch_document(URI.parse("https://www.other.com/"))
    end
  end

  test "#fetch_document bounds slow response headers with the shared deadline" do
    response = ->(socket) do
      socket.write "HTTP/1.1 200 OK\r\nX-Slow:"
      sleep 0.2
      socket.write " complete\r\n\r\n"
    end

    with_raw_tls_response(response) do |server|
      http_client = server.http_client
      Net::HTTP.stubs(:new).with("slow.example.com", 443, nil).returns(http_client)
      Resolv.stubs(:getaddresses).with("slow.example.com").returns([ "93.184.216.34" ])

      assert_raises(Opengraph::Fetch::RequestTimeoutError) do
        Opengraph::Fetch.new(maximum_request_time: 0.05)
          .fetch_document(URI("https://slow.example.com"))
      end
    end
  end

  test "#fetch_document rejects oversized raw response headers" do
    with_raw_tls_response(oversized_raw_response_header) do |server|
      http_client = server.http_client
      Net::HTTP.stubs(:new).with("headers.example.com", 443, nil).returns(http_client)
      Resolv.stubs(:getaddresses).with("headers.example.com").returns([ "93.184.216.34" ])

      error = assert_raises(Opengraph::Fetch::DeniedError) do
        @fetch.fetch_document(URI("https://headers.example.com"))
      end
      assert_instance_of RestrictedHTTP::ResponseHeaderGuard::Exceeded, error.cause
    end
  end

  test "#fetch_document is empty following redirects that never finish" do
    WebMock.stub_request(:get, "https://www.example.com/")
      .to_return(status: 302, headers: { location: "https://www.example.com/" })

    assert_raises Opengraph::Fetch::TooManyRedirectsError do
      @fetch.fetch_document(@url)
    end
  end

  test "#fetch_document ignores large responses" do
    WebMock.stub_request(:get, "https://www.example.com/")
      .to_return(status: 200, body: "too large", headers: { content_length: 1.gigabyte, content_type: "text/html" })

    assert_nil @fetch.fetch_document(@url)
  end

  test "#fetch_document ignores large responses that were missing their content length" do
    WebMock.stub_request(:get, "https://www.example.com/")
      .to_return(status: 200, body: large_body_content, headers: { content_type: "text/html" })

    assert_nil @fetch.fetch_document(@url)
  end

  test "#fetch_document ignores large responses that were lying about their content length" do
    WebMock.stub_request(:get, "https://www.example.com/")
      .to_return(status: 200, body: large_body_content, headers: { content_length: 1.megabyte, content_type: "text/html" })

    assert_nil @fetch.fetch_document(@url)
  end

  test "fetch content type" do
    WebMock.stub_request(:head, "https://example.com/image.png").to_return(status: 200, headers: { content_type: "image/png" })

    url = URI.parse("https://example.com/image.png")
    assert_equal "image/png", @fetch.fetch_content_type(url)
  end

  private
    def large_body_content
      "x" * (Opengraph::Fetch::MAX_BODY_SIZE + 1)
    end
end
