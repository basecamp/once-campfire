require "test_helper"

class Oidc::ConfigurationTest < ActiveSupport::TestCase
  VALID_ENV = OidcTestHelper::DEFAULT_OIDC_ENV

  test "OIDC is disabled by default" do
    configuration = Oidc::Configuration.new({})

    assert_not configuration.enabled?
    assert_not configuration.required?
    assert_not configuration.jit_provisioning?
  end

  test "loads a complete configuration" do
    configuration = Oidc::Configuration.new(VALID_ENV.merge(
      "OIDC_MODE" => "required",
      "OIDC_PROVIDER_NAME" => "Acme Identity",
      "OIDC_JIT_PROVISIONING" => "true",
      "OIDC_SESSION_LIFETIME" => "3600",
      "OIDC_BREAK_GLASS_EMAIL" => " ADMIN@EXAMPLE.COM ",
      "OIDC_ALLOWED_HOSTS" => "tokens.example.com, JWKS.EXAMPLE.COM."
    ))

    assert configuration.enabled?
    assert configuration.required?
    assert configuration.jit_provisioning?
    assert_equal "Acme Identity", configuration.provider_name
    assert_equal 3600, configuration.session_lifetime_seconds
    assert_equal "admin@example.com", configuration.break_glass_email
    assert_equal %w[idp.example.com tokens.example.com jwks.example.com], configuration.allowed_hosts
  end

  test "requires all credentials when enabled" do
    error = assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.except("OIDC_CLIENT_SECRET"))
    end

    assert_match "OIDC_CLIENT_SECRET is required", error.message
  end

  test "rejects unknown modes and invalid booleans" do
    assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.merge("OIDC_MODE" => "enabled"))
    end

    assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.merge("OIDC_JIT_PROVISIONING" => "yes"))
    end
  end

  test "requires HTTPS issuer and redirect URLs" do
    assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.merge("OIDC_ISSUER" => "http://idp.example.com"))
    end

    assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.merge("OIDC_REDIRECT_URI" => "http://campfire.example.com/auth/openid_connect/callback"))
    end
  end

  test "requires the fixed callback path" do
    assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.merge("OIDC_REDIRECT_URI" => "https://campfire.example.com/callback"))
    end
  end

  test "bounds the persisted issuer identifier" do
    assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.merge("OIDC_ISSUER" => "https://idp.example.com/#{'a' * 240}"))
    end
  end

  test "only permits the tested signing algorithm and client authentication method" do
    assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.merge("OIDC_SIGNING_ALGORITHM" => "HS256"))
    end

    assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.merge("OIDC_SIGNING_ALGORITHM" => "ES256"))
    end

    assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.merge("OIDC_CLIENT_AUTH_METHOD" => "post"))
    end
  end

  test "requires the redirect host to match TLS_DOMAIN" do
    assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.merge("TLS_DOMAIN" => "another.example.com"))
    end
  end

  test "bounds federated session lifetime" do
    assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.merge("OIDC_SESSION_LIFETIME" => "60"))
    end

    assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.merge("OIDC_SESSION_LIFETIME" => "forever"))
    end
  end

  test "requires a valid break glass email" do
    assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.merge("OIDC_BREAK_GLASS_EMAIL" => "not-an-email"))
    end
  end

  test "requires explicit trusted proxy networks when application SSL is disabled" do
    error = assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.merge("DISABLE_SSL" => "true"))
    end

    assert_match "OIDC_TRUSTED_PROXY_CIDRS is required", error.message
  end

  test "accepts forwarded HTTPS only from configured proxy networks" do
    configuration = Oidc::Configuration.new(VALID_ENV.merge(
      "DISABLE_SSL" => "true",
      "OIDC_TRUSTED_PROXY_CIDRS" => "10.20.0.0/16, 2001:db8:1234::/48"
    ))

    assert configuration.trusted_proxy?("10.20.3.4")
    assert configuration.trusted_proxy?("2001:db8:1234::10")
    assert_not configuration.trusted_proxy?("10.21.3.4")
    assert_not configuration.trusted_proxy?("not-an-address")
  end

  test "direct TLS never trusts forwarding proxies" do
    configuration = Oidc::Configuration.new(VALID_ENV)

    assert_not configuration.trusted_proxy?("127.0.0.1")
    assert_not configuration.trusted_proxy?("10.20.3.4")
  end

  test "rejects proxy attribution networks without external TLS termination" do
    assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.merge("OIDC_TRUSTED_PROXY_CIDRS" => "10.20.0.0/16"))
    end
  end

  test "rejects invalid trusted proxy networks" do
    assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.merge(
        "DISABLE_SSL" => "true", "OIDC_TRUSTED_PROXY_CIDRS" => "not-a-network"
      ))
    end
  end

  test "binds TLS termination mode and port into the configuration fingerprint" do
    direct = Oidc::Configuration.new(VALID_ENV)
    proxy_environment = VALID_ENV.merge(
      "DISABLE_SSL" => "true", "OIDC_TRUSTED_PROXY_CIDRS" => "10.20.0.0/16"
    )
    proxied = Oidc::Configuration.new(proxy_environment)
    alternate_port = Oidc::Configuration.new(proxy_environment.merge(
      "HTTPS_PORT" => "8443",
      "OIDC_REDIRECT_URI" => "https://campfire.example.com:8443/auth/openid_connect/callback"
    ))

    assert_not_equal direct.fingerprint, proxied.fingerprint
    assert_not_equal proxied.fingerprint, alternate_port.fingerprint
    assert_equal 8443, alternate_port.redirect_port
  end

  test "uses effective prefixed Thruster settings in validation and fingerprints" do
    original = Oidc::Configuration.new(VALID_ENV)
    effective = Oidc::Configuration.new(VALID_ENV.merge(
      "THRUSTER_TLS_DOMAIN" => "campfire.example.com, alternate.example.com",
      "THRUSTER_HTTPS_PORT" => "443"
    ))

    assert_equal %w[ campfire.example.com alternate.example.com ], effective.tls_domains
    assert_not_equal original.fingerprint, effective.fingerprint
  end

  test "rejects empty or incompatible effective Thruster TLS settings" do
    [ "", "another.example.com" ].each do |domains|
      assert_raises(Oidc::ConfigurationError) do
        Oidc::Configuration.new(VALID_ENV.merge("THRUSTER_TLS_DOMAIN" => domains))
      end
    end

    assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.merge("THRUSTER_HTTPS_PORT" => ""))
    end
  end

  test "rejects non-default HTTPS ports with built-in Thruster TLS" do
    direct_non_default = VALID_ENV.merge(
      "HTTPS_PORT" => "8443",
      "OIDC_REDIRECT_URI" => "https://campfire.example.com:8443/auth/openid_connect/callback"
    )

    error = assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(direct_non_default)
    end
    assert_match "built-in Thruster TLS requires HTTPS_PORT=443", error.message

    error = assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(
        direct_non_default.except("HTTPS_PORT").merge("THRUSTER_HTTPS_PORT" => "8443")
      )
    end
    assert_match "built-in Thruster TLS requires HTTPS_PORT=443", error.message
  end

  test "binds the complete trusted proxy network into the configuration fingerprint" do
    proxy_environment = VALID_ENV.merge("DISABLE_SSL" => "true")
    narrow = Oidc::Configuration.new(proxy_environment.merge(
      "OIDC_TRUSTED_PROXY_CIDRS" => "10.20.0.0/24"
    ))
    broad = Oidc::Configuration.new(proxy_environment.merge(
      "OIDC_TRUSTED_PROXY_CIDRS" => "10.20.0.0/16"
    ))

    assert_not narrow.trusted_proxy?("10.20.1.2")
    assert broad.trusted_proxy?("10.20.1.2")
    assert_not_equal narrow.fingerprint, broad.fingerprint
  end

  test "requires TLS_DOMAIN and rejects every Thruster true spelling for forwarded headers" do
    assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.except("TLS_DOMAIN"))
    end

    %w[ FORWARD_HEADERS THRUSTER_FORWARD_HEADERS ].each do |key|
      Oidc::Configuration::THRUSTER_TRUE_VALUES.each do |value|
        assert_raises(Oidc::ConfigurationError) do
          Oidc::Configuration.new(VALID_ENV.merge(key => value))
        end
      end
      Oidc::Configuration::THRUSTER_FALSE_VALUES.each do |value|
        assert Oidc::Configuration.new(VALID_ENV.merge(key => value)).enabled?
      end
    end

    error = assert_raises(Oidc::ConfigurationError) do
      Oidc::Configuration.new(VALID_ENV.merge("THRUSTER_FORWARD_HEADERS" => ""))
    end
    assert_match "must be a boolean understood by Thruster", error.message
  end

  test "requires a valid public HTTPS port" do
    %w[ 0 65536 invalid ].each do |port|
      assert_raises(Oidc::ConfigurationError) do
        Oidc::Configuration.new(VALID_ENV.merge("HTTPS_PORT" => port))
      end
    end
  end
end
