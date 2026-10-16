# Enforcing baseline policy. Application pages narrow script-src from this
# origin to its asset directory, since uploads are served from this origin
# too, and allow the two inline scripts the importmap helper emits by hash
# (InlineScriptHashes). There is no per-request nonce, so rendered HTML stays
# cacheable. 'self' remains for responses outside ApplicationController, none
# of which render user content.
#
# Nothing else is restricted: images, media, fonts, styles (including an
# account's custom styles) and connections behave as before.
#
# DISABLE_CONTENT_SECURITY_POLICY=true is the escape hatch for an install whose
# proxy or customization injects scripts the policy would block.
unless ENV["DISABLE_CONTENT_SECURITY_POLICY"] == "true"
  Rails.application.configure do
    config.content_security_policy do |policy|
      policy.script_src :self
      policy.object_src :none
      policy.base_uri   :self
    end
  end
end
