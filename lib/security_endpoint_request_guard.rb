require "concurrent"
require "oidc"
require "security_endpoint_rate_limiter"
require "stringio"

class SecurityEndpointRequestGuard
  LOGOUT_PATH = "/auth/openid_connect/backchannel_logout"
  SCIM_PATH_PREFIX = "/scim/v2"
  CANONICAL_PATHS = %w[
    /auth/openid_connect
    /auth/openid_connect/callback
    /auth/openid_connect/backchannel_logout
    /auth/failure
    /oidc_link
    /oidc_flow
    /scim/v2/ServiceProviderConfig
    /scim/v2/Users
    /up/oidc
    /up/scim
  ].freeze
  SCIM_USER_PATH = %r{\A/scim/v2/Users/([^/]+)\z}i
  LOGOUT_BODY_BYTES = 20.kilobytes
  SCIM_BODY_BYTES = 32.kilobytes
  LOGOUT_REQUEST_LIMIT = 120
  SCIM_REQUEST_LIMIT = 300
  REQUEST_WINDOW = 3.minutes
  LOGOUT_CONCURRENCY = 4
  SCIM_CONCURRENCY = 8
  Endpoint = Data.define(:name, :request_limit, :semaphore, :scim)

  class << self
    def canonical_security_path(path)
      candidate = path.to_s.delete_suffix("/")
      without_format = candidate.sub(/\.[^\/]*\z/, "")
      CANONICAL_PATHS.find do |canonical|
        canonical.casecmp?(candidate) || canonical.casecmp?(without_format)
      end || begin
        if match = candidate.match(SCIM_USER_PATH)
          id = match[1].sub(/\.[^\/]*\z/, "")
          "/scim/v2/Users/#{id}"
        end
      end
    end

    def noncanonical_security_path?(path)
      canonical = canonical_security_path(path)
      canonical && path.to_s != canonical
    end

    def not_found_response(head: false)
      body = "Not found"
      [
        Rack::Utils.status_code(:not_found),
        Oidc.security_headers(
          "cache-control" => "no-store",
          "content-length" => body.bytesize.to_s,
          "content-type" => "text/plain"
        ),
        head ? [] : [ body ]
      ]
    end
  end

  def initialize(app, store: Rails.cache,
      logout_semaphore: Concurrent::Semaphore.new(LOGOUT_CONCURRENCY),
      scim_semaphore: Concurrent::Semaphore.new(SCIM_CONCURRENCY))
    @app = app
    @store = store
    @logout = Endpoint.new(
      name: "oidc-backchannel-logout", request_limit: LOGOUT_REQUEST_LIMIT,
      semaphore: logout_semaphore, scim: false
    )
    @scim = Endpoint.new(
      name: "scim", request_limit: SCIM_REQUEST_LIMIT,
      semaphore: scim_semaphore, scim: true
    )
  end

  def call(env)
    restore_security_endpoint_method!(env)
    request = ActionDispatch::Request.new(env)
    if self.class.noncanonical_security_path?(request.path)
      return self.class.not_found_response(head: request.head?)
    end
    endpoint = endpoint_for(request.path)
    return @app.call(env) unless endpoint && endpoint_enabled?(endpoint)
    if SecurityEndpointRateLimiter.exceeded?(
      endpoint: endpoint.name, remote_ip: request.remote_ip,
      limit: endpoint.request_limit, window: REQUEST_WINDOW, store: @store
    )
      return error_response(endpoint, :too_many_requests, head: request.head?)
    end
    return error_response(endpoint, :service_unavailable, head: request.head?) unless endpoint.semaphore.try_acquire

    begin
      status, headers, body = @app.call(env)
      headers = headers.dup
      headers.delete("Cache-Control")
      headers["cache-control"] = "no-store"
      [ status, headers, body ]
    ensure
      endpoint.semaphore.release
    end
  rescue SecurityEndpointRateLimiter::Unavailable
    error_response(endpoint, :service_unavailable, head: request&.head?)
  end

  private
    def restore_security_endpoint_method!(env)
      original_method = env["rack.methodoverride.original_method"]
      if original_method && (endpoint_for(env["PATH_INFO"]) || oidc_authentication_path?(env["PATH_INFO"]))
        env["REQUEST_METHOD"] = original_method
      end
    end

    def oidc_authentication_path?(path)
      normalized = path.to_s.downcase.delete_suffix("/")
      normalized.in?([ SecurityEndpointBodyLimiter::OIDC_PATH, SecurityEndpointBodyLimiter::OIDC_CALLBACK_PATH ])
    end

    def endpoint_for(path)
      normalized = path.to_s.downcase.delete_suffix("/")
      return @logout if normalized == LOGOUT_PATH
      @scim if normalized == SCIM_PATH_PREFIX || normalized.start_with?("#{SCIM_PATH_PREFIX}/")
    end

    def endpoint_enabled?(endpoint)
      endpoint.scim ? Scim.enabled? : Oidc.enabled?
    end

    def error_response(endpoint, status, head: false)
      return plain_response(status) unless endpoint&.scim

      scim_response(status).tap { _1[2] = [] if head }
    end

    def plain_response(status)
      [
        Rack::Utils.status_code(status),
        Oidc.security_headers(
          "cache-control" => "no-store", "content-length" => "0", "content-type" => "text/plain"
        ),
        []
      ]
    end

    def scim_response(status)
      detail = case status
      when :content_too_large then "Request body is too large."
      when :too_many_requests then "Too many requests."
      when :bad_request then "The request is malformed."
      else "Service is unavailable."
      end
      body = ActiveSupport::JSON.encode(
        schemas: [ Scim::ERROR_SCHEMA ], status: Rack::Utils.status_code(status).to_s, detail:
      )
      [
        Rack::Utils.status_code(status),
        Oidc.security_headers(
          "cache-control" => "no-store", "content-length" => body.bytesize.to_s,
          "content-type" => Scim::MEDIA_TYPE
        ),
        [ body ]
      ]
    end
