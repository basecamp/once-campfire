require "test_helper"

class Scim::ConfigurationTest < ActiveSupport::TestCase
  setup do
    configure_oidc
  end

  test "SCIM is disabled unless explicitly enabled" do
    configuration = Scim::Configuration.new(
      { "SCIM_BEARER_TOKEN" => ScimTestHelper::SCIM_BEARER_TOKEN },
      oidc_configuration: Oidc.configuration
    )

    assert_not configuration.enabled?
  end

  test "enabled SCIM is pinned to the configured OIDC issuer" do
    configuration = Scim::Configuration.new(
      ScimTestHelper::DEFAULT_SCIM_ENV,
      oidc_configuration: Oidc.configuration
    )

    assert configuration.enabled?
    assert_equal Oidc.issuer, configuration.issuer
  end

  test "enabled SCIM requires OIDC and a strong bearer token" do
    assert_raises(Scim::ConfigurationError) do
      Scim::Configuration.new(
        ScimTestHelper::DEFAULT_SCIM_ENV,
        oidc_configuration: Oidc::Configuration.new({})
      )
    end

    assert_raises(Scim::ConfigurationError) do
      Scim::Configuration.new(
        ScimTestHelper::DEFAULT_SCIM_ENV.merge("SCIM_BEARER_TOKEN" => "too-short"),
        oidc_configuration: Oidc.configuration
      )
    end

    assert_raises(Scim::ConfigurationError) do
      Scim::Configuration.new(
        ScimTestHelper::DEFAULT_SCIM_ENV.merge("SCIM_BEARER_TOKEN" => "!" * 64),
        oidc_configuration: Oidc.configuration
      )
    end
  end

  test "bearer authentication is exact and does not retain a public secret" do
    configuration = Scim::Configuration.new(
      ScimTestHelper::DEFAULT_SCIM_ENV,
      oidc_configuration: Oidc.configuration
    )

    assert configuration.authorized?("Bearer #{ScimTestHelper::SCIM_BEARER_TOKEN}")
    assert configuration.authorized?("bearer #{ScimTestHelper::SCIM_BEARER_TOKEN}")
    assert_not configuration.authorized?("Token #{ScimTestHelper::SCIM_BEARER_TOKEN}")
    assert_not configuration.authorized?("Bearer #{ScimTestHelper::SCIM_BEARER_TOKEN} extra")
    assert_not_respond_to configuration, :bearer_token
  end

  test "rejects invalid enablement booleans" do
    assert_raises(Scim::ConfigurationError) do
      Scim::Configuration.new(
        ScimTestHelper::DEFAULT_SCIM_ENV.merge("SCIM_ENABLED" => "yes"),
        oidc_configuration: Oidc.configuration
      )
    end
  end
end
