require "test_helper"
require "security_endpoint_request_guard"

class SecurityEndpointRequestGuardTest < ActiveSupport::TestCase
  setup do
    configure_oidc
    configure_scim
    @calls = 0
    @app = ->(env) { @calls += 1; [ 200, {}, [ env[SecurityEndpointBodyLimiter::RAW_BODY_KEY].to_s ] ] }
  end

  test "rejects a declared logout body before reading or parsing it" do
    unreadable = Object.new
    unreadable.expects(:read).never
    env = environment(
      SecurityEndpointRequestGuard::LOGOUT_PATH,
      input: unreadable,
      content_length: SecurityEndpointRequestGuard::LOGOUT_BODY_BYTES + 1
    )

    status, headers = SecurityEndpointBodyLimiter.new(@app).call(env)

    assert_equal 413, status
    assert_equal "no-store", headers.fetch("cache-control")
    assert_security_headers headers
    assert_equal 0, @calls
  end

  test "rejects noncanonical security endpoint paths before downstream routing" do
    middleware = SecurityEndpointRequestGuard.new(@app)
    %w[
      /auth/openid_connect.json
      /AUTH/OPENID_CONNECT/CALLBACK
      /auth/openid_connect/backchannel_logout/
      /auth/failure.json
      /oidc_link.json
      /oidc_flow/
      /scim/v2/ServiceProviderConfig.json
      /scim/v2/Users.json
      /scim/v2/Users/stable-id.json
      /up/oidc.json
      /up/scim/
    ].each do |path|
      status, headers, = middleware.call(environment(path))

      assert_equal 404, status, path
      assert_equal "no-store", headers.fetch("cache-control"), path
      assert_security_headers headers
    end

    assert_equal 0, @calls
  end

  test "rejects a format-suffixed SCIM alias before MethodOverride reads its body" do
    unreadable = Object.new
    unreadable.expects(:read).never
    env = environment(
      "/scim/v2/Users.json", input: unreadable, content_length: nil
    )
    middleware = SecurityEndpointBodyLimiter.new(Rack::MethodOverride.new(@app))

    status, headers, = middleware.call(env)

    assert_equal 404, status
    assert_equal "no-store", headers.fetch("cache-control")
    assert_security_headers headers
    assert_equal 0, @calls
  end

  test "bounds a chunked SCIM body before parameter parsing and returns a SCIM error" do
    env = environment(
      "/scim/v2/Users/stable-id", method: "PATCH",
      input: StringIO.new("x" * (SecurityEndpointRequestGuard::SCIM_BODY_BYTES + 1)),
      content_length: nil
    )

    status, headers, body = SecurityEndpointBodyLimiter.new(@app).call(env)

    assert_equal 413, status
    assert_equal Scim::MEDIA_TYPE, headers.fetch("content-type")
    assert_equal [ Scim::ERROR_SCHEMA ], JSON.parse(body.join).fetch("schemas")
    assert_equal 0, @calls
  end

  test "bounds SCIM bodies on GET and HEAD before parameter parsing" do
    %w[ GET HEAD ].each do |method|
      env = environment(
        "/scim/v2/Users", method:,
        input: StringIO.new("x" * (SecurityEndpointRequestGuard::SCIM_BODY_BYTES + 1)),
        content_length: nil
      )

      status, headers, body = SecurityEndpointBodyLimiter.new(@app).call(env)

      assert_equal 413, status
      assert_equal Scim::MEDIA_TYPE, headers.fetch("content-type")
      assert_empty body if method == "HEAD"
    end
    assert_equal 0, @calls
  end

  test "restores the original OIDC method before request admission" do
    oidc_guard = Oidc::RequestGuard.new(
      @app, store: ActiveSupport::Cache::MemoryStore.new,
      semaphore: Concurrent::Semaphore.new(1)
    )
    env = environment(SecurityEndpointBodyLimiter::OIDC_CALLBACK_PATH, method: "GET")
    env["rack.methodoverride.original_method"] = "POST"

    status, headers = SecurityEndpointRequestGuard.new(oidc_guard).call(env)

    assert_equal 405, status
    assert_equal "GET", headers.fetch("allow")
    assert_equal 0, @calls
  end

  test "bounds OIDC initiation and rejects callback request bodies" do
    initiation = environment(
      SecurityEndpointBodyLimiter::OIDC_PATH,
      input: StringIO.new("x" * (SecurityEndpointBodyLimiter::OIDC_BODY_BYTES + 1)),
      content_length: nil
    )
    callback = environment(
      SecurityEndpointBodyLimiter::OIDC_CALLBACK_PATH, method: "GET",
      input: StringIO.new("x"), content_length: nil
    )

    assert_equal 413, SecurityEndpointBodyLimiter.new(@app).call(initiation).first
    assert_equal 413, SecurityEndpointBodyLimiter.new(@app).call(callback).first
    assert_equal 0, @calls
  end

  test "preserves a bounded raw form for duplicate logout-token detection" do
    raw_body = "logout_token=first&hint=value&logout_token=second"
    env = environment(
      SecurityEndpointRequestGuard::LOGOUT_PATH,
      input: StringIO.new(raw_body), content_length: raw_body.bytesize
    )

    status, = SecurityEndpointBodyLimiter.new(@app).call(env)

    assert_equal 200, status
    assert_equal raw_body, env.fetch(SecurityEndpointBodyLimiter::RAW_BODY_KEY)
    assert_equal raw_body, env.fetch("rack.input").read
  end

  test "rate limits before downstream logout verification" do
    store = stub
    store.expects(:increment).returns(SecurityEndpointRequestGuard::LOGOUT_REQUEST_LIMIT + 1)

    status, headers, = guard(store:).call(environment(SecurityEndpointRequestGuard::LOGOUT_PATH))

    assert_equal 429, status
    assert_security_headers headers
    assert_equal 0, @calls
  end

  test "reserves concurrency separately for logout and SCIM" do
    logout_semaphore = Concurrent::Semaphore.new(1)
    scim_semaphore = Concurrent::Semaphore.new(1)
    logout_semaphore.acquire
    scim_semaphore.acquire
    guard = guard(
      store: stub(increment: 1), logout_semaphore:, scim_semaphore:
    )

    logout_status, = guard.call(environment(SecurityEndpointRequestGuard::LOGOUT_PATH))
    scim_status, = guard.call(environment("/scim/v2/Users/stable-id", method: "PATCH"))

    assert_equal 503, logout_status
    assert_equal 503, scim_status
    assert_equal 0, @calls
  ensure
    logout_semaphore&.release
    scim_semaphore&.release
  end

  test "SCIM HEAD guard errors contain no response body" do
    rate_limited = guard(store: stub(increment: SecurityEndpointRequestGuard::SCIM_REQUEST_LIMIT + 1))
    rate_status, rate_headers, rate_body = rate_limited.call(
      environment("/scim/v2/Users", method: "HEAD")
    )

    semaphore = Concurrent::Semaphore.new(1)
    semaphore.acquire
    busy = guard(store: stub(increment: 1), scim_semaphore: semaphore)
    busy_status, busy_headers, busy_body = busy.call(environment("/scim/v2/Users", method: "HEAD"))

    assert_equal 429, rate_status
    assert_operator rate_headers.fetch("content-length").to_i, :positive?
    assert_empty rate_body
    assert_equal 503, busy_status
    assert_operator busy_headers.fetch("content-length").to_i, :positive?
    assert_empty busy_body
    assert_equal 0, @calls
  ensure
    semaphore&.release
  end

  private
    def assert_security_headers(headers)
      Oidc::DEFAULT_SECURITY_HEADERS.each do |name, value|
        assert_equal value, headers.fetch(name)
      end
    end

    def guard(store:, logout_semaphore: Concurrent::Semaphore.new(1),
        scim_semaphore: Concurrent::Semaphore.new(1))
      SecurityEndpointRequestGuard.new(
        @app, store:, logout_semaphore:, scim_semaphore:
      )
    end

    def environment(path, method: "POST", input: StringIO.new(""), content_length: 0)
      Rack::MockRequest.env_for(
        "https://campfire.example.com#{path}", method:, input:,
        "CONTENT_TYPE" => "application/x-www-form-urlencoded",
        "REMOTE_ADDR" => "203.0.113.20"
      ).tap do |env|
        if content_length
          env["CONTENT_LENGTH"] = content_length.to_s
        else
          env.delete("CONTENT_LENGTH")
        end
      end
    end
end
