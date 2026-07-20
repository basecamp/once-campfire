require "test_helper"
require "restricted_http/private_network_guard"

class RestrictedHTTP::PrivateNetworkGuardTest < ActiveSupport::TestCase
  test "private_ip? returns true for 'This' network (RFC1700)" do
    assert_private_ip "0.0.0.0"
    assert_private_ip "0.255.255.255"
  end

  test "private_ip? returns true for loopback addresses" do
    assert_private_ip "127.0.0.0"
    assert_private_ip "127.0.0.1"
    assert_private_ip "127.255.255.255"
  end

  test "private_ip? returns true for RFC1918 private addresses" do
    assert_private_ip "10.0.0.0"
    assert_private_ip "10.255.255.255"
    assert_private_ip "172.16.0.0"
    assert_private_ip "172.31.255.255"
    assert_private_ip "192.168.0.0"
    assert_private_ip "192.168.255.255"
  end

  test "private_ip? returns true for link-local addresses" do
    assert_private_ip "169.254.0.1"
    assert_private_ip "169.254.169.254"  # AWS IMDS
    assert_private_ip "169.254.255.255"
  end

  test "private_ip? returns false for public addresses" do
    assert_not RestrictedHTTP::PrivateNetworkGuard.private_ip?("93.184.216.34")
    assert_not RestrictedHTTP::PrivateNetworkGuard.private_ip?("8.8.8.8")
  end

  # IPv6 address format tests (SSRF bypass prevention)

  test "private_ip? returns true for IPv4-mapped IPv6 addresses with private IPs" do
    assert_private_ip "::ffff:192.168.1.1"
    assert_private_ip "::ffff:10.0.0.1"
    assert_private_ip "::ffff:172.16.0.1"
  end

  test "private_ip? returns true for IPv4-mapped IPv6 addresses with link-local IPs" do
    assert_private_ip "::ffff:169.254.169.254"  # AWS metadata via mapped format
  end

  test "private_ip? returns true for IPv4-mapped IPv6 addresses even with public IPs" do
    # Block all ipv4_mapped? since DNS never returns this format legitimately
    assert_private_ip "::ffff:93.184.216.34"
  end

  test "private_ip? returns true for IPv4-compatible IPv6 addresses with private IPs" do
    assert_private_ip "::192.168.1.1"
    assert_private_ip "::10.0.0.1"
  end

  test "private_ip? returns true for IPv4-compatible IPv6 addresses with link-local IPs" do
    assert_private_ip "::169.254.169.254"  # AWS metadata via compat format - the reported bypass
  end

  test "private_ip? returns true for IPv4-compatible IPv6 addresses even with public IPs" do
    # Block all ipv4_compat? since DNS never returns this format legitimately
    assert_private_ip "::93.184.216.34"
  end

  # IPv6/encapsulation and shared-address ranges (SSRF bypass prevention)

  test "private_ip? returns true for NAT64 addresses" do
    assert_private_ip "64:ff9b::a00:1"  # NAT64-embedded 10.0.0.1
  end

  test "private_ip? returns true for 6to4 addresses" do
    assert_private_ip "2002::1"
    assert_private_ip "2002:0a00:0001::"  # 6to4-embedded 10.0.0.1
  end

  test "private_ip? returns true for CGNAT / shared address space" do
    assert_private_ip "100.64.0.1"
    assert_private_ip "100.127.255.255"
  end

  test "private_ip? returns false for public addresses outside the new ranges" do
    assert_not RestrictedHTTP::PrivateNetworkGuard.private_ip?("93.184.216.34")
  end

  test "private_ip? returns true for invalid addresses" do
    assert RestrictedHTTP::PrivateNetworkGuard.private_ip?("not-an-ip")
    assert RestrictedHTTP::PrivateNetworkGuard.private_ip?("")
  end

  test "resolve raises Violation for private hostname" do
    Resolv.stubs(:getaddress).returns("192.168.1.1")
    assert_raises RestrictedHTTP::Violation do
      RestrictedHTTP::PrivateNetworkGuard.resolve("private.example.com")
    end
  end

  test "resolve returns IP for public hostname" do
    Resolv.stubs(:getaddress).returns("93.184.216.34")
    assert_equal "93.184.216.34", RestrictedHTTP::PrivateNetworkGuard.resolve("example.com")
  end

  private
    def assert_private_ip(address)
      assert RestrictedHTTP::PrivateNetworkGuard.private_ip?(address),
        "Expected #{address} to be classified as private"
    end
end
