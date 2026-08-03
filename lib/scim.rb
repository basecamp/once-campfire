require "digest"

module Scim
  MEDIA_TYPE = "application/scim+json"
  USER_SCHEMA = "urn:ietf:params:scim:schemas:core:2.0:User"
  ERROR_SCHEMA = "urn:ietf:params:scim:api:messages:2.0:Error"
  LIST_RESPONSE_SCHEMA = "urn:ietf:params:scim:api:messages:2.0:ListResponse"
  PATCH_OPERATION_SCHEMA = "urn:ietf:params:scim:api:messages:2.0:PatchOp"
  SERVICE_PROVIDER_CONFIG_SCHEMA = "urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"

  class ConfigurationError < StandardError; end

  class Configuration
    MINIMUM_BEARER_TOKEN_BYTES = 32
    MAXIMUM_BEARER_TOKEN_BYTES = 512
    BEARER_TOKEN_PATTERN = /\A[A-Za-z0-9\-._~+\/]+=*\z/

    attr_reader :issuer

    def initialize(env = ENV, oidc_configuration: Oidc.configuration)
      @enabled = boolean_value(env, "SCIM_ENABLED", false)
      return unless enabled?

      unless oidc_configuration.enabled?
        raise ConfigurationError, "SCIM_ENABLED requires OIDC_MODE to be optional or required"
      end

      bearer_token = env["SCIM_BEARER_TOKEN"].to_s
      unless bearer_token.bytesize.between?(MINIMUM_BEARER_TOKEN_BYTES, MAXIMUM_BEARER_TOKEN_BYTES) &&
          bearer_token.match?(BEARER_TOKEN_PATTERN)
        raise ConfigurationError,
          "SCIM_BEARER_TOKEN must be a high-entropy secret between #{MINIMUM_BEARER_TOKEN_BYTES} and #{MAXIMUM_BEARER_TOKEN_BYTES} bytes"
      end

      @issuer = oidc_configuration.issuer
      @bearer_token_digest = Digest::SHA256.digest(bearer_token)
    end

    def enabled?
      @enabled
    end

    def authorized?(authorization)
      return false unless enabled? && authorization.is_a?(String)

      match = authorization.match(/\ABearer ([A-Za-z0-9\-._~+\/]+=*)\z/i)
      return false unless match && match[1].bytesize <= MAXIMUM_BEARER_TOKEN_BYTES

      ActiveSupport::SecurityUtils.secure_compare(
        @bearer_token_digest,
        Digest::SHA256.digest(match[1])
      )
    end

    private
      def boolean_value(env, key, default)
        return default unless env.key?(key)

        case env[key].to_s.downcase
        when "true" then true
        when "false" then false
        else raise ConfigurationError, "#{key} must be true or false"
        end
      end
  end

  class << self
    attr_accessor :configuration

    delegate :enabled?, :issuer, :authorized?, to: :configuration

    def ready?
      return true unless enabled?
      return false unless Oidc.enabled? && issuer == Oidc.issuer
      return false if Oidc.rollback_prepared?

        Identity.table_exists? &&
        Identity.column_names.include?("scim_id") &&
        Identity.column_names.include?("provider_revoked_at") &&
        Session.column_names.include?("oidc_session_id") &&
        Oidc::LogoutToken.ready?
    rescue Oidc::PolicyUnavailable, ActiveRecord::ActiveRecordError
      false
    end
  end
end
