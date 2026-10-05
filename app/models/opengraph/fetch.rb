require "net/http"
require "restricted_http/private_network_guard"

class Opengraph::Fetch
  ALLOWED_DOCUMENT_CONTENT_TYPE = "text/html"
  MAX_BODY_SIZE = 5.megabytes
  MAX_REDIRECTS = 10
  TIMEOUT = 7.seconds   # to connect (TLS included), and for each read and write, as Webhook does
  DEADLINE = 10.seconds # for the whole fetch: redirects, headers and body

  class TooManyRedirectsError < StandardError; end
  class RedirectDeniedError < StandardError; end

  def fetch_document(url, ip: RestrictedHTTP::PrivateNetworkGuard.resolve(url.host))
    request(url, Net::HTTP::Get, ip: ip) do |response|
      return body_if_acceptable(response)
    end
  end

  def fetch_content_type(url, ip: RestrictedHTTP::PrivateNetworkGuard.resolve(url.host))
    request(url, Net::HTTP::Head, ip: ip) do |response|
      return response["Content-Type"]
    end
  end

  private
    # A member triggers this from a web request, and the host on the other end decides how fast it answers.
    # The timeouts bound each operation, but Net::HTTP reads headers and body in as many reads as the host
    # likes, so only a deadline over the whole fetch stops one that sends a byte at a time.
    def request(url, request_class, ip:)
      Timeout.timeout(DEADLINE) do
        MAX_REDIRECTS.times do
          Net::HTTP.start(url.host, url.port, ipaddr: ip, use_ssl: url.scheme == "https", **timeouts) do |http|
            http.request request_class.new(url) do |response|
              if response.is_a?(Net::HTTPRedirection)
                url, ip = resolve_redirect(response["location"])
              else
                yield response
              end
            end
          end
        end

        raise TooManyRedirectsError
      end
    end

    # Without max_retries: 0, Net::HTTP sends a GET or HEAD that timed out a second time.
    def timeouts
      { open_timeout: TIMEOUT, read_timeout: TIMEOUT, write_timeout: TIMEOUT, max_retries: 0 }
    end

    def resolve_redirect(location)
      url = URI.parse(location)
      raise RedirectDeniedError unless url.is_a?(URI::HTTP)
      [ url, RestrictedHTTP::PrivateNetworkGuard.resolve(url.host) ]
    end

    def body_if_acceptable(response)
      size_restricted_body(response) if response_valid?(response)
    end

    def size_restricted_body(response)
      # We've already checked the Content-Length header, to try to avoid reading
      # the body of any large responses. But that header could be wrong or
      # missing. To be on the safe side, we'll read the body in chunks, and bail
      # if it runs over our size limit.
      StringIO.new.tap do |body|
        response.read_body do |chunk|
          return nil if body.string.bytesize + chunk.bytesize > MAX_BODY_SIZE
          body << chunk
        end
      end.string
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
      response.content_length.to_i <= MAX_BODY_SIZE
    end
end
