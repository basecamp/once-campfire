require "uri"

class OidcConfiguration
  PROVIDERS_ENV_KEY = "OIDC_PROVIDERS".freeze
  PROVIDER_KEY_FORMAT = /\A[a-z][a-z0-9_]*\z/.freeze
  REQUIRED_KEYS = %w[ISSUER CLIENT_ID CLIENT_SECRET REDIRECT_URI].freeze
  DEFAULT_SCOPE = %w[openid email profile].freeze
  DEFAULT_CLIENT_AUTH_METHOD = "basic".freeze

  class << self
    def providers(env: ENV)
      provider_keys(env:)
        .map { build_provider(_1, env:) }
        .tap { validate_unique_strategy_names!(_1) }
    end

    def strategy_names(env: ENV)
      providers(env:).map { _1[:strategy] }
    end

    def provider_for_strategy(strategy, env: ENV)
      strategy_name = strategy.to_s
      return if strategy_name.blank?

      providers(env:).find { _1.fetch(:strategy) == strategy_name }
    end

    private
      def provider_keys(env:)
        keys = env.fetch(PROVIDERS_ENV_KEY, "")
          .split(",")
          .map { _1.strip.downcase }
          .reject(&:blank?)

        duplicates = keys.tally.select { _2 > 1 }.keys
        if duplicates.any?
          raise ArgumentError, "Duplicate OIDC provider keys in #{PROVIDERS_ENV_KEY}: #{duplicates.join(', ')}"
        end

        invalid = keys.reject { PROVIDER_KEY_FORMAT.match?(_1) }
        if invalid.any?
          raise ArgumentError, "Invalid OIDC provider key(s): #{invalid.join(', ')}. Use lowercase letters, numbers, and underscores."
        end

        keys
      end

      def build_provider(key, env:)
        uppercase_key = key.upcase
        required_config = REQUIRED_KEYS.to_h do |config_key|
          [ config_key.downcase.to_sym, read_required(env:, provider_key: uppercase_key, config_key:) ]
        end

        strategy = strategy_from_redirect_uri(required_config.fetch(:redirect_uri))

        {
          key:,
          strategy:,
          display_name: provider_display_name(env:, uppercase_key:, key:),
          scope: parse_scope(env["OIDC_#{uppercase_key}_SCOPE"]),
          client_auth_method: env["OIDC_#{uppercase_key}_CLIENT_AUTH_METHOD"].presence || DEFAULT_CLIENT_AUTH_METHOD,
          end_session_endpoint: env["OIDC_#{uppercase_key}_END_SESSION_ENDPOINT"].presence
        }.merge(required_config)
      end

      def provider_display_name(env:, uppercase_key:, key:)
        env["OIDC_#{uppercase_key}_PROVIDER_NAME"].presence ||
          env["OIDC_#{uppercase_key}_DISPLAY_NAME"].presence ||
          key.tr("_", " ").titleize
      end

      def strategy_from_redirect_uri(redirect_uri)
        uri = URI.parse(redirect_uri)
        strategy = uri.path[%r{\A/auth/(?<provider>[a-z0-9_]+)/callback\z}, :provider]

        if strategy.blank?
          raise ArgumentError, "OIDC redirect URI must use /auth/<provider>/callback (got #{redirect_uri.inspect})"
        end

        strategy
      rescue URI::InvalidURIError => e
        raise ArgumentError, "OIDC redirect URI is invalid: #{e.message}"
      end

      def validate_unique_strategy_names!(providers)
        duplicates = providers.map { _1.fetch(:strategy) }.tally.select { _2 > 1 }.keys
        return if duplicates.empty?

        raise ArgumentError, "OIDC redirect URIs resolve to duplicate strategy names: #{duplicates.join(', ')}"
      end

      def read_required(env:, provider_key:, config_key:)
        env_key = "OIDC_#{provider_key}_#{config_key}"
        value = env[env_key].to_s.strip

        raise ArgumentError, "#{env_key} is required when #{PROVIDERS_ENV_KEY} includes '#{provider_key.downcase}'" if value.blank?

        value
      end

      def parse_scope(raw_scope)
        parsed_scope = raw_scope.to_s.split(/[\s,]+/).reject(&:blank?)
        parsed_scope.presence || DEFAULT_SCOPE
      end
  end
end
