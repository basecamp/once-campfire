require "test_helper"

class Oidc::DocumentationTest < ActiveSupport::TestCase
  test "documents the enforced transport guarantees" do
    sso_guide = Rails.root.join("docs/sso.md").read.squish
    self_hosting_guide = Rails.root.join("docs/self-hosting.md").read.squish

    assert_includes sso_guide, "Built-in Thruster TLS requires `443`"
    assert_includes sso_guide, "Thruster-prefixed `THRUSTER_TLS_DOMAIN`"
    assert_includes sso_guide, "rejects arbitrary HTTP Host values"
    assert_includes self_hosting_guide,
      "`DISABLE_SSL=true` does not authorize plaintext production traffic"
    assert_includes self_hosting_guide,
      "pass the original HTTPS scheme through `X-Forwarded-Proto: https`"
    assert_includes self_hosting_guide,
      "direct clients must not be able to reach or spoof requests to the application port"
    assert_includes self_hosting_guide,
      "Authentication cookies remain `Secure` even when TLS terminates at the proxy"
    assert_includes self_hosting_guide,
      "CIDRs of only the proxies that connect directly to Campfire"
    assert_includes self_hosting_guide, "Campfire ignores forwarded HTTPS from other addresses"
    assert_includes self_hosting_guide,
      "send the exact port in `X-Forwarded-Port` and set the same value in `HTTPS_PORT`"
    assert_includes self_hosting_guide,
      "Rails CSRF and Action Cable origin checks use the browser's canonical origin"
  end
end
