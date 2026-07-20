require "resolv"

module RestrictedHTTP
  class Violation < StandardError; end

  module PrivateNetworkGuard
    extend self

    LOCAL_IP = IPAddr.new("0.0.0.0/8") # "This" network

    # IPv6 transition/encapsulation and shared-address ranges that can smuggle
    # requests toward internal networks and must never be reachable.
    DISALLOWED_RANGES = [
      IPAddr.new("64:ff9b::/96"),  # NAT64 (RFC 6052) — embeds IPv4 in IPv6
      IPAddr.new("2002::/16"),     # 6to4 (RFC 3056) — embeds IPv4 in IPv6
      IPAddr.new("100.64.0.0/10")  # CGNAT / shared address space (RFC 6598)
    ]

    def resolve(hostname)
      Resolv.getaddress(hostname).tap do |ip|
        raise Violation.new("Attempt to access private IP via #{hostname}") if ip && private_ip?(ip)
      end
    end

    def private_ip?(ip)
      IPAddr.new(ip).then do |ipaddr|
        ipaddr.private? || ipaddr.loopback? || ipaddr.link_local? || ipaddr.ipv4_mapped? || ipaddr.ipv4_compat? || LOCAL_IP.include?(ipaddr) || DISALLOWED_RANGES.any? { |range| range.include?(ipaddr) }
      end
    rescue IPAddr::InvalidAddressError
      true
    end
  end
end
