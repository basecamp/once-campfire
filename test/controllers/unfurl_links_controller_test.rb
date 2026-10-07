require "test_helper"

class UnfurlLinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "create" do
    stub_successful_request

    post unfurl_link_url, params: { url: "https://www.example.com" }
    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal "Hey!", json_response["title"]
    assert_equal "https://example.com", json_response["url"]
    assert_equal "https://example.com/image.png", json_response["image"]
    assert_equal "desc..", json_response["description"]
  end

  test "create strips markup from the title and description" do
    entity_encoded_image_tag = "&#x3c;&#x69;&#x6d;&#x67;&#x20;&#x73;&#x72;&#x63;&#x3d;&#x61;&#x20;&#x6f;&#x6e;&#x65;&#x72;&#x72;&#x6f;&#x72;&#x3d;&#x70;&#x72;&#x6f;&#x6d;&#x70;&#x74;&#x28;&#x31;&#x29;&#x3e;"
    stub_successful_request title: "#{entity_encoded_image_tag}Hey!", description: "#{entity_encoded_image_tag}desc.."

    post unfurl_link_url, params: { url: "https://www.example.com" }
    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal "Hey!", json_response["title"]
    assert_equal "desc..", json_response["description"]
  end

  test "create with missing opengraph meta tags" do
    WebMock.stub_request(:get, "https://www.example.com/").to_return(status: 200, body: "<html><head></head></html>", headers: {})

    post unfurl_link_url, params: { url: "https://www.example.com" }
    assert_response :no_content
  end

  test "create returns no content when the title and description are only a markup tag" do
    image_tag = "<img src='x' onerror='alert(document.domain)'/>"
    body = "<html><head>" \
      "<meta property=\"og:url\" content=\"https://example.com\">" \
      "<meta property=\"og:title\" content=\"#{image_tag}\">" \
      "<meta property=\"og:description\" content=\"#{image_tag}\">" \
      "<meta property=\"og:image\" content=\"https://example.com/image.png\">" \
      "</head></html>"
    WebMock.stub_request(:get, "https://www.example.com/").to_return(status: 200, body: body, headers: { content_type: "text/html" })
    WebMock.stub_request(:head, "https://example.com/image.png").to_return(status: 200, headers: { content_type: "image/png" })

    post unfurl_link_url, params: { url: "https://www.example.com" }
    assert_response :no_content
  end

  test "create with a missing URL" do
    assert_raise ActionController::ParameterMissing do
      post unfurl_link_url, params: { url: "" }
      assert_response :bad_request
    end
  end

  test "create for twitter.com" do
    stub_successful_request url: "https://fxtwitter.com/dhh/status/834146806594433025"

    post unfurl_link_url, params: { url: "https://twitter.com/dhh/status/834146806594433025" }
    assert_response :success
    assert_equal "Hey!", JSON.parse(response.body)["title"]
  end

  test "create for x.com" do
    stub_successful_request url: "https://fxtwitter.com/dhh/status/834146806594433025"

    post unfurl_link_url, params: { url: "https://x.com/dhh/status/834146806594433025" }
    assert_response :success
    assert_equal "Hey!", JSON.parse(response.body)["title"]
  end

  test "create gives up on a host that accepts the connection and never answers" do
    with_local_host do |url, connections|
      stub_const(Opengraph::Fetch, :TIMEOUT, 0.2.seconds) do
        assert_unfurls_nothing_within(1.second) { post unfurl_link_url, params: { url: url } }
      end
      assert_equal 1, connections.size, "the GET is not retried"
    end
  end

  test "create gives up on headers that trickle in past the deadline" do
    trickle_headers = ->(client) do
      client.write "HTTP/1.1 200 OK\r\nX-Padding: "
      100.times { client.write "x"; sleep 0.05 }
      client.write "\r\nContent-Type: text/html\r\nContent-Length: 2\r\n\r\nok"
    end

    with_local_host(trickle_headers) do |url|
      stub_const(UnfurlLinksController, :DEADLINE, 0.5.seconds) do
        assert_unfurls_nothing_within(1.5.seconds) { post unfurl_link_url, params: { url: url } }
      end
    end
  end

  test "create gives up on a body that trickles in past the deadline" do
    trickle_body = ->(client) do
      client.write "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 100\r\n\r\n"
      100.times { client.write "x"; sleep 0.05 }
    end

    with_local_host(trickle_body) do |url|
      stub_const(UnfurlLinksController, :DEADLINE, 0.5.seconds) do
        assert_unfurls_nothing_within(1.5.seconds) { post unfurl_link_url, params: { url: url } }
      end
    end
  end

  test "create gives up on redirects that keep coming past the deadline" do
    stub_dns_resolution("1.2.3.4")
    WebMock.stub_request(:get, "https://www.example.com/").to_return do
      sleep 0.2
      { status: 302, headers: { location: "https://www.example.com/" } }
    end

    stub_const(UnfurlLinksController, :DEADLINE, 0.5.seconds) do
      assert_unfurls_nothing_within(1.second) { post unfurl_link_url, params: { url: "https://www.example.com" } }
    end
  end

  test "create gives up on a host name that takes too long to look up" do
    Resolv.stubs(:getaddresses).with { sleep 2 }.returns([ "1.2.3.4" ]) # each lookup takes 2 s
    WebMock.stub_request(:get, "https://www.example.com/").to_return(status: 200, body: "<html></html>", headers: { content_type: "text/html" })

    stub_const(UnfurlLinksController, :DEADLINE, 0.5.seconds) do
      assert_unfurls_nothing_within(1.second) { post unfurl_link_url, params: { url: "https://www.example.com" } }
    end
  end

  private
    # A real socket, because WebMock reads the whole response before the code under test sees any of it.
    # The guard lets the local address through, as it would a public one.
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

      RestrictedHTTP::PrivateNetworkGuard.stubs(:resolve).returns("127.0.0.1")
      WebMock.disable!
      yield "http://www.example.com:#{server.addr[1]}/", connections
    ensure
      WebMock.enable!
      server&.close
    end

    def assert_unfurls_nothing_within(limit)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      assert_response :no_content
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, limit
    end

    def stub_successful_request(url: "https://www.example.com/", title: "Hey!", description: "desc..")
      WebMock.stub_request(:get, url).to_return(
        status: 200,
        body: "<html><head><meta property=\"og:url\" content=\"https://example.com\"><meta property=\"og:title\" content=\"#{title}\"><meta property=\"og:description\" content=\"#{description}\"><meta property=\"og:image\" content=\"https://example.com/image.png\"></head></html>",
        headers: { content_type: "text/html" }
      )

      WebMock.stub_request(:head, "https://example.com/image.png").to_return(
        status: 200,
        headers: { content_type: "image/png" }
      )
    end
end
