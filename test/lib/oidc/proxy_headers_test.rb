require "test_helper"
require "action_dispatch/middleware/remote_ip"
require "oidc/proxy_headers"
require "oidc/request_guard"

class Oidc::ProxyHeadersTest < ActiveSupport::TestCase
  TRUSTED_PROXY_CIDRS = "10.20.0.0/16, 10.30.0.0/16, fd12:3456::/48"

  setup do
    configure_oidc(
      "DISABLE_SSL" => "true",
      "OIDC_TRUSTED_PROXY_CIDRS" => TRUSTED_PROXY_CIDRS
    )
    @calls = 0
    @remote_ips = []
    @app = lambda do |env|
      @calls += 1
      @remote_ips << ActionDispatch::Request.new(env).remote_ip.to_s
      [ 200, {}, [ "ok" ] ]
    end
  end

  test "attributes direct IPv4 and IPv6 requests to the socket and strips spoofed headers" do
    configure_oidc
    stack = attribution_stack

    assert_equal 200, stack.call(environment(
      remote_address: "198.51.100.20",
      scheme: "https",
      forwarded_for: "203.0.113.99",
      client_ip: "203.0.113.98"
    )).first
    assert_equal 200, stack.call(environment(
      remote_address: "2606:4700:4700::1111",
      scheme: "https",
      forwarded_for: "2001:4860:4860::8888"
    )).first

    assert_equal [ "198.51.100.20", "2606:4700:4700::1111" ], @remote_ips
  end

  test "attributes the published Thruster boundary to its single forwarded client" do
    configure_oidc
    stack = attribution_stack

    assert_equal 200, stack.call(environment(
      remote_address: "127.0.0.1", scheme: "https", forwarded_for: "198.51.100.12"
    )).first
    assert_equal 200, stack.call(environment(
      remote_address: "::1", scheme: "https", forwarded_for: "2606:4700:4700::1111"
    )).first

    assert_equal [ "198.51.100.12", "2606:4700:4700::1111" ], @remote_ips
  end

  test "rejects a forwarded chain from the single-hop Thruster boundary" do
    configure_oidc
    stack = attribution_stack

    assert_equal 421, stack.call(environment(
      remote_address: "127.0.0.1",
      scheme: "https",
      forwarded_for: "198.51.100.12, 127.0.0.1"
    )).first
    assert_equal 0, @calls
  end

  test "attributes multi-hop IPv4 and IPv6 chains to the nearest untrusted client" do
    stack = full_stack

    assert_equal 200, stack.call(environment(
      remote_address: "10.20.1.2",
      forwarded_for: "198.51.100.12, 10.30.4.5"
    )).first
    assert_equal 200, stack.call(environment(
      remote_address: "fd12:3456::20",
      forwarded_for: "2606:4700:4700::1111, fd12:3456::30"
    )).first

    assert_equal [ "198.51.100.12", "2606:4700:4700::1111" ], @remote_ips
  end

  test "preserves honest private IPv4 and IPv6 clients behind configured proxy hops" do
    stack = full_stack

    assert_equal 200, stack.call(environment(
      remote_address: "10.20.1.2",
      forwarded_for: "192.168.50.12, 10.30.4.5"
    )).first
    assert_equal 200, stack.call(environment(
      remote_address: "fd12:3456::20",
      forwarded_for: "fd99::12, fd12:3456::30"
    )).first

    assert_equal [ "192.168.50.12", "fd99::12" ], @remote_ips
  end

  test "rejects attacker-prepended client addresses" do
    stack = full_stack

    assert_equal 421, stack.call(environment(
      remote_address: "10.20.1.2",
      forwarded_for: "192.0.2.99, 198.51.100.12, 10.30.4.5"
    )).first
    assert_equal 0, @calls
  end

  test "rejects missing, malformed, or proxy-only client chains from a trusted edge" do
    stack = full_stack

    assert_equal 421, stack.call(environment(remote_address: "10.20.1.2", forwarded_for: nil)).first
    assert_equal 421, stack.call(environment(
      remote_address: "10.20.1.2", forwarded_for: "not-an-address"
    )).first
    assert_equal 421, stack.call(environment(
      remote_address: "10.20.1.2", forwarded_for: "10.30.4.5"
    )).first
    assert_equal 0, @calls
  end

  test "disables response storage for security endpoint attribution failures only" do
    stack = attribution_stack

    [
      "/auth/openid_connect/callback",
      "/auth/openid_connect/backchannel_logout",
      "/scim/v2/Users"
    ].each do |path|
      status, headers = stack.call(environment(
        remote_address: "10.20.1.2", forwarded_for: nil, path:
      ))
      assert_equal 421, status
      assert_equal "no-store", headers.fetch("cache-control")
    end

    status, headers = stack.call(environment(
      remote_address: "10.20.1.2", forwarded_for: nil, path: "/rooms/1"
    ))
    assert_equal 421, status
    assert_not headers.key?("cache-control")
    assert_equal 0, @calls
  end

  test "ignores Client-IP and Forwarded attribution in favor of the trusted edge X-Forwarded-For chain" do
    stack = full_stack

    assert_equal 200, stack.call(environment(
      remote_address: "10.20.1.2",
      forwarded_for: "198.51.100.12",
      client_ip: "203.0.113.200",
      forwarded: "for=203.0.113.201;proto=https"
    )).first

    assert_equal [ "198.51.100.12" ], @remote_ips
  end

  test "untrusted peers cannot assert forwarded TLS or client attribution" do
    stack = full_stack

    assert_equal 421, stack.call(environment(
      remote_address: "198.51.100.20",
      forwarded_for: "203.0.113.99",
      forwarded_proto: "https"
    )).first
    assert_equal 0, @calls
  end

  test "trusted peers cannot omit or ambiguously append the forwarded TLS scheme" do
    stack = full_stack

    assert_equal 421, stack.call(environment(
      remote_address: "10.20.1.2",
      forwarded_for: "198.51.100.12",
      forwarded_proto: nil
    )).first
    assert_equal 421, stack.call(environment(
      remote_address: "10.20.1.2",
      forwarded_for: "198.51.100.12",
      forwarded_proto: "http,https"
    )).first
    assert_equal 0, @calls
  end

  test "trusted non-default proxy authority passes CSRF origin checks without accepting a forged POST" do
    configure_non_default_proxy_port
    observed_hosts = []
    @app = lambda do |env|
      request = ActionDispatch::Request.new(env)
      controller = ActionController::Base.new
      controller.set_request! request
      observed_hosts << env["HTTP_HOST"]
      status = controller.send(:valid_request_origin?) ? 200 : 403
      [ status, {}, [] ]
    end
    stack = full_stack

    assert_equal 200, stack.call(environment(
      remote_address: "10.20.1.2",
      forwarded_for: "198.51.100.12",
      forwarded_port: "8443",
      origin: "https://campfire.example.com:8443"
    )).first
    assert_equal 403, stack.call(environment(
      remote_address: "10.20.1.2",
      forwarded_for: "198.51.100.12",
      forwarded_port: "8443",
      origin: "https://attacker.example.com"
    )).first
    assert_equal [ "campfire.example.com:8443", "campfire.example.com:8443" ], observed_hosts
  end

  test "trusted non-default proxy authority passes the Action Cable handshake origin check" do
    configure_non_default_proxy_port
    @app = lambda do |env|
      connection = ApplicationCable::Connection.new(ActionCable.server, env)
      status = connection.send(:allow_request_origin?) ? 200 : 403
      [ status, {}, [] ]
    end

    status, = full_stack.call(environment(
      remote_address: "10.20.1.2",
      forwarded_for: "198.51.100.12",
      forwarded_port: "8443",
      origin: "https://campfire.example.com:8443",
      method: "GET",
      path: "/cable"
    ))

    assert_equal 200, status
  end

  test "rate limits users sharing one trusted edge by attributed client address" do
    store = ActiveSupport::Cache::MemoryStore.new
    stack = full_stack(store:)

    Oidc::RequestGuard::REQUEST_LIMIT.times do
      assert_equal 200, stack.call(environment(
        remote_address: "10.20.1.2", forwarded_for: "198.51.100.12"
      )).first
      assert_equal 200, stack.call(environment(
        remote_address: "10.20.1.2", forwarded_for: "198.51.100.13"
      )).first
    end

    assert_equal 429, stack.call(environment(
      remote_address: "10.20.1.2", forwarded_for: "198.51.100.12"
    )).first
    assert_equal 429, stack.call(environment(
      remote_address: "10.20.1.2", forwarded_for: "198.51.100.13"
    )).first
  end

  test "rate limits Thruster clients by their forwarded address instead of loopback" do
    configure_oidc
    stack = full_stack(store: ActiveSupport::Cache::MemoryStore.new)

    Oidc::RequestGuard::REQUEST_LIMIT.times do
      assert_equal 200, stack.call(environment(
        remote_address: "127.0.0.1", scheme: "https", forwarded_for: "198.51.100.12"
      )).first
      assert_equal 200, stack.call(environment(
        remote_address: "127.0.0.1", scheme: "https", forwarded_for: "198.51.100.13"
      )).first
    end

    assert_equal 429, stack.call(environment(
      remote_address: "127.0.0.1", scheme: "https", forwarded_for: "198.51.100.12"
    )).first
    assert_equal 429, stack.call(environment(
      remote_address: "127.0.0.1", scheme: "https", forwarded_for: "198.51.100.13"
    )).first
  end

  test "a ban behind one trusted edge does not ban another client" do
    Ban.create!(user: users(:kevin), ip_address: "198.51.100.12")
    stack = full_stack

    assert_equal 429, stack.call(environment(
      remote_address: "10.20.1.2", forwarded_for: "198.51.100.12"
    )).first
    assert_equal 200, stack.call(environment(
      remote_address: "10.20.1.2", forwarded_for: "198.51.100.13"
    )).first
    assert_equal [ "198.51.100.13" ], @remote_ips
  end

  private
    def full_stack(store: ActiveSupport::Cache::MemoryStore.new)
      guard = Oidc::RequestGuard.new(@app, store:, semaphore: Concurrent::Semaphore.new(1))
      attribution_stack(guard)
    end

    def attribution_stack(app = @app)
      remote_ip_proxies = Oidc::ProxyHeaders.attribution_proxy_ranges
      remote_ip = ActionDispatch::RemoteIp.new(app, true, remote_ip_proxies)
      Oidc::ProxyHeaders.new(
        remote_ip,
        trusted_proxy_ranges: remote_ip_proxies,
        allow_proxy_chain: Oidc.proxy_required?
      )
    end

    def environment(remote_address:, forwarded_for:, scheme: "http", forwarded_proto: "https",
        forwarded_port: nil, client_ip: nil, forwarded: nil, origin: nil,
        method: "POST", path: "/auth/openid_connect")
      Rack::MockRequest.env_for(
        "#{scheme}://campfire.example.com#{path}",
        method:,
        "REMOTE_ADDR" => remote_address,
        "HTTP_HOST" => "campfire.example.com"
      ).tap do |env|
        env["HTTP_X_FORWARDED_FOR"] = forwarded_for if forwarded_for
        env["HTTP_X_FORWARDED_PROTO"] = forwarded_proto if forwarded_proto
        env["HTTP_X_FORWARDED_PORT"] = forwarded_port if forwarded_port
        env["HTTP_CLIENT_IP"] = client_ip if client_ip
        env["HTTP_FORWARDED"] = forwarded if forwarded
        env["HTTP_ORIGIN"] = origin if origin
      end
    end

    def configure_non_default_proxy_port
      configure_oidc(
        "DISABLE_SSL" => "true",
        "OIDC_TRUSTED_PROXY_CIDRS" => TRUSTED_PROXY_CIDRS,
        "HTTPS_PORT" => "8443",
        "OIDC_REDIRECT_URI" => "https://campfire.example.com:8443/auth/openid_connect/callback"
      )
    end
end
