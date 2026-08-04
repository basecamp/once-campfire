require "test_helper"
require "campfire_open_id_connect_strategy"

class CampfireOpenIdConnectStrategyTest < ActiveSupport::TestCase
  setup do
    @strategy = CampfireOpenIdConnectStrategy.new(->(_env) { [ 200, {}, [] ] })
  end

  test "requires an ID token in the token response" do
    token = stub(id_token: nil)

    assert_raises(OmniAuth::Strategies::OpenIDConnect::CallbackError) do
      @strategy.send(:validate_access_token!, token)
    end
  end

  test "uses only the session-bound PKCE verifier" do
    token = stub(id_token: "id-token")
    client = mock
    client.expects(:access_token!).with(has_entry(code_verifier: "stored-verifier")).returns(token)
    @strategy.instance_variable_set(:@env, "rack.session" => { "omniauth.pkce.verifier" => "stored-verifier" })
    @strategy.options.pkce = true
    @strategy.stubs(:client).returns(client)
    @strategy.stubs(:configured_response_type).returns("code")
    @strategy.stubs(:verify_id_token!)

    assert_equal token, @strategy.send(:access_token)
  end

  test "rejects a missing session-bound PKCE verifier" do
    @strategy.instance_variable_set(:@env, "rack.session" => {})
    @strategy.options.pkce = true

    assert_raises(OmniAuth::Strategies::OpenIDConnect::CallbackError) do
      @strategy.send(:access_token)
    end
  end

  test "uses only the session-bound nonce" do
    verified_token = mock
    verified_token.expects(:verify!).with(
      issuer: "https://idp.example.com", client_id: "campfire", nonce: "stored-nonce"
    )
    @strategy.instance_variable_set(:@env, "rack.session" => { "omniauth.nonce" => "stored-nonce" })
    @strategy.options.issuer = "https://idp.example.com"
    @strategy.options.client_options.identifier = "campfire"
    @strategy.stubs(:decode_id_token).with("id-token").returns(verified_token)

    @strategy.send(:verify_id_token!, "id-token")
  end

  test "rejects insecure discovered endpoints" do
    @strategy.options.client_options.authorization_endpoint = "http://idp.example.com/authorize"
    @strategy.options.client_options.token_endpoint = "https://idp.example.com/token"
    @strategy.options.client_options.userinfo_endpoint = "https://idp.example.com/userinfo"
    @strategy.options.client_options.jwks_uri = "https://idp.example.com/jwks"

    assert_raises(Oidc::EndpointError) do
      @strategy.send(:validate_discovered_endpoints!)
    end
  end

  test "rejects a provider that does not advertise required capabilities" do
    config = stub(
      raw: {},
      response_types_supported: [ "code" ],
      id_token_signing_alg_values_supported: [ "RS256" ],
      token_endpoint_auth_methods_supported: [ "client_secret_basic" ]
    )
    @strategy.stubs(:config).returns(config)

    assert_raises(Oidc::EndpointError) { @strategy.send(:validate_provider_capabilities!) }
  end

  test "requires UserInfo to match the ID token subject" do
    token = stub(id_token: "id-token")
    token.stubs(:userinfo!).returns(user_info("different-subject"))
    @strategy.stubs(:access_token).returns(token)
    @strategy.stubs(:decode_id_token).returns(token_claims("token-subject"))

    assert_raises(OmniAuth::Strategies::OpenIDConnect::CallbackError) do
      @strategy.send(:user_info)
    end
  end

  test "merges validated UserInfo with authoritative ID token claims" do
    token = stub(id_token: "id-token")
    token.stubs(:userinfo!).returns(user_info("token-subject"))
    @strategy.stubs(:access_token).returns(token)
    @strategy.stubs(:decode_id_token).returns(token_claims("token-subject"))

    result = @strategy.send(:user_info)

    assert_equal "token-subject", result.sub
    assert_equal "person@example.com", result.email
  end

  test "completes a signed authorization code flow" do
    configure_oidc
    signing_key = OpenSSL::PKey::RSA.generate(2048)
    jwk = JSON::JWK.new(signing_key.public_key)
    stub_provider_metadata(jwk)

    browser_session = {}
    request_strategy = strategy_for(request_environment(browser_session))
    status, headers = request_strategy.request_phase

    assert_equal 302, status
    authorization_params = Rack::Utils.parse_query(URI(headers.fetch("location")).query)
    assert_equal "S256", authorization_params["code_challenge_method"]
    assert_equal browser_session.fetch("omniauth.state"), authorization_params["state"]
    assert_equal browser_session.fetch("omniauth.nonce"), authorization_params["nonce"]
    assert browser_session["omniauth.pkce.verifier"].present?

    id_token = signed_id_token(signing_key, jwk, nonce: browser_session.fetch("omniauth.nonce"))
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
        body: { sub: "signed-subject", email: "signed@example.com", email_verified: true }.to_json
      )

    captured_auth = nil
    callback_strategy = strategy_for(callback_environment(browser_session, authorization_params.fetch("state"))) do |env|
      env.fetch("oidc.flow").finalize! do
        captured_auth = env.fetch("omniauth.auth")
        [ 200, {}, [ "ok" ] ]
      end
    end

    callback_status, = callback_strategy.callback_phase

    assert_equal 200, callback_status
    assert_equal "signed-subject", captured_auth.uid
    assert_equal "signed@example.com", captured_auth.info.email
    assert_nil browser_session["omniauth.state"]
    assert_nil browser_session["omniauth.nonce"]
    assert_nil browser_session["omniauth.pkce.verifier"]
    assert_not Oidc::Flow.exists?
  end

  test "rejects weak provider RSA signing keys" do
    configure_oidc
    signing_key = OpenSSL::PKey::RSA.generate(1024)
    jwk = JSON::JWK.new(signing_key.public_key)
    stub_provider_metadata(jwk)
    token = signed_id_token(signing_key, jwk, nonce: "nonce")

    assert_raises(Oidc::EndpointError) do
      strategy_for(request_environment({})).send(:decode_id_token, token)
    end
  end

  test "rejects recursive SWD discovery redirects without following them" do
    configure_oidc
    discovery_url = "https://idp.example.com/.well-known/openid-configuration"
    stub_request(:get, discovery_url).to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { SWD_service_redirect: { location: discovery_url } }.to_json
    )

    assert_raises(OpenIDConnect::Discovery::DiscoveryFailed) do
      strategy_for(request_environment({})).send(:discover!)
    end
    assert_requested :get, discovery_url, times: 1
  end

  test "does not let a second browser tab invalidate an active flow" do
    configure_oidc
    signing_key = OpenSSL::PKey::RSA.generate(2048)
    stub_provider_metadata(JSON::JWK.new(signing_key.public_key))
    browser_session = {}

    first_status, = strategy_for(request_environment(browser_session)).request_phase
    original_state = browser_session.fetch("omniauth.state")
    second_status, second_headers = strategy_for(request_environment(browser_session)).request_phase

    assert_equal 302, first_status
    assert_equal 303, second_status
    assert_equal "/oidc_flow", second_headers.fetch("location")
    assert_equal original_state, browser_session.fetch("omniauth.state")
  end

  private
    def strategy_for(environment, &app)
      app ||= ->(_env) { [ 200, {}, [] ] }
      CampfireOpenIdConnectStrategy.new(
        app,
        issuer: Oidc.issuer,
        discovery: true,
        scope: %i[ openid email profile ],
        response_type: :code,
        send_state: true,
        require_state: true,
        send_nonce: true,
        pkce: true,
        client_signing_alg: :RS256,
        client_options: {
          identifier: Oidc.client_id,
          secret: Oidc.client_secret,
          redirect_uri: Oidc.redirect_uri
        }
      ).tap { _1.instance_variable_set(:@env, environment) }
    end

    def request_environment(browser_session)
      Rack::MockRequest.env_for(
        "https://campfire.example.com/auth/openid_connect",
        method: "POST",
        "HTTP_COOKIE" => "#{Oidc::BROWSER_COOKIE}=#{browser_token(browser_session)}"
      ).merge("rack.session" => browser_session)
    end

    def callback_environment(browser_session, state)
      Rack::MockRequest.env_for(
        "https://campfire.example.com/auth/openid_connect/callback?code=authorization-code&state=#{state}",
        "HTTP_COOKIE" => "#{Oidc::BROWSER_COOKIE}=#{browser_token(browser_session)}"
      ).merge("rack.session" => browser_session)
    end

    def browser_token(browser_session)
      Digest::SHA256.hexdigest(browser_session.object_id.to_s)
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

    def signed_id_token(signing_key, jwk, nonce:)
      JSON::JWT.new(
        iss: Oidc.issuer,
        sub: "signed-subject",
        aud: Oidc.client_id,
        exp: 5.minutes.from_now.to_i,
        iat: Time.current.to_i,
        nonce:,
        email: "signed@example.com",
        email_verified: true
      ).tap { _1.kid = jwk.thumbprint }.sign(signing_key, :RS256).to_s
    end

    def user_info(subject)
      OpenIDConnect::ResponseObject::UserInfo.new(
        sub: subject,
        email: "person@example.com",
        email_verified: true
      )
    end

    def token_claims(subject)
      stub(sub: subject, raw_attributes: { "sub" => subject })
    end
end
