require "concurrent"
require "digest"

module Oidc
  class RequestGuard
    AUTHENTICATION_PATHS = %w[ /auth/openid_connect /auth/openid_connect/callback ].freeze
    BACK_CHANNEL_LOGOUT_PATH = "/auth/openid_connect/backchannel_logout"
    HEALTH_PATHS = %w[ /up /up/oidc /up/scim ].freeze
    REQUEST_LIMIT = 10
    IP_REQUEST_LIMIT = 60
    REQUEST_WINDOW = 3.minutes
    MAXIMUM_CONCURRENT_REQUESTS = 4

    def initialize(app, store: Rails.cache, semaphore: Concurrent::Semaphore.new(MAXIMUM_CONCURRENT_REQUESTS))
      @app = app
      @store = store
      @semaphore = semaphore
    end

    def call(env)
      request = ActionDispatch::Request.new(env)
      return canonical_origin_response(request) unless canonical_origin?(request)
      recognized_path = recognized_security_path(request.path)
      return response(:not_found, "Not found") if recognized_path && request.path != recognized_path
      authentication_path = recognized_authentication_path(request.path)
      if Oidc.rollback_prepared? && !request.path.in?(HEALTH_PATHS)
        return response(:service_unavailable, "Campfire is prepared for rollback")
      end
      if Oidc.required? && !Activation.ready? && !self.class.maintenance_request?(request)
        return response(:service_unavailable, "OIDC required mode is not ready")
      end
      install_canonical_authority!(env) if Oidc.proxy_required? && !request.path.in?(HEALTH_PATHS)
      return @app.call(env) unless authentication_path
      return response(:too_many_requests, "Too many requests") if Ban.banned?(request.remote_ip)
      return response(:too_many_requests, "Too many requests") if rate_limited?(request)
      return response(:service_unavailable, "Single sign-on is temporarily busy") unless @semaphore.try_acquire

      begin
        @app.call(env)
      ensure
        @semaphore.release
      end
    rescue Oidc::PolicyUnavailable
      response(:service_unavailable, Oidc::POLICY_UNAVAILABLE_MESSAGE)
    end

    private
      def canonical_origin?(request)
        request.path.in?(HEALTH_PATHS) ||
          (trusted_transport?(request) && request.host == Oidc.configuration.redirect_host &&
            public_port(request) == Oidc.configuration.redirect_port)
      end

      def trusted_transport?(request)
        if Oidc.proxy_required?
          request.get_header("HTTP_X_FORWARDED_PROTO") == "https" &&
            Oidc.trusted_proxy?(request.get_header("REMOTE_ADDR"))
        else
          request.ssl?
        end
      end

      def public_port(request)
        return request.port unless Oidc.configuration.proxy_required?

        value = request.get_header("HTTP_X_FORWARDED_PORT").presence
        return 443 unless value
        return unless value.match?(/\A\d+\z/)

        Integer(value, 10).presence_in(1..65_535)
      end

      def canonical_origin_response(request)
        if request.get? || request.head?
          [ 308, { "location" => "#{Oidc.configuration.canonical_origin}#{request.fullpath}", "content-type" => "text/plain" }, [] ]
        else
          response :misdirected_request, "Use the configured Campfire origin"
        end
      end

      def install_canonical_authority!(env)
        env["HTTP_HOST"] = Oidc.configuration.canonical_authority
        env["SERVER_NAME"] = Oidc.configuration.redirect_host
        env["SERVER_PORT"] = Oidc.configuration.redirect_port.to_s
        env.delete("HTTP_X_FORWARDED_HOST")
      end

      def rate_limited?(request)
        path = recognized_authentication_path(request.path)
        session_cookie = request.cookies.fetch("_campfire_session", "")
        client = Digest::SHA256.hexdigest(session_cookie).first(16)
        client_count = increment_rate_limit!(
          [ "oidc-request", path, request.remote_ip, client ].join(":"), 1, expires_in: REQUEST_WINDOW
        )
        return true if client_count > REQUEST_LIMIT

        ip_count = increment_rate_limit!(
          [ "oidc-request-ip", path, request.remote_ip ].join(":"), 1, expires_in: REQUEST_WINDOW
        )
        ip_count > IP_REQUEST_LIMIT
      end

      def increment_rate_limit!(*arguments, **options)
        count = @store.increment(*arguments, **options)
        return count if count.is_a?(Integer)

        raise Oidc::PolicyUnavailable, Oidc::POLICY_UNAVAILABLE_MESSAGE
      rescue Oidc::PolicyUnavailable
        raise
      rescue StandardError => error
        raise Oidc::PolicyUnavailable.new(Oidc::POLICY_UNAVAILABLE_MESSAGE), cause: error
      end

      def response(status, body)
        [ Rack::Utils.status_code(status), { "content-type" => "text/plain", "content-length" => body.bytesize.to_s }, [ body ] ]
      end


      def recognized_authentication_path(path)
        normalized_path = path.downcase.sub(%r{/$}, "")
        normalized_path if normalized_path.in?(AUTHENTICATION_PATHS)
      end

      def recognized_security_path(path)
        normalized_path = path.downcase.sub(%r{/$}, "")
        normalized_path if normalized_path.in?(AUTHENTICATION_PATHS) || normalized_path == BACK_CHANNEL_LOGOUT_PATH
      end

      class << self
        def maintenance_request?(request)
          return true if request.path.in?(HEALTH_PATHS)

          case [ request.request_method, request.path ]
          when [ "GET", "/session/new" ], [ "POST", "/session" ],
              [ "POST", "/auth/openid_connect" ], [ "GET", "/auth/openid_connect/callback" ],
              [ "POST", "/auth/openid_connect/backchannel_logout" ],
              [ "GET", "/auth/failure" ], [ "GET", "/oidc_flow" ], [ "DELETE", "/oidc_flow" ]
            true
          else
            request.path.start_with?("/scim/v2/")
          end
        end
      end
  end
end
