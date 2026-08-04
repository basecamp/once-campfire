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
      if authentication_path && !authentication_method_allowed?(request, authentication_path)
        return method_not_allowed_response(authentication_path)
      end
      if Oidc.rollback_prepared? && !request.path.in?(HEALTH_PATHS)
        return response(:service_unavailable, "Campfire is prepared for rollback")
      end
      if Oidc.required? && !Activation.ready? && !self.class.maintenance_request?(request)
        return required_mode_not_ready_response(request)
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
        return true if request.path.in?(HEALTH_PATHS)

        external_port = public_port(request)
        host_port = explicit_host_port(request)
        trusted_transport?(request) && request.host == Oidc.configuration.redirect_host &&
          external_port == Oidc.configuration.redirect_port && host_port != :invalid &&
          (!host_port || host_port == external_port)
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

      def explicit_host_port(request)
        authority = request.get_header("HTTP_HOST").to_s
        return if authority.blank?

        if authority.start_with?("[")
          match = authority.match(/\A\[[^\]]+\](?::(\d+))?\z/)
          return :invalid unless match
          return Integer(match[1], 10) if match[1]

          return
        end

        return :invalid if authority.count(":") > 1

        host, separator, port = authority.rpartition(":")
        return if separator.empty?
        return :invalid if host.empty? || !port.match?(/\A\d+\z/)

        Integer(port, 10)
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

      def required_mode_not_ready_response(request)
        accept = request.get_header("HTTP_ACCEPT").to_s
        html_ranges = accept.split(",").filter_map do |entry|
          type, *parameters = entry.split(";")
          specificity = { "text/html" => 2, "text/*" => 1, "*/*" => 0 }[type.strip.downcase]
          next unless specificity

          quality_parameter = parameters.find { _1.strip.match?(/\Aq\s*=/i) }
          quality = quality_parameter ? Float(quality_parameter.split("=", 2).last) : 1.0
          [ specificity, quality ] if quality.between?(0.0, 1.0)
        rescue ArgumentError
          nil
        end
        highest_specificity = html_ranges.map(&:first).max
        accepts_html = accept.blank? || (highest_specificity && html_ranges
          .select { _1.first == highest_specificity }
          .map(&:last).max.positive?)
        unless (request.get? || request.head?) && accepts_html
          return response(:service_unavailable, "OIDC required mode is not ready")
        end

        body = <<~HTML
          <!doctype html>
          <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>Single sign-on setup in progress</title>
            </head>
            <body>
              <main>
                <h1>Single sign-on setup in progress</h1>
                <p>Campfire is waiting for account verification before required single sign-on can be activated.</p>
                <p><a href="/session/new">Continue to single sign-on</a></p>
              </main>
            </body>
          </html>
        HTML
        [
          Rack::Utils.status_code(:service_unavailable),
          {
            "cache-control" => "no-store",
            "content-type" => "text/html; charset=utf-8",
            "content-length" => body.bytesize.to_s
          },
          request.head? ? [] : [ body ]
        ]
      end

      def authentication_method_allowed?(request, path)
        path == AUTHENTICATION_PATHS.first ? request.post? : request.get?
      end

      def method_not_allowed_response(path)
        response(:method_not_allowed, "Method not allowed").tap do |_, headers, _|
          headers["allow"] = path == AUTHENTICATION_PATHS.first ? "POST" : "GET"
        end
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
