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

  # Per-install CSP extras.
  #
  # Campfire is a ONCE product: each customer self-hosts it on their own domain
  # and an admin may embed or connect to external hosts — video/embed providers,
  # image CDNs, analytics, form or webhook endpoints — that vary per install and
  # are unknown at build time. `:self` already tracks this install's own origin;
  # these ENV knobs let an admin allow additional hosts without editing this file
  # (and without which enforcement would break their legitimate integrations).
  #
  # Each is a comma-, semicolon-, or whitespace-separated list of CSP source
  # expressions, e.g.
  #
  #   CSP_EXTRA_FRAME_SRC="https://www.youtube.com https://player.vimeo.com"
  #
  # Leave them unset (the default) to keep each directive at :self only.
  EXTRA_ENV = {
    script_src:  "CSP_EXTRA_SCRIPT_SRC",
    style_src:   "CSP_EXTRA_STYLE_SRC",
    img_src:     "CSP_EXTRA_IMG_SRC",
    connect_src: "CSP_EXTRA_CONNECT_SRC",
    frame_src:   "CSP_EXTRA_FRAME_SRC",
    form_action: "CSP_EXTRA_FORM_ACTION"
  }.freeze

  # Parse one ENV knob into a list of extra host sources.
  #
  # Semicolons are tokenized like commas/whitespace: because the nonce forces a
  # per-request policy build, a stray `;` in a value (a plausible operator paste,
  # e.g. "https://youtube.com; https://vimeo.com") would otherwise land inside a
  # single source token and make Rails raise InvalidDirectiveError on every
  # request — a site-wide 500 even in report-only mode. Splitting on `;` yields
  # valid tokens instead; Rails still validates each one, so no injection is
  # introduced (a token with an embedded space still fails validation).
  def self.extra(directive)
    ENV[EXTRA_ENV.fetch(directive)].to_s.split(/[,;\s]+/).reject(&:blank?)
  end

  # Build the baseline policy. Kept as a reusable method so it can be exercised
  # in isolation by tests as well as at boot.
  def self.apply(policy)
    policy.default_src     :self
    policy.script_src      :self, *extra(:script_src)  # nonce auto-appended via nonce_directives below
    # unsafe_inline retained: many style="…" attributes across the message
    # composer and ActionText content can't be nonced yet.
    policy.style_src       :self, :unsafe_inline, *extra(:style_src)
    # frame_src / img_src / connect_src start at :self plus any per-install extras
    # and get tuned against violation reports during the report-only window.
    policy.img_src         :self, :data, :blob, *extra(:img_src)
    policy.connect_src     :self, *extra(:connect_src)
    policy.frame_src       :self, *extra(:frame_src)
    policy.frame_ancestors :self
    policy.base_uri        :self
    policy.form_action     :self, *extra(:form_action)
    policy.object_src      :none
    # Specify URI for violation reports once a report sink is available
    # policy.report_uri "/csp-violation-report-endpoint"
  end
end

Rails.application.configure do
  config.content_security_policy { |policy| CSP.apply(policy) }

  config.content_security_policy_nonce_generator = ->(request) { CSP::Nonce.generate(request) }
  config.content_security_policy_nonce_directives = %w[ script-src ]

  # Report violations without enforcing the policy.
  config.content_security_policy_report_only = true
end
