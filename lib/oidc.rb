require "uri"
require "digest"
require "ipaddr"
require "json"
require "openssl"
require "email_address"

module Oidc
  LINKING_INTENT_SESSION_KEY = "oidc.linking_intent"
  FLOW_STARTED_AT_SESSION_KEY = "oidc.flow_started_at"
  BROWSER_COOKIE = "__Host-campfire_oidc_browser"
  FLOW_LIFETIME = 10.minutes
  POLICY_UNAVAILABLE_MESSAGE = "Security policy is temporarily unavailable"
  class ConfigurationError < StandardError; end
  class EndpointError < StandardError; end
  class PolicyUnavailable < StandardError; end

  class Configuration
    MODES = %w[ disabled optional required ].freeze
    SIGNING_ALGORITHMS = %w[ RS256 ].freeze
    CLIENT_AUTH_METHODS = %w[ basic ].freeze
    THRUSTER_TRUE_VALUES = %w[ 1 t T TRUE true True ].freeze
    THRUSTER_FALSE_VALUES = %w[ 0 f F FALSE false False ].freeze
    DEFAULT_SESSION_LIFETIME = 12.hours.to_i
    MINIMUM_SESSION_LIFETIME = 5.minutes.to_i
    MAXIMUM_SESSION_LIFETIME = 30.days.to_i

    attr_reader :mode, :issuer, :client_id, :client_secret, :redirect_uri,
      :provider_name, :signing_algorithm, :client_auth_method,
      :session_lifetime_seconds, :break_glass_email, :allowed_hosts, :trusted_proxy_ranges,
      :tls_domains, :https_port

    def initialize(env = ENV)
      @mode = env.fetch("OIDC_MODE", "disabled").to_s.downcase
      validate_inclusion! "OIDC_MODE", mode, MODES
      return set_disabled_defaults unless enabled?

      @issuer = required_value(env, "OIDC_ISSUER")
      @client_id = required_value(env, "OIDC_CLIENT_ID")
      @client_secret = required_value(env, "OIDC_CLIENT_SECRET")
      @redirect_uri = required_value(env, "OIDC_REDIRECT_URI")
      @provider_name = env.fetch("OIDC_PROVIDER_NAME", "Single Sign-On").to_s.strip.presence || "Single Sign-On"
      @signing_algorithm = env.fetch("OIDC_SIGNING_ALGORITHM", "RS256").to_s.upcase
      @client_auth_method = env.fetch("OIDC_CLIENT_AUTH_METHOD", "basic").to_s.downcase
      @session_lifetime_seconds = integer_value(env, "OIDC_SESSION_LIFETIME", DEFAULT_SESSION_LIFETIME)
      @jit_provisioning = boolean_value(env, "OIDC_JIT_PROVISIONING", false)
      @allow_private_network = boolean_value(env, "OIDC_ALLOW_PRIVATE_NETWORK", false)
      @proxy_required = env["DISABLE_SSL"].present?
      @break_glass_email = EmailAddress.normalize(env["OIDC_BREAK_GLASS_EMAIL"].to_s).presence
      @fingerprint_key = env["SECRET_KEY_BASE"].presence || Rails.application.secret_key_base

      issuer_uri = https_url!("OIDC_ISSUER", issuer)
      redirect_uri = https_url!("OIDC_REDIRECT_URI", self.redirect_uri)

      raise ConfigurationError, "OIDC_ISSUER cannot include a query or fragment" if issuer_uri.query || issuer_uri.fragment
      raise ConfigurationError, "OIDC_ISSUER cannot exceed 255 bytes" if issuer.bytesize > 255
      unless redirect_uri.path == "/auth/openid_connect/callback" && !redirect_uri.query && !redirect_uri.fragment
        raise ConfigurationError, "OIDC_REDIRECT_URI must end with /auth/openid_connect/callback and cannot include a query or fragment"
      end
      tls_domain_value = proxy_required? ? env.fetch("TLS_DOMAIN", "") : effective_thruster_setting(env, "TLS_DOMAIN", "").last
      @tls_domains = tls_domain_value.split(",").filter_map { canonical_host(_1) }.uniq.freeze
      @https_port = integer_value(env, "HTTPS_PORT", 443, thruster: !proxy_required?)
      unless https_port.between?(1, 65_535)
        raise ConfigurationError, "HTTPS_PORT must be between 1 and 65535"
      end
      unless redirect_uri.host.downcase.in?(tls_domains)
        raise ConfigurationError, "OIDC_REDIRECT_URI host must be included in TLS_DOMAIN"
      end
      if redirect_uri.port != https_port
        raise ConfigurationError, "OIDC_REDIRECT_URI port must match HTTPS_PORT"
      end
      if !proxy_required? && https_port != 443
        raise ConfigurationError, "built-in Thruster TLS requires HTTPS_PORT=443 when OIDC is enabled"
      end
      if !proxy_required? && forwarded_headers_enabled?(env)
        raise ConfigurationError, "FORWARD_HEADERS cannot be enabled when Thruster terminates OIDC TLS"
      end

      validate_inclusion! "OIDC_SIGNING_ALGORITHM", signing_algorithm, SIGNING_ALGORITHMS
      validate_inclusion! "OIDC_CLIENT_AUTH_METHOD", client_auth_method, CLIENT_AUTH_METHODS
      validate_session_lifetime!
      validate_break_glass_email!

      configured_hosts = env.fetch("OIDC_ALLOWED_HOSTS", "").split(/[\s,]+/)
      @allowed_hosts = ([ issuer_uri.host ] + configured_hosts).filter_map { canonical_host(_1) }.uniq.freeze
      @trusted_proxy_ranges = env.fetch("OIDC_TRUSTED_PROXY_CIDRS", "").split(/\s*,\s*|\s+/).filter_map do |range|
        IPAddr.new(range) if range.present?
      rescue IPAddr::InvalidAddressError
        raise ConfigurationError, "OIDC_TRUSTED_PROXY_CIDRS contains an invalid network"
      end.freeze
      if proxy_required? && trusted_proxy_ranges.empty?
        raise ConfigurationError, "OIDC_TRUSTED_PROXY_CIDRS is required when OIDC uses DISABLE_SSL"
      end
      if !proxy_required? && trusted_proxy_ranges.any?
        raise ConfigurationError, "OIDC_TRUSTED_PROXY_CIDRS requires DISABLE_SSL"
      end
    end

    def enabled?
      mode != "disabled"
    end

    def required?
      mode == "required"
    end

    def jit_provisioning?
      @jit_provisioning
    end

    def allow_private_network?
      @allow_private_network
    end

    def break_glass_configured?
      break_glass_email.present?
    end

    def proxy_required?
      @proxy_required
    end

    def trusted_proxy?(address)
      trusted_proxy_ranges.any? { _1.include?(IPAddr.new(address.to_s)) }
    rescue IPAddr::InvalidAddressError
      false
    end

    def redirect_host
      URI(redirect_uri).host.downcase
    end

    def redirect_port
      URI(redirect_uri).port
    end

    def canonical_origin
      uri = URI(redirect_uri)
      "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.port == uri.default_port}"
    end

    def canonical_authority
      canonical_origin.delete_prefix("https://")
    end

    def fingerprint
      canonical_proxy_ranges = trusted_proxy_ranges.map do |range|
        bounds = range.to_range
        [ bounds.begin.to_s, bounds.end.to_s ]
      end.sort

      payload = [
        issuer, client_id, client_secret, redirect_uri, signing_algorithm, client_auth_method,
        session_lifetime_seconds, break_glass_email, allowed_hosts.sort,
        canonical_proxy_ranges, tls_domains.sort, https_port, proxy_required?,
        jit_provisioning?, allow_private_network?
      ]
      OpenSSL::HMAC.hexdigest "SHA256", @fingerprint_key, JSON.generate(payload)
    end

    def provider_fingerprint
      Digest::SHA256.hexdigest [ issuer, client_id ].join("\0")
    end

    private
      def set_disabled_defaults
        @session_lifetime_seconds = DEFAULT_SESSION_LIFETIME
        @jit_provisioning = false
        @allow_private_network = false
        @proxy_required = false
        @trusted_proxy_ranges = [].freeze
        @tls_domains = [].freeze
        @https_port = 443
        @allowed_hosts = [].freeze
      end

      def required_value(env, key)
        env[key].to_s.strip.presence || raise(ConfigurationError, "#{key} is required when OIDC_MODE is #{mode}")
      end

      def boolean_value(env, key, default)
        return default unless env.key?(key)

        case env[key].to_s.downcase
        when "true" then true
        when "false" then false
        else raise ConfigurationError, "#{key} must be true or false"
        end
      end

      def integer_value(env, key, default, thruster: false)
        source_key, value = thruster ? effective_thruster_setting(env, key, default) : [ key, env.fetch(key, default) ]
        Integer(value.to_s, 10)
      rescue ArgumentError, TypeError
        raise ConfigurationError, "#{source_key} must be an integer number of seconds"
      end

      def https_url!(key, value)
        URI.parse(value).tap do |uri|
          unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?
            raise ConfigurationError, "#{key} must be an absolute HTTPS URL without user information"
          end
        end
      rescue URI::InvalidURIError
        raise ConfigurationError, "#{key} must be a valid URL"
      end

      def validate_inclusion!(key, value, allowed_values)
        return if value.in?(allowed_values)

        raise ConfigurationError, "#{key} must be one of: #{allowed_values.join(', ')}"
      end

      def validate_session_lifetime!
        return if session_lifetime_seconds.between?(MINIMUM_SESSION_LIFETIME, MAXIMUM_SESSION_LIFETIME)

        raise ConfigurationError, "OIDC_SESSION_LIFETIME must be between #{MINIMUM_SESSION_LIFETIME} and #{MAXIMUM_SESSION_LIFETIME} seconds"
      end

      def validate_break_glass_email!
        return if break_glass_email.blank? || break_glass_email.match?(URI::MailTo::EMAIL_REGEXP)

        raise ConfigurationError, "OIDC_BREAK_GLASS_EMAIL must be a valid email address"
      end

      def forwarded_headers_enabled?(env)
        key, value = effective_thruster_setting(env, "FORWARD_HEADERS", "false")
        return true if value.to_s.in?(THRUSTER_TRUE_VALUES)
        return false if value.to_s.in?(THRUSTER_FALSE_VALUES)

        raise ConfigurationError, "#{key} must be a boolean understood by Thruster"
      end

      def effective_thruster_setting(env, key, default)
        prefixed_key = "THRUSTER_#{key}"
        env.key?(prefixed_key) ? [ prefixed_key, env[prefixed_key] ] : [ key, env.fetch(key, default) ]
      end

      def canonical_host(host)
        host.to_s.strip.downcase.delete_suffix(".").presence
      end
  end

  class << self
    attr_accessor :configuration

    delegate :mode, :issuer, :client_id, :client_secret, :redirect_uri,
      :provider_name, :signing_algorithm, :client_auth_method,
      :session_lifetime_seconds, :allowed_hosts, :provider_fingerprint, :trusted_proxy_ranges,
      :proxy_required?, to: :configuration
    delegate :enabled?, :required?, :jit_provisioning?, :allow_private_network?,
      :break_glass_configured?, to: :configuration

    def trusted_proxy?(address)
      configuration.trusted_proxy? address
    end

    def break_glass?(user)
      user && break_glass_user&.id == user.id
    end

    def break_glass_user
      account = Account.first
      if account&.oidc_break_glass_user_id?
        user = account.oidc_break_glass_user
        return user if user&.active? && user.administrator?
        return
      end

      configured_break_glass_user
    rescue ActiveRecord::ActiveRecordError => error
      raise PolicyUnavailable.new(POLICY_UNAVAILABLE_MESSAGE), cause: error
    end

    def configured_break_glass_user
      return unless configuration.break_glass_configured?

      User.active.where(role: :administrator)
        .where(
          email_address: configuration.break_glass_email,
          normalized_email_address: configuration.break_glass_email
        ).sole
    rescue ActiveRecord::RecordNotFound, ActiveRecord::SoleRecordExceeded
      nil
    end

    def local_authentication_allowed_for?(user)
      !rollback_prepared? && (!required? || break_glass?(user))
    end

    def rollback_prepared?
      read_account_policy(:oidc_transition_state) do
        Account.where(oidc_transition_state: "rollback_prepared").exists?
      end
    end

    def required_active?
      required? && read_account_policy(
        :oidc_configuration_fingerprint, :oidc_transition_state, :oidc_required_at
      ) do
        Account.where(
          oidc_configuration_fingerprint: configuration.fingerprint,
          oidc_transition_state: nil
        ).where.not(oidc_required_at: nil).exists?
      end
    end

    def current_identity?(identity)
      enabled? && identity&.issuer == issuer && identity.provider_fingerprint == provider_fingerprint
    end

    def flow_in_progress?(session)
      session[FLOW_STARTED_AT_SESSION_KEY].to_i > FLOW_LIFETIME.ago.to_i
    end

    def ensure_browser_binding!(cookies)
      cookies[BROWSER_COOKIE].presence || SecureRandom.urlsafe_base64(32).tap do |token|
        cookies[BROWSER_COOKIE] = { value: token, httponly: true, same_site: :lax, secure: true, path: "/" }
      end
    end

    def validate_endpoint!(value, hosts: allowed_hosts)
      URI.parse(value.to_s).tap do |uri|
        host = uri.host.to_s.downcase.delete_suffix(".")
        unless uri.is_a?(URI::HTTPS) && host.in?(hosts) && uri.userinfo.nil? && uri.fragment.nil?
          raise EndpointError, "OIDC endpoint must use HTTPS and an allowlisted host"
        end
      end
    rescue URI::InvalidURIError
      raise EndpointError, "OIDC endpoint is invalid"
    end

    private
      def read_account_policy(*columns)
        return false unless Account.table_exists?
        return false unless columns.all? { Account.column_names.include?(_1.to_s) }

        yield
      rescue ActiveRecord::ActiveRecordError => error
        raise PolicyUnavailable.new(POLICY_UNAVAILABLE_MESSAGE), cause: error
      end
  end
end
