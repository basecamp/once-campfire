require "surfguard"

module RestrictedHTTP
  class Violation < StandardError; end

  # The address policy lives in the surfguard gem so this app, Basecamp, HEY and
  # Fizzy classify "internal" the same way instead of each keeping a copy that
  # drifts. The callers here hand a bare hostname in and pin the address that
  # comes back, so this stays a hostname-in, address-out shim.
  module PrivateNetworkGuard
    extend self

    def resolve(hostname)
      Surfguard.resolve_public_ips(hostname).first or
        raise Violation.new("Attempt to access private IP via #{hostname}")
    end

    def private_ip?(ip)
      Surfguard.blocked_address?(ip)
    end
  end
end
