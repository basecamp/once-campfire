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

    status, = guard(store:).call(environment(SecurityEndpointRequestGuard::LOGOUT_PATH))

    assert_equal 429, status
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

  private
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
