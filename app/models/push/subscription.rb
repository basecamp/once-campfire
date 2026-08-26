class Push::Subscription < ApplicationRecord
  # Web push endpoints only ever point at a browser vendor's push service. An
  # allowlist keeps a user-supplied endpoint from turning delivery into an SSRF
  # sink, and pinning the resolved public IP on every delivery closes the
  # DNS-rebinding gap the way Opengraph::Fetch does for unfurls.
  PERMITTED_ENDPOINT_HOSTS = %w[
    jmt17.google.com
    fcm.googleapis.com
    updates.push.services.mozilla.com
    web.push.apple.com
    notify.windows.com
  ].freeze

  belongs_to :user

  validates :endpoint, presence: true
  validate :validate_endpoint_url

  def notification(**params)
    WebPush::Notification.new(**params, badge: user.memberships.unread.count, endpoint: endpoint, endpoint_ip: resolved_endpoint_ip, p256dh_key: p256dh_key, auth_key: auth_key)
  end

  # The public address to pin this delivery to, or nil when the endpoint is not a
  # permitted push service or doesn't resolve to a public IP. Enforced here, not
  # only at save time, so a row that predates validation (or was inserted around
  # it) still can't drive delivery at a non-allowlisted or private target.
  # Re-resolved on every call so each delivery pins a freshly looked-up address
  # rather than trusting the host to still resolve the way it did at sign-up.
  def resolved_endpoint_ip
    Surfguard.resolve_public_ips(endpoint_uri.host).first if permitted_endpoint_uri?
  rescue Surfguard::Unresolvable
    # A host that resolves to nothing has no usable public IP -- the same outcome
    # as one whose only addresses are blocked: no endpoint IP to pin, which fails
    # endpoint validation. Push has no lookup-failed surface to distinguish.
    nil
  end

  private
    # The full shape a deliverable endpoint must have: HTTPS on the default port,
    # pointing at a permitted push service. Gating resolution on this (not just
    # the host) keeps a row that slipped past save-time validation from driving
    # delivery to an odd port or scheme on a permitted vendor's address.
    def permitted_endpoint_uri?
      endpoint_uri&.scheme == "https" && endpoint_uri.port == 443 && permitted_endpoint_host?
    end

    def endpoint_uri
      URI.parse(endpoint) if endpoint.present?
    rescue URI::InvalidURIError
      nil
    end

    def validate_endpoint_url
      if endpoint_uri.nil?
        errors.add(:endpoint, "is not a valid URL")
      elsif endpoint_uri.scheme != "https"
        errors.add(:endpoint, "must use HTTPS")
      elsif endpoint_uri.port != 443
        errors.add(:endpoint, "must use the default HTTPS port")
      elsif !permitted_endpoint_host?
        errors.add(:endpoint, "is not a permitted push service")
      elsif resolved_endpoint_ip.nil?
        errors.add(:endpoint, "resolves to a private or invalid IP address")
      end
    end

    def permitted_endpoint_host?
      host = endpoint_uri&.host&.downcase
      host.present? && PERMITTED_ENDPOINT_HOSTS.any? do |permitted|
        host == permitted || host.end_with?(".#{permitted}")
      end
    end
end
