require "test_helper"

class OidcFullStackTest < ActionDispatch::IntegrationTest
  setup do
    skip "run with OIDC enabled before boot" unless Oidc.enabled?

    @forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    Rails.cache.stubs(:increment).returns(1)
    host! Oidc.configuration.redirect_host
    https!
    Resolv.stubs(:getaddresses).with("idp.example.com").returns([ "93.184.216.34" ])
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_protection unless @forgery_protection.nil?
  end

  def get(path, **options)
    super(path, **proxied_options(options))
  end

  def post(path, **options)
    super(path, **proxied_options(options))
  end

  def patch(path, **options)
    super(path, **proxied_options(options))
  end

  test "signed authorization code flow crosses the mounted production middleware" do
    identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "full-stack-subject")
    signing_key = OpenSSL::PKey::RSA.generate(2048)
    jwk = JSON::JWK.new(signing_key.public_key)
    stub_provider_metadata(jwk)

    get new_session_path
    authenticity_token = css_select("form[action='#{openid_connect_path}'] input[name='authenticity_token']").first["value"]
    post openid_connect_path, params: { authenticity_token: }

    assert_response :redirect
    authorization_params = Rack::Utils.parse_query(URI(response.location).query)
    assert_equal "S256", authorization_params.fetch("code_challenge_method")

    id_token = signed_id_token(signing_key, jwk, nonce: authorization_params.fetch("nonce"))
    stub_request(:post, "https://idp.example.com/token").to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { access_token: "access-token", token_type: "Bearer", id_token: }.to_json
    )
    stub_request(:get, "https://idp.example.com/userinfo")
      .with(headers: { "Authorization" => "Bearer access-token" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { sub: identity.subject, email: users(:jz).email_address, email_verified: true }.to_json
      )

    get "/auth/openid_connect/callback", params: {
      code: "authorization-code", state: authorization_params.fetch("state")
    }

    assert_redirected_to root_url
    authentication_cookie = Array(response.headers.fetch("set-cookie")).find { _1.start_with?("session_token=") }
    assert_match(/;\s*secure/i, authentication_cookie)
    session = Session.find_by!(token: parsed_cookies.signed[:session_token])
    assert_equal identity, session.identity
    assert_equal "oidc", session.authentication_method
    assert_equal "full-stack-provider-session", session.oidc_session_id
    assert_operator session.oidc_issued_at, :>, 0
    assert_equal "203.0.113.20", session.ip_address
    assert session.expires_at.future?
    assert_equal Oidc.configuration.fingerprint, accounts(:signal).reload.oidc_verified_configuration_fingerprint

    get user_profile_path
    assert_response :success
  end

  test "banned IP is rejected before mounted middleware performs discovery" do
    get new_session_path, env: { "REMOTE_ADDR" => "203.0.113.40" }
    authenticity_token = css_select("form[action='#{openid_connect_path}'] input[name='authenticity_token']").first["value"]
    Ban.create!(user: users(:kevin), ip_address: "203.0.113.40")

    post openid_connect_path,
      params: { authenticity_token: },
      env: { "REMOTE_ADDR" => "203.0.113.40" }

    assert_response :too_many_requests
    assert_not_requested :get, "https://idp.example.com/.well-known/openid-configuration"
  end

  test "a vanished initiating session cannot be reinterpreted as an unrelated login" do
    sign_in_with_csrf users(:jz)
    initiating_session = Session.find_by!(token: parsed_cookies.signed[:session_token])
    identity = Identity.create!(user: users(:kevin), issuer: Oidc.issuer, subject: "unrelated-subject")
    signing_key = OpenSSL::PKey::RSA.generate(2048)
    jwk = JSON::JWK.new(signing_key.public_key)
    stub_provider_metadata(jwk)

    get new_session_path
    authenticity_token = css_select("form[action='#{openid_connect_path}'] input[name='authenticity_token']").sole["value"]
    post openid_connect_path, params: { authenticity_token: }
    authorization_params = Rack::Utils.parse_query(URI(response.location).query)
    assert_equal initiating_session.id, Oidc::Flow.pending.sole.initiating_session_id

    id_token = signed_id_token(
      signing_key, jwk, nonce: authorization_params.fetch("nonce"),
      subject: identity.subject, email: users(:kevin).email_address
    )
    stub_token_and_userinfo(id_token:, subject: identity.subject, email: users(:kevin).email_address)
    initiating_session.destroy!

    assert_no_difference -> { Session.where(authentication_method: "oidc").count } do
      get "/auth/openid_connect/callback", params: {
        code: "authorization-code", state: authorization_params.fetch("state")
      }
    end

    assert_redirected_to new_session_url
    assert_not Session.exists?(initiating_session.id)
  end

  test "linking submits a destination-bound CSRF token through the mounted middleware" do
    sign_in_with_csrf users(:jz)
    original_session = Session.find_by!(token: parsed_cookies.signed[:session_token])
    signing_key = OpenSSL::PKey::RSA.generate(2048)
    jwk = JSON::JWK.new(signing_key.public_key)
    stub_provider_metadata(jwk)

    get oidc_link_path
    authenticity_token = css_select("form[action='#{oidc_link_path}'] input[name='authenticity_token']").sole["value"]
    patch oidc_link_path, params: { authenticity_token:, current_password: "secret123456" }
    assert_redirected_to oidc_link_path

    get oidc_link_path
    authenticity_token = css_select("form[action='#{openid_connect_path}'] input[name='authenticity_token']").sole["value"]
    linking_state = css_select("form[action='#{openid_connect_path}'] input[name='linking_state']").sole["value"]
    post openid_connect_path, params: { authenticity_token:, oidc_linking: "1", linking_state: }

    assert_response :redirect
    authorization_params = Rack::Utils.parse_query(URI(response.location).query)
    assert_equal linking_state, authorization_params.fetch("state")

    subject = "linked-full-stack-subject"
    id_token = signed_id_token(
      signing_key, jwk, nonce: authorization_params.fetch("nonce"), subject:,
      email: users(:jz).email_address
    )
    stub_token_and_userinfo(id_token:, subject:, email: users(:jz).email_address)

    get "/auth/openid_connect/callback", params: {
      code: "authorization-code", state: authorization_params.fetch("state")
    }

    assert_redirected_to user_profile_url
    assert_equal subject, users(:jz).identities.find_by!(issuer: Oidc.issuer).subject
    assert_not Session.exists?(original_session.id)
    assert_equal "oidc", Session.find_by!(token: parsed_cookies.signed[:session_token]).authentication_method
  end

  test "required mode rejects ordinary HTTP without deleting existing credentials" do
    sign_in_with_csrf users(:jz)
    current_session = Session.find_by!(token: parsed_cookies.signed[:session_token])
    push_subscriptions(:jz_chrome).update!(session: current_session)
    configure_oidc(
      "OIDC_MODE" => "required",
      "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address
    )

    assert_no_changes -> { [ Session.count, Push::Subscription.count ] } do
      get root_path
    end

    assert_response :service_unavailable
    assert Session.exists?(current_session.id)
  end

  test "noncanonical auth paths are rejected before provider work" do
    get new_session_path
    authenticity_token = css_select("form[action='#{openid_connect_path}'] input[name='authenticity_token']").sole["value"]

    post "/AUTH/OPENID_CONNECT", params: { authenticity_token: }

    assert_response :not_found
    assert_not_requested :get, "https://idp.example.com/.well-known/openid-configuration"
  end

  test "the dependency logout phase is disabled" do
    assert_raises(ActionController::RoutingError) { get "/auth/openid_connect/logout" }

    assert_not_requested :get, "https://idp.example.com/.well-known/openid-configuration"
  end

  test "signed back-channel logout crosses mounted transport and revokes exact session capabilities" do
    identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "logout-full-stack-subject")
    session = users(:jz).sessions.start!(
      user_agent: "Browser", ip_address: "192.0.2.1", identity:,
      oidc_session_id: "logout-full-stack-session", oidc_issued_at: Time.current.to_i
    )
    subscription = push_subscriptions(:jz_chrome)
    subscription.update!(session:)
    signing_key = OpenSSL::PKey::RSA.generate(2048)
    jwk = JSON::JWK.new(signing_key.public_key)
    stub_provider_metadata(jwk)
    logout_token = signed_logout_token(
      signing_key, jwk, subject: identity.subject, sid: session.oidc_session_id
    )

    post oidc_back_channel_logout_path, params: { logout_token: }

    assert_response :success
    assert_not Session.exists?(session.id)
    assert_not Push::Subscription.exists?(subscription.id)

    post oidc_back_channel_logout_path, params: { logout_token: }
    assert_response :bad_request
  end

  test "back-channel logout before a JIT callback prevents first-login session creation" do
    configure_oidc("OIDC_JIT_PROVISIONING" => "true")
    signing_key = OpenSSL::PKey::RSA.generate(2048)
    jwk = JSON::JWK.new(signing_key.public_key)
    stub_provider_metadata(jwk)

    get new_session_path
    authenticity_token = css_select("form[action='#{openid_connect_path}'] input[name='authenticity_token']").sole["value"]
    post openid_connect_path, params: { authenticity_token: }
    authorization_params = Rack::Utils.parse_query(URI(response.location).query)
    issued_at = Time.current.to_i
    subject = "logout-before-jit-callback"
    sid = "logout-before-jit-session"
    email = "logout-before-jit@example.com"
    id_token = signed_id_token(
      signing_key, jwk, nonce: authorization_params.fetch("nonce"), subject:, email:, sid:, issued_at:
    )
    stub_token_and_userinfo(id_token:, subject:, email:)
    logout_token = signed_logout_token(signing_key, jwk, subject:, sid:, issued_at:)

    post oidc_back_channel_logout_path, params: { logout_token:, provider_hint: "ignored" }
    assert_response :success

    assert_no_changes -> { [ User.count, Identity.count, Session.count ] } do
      get "/auth/openid_connect/callback", params: {
        code: "authorization-code", state: authorization_params.fetch("state")
      }
    end

    assert_redirected_to new_session_url
    assert_not User.exists?(email_address: email)
    assert Oidc::Revocation.where.not(revoked_before: nil).exists?
  end

  test "issuer-bound SCIM deactivation crosses the mounted stack" do
    configure_scim
    identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "scim-full-stack-subject")
    session = users(:jz).sessions.start!(
      user_agent: "Browser", ip_address: "192.0.2.1", identity:,
      oidc_session_id: "scim-full-stack-session", oidc_issued_at: Time.current.to_i
    )
    push_subscriptions(:jz_chrome).update!(session:)

    patch scim_v2_user_path(identity.scim_id),
      params: {
        schemas: [ Scim::PATCH_OPERATION_SCHEMA ],
        Operations: [ { op: "replace", path: "active", value: false } ]
      }.to_json,
      headers: scim_headers

    assert_response :success
    assert users(:jz).reload.deactivated?
    assert_empty users(:jz).sessions
    assert_empty users(:jz).push_subscriptions
  end

  private
    def proxied_options(options)
      environment = options.fetch(:env, {})
      client_address = environment.fetch("REMOTE_ADDR", "203.0.113.20")
      unless Oidc.proxy_required?
        return options.merge(env: environment.merge(
          "REMOTE_ADDR" => "127.0.0.1",
          "HTTP_X_FORWARDED_FOR" => client_address,
          "HTTP_X_FORWARDED_PROTO" => "https",
          "HTTP_ORIGIN" => Oidc.configuration.canonical_origin
        ))
      end

      proxy_address = Oidc.trusted_proxy_ranges.first.to_range.begin.to_s
      options.merge(env: environment.merge(
        "REMOTE_ADDR" => proxy_address,
        "HTTP_X_FORWARDED_FOR" => client_address,
        "HTTP_X_FORWARDED_PROTO" => "https",
        "HTTP_X_FORWARDED_PORT" => Oidc.configuration.redirect_port.to_s,
        "HTTP_ORIGIN" => Oidc.configuration.canonical_origin
      ))
    end

    def stub_provider_metadata(jwk)
      stub_request(:get, "https://idp.example.com/.well-known/openid-configuration").to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          issuer: Oidc.issuer,
          authorization_endpoint: "https://idp.example.com/authorize",
          token_endpoint: "https://idp.example.com/token",
          userinfo_endpoint: "https://idp.example.com/userinfo",
          jwks_uri: "https://idp.example.com/jwks",
          response_types_supported: [ "code" ],
          code_challenge_methods_supported: [ "S256" ],
          token_endpoint_auth_methods_supported: [ "client_secret_basic" ],
          subject_types_supported: [ "public" ],
          id_token_signing_alg_values_supported: [ "RS256" ]
        }.to_json
      )
      stub_request(:get, "https://idp.example.com/jwks").to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { keys: [ jwk.as_json ] }.to_json
      )
    end

    def sign_in_with_csrf(user)
      get new_session_path
      authenticity_token = css_select("form[action='#{session_url}'] input[name='authenticity_token']").sole["value"]
      post session_path, params: {
        authenticity_token:, email_address: user.email_address, password: "secret123456"
      }
      assert_redirected_to root_url
    end

    def signed_id_token(signing_key, jwk, nonce:, subject: "full-stack-subject", email: users(:jz).email_address,
        sid: "full-stack-provider-session", issued_at: Time.current.to_i)
      JSON::JWT.new(
        iss: Oidc.issuer,
        sub: subject,
        aud: Oidc.client_id,
        exp: 5.minutes.from_now.to_i,
        iat: issued_at,
        nonce:,
        sid:,
        email:,
        email_verified: true
      ).tap { _1.kid = jwk.thumbprint }.sign(signing_key, :RS256).to_s
    end

    def signed_logout_token(signing_key, jwk, subject:, sid:, issued_at: Time.current.to_i)
      JSON::JWT.new(
        iss: Oidc.issuer,
        aud: Oidc.client_id,
        iat: issued_at,
        exp: 5.minutes.from_now.to_i,
        jti: SecureRandom.uuid,
        events: { Oidc::LogoutTokenVerifier::BACK_CHANNEL_LOGOUT_EVENT => {} },
        sub: subject,
        sid:
      ).tap { _1.kid = jwk.thumbprint }.sign(signing_key, :RS256).to_s
    end

    def stub_token_and_userinfo(id_token:, subject:, email:)
      stub_request(:post, "https://idp.example.com/token").to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { access_token: "access-token", token_type: "Bearer", id_token: }.to_json
      )
      stub_request(:get, "https://idp.example.com/userinfo")
        .with(headers: { "Authorization" => "Bearer access-token" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { sub: subject, email:, email_verified: true }.to_json
        )
    end
end
