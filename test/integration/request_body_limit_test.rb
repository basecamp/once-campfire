require "test_helper"
require "puma/server"
require "socket"

class RequestBodyLimitTest < ActiveSupport::TestCase
  test "configured limit permits multipart overhead but rejects unsafe overrides" do
    assert_operator ContentLimits::REQUEST_BODY_BYTES, :>, ContentLimits::ATTACHMENT_BYTES
    assert_equal ContentLimits::REQUEST_BODY_BYTES,
      ContentLimits.request_body_bytes("MAX_REQUEST_BODY" => ContentLimits::REQUEST_BODY_BYTES.to_s)

    [
      "0", "not-an-integer",
      (ContentLimits::REQUEST_BODY_BYTES - 1).to_s,
      (ContentLimits::MAXIMUM_CONFIGURED_REQUEST_BODY_BYTES + 1).to_s
    ].each do |value|
      assert_raises(ArgumentError) do
        ContentLimits.request_body_bytes("MAX_REQUEST_BODY" => value)
      end
    end
  end

  test "Docker config gives Thruster the same validated request ceiling" do
    dockerfile = Rails.root.join("Dockerfile").read

    assert_includes dockerfile, "ENV MAX_REQUEST_BODY=#{ContentLimits::REQUEST_BODY_BYTES}"
  end

  test "real Puma server rejects a fixed-length body before Rack" do
    with_puma_limit(32) do |port, calls|
      response = raw_request(port, <<~HTTP.gsub("\n", "\r\n"))
        POST / HTTP/1.1
        Host: localhost
        Connection: close
        Content-Length: 33

        #{"x" * 33}
      HTTP

      assert_match %r{HTTP/1\.1 413}, response
      assert_equal 0, calls.call
    end
  end

  test "real Puma server rejects an oversized chunked body before Rack" do
    with_puma_limit(32) do |port, calls|
      response = raw_request(port, <<~HTTP.gsub("\n", "\r\n"))
        POST / HTTP/1.1
        Host: localhost
        Connection: close
        Transfer-Encoding: chunked

        21
        #{"x" * 33}
        0

      HTTP

      assert_match %r{HTTP/1\.1 413}, response
      assert_equal 0, calls.call
    end
  end

  private
    def with_puma_limit(limit)
      calls = 0
      app = lambda do |_env|
        calls += 1
        [ 200, { "content-type" => "text/plain" }, [ "ok" ] ]
      end
      server = Puma::Server.new(app, nil, http_content_length_limit: limit, min_threads: 0, max_threads: 1)
      listener = server.add_tcp_listener("127.0.0.1", 0)
      thread = server.run

      yield listener.local_address.ip_port, -> { calls }
    ensure
      server&.stop(true)
      thread&.join(2)
    end

    def raw_request(port, request)
      TCPSocket.open("127.0.0.1", port) do |socket|
        socket.write request
        socket.read
      end
    end
end
