class SecureSessionCookie
  def initialize(app)
    @app = app
  end

  def call(env)
    if ActionDispatch::Request.new(env).ssl?
      env.fetch("rack.session.options")[:secure] = true
    end
    @app.call(env)
  end
end

Rails.application.config.session_store :cookie_store,
  key: "_campfire_session",
  secure: Oidc.secure_session_cookie?,
  # Persist session cookie as permament so re-opened browser windows maintain a CSRF token
  expire_after: 20.years
Rails.application.config.middleware.insert_after ActionDispatch::Session::CookieStore, SecureSessionCookie
