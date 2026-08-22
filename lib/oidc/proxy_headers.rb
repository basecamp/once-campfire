require "ipaddr"

module Oidc
  class ProxyHeaders
    HEALTH_PATHS = Oidc::HEALTH_PATHS
    THRUSTER_PROXY_RANGES = %w[ 127.0.0.1/32 ::1/128 ].map { IPAddr.new(_1).freeze }.freeze
    UNTRUSTED_FORWARDED_HEADERS = %w[
      HTTP_CLIENT_IP
      HTTP_FORWARDED
      HTTP_X_FORWARDED_FOR
      HTTP_X_FORWARDED_HOST
      HTTP_X_FORWARDED_PORT
      HTTP_X_FORWARDED_PROTO
    ].freeze
    UNSUPPORTED_ATTRIBUTION_HEADERS = %w[ HTTP_CLIENT_IP HTTP_FORWARDED HTTP_X_FORWARDED_HOST ].freeze
    SECURITY_PATHS = %w[
      /auth/openid_connect
      /auth/openid_connect/callback
      /auth/openid_connect/backchannel_logout
    ].freeze
    SCIM_PATH_PREFIX = "/scim/v2"
    INVALID_ATTRIBUTION_BODY = "A trusted proxy must supply a valid client address"

    class << self
      def attribution_proxy_ranges
        Oidc.proxy_required? ? Oidc.trusted_proxy_ranges : THRUSTER_PROXY_RANGES
      end
    end

    def initialize(app, trusted_proxy_ranges:, allow_proxy_chain: true)
      @app = app
      @trusted_proxy_ranges = trusted_proxy_ranges
      @allow_proxy_chain = allow_proxy_chain
    end

    def call(env)
      env = env.dup
      if trusted_proxy?(env["REMOTE_ADDR"])
        UNSUPPORTED_ATTRIBUTION_HEADERS.each { env.delete(_1) }
        return invalid_attribution_response(env) unless health_request?(env) || valid_forwarded_chain?(env)
      else
        UNTRUSTED_FORWARDED_HEADERS.each { env.delete(_1) }
      end

      @app.call(env)
    end

    private
      def trusted_proxy?(address)
        @trusted_proxy_ranges.any? { _1.include?(IPAddr.new(address.to_s)) }
      rescue IPAddr::InvalidAddressError
        false
      end

      def valid_forwarded_chain?(env)
        addresses = env["HTTP_X_FORWARDED_FOR"].to_s.split(/[\s,]+/)
        client, *proxy_hops = addresses
        valid_proxy_hops = @allow_proxy_chain ? proxy_hops.all? { trusted_proxy?(_1) } : proxy_hops.empty?
        valid = client.present? && addresses.all? { valid_address?(_1) } &&
          !trusted_proxy?(client) && valid_proxy_hops
        env["HTTP_X_FORWARDED_FOR"] = addresses.join(", ") if valid
        valid
      end

      def valid_address?(address)
        range = IPAddr.new(address).to_range
        range.begin == range.end
      rescue IPAddr::InvalidAddressError
        false
      end

      def health_request?(env)
        env["REQUEST_METHOD"].in?(%w[ GET HEAD ]) && env["PATH_INFO"].in?(HEALTH_PATHS)
      end

      def invalid_attribution_response(env)
        headers = {
          "content-type" => "text/plain",
          "content-length" => INVALID_ATTRIBUTION_BODY.bytesize.to_s
        }
        headers["cache-control"] = "no-store" if security_endpoint?(env["PATH_INFO"])
        [ 421, Oidc.security_headers(headers), [ INVALID_ATTRIBUTION_BODY ] ]
      end

      def security_endpoint?(path)
        normalized = path.to_s.downcase.delete_suffix("/")
        normalized.in?(SECURITY_PATHS) || normalized == SCIM_PATH_PREFIX ||
          normalized.start_with?("#{SCIM_PATH_PREFIX}/")
      end
  end
end