end

class SecurityEndpointBodyLimiter
  RAW_BODY_KEY = "campfire.security_endpoint_raw_body"
  OIDC_PATH = "/auth/openid_connect"
  OIDC_CALLBACK_PATH = "/auth/openid_connect/callback"
  OIDC_BODY_BYTES = 16.kilobytes

  def initialize(app)
    @app = app
  end

  def call(env)
    if SecurityEndpointRequestGuard.noncanonical_security_path?(env["PATH_INFO"])
      return SecurityEndpointRequestGuard.not_found_response(head: env["REQUEST_METHOD"] == "HEAD")
    end

    endpoint = endpoint_for(env["PATH_INFO"])
    return @app.call(env) unless endpoint
    if declared_body_too_large?(env, endpoint.fetch(:maximum))
      return request_error_response(env, endpoint, :content_too_large)
    end

    input = env["rack.input"] || StringIO.new("")
    body = read_body(input, endpoint.fetch(:maximum))
    return request_error_response(env, endpoint, :content_too_large) unless body

    env[RAW_BODY_KEY] = body
    env["rack.input"] = StringIO.new(body)
    @app.call(env)
  rescue IOError, SystemCallError
    request_error_response(env, endpoint, :bad_request)
  end

  private
    def endpoint_for(path)
      normalized = path.to_s.downcase.delete_suffix("/")
      if normalized == SecurityEndpointRequestGuard::LOGOUT_PATH
        { maximum: SecurityEndpointRequestGuard::LOGOUT_BODY_BYTES, scim: false }
      elsif normalized == SecurityEndpointRequestGuard::SCIM_PATH_PREFIX ||
          normalized.start_with?("#{SecurityEndpointRequestGuard::SCIM_PATH_PREFIX}/")
        { maximum: SecurityEndpointRequestGuard::SCIM_BODY_BYTES, scim: true }
      elsif normalized == OIDC_PATH
        { maximum: OIDC_BODY_BYTES, scim: false }
      elsif normalized == OIDC_CALLBACK_PATH
        { maximum: 0, scim: false }
      end
    end

    def declared_body_too_large?(env, maximum)
      value = env["CONTENT_LENGTH"]
      return false if value.blank?
      return true unless value.match?(/\A\d+\z/)

      Integer(value, 10) > maximum
    end

    def read_body(input, maximum)
      body = +"".b
      loop do
        chunk = input.read([ 16.kilobytes, maximum - body.bytesize + 1 ].min)
        break if chunk.nil? || chunk.empty?

        body << chunk
        return if body.bytesize > maximum
      end
      body
    end

    def error_response(endpoint, status)
      unless endpoint&.fetch(:scim, false)
        return [
          Rack::Utils.status_code(status),
          Oidc.security_headers(
            "cache-control" => "no-store", "content-length" => "0", "content-type" => "text/plain"
          ),
          []
        ]
      end

      detail = status == :content_too_large ? "Request body is too large." : "The request is malformed."
      body = ActiveSupport::JSON.encode(
        schemas: [ Scim::ERROR_SCHEMA ], status: Rack::Utils.status_code(status).to_s, detail:
      )
      [
        Rack::Utils.status_code(status),
        Oidc.security_headers(
          "cache-control" => "no-store", "content-length" => body.bytesize.to_s,
          "content-type" => Scim::MEDIA_TYPE
        ),
        [ body ]
      ]
    end

    def request_error_response(env, endpoint, status)
      response = error_response(endpoint, status)
      response[2] = [] if env["REQUEST_METHOD"] == "HEAD"
      response
    end
end
