require "ipaddr"
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
    # predicates in #disallowed_ipv6?. The RFC 8215 local-use NAT64 prefix is
    # site-specific and not globally reachable, so it is never a valid fetch target.
    DISALLOWED_IPV6 = %w[
      ::/128 64:ff9b:1::/48 100::/64 2001::/32 2001:2::/48 2001:db8::/32 2002::/16
      fec0::/10 ff00::/8
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    # The well-known NAT64 prefix has a fixed /96 embedding. Re-check its IPv4
    # target so public DNS64 remains usable while translations to internal IPs fail.
    WELL_KNOWN_NAT64_PREFIX = IPAddr.new("64:ff9b::/96")

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
      elsif WELL_KNOWN_NAT64_PREFIX.include?(ipaddr)
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
