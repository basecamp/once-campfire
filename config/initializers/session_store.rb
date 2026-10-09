Rails.application.config.session_store :cookie_store,
  key: "_campfire_session",
  # Preserve the existing installation's persistent browser-session cookie.
  expire_after: 20.years
