require "resolv"
require "restricted_http/private_network_guard"
require "timeout"
require "uri"

module WebPush
  module Endpoint
    extend self

    class Denied < StandardError; end
    class Unavailable < StandardError; end

    MAXIMUM_LENGTH = 2048
    RESOLUTION_TIMEOUT = 5.seconds

    def parse(value)
      string = value.to_s
      raise Denied, "Web Push endpoint is too long" if string.bytesize > MAXIMUM_LENGTH

      URI.parse(string).tap do |uri|
        unless uri.is_a?(URI::HTTPS) && uri.hostname.present? && uri.port == 443 &&
            uri.userinfo.nil? && uri.fragment.nil?
          raise Denied, "Web Push endpoint must be a public HTTPS URL on port 443"
        end
        if ip_address?(uri.hostname) && RestrictedHTTP::PrivateNetworkGuard.private_ip?(uri.hostname)
          raise Denied, "Web Push endpoint must not use a private or special-use address"
        end
      end
    rescue URI::InvalidURIError
      raise Denied, "Web Push endpoint is invalid"
    end

    def resolve(value)
      uri = parse(value)
      addresses = Timeout.timeout(RESOLUTION_TIMEOUT) { Resolv.getaddresses(uri.hostname) }
      raise Unavailable, "Web Push endpoint could not be resolved" if addresses.empty?
      if addresses.any? { RestrictedHTTP::PrivateNetworkGuard.private_ip?(_1) }
        raise Denied, "Web Push endpoint resolved to a private or invalid address"
      end

      [ uri, addresses.first ]
    rescue Resolv::ResolvError, SocketError, Timeout::Error
      raise Unavailable, "Web Push endpoint could not be resolved"
    end

    private
      def ip_address?(host)
        IPAddr.new(host)
        true
      rescue IPAddr::InvalidAddressError
        false
      end
  end
end
