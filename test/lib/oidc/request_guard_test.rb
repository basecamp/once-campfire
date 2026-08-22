require "test_helper"
require "oidc/request_guard"

class Oidc::RequestGuardTest < ActiveSupport::TestCase
  setup do
    configure_oidc
    @calls = 0
    @app = ->(_env) { @calls += 1; [ 200, {}, [ "ok" ] ] }
  end

  test "rejects banned IPs before OIDC middleware" do
    Ban.create!(user: users(:kevin), ip_address: "203.0.113.10")

    status, = guard.call(environment(ip: "203.0.113.10"))

    assert_equal 429, status
    assert_equal 0, @calls
  end

  test "rate limits OIDC work before calling downstream middleware" do
    guard = guard(store: ActiveSupport::Cache::MemoryStore.new)

    Oidc::RequestGuard::REQUEST_LIMIT.times { assert_equal 200, guard.call(environment).first }
    assert_equal 429, guard.call(environment).first
    assert_equal Oidc::RequestGuard::REQUEST_LIMIT, @calls
  end

  test "fails closed before OIDC work when rate limit storage returns nil" do
    store = stub(increment: nil)

    status, = guard(store:).call(environment)

    assert_equal 503, status
    assert_equal 0, @calls
  end

  test "fails closed before OIDC work when rate limit storage times out" do
    store = stub
    store.stubs(:increment).raises(Timeout::Error, "cache timeout")

    status, = guard(store:).call(environment)

    assert_equal 503, status
    assert_equal 0, @calls
  end

  test "concurrent OIDC requests cannot exceed the per-client limit" do
    request_count = Oidc::RequestGuard::REQUEST_LIMIT + 5
    start = Queue.new
    Oidc.stubs(:rollback_prepared?).returns(false)
    Ban.stubs(:banned?).returns(false)
    guard = guard(
      store: ActiveSupport::Cache::MemoryStore.new,
      semaphore: Concurrent::Semaphore.new(request_count)
    )
    requests = request_count.times.map do
      Thread.new do
        start.pop
        guard.call(environment).first
      end
    end

    request_count.times { start << true }
    statuses = requests.map(&:value)

    assert_equal Oidc::RequestGuard::REQUEST_LIMIT, statuses.count(200)
    assert_equal request_count - Oidc::RequestGuard::REQUEST_LIMIT, statuses.count(429)
    assert_equal Oidc::RequestGuard::REQUEST_LIMIT, @calls
  end

  test "reserves application capacity when all OIDC permits are occupied" do
    semaphore = Concurrent::Semaphore.new(1)
    semaphore.acquire

    assert_equal 503, guard(semaphore:).call(environment).first
    assert_equal 0, @calls
  ensure
    semaphore&.release
  end

  test "requires the configured canonical host" do
    status, headers = guard.call(environment(host: "alias.example.com", method: "GET", path: "/session/new"))

    assert_equal 308, status
    assert_equal "https://campfire.example.com/session/new", headers.fetch("location")
    assert_equal 0, @calls
  end

  test "blocks ordinary requests before required mode activation" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address)
    Oidc::Activation.stubs(:ready?).returns(false)

    status, headers, body = guard.call(environment(method: "GET", path: "/rooms/1"))

    assert_equal 503, status
    assert_equal "text/html; charset=utf-8", headers.fetch("content-type")
    assert_includes body.join, "<main>"
    assert_includes body.join, '<a href="/session/new">Continue to single sign-on</a>'
    assert_equal 0, @calls
  end

  test "returns maintenance metadata without a body for HEAD" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address)
    Oidc::Activation.stubs(:ready?).returns(false)

    status, headers, body = guard.call(environment(method: "HEAD", path: "/rooms/1"))

    assert_equal 503, status
    assert_equal "text/html; charset=utf-8", headers.fetch("content-type")
    assert_empty body
    assert_operator headers.fetch("content-length").to_i, :positive?
  end

  test "preserves the plain maintenance response for non-HTML clients" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address)
    Oidc::Activation.stubs(:ready?).returns(false)

    status, headers, body = guard.call(environment(
      method: "GET", path: "/rooms/1", accept: "application/json"
    ))

    assert_equal 503, status
    assert_equal "text/plain", headers.fetch("content-type")
    assert_equal [ "OIDC required mode is not ready" ], body
  end

  test "honors an explicit refusal of HTML maintenance content" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address)
    Oidc::Activation.stubs(:ready?).returns(false)

    _status, headers, = guard.call(environment(
      method: "GET", path: "/rooms/1", accept: "text/html;q=0, */*;q=1"
    ))

    assert_equal "text/plain", headers.fetch("content-type")
  end

  test "permits the OIDC verification surface before required mode activation" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address)
    Oidc::Activation.stubs(:ready?).returns(false)

    assert_equal 200, guard.call(environment).first
    assert_equal 1, @calls
  end

  test "permits revocation and deprovisioning surfaces before required mode activation" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address)
    Oidc::Activation.stubs(:ready?).returns(false)

    assert_equal 200, guard.call(environment(path: "/auth/openid_connect/backchannel_logout")).first
    assert_equal 200, guard.call(environment(path: "/scim/v2/Users/stable-id", method: "PATCH")).first
    assert_equal 2, @calls
  end

  test "SCIM readiness bypasses canonical origin like other health checks" do
    status, = guard.call(environment(host: "alias.example.com", method: "GET", path: "/up/scim", scheme: "http"))

    assert_equal 200, status
    assert_equal 1, @calls
  end

  test "rejects auth path variants recognized by OmniAuth" do
    %w[
      /AUTH/OPENID_CONNECT
      /auth/openid_connect/
      /auth/openid_connect.json
      /auth/openid_connect/callback.json
      /AUTH/OPENID_CONNECT/BACKCHANNEL_LOGOUT
      /auth/openid_connect/backchannel_logout/
      /auth/openid_connect/backchannel_logout.json
    ].each do |path|
      assert_equal 404, guard.call(environment(path:)).first
    end

    assert_equal 0, @calls
  end

  test "direct guard responses include the default security headers" do
    _status, headers, = guard.call(environment(method: "GET"))

    Oidc::DEFAULT_SECURITY_HEADERS.each do |name, value|
      assert_equal value, headers.fetch(name)
    end
  end

  test "requires POST initiation and GET callback before OmniAuth" do
    initiation_status, initiation_headers = guard.call(environment(method: "GET"))
    callback_status, callback_headers = guard.call(environment(method: "POST", path: "/auth/openid_connect/callback"))

    assert_equal 405, initiation_status
    assert_equal "POST", initiation_headers.fetch("allow")
    assert_equal 405, callback_status
    assert_equal "GET", callback_headers.fetch("allow")
    assert_equal 0, @calls
  end

  test "redirects same-host HTTP requests to the HTTPS canonical origin" do
    status, headers = guard.call(environment(method: "GET", path: "/session/new", scheme: "http"))

    assert_equal 308, status
    assert_equal "https://campfire.example.com/session/new", headers.fetch("location")
    assert_equal 0, @calls
  end

  test "accepts forwarded HTTPS only from a directly trusted proxy" do
    configure_oidc("DISABLE_SSL" => "true", "OIDC_TRUSTED_PROXY_CIDRS" => "10.20.0.0/16")

    assert_equal 200, guard.call(environment(ip: "10.20.1.2", scheme: "http", forwarded_proto: "https")).first
    assert_equal 421, guard.call(environment(ip: "203.0.113.20", scheme: "http", forwarded_proto: "https")).first
    assert_equal 1, @calls
  end

  test "rejects unsafe requests that do not come through a trusted HTTPS proxy" do
    configure_oidc("DISABLE_SSL" => "true", "OIDC_TRUSTED_PROXY_CIDRS" => "10.20.0.0/16")

    status, = guard.call(environment(
      ip: "203.0.113.20", method: "POST", path: "/rooms/1", scheme: "http", forwarded_proto: "https"
    ))

    assert_equal 421, status
    assert_equal 0, @calls
  end

  test "requires the exact configured HTTPS port" do
    status, = guard.call(environment(host: "campfire.example.com:8443", method: "POST"))

    assert_equal 421, status
    assert_equal 0, @calls
  end

  test "requires a trusted proxy to state a non-default public port" do
    configure_oidc(
      "DISABLE_SSL" => "true",
      "OIDC_TRUSTED_PROXY_CIDRS" => "10.20.0.0/16",
      "HTTPS_PORT" => "8443",
      "OIDC_REDIRECT_URI" => "https://campfire.example.com:8443/auth/openid_connect/callback"
    )

    assert_equal 421, guard.call(environment(
      ip: "10.20.1.2", scheme: "http", forwarded_proto: "https"
    )).first
    assert_equal 200, guard.call(environment(
      ip: "10.20.1.2", scheme: "http", forwarded_proto: "https", forwarded_port: "8443"
    )).first
  end

  test "rejects an explicit Host port that conflicts with the canonical proxy port" do
    configure_oidc("DISABLE_SSL" => "true", "OIDC_TRUSTED_PROXY_CIDRS" => "10.20.0.0/16")

    status, = guard.call(environment(
      ip: "10.20.1.2", host: "campfire.example.com:8443", scheme: "http", forwarded_proto: "https"
    ))

    assert_equal 421, status
    assert_equal 0, @calls
  end

  private
    def guard(store: ActiveSupport::Cache::MemoryStore.new, semaphore: Concurrent::Semaphore.new(1))
      Oidc::RequestGuard.new(@app, store:, semaphore:)
    end

    def environment(ip: "203.0.113.20", host: "campfire.example.com", method: "POST", path: "/auth/openid_connect",
        scheme: "https", forwarded_proto: nil, forwarded_port: nil, accept: nil)
      Rack::MockRequest.env_for("#{scheme}://#{host}#{path}", method:, "REMOTE_ADDR" => ip).tap do |env|
        env["HTTP_HOST"] = host
        env["HTTP_ACCEPT"] = accept if accept
        env["HTTP_X_FORWARDED_PROTO"] = forwarded_proto if forwarded_proto
        env["HTTP_X_FORWARDED_PORT"] = forwarded_port if forwarded_port
      end
    end
end
