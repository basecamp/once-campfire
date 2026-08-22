require "net/http"
require "resolv"
require "restricted_http/private_network_guard"
require "restricted_http/response_header_guard"
require "timeout"

class Opengraph::Fetch
  ALLOWED_DOCUMENT_CONTENT_TYPE = "text/html"
  MAX_BODY_SIZE = 5.megabytes
  MAX_REDIRECTS = 10
  MAXIMUM_REQUEST_TIME = 10.seconds
  RESOLUTION_TIMEOUT = 3.seconds
  MAXIMUM_RESPONSE_HEADER_BYTES = RestrictedHTTP::ResponseHeaderGuard::MAXIMUM_TOTAL_BYTES

  class DeniedError < StandardError; end
  class RequestTimeoutError < DeniedError; end
  class TooManyRedirectsError < StandardError; end
  class RedirectDeniedError < StandardError; end

  def initialize(maximum_request_time: MAXIMUM_REQUEST_TIME)
    @maximum_request_time = maximum_request_time
  end

  def fetch_document(url)
    request(url, Net::HTTP::Get) do |response|
      return body_if_acceptable(response)
    end
  end

  def fetch_content_type(url)
    request(url, Net::HTTP::Head) do |response|
      return response["Content-Type"]
    end
  end

  def public_addresses(hostname)
    resolve_addresses hostname, deadline: deadline
  end

  private
    def request(url, request_class)
      request_deadline = deadline
      redirects = 0

      loop do
        address = resolve_addresses(url.hostname, deadline: request_deadline).first
        Timeout.timeout(remaining_time(request_deadline), RequestTimeoutError) do
          RestrictedHTTP::ResponseHeaderGuard.with_limits do
            http_for(url, address, deadline: request_deadline).request(request_class.new(url)) do |response|
              verify_response_headers! response

              if response.is_a?(Net::HTTPRedirection)
                raise TooManyRedirectsError if redirects >= MAX_REDIRECTS

                url = resolve_redirect(response["location"], from: url)
                redirects += 1
              else
                yield response
                return
              end
            end
          end
        end
      end
    rescue RestrictedHTTP::ResponseHeaderGuard::Exceeded => error
      raise DeniedError.new("Open Graph response headers exceeded safety limits"), cause: error
    rescue Timeout::Error
      raise RequestTimeoutError, "Open Graph request exceeded #{@maximum_request_time.to_f} seconds"
    end

    def resolve_redirect(location, from:)
      url = URI.join(from, location.to_s)
      raise RedirectDeniedError unless url.is_a?(URI::HTTP)

      url
    rescue URI::InvalidURIError
      raise RedirectDeniedError
    end

    def resolve_addresses(hostname, deadline:)
      remaining = remaining_time(deadline)
      addresses = Timeout.timeout([ RESOLUTION_TIMEOUT, remaining ].min, RequestTimeoutError) do
        Resolv.getaddresses hostname
      end
      if addresses.empty? || addresses.any? { RestrictedHTTP::PrivateNetworkGuard.private_ip?(_1) }
        raise RestrictedHTTP::Violation, "Attempt to access a private or unresolved address via #{hostname}"
      end

      addresses
    rescue Resolv::ResolvError, SocketError => error
      raise DeniedError.new("Open Graph endpoint could not be resolved"), cause: error
    end

    def http_for(url, address, deadline:)
      Net::HTTP.new(url.hostname, url.port, nil).tap do |http|
        http.ipaddr = address
        http.use_ssl = url.scheme == "https"
        http.max_retries = 0
        http.open_timeout = remaining_time(deadline)
        http.read_timeout = remaining_time(deadline)
        http.write_timeout = remaining_time(deadline)
      end
    end

    def deadline
      Process.clock_gettime(Process::CLOCK_MONOTONIC) + @maximum_request_time
    end

    def remaining_time(request_deadline)
      (request_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)).tap do |remaining|
        raise RequestTimeoutError, "Open Graph request exceeded #{@maximum_request_time.to_f} seconds" unless remaining.positive?
      end
    end

    def verify_response_headers!(response)
      bytes = response.each_header.sum { |name, value| name.bytesize + value.bytesize + 4 }
      if bytes > MAXIMUM_RESPONSE_HEADER_BYTES
        raise DeniedError, "Open Graph response headers exceeded safety limits"
      end
    end

    def body_if_acceptable(response)
      size_restricted_body(response) if response_valid?(response)
    end

    def size_restricted_body(response)
      # We've already checked the Content-Length header, to try to avoid reading
      # the body of any large responses. But that header could be wrong or
      # missing. To be on the safe side, we'll read the body in chunks, and bail
      # if it runs over our size limit.
      ContentLimits.read(response, maximum: MAX_BODY_SIZE, description: "Open Graph response")
    rescue ContentLimits::Exceeded
      nil
    end

    def response_valid?(response)
      status_valid?(response) && content_type_valid?(response) && content_length_valid?(response)
    end

    def status_valid?(response)
      response.is_a?(Net::HTTPOK)
    end

    def content_type_valid?(response)
      response.content_type == ALLOWED_DOCUMENT_CONTENT_TYPE
    end

    def content_length_valid?(response)
      return true unless response["Content-Length"]

      Integer(response["Content-Length"], 10).between?(0, MAX_BODY_SIZE)
    rescue ArgumentError
      false
    end
end
