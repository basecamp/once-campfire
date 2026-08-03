require "test_helper"
require "oidc/logout_token_verifier"

class Oidc::LogoutTokenVerifierTest < ActiveSupport::TestCase
  SIGNING_KEY = OpenSSL::PKey::RSA.generate(2048)
  JWK = JSON::JWK.new(SIGNING_KEY.public_key)

  setup do
    configure_oidc
    Resolv.stubs(:getaddresses).with("idp.example.com").returns([ "93.184.216.34" ])
    stub_verification_material
  end

  test "validates a signed standards-shaped logout token" do
    claims = Oidc::LogoutTokenVerifier.new.verify(signed_logout_token)

    assert_equal Oidc.issuer, claims.fetch("iss")
    assert_equal "logout-subject", claims.fetch("sub")
    assert_equal "provider-session", claims.fetch("sid")
    assert_requested :get, "https://idp.example.com/.well-known/openid-configuration"
    assert_requested :get, "https://idp.example.com/jwks"
  end

  test "requires the configured algorithm and a valid signature" do
    assert_invalid signed_logout_token(algorithm: :RS384)

    attacker_key = OpenSSL::PKey::RSA.generate(2048)
    assert_invalid signed_logout_token(signing_key: attacker_key)
  end

  test "requires issuer audience issue time identifier and logout event" do
    invalid_claims = [
      { "iss" => nil },
      { "iss" => "https://attacker.example.com" },
      { "aud" => nil },
      { "aud" => "another-client" },
      { "iat" => nil },
      { "iat" => 10.minutes.ago.to_i },
      { "iat" => 2.minutes.from_now.to_i },
      { "exp" => nil },
      { "exp" => 2.minutes.ago.to_i },
      { "jti" => nil },
      { "events" => {} },
      { "events" => { Oidc::LogoutTokenVerifier::BACK_CHANNEL_LOGOUT_EVENT => true } }
    ]

    invalid_claims.each { assert_invalid signed_logout_token(claims: _1), message: _1.inspect }
    assert_invalid compact_token(payload: logout_claims.merge(exp: 5.minutes.from_now.to_f).to_json)
  end

  test "accepts only Campfire as the audience and authorized party" do
    assert_equal [ Oidc.client_id ], Oidc::LogoutTokenVerifier.new.verify(
      signed_logout_token(claims: { "aud" => [ Oidc.client_id ], "azp" => Oidc.client_id })
    ).fetch("aud")

    assert_invalid signed_logout_token(
      claims: { "aud" => [ Oidc.client_id, "another-api" ], "azp" => Oidc.client_id }
    )
    assert_invalid signed_logout_token(claims: { "azp" => "another-client" })
    assert_invalid signed_logout_token(claims: { "azp" => 123 })
  end

  test "rejects nonce and unusable subject or session semantics" do
    assert_invalid signed_logout_token(claims: { "nonce" => "browser-nonce" })
    assert_invalid signed_logout_token(claims: { "sub" => nil, "sid" => nil })
    assert_invalid signed_logout_token(claims: { "sub" => "", "sid" => nil })
    assert_invalid signed_logout_token(claims: { "sub" => nil, "sid" => 123 })

    assert_equal "logout-subject",
      Oidc::LogoutTokenVerifier.new.verify(signed_logout_token(without: [ "sid" ])).fetch("sub")
    assert_equal "provider-session",
      Oidc::LogoutTokenVerifier.new.verify(signed_logout_token(without: [ "sub" ])).fetch("sid")
  end

  test "rejects duplicate JWT members before provider work" do
    WebMock.reset!
    payload = logout_claims.to_json.sub(
      /\A\{/,
      %({"iss":"#{Oidc.issuer}",)
    )

    assert_invalid compact_token(payload:)
    assert_not_requested :get, "https://idp.example.com/.well-known/openid-configuration"
  end

  test "rejects duplicate or incompatible JWKS keys" do
    duplicate = JWK.as_json.deep_dup
    stub_request(:get, "https://idp.example.com/jwks").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { keys: [ JWK.as_json, duplicate ] }.to_json
    )
    assert_invalid signed_logout_token

    incompatible = JWK.as_json.merge(alg: "RS384")
    stub_request(:get, "https://idp.example.com/jwks").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { keys: [ incompatible ] }.to_json
    )
    assert_invalid signed_logout_token
  end

  test "fails closed when discovery changes issuer or escapes the host allowlist" do
    stub_request(:get, "https://idp.example.com/.well-known/openid-configuration").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: provider_metadata.merge(issuer: "https://attacker.example.com").to_json
    )
    assert_unavailable signed_logout_token

    stub_request(:get, "https://idp.example.com/.well-known/openid-configuration").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: provider_metadata.merge(jwks_uri: "https://attacker.example.com/jwks").to_json
    )
    assert_unavailable signed_logout_token
    assert_not_requested :get, "https://attacker.example.com/jwks"
  end

  test "fails closed on unavailable or malformed verification material" do
    stub_request(:get, "https://idp.example.com/.well-known/openid-configuration").to_return(status: 503)
    assert_unavailable signed_logout_token

    stub_request(:get, "https://idp.example.com/.well-known/openid-configuration").to_return(
      status: 200, body: '{"issuer":"first","issuer":"second"}'
    )
    assert_unavailable signed_logout_token
  end

  test "caches bounded verification material" do
    verifier = Oidc::LogoutTokenVerifier.new

    2.times { assert_equal "logout-subject", verifier.verify(signed_logout_token).fetch("sub") }

    assert_requested :get, "https://idp.example.com/.well-known/openid-configuration", times: 1
    assert_requested :get, "https://idp.example.com/jwks", times: 1
  end

  test "refreshes once on a cached kid miss so rotated keys work" do
    verifier = Oidc::LogoutTokenVerifier.new
    verifier.verify signed_logout_token

    rotated_key = OpenSSL::PKey::RSA.generate(2048)
    rotated_jwk = JSON::JWK.new(rotated_key.public_key)
    stub_request(:get, "https://idp.example.com/jwks").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { keys: [ rotated_jwk.as_json ] }.to_json
    )

    claims = verifier.verify signed_logout_token(signing_key: rotated_key, kid: rotated_jwk.thumbprint)

    assert_equal "logout-subject", claims.fetch("sub")
    assert_requested :get, "https://idp.example.com/.well-known/openid-configuration", times: 2
    assert_requested :get, "https://idp.example.com/jwks", times: 2
  end

  test "refreshes once when a cached kid is reused for a rotated signing key" do
    verifier = Oidc::LogoutTokenVerifier.new(cache: ActiveSupport::Cache::MemoryStore.new)
    verifier.verify signed_logout_token

    rotated_key = OpenSSL::PKey::RSA.generate(2048)
    rotated_jwk = JSON::JWK.new(rotated_key.public_key).as_json.merge("kid" => JWK.thumbprint)
    stub_request(:get, "https://idp.example.com/jwks").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { keys: [ rotated_jwk ] }.to_json
    )

    claims = verifier.verify signed_logout_token(signing_key: rotated_key, kid: JWK.thumbprint)

    assert_equal "logout-subject", claims.fetch("sub")
    assert_requested :get, "https://idp.example.com/.well-known/openid-configuration", times: 2
    assert_requested :get, "https://idp.example.com/jwks", times: 2
  end

  test "coordinates concurrent same-kid rotation behind one outbound refresh" do
    cache = ActiveSupport::Cache::MemoryStore.new
    Oidc::LogoutTokenVerifier.new(cache:).verify signed_logout_token
    rotated_key = OpenSSL::PKey::RSA.generate(2048)
    rotated_jwk = JSON::JWK.new(rotated_key.public_key).as_json.merge("kid" => JWK.thumbprint)
    refresh_started = Queue.new
    release_refresh = Queue.new
    follower_waiting = Queue.new
    results = Queue.new
    threads = []

    stub_request(:get, "https://idp.example.com/jwks").to_return do
      refresh_started << true
      release_refresh.pop
      {
        status: 200, headers: { "Content-Type" => "application/json" },
        body: { keys: [ rotated_jwk ] }.to_json
      }
    end

    verify = lambda do |verifier, token|
      Thread.new do
        results << verifier.verify(token)
      rescue StandardError => error
        results << error
      end
    end
    tokens = 3.times.map do |index|
      signed_logout_token(
        signing_key: rotated_key, kid: JWK.thumbprint, claims: { "jti" => "rotated-#{index}" }
      )
    end

    threads << verify.call(Oidc::LogoutTokenVerifier.new(cache:), tokens.shift)
    refresh_started.pop
    2.times do
      sleeper = ->(duration) { follower_waiting << true; sleep duration }
      threads << verify.call(Oidc::LogoutTokenVerifier.new(cache:, sleeper:), tokens.shift)
    end
    Timeout.timeout(2) { 2.times { follower_waiting.pop } }
    release_refresh << true
    threads.each(&:join)

    outcomes = 3.times.map { results.pop }
    assert outcomes.all? { _1.is_a?(Hash) && _1["sub"] == "logout-subject" }, outcomes.inspect
    assert_requested :get, "https://idp.example.com/.well-known/openid-configuration", times: 2
    assert_requested :get, "https://idp.example.com/jwks", times: 2
  ensure
    release_refresh << true if threads&.any?(&:alive?)
    threads&.each { _1.join(2) }
  end

  test "fails followers closed when the coordinated refresher fails" do
    cache = ActiveSupport::Cache::MemoryStore.new
    leader = Oidc::LogoutTokenVerifier.new(cache:)
    leader.verify signed_logout_token
    rotated_key = OpenSSL::PKey::RSA.generate(2048)
    rotated = signed_logout_token(signing_key: rotated_key, kid: JWK.thumbprint)
    stub_request(:get, "https://idp.example.com/.well-known/openid-configuration").to_return(status: 503)

    assert_raises(Oidc::LogoutTokenVerifier::Unavailable) { leader.verify(rotated) }
    assert_raises(Oidc::LogoutTokenVerifier::Unavailable) do
      Oidc::LogoutTokenVerifier.new(cache:).verify(rotated)
    end

    assert_requested :get, "https://idp.example.com/.well-known/openid-configuration", times: 2
    assert_requested :get, "https://idp.example.com/jwks", times: 1
  end

  test "fails closed when an in-progress verification refresh times out" do
    cache = ActiveSupport::Cache::MemoryStore.new
    monotonic_time = 0.0
    verifier = Oidc::LogoutTokenVerifier.new(
      cache:,
      monotonic_clock: -> { monotonic_time },
      sleeper: ->(duration) { monotonic_time += duration }
    )
    verifier.verify signed_logout_token
    cache.write(
      verifier.send(:cache_key, "refresh"),
      { "status" => "refreshing", "generation" => "a" * 32, "token" => "b" * 64 },
      expires_in: Oidc::LogoutTokenVerifier::VERIFICATION_REFRESH_LEASE
    )
    rotated_key = OpenSSL::PKey::RSA.generate(2048)

    error = assert_raises(Oidc::LogoutTokenVerifier::Unavailable) do
      verifier.verify signed_logout_token(signing_key: rotated_key, kid: JWK.thumbprint)
    end

    assert_match(/timed out/, error.message)
    assert_requested :get, "https://idp.example.com/.well-known/openid-configuration", times: 1
    assert_requested :get, "https://idp.example.com/jwks", times: 1
  end

  test "rejects an invalid known-kid signature after one refresh" do
    verifier = Oidc::LogoutTokenVerifier.new(cache: ActiveSupport::Cache::MemoryStore.new)
    verifier.verify signed_logout_token
    attacker_key = OpenSSL::PKey::RSA.generate(2048)

    assert_raises(Oidc::LogoutTokenVerifier::Invalid) do
      verifier.verify signed_logout_token(signing_key: attacker_key, kid: JWK.thumbprint)
    end

    assert_requested :get, "https://idp.example.com/.well-known/openid-configuration", times: 2
    assert_requested :get, "https://idp.example.com/jwks", times: 2
  end

  test "globally throttles repeated known-kid signature refreshes" do
    verifier = Oidc::LogoutTokenVerifier.new(cache: ActiveSupport::Cache::MemoryStore.new)
    verifier.verify signed_logout_token
    attacker_key = OpenSSL::PKey::RSA.generate(2048)
    invalid = signed_logout_token(signing_key: attacker_key, kid: JWK.thumbprint)

    2.times do
      assert_raises(Oidc::LogoutTokenVerifier::Invalid) { verifier.verify(invalid) }
    end

    assert_requested :get, "https://idp.example.com/.well-known/openid-configuration", times: 2
    assert_requested :get, "https://idp.example.com/jwks", times: 2
  end

  test "globally throttles repeated attacker-controlled kid misses" do
    verifier = Oidc::LogoutTokenVerifier.new
    verifier.verify signed_logout_token

    2.times do
      assert_invalid signed_logout_token(kid: SecureRandom.hex(16))
    end

    assert_requested :get, "https://idp.example.com/.well-known/openid-configuration", times: 2
    assert_requested :get, "https://idp.example.com/jwks", times: 2
  end

  private
    def assert_invalid(token, message: nil)
      expected = [ Oidc::LogoutTokenVerifier::Invalid ]
      expected << message if message
      assert_raises(*expected) do
        Oidc::LogoutTokenVerifier.new.verify(token)
      end
    end

    def assert_unavailable(token)
      assert_raises(Oidc::LogoutTokenVerifier::Unavailable) do
        Oidc::LogoutTokenVerifier.new.verify(token)
      end
    end

    def signed_logout_token(claims: {}, without: [], signing_key: SIGNING_KEY, algorithm: :RS256,
        kid: JWK.thumbprint)
      attributes = logout_claims.stringify_keys.merge(claims.stringify_keys).except(*without)
      JSON::JWT.new(attributes).tap { _1.kid = kid }
        .sign(signing_key, algorithm).to_s
    end

    def logout_claims
      {
        iss: Oidc.issuer,
        aud: Oidc.client_id,
        iat: Time.current.to_i,
        exp: 5.minutes.from_now.to_i,
        jti: SecureRandom.uuid,
        events: { Oidc::LogoutTokenVerifier::BACK_CHANNEL_LOGOUT_EVENT => {} },
        sub: "logout-subject",
        sid: "provider-session"
      }
    end

    def compact_token(payload:)
      header = { typ: "JWT", alg: "RS256", kid: JWK.thumbprint }.to_json
      encoded_header = Base64.urlsafe_encode64(header, padding: false)
      encoded_payload = Base64.urlsafe_encode64(payload, padding: false)
      signing_input = [ encoded_header, encoded_payload ].join(".")
      signature = SIGNING_KEY.sign(OpenSSL::Digest::SHA256.new, signing_input)
      [ signing_input, Base64.urlsafe_encode64(signature, padding: false) ].join(".")
    end

    def stub_verification_material
      stub_request(:get, "https://idp.example.com/.well-known/openid-configuration").to_return(
        status: 200, headers: { "Content-Type" => "application/json" }, body: provider_metadata.to_json
      )
      stub_request(:get, "https://idp.example.com/jwks").to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: { keys: [ JWK.as_json ] }.to_json
      )
    end

    def provider_metadata
      {
        issuer: Oidc.issuer,
        jwks_uri: "https://idp.example.com/jwks",
        id_token_signing_alg_values_supported: [ Oidc.signing_algorithm ]
      }
    end
end
