require "resolv"

module RestrictedHTTP
  class Violation < StandardError; end

  module PrivateNetworkGuard
    extend self

    # IPv4 special-use ranges (RFC 5735/6890) not already covered by the
    # private?/loopback?/link_local? predicates in #disallowed_ipv4?.
    DISALLOWED_IPV4 = %w[
      0.0.0.0/8 100.64.0.0/10 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24
      198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    # IPv6 special-use ranges not caught by the predicates. 6to4 (2002::/16) and
    # Teredo (2001::/32) are deprecated transition mechanisms with no legitimate
    # fetch target, so they are blocked outright. ULA (fc00::/7, incl. the AWS
    # IMDSv6 address fd00:ec2::254), link-local, and loopback are covered by the
    # predicates in #disallowed_ipv6?.
    DISALLOWED_IPV6 = %w[
      ::/128 100::/64 2001::/32 2001:2::/48 2001:db8::/32 2002::/16
      fec0::/10 ff00::/8
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    # NAT64 prefixes: the well-known prefix (RFC 6052/6146) and the local-use
    # prefix (RFC 8215). An address here embeds an IPv4 target in its low 32
    # bits; we extract it and re-check against the IPv4 rules so NAT64 to a
    # public address still resolves while NAT64 to an internal address is
    # blocked.
    NAT64_PREFIXES = [
      IPAddr.new("64:ff9b::/96"),
      IPAddr.new("64:ff9b:1::/48")
    ].freeze

    def resolve(hostname)
      Resolv.getaddress(hostname).tap do |ip|
        raise Violation.new("Attempt to access private IP via #{hostname}") if ip && private_ip?(ip)
      end
    end

    def private_ip?(ip)
      ipaddr = IPAddr.new(ip)

      # DNS never legitimately returns these embedded forms, so block them all
      # regardless of the address they wrap.
      if ipaddr.ipv4_mapped? || ipaddr.ipv4_compat?
        true
      elsif ipaddr.ipv4?
        disallowed_ipv4?(ipaddr)
      elsif NAT64_PREFIXES.any? { |prefix| prefix.include?(ipaddr) }
        disallowed_ipv4?(embedded_ipv4(ipaddr))
      else
        disallowed_ipv6?(ipaddr)
      end
    rescue IPAddr::InvalidAddressError
      true
    end

    private
      def disallowed_ipv4?(ipaddr)
        ipaddr.private? || ipaddr.loopback? || ipaddr.link_local? ||
          DISALLOWED_IPV4.any? { |range| range.include?(ipaddr) }
      end

      def disallowed_ipv6?(ipaddr)
        ipaddr.private? || ipaddr.loopback? || ipaddr.link_local? ||
          DISALLOWED_IPV6.any? { |range| range.include?(ipaddr) }
      end

      def embedded_ipv4(ipaddr)
        IPAddr.new([ ipaddr.to_i & 0xffffffff ].pack("N").unpack("C4").join("."))
      end
  end
end
