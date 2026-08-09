# Be sure to restart your server when you modify this file.

# Baseline application-wide Content-Security-Policy, deployed in Report-Only
# mode: browsers evaluate the policy and report violations (once a report
# endpoint is wired up) but enforce nothing, so rendering cannot break.
# Tune the policy against observed violations, then flip
# `content_security_policy_report_only` off to enforce it.
#
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

# Session-stable nonce for permitted inline scripts (the importmap JSON + shim,
# auto-nonced by importmap-rails).
#
# The nonce is stable across a session's requests so Turbo snapshot restores
# don't replay a stale nonce and trip CSP. It's the HMAC of a stable cookie
# value keyed by the server secret: the cookie is client-settable, but the
# client can't predict the resulting nonce without knowing secret_key_base.
#
# Campfire sets no per-session verification cookie, so the lightweight
# nonce_id cookie — set on first visit, present for every session including
# unauthenticated ones — is the sole identifier.
module CSP
  module Nonce
    COOKIE = "campfire_csp_nonce_id"

    def self.generate(request)
      hmac(nonce_id(request))
    end

    def self.hmac(identifier)
      OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, identifier)
    end

    # Read or initialize a stable nonce identifier cookie.
    def self.nonce_id(request)
      request.cookies[COOKIE] || set_nonce_id(request)
    end

    def self.set_nonce_id(request)
      value = SecureRandom.base64(16)
      request.cookie_jar[COOKIE] = { value: value, httponly: true, same_site: :lax }
      value
    end
  end
end

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src     :self
    policy.script_src      :self  # nonce auto-appended via nonce_directives below
    # unsafe_inline retained: many style="…" attributes across the message
    # composer and ActionText content can't be nonced yet.
    policy.style_src       :self, :unsafe_inline
    # frame_src / img_src / connect_src start at :self and get tuned against
    # violation reports during the report-only window.
    policy.img_src         :self, :data, :blob
    policy.connect_src     :self
    policy.frame_src       :self
    policy.frame_ancestors :self
    policy.base_uri        :self
    policy.form_action     :self
    policy.object_src      :none
    # Specify URI for violation reports once a report sink is available
    # policy.report_uri "/csp-violation-report-endpoint"
  end

  config.content_security_policy_nonce_generator = ->(request) { CSP::Nonce.generate(request) }
  config.content_security_policy_nonce_directives = %w[ script-src ]

  # Report violations without enforcing the policy.
  config.content_security_policy_report_only = true
end
