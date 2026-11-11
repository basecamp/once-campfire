Rails.application.config.session_store :cookie_store,
  key: "_campfire_session",
  # Preserve the existing installation's persistent browser-session cookie.
  expire_after: 20.years,
  # Lax is required so the session survives the top-level redirect back from
  # Sign in with Backlit after a passkey ceremony.
  same_site: :lax,
  secure: Rails.env.production?,
  httponly: true
