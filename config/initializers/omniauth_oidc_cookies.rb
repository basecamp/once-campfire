# frozen_string_literal: true

# OmniAuth OpenID Connect stores state/nonce/PKCE verifier in the Rails session.
# During Sign in with Backlit, the browser leaves Campfire, signs in on bck.lt
# (often with a passkey), then returns via a cross-site redirect. If the large
# _campfire_session cookie is dropped or partitioned, callback CSRF fails and
# the user lands back on the Campfire sign-in page.
#
# Mirror those short-lived values into small signed cookies so the callback can
# still validate state after a passkey sign-in in a fresh browser.
module OmniAuthOidcCookies
  def self.cookie_opts
    {
      expires: 30.minutes,
      secure: Rails.env.production?,
      httponly: true,
      same_site: :lax
    }
  end

  def new_state
    state = super
    write_oidc_cookie("omniauth.state", state)
    state
  end

  def stored_state
    read_oidc_cookie("omniauth.state") || super
  end

  def new_nonce
    nonce = super
    write_oidc_cookie("omniauth.nonce", nonce)
    nonce
  end

  def stored_nonce
    read_oidc_cookie("omniauth.nonce") || super
  end

  def authorize_uri
    uri = super
    verifier = session["omniauth.pkce.verifier"]
    write_oidc_cookie("omniauth.pkce.verifier", verifier) if verifier.present?
    uri
  end

  def access_token
    if options.pkce && session["omniauth.pkce.verifier"].blank?
      session["omniauth.pkce.verifier"] = read_oidc_cookie("omniauth.pkce.verifier")
    end
    super
  end

  private
    def write_oidc_cookie(name, value)
      return if value.blank? || @env.nil?

      request = ActionDispatch::Request.new(@env)
      request.cookie_jar.signed[name] = OmniAuthOidcCookies.cookie_opts.merge(value: value)
    end

    def read_oidc_cookie(name)
      return if @env.nil?

      request = ActionDispatch::Request.new(@env)
      value = request.cookie_jar.signed[name]
      request.cookie_jar.delete(name)
      value
    end
end

OmniAuth::Strategies::OpenIDConnect.prepend(OmniAuthOidcCookies)
