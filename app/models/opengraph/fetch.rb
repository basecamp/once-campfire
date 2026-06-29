require "net/http"
require "restricted_http/private_network_guard"

class Opengraph::Fetch
  ALLOWED_DOCUMENT_CONTENT_TYPE = "text/html"
  MAX_BODY_SIZE = 5.megabytes
  MAX_REDIRECTS = 10

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
    def request(url, request_class, ip:)
      MAX_REDIRECTS.times do
        begin
          Net::HTTP.start(url.host, url.port, ipaddr: ip, use_ssl: url.scheme == "https") do |http|
            http.request request_class.new(url) do |response|
              if response.is_a?(Net::HTTPRedirection)
                url, ip = resolve_redirect(response["location"])
              else
                yield response
              end
            end
          end
        rescue => e
          Rails.logger.warn "Failed to fetch #{url} at #{ip} (#{e})"
          # Try without specifying IP if the first attempt fails
          if ip
            begin
              Net::HTTP.start(url.host, url.port, use_ssl: url.scheme == "https") do |http|
                http.request request_class.new(url) do |response|
                  if response.is_a?(Net::HTTPRedirection)
                    url, ip = resolve_redirect(response["location"])
                  else
                    yield response
                  end
                end
              end
            rescue => e2
              Rails.logger.warn "Failed to fetch #{url} without IP (#{e2})"
              raise e2
            end
          else
            raise e
          end
        end
      end

      raise TooManyRedirectsError
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
