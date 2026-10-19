module Users::PushSubscriptionsHelper
  # Names the session without revealing its token, so the browser can tell when it's in a new one. The creation
  # time keeps an id reused by a new database from looking like the same session.
  def push_subscription_session_marker
    Digest::SHA256.hexdigest("push-subscription-session-#{Current.session.id}-#{Current.session.created_at.to_f}") if Current.session
  end
end
