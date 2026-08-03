module ScimTestHelper
  SCIM_BEARER_TOKEN = "scim-test-token-#{'a' * 48}"
  DEFAULT_SCIM_ENV = {
    "SCIM_ENABLED" => "true",
    "SCIM_BEARER_TOKEN" => SCIM_BEARER_TOKEN
  }.freeze

  def configure_scim(overrides = {})
    @original_scim_configuration ||= Scim.configuration
    Scim.configuration = Scim::Configuration.new(
      DEFAULT_SCIM_ENV.merge(overrides.stringify_keys),
      oidc_configuration: Oidc.configuration
    )
  end

  def reset_scim_configuration
    if @original_scim_configuration
      Scim.configuration = @original_scim_configuration
      @original_scim_configuration = nil
    end
  end

  def scim_headers(token: SCIM_BEARER_TOKEN)
    {
      "Authorization" => "Bearer #{token}",
      "Content-Type" => Scim::MEDIA_TYPE,
      "Accept" => Scim::MEDIA_TYPE
    }
  end
end
