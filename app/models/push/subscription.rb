require "restricted_http/private_network_guard"

class Push::Subscription < ApplicationRecord
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
    # Defer DNS lookup to the delivery worker to prevent rebinding
    WebPush::Notification.new(**params, badge: user.memberships.unread.count, endpoint: endpoint, endpoint_ip_resolver: method(:resolved_endpoint_ip), p256dh_key: p256dh_key, auth_key: auth_key)
  end

  # Validate at point of use, not just when saved.
  def resolved_endpoint_ip
    RestrictedHTTP::PrivateNetworkGuard.resolve(endpoint_uri.host) if permitted_endpoint_uri?
  rescue RestrictedHTTP::Violation, Surfguard::Unresolvable
    nil
  end

  private
    # Validate endpoint shape. Belt & suspenders.
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
