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
    Resolv.stubs(:getaddresses).with("www.other.com").returns([ "127.0.0.1" ])

    assert_raises RestrictedHTTP::Violation do
      @fetch.fetch_document(@url, ip: "1.2.3.4")
    end
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
      @fetch.fetch_document(URI.parse("https://www.other.com/"), ip: "1.2.3.4")
    end
  end

  test "#fetch_document gives up on a host that accepts the connection and never answers" do
    with_local_host do |url, connections|
      stub_const(Opengraph::Fetch, :TIMEOUT, 0.2.seconds) do
        assert_gives_up_within(1.second, Net::ReadTimeout) { @fetch.fetch_document(url, ip: "127.0.0.1") }
      end
      assert_equal 1, connections.size, "the GET is not retried"
    end
  end

  test "#fetch_document gives up on headers that trickle in past the deadline" do
    trickle_headers = ->(client) do
      client.write "HTTP/1.1 200 OK\r\nX-Padding: "
      100.times { client.write "x"; sleep 0.05 }
      client.write "\r\nContent-Type: text/html\r\nContent-Length: 2\r\n\r\nok"
    end

    with_local_host(trickle_headers) do |url|
      stub_const(Opengraph::Fetch, :DEADLINE, 0.5.seconds) do
        assert_gives_up_within(1.5.seconds, Timeout::Error) { @fetch.fetch_document(url, ip: "127.0.0.1") }
      end
    end
  end

  test "#fetch_document gives up on a body that trickles in past the deadline" do
    trickle_body = ->(client) do
      client.write "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 100\r\n\r\n"
      100.times { client.write "x"; sleep 0.05 }
    end

    with_local_host(trickle_body) do |url|
      stub_const(Opengraph::Fetch, :DEADLINE, 0.5.seconds) do
        assert_gives_up_within(1.5.seconds, Timeout::Error) { @fetch.fetch_document(url, ip: "127.0.0.1") }
      end
    end
  end

  test "#fetch_document gives up on redirects that keep coming past the deadline" do
    stub_dns_resolution("1.2.3.4")
    WebMock.stub_request(:get, "https://www.example.com/").to_return do
      sleep 0.2
      { status: 302, headers: { location: "https://www.example.com/" } }
    end

    stub_const(Opengraph::Fetch, :DEADLINE, 0.5.seconds) do
      assert_gives_up_within(1.second, Timeout::Error) { @fetch.fetch_document(@url, ip: "1.2.3.4") }
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

    # A real socket, because WebMock reads the whole response before the code under test sees any of it.
    def with_local_host(respond = ->(client) { })
      server = TCPServer.new("127.0.0.1", 0)
      connections = Queue.new
      Thread.new do
        loop do
          client = server.accept
          connections << client
          client.readpartial(1024)
          respond.call(client)
        end
      rescue IOError, SystemCallError
      end

      WebMock.disable!
      yield URI.parse("http://www.example.com:#{server.addr[1]}/"), connections
    ensure
      WebMock.enable!
      server&.close
    end

    def assert_gives_up_within(limit, error, &block)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(error, &block)
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, limit
    end
end
