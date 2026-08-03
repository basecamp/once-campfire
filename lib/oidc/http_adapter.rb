require "faraday/adapter/net_http"
require "resolv"
require "restricted_http/private_network_guard"
require "restricted_http/response_header_guard"
require "timeout"

module Oidc
  class HTTPAdapter < Faraday::Adapter::NetHttp
    class Denied < StandardError; end
    MAXIMUM_RESPONSE_SIZE = 1.megabyte
    MAXIMUM_REQUEST_TIME = 15.seconds

    def initialize(app = nil, allowed_hosts:, allow_private_network:)
      super(app)
      @allowed_hosts = allowed_hosts
      @allow_private_network = allow_private_network
    end

    private
      def perform_request(http, environment)
        RestrictedHTTP::ResponseHeaderGuard.with_limits do
          Timeout.timeout(remaining_time(environment)) do
            return super if environment.stream_response?

            body = +"".b
            http.start do |opened_http|
              opened_http.request create_request(environment) do |response|
                save_http_response environment, response
                response.read_body do |chunk|
                  if body.bytesize + chunk.bytesize > MAXIMUM_RESPONSE_SIZE
                    raise Denied, "OIDC response exceeded #{MAXIMUM_RESPONSE_SIZE} bytes"
                  end
                  body << chunk
                end
              end
            end

            environment.response_body = body
            environment.response.finish(environment)
          end
        end
      rescue RestrictedHTTP::ResponseHeaderGuard::Exceeded => error
        raise Denied.new("OIDC response headers exceeded safety limits"), cause: error
      rescue Timeout::Error
        raise Denied, "OIDC request exceeded #{MAXIMUM_REQUEST_TIME.to_i} seconds"
      end

      def net_http_connection(environment)
        url = Oidc.validate_endpoint!(environment[:url], hosts: @allowed_hosts)
        addresses = Timeout.timeout(remaining_time(environment)) { Resolv.getaddresses(url.host) }

        if addresses.empty? || (!@allow_private_network && addresses.any? { RestrictedHTTP::PrivateNetworkGuard.private_ip?(_1) })
          raise Denied, "OIDC endpoint resolved to a private or invalid address"
        end

        Net::HTTP.new(url.host, url.port, nil).tap { _1.ipaddr = addresses.first }
      rescue Resolv::ResolvError, SocketError, Timeout::Error
        raise Denied, "OIDC endpoint could not be resolved"
      end

      def remaining_time(environment)
        deadline = environment.instance_variable_get(:@oidc_request_deadline)
        unless deadline
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + MAXIMUM_REQUEST_TIME
          environment.instance_variable_set(:@oidc_request_deadline, deadline)
        end

        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Timeout::Error if remaining <= 0

        remaining
      end
  end
end
