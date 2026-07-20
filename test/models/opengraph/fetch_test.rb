require "test_helper"
require "restricted_http/private_network_guard"

class Opengraph::FetchTest < ActiveSupport::TestCase
  setup do
    @fetch = Opengraph::Fetch.new
    @url = URI.parse("https://www.example.com")
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
    Resolv.stubs(:getaddress).with("www.other.com").returns("127.0.0.1")

    assert_raises RestrictedHTTP::Violation do
      @fetch.fetch_document(@url, ip: "1.2.3.4")
    end
  end

  test "#fetch_document resolves hostnames once to avoid DNS rebinding" do
    # Allow but interrupt a real connection to demonstrate that we connect
    # to a resolved IP, not a hostname to re-resolve.
    WebMock.disable_net_connect! allow: [ @url.host ]
    Resolv.stubs(:getaddress).with(@url.host).returns("1.2.3.4", "127.0.0.1")
    TCPSocket.expects(:open).with { |*args, **| args.first == @url.host }.never
    TCPSocket.expects(:open).with { |*args, **| args.first == "1.2.3.4" }.throws(:dns_not_rebound)

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
    Resolv.stubs(:getaddress).with(@url.host).returns("1.2.3.4", "127.0.0.1")
    TCPSocket.expects(:open).with { |*args, **| args.first == @url.host }.never
    TCPSocket.expects(:open).with { |*args, **| args.first == "1.2.3.4" }.throws(:dns_not_rebound)

    assert_throws :dns_not_rebound do
      @fetch.fetch_document(URI.parse("https://www.other.com/"), ip: "1.2.3.4")
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
