# Enforcing baseline policy. Scripts run only from this origin; the two inline
# scripts the importmap helper emits are allowed by hash (InlineScriptHashes),
# so there is no per-request nonce and rendered HTML stays cacheable.
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
