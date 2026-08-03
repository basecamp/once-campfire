require "test_helper"
require "oidc/http_adapter"

class Oidc::HTTPAdapterTest < ActiveSupport::TestCase
  setup do
    configure_oidc
    @adapter = Oidc::HTTPAdapter.new(nil, allowed_hosts: Oidc.allowed_hosts, allow_private_network: false)
  end

  test "pins HTTPS requests to the validated public address" do
    Resolv.stubs(:getaddresses).with("idp.example.com").returns([ "93.184.216.34" ])

    connection = @adapter.send(:net_http_connection, environment("https://idp.example.com/token"))

    assert_equal "idp.example.com", connection.address
    assert_equal "93.184.216.34", connection.ipaddr
  end

  test "rejects cleartext and non-allowlisted endpoints" do
    assert_raises(Oidc::EndpointError) do
      @adapter.send(:net_http_connection, environment("http://idp.example.com/token"))
    end

    assert_raises(Oidc::EndpointError) do
      @adapter.send(:net_http_connection, environment("https://metadata.example.net/token"))
    end
  end

  test "rejects any private or unresolvable address" do
    Resolv.stubs(:getaddresses).with("idp.example.com").returns([ "93.184.216.34", "169.254.169.254" ])

    assert_raises(Oidc::HTTPAdapter::Denied) do
      @adapter.send(:net_http_connection, environment("https://idp.example.com/token"))
    end

    Resolv.stubs(:getaddresses).with("idp.example.com").returns([])

    assert_raises(Oidc::HTTPAdapter::Denied) do
      @adapter.send(:net_http_connection, environment("https://idp.example.com/token"))
    end
  end

  test "allows explicitly configured private identity providers" do
    adapter = Oidc::HTTPAdapter.new(nil, allowed_hosts: Oidc.allowed_hosts, allow_private_network: true)
    Resolv.stubs(:getaddresses).with("idp.example.com").returns([ "10.0.0.5" ])

    connection = adapter.send(:net_http_connection, environment("https://idp.example.com/token"))

    assert_equal "10.0.0.5", connection.ipaddr
  end

  test "bounds DNS resolution time" do
    Resolv.stubs(:getaddresses).raises(Timeout::Error)

    error = assert_raises(Oidc::HTTPAdapter::Denied) do
      @adapter.send(:net_http_connection, environment("https://idp.example.com/token"))
    end

    assert_match "could not be resolved", error.message
  end

  test "DNS and HTTP consume one shared request deadline" do
    environment = environment("https://idp.example.com/token")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    environment.instance_variable_set(:@oidc_request_deadline, deadline)

    assert_in_delta 10, @adapter.send(:remaining_time, environment), 0.1
    assert_equal deadline, environment.instance_variable_get(:@oidc_request_deadline)
  end

  test "rejects an oversized response header line before parsing" do
    assert_request_rejects oversized_raw_response_header
  end

  test "rejects excessive response header lines before parsing" do
    assert_request_rejects excessive_raw_response_headers, stream: true
  end

  test "accepts a bounded chunked response over TLS" do
    response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n"

    with_raw_tls_response(response) do |server|
      assert_equal "ok", oidc_connection(server).get("/").body
    end
  end

  private
    def environment(url)
      { url: URI(url) }
    end

    def assert_request_rejects(response, stream: false)
      with_raw_tls_response(response) do |server|
        error = assert_raises(Oidc::HTTPAdapter::Denied) do
          oidc_connection(server).get("/") do |request|
            request.options.on_data = ->(*) { } if stream
          end
        end
        assert_instance_of RestrictedHTTP::ResponseHeaderGuard::Exceeded, error.cause
      end
    end

    def oidc_connection(server)
      Resolv.stubs(:getaddresses).with("localhost").returns([ "127.0.0.1" ])
      Faraday.new(url: "https://localhost:#{server.port}", ssl: { verify: false }) do |faraday|
        faraday.adapter Oidc::HTTPAdapter, allowed_hosts: [ "localhost" ], allow_private_network: true
      end
    end
end
