class WebPush::Notification
  def initialize(title:, body:, path:, badge:, endpoint:, endpoint_ip_resolver:, p256dh_key:, auth_key:)
    @title, @body, @path, @badge = title, body, path, badge
    @endpoint, @endpoint_ip_resolver, @p256dh_key, @auth_key = endpoint, endpoint_ip_resolver, p256dh_key, auth_key
  end

  # @endpoint_ip_resolver resolves and guards the endpoint's public address --
  # Push::Subscription's allowlist plus surfguard's private-network classification
  # -- returning the IP to pin, or nil. It is invoked here, on the bounded
  # delivery worker, rather than when the notification is built on the serial
  # enqueue path, so a slow or stalled resolver can't hold up the push job before
  # any delivery starts (one blocking lookup per recipient, serialized, would
  # otherwise multiply a resolver timeout by the room's subscriber count).
  #
  # nil means the host resolved to nothing or to a blocked (private) address, so
  # we skip delivery rather than let the request fall back to re-resolving the
  # raw host -- which is what would reopen the SSRF for a subscription that
  # slipped in before endpoint validation existed.
  def deliver(connection: nil)
    if endpoint_ip = @endpoint_ip_resolver.call
      WebPush.payload_send \
        message: encoded_message,
        endpoint: @endpoint, endpoint_ip: endpoint_ip, p256dh: @p256dh_key, auth: @auth_key,
        vapid: vapid_identification,
        connection: connection,
        urgency: "high"
    end
  end

  private
    def vapid_identification
      { subject: "mailto:support@37signals.com" }.merge \
        Rails.configuration.x.vapid.symbolize_keys
    end

    def encoded_message
      JSON.generate title: @title, options: { body: @body, icon: icon_path, data: { path: @path, badge: @badge } }
    end

    def icon_path
      Rails.application.routes.url_helpers.account_logo_path
    end
end
